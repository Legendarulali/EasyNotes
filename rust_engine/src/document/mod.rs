//! The in-memory document and the editing engine operating on it.
//!
//! Items (strokes and sticky notes) share a single monotonically increasing key space.
//! Keys double as z-order (higher = newer = on top) and are encoded in the public string
//! IDs (`s42` for strokes, `n43` for notes), so the FFI layer can stay string based.
//!
//! Paged documents (notebooks, imported PDFs) keep every item inside the 1000-unit-wide
//! page column and grow the [`PageStack`] at the bottom whenever content reaches past the
//! last page. Whiteboards are unbounded towards +X / +Y.

pub mod eraser;
pub mod page;
pub mod paper;
pub mod pdf_importer;
pub mod storage;

pub use eraser::EraserMode;
pub use page::{CanvasPage, DocumentKind, PageStack, PAGE_HEIGHT, PAGE_WIDTH};
pub use paper::{PaperKind, PaperSpec, PaperStyle};
pub use pdf_importer::ImportedPdf;
pub use storage::DocumentData;

use crate::geometry::stroke::process_input;
use crate::geometry::{
    detect_and_snap_rectangle, Brush, ShapeKind, StickyNote, Stroke, StrokePoint, StrokeRender,
    ToolType, TransformMatrix, Vec2, ViewportRect,
};
use crate::spatial::hit_test::{distance_to_polyline, point_in_polygon};
use crate::spatial::{BoundsTransform, QuadTree};
use eraser::{cut_polyline, CutOutcome, EraserSweep};
use std::collections::{BTreeMap, BTreeSet};

/// Offset applied to duplicated items so the copy is visibly separate.
pub const DUPLICATE_OFFSET: f32 = 24.0;
/// Share of a stroke's samples that must fall inside a lasso / box to select it.
const SELECTION_COVERAGE: f32 = 0.5;
/// Content may poke this far below the last page (stroke thickness, rounding) before a
/// new page is appended for it.
const PAGE_COVER_TOLERANCE: f32 = 12.0;

/// Current selection: ids plus their combined bounding box.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SelectionInfo {
    pub ids: Vec<String>,
    pub bounds: Option<ViewportRect>,
}

/// Incremental scene change returned by mutating operations, so Flutter only patches
/// what changed instead of re-downloading the whole document.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SceneDelta {
    pub upserted_strokes: Vec<StrokeRender>,
    pub upserted_notes: Vec<StickyNote>,
    pub removed_ids: Vec<String>,
    pub selection: SelectionInfo,
    /// Page count after the operation (it grows when content moves below the last page).
    pub page_count: u32,
}

/// Full scene, z-ordered (used for initial load / resynchronisation).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SceneSnapshot {
    pub strokes: Vec<StrokeRender>,
    pub notes: Vec<StickyNote>,
    pub selection: SelectionInfo,
}

/// Document-level state shown by the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct DocumentInfo {
    pub kind: DocumentKind,
    pub paper: PaperStyle,
    /// Width of every page ([`PAGE_WIDTH`]), or `0` for the unbounded whiteboard.
    pub page_width: f32,
    pub pages: Vec<CanvasPage>,
    /// Pages in the imported PDF (`0` when there is none).
    pub pdf_page_count: u32,
    /// Bumped by every change; compare with the value of the last save to detect edits.
    pub revision: u32,
    pub item_count: u32,
}

#[derive(Debug, Clone)]
enum ClipItem {
    Stroke(Stroke),
    Note(StickyNote),
}

#[derive(Debug, Clone)]
struct PendingStroke {
    tool: ToolType,
    brush: Brush,
    points: Vec<StrokePoint>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemKind {
    Stroke,
    Note,
}

fn encode_id(kind: ItemKind, key: u64) -> String {
    match kind {
        ItemKind::Stroke => format!("s{key}"),
        ItemKind::Note => format!("n{key}"),
    }
}

fn decode_id(id: &str) -> Option<(ItemKind, u64)> {
    let kind = match id.as_bytes().first()? {
        b's' => ItemKind::Stroke,
        b'n' => ItemKind::Note,
        _ => return None,
    };
    id[1..].parse().ok().map(|k| (kind, k))
}

/// Keeps a note inside the page column (`max_x`) when there is one.
fn fit_note(note: StickyNote, max_x: Option<f32>) -> StickyNote {
    let mut n = note.sanitized();
    if let Some(max_x) = max_x {
        n.width = n.width.min(max_x);
        n.x = n.x.min(max_x - n.width).max(0.0);
    }
    n
}

/// Document state + editing operations. Not thread-safe by itself; the API layer wraps it
/// in a mutex.
#[derive(Debug)]
pub struct Engine {
    kind: DocumentKind,
    paper: PaperStyle,
    pages: PageStack,
    pdf: Option<ImportedPdf>,
    revision: u32,
    strokes: BTreeMap<u64, Stroke>,
    notes: BTreeMap<u64, StickyNote>,
    index: QuadTree,
    selection: BTreeSet<u64>,
    clipboard: Vec<ClipItem>,
    pending: Option<PendingStroke>,
    next_key: u64,
    paste_count: u32,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    /// An empty, unbounded whiteboard.
    pub fn new() -> Self {
        Self::with_kind(DocumentKind::Whiteboard, PaperStyle::Whiteboard)
    }

    /// An empty document of `kind` (paged kinds start with one 1000 × 1000 page).
    pub fn with_kind(kind: DocumentKind, paper: PaperStyle) -> Self {
        Self {
            kind,
            paper,
            pages: if kind.is_paged() {
                PageStack::blank(1)
            } else {
                PageStack::default()
            },
            pdf: None,
            revision: 0,
            strokes: BTreeMap::new(),
            notes: BTreeMap::new(),
            index: QuadTree::new(),
            selection: BTreeSet::new(),
            clipboard: Vec::new(),
            pending: None,
            next_key: 1,
            paste_count: 0,
        }
    }

    /// A PDF annotation document: one background page per PDF page.
    pub fn with_pdf(pdf: ImportedPdf) -> Self {
        let mut e = Self::with_kind(DocumentKind::PdfAnnotation, PaperStyle::Whiteboard);
        e.pages = pdf.page_stack();
        e.pdf = Some(pdf);
        e
    }

    /// Rebuilds an engine from saved data. Page backgrounds referring to PDF pages that
    /// do not exist (missing or replaced PDF) fall back to blank pages.
    pub fn from_data(data: DocumentData, pdf: Option<ImportedPdf>) -> Self {
        let mut e = Self::with_kind(data.kind, data.paper);
        if data.kind.is_paged() && !data.pages.is_empty() {
            let pdf_pages = pdf.as_ref().map_or(0, ImportedPdf::page_count);
            let heights: Vec<(f32, Option<u32>)> = data
                .pages
                .iter()
                .map(|p| (p.height, p.pdf_page.filter(|&i| i < pdf_pages)))
                .collect();
            e.pages = PageStack::from_heights(&heights);
        }
        e.pdf = pdf;
        for mut s in data.strokes {
            let key = e.alloc_key();
            s.id = encode_id(ItemKind::Stroke, key);
            e.index.insert(key, s.bounds());
            e.strokes.insert(key, s);
        }
        let max_x = e.page_limit_x();
        for n in data.notes {
            let key = e.alloc_key();
            let mut n = fit_note(n, max_x);
            n.id = encode_id(ItemKind::Note, key);
            e.index.insert(key, n.rect());
            e.notes.insert(key, n);
        }
        e
    }

    /// Clones the persistent part of the document (for saving / exporting off-lock).
    pub fn data(&self) -> DocumentData {
        DocumentData {
            kind: self.kind,
            paper: self.paper,
            pages: self.pages.pages().to_vec(),
            strokes: self.strokes(),
            notes: self.notes(),
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Removes every stroke and note but keeps the document type, paper, pages, the
    /// imported PDF and the clipboard.
    pub fn clear_content(&mut self) {
        self.strokes.clear();
        self.notes.clear();
        self.index.clear();
        self.selection.clear();
        self.pending = None;
        self.touch();
    }

    fn alloc_key(&mut self) -> u64 {
        let k = self.next_key;
        self.next_key += 1;
        k
    }

    fn kind_of(&self, key: u64) -> Option<ItemKind> {
        if self.strokes.contains_key(&key) {
            Some(ItemKind::Stroke)
        } else if self.notes.contains_key(&key) {
            Some(ItemKind::Note)
        } else {
            None
        }
    }

    fn id_of(&self, key: u64) -> Option<String> {
        self.kind_of(key).map(|k| encode_id(k, key))
    }

    fn item_bounds(&self, key: u64) -> Option<ViewportRect> {
        self.index.bounds_of(key)
    }

    // ------------------------------------------------------------------ document / pages

    pub fn kind(&self) -> DocumentKind {
        self.kind
    }

    pub fn paper(&self) -> PaperStyle {
        self.paper
    }

    pub fn pdf(&self) -> Option<&ImportedPdf> {
        self.pdf.as_ref()
    }

    pub fn pages(&self) -> &[CanvasPage] {
        self.pages.pages()
    }

    pub fn page_count(&self) -> u32 {
        self.pages.len() as u32
    }

    pub fn revision(&self) -> u32 {
        self.revision
    }

    pub fn info(&self) -> DocumentInfo {
        DocumentInfo {
            kind: self.kind,
            paper: self.paper,
            page_width: if self.kind.is_paged() {
                PAGE_WIDTH
            } else {
                0.0
            },
            pages: self.pages.pages().to_vec(),
            pdf_page_count: self.pdf.as_ref().map_or(0, ImportedPdf::page_count),
            revision: self.revision,
            item_count: self.item_count() as u32,
        }
    }

    pub fn set_paper(&mut self, paper: PaperStyle) {
        if paper != self.paper {
            self.paper = paper;
            self.touch();
        }
    }

    /// Appends a blank page at the bottom (continuous scroll). `None` for whiteboards or
    /// at the page limit.
    pub fn append_page(&mut self) -> Option<CanvasPage> {
        if !self.kind.is_paged() {
            return None;
        }
        let page = self.pages.append_blank()?;
        self.touch();
        Some(page)
    }

    /// Continuous scroll / writing: appends the next blank page when `y` (the bottom of the
    /// visible area, or the pen) is within `margin` units of the end of the last page.
    /// Appends at most one page per call; `None` when not near the end, for whiteboards
    /// or at the page limit.
    pub fn append_page_if_near_end(&mut self, y: f32, margin: f32) -> Option<CanvasPage> {
        if !self.kind.is_paged() || !self.pages.is_near_end(y, margin) {
            return None;
        }
        self.append_page()
    }

    /// Removes blank pages at the end of the stack that nothing was written on (pages
    /// created by scrolling down). Imported PDF pages and the first page always stay.
    /// Returns how many pages were removed.
    pub fn trim_trailing_blank_pages(&mut self) -> u32 {
        if !self.kind.is_paged() {
            return 0;
        }
        // Same tolerance as `cover`: a stroke's edge grazing the next page does not keep it.
        let bottom = self
            .content_bounds()
            .map_or(0.0, |b| b.bottom - PAGE_COVER_TOLERANCE);
        let removed = self.pages.trim_trailing_blank(bottom, 1);
        if removed > 0 {
            self.touch();
        }
        removed as u32
    }

    fn touch(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }

    /// Right edge of the page column, `None` for the unbounded whiteboard.
    fn page_limit_x(&self) -> Option<f32> {
        self.kind.is_paged().then_some(PAGE_WIDTH)
    }

    /// Appends pages so content reaching down to `bottom` sits on paper.
    fn cover(&mut self, bottom: f32) {
        if self.kind.is_paged() && self.pages.ensure_covers(bottom - PAGE_COVER_TOLERANCE) > 0 {
            self.touch();
        }
    }

    /// Restricts a translation of `bounds` so it stays at x, y ≥ 0 and, on paged
    /// documents, inside the page column whenever it fits.
    fn clamp_offset(&self, bounds: &ViewportRect, mut dx: f32, mut dy: f32) -> (f32, f32) {
        if let Some(max_x) = self.page_limit_x() {
            let overflow = bounds.right + dx - max_x;
            if overflow > 0.0 {
                dx -= overflow;
            }
        }
        if bounds.left + dx < 0.0 {
            dx = -bounds.left;
        }
        if bounds.top + dy < 0.0 {
            dy = -bounds.top;
        }
        (dx, dy)
    }

    fn finish_delta(&self, mut delta: SceneDelta) -> SceneDelta {
        delta.selection = self.selection_info();
        delta.page_count = self.page_count();
        delta
    }

    // ------------------------------------------------------------------ drawing

    pub fn begin_stroke(&mut self, tool: ToolType, brush: Brush) {
        self.pending = Some(PendingStroke {
            tool,
            brush,
            points: Vec::with_capacity(256),
        });
    }

    /// Appends an input sample. On paged documents the sample is clamped to the page
    /// column (and at most one page below the last one).
    pub fn add_point(&mut self, point: StrokePoint) {
        let point = if self.kind.is_paged() {
            let (x, y) = self.pages.clamp_point(point.x, point.y);
            StrokePoint::new(x, y, point.pressure)
        } else {
            point
        };
        let pending = self.pending.get_or_insert_with(|| PendingStroke {
            tool: ToolType::Pen,
            brush: Brush::default(),
            points: Vec::new(),
        });
        pending.points.push(point);
    }

    pub fn cancel_stroke(&mut self) {
        self.pending = None;
    }

    fn build_stroke(
        &self,
        pending: &PendingStroke,
        tool: ToolType,
        auto_correct: bool,
    ) -> Option<Stroke> {
        let width = if pending.brush.width.is_finite() {
            pending.brush.width.clamp(0.2, 200.0)
        } else {
            3.0
        };
        let mut points = process_input(&pending.points, width);
        if points.is_empty() {
            return None;
        }
        let mut shape = ShapeKind::Freehand;
        if auto_correct {
            if let Some(rect) = detect_and_snap_rectangle(&points) {
                points = rect;
                shape = ShapeKind::Rectangle;
            }
        }
        let mean_pressure = points.iter().map(|p| p.pressure).sum::<f32>() / points.len() as f32;
        let opacity = if pending.brush.opacity.is_finite() {
            pending.brush.opacity.clamp(0.02, 1.0)
        } else {
            1.0
        };
        Some(Stroke {
            id: String::new(),
            points,
            color: pending.brush.color,
            width,
            alpha: (opacity * tool.opacity_factor(mean_pressure)).clamp(0.0, 1.0),
            tool_type: tool,
            transform_matrix: TransformMatrix::IDENTITY,
            shape,
        })
    }

    /// Render of the stroke currently being drawn (same tessellation as the final one).
    pub fn preview(&self) -> Option<StrokeRender> {
        let pending = self.pending.as_ref()?;
        if !pending.tool.is_ink() {
            return None;
        }
        let mut s = self.build_stroke(pending, pending.tool, false)?;
        s.id = "preview".into();
        Some(s.render())
    }

    /// Commits the pending stroke. With `auto_correct`, rectangle-like loops are snapped
    /// to a clean geometric rectangle right here, on pen-up. The eraser tool erases along
    /// the gesture instead (stroke mode).
    pub fn finish_stroke(&mut self, tool: ToolType, auto_correct: bool) -> Option<StrokeRender> {
        let pending = self.pending.take()?;
        match tool {
            ToolType::Eraser => {
                let radius = pending.brush.width.max(4.0) * 0.5;
                let pts: Vec<Vec2> = pending.points.iter().map(StrokePoint::pos).collect();
                for (i, &p) in pts.iter().enumerate() {
                    let prev = if i == 0 { p } else { pts[i - 1] };
                    self.erase_along(prev, p, radius, EraserMode::Stroke);
                }
                None
            }
            ToolType::StickyNote => None,
            _ => {
                let mut stroke = self.build_stroke(&pending, tool, auto_correct)?;
                let key = self.alloc_key();
                stroke.id = encode_id(ItemKind::Stroke, key);
                let render = stroke.render();
                self.index.insert(key, render.bounds);
                self.strokes.insert(key, stroke);
                self.cover(render.bounds.bottom);
                self.touch();
                Some(render)
            }
        }
    }

    // ------------------------------------------------------------------ erasing

    /// Stroke eraser at a single point: removes every stroke touched by a circle of
    /// `radius` at `(x, y)`. Returns the removed ids.
    pub fn erase_at(&mut self, x: f32, y: f32, radius: f32) -> Vec<String> {
        let p = Vec2::new(x, y);
        self.erase_along(p, p, radius, EraserMode::Stroke)
            .removed_ids
    }

    /// Erases along the eraser's path from `from` to `to` (the capsule swept by a disc of
    /// `radius`). [`EraserMode::Stroke`] deletes touched strokes; [`EraserMode::Partial`]
    /// cuts them and keeps the pieces outside the eraser as separate strokes (the first
    /// piece keeps the original id and z-position). Sticky notes are never erased.
    pub fn erase_along(
        &mut self,
        from: Vec2,
        to: Vec2,
        radius: f32,
        mode: EraserMode,
    ) -> SceneDelta {
        let sweep = EraserSweep::new(from, to, radius);
        let mut delta = SceneDelta::default();
        let mut keys: Vec<u64> = self
            .index
            .query(&sweep.bounds(0.0))
            .into_iter()
            .filter(|k| self.strokes.contains_key(k))
            .collect();
        keys.sort_unstable();
        let mut changed = false;
        for key in keys {
            let Some(stroke) = self.strokes.get(&key) else {
                continue;
            };
            let world = stroke.world_points();
            let closed = stroke.shape == ShapeKind::Rectangle;
            match mode {
                EraserMode::Stroke => {
                    let pts: Vec<Vec2> = world.iter().map(StrokePoint::pos).collect();
                    let reach = sweep.radius + stroke.max_half_width() * 0.8;
                    if sweep.touches(&pts, closed, reach) && self.remove_item(key) {
                        delta.removed_ids.push(encode_id(ItemKind::Stroke, key));
                        changed = true;
                    }
                }
                EraserMode::Partial => {
                    let reach = sweep.radius + stroke.max_half_width() * 0.5;
                    match cut_polyline(&world, closed, &sweep, reach) {
                        CutOutcome::Untouched => {}
                        CutOutcome::Erased => {
                            if self.remove_item(key) {
                                delta.removed_ids.push(encode_id(ItemKind::Stroke, key));
                                changed = true;
                            }
                        }
                        CutOutcome::Split(pieces) => {
                            // Pieces are baked into world space (identity transform).
                            let template = Stroke {
                                id: String::new(),
                                points: Vec::new(),
                                width: stroke.world_width(),
                                transform_matrix: TransformMatrix::IDENTITY,
                                shape: match stroke.shape {
                                    ShapeKind::Freehand => ShapeKind::Freehand,
                                    _ => ShapeKind::Polyline,
                                },
                                ..stroke.clone()
                            };
                            for (i, points) in pieces.into_iter().enumerate() {
                                let k = if i == 0 { key } else { self.alloc_key() };
                                let piece = Stroke {
                                    id: encode_id(ItemKind::Stroke, k),
                                    points,
                                    ..template.clone()
                                };
                                let render = piece.render();
                                self.index.insert(k, render.bounds);
                                self.strokes.insert(k, piece);
                                delta.upserted_strokes.push(render);
                            }
                            changed = true;
                        }
                    }
                }
            }
        }
        if changed {
            self.touch();
        }
        self.finish_delta(delta)
    }

    fn remove_item(&mut self, key: u64) -> bool {
        let existed = self.strokes.remove(&key).is_some() || self.notes.remove(&key).is_some();
        if existed {
            self.index.remove(key);
            self.selection.remove(&key);
        }
        existed
    }

    // ------------------------------------------------------------------ sticky notes

    pub fn create_note(
        &mut self,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: u32,
        text: String,
    ) -> StickyNote {
        let key = self.alloc_key();
        let note = fit_note(
            StickyNote {
                id: encode_id(ItemKind::Note, key),
                x,
                y,
                width,
                height,
                color,
                text,
                font_size: crate::geometry::sticky_note::DEFAULT_NOTE_FONT_SIZE,
            },
            self.page_limit_x(),
        );
        self.index.insert(key, note.rect());
        self.notes.insert(key, note.clone());
        self.cover(note.rect().bottom);
        self.touch();
        note
    }

    /// Replaces a note's geometry / text / colour. Returns `None` for unknown ids.
    pub fn update_note(&mut self, note: StickyNote) -> Option<StickyNote> {
        let (kind, key) = decode_id(&note.id)?;
        if kind != ItemKind::Note || !self.notes.contains_key(&key) {
            return None;
        }
        let note = fit_note(note, self.page_limit_x());
        self.index.insert(key, note.rect());
        self.notes.insert(key, note.clone());
        self.cover(note.rect().bottom);
        self.touch();
        Some(note)
    }

    /// Topmost note under `(x, y)`.
    pub fn note_at(&self, x: f32, y: f32) -> Option<StickyNote> {
        let p = Vec2::new(x, y);
        self.index
            .query_point(p, 0.0)
            .into_iter()
            .filter(|k| self.notes.get(k).is_some_and(|n| n.rect().contains(p)))
            .max()
            .and_then(|k| self.notes.get(&k).cloned())
    }

    pub fn delete_items(&mut self, ids: &[String]) -> SceneDelta {
        let mut removed = Vec::new();
        for id in ids {
            if let Some((_, key)) = decode_id(id) {
                if self.remove_item(key) {
                    removed.push(id.clone());
                }
            }
        }
        if !removed.is_empty() {
            self.touch();
        }
        self.finish_delta(SceneDelta {
            removed_ids: removed,
            ..Default::default()
        })
    }

    // ------------------------------------------------------------------ selection

    pub fn selection_info(&self) -> SelectionInfo {
        let mut bounds: Option<ViewportRect> = None;
        let mut ids = Vec::with_capacity(self.selection.len());
        for &key in &self.selection {
            if let (Some(id), Some(b)) = (self.id_of(key), self.item_bounds(key)) {
                ids.push(id);
                bounds = Some(bounds.map_or(b, |acc| acc.union(&b)));
            }
        }
        SelectionInfo { ids, bounds }
    }

    pub fn clear_selection(&mut self) {
        self.selection.clear();
    }

    /// Replaces the selection with the given ids (unknown ids are ignored).
    pub fn set_selection(&mut self, ids: &[String]) -> SelectionInfo {
        self.selection = ids
            .iter()
            .filter_map(|id| decode_id(id))
            .map(|(_, k)| k)
            .filter(|k| self.kind_of(*k).is_some())
            .collect();
        self.selection_info()
    }

    fn select_where<F: Fn(Vec2) -> bool>(
        &mut self,
        area: &ViewportRect,
        inside: F,
    ) -> SelectionInfo {
        let mut selected = BTreeSet::new();
        for key in self.index.query(area) {
            if let Some(stroke) = self.strokes.get(&key) {
                let pts = stroke.world_points();
                let hits = pts.iter().filter(|p| inside(p.pos())).count();
                if !pts.is_empty() && hits as f32 >= SELECTION_COVERAGE * pts.len() as f32 {
                    selected.insert(key);
                }
            } else if let Some(note) = self.notes.get(&key) {
                if inside(note.rect().center()) {
                    selected.insert(key);
                }
            }
        }
        self.selection = selected;
        self.selection_info()
    }

    /// Box selection: strokes with at least half of their samples inside `rect`, notes
    /// whose centre lies inside.
    pub fn select_in_rect(&mut self, rect: ViewportRect) -> SelectionInfo {
        let rect = rect.normalized();
        self.select_where(&rect, |p| rect.contains(p))
    }

    /// Lasso selection with a free-form polygon.
    pub fn select_in_lasso(&mut self, polygon: &[Vec2]) -> SelectionInfo {
        let Some(area) = ViewportRect::from_points(polygon.iter().copied()) else {
            self.selection.clear();
            return SelectionInfo::default();
        };
        if polygon.len() < 3 {
            self.selection.clear();
            return SelectionInfo::default();
        }
        self.select_where(&area, |p| point_in_polygon(p, polygon))
    }

    /// Tap selection: topmost item within `tolerance` of `(x, y)`.
    pub fn select_at(&mut self, x: f32, y: f32, tolerance: f32) -> SelectionInfo {
        let p = Vec2::new(x, y);
        let mut best: Option<u64> = None;
        for key in self.index.query_point(p, tolerance.max(1.0)) {
            let hit = if let Some(stroke) = self.strokes.get(&key) {
                let pts: Vec<Vec2> = stroke.world_points().iter().map(|q| q.pos()).collect();
                distance_to_polyline(p, &pts, stroke.shape == ShapeKind::Rectangle)
                    <= tolerance + stroke.max_half_width()
            } else if let Some(note) = self.notes.get(&key) {
                note.rect().contains(p)
            } else {
                false
            };
            // Strokes are drawn above notes, so they win ties; otherwise newest wins.
            if hit {
                let better = match best {
                    None => true,
                    Some(b) => {
                        let (bs, ks) = (
                            self.strokes.contains_key(&b),
                            self.strokes.contains_key(&key),
                        );
                        (ks && !bs) || (ks == bs && key > b)
                    }
                };
                if better {
                    best = Some(key);
                }
            }
        }
        self.selection = best.into_iter().collect();
        self.selection_info()
    }

    /// Scales the selection about its bounding box's top-left corner by
    /// `(scale_x, scale_y)` and then translates it by `(dx, dy)`. The result never moves
    /// into negative coordinates and, on paged documents, stays on the page column; pages
    /// are appended if it is moved below the last one.
    pub fn transform_selection(
        &mut self,
        scale_x: f32,
        scale_y: f32,
        dx: f32,
        dy: f32,
    ) -> SceneDelta {
        let Some(bounds) = self.selection_info().bounds else {
            return self.finish_delta(SceneDelta::default());
        };
        let max_x = self.page_limit_x();
        let mut t =
            BoundsTransform::new(&bounds, scale_x, scale_y, dx, dy).clamped_to_positive(&bounds);
        if let Some(max_x) = max_x {
            t = t.clamped_to_width(&bounds, max_x);
        }
        if t.is_identity() {
            return self.finish_delta(SceneDelta::default());
        }
        let m = t.matrix();
        let mut delta = SceneDelta::default();
        let keys: Vec<u64> = self.selection.iter().copied().collect();
        for key in keys {
            if let Some(stroke) = self.strokes.get_mut(&key) {
                stroke.transform_matrix = stroke.transform_matrix.then(&m);
                let render = stroke.render();
                self.index.insert(key, render.bounds);
                delta.upserted_strokes.push(render);
            } else if let Some(note) = self.notes.get_mut(&key) {
                let r = t.apply_rect(&note.rect());
                note.x = r.left;
                note.y = r.top;
                note.width = r.width();
                note.height = r.height();
                note.font_size *= t.uniform_scale();
                *note = fit_note(note.clone(), max_x);
                self.index.insert(key, note.rect());
                delta.upserted_notes.push(note.clone());
            }
        }
        self.cover(t.apply_rect(&bounds).bottom);
        self.touch();
        self.finish_delta(delta)
    }

    fn selected_clip_items(&self) -> Vec<ClipItem> {
        self.selection
            .iter()
            .filter_map(|k| {
                if let Some(s) = self.strokes.get(k) {
                    Some(ClipItem::Stroke(s.clone()))
                } else {
                    self.notes.get(k).map(|n| ClipItem::Note(n.clone()))
                }
            })
            .collect()
    }

    fn clip_bounds(items: &[ClipItem]) -> ViewportRect {
        items
            .iter()
            .map(|item| match item {
                ClipItem::Stroke(s) => s.bounds(),
                ClipItem::Note(n) => n.rect(),
            })
            .reduce(|a, b| a.union(&b))
            .unwrap_or(ViewportRect::new(0.0, 0.0, 0.0, 0.0))
    }

    /// Inserts copies of `items` shifted by `(dx, dy)` (kept on the page) and selects them.
    fn insert_copies(&mut self, items: &[ClipItem], dx: f32, dy: f32) -> SceneDelta {
        let bounds = Self::clip_bounds(items);
        let (dx, dy) = self.clamp_offset(&bounds, dx, dy);
        let max_x = self.page_limit_x();
        let shift = TransformMatrix::translation(dx, dy);
        let mut delta = SceneDelta::default();
        let mut new_sel = BTreeSet::new();
        for item in items {
            let key = self.alloc_key();
            match item {
                ClipItem::Stroke(s) => {
                    let mut s = s.clone();
                    s.id = encode_id(ItemKind::Stroke, key);
                    s.transform_matrix = s.transform_matrix.then(&shift);
                    let render = s.render();
                    self.index.insert(key, render.bounds);
                    self.strokes.insert(key, s);
                    delta.upserted_strokes.push(render);
                }
                ClipItem::Note(n) => {
                    let mut n = n.clone();
                    n.id = encode_id(ItemKind::Note, key);
                    n.x += dx;
                    n.y += dy;
                    let n = fit_note(n, max_x);
                    self.index.insert(key, n.rect());
                    self.notes.insert(key, n.clone());
                    delta.upserted_notes.push(n);
                }
            }
            new_sel.insert(key);
        }
        self.selection = new_sel;
        self.cover(bounds.bottom + dy);
        self.touch();
        self.finish_delta(delta)
    }

    pub fn duplicate_selection(&mut self) -> SceneDelta {
        let items = self.selected_clip_items();
        if items.is_empty() {
            return self.finish_delta(SceneDelta::default());
        }
        self.insert_copies(&items, DUPLICATE_OFFSET, DUPLICATE_OFFSET)
    }

    /// Copies the selection to the internal clipboard; returns the number of items copied.
    pub fn copy_selection(&mut self) -> u32 {
        let items = self.selected_clip_items();
        if !items.is_empty() {
            self.clipboard = items;
            self.paste_count = 0;
        }
        self.clipboard.len() as u32
    }

    pub fn cut_selection(&mut self) -> SceneDelta {
        if self.copy_selection() == 0 || self.selection.is_empty() {
            return self.finish_delta(SceneDelta::default());
        }
        let ids: Vec<String> = self.selection_info().ids;
        self.delete_items(&ids)
    }

    pub fn delete_selection(&mut self) -> SceneDelta {
        let ids = self.selection_info().ids;
        self.delete_items(&ids)
    }

    pub fn has_clipboard(&self) -> bool {
        !self.clipboard.is_empty()
    }

    /// Pastes the clipboard centred on `(center_x, center_y)`. Repeated pastes at the same
    /// spot cascade slightly so copies don't stack invisibly.
    pub fn paste_clipboard(&mut self, center_x: f32, center_y: f32) -> SceneDelta {
        if self.clipboard.is_empty() {
            return self.finish_delta(SceneDelta::default());
        }
        let bounds = Self::clip_bounds(&self.clipboard);
        let cascade = (self.paste_count % 10) as f32 * 12.0;
        self.paste_count += 1;
        let c = bounds.center();
        let items = self.clipboard.clone();
        self.insert_copies(&items, center_x - c.x + cascade, center_y - c.y + cascade)
    }

    // ------------------------------------------------------------------ queries

    pub fn snapshot(&self) -> SceneSnapshot {
        SceneSnapshot {
            strokes: self.strokes.values().map(Stroke::render).collect(),
            notes: self.notes.values().cloned().collect(),
            selection: self.selection_info(),
        }
    }

    /// Combined bounds of every item, `None` for an empty document.
    pub fn content_bounds(&self) -> Option<ViewportRect> {
        self.strokes
            .keys()
            .chain(self.notes.keys())
            .filter_map(|k| self.index.bounds_of(*k))
            .reduce(|a, b| a.union(&b))
    }

    /// Z-ordered strokes (cloned) – used by the exporter outside the engine lock.
    pub fn strokes(&self) -> Vec<Stroke> {
        self.strokes.values().cloned().collect()
    }

    pub fn notes(&self) -> Vec<StickyNote> {
        self.notes.values().cloned().collect()
    }

    pub fn item_count(&self) -> usize {
        self.strokes.len() + self.notes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draw_line(engine: &mut Engine, x0: f32, y0: f32, x1: f32, y1: f32) -> StrokeRender {
        engine.begin_stroke(
            ToolType::Pen,
            Brush {
                color: 0xFF000000,
                width: 3.0,
                opacity: 1.0,
            },
        );
        for i in 0..=20 {
            let t = i as f32 / 20.0;
            engine.add_point(StrokePoint::new(
                x0 + (x1 - x0) * t,
                y0 + (y1 - y0) * t,
                0.5,
            ));
        }
        engine.finish_stroke(ToolType::Pen, true).expect("stroke")
    }

    fn notebook() -> Engine {
        Engine::with_kind(DocumentKind::Notebook, PaperStyle::Dictando)
    }

    #[test]
    fn draw_select_transform_duplicate_delete() {
        let mut e = Engine::new();
        let a = draw_line(&mut e, 10.0, 10.0, 100.0, 10.0);
        let b = draw_line(&mut e, 10.0, 300.0, 100.0, 300.0);
        assert_ne!(a.id, b.id);

        let sel = e.select_in_rect(ViewportRect::new(0.0, 0.0, 200.0, 50.0));
        assert_eq!(sel.ids, vec![a.id.clone()]);

        let delta = e.transform_selection(2.0, 2.0, 50.0, 50.0);
        assert_eq!(delta.upserted_strokes.len(), 1);
        let nb = delta.selection.bounds.unwrap();
        assert!(nb.left > 50.0 && nb.width() > 150.0);

        let dup = e.duplicate_selection();
        assert_eq!(dup.upserted_strokes.len(), 1);
        assert_eq!(e.item_count(), 3);
        assert_ne!(dup.selection.ids, sel.ids);

        let del = e.delete_selection();
        assert_eq!(del.removed_ids.len(), 1);
        assert_eq!(e.item_count(), 2);
        assert!(del.selection.ids.is_empty());
    }

    #[test]
    fn lasso_cut_and_paste() {
        let mut e = Engine::new();
        draw_line(&mut e, 50.0, 50.0, 80.0, 60.0);
        e.create_note(200.0, 200.0, 100.0, 100.0, 0xFFFFF59D, "hi".into());
        let lasso = [
            Vec2::new(0.0, 0.0),
            Vec2::new(400.0, 0.0),
            Vec2::new(400.0, 400.0),
            Vec2::new(0.0, 400.0),
        ];
        assert_eq!(e.select_in_lasso(&lasso).ids.len(), 2);
        let cut = e.cut_selection();
        assert_eq!(cut.removed_ids.len(), 2);
        assert_eq!(e.item_count(), 0);
        let pasted = e.paste_clipboard(500.0, 500.0);
        assert_eq!(
            pasted.upserted_strokes.len() + pasted.upserted_notes.len(),
            2
        );
        assert_eq!(e.item_count(), 2);
    }

    #[test]
    fn eraser_removes_touched_strokes_only() {
        let mut e = Engine::new();
        let a = draw_line(&mut e, 10.0, 10.0, 100.0, 10.0);
        draw_line(&mut e, 10.0, 200.0, 100.0, 200.0);
        let removed = e.erase_at(50.0, 12.0, 5.0);
        assert_eq!(removed, vec![a.id]);
        assert_eq!(e.item_count(), 1);
    }

    #[test]
    fn partial_eraser_splits_and_keeps_the_original_id() {
        let mut e = Engine::new();
        let a = draw_line(&mut e, 10.0, 100.0, 210.0, 100.0);
        let delta = e.erase_along(
            Vec2::new(110.0, 60.0),
            Vec2::new(110.0, 140.0),
            6.0,
            EraserMode::Partial,
        );
        assert!(delta.removed_ids.is_empty());
        assert_eq!(delta.upserted_strokes.len(), 2);
        assert_eq!(delta.upserted_strokes[0].id, a.id);
        assert_eq!(e.item_count(), 2);
        // The gap really is where the eraser passed.
        for r in &delta.upserted_strokes {
            assert!(
                r.bounds.right < 108.0 || r.bounds.left > 112.0,
                "{:?}",
                r.bounds
            );
        }
        // Erasing the remaining pieces completely removes them.
        let d = e.erase_along(
            Vec2::new(0.0, 100.0),
            Vec2::new(220.0, 100.0),
            10.0,
            EraserMode::Partial,
        );
        assert_eq!(d.removed_ids.len(), 2);
        assert_eq!(e.item_count(), 0);
    }

    #[test]
    fn partial_eraser_turns_a_rectangle_into_a_sharp_open_shape() {
        let mut e = Engine::new();
        e.begin_stroke(ToolType::Pen, Brush::default());
        for (x, y) in [
            (100.0, 100.0),
            (300.0, 100.0),
            (300.0, 220.0),
            (100.0, 220.0),
            (100.0, 100.0),
        ]
        .windows(2)
        .flat_map(|w| {
            (0..20).map(move |k| {
                let t = k as f32 / 20.0;
                (
                    w[0].0 + (w[1].0 - w[0].0) * t,
                    w[0].1 + (w[1].1 - w[0].1) * t,
                )
            })
        }) {
            e.add_point(StrokePoint::new(x, y, 0.5));
        }
        let rect = e.finish_stroke(ToolType::Pen, true).unwrap();
        assert_eq!(rect.kind, crate::geometry::RenderKind::ClosedPolygon);
        let d = e.erase_along(
            Vec2::new(300.0, 160.0),
            Vec2::new(300.0, 160.0),
            5.0,
            EraserMode::Partial,
        );
        assert_eq!(d.upserted_strokes.len(), 1);
        assert_eq!(
            d.upserted_strokes[0].kind,
            crate::geometry::RenderKind::OpenShape
        );
    }

    #[test]
    fn transform_never_goes_negative() {
        let mut e = Engine::new();
        draw_line(&mut e, 10.0, 10.0, 100.0, 10.0);
        e.select_in_rect(ViewportRect::new(0.0, 0.0, 200.0, 50.0));
        let d = e.transform_selection(1.0, 1.0, -500.0, -500.0);
        let b = d.selection.bounds.unwrap();
        assert!(b.left >= -0.01 && b.top >= -0.01, "{b:?}");
    }

    #[test]
    fn notes_are_hit_tested_and_updated() {
        let mut e = Engine::new();
        let n = e.create_note(100.0, 100.0, 150.0, 120.0, 0xFFFFF59D, String::new());
        assert_eq!(e.note_at(120.0, 120.0).map(|n| n.id), Some(n.id.clone()));
        let mut moved = n.clone();
        moved.x = 400.0;
        moved.text = "Salut ăîșț".into();
        e.update_note(moved).unwrap();
        assert!(e.note_at(120.0, 120.0).is_none());
        assert_eq!(e.note_at(410.0, 110.0).unwrap().text, "Salut ăîșț");
    }

    #[test]
    fn auto_correct_snaps_rectangle() {
        let mut e = Engine::new();
        e.begin_stroke(ToolType::Pen, Brush::default());
        let corners = [
            (100.0, 100.0),
            (300.0, 104.0),
            (297.0, 220.0),
            (102.0, 216.0),
            (101.0, 102.0),
        ];
        for w in corners.windows(2) {
            for k in 0..20 {
                let t = k as f32 / 20.0;
                let (x, y) = (
                    w[0].0 + (w[1].0 - w[0].0) * t,
                    w[0].1 + (w[1].1 - w[0].1) * t,
                );
                e.add_point(StrokePoint::new(x, y, 0.5));
            }
        }
        let r = e.finish_stroke(ToolType::Pen, true).unwrap();
        assert_eq!(r.kind, crate::geometry::RenderKind::ClosedPolygon);
        assert_eq!(r.geometry.len(), 8);
    }

    #[test]
    fn notebook_strokes_stay_on_the_page_column() {
        let mut e = notebook();
        let r = draw_line(&mut e, 900.0, 50.0, 1400.0, 50.0);
        assert!(r.bounds.right <= PAGE_WIDTH + 5.0, "{:?}", r.bounds);
        let n = e.create_note(950.0, 10.0, 200.0, 100.0, 0xFFFFF59D, String::new());
        assert_eq!(n.x + n.width, PAGE_WIDTH);
        e.select_in_rect(ViewportRect::new(0.0, 0.0, 1000.0, 200.0));
        let d = e.transform_selection(1.0, 1.0, 400.0, 0.0);
        assert!(d.selection.bounds.unwrap().right <= PAGE_WIDTH + 5.0);
    }

    #[test]
    fn drawing_past_the_last_page_appends_pages() {
        let mut e = notebook();
        assert_eq!(e.page_count(), 1);
        draw_line(&mut e, 100.0, 900.0, 100.0, 1500.0);
        assert_eq!(e.page_count(), 2);
        // Input is clamped to at most one page below the end.
        draw_line(&mut e, 200.0, 1800.0, 200.0, 99_999.0);
        assert_eq!(e.page_count(), 3);
        assert!(e.append_page().is_some());
        assert_eq!(e.info().pages.len(), 4);
        // Whiteboards have no pages.
        assert!(Engine::new().append_page().is_none());
    }

    #[test]
    fn scrolling_or_writing_near_the_bottom_appends_the_next_page() {
        let mut e = notebook();
        // Visible bottom still 60 units above the end of page 1: nothing happens.
        assert!(e.append_page_if_near_end(940.0, 50.0).is_none());
        let p = e.append_page_if_near_end(955.0, 50.0).expect("page 2");
        assert_eq!((p.index, p.top, p.height), (1, 1000.0, 1000.0));
        // One page per call, even when far past the end.
        assert!(e.append_page_if_near_end(99_999.0, 50.0).is_some());
        assert_eq!(e.page_count(), 3);
        assert!(Engine::new().append_page_if_near_end(0.0, 50.0).is_none());
    }

    #[test]
    fn blank_pages_created_by_scrolling_are_trimmed() {
        let mut e = notebook();
        for _ in 0..5 {
            e.append_page();
        }
        draw_line(&mut e, 100.0, 1100.0, 300.0, 1150.0); // writes on page 2
        let r = e.revision();
        assert_eq!(e.trim_trailing_blank_pages(), 4);
        assert_eq!(e.page_count(), 2);
        assert_ne!(e.revision(), r, "trimming is a document change (saved)");
        assert_eq!(e.trim_trailing_blank_pages(), 0);
        // Sticky notes keep their page too.
        let mut n = notebook();
        n.append_page();
        n.append_page();
        n.create_note(50.0, 1500.0, 200.0, 150.0, 0xFFFFF59D, String::new());
        assert_eq!(n.trim_trailing_blank_pages(), 1);
        assert_eq!(n.page_count(), 2);
    }

    #[test]
    fn moving_a_selection_below_the_last_page_appends_one() {
        let mut e = notebook();
        draw_line(&mut e, 100.0, 100.0, 300.0, 100.0);
        e.select_in_rect(ViewportRect::new(0.0, 0.0, 1000.0, 1000.0));
        let d = e.transform_selection(1.0, 1.0, 0.0, 1200.0);
        assert_eq!(d.page_count, 2);
    }

    #[test]
    fn revision_tracks_changes() {
        let mut e = notebook();
        let r0 = e.revision();
        draw_line(&mut e, 10.0, 10.0, 50.0, 10.0);
        assert!(e.revision() != r0);
        let r1 = e.revision();
        e.select_in_rect(ViewportRect::new(0.0, 0.0, 100.0, 100.0));
        assert_eq!(e.revision(), r1, "selection is not a document change");
    }

    #[test]
    fn save_and_reload_round_trip() {
        let mut e = notebook();
        draw_line(&mut e, 10.0, 10.0, 200.0, 40.0);
        e.create_note(100.0, 300.0, 160.0, 120.0, 0xFFFFF59D, "Notă".into());
        e.append_page();
        let bytes = storage::encode(&e.data()).unwrap();
        let back = Engine::from_data(storage::decode(&bytes).unwrap(), None);
        assert_eq!(back.kind(), DocumentKind::Notebook);
        assert_eq!(back.paper(), PaperStyle::Dictando);
        assert_eq!(back.page_count(), 2);
        assert_eq!(back.item_count(), 2);
        assert_eq!(back.snapshot().notes[0].text, "Notă");
    }

    #[test]
    fn pdf_documents_get_one_page_per_pdf_page() {
        let pdf = ImportedPdf::parse(pdf_importer::tests::sample_pdf()).unwrap();
        let e = Engine::with_pdf(pdf);
        let info = e.info();
        assert_eq!(info.kind, DocumentKind::PdfAnnotation);
        assert_eq!(info.pdf_page_count, 2);
        assert_eq!(info.pages[1].pdf_page, Some(1));
        // Reloading without the PDF degrades the backgrounds to blank pages.
        let back = Engine::from_data(e.data(), None);
        assert!(back.pages().iter().all(|p| p.pdf_page.is_none()));
    }
}

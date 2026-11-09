//! Thread-safe FFI endpoints exposed to Flutter through `flutter_rust_bridge`.
//!
//! Interactive calls are `#[frb(sync)]`: they are tiny, run on the UI isolate and return
//! immediately (no async hop while the pen is moving). Heavy work (PDF import / export,
//! saving and loading) is async and runs on frb's worker pool; it snapshots the document
//! under the lock and does the slow part without holding it, so drawing never stalls.

use crate::document::{
    storage, CanvasPage, DocumentInfo, DocumentKind, Engine, EraserMode, ImportedPdf, PaperSpec,
    PaperStyle, SceneDelta, SceneSnapshot, SelectionInfo,
};
use crate::export::{self, ExportDocument, PdfExportReport};
use crate::geometry::{
    detect_and_snap_rectangle, Brush, StickyNote, StrokePoint, StrokeRender, ToolType, Vec2,
    ViewportRect,
};
use anyhow::Context;
use flutter_rust_bridge::frb;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

static ENGINE: LazyLock<Mutex<Engine>> = LazyLock::new(|| Mutex::new(Engine::new()));
static EXPORT_FONT: LazyLock<Mutex<Option<Arc<Vec<u8>>>>> = LazyLock::new(|| Mutex::new(None));

/// Locks the engine, recovering from a poisoned mutex (a panic in one call must not
/// brick the whole canvas).
fn engine() -> MutexGuard<'static, Engine> {
    ENGINE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Result of [`save_document`].
#[derive(Debug, Clone, PartialEq)]
pub struct SaveReport {
    pub path: String,
    pub byte_size: u32,
    /// Document revision that was written (edits made during the save stay unsaved).
    pub revision: u32,
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// ============================================================================ document

/// Replaces the open document with an empty one of `kind` (notebooks start with a single
/// 1000 × 1000 page; whiteboards are unbounded).
#[frb(sync)]
pub fn new_document(kind: DocumentKind, paper: PaperStyle) -> DocumentInfo {
    let mut e = engine();
    *e = Engine::with_kind(kind, paper);
    e.info()
}

/// Opens the PDF at `path` as a new annotation document: one page per PDF page, each
/// 1000 units wide with the PDF page's aspect ratio.
pub fn import_pdf(path: String) -> anyhow::Result<DocumentInfo> {
    let pdf = ImportedPdf::read(&path)?;
    let mut e = engine();
    *e = Engine::with_pdf(pdf);
    Ok(e.info())
}

/// Loads a document saved by [`save_document`]. `pdf_path` is the document's imported
/// PDF (page backgrounds), if it has one.
pub fn load_document(path: String, pdf_path: Option<String>) -> anyhow::Result<DocumentInfo> {
    let bytes = std::fs::read(&path).with_context(|| format!("reading {path}"))?;
    let data = storage::decode(&bytes)?;
    let pdf = match pdf_path {
        Some(p) if data.kind == DocumentKind::PdfAnnotation => Some(ImportedPdf::read(&p)?),
        _ => None,
    };
    let loaded = Engine::from_data(data, pdf);
    let mut e = engine();
    *e = loaded;
    Ok(e.info())
}

/// Saves the open document to `path` (atomically: temp file + rename).
pub fn save_document(path: String) -> anyhow::Result<SaveReport> {
    let (data, revision) = {
        let e = engine();
        (e.data(), e.revision())
    };
    let bytes = storage::encode(&data)?;
    storage::write_atomic(&path, &bytes)?;
    Ok(SaveReport {
        path,
        byte_size: bytes.len().min(u32::MAX as usize) as u32,
        revision,
    })
}

/// Kind, paper, page stack and revision of the open document.
#[frb(sync)]
pub fn document_info() -> DocumentInfo {
    engine().info()
}

/// Revision counter (changes on every edit; selection changes do not count).
#[frb(sync)]
pub fn document_revision() -> u32 {
    engine().revision()
}

/// Number of pages (`0` for whiteboards). Cheap: call it after edits that may append pages.
#[frb(sync)]
pub fn page_count() -> u32 {
    engine().page_count()
}

#[frb(sync)]
pub fn document_pages() -> Vec<CanvasPage> {
    engine().pages().to_vec()
}

/// Continuous scroll: appends a blank 1000 × 1000 page below the last one.
#[frb(sync)]
pub fn append_page() -> Option<CanvasPage> {
    engine().append_page()
}

/// Changes the paper pattern of the open document.
#[frb(sync)]
pub fn set_paper_style(style: PaperStyle) -> DocumentInfo {
    let mut e = engine();
    e.set_paper(style);
    e.info()
}

/// Removes all strokes and notes, keeping the document type, pages and imported PDF.
#[frb(sync)]
pub fn reset_document() {
    engine().clear_content();
}

/// Full z-ordered scene (initial load / resync).
#[frb(sync)]
pub fn get_scene() -> SceneSnapshot {
    engine().snapshot()
}

/// Bounding box of all content, `None` when the document is empty.
#[frb(sync)]
pub fn content_bounds() -> Option<ViewportRect> {
    engine().content_bounds()
}

/// Paper geometry shared by the Flutter background painter and the PDF exporter.
#[frb(sync)]
pub fn paper_spec(style: PaperStyle) -> PaperSpec {
    style.spec()
}

// ============================================================================ drawing

/// Starts a new stroke with the given tool and brush (discarding any unfinished one).
#[frb(sync)]
pub fn begin_stroke(tool: ToolType, brush: Brush) {
    engine().begin_stroke(tool, brush);
}

/// Appends one input sample to the stroke in progress.
#[frb(sync)]
pub fn add_point(point: StrokePoint) {
    engine().add_point(point);
}

/// Appends a batch of samples (coalesced / high-frequency stylus events).
#[frb(sync)]
pub fn add_points(points: Vec<StrokePoint>) {
    let mut e = engine();
    for p in points {
        e.add_point(p);
    }
}

/// Tessellated preview of the stroke in progress, identical to what `finish_stroke`
/// will commit (minus shape auto-correction).
#[frb(sync)]
pub fn current_stroke_preview() -> Option<StrokeRender> {
    engine().preview()
}

/// Commits the stroke in progress. With `auto_correct`, rectangle-like loops are
/// replaced by a perfect rectangle immediately. Returns the committed render (or `None`).
/// May append pages when the stroke reaches below the last page (see [`page_count`]).
#[frb(sync)]
pub fn finish_stroke(tool: ToolType, auto_correct: bool) -> Option<StrokeRender> {
    engine().finish_stroke(tool, auto_correct)
}

#[frb(sync)]
pub fn cancel_stroke() {
    engine().cancel_stroke();
}

/// Stroke eraser at a point: removes strokes touched by the circle; returns their ids.
#[frb(sync)]
pub fn erase_at(x: f32, y: f32, radius: f32) -> Vec<String> {
    engine().erase_at(x, y, radius)
}

/// Erases along the eraser's movement from `(x0, y0)` to `(x1, y1)`.
/// [`EraserMode::Stroke`] deletes whole strokes, [`EraserMode::Partial`] cuts them.
#[frb(sync)]
pub fn erase_along(
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    radius: f32,
    mode: EraserMode,
) -> SceneDelta {
    engine().erase_along(Vec2::new(x0, y0), Vec2::new(x1, y1), radius, mode)
}

/// Stateless access to the rectangle recogniser (handy for tests and tooling).
#[frb(sync)]
pub fn detect_rectangle(points: Vec<StrokePoint>) -> Option<Vec<StrokePoint>> {
    detect_and_snap_rectangle(&points)
}

// ============================================================================ selection

/// Box selection. Returns the selected ids.
#[frb(sync)]
pub fn select_in_region(rect: ViewportRect) -> Vec<String> {
    engine().select_in_rect(rect).ids
}

/// Lasso selection with a flattened polygon `[x0, y0, x1, y1, ...]`.
#[frb(sync)]
pub fn select_in_lasso(polygon: Vec<f32>) -> Vec<String> {
    let pts: Vec<Vec2> = crate::spatial::hit_test::unflatten(&polygon);
    engine().select_in_lasso(&pts).ids
}

/// Tap selection of the topmost item near `(x, y)`.
#[frb(sync)]
pub fn select_at(x: f32, y: f32, tolerance: f32) -> Vec<String> {
    engine().select_at(x, y, tolerance).ids
}

#[frb(sync)]
pub fn set_selection(ids: Vec<String>) -> SelectionInfo {
    engine().set_selection(&ids)
}

#[frb(sync)]
pub fn get_selection() -> SelectionInfo {
    engine().selection_info()
}

#[frb(sync)]
pub fn clear_selection() {
    engine().clear_selection();
}

/// Scales the selection about its bounding box's top-left corner, then translates it.
/// The result is clamped so nothing moves into negative coordinates (or off the page).
#[frb(sync)]
pub fn transform_selection(scale_x: f32, scale_y: f32, dx: f32, dy: f32) -> SceneDelta {
    engine().transform_selection(scale_x, scale_y, dx, dy)
}

/// Clones the selection with an offset and selects the clones.
#[frb(sync)]
pub fn duplicate_selection() -> SceneDelta {
    engine().duplicate_selection()
}

/// Copies the selection to the internal clipboard; returns the number of items.
#[frb(sync)]
pub fn copy_selection() -> u32 {
    engine().copy_selection()
}

/// Copies the selection to the clipboard and removes it from the canvas.
#[frb(sync)]
pub fn cut_selection() -> SceneDelta {
    engine().cut_selection()
}

/// Pastes the clipboard centred on `(center_x, center_y)` and selects the result.
#[frb(sync)]
pub fn paste_clipboard(center_x: f32, center_y: f32) -> SceneDelta {
    engine().paste_clipboard(center_x, center_y)
}

#[frb(sync)]
pub fn has_clipboard() -> bool {
    engine().has_clipboard()
}

/// Removes the selected items from the QuadTree and the canvas.
#[frb(sync)]
pub fn delete_selection() -> SceneDelta {
    engine().delete_selection()
}

#[frb(sync)]
pub fn delete_items(ids: Vec<String>) -> SceneDelta {
    engine().delete_items(&ids)
}

// ============================================================================ sticky notes

#[frb(sync)]
pub fn create_sticky_note(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: u32,
    text: String,
) -> StickyNote {
    engine().create_note(x, y, width, height, color, text)
}

/// Moves / resizes / re-colours / edits a note. Returns the sanitised note, or `None`
/// if the id is unknown.
#[frb(sync)]
pub fn update_sticky_note(note: StickyNote) -> Option<StickyNote> {
    engine().update_note(note)
}

/// Topmost sticky note containing `(x, y)`.
#[frb(sync)]
pub fn sticky_note_at(x: f32, y: f32) -> Option<StickyNote> {
    engine().note_at(x, y)
}

// ============================================================================ export

/// Registers a TrueType font used for sticky-note text in PDFs (full Unicode, embedded).
/// Returns `false` if the bytes are not a parsable font.
#[frb(sync)]
pub fn set_export_font(font_bytes: Vec<u8>) -> bool {
    if ttf_parser::Face::parse(&font_bytes, 0).is_err() {
        return false;
    }
    *EXPORT_FONT.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(font_bytes));
    true
}

struct ExportSnapshot {
    data: crate::document::DocumentData,
    pdf: Option<Arc<Vec<u8>>>,
    font: Option<Arc<Vec<u8>>>,
}

impl ExportSnapshot {
    fn take() -> Self {
        let (data, pdf) = {
            let e = engine();
            (e.data(), e.pdf().map(|p| p.bytes.clone()))
        };
        let font = EXPORT_FONT
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        Self { data, pdf, font }
    }

    fn document(&self) -> ExportDocument<'_> {
        ExportDocument {
            kind: self.data.kind,
            paper: self.data.paper,
            pages: &self.data.pages,
            strokes: &self.data.strokes,
            notes: &self.data.notes,
            pdf: self.pdf.as_deref().map(Vec::as_slice),
        }
    }
}

/// Writes the whole document as a vector PDF to `path`: one PDF page per page (imported
/// PDF pages are re-embedded underneath the annotations, as vectors).
pub fn export_to_pdf(path: String) -> anyhow::Result<PdfExportReport> {
    let snap = ExportSnapshot::take();
    export::export_document(
        &path,
        &snap.document(),
        snap.font.as_deref().map(Vec::as_slice),
    )
}

/// Renders the document as PDF bytes (for share sheets / save dialogs).
pub fn export_to_pdf_bytes() -> anyhow::Result<Vec<u8>> {
    let snap = ExportSnapshot::take();
    export::render_document(&snap.document(), snap.font.as_deref().map(Vec::as_slice))
        .map(|(bytes, _)| bytes)
}

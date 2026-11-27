//! Thread-safe FFI endpoints exposed to Flutter through `flutter_rust_bridge`.
//!
//! Interactive calls are `#[frb(sync)]`: they are tiny, run on the UI isolate and return
//! immediately (no async hop while the pen is moving). Heavy work (PDF import / export,
//! saving and loading) is async and runs on frb's worker pool; it snapshots the document
//! under the lock and does the slow part without holding it, so drawing never stalls.
//!
//! Several documents can be open at once (editor tabs, see [`Workspace`]). The editing
//! calls work on the *active* one, chosen with [`activate_document`]. The async calls run
//! later on a worker thread, when another tab may be active, so they name their document's
//! slot explicitly.

use crate::document::{
    storage, CanvasPage, DocumentInfo, DocumentKind, Engine, EraserMode, ImportedPdf, PaperSpec,
    PaperStyle, SceneDelta, SceneSnapshot, SelectionInfo, Workspace,
};
use crate::export::{self, ExportDocument, PdfExportReport};
use crate::geometry::{
    Brush, DetectedShape, StickyNote, StrokePoint, StrokeRender, ToolType, Vec2, ViewportRect,
};
use anyhow::Context;
use flutter_rust_bridge::frb;
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

static WORKSPACE: LazyLock<Mutex<Workspace>> = LazyLock::new(|| Mutex::new(Workspace::new()));
static EXPORT_FONT: LazyLock<Mutex<Option<Arc<Vec<u8>>>>> = LazyLock::new(|| Mutex::new(None));

/// Locks the open documents, recovering from a poisoned mutex (a panic in one call must
/// not brick the whole canvas).
fn workspace() -> MutexGuard<'static, Workspace> {
    WORKSPACE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The locked active document.
struct ActiveEngine(MutexGuard<'static, Workspace>);

impl Deref for ActiveEngine {
    type Target = Engine;

    fn deref(&self) -> &Engine {
        self.0.active()
    }
}

impl DerefMut for ActiveEngine {
    fn deref_mut(&mut self) -> &mut Engine {
        self.0.active_mut()
    }
}

fn engine() -> ActiveEngine {
    ActiveEngine(workspace())
}

/// Runs `f` on the document of `slot` (active or parked) under the lock.
fn with_document<R>(slot: u32, f: impl FnOnce(&Engine) -> R) -> anyhow::Result<R> {
    let ws = workspace();
    let doc = ws
        .get(slot)
        .with_context(|| format!("document {slot} is not open"))?;
    Ok(f(doc))
}

/// Puts a freshly created / loaded document into `slot`.
fn install(slot: u32, doc: Engine) -> DocumentInfo {
    let info = doc.info();
    workspace().install(slot, doc);
    info
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

// ============================================================================ open documents

/// Makes the document of `slot` the one every editing call works on (switching tabs).
/// Parked documents keep their history, selection and unfinished stroke; the clipboard
/// moves along. Returns `false` (nothing changes) when no document is open in `slot`.
/// Slot `0` is the scratch document and always exists.
#[frb(sync)]
pub fn activate_document(slot: u32) -> bool {
    workspace().activate(slot)
}

/// Slot of the active document.
#[frb(sync)]
pub fn active_document() -> u32 {
    workspace().active_slot()
}

/// Frees the document of `slot` (tab closed). If it was active, the scratch document
/// takes over.
#[frb(sync)]
pub fn close_document(slot: u32) {
    workspace().close(slot);
}

/// Slots of the documents open in tabs (the scratch document is not listed).
#[frb(sync)]
pub fn open_documents() -> Vec<u32> {
    workspace().slots()
}

// ============================================================================ document

/// Puts an empty document of `kind` into `slot` (notebooks start with a single
/// 1000 × 1000 page; whiteboards are unbounded).
#[frb(sync)]
pub fn new_document(slot: u32, kind: DocumentKind, paper: PaperStyle) -> DocumentInfo {
    install(slot, Engine::with_kind(kind, paper))
}

/// Opens the PDF at `path` as a new annotation document in `slot`: one page per PDF
/// page, each 1000 units wide with the PDF page's aspect ratio.
pub fn import_pdf(slot: u32, path: String) -> anyhow::Result<DocumentInfo> {
    let pdf = ImportedPdf::read(&path)?;
    Ok(install(slot, Engine::with_pdf(pdf)))
}

/// Loads a document saved by [`save_document`] into `slot`. `pdf_path` is the document's
/// imported PDF (page backgrounds), if it has one.
pub fn load_document(
    slot: u32,
    path: String,
    pdf_path: Option<String>,
) -> anyhow::Result<DocumentInfo> {
    let bytes = std::fs::read(&path).with_context(|| format!("reading {path}"))?;
    let data = storage::decode(&bytes)?;
    let pdf = match pdf_path {
        Some(p) if data.kind == DocumentKind::PdfAnnotation => Some(ImportedPdf::read(&p)?),
        _ => None,
    };
    Ok(install(slot, Engine::from_data(data, pdf)))
}

/// Saves the document of `slot` to `path` (atomically: temp file + rename).
pub fn save_document(slot: u32, path: String) -> anyhow::Result<SaveReport> {
    let (data, revision) = with_document(slot, |e| (e.data(), e.revision()))?;
    let bytes = storage::encode(&data)?;
    storage::write_atomic(&path, &bytes)?;
    Ok(SaveReport {
        path,
        byte_size: bytes.len().min(u32::MAX as usize) as u32,
        revision,
    })
}

/// Kind, paper, page stack and revision of the active document.
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

/// Continuous scroll / writing: appends the next page when `y` (bottom of the visible
/// area, or the pen position) is within `margin` units of the bottom of the last page.
/// At most one page per call; `None` if not near the end (or whiteboard / page limit).
#[frb(sync)]
pub fn append_page_if_near_end(y: f32, margin: f32) -> Option<CanvasPage> {
    engine().append_page_if_near_end(y, margin)
}

/// Drops trailing pages nobody wrote on (created by scrolling). Call before the final
/// save; returns how many pages were removed.
#[frb(sync)]
pub fn trim_trailing_blank_pages() -> u32 {
    engine().trim_trailing_blank_pages()
}

/// Upper bound on the number of pages of a document.
#[frb(sync)]
pub fn max_page_count() -> u32 {
    crate::document::page::MAX_PAGES
}

/// Changes the paper pattern of the active document.
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

/// Whiteboards: the part of the canvas each exported PDF page shows (world units, in
/// page order), for the "Show page guides" lines. Empty for notebooks and PDFs.
#[frb(sync)]
pub fn whiteboard_page_guides() -> Vec<ViewportRect> {
    engine().whiteboard_export_pages()
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

/// Commits the stroke in progress. With `auto_correct`, strokes that look like a line,
/// circle / ellipse, triangle, rectangle / square, trapezoid, 5–8-gon or five-pointed
/// star are replaced by clean geometry immediately. Returns the committed render (or
/// `None`). May append pages when the stroke reaches below the last page (see
/// [`page_count`]). One undo step.
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

/// Stateless access to the shape recogniser (handy for tests and tooling): the shape the
/// samples would snap to on pen-up, or `None` for freehand ink.
#[frb(sync)]
pub fn detect_shape(points: Vec<StrokePoint>) -> Option<DetectedShape> {
    crate::geometry::detect_shape(&points)
}

// ============================================================================ history

/// Reverts the most recent edit (stroke, erase, transform, duplicate / cut / paste /
/// delete, sticky-note change, clear). Returns the scene change to apply, or `None` when
/// there is nothing to undo. Restored items keep their ids and z-order.
#[frb(sync)]
pub fn undo() -> Option<SceneDelta> {
    engine().undo()
}

/// Re-applies the most recently undone edit; `None` when there is nothing to redo.
#[frb(sync)]
pub fn redo() -> Option<SceneDelta> {
    engine().redo()
}

#[frb(sync)]
pub fn can_undo() -> bool {
    engine().can_undo()
}

#[frb(sync)]
pub fn can_redo() -> bool {
    engine().can_redo()
}

/// Merges all following edits into one undo step until [`end_history_group`]: call it
/// at the start of a gesture made of many calls (an eraser drag, creating and editing a
/// sticky note). Undo / redo close an open group.
#[frb(sync)]
pub fn begin_history_group() {
    engine().begin_history_group();
}

#[frb(sync)]
pub fn end_history_group() {
    engine().end_history_group();
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

/// Gives the selected strokes and shapes the ARGB `color` (sticky notes keep theirs).
/// One undo step.
#[frb(sync)]
pub fn recolor_selection(color: u32) -> SceneDelta {
    engine().recolor_selection(color)
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
    fn take(slot: u32) -> anyhow::Result<Self> {
        let (data, pdf) = with_document(slot, |e| (e.data(), e.pdf().map(|p| p.bytes.clone())))?;
        let font = EXPORT_FONT
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        Ok(Self { data, pdf, font })
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

/// Writes the whole document of `slot` as a vector PDF to `path`: one PDF page per page
/// (imported PDF pages are re-embedded underneath the annotations, as vectors).
pub fn export_to_pdf(slot: u32, path: String) -> anyhow::Result<PdfExportReport> {
    let snap = ExportSnapshot::take(slot)?;
    export::export_document(
        &path,
        &snap.document(),
        snap.font.as_deref().map(Vec::as_slice),
    )
}

/// Renders the document of `slot` as PDF bytes (for share sheets / save dialogs).
pub fn export_to_pdf_bytes(slot: u32) -> anyhow::Result<Vec<u8>> {
    let snap = ExportSnapshot::take(slot)?;
    export::render_document(&snap.document(), snap.font.as_deref().map(Vec::as_slice))
        .map(|(bytes, _)| bytes)
}

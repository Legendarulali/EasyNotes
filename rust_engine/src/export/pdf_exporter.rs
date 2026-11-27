//! Vector PDF export (`pdf-writer`).
//!
//! Everything is emitted as true vector content: paper grids as line paths, ink as the
//! very same tessellated outlines Flutter renders, highlighters with a Multiply blend
//! ExtGState, sticky notes as filled rectangles with real (selectable) text.
//!
//! Page layout:
//! - **Paged documents** (notebooks, imported PDFs): one PDF page per document page.
//!   Notebook pages (1000 × 1000 units) become 750 × 750 pt (1 unit = 0.75 pt, so the 5 mm
//!   grid stays 5 mm on paper). PDF-backed pages get the source page's exact size, with
//!   the source page re-embedded underneath as a vector Form XObject.
//!   Blank pages at the end (appended while scrolling or writing) are not exported.
//! - **Whiteboards** become A4 portrait pages stacked downwards: the content is scaled
//!   to fit the page width and page breaks move into the gaps between lines of writing
//!   ([`smart_page_breaks`]).
//!
//! Text: if a TrueType font was registered (see `set_export_font`) it is embedded as a
//! CID font with a ToUnicode map, so Romanian diacritics (ă â î ș ț) survive. Otherwise
//! the built-in Helvetica is used with a WinAnsi transliteration fallback.

use super::pdf_embed::{PdfEmbedder, RefAlloc};
use crate::document::page::without_trailing_blank;
use crate::document::{
    CanvasPage, DocumentKind, PaperKind, PaperSpec, PaperStyle, PAGE_COVER_TOLERANCE,
};
use crate::geometry::{RenderKind, StickyNote, Stroke, StrokeRender, ToolType, ViewportRect};
use anyhow::{Context, Result};
use miniz_oxide::deflate::compress_to_vec_zlib;
use pdf_writer::types::{
    CidFontType, FontFlags, LineCapStyle, LineJoinStyle, SystemInfo, UnicodeCmap,
};
use pdf_writer::{Content, Filter, Finish, Name, Pdf, Rect, Ref, Str, TextStr};
use std::collections::{BTreeMap, HashMap};

pub const PT_PER_UNIT: f32 = 0.75;
const A4_WIDTH_PT: f32 = 595.28;
const A4_HEIGHT_PT: f32 = 841.89;
/// Whiteboard pages: blank border around the content on every side.
pub const WHITEBOARD_MARGIN_PT: f32 = 24.0;
/// Room left above the line of writing a smart page break moves to the next page.
const BREAK_PADDING_PT: f32 = 10.0;
/// A smart page break may give up at most this share of a page's usable height;
/// otherwise the page is cut where it is full.
pub const MAX_BREAK_SHIFT: f32 = 0.35;
const MAX_WHITEBOARD_PAGES: usize = 10_000;
/// Acrobat's implementation limit for page dimensions.
const MAX_PAGE_PT: f32 = 14_400.0;
const NOTE_PADDING: f32 = 10.0;
const NOTE_LINE_HEIGHT: f32 = 1.3;
const NOTE_TEXT_COLOR: u32 = 0xFF212121;
const BACKGROUND_FORM: &[u8] = b"Bg";

/// Summary returned to the UI after a successful export.
#[derive(Debug, Clone, PartialEq)]
pub struct PdfExportReport {
    pub path: String,
    pub page_count: u32,
    /// Size of the first page.
    pub page_width_pt: f32,
    pub page_height_pt: f32,
    pub byte_size: u32,
}

/// Everything the exporter needs, snapshotted out of the engine.
#[derive(Debug, Clone, Copy)]
pub struct ExportDocument<'a> {
    pub kind: DocumentKind,
    pub paper: PaperStyle,
    pub pages: &'a [CanvasPage],
    pub strokes: &'a [Stroke],
    pub notes: &'a [StickyNote],
    /// Original bytes of the imported PDF (page backgrounds), if any.
    pub pdf: Option<&'a [u8]>,
}

/// One page of the output file.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OutputPage {
    /// Region of the canvas shown on this page (world units).
    pub area: ViewportRect,
    /// Points per world unit.
    pub scale: f32,
    /// World Y at which the paper pattern starts (page top for paged documents).
    pub pattern_origin: f32,
    /// Source PDF page drawn underneath.
    pub pdf_page: Option<u32>,
    /// Part of `area` whose ink and notes belong on this page (whiteboards: the slice
    /// between two page breaks; the margins show only paper). `None`: all of `area`.
    pub content: Option<ViewportRect>,
}

impl OutputPage {
    pub fn size_pt(&self) -> (f32, f32) {
        (
            self.area.width() * self.scale,
            self.area.height() * self.scale,
        )
    }
}

/// Decides the output pages. `pdf_width` returns a source page's displayed width (pt).
///
/// Paged documents get one PDF page per page, except blank pages at the end (added
/// automatically while scrolling or writing): those are left out. Blank pages between
/// written ones stay, and an empty document still exports its first page.
pub fn layout_pages(
    doc: &ExportDocument,
    renders: &[StrokeRender],
    pdf_width: impl Fn(u32) -> Option<f32>,
) -> Vec<OutputPage> {
    let items: Vec<ViewportRect> = renders
        .iter()
        .map(|r| r.bounds)
        .chain(doc.notes.iter().map(StickyNote::rect))
        .collect();
    if !doc.kind.is_paged() || doc.pages.is_empty() {
        return whiteboard_pages(&items);
    }
    // Same tolerance as the editor's page trimming: a stroke's edge grazing the next page
    // does not keep that page.
    let bottom = items
        .iter()
        .map(|r| r.bottom)
        .filter(|b| b.is_finite())
        .reduce(f32::max)
        .map_or(0.0, |b| b - PAGE_COVER_TOLERANCE);
    let kept = without_trailing_blank(doc.pages, bottom, 1);
    let mut last_scale = PT_PER_UNIT;
    doc.pages[..kept]
        .iter()
        .map(|p| {
            let pdf = p.pdf_page.and_then(|i| pdf_width(i).map(|w| (i, w)));
            let mut scale = match pdf {
                Some((_, w)) if p.width > 0.0 => w / p.width,
                _ => last_scale,
            };
            scale = scale.min(MAX_PAGE_PT / p.width.max(p.height).max(1.0));
            last_scale = scale;
            OutputPage {
                area: p.rect(),
                scale,
                pattern_origin: p.top,
                pdf_page: pdf.map(|(i, _)| i),
                content: None,
            }
        })
        .collect()
}

/// Pages of a whiteboard whose items (strokes, notes) have the bounds `items`.
///
/// A4 portrait pages, stacked downwards. The content is cropped to its bounding box and
/// scaled so its full width fits between the side margins (never enlarged beyond the
/// notebook scale), so the board is never sliced into columns. Page breaks avoid cutting
/// through handwriting, see [`smart_page_breaks`]. An empty board gives one blank page.
pub fn whiteboard_pages(items: &[ViewportRect]) -> Vec<OutputPage> {
    let finite: Vec<ViewportRect> = items
        .iter()
        .copied()
        .filter(|r| {
            [r.left, r.top, r.right, r.bottom]
                .iter()
                .all(|v| v.is_finite())
        })
        .collect();
    let Some(content) = finite.iter().copied().reduce(|a, b| a.union(&b)) else {
        return vec![OutputPage {
            area: ViewportRect::new(
                0.0,
                0.0,
                A4_WIDTH_PT / PT_PER_UNIT,
                A4_HEIGHT_PT / PT_PER_UNIT,
            ),
            scale: PT_PER_UNIT,
            pattern_origin: 0.0,
            pdf_page: None,
            content: None,
        }];
    };
    let usable_width_pt = A4_WIDTH_PT - 2.0 * WHITEBOARD_MARGIN_PT;
    let scale = if content.width() > 0.0 {
        PT_PER_UNIT.min(usable_width_pt / content.width())
    } else {
        PT_PER_UNIT
    };
    let margin = WHITEBOARD_MARGIN_PT / scale;
    let (page_width, page_height) = (A4_WIDTH_PT / scale, A4_HEIGHT_PT / scale);
    let left = content.left - margin;
    let spans: Vec<(f32, f32)> = finite.iter().map(|r| (r.top, r.bottom)).collect();
    let slices = smart_page_breaks(
        &spans,
        content.top,
        content.bottom,
        page_height - 2.0 * margin,
        BREAK_PADDING_PT / scale,
    );
    let last = slices.len().saturating_sub(1);
    slices
        .iter()
        .enumerate()
        .map(|(i, &(top, bottom))| {
            let area = ViewportRect::new(
                left,
                top - margin,
                left + page_width,
                top - margin + page_height,
            );
            // Nothing lies above the first slice or below the last one: let those pages
            // show their whole area (no clipping at the very edge of the content).
            let top = if i == 0 { area.top } else { top };
            let bottom = if i == last {
                area.bottom.max(bottom)
            } else {
                bottom
            };
            OutputPage {
                area,
                scale,
                pattern_origin: 0.0,
                pdf_page: None,
                content: Some(ViewportRect::new(area.left, top, area.right, bottom)),
            }
        })
        .collect()
}

/// Splits the content between `top` and `bottom` into page slices `(top, bottom)` at most
/// `usable` tall (world units; `spans` are the items' vertical extents).
///
/// Smart page break: where a page would end (`cut = slice top + usable`), the items
/// crossing that line are found. If there are any, the break moves up to just above the
/// topmost of them, `padding` above it (less if the gap to the writing above is smaller),
/// so that line of handwriting starts the next page intact. Items overlapping those move
/// along too. A break never moves up by more than [`MAX_BREAK_SHIFT`] of the page; then
/// the page is cut where it is full. Only the pagination changes, never the canvas.
pub fn smart_page_breaks(
    spans: &[(f32, f32)],
    top: f32,
    bottom: f32,
    usable: f32,
    padding: f32,
) -> Vec<(f32, f32)> {
    if !(top.is_finite() && bottom.is_finite() && usable.is_finite() && usable > 0.0) {
        return vec![(top, bottom)];
    }
    // Runs of items that overlap vertically: a break inside one cuts through ink.
    let mut sorted: Vec<(f32, f32)> = spans
        .iter()
        .copied()
        .filter(|(a, b)| a.is_finite() && b.is_finite() && b > a)
        .collect();
    sorted.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut runs: Vec<(f32, f32)> = Vec::new();
    for (a, b) in sorted {
        match runs.last_mut() {
            Some(run) if a < run.1 => run.1 = run.1.max(b),
            _ => runs.push((a, b)),
        }
    }

    let padding = padding.max(0.0);
    let mut slices = Vec::new();
    let mut y = top;
    loop {
        let cut = y + usable;
        if cut >= bottom || slices.len() + 1 >= MAX_WHITEBOARD_PAGES {
            slices.push((y, bottom));
            return slices;
        }
        // The run the page end falls into (strictly inside: touching is not cutting).
        let i = runs.partition_point(|run| run.0 < cut);
        let smart = match i.checked_sub(1).map(|j| (j, runs[j])) {
            Some((j, (a, b))) if b > cut => {
                // Into the gap above the run: `padding` above it, or halfway into a
                // narrower gap.
                let above = if j > 0 {
                    runs[j - 1].1
                } else {
                    f32::NEG_INFINITY
                };
                let shifted = (a - padding).max((above + a) * 0.5).min(a);
                (shifted >= y + (1.0 - MAX_BREAK_SHIFT) * usable).then_some(shifted)
            }
            _ => None,
        };
        let cut = smart.unwrap_or(cut);
        slices.push((y, cut));
        y = cut;
    }
}

/// Renders the document and writes it to `path`.
pub fn export_document(
    path: &str,
    doc: &ExportDocument,
    font: Option<&[u8]>,
) -> Result<PdfExportReport> {
    let (bytes, pages) = render_document(doc, font)?;
    if let Some(parent) = std::path::Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
    }
    std::fs::write(path, &bytes).with_context(|| format!("writing {path}"))?;
    let (w, h) = pages.first().map_or((0.0, 0.0), OutputPage::size_pt);
    Ok(PdfExportReport {
        path: path.to_string(),
        page_count: pages.len() as u32,
        page_width_pt: w,
        page_height_pt: h,
        byte_size: bytes.len().min(u32::MAX as usize) as u32,
    })
}

/// Renders the document to PDF bytes. Returns the bytes and the output pages.
pub fn render_document(
    doc: &ExportDocument,
    font: Option<&[u8]>,
) -> Result<(Vec<u8>, Vec<OutputPage>)> {
    let renders: Vec<StrokeRender> = doc.strokes.iter().map(Stroke::render).collect();
    // A PDF that fails to parse only loses its backgrounds; the annotations still export.
    let mut embedder = doc.pdf.and_then(|bytes| PdfEmbedder::new(bytes).ok());
    let pages = layout_pages(doc, &renders, |i| {
        embedder
            .as_ref()
            .and_then(|e| e.geometry(i as usize))
            .map(|g| g.display_size().0)
    });
    let spec = doc.paper.spec();

    let mut font = PdfFont::new(font);
    let mut states = GraphicsStates::default();
    let mut page_streams: Vec<Vec<u8>> = Vec::with_capacity(pages.len());
    for page in &pages {
        let form_matrix = page.pdf_page.and_then(|i| {
            let g = embedder.as_ref()?.geometry(i as usize)?;
            let (w, h) = g.display_size();
            let (out_w, out_h) = page.size_pt();
            let (sx, sy) = (out_w / w, out_h / h);
            let [a, b, c, d, e, f] = g.display_matrix();
            Some([a * sx, b * sy, c * sx, d * sy, e * sx, f * sy])
        });
        let content = render_page(
            page,
            &spec,
            form_matrix,
            &renders,
            doc.notes,
            &mut font,
            &mut states,
        );
        page_streams.push(content.finish().to_vec());
    }

    // ---- object graph
    let mut alloc = RefAlloc::new();
    let catalog_id = alloc.bump();
    let tree_id = alloc.bump();
    let info_id = alloc.bump();
    let page_ids: Vec<Ref> = pages.iter().map(|_| alloc.bump()).collect();
    let content_ids: Vec<Ref> = pages.iter().map(|_| alloc.bump()).collect();
    let state_ids: Vec<Ref> = states.entries.iter().map(|_| alloc.bump()).collect();
    let font_ids = FontRefs {
        font: alloc.bump(),
        cid: alloc.bump(),
        descriptor: alloc.bump(),
        file: alloc.bump(),
        cmap: alloc.bump(),
    };
    let form_ids: Vec<Option<Ref>> = pages
        .iter()
        .map(|p| {
            let e = embedder.as_mut()?;
            e.form(p.pdf_page? as usize, &mut alloc)
        })
        .collect();

    let mut pdf = Pdf::new();
    pdf.catalog(catalog_id).pages(tree_id);
    pdf.document_info(info_id)
        .title(TextStr("EasyNotes export"))
        .creator(TextStr("EasyNotes rust_engine"));
    pdf.pages(tree_id)
        .kids(page_ids.iter().copied())
        .count(pages.len() as i32);

    for (i, &page_id) in page_ids.iter().enumerate() {
        let (w, h) = pages[i].size_pt();
        let mut page = pdf.page(page_id);
        page.media_box(Rect::new(0.0, 0.0, w, h))
            .parent(tree_id)
            .contents(content_ids[i]);
        let mut resources = page.resources();
        resources.fonts().pair(Name(b"F1"), font_ids.font);
        {
            let mut gs = resources.ext_g_states();
            for (j, entry) in states.entries.iter().enumerate() {
                gs.pair(Name(entry.name.as_bytes()), state_ids[j]);
            }
        }
        if let Some(form) = form_ids[i] {
            resources.x_objects().pair(Name(BACKGROUND_FORM), form);
        }
        resources.finish();
        page.finish();
    }
    for (i, data) in page_streams.iter().enumerate() {
        let compressed = compress_to_vec_zlib(data, 6);
        pdf.stream(content_ids[i], &compressed)
            .filter(Filter::FlateDecode);
    }
    for (j, entry) in states.entries.iter().enumerate() {
        let mut gs = pdf.ext_graphics(state_ids[j]);
        gs.non_stroking_alpha(entry.alpha)
            .stroking_alpha(entry.alpha);
        if entry.multiply {
            gs.blend_mode(pdf_writer::types::BlendMode::Multiply);
        }
    }
    font.write(&mut pdf, &font_ids)?;
    if let Some(e) = embedder {
        e.write(&mut pdf, &mut alloc);
    }

    Ok((pdf.finish(), pages))
}

// ------------------------------------------------------------------------- pages

fn render_page(
    page: &OutputPage,
    spec: &PaperSpec,
    form_matrix: Option<[f32; 6]>,
    renders: &[StrokeRender],
    notes: &[StickyNote],
    font: &mut PdfFont,
    states: &mut GraphicsStates,
) -> Content {
    let area = page.area;
    let s = page.scale;
    // World (Y down, page-relative) → PDF user space (Y up, origin bottom-left).
    let world = [s, 0.0, 0.0, -s, -s * area.left, s * area.bottom];
    let mut c = Content::new();

    c.save_state();
    c.transform(world);
    if form_matrix.is_some() {
        states.apply(&mut c, 1.0, false);
        set_fill(&mut c, 0xFFFFFFFF);
        c.rect(area.left, area.top, area.width(), area.height());
        c.fill_nonzero();
    } else {
        draw_paper(&mut c, &area, page.pattern_origin, spec, states);
    }
    c.restore_state();

    if let Some(m) = form_matrix {
        c.save_state();
        c.transform(m);
        c.x_object(Name(BACKGROUND_FORM));
        c.restore_state();
    }

    c.save_state();
    c.transform(world);
    let shown = page.content.unwrap_or(area);
    if page.content.is_some() {
        // Ink crossing a page break is split there instead of repeating in the margin.
        c.rect(shown.left, shown.top, shown.width(), shown.height());
        c.clip_nonzero();
        c.end_path();
    }
    for note in notes.iter().filter(|n| n.rect().intersects(&shown)) {
        draw_note(&mut c, note, font, states);
    }
    // Highlighters go beneath the regular ink.
    for r in renders
        .iter()
        .filter(|r| r.tool == ToolType::Highlighter && r.bounds.intersects(&shown))
    {
        draw_stroke(&mut c, r, states);
    }
    for r in renders
        .iter()
        .filter(|r| r.tool != ToolType::Highlighter && r.bounds.intersects(&shown))
    {
        draw_stroke(&mut c, r, states);
    }
    c.restore_state();
    c
}

/// Paper background and pattern for `area`. Patterns restart at `origin_y` (each page's
/// top on paged documents), matching the Flutter painter.
fn draw_paper(
    c: &mut Content,
    area: &ViewportRect,
    origin_y: f32,
    spec: &PaperSpec,
    states: &mut GraphicsStates,
) {
    states.apply(c, 1.0, false);
    set_fill(c, spec.background);
    c.rect(area.left, area.top, area.width(), area.height());
    c.fill_nonzero();

    match spec.kind {
        PaperKind::Plain => {}
        PaperKind::Lined => {
            let first = origin_y + spec.first_line_y;
            let mut y = first + ((area.top - first) / spec.spacing).ceil().max(0.0) * spec.spacing;
            set_stroke(c, spec.line_color);
            c.set_line_width(spec.line_width);
            let mut any = false;
            while y <= area.bottom {
                c.move_to(area.left, y);
                c.line_to(area.right, y);
                any = true;
                y += spec.spacing;
            }
            if any {
                c.stroke();
            }
            if spec.margin_x > 0.0 {
                set_stroke(c, spec.margin_color);
                c.set_line_width(1.2);
                c.move_to(spec.margin_x, area.top);
                c.line_to(spec.margin_x, area.bottom);
                c.stroke();
            }
        }
        PaperKind::Grid => {
            set_stroke(c, spec.line_color);
            c.set_line_width(spec.line_width);
            let mut x = (area.left / spec.spacing).ceil() * spec.spacing;
            while x <= area.right {
                c.move_to(x, area.top);
                c.line_to(x, area.bottom);
                x += spec.spacing;
            }
            let mut y = origin_y + ((area.top - origin_y) / spec.spacing).ceil() * spec.spacing;
            while y <= area.bottom {
                c.move_to(area.left, y);
                c.line_to(area.right, y);
                y += spec.spacing;
            }
            c.stroke();
        }
    }
}

fn draw_stroke(c: &mut Content, r: &StrokeRender, states: &mut GraphicsStates) {
    let pts = &r.geometry;
    if pts.len() < 2 {
        return;
    }
    let color_alpha = ((r.color >> 24) & 0xFF) as f32 / 255.0;
    let pencil_factor = if r.tool == ToolType::Pencil {
        0.92
    } else {
        1.0
    };
    let alpha = (r.opacity * color_alpha * pencil_factor).clamp(0.0, 1.0);
    states.apply(c, alpha, r.tool == ToolType::Highlighter);

    let path = |c: &mut Content| {
        c.move_to(pts[0], pts[1]);
        for i in (2..pts.len() - 1).step_by(2) {
            c.line_to(pts[i], pts[i + 1]);
        }
    };
    match r.kind {
        RenderKind::FilledOutline => {
            set_fill(c, r.color);
            path(c);
            c.close_path();
            c.fill_nonzero();
        }
        RenderKind::OpenPolyline => {
            set_stroke(c, r.color);
            c.set_line_width(r.width);
            c.set_line_cap(LineCapStyle::ProjectingSquareCap);
            c.set_line_join(LineJoinStyle::RoundJoin);
            path(c);
            if pts.len() == 2 {
                // Single sample: zero-length subpath renders as a square dot.
                c.line_to(pts[0], pts[1]);
            }
            c.stroke();
        }
        RenderKind::ClosedPolygon | RenderKind::OpenShape => {
            set_stroke(c, r.color);
            c.set_line_width(r.width);
            c.set_line_cap(LineCapStyle::ButtCap);
            c.set_line_join(LineJoinStyle::MiterJoin);
            c.set_miter_limit(10.0);
            path(c);
            if r.kind == RenderKind::ClosedPolygon {
                c.close_path();
            }
            c.stroke();
        }
    }
}

fn draw_note(c: &mut Content, note: &StickyNote, font: &mut PdfFont, states: &mut GraphicsStates) {
    let r = note.rect();
    // Soft drop shadow.
    states.apply(c, 0.12, false);
    set_fill(c, 0xFF000000);
    c.rect(r.left + 2.0, r.top + 3.0, r.width(), r.height());
    c.fill_nonzero();

    states.apply(c, 1.0, false);
    set_fill(c, note.color);
    c.rect(r.left, r.top, r.width(), r.height());
    c.fill_nonzero();
    set_stroke(c, darken(note.color, 0.82));
    c.set_line_width(1.0);
    c.rect(r.left, r.top, r.width(), r.height());
    c.stroke();

    if note.text.trim().is_empty() {
        return;
    }
    let fs = note.font_size;
    let max_w = (r.width() - 2.0 * NOTE_PADDING).max(fs);
    let lines = wrap_text(&note.text, max_w, |t| font.measure(t, fs));

    c.save_state();
    c.rect(r.left, r.top, r.width(), r.height());
    c.clip_nonzero();
    c.end_path();
    set_fill(c, NOTE_TEXT_COLOR);
    let line_h = fs * NOTE_LINE_HEIGHT;
    // Baseline of the first line: padding + half-leading + ascent.
    let mut baseline = r.top + NOTE_PADDING + (line_h - fs) * 0.5 + font.ascent() * fs;
    c.begin_text();
    c.set_font(Name(b"F1"), 1.0);
    for line in lines {
        if baseline - fs > r.bottom {
            break;
        }
        // Text space is Y-up; flip it back because the page CTM is Y-down.
        c.set_text_matrix([fs, 0.0, 0.0, -fs, r.left + NOTE_PADDING, baseline]);
        let encoded = font.encode(&line);
        c.show(Str(&encoded));
        baseline += line_h;
    }
    c.end_text();
    c.restore_state();
}

/// Greedy word wrap honouring explicit newlines; overlong words are broken by character.
pub fn wrap_text(text: &str, max_width: f32, mut measure: impl FnMut(&str) -> f32) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let mut current = String::new();
        for word in paragraph.split(' ') {
            let candidate = if current.is_empty() {
                word.to_string()
            } else {
                format!("{current} {word}")
            };
            if measure(&candidate) <= max_width {
                current = candidate;
                continue;
            }
            if !current.is_empty() {
                lines.push(std::mem::take(&mut current));
            }
            if measure(word) <= max_width {
                current = word.to_string();
            } else {
                for ch in word.chars() {
                    let mut next = current.clone();
                    next.push(ch);
                    if measure(&next) > max_width && !current.is_empty() {
                        lines.push(std::mem::take(&mut current));
                        current.push(ch);
                    } else {
                        current = next;
                    }
                }
            }
        }
        lines.push(current);
    }
    lines
}

// ------------------------------------------------------------------------- colours / states

fn rgb(color: u32) -> (f32, f32, f32) {
    (
        ((color >> 16) & 0xFF) as f32 / 255.0,
        ((color >> 8) & 0xFF) as f32 / 255.0,
        (color & 0xFF) as f32 / 255.0,
    )
}

fn set_fill(c: &mut Content, color: u32) {
    let (r, g, b) = rgb(color);
    c.set_fill_rgb(r, g, b);
}

fn set_stroke(c: &mut Content, color: u32) {
    let (r, g, b) = rgb(color);
    c.set_stroke_rgb(r, g, b);
}

fn darken(color: u32, f: f32) -> u32 {
    let (r, g, b) = rgb(color);
    let ch = |v: f32| ((v * f).clamp(0.0, 1.0) * 255.0).round() as u32;
    0xFF00_0000 | (ch(r) << 16) | (ch(g) << 8) | ch(b)
}

struct GraphicsStateEntry {
    name: String,
    alpha: f32,
    multiply: bool,
}

/// Deduplicated ExtGState dictionary (opacity + blend mode combinations).
#[derive(Default)]
struct GraphicsStates {
    entries: Vec<GraphicsStateEntry>,
    lookup: HashMap<(u8, bool), usize>,
}

impl GraphicsStates {
    /// Selects (creating on first use) the ExtGState for `alpha` / blend mode on `c`.
    fn apply(&mut self, c: &mut Content, alpha: f32, multiply: bool) {
        let q = (alpha.clamp(0.0, 1.0) * 255.0).round() as u8;
        let idx = match self.lookup.get(&(q, multiply)) {
            Some(&i) => i,
            None => {
                self.entries.push(GraphicsStateEntry {
                    name: format!("G{}", self.entries.len()),
                    alpha: q as f32 / 255.0,
                    multiply,
                });
                self.lookup.insert((q, multiply), self.entries.len() - 1);
                self.entries.len() - 1
            }
        };
        c.set_parameters(Name(self.entries[idx].name.as_bytes()));
    }
}

// ------------------------------------------------------------------------- fonts

struct FontRefs {
    font: Ref,
    cid: Ref,
    descriptor: Ref,
    file: Ref,
    cmap: Ref,
}

enum PdfFont<'a> {
    Embedded {
        face: Box<ttf_parser::Face<'a>>,
        data: &'a [u8],
        used: BTreeMap<u16, char>,
    },
    Helvetica,
}

impl<'a> PdfFont<'a> {
    fn new(data: Option<&'a [u8]>) -> Self {
        match data.and_then(|d| ttf_parser::Face::parse(d, 0).ok().map(|f| (d, f))) {
            Some((data, face)) => PdfFont::Embedded {
                face: Box::new(face),
                data,
                used: BTreeMap::new(),
            },
            None => PdfFont::Helvetica,
        }
    }

    fn ascent(&self) -> f32 {
        match self {
            PdfFont::Embedded { face, .. } => face.ascender() as f32 / face.units_per_em() as f32,
            PdfFont::Helvetica => 0.718,
        }
    }

    fn measure(&self, text: &str, size: f32) -> f32 {
        match self {
            PdfFont::Embedded { face, .. } => {
                let upem = face.units_per_em() as f32;
                text.chars()
                    .map(|ch| {
                        let gid = face.glyph_index(ch).unwrap_or(ttf_parser::GlyphId(0));
                        face.glyph_hor_advance(gid).unwrap_or(0) as f32 / upem
                    })
                    .sum::<f32>()
                    * size
            }
            PdfFont::Helvetica => text.chars().map(helvetica_width).sum::<f32>() * size,
        }
    }

    fn encode(&mut self, text: &str) -> Vec<u8> {
        match self {
            PdfFont::Embedded { face, used, .. } => {
                let mut out = Vec::with_capacity(text.len() * 2);
                for ch in text.chars() {
                    let gid = face.glyph_index(ch).map_or(0, |g| g.0);
                    if gid != 0 {
                        used.entry(gid).or_insert(ch);
                    }
                    out.extend_from_slice(&gid.to_be_bytes());
                }
                out
            }
            PdfFont::Helvetica => text.chars().map(win_ansi_byte).collect(),
        }
    }

    fn write(&self, pdf: &mut Pdf, refs: &FontRefs) -> Result<()> {
        match self {
            PdfFont::Helvetica => {
                pdf.type1_font(refs.font)
                    .base_font(Name(b"Helvetica"))
                    .encoding_predefined(Name(b"WinAnsiEncoding"));
            }
            PdfFont::Embedded { face, data, used } => {
                let upem = face.units_per_em() as f32;
                let to_pdf = |v: f32| v * 1000.0 / upem;
                let base = Name(b"EasyNotesNoteFont");

                pdf.type0_font(refs.font)
                    .base_font(base)
                    .encoding_predefined(Name(b"Identity-H"))
                    .descendant_font(refs.cid)
                    .to_unicode(refs.cmap);

                let mut cid = pdf.cid_font(refs.cid);
                cid.subtype(CidFontType::Type2)
                    .base_font(base)
                    .system_info(SystemInfo {
                        registry: Str(b"Adobe"),
                        ordering: Str(b"Identity"),
                        supplement: 0,
                    })
                    .font_descriptor(refs.descriptor)
                    .default_width(500.0)
                    .cid_to_gid_map_predefined(Name(b"Identity"));
                {
                    let mut widths = cid.widths();
                    for &gid in used.keys() {
                        let adv = face
                            .glyph_hor_advance(ttf_parser::GlyphId(gid))
                            .unwrap_or(0) as f32;
                        widths.consecutive(gid, [to_pdf(adv)]);
                    }
                }
                cid.finish();

                let bbox = face.global_bounding_box();
                pdf.font_descriptor(refs.descriptor)
                    .name(base)
                    .flags(FontFlags::NON_SYMBOLIC)
                    .bbox(Rect::new(
                        to_pdf(bbox.x_min as f32),
                        to_pdf(bbox.y_min as f32),
                        to_pdf(bbox.x_max as f32),
                        to_pdf(bbox.y_max as f32),
                    ))
                    .italic_angle(face.italic_angle())
                    .ascent(to_pdf(face.ascender() as f32))
                    .descent(to_pdf(face.descender() as f32))
                    .cap_height(to_pdf(
                        face.capital_height().unwrap_or(face.ascender()) as f32
                    ))
                    .stem_v(80.0)
                    .font_file2(refs.file);

                let compressed = compress_to_vec_zlib(data, 6);
                pdf.stream(refs.file, &compressed)
                    .filter(Filter::FlateDecode)
                    .pair(Name(b"Length1"), data.len() as i32);

                let mut cmap = UnicodeCmap::new(
                    Name(b"EasyNotes-UTF16"),
                    SystemInfo {
                        registry: Str(b"Adobe"),
                        ordering: Str(b"UCS"),
                        supplement: 0,
                    },
                );
                for (&gid, &ch) in used {
                    cmap.pair(gid, ch);
                }
                let cmap = cmap.finish();
                pdf.stream(refs.cmap, &cmap);
            }
        }
        Ok(())
    }
}

/// Maps a char to WinAnsi (CP1252), transliterating Romanian letters that it lacks.
fn win_ansi_byte(ch: char) -> u8 {
    let ch = match ch {
        'ă' => 'a',
        'Ă' => 'A',
        'ș' | 'ş' => 's',
        'Ș' | 'Ş' => 'S',
        'ț' | 'ţ' => 't',
        'Ț' | 'Ţ' => 'T',
        '\u{2018}' | '\u{2019}' => '\'',
        '\u{201C}' | '\u{201D}' | '\u{201E}' => '"',
        '\u{2013}' | '\u{2014}' => '-',
        '\t' => ' ',
        c => c,
    };
    let code = ch as u32;
    if (0x20..=0x7E).contains(&code) || (0xA0..=0xFF).contains(&code) {
        code as u8
    } else {
        b'?'
    }
}

/// Approximate Helvetica advance widths (em) – good enough for wrapping fallback text.
fn helvetica_width(ch: char) -> f32 {
    match ch {
        ' ' | '!' | ',' | '.' | '/' | ':' | ';' | 'I' | '[' | ']' | '\\' | 'f' | 't' => 0.278,
        'i' | 'j' | 'l' | '\'' | '|' | 'î' => 0.222,
        'r' | '(' | ')' | '-' => 0.333,
        'm' | 'M' => 0.833,
        'w' | 'W' => 0.75,
        '0'..='9' => 0.556,
        c if c.is_uppercase() => 0.667,
        _ => 0.556,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::pdf_importer::tests::sample_pdf;
    use crate::document::{Engine, ImportedPdf};
    use crate::geometry::{Brush, StrokePoint};

    fn scribble(e: &mut Engine, tool: ToolType, y: f32) {
        e.begin_stroke(
            tool,
            Brush {
                color: 0xFF2255CC,
                width: 4.0,
                opacity: 0.9,
            },
        );
        for i in 0..40 {
            e.add_point(StrokePoint::new(
                30.0 + i as f32 * 8.0,
                y + (i as f32 * 0.4).sin() * 10.0,
                0.6,
            ));
        }
        e.finish_stroke(tool, false).unwrap();
    }

    fn sample_whiteboard() -> Engine {
        let mut e = Engine::new();
        for (tool, y) in [
            (ToolType::Pen, 50.0),
            (ToolType::Pencil, 120.0),
            (ToolType::Highlighter, 200.0),
        ] {
            scribble(&mut e, tool, y);
        }
        e.create_note(
            400.0,
            400.0,
            200.0,
            120.0,
            0xFFFFF59D,
            "Salut! Notă cu diacritice ăâîșț și text lung care se rupe.".into(),
        );
        // Content far below → multiple pages.
        e.begin_stroke(ToolType::Pen, Brush::default());
        for i in 0..10 {
            e.add_point(StrokePoint::new(100.0 + i as f32 * 3.0, 2500.0, 0.5));
        }
        e.finish_stroke(ToolType::Pen, false).unwrap();
        e
    }

    fn export_doc<'a>(
        e: &'a Engine,
        data: &'a crate::document::DocumentData,
        paper: PaperStyle,
    ) -> ExportDocument<'a> {
        ExportDocument {
            kind: data.kind,
            paper,
            pages: &data.pages,
            strokes: &data.strokes,
            notes: &data.notes,
            pdf: e.pdf().map(|p| p.bytes.as_slice()),
        }
    }

    fn assert_valid_pdf(bytes: &[u8]) -> lopdf::Document {
        assert!(bytes.starts_with(b"%PDF-"));
        assert!(bytes.ends_with(b"%%EOF") || bytes.ends_with(b"%%EOF\n"));
        lopdf::Document::load_mem(bytes).expect("output must parse")
    }

    fn media_box(doc: &lopdf::Document, page: lopdf::ObjectId) -> Vec<f32> {
        doc.get_dictionary(page)
            .unwrap()
            .get(b"MediaBox")
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o.as_float().unwrap())
            .collect()
    }

    fn rect(left: f32, top: f32, right: f32, bottom: f32) -> ViewportRect {
        ViewportRect::new(left, top, right, bottom)
    }

    /// Usable page height (world units) at the natural scale.
    fn usable_height() -> f32 {
        (A4_HEIGHT_PT - 2.0 * WHITEBOARD_MARGIN_PT) / PT_PER_UNIT
    }

    #[test]
    fn whiteboards_paginate_downwards_on_a4() {
        let pages = whiteboard_pages(&[rect(0.0, 0.0, 500.0, 2500.0)]);
        // One item taller than a page cannot be avoided: hard cuts every full page.
        assert_eq!(pages.len(), 3);
        for p in &pages {
            let (w, h) = p.size_pt();
            assert!(
                (w - A4_WIDTH_PT).abs() < 0.01 && (h - A4_HEIGHT_PT).abs() < 0.01,
                "{w}×{h}"
            );
            assert_eq!(
                p.scale, PT_PER_UNIT,
                "narrow boards keep the notebook scale"
            );
        }
        // Content starts at the top-left margin, not at the canvas origin.
        let first = pages[0].content.unwrap();
        assert!((pages[0].area.left - (0.0 - WHITEBOARD_MARGIN_PT / PT_PER_UNIT)).abs() < 0.01);
        assert!(first.top <= 0.0);
        // Consecutive pages continue exactly where the previous one stopped.
        for pair in pages.windows(2) {
            assert_eq!(
                pair[0].content.unwrap().bottom,
                pair[1].content.unwrap().top
            );
        }
        // An empty board still exports one A4 page.
        let empty = whiteboard_pages(&[]);
        assert_eq!(empty.len(), 1);
        assert!((empty[0].size_pt().0 - A4_WIDTH_PT).abs() < 0.01);
    }

    #[test]
    fn wide_whiteboards_are_scaled_to_the_page_width_instead_of_sliced() {
        let items = [
            rect(-200.0, 100.0, 2800.0, 300.0),
            rect(1000.0, 400.0, 1200.0, 500.0),
        ];
        let pages = whiteboard_pages(&items);
        assert_eq!(pages.len(), 1, "no horizontal slicing");
        let p = &pages[0];
        let usable_pt = A4_WIDTH_PT - 2.0 * WHITEBOARD_MARGIN_PT;
        assert!((p.scale - usable_pt / 3000.0).abs() < 1e-6);
        // Left and right content edges sit exactly on the 24 pt margins.
        assert!(((-200.0 - p.area.left) * p.scale - WHITEBOARD_MARGIN_PT).abs() < 0.01);
        assert!(((p.area.right - 2800.0) * p.scale - WHITEBOARD_MARGIN_PT).abs() < 0.01);
        assert!((p.size_pt().0 - A4_WIDTH_PT).abs() < 0.01);
    }

    #[test]
    fn smart_page_breaks_move_lines_of_writing_to_the_next_page() {
        let usable = usable_height();
        let padding = BREAK_PADDING_PT / PT_PER_UNIT;
        // Lines of handwriting 60 units tall with 40-unit gaps; one of them straddles the
        // natural end of page 1.
        let lines: Vec<(f32, f32)> = (0..30)
            .map(|i| (i as f32 * 100.0, i as f32 * 100.0 + 60.0))
            .collect();
        let natural = usable;
        let straddling = lines
            .iter()
            .find(|(a, b)| *a < natural && *b > natural)
            .copied()
            .unwrap();
        let slices = smart_page_breaks(&lines, 0.0, 2960.0, usable, padding);
        let cut = slices[0].1;
        assert!(cut < straddling.0, "the line moves to page 2 in one piece");
        assert!(
            (straddling.0 - cut - padding).abs() < 0.01,
            "with the padding above it"
        );
        assert!(
            cut > straddling.0 - 40.0,
            "but still in the gap below the previous line"
        );
        // No page break cuts through any line.
        for &(_, end) in &slices[..slices.len() - 1] {
            assert!(
                lines.iter().all(|&(a, b)| !(a < end && b > end)),
                "cut at {end}"
            );
        }
        // The slices cover everything, in order, none taller than a page.
        assert_eq!(slices.first().unwrap().0, 0.0);
        assert_eq!(slices.last().unwrap().1, 2960.0);
        for s in &slices {
            assert!(s.1 > s.0 && s.1 - s.0 <= usable + 0.01);
        }
    }

    #[test]
    fn smart_page_breaks_use_half_a_narrow_gap_and_never_give_up_more_than_35_percent() {
        let usable = 1000.0;
        // Gap of 6 units between two lines; padding 13 would reach into the upper line.
        let tight = [(900.0, 990.0), (996.0, 1050.0)];
        let slices = smart_page_breaks(&tight, 0.0, 1050.0, usable, 13.0);
        assert_eq!(slices[0].1, 993.0, "halfway into the gap");

        // A drawing spanning 40 % of the page across the cut: moving above it would waste
        // too much paper, so it is cut where the page is full.
        let tall = [(100.0, 200.0), (600.0, 1400.0)];
        let slices = smart_page_breaks(&tall, 0.0, 1400.0, usable, 13.0);
        assert_eq!(slices[0], (0.0, 1000.0));
        // Giving up about 31 % of the page is still fine.
        let ok = [(700.0, 1300.0)];
        let slices = smart_page_breaks(&ok, 0.0, 1300.0, usable, 13.0);
        assert_eq!(slices[0], (0.0, 687.0));

        // Items that only touch the page end are not cut, and the break stays.
        let touching = [(0.0, 1000.0), (1000.0, 1100.0)];
        assert_eq!(
            smart_page_breaks(&touching, 0.0, 1100.0, usable, 13.0)[0],
            (0.0, 1000.0)
        );
    }

    #[test]
    fn whiteboard_pages_clip_ink_to_their_slice() {
        let usable = usable_height();
        let line = rect(10.0, usable - 30.0, 400.0, usable + 30.0);
        let pages = whiteboard_pages(&[rect(10.0, 0.0, 400.0, 50.0), line]);
        assert_eq!(pages.len(), 2);
        let (p1, p2) = (pages[0].content.unwrap(), pages[1].content.unwrap());
        assert!(p1.bottom <= line.top, "page 1 stops above the line");
        assert!(
            p2.top <= line.top && p2.bottom >= line.bottom,
            "page 2 holds all of it"
        );
        // The page areas include the margins around the slice.
        assert!(pages[1].area.top < p2.top);
    }

    #[test]
    fn renders_valid_whiteboard_pdf_for_every_paper_style() {
        let e = sample_whiteboard();
        let data = e.data();
        for style in [
            PaperStyle::Whiteboard,
            PaperStyle::Dictando,
            PaperStyle::Matematica,
        ] {
            let (bytes, pages) = render_document(&export_doc(&e, &data, style), None).unwrap();
            assert_valid_pdf(&bytes);
            assert_eq!(pages.len(), 3);
        }
    }

    #[test]
    fn notebooks_export_one_square_page_per_page() {
        let mut e = Engine::with_kind(DocumentKind::Notebook, PaperStyle::Matematica);
        scribble(&mut e, ToolType::Pen, 100.0);
        e.append_page();
        e.append_page();
        // Page 2 stays blank on purpose; page 3 is written on.
        scribble(&mut e, ToolType::Pen, 2100.0);
        let data = e.data();
        let (bytes, pages) =
            render_document(&export_doc(&e, &data, PaperStyle::Matematica), None).unwrap();
        assert_eq!(pages.len(), 3);
        let doc = assert_valid_pdf(&bytes);
        let ids: Vec<_> = doc.page_iter().collect();
        assert_eq!(ids.len(), 3);
        assert_eq!(media_box(&doc, ids[1]), vec![0.0, 0.0, 750.0, 750.0]);
        assert_eq!(media_box(&doc, ids[2]), vec![0.0, 0.0, 750.0, 750.0]);
    }

    #[test]
    fn blank_pages_at_the_end_of_a_notebook_are_not_exported() {
        let pages_of = |e: &Engine| {
            let data = e.data();
            layout_pages(&export_doc(e, &data, e.paper()), &[], |_| None)
                .iter()
                .map(|p| p.area.top)
                .collect::<Vec<_>>()
        };
        let mut e = Engine::with_kind(DocumentKind::Notebook, PaperStyle::Dictando);
        scribble(&mut e, ToolType::Pen, 100.0);
        e.append_page();
        e.append_page();
        e.append_page();
        // Ink on page 1 only: the three pages added by scrolling are left out.
        let data = e.data();
        let renders: Vec<StrokeRender> = data.strokes.iter().map(Stroke::render).collect();
        let pages = layout_pages(&export_doc(&e, &data, e.paper()), &renders, |_| None);
        assert_eq!(pages.len(), 1);
        assert_eq!(data.pages.len(), 4, "the document itself keeps its pages");

        // A sticky note on page 3 keeps pages 1–3 (page 2 is a blank page in between).
        e.create_note(100.0, 2200.0, 200.0, 150.0, 0xFFFFF59D, String::new());
        let data = e.data();
        let renders: Vec<StrokeRender> = data.strokes.iter().map(Stroke::render).collect();
        let pages = layout_pages(&export_doc(&e, &data, e.paper()), &renders, |_| None);
        assert_eq!(pages.len(), 3);

        // A stroke whose edge only grazes the next page does not keep that page.
        let mut graze = Engine::with_kind(DocumentKind::Notebook, PaperStyle::Dictando);
        graze.append_page();
        scribble(&mut graze, ToolType::Pen, 994.0);
        let data = graze.data();
        let renders: Vec<StrokeRender> = data.strokes.iter().map(Stroke::render).collect();
        assert!(renders[0].bounds.bottom > 1000.0);
        let pages = layout_pages(&export_doc(&graze, &data, graze.paper()), &renders, |_| {
            None
        });
        assert_eq!(pages.len(), 1);

        // An empty notebook still exports its first page.
        let mut empty = Engine::with_kind(DocumentKind::Notebook, PaperStyle::Dictando);
        empty.append_page();
        empty.append_page();
        assert_eq!(pages_of(&empty), vec![0.0]);
    }

    #[test]
    fn pdf_annotations_keep_the_original_pages_as_vectors() {
        let pdf = ImportedPdf::parse(sample_pdf()).unwrap();
        // Untouched PDF pages are always exported; a blank page added after them is not.
        let mut untouched = Engine::with_pdf(pdf.clone());
        untouched.append_page();
        let data = untouched.data();
        let (_, pages) =
            render_document(&export_doc(&untouched, &data, PaperStyle::Whiteboard), None).unwrap();
        assert_eq!(pages.len(), 2);

        let mut e = Engine::with_pdf(pdf);
        scribble(&mut e, ToolType::Highlighter, 120.0);
        let appended = e.append_page().unwrap();
        // Written on, so the appended page is exported (with the previous page's scale).
        scribble(&mut e, ToolType::Pen, appended.top + 200.0);
        e.append_page();
        let data = e.data();
        let (bytes, pages) =
            render_document(&export_doc(&e, &data, PaperStyle::Whiteboard), None).unwrap();
        assert_eq!(pages.len(), 3);
        let doc = assert_valid_pdf(&bytes);
        let ids: Vec<_> = doc.page_iter().collect();
        // Original page sizes (the second one is rotated and cropped).
        let p0 = media_box(&doc, ids[0]);
        assert!(
            (p0[2] - 595.0).abs() < 0.01 && (p0[3] - 842.0).abs() < 0.01,
            "{p0:?}"
        );
        let p1 = media_box(&doc, ids[1]);
        assert!(
            (p1[2] - 802.0).abs() < 0.01 && (p1[3] - 575.0).abs() < 0.01,
            "{p1:?}"
        );
        // The appended blank page uses the previous page's scale.
        let p2 = media_box(&doc, ids[2]);
        assert!((p2[2] - 802.0).abs() < 0.01, "{p2:?}");
        // Page 1 references a background form whose content is the original drawing.
        let res = doc
            .get_dict_in_dict(doc.get_dictionary(ids[0]).unwrap(), b"Resources")
            .unwrap();
        let xobjects = doc.get_dict_in_dict(res, b"XObject").unwrap();
        let form_id = xobjects.get(b"Bg").unwrap().as_reference().unwrap();
        let form = doc.get_object(form_id).unwrap().as_stream().unwrap();
        let content = form.decompressed_content().unwrap();
        assert!(
            String::from_utf8_lossy(&content).contains("re"),
            "form lost the page content"
        );
        assert!(doc
            .get_dict_in_dict(doc.get_dictionary(ids[2]).unwrap(), b"Resources")
            .and_then(|r| doc.get_dict_in_dict(r, b"XObject"))
            .is_err());
    }

    #[test]
    fn export_writes_file() {
        let e = sample_whiteboard();
        let data = e.data();
        let dir = std::env::temp_dir().join("easynotes_pdf_test");
        let path = dir.join("export.pdf");
        let report = export_document(
            path.to_str().unwrap(),
            &export_doc(&e, &data, PaperStyle::Dictando),
            None,
        )
        .unwrap();
        assert!(report.byte_size > 500);
        assert_eq!(
            std::fs::metadata(&path).unwrap().len() as u32,
            report.byte_size
        );
    }

    #[test]
    fn wraps_text_to_width() {
        let lines = wrap_text("aaaa bbbb cccc", 9.0, |t| t.chars().count() as f32);
        assert_eq!(lines, vec!["aaaa bbbb", "cccc"]);
        let lines = wrap_text("abcdefghij", 4.0, |t| t.chars().count() as f32);
        assert_eq!(lines, vec!["abcd", "efgh", "ij"]);
    }

    #[test]
    fn transliterates_for_win_ansi() {
        let bytes: Vec<u8> = "ăîșț€".chars().map(win_ansi_byte).collect();
        assert_eq!(bytes, vec![b'a', 0xEE, b's', b't', b'?']);
    }
}

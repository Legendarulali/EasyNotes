//! PDF import: turns an external PDF's page tree into canvas page backgrounds.
//!
//! Rust owns the document structure: page count, effective page boxes (inherited
//! MediaBox / CropBox) and `/Rotate`, which decide the page stack layout, plus the original
//! bytes, which the exporter re-embeds as vector Form XObjects so an annotated export keeps
//! the PDF's text and vector art intact. Rasterising the pages for the screen is Flutter's
//! job (PDFium via `pdfrx`), driven by the `pdf_page` index of each [`CanvasPage`](super::CanvasPage).

use super::page::PageStack;
use anyhow::{anyhow, bail, Result};
use lopdf::{Document, Object, ObjectId};
use std::sync::Arc;

/// Refuse absurdly large inputs instead of exhausting memory on mobile devices.
pub const MAX_PDF_BYTES: usize = 512 * 1024 * 1024;
/// US Letter, used when a page has no (valid) MediaBox anywhere in its ancestry.
const DEFAULT_MEDIA_BOX: [f32; 4] = [0.0, 0.0, 612.0, 792.0];
const MAX_INHERITANCE_DEPTH: usize = 64;

/// One imported page as it is displayed (rotation applied), in PDF points.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PdfPageInfo {
    pub index: u32,
    pub width_pt: f32,
    pub height_pt: f32,
    /// Clockwise display rotation: 0, 90, 180 or 270.
    pub rotation: u32,
}

/// An imported PDF held by the engine (the bytes are shared with export jobs).
#[derive(Debug, Clone)]
pub struct ImportedPdf {
    pub bytes: Arc<Vec<u8>>,
    pub pages: Vec<PdfPageInfo>,
}

impl ImportedPdf {
    /// Parses `bytes` and records every page's displayed size.
    pub fn parse(bytes: Vec<u8>) -> Result<Self> {
        if bytes.len() > MAX_PDF_BYTES {
            bail!("PDF is too large ({} MB)", bytes.len() / (1024 * 1024));
        }
        let doc = load_pdf(&bytes)?;
        let pages: Vec<PdfPageInfo> = doc
            .page_iter()
            .enumerate()
            .map(|(i, id)| {
                let g = page_geometry(&doc, id);
                let (w, h) = g.display_size();
                PdfPageInfo {
                    index: i as u32,
                    width_pt: w,
                    height_pt: h,
                    rotation: g.rotation,
                }
            })
            .collect();
        if pages.is_empty() {
            bail!("the PDF has no pages");
        }
        Ok(Self {
            bytes: Arc::new(bytes),
            pages,
        })
    }

    pub fn read(path: &str) -> Result<Self> {
        let bytes = std::fs::read(path).map_err(|e| anyhow!("cannot read {path}: {e}"))?;
        Self::parse(bytes)
    }

    pub fn page_count(&self) -> u32 {
        self.pages.len() as u32
    }

    /// Page stack with one background page per PDF page (1000 units wide).
    pub fn page_stack(&self) -> PageStack {
        let sizes: Vec<(f32, f32)> = self
            .pages
            .iter()
            .map(|p| (p.width_pt, p.height_pt))
            .collect();
        PageStack::from_pdf_sizes(&sizes)
    }
}

/// Loads a PDF, rejecting files that need a password.
pub fn load_pdf(bytes: &[u8]) -> Result<Document> {
    let doc = Document::load_mem(bytes).map_err(|e| anyhow!("not a readable PDF: {e}"))?;
    if doc.is_encrypted() {
        bail!("password-protected PDFs are not supported");
    }
    Ok(doc)
}

/// Effective geometry of one page, with page-tree inheritance resolved.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PageGeometry {
    /// Visible region (CropBox ∩ MediaBox) in the page's own user space: `[x0, y0, x1, y1]`.
    pub crop: [f32; 4],
    /// Clockwise display rotation: 0, 90, 180 or 270.
    pub rotation: u32,
}

impl PageGeometry {
    /// Size of the page as a viewer displays it.
    pub fn display_size(&self) -> (f32, f32) {
        let w = (self.crop[2] - self.crop[0]).abs().max(1.0);
        let h = (self.crop[3] - self.crop[1]).abs().max(1.0);
        if self.rotation % 180 == 90 {
            (h, w)
        } else {
            (w, h)
        }
    }

    /// Matrix `[a b c d e f]` mapping the page's user space onto the displayed page, whose
    /// origin is its bottom-left corner (PDF convention, Y up).
    pub fn display_matrix(&self) -> [f32; 6] {
        let [x0, y0, x1, y1] = self.crop;
        match self.rotation {
            90 => [0.0, -1.0, 1.0, 0.0, -y0, x1],
            180 => [-1.0, 0.0, 0.0, -1.0, x1, y1],
            270 => [0.0, 1.0, -1.0, 0.0, y1, -x0],
            _ => [1.0, 0.0, 0.0, 1.0, -x0, -y0],
        }
    }
}

/// Resolves MediaBox, CropBox and Rotate for `page_id`.
pub fn page_geometry(doc: &Document, page_id: ObjectId) -> PageGeometry {
    let media = inherited(doc, page_id, b"MediaBox")
        .and_then(|o| rect_from(doc, o))
        .unwrap_or(DEFAULT_MEDIA_BOX);
    let crop = inherited(doc, page_id, b"CropBox")
        .and_then(|o| rect_from(doc, o))
        .and_then(|c| intersect(c, media))
        .unwrap_or(media);
    let rotation = inherited(doc, page_id, b"Rotate")
        .and_then(|o| number(doc, o))
        .map_or(0, |r| ((r.round() as i64).rem_euclid(360) / 90 * 90) as u32);
    PageGeometry { crop, rotation }
}

/// Looks `key` up on the page and then on its ancestors (ISO 32000-1, 7.7.3.4).
pub fn inherited<'a>(doc: &'a Document, page_id: ObjectId, key: &[u8]) -> Option<&'a Object> {
    let mut node = doc.get_dictionary(page_id).ok()?;
    for _ in 0..MAX_INHERITANCE_DEPTH {
        if let Ok(value) = node.get(key) {
            return Some(value);
        }
        let parent = node.get(b"Parent").and_then(Object::as_reference).ok()?;
        node = doc.get_dictionary(parent).ok()?;
    }
    None
}

fn number(doc: &Document, o: &Object) -> Option<f32> {
    match doc.dereference(o).ok()?.1 {
        Object::Integer(i) => Some(*i as f32),
        Object::Real(r) => Some(*r),
        _ => None,
    }
}

/// Normalised `[x0, y0, x1, y1]` from a PDF rectangle array.
fn rect_from(doc: &Document, o: &Object) -> Option<[f32; 4]> {
    let arr = doc.dereference(o).ok()?.1.as_array().ok()?;
    if arr.len() != 4 {
        return None;
    }
    let mut v = [0.0f32; 4];
    for (slot, item) in v.iter_mut().zip(arr) {
        *slot = number(doc, item)?;
        if !slot.is_finite() {
            return None;
        }
    }
    let r = [
        v[0].min(v[2]),
        v[1].min(v[3]),
        v[0].max(v[2]),
        v[1].max(v[3]),
    ];
    (r[2] - r[0] >= 1.0 && r[3] - r[1] >= 1.0).then_some(r)
}

fn intersect(a: [f32; 4], b: [f32; 4]) -> Option<[f32; 4]> {
    let r = [
        a[0].max(b[0]),
        a[1].max(b[1]),
        a[2].min(b[2]),
        a[3].min(b[3]),
    ];
    (r[2] - r[0] >= 1.0 && r[3] - r[1] >= 1.0).then_some(r)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use pdf_writer::{Content, Finish, Pdf, Rect, Ref};

    /// Builds a small PDF: page 1 is A4 portrait, page 2 is A4 rotated by 90°, and both
    /// inherit their MediaBox from the page tree except where overridden.
    pub(crate) fn sample_pdf() -> Vec<u8> {
        let mut pdf = Pdf::new();
        let (catalog, tree, p1, p2, c1, c2) = (
            Ref::new(1),
            Ref::new(2),
            Ref::new(3),
            Ref::new(4),
            Ref::new(5),
            Ref::new(6),
        );
        pdf.catalog(catalog).pages(tree);
        pdf.pages(tree)
            .kids([p1, p2])
            .count(2)
            .media_box(Rect::new(0.0, 0.0, 595.0, 842.0));
        pdf.page(p1).parent(tree).contents(c1);
        let mut page2 = pdf.page(p2);
        page2.parent(tree).contents(c2).rotate(90);
        page2.crop_box(Rect::new(10.0, 20.0, 585.0, 822.0));
        page2.finish();
        let mut content = Content::new();
        content.set_fill_rgb(0.9, 0.2, 0.2);
        content.rect(50.0, 50.0, 200.0, 100.0);
        content.fill_nonzero();
        let data = content.finish();
        pdf.stream(c1, &data);
        pdf.stream(c2, &data);
        pdf.finish()
    }

    #[test]
    fn parses_pages_with_inherited_boxes_and_rotation() {
        let pdf = ImportedPdf::parse(sample_pdf()).unwrap();
        assert_eq!(pdf.page_count(), 2);
        assert_eq!(
            (pdf.pages[0].width_pt, pdf.pages[0].height_pt),
            (595.0, 842.0)
        );
        // Rotated: displayed width is the crop box height.
        assert_eq!(pdf.pages[1].rotation, 90);
        assert_eq!(
            (pdf.pages[1].width_pt, pdf.pages[1].height_pt),
            (802.0, 575.0)
        );

        let stack = pdf.page_stack();
        assert_eq!(stack.len(), 2);
        assert_eq!(stack.pages()[0].pdf_page, Some(0));
        assert!((stack.pages()[0].height - 1000.0 * 842.0 / 595.0).abs() < 0.01);
        assert!((stack.pages()[1].height - 1000.0 * 575.0 / 802.0).abs() < 0.01);
    }

    #[test]
    fn display_matrix_maps_crop_box_onto_the_displayed_page() {
        let g = PageGeometry {
            crop: [10.0, 20.0, 110.0, 220.0],
            rotation: 90,
        };
        let m = g.display_matrix();
        let apply = |x: f32, y: f32| (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]);
        let (w, h) = g.display_size();
        assert_eq!((w, h), (200.0, 100.0));
        // All four crop corners land on the displayed page's corners.
        let mut corners = [
            apply(10.0, 20.0),
            apply(110.0, 20.0),
            apply(110.0, 220.0),
            apply(10.0, 220.0),
        ];
        corners.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(
            corners,
            [(0.0, 0.0), (0.0, 100.0), (200.0, 0.0), (200.0, 100.0)]
        );
    }

    #[test]
    fn rejects_garbage() {
        assert!(ImportedPdf::parse(b"definitely not a pdf".to_vec()).is_err());
    }
}

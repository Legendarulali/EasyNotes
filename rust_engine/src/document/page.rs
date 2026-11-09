//! Fixed-size pages stacked vertically (continuous scroll).
//!
//! Notebook pages are exactly [`PAGE_WIDTH`] × [`PAGE_HEIGHT`] world units and sit directly
//! beneath each other, so page `n` spans `y ∈ [1000·n, 1000·(n+1))`. Pages imported from a
//! PDF keep the source page's aspect ratio at the same 1000-unit width (an A4 page becomes
//! 1000 × 1414), and blank pages appended after them are regular 1000 × 1000 pages.
//!
//! The stack only ever grows at the bottom: scrolling (or drawing) past the last page
//! appends a new one. Whiteboards have no pages at all: they are an unbounded canvas
//! towards +X / +Y.

use crate::geometry::ViewportRect;

pub const PAGE_WIDTH: f32 = 1000.0;
pub const PAGE_HEIGHT: f32 = 1000.0;
/// Hard cap so a runaway scroll gesture cannot create an unbounded document.
pub const MAX_PAGES: u32 = 2000;
/// Bounds for imported PDF page heights (extreme aspect ratios are clamped).
const MIN_PDF_PAGE_HEIGHT: f32 = 100.0;
const MAX_PDF_PAGE_HEIGHT: f32 = 20_000.0;

/// What kind of document the engine is editing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DocumentKind {
    /// Ruled / grid / blank paginated notebook.
    Notebook,
    /// Unbounded canvas (no pages, no right edge).
    Whiteboard,
    /// Imported PDF: one page per PDF page, written over as an annotation layer.
    PdfAnnotation,
}

impl DocumentKind {
    pub fn is_paged(self) -> bool {
        !matches!(self, DocumentKind::Whiteboard)
    }
}

/// One page of the vertical stack, in world units.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CanvasPage {
    pub index: u32,
    pub top: f32,
    pub width: f32,
    pub height: f32,
    /// 0-based page of the imported PDF drawn as this page's background.
    pub pdf_page: Option<u32>,
}

impl CanvasPage {
    pub fn bottom(&self) -> f32 {
        self.top + self.height
    }

    pub fn rect(&self) -> ViewportRect {
        ViewportRect::new(0.0, self.top, self.width, self.bottom())
    }
}

/// Ordered pages with cumulative `top` offsets (no gaps).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PageStack {
    pages: Vec<CanvasPage>,
}

impl PageStack {
    /// `count` blank 1000 × 1000 pages (at least one).
    pub fn blank(count: u32) -> Self {
        let mut s = Self::default();
        for _ in 0..count.clamp(1, MAX_PAGES) {
            s.push(PAGE_HEIGHT, None);
        }
        s
    }

    /// Pages described by `(height, pdf_page)` pairs, e.g. when loading a saved document.
    pub fn from_heights(heights: &[(f32, Option<u32>)]) -> Self {
        let mut s = Self::default();
        for &(h, pdf) in heights.iter().take(MAX_PAGES as usize) {
            let h = if h.is_finite() {
                h.clamp(MIN_PDF_PAGE_HEIGHT, MAX_PDF_PAGE_HEIGHT)
            } else {
                PAGE_HEIGHT
            };
            s.push(h, pdf);
        }
        s
    }

    /// One page per PDF page, `(width_pt, height_pt)` as displayed (rotation applied).
    pub fn from_pdf_sizes(sizes: &[(f32, f32)]) -> Self {
        let mut s = Self::default();
        for (i, &(w, h)) in sizes.iter().take(MAX_PAGES as usize).enumerate() {
            s.push(pdf_page_height(w, h), Some(i as u32));
        }
        if s.pages.is_empty() {
            s.push(PAGE_HEIGHT, None);
        }
        s
    }

    fn push(&mut self, height: f32, pdf_page: Option<u32>) {
        let top = self.total_height();
        self.pages.push(CanvasPage {
            index: self.pages.len() as u32,
            top,
            width: PAGE_WIDTH,
            height,
            pdf_page,
        });
    }

    pub fn pages(&self) -> &[CanvasPage] {
        &self.pages
    }

    pub fn len(&self) -> usize {
        self.pages.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pages.is_empty()
    }

    pub fn total_height(&self) -> f32 {
        self.pages.last().map_or(0.0, CanvasPage::bottom)
    }

    /// Appends one blank 1000 × 1000 page. Returns it, or `None` at [`MAX_PAGES`].
    pub fn append_blank(&mut self) -> Option<CanvasPage> {
        if self.pages.len() >= MAX_PAGES as usize {
            return None;
        }
        self.push(PAGE_HEIGHT, None);
        self.pages.last().copied()
    }

    /// Appends blank pages until `bottom` lies inside the stack. Returns how many were added.
    pub fn ensure_covers(&mut self, bottom: f32) -> usize {
        let mut added = 0;
        while bottom.is_finite() && bottom > self.total_height() && self.append_blank().is_some() {
            added += 1;
        }
        added
    }

    /// `true` when `y` lies within `margin` units of the bottom of the last page (or below it).
    pub fn is_near_end(&self, y: f32, margin: f32) -> bool {
        y.is_finite() && y >= self.total_height() - margin.clamp(0.0, PAGE_HEIGHT)
    }

    /// Removes blank pages (no PDF background) from the end of the stack while they start
    /// at or below `content_bottom`, keeping at least `min_len` pages. Returns how many
    /// pages were removed.
    pub fn trim_trailing_blank(&mut self, content_bottom: f32, min_len: usize) -> usize {
        let before = self.pages.len();
        while self.pages.len() > min_len.max(1) {
            match self.pages.last() {
                Some(p) if p.pdf_page.is_none() && p.top >= content_bottom => {
                    self.pages.pop();
                }
                _ => break,
            }
        }
        before - self.pages.len()
    }

    /// Index of the page containing `y` (clamped to the first / last page).
    pub fn page_index_at(&self, y: f32) -> Option<usize> {
        if self.pages.is_empty() {
            return None;
        }
        let i = self.pages.partition_point(|p| p.bottom() <= y);
        Some(i.min(self.pages.len() - 1))
    }

    /// Pages overlapping the world rectangle `r`.
    pub fn intersecting<'a>(
        &'a self,
        r: &'a ViewportRect,
    ) -> impl Iterator<Item = &'a CanvasPage> + 'a {
        let start = self.page_index_at(r.top).unwrap_or(0);
        self.pages[start.min(self.pages.len())..]
            .iter()
            .take_while(move |p| p.top <= r.bottom)
    }

    /// Hard page boundary for input: x is kept on the page, y may reach one page past the
    /// end (that page is appended once the stroke is committed).
    pub fn clamp_point(&self, x: f32, y: f32) -> (f32, f32) {
        let max_y = self.total_height() + PAGE_HEIGHT;
        (x.clamp(0.0, PAGE_WIDTH), y.clamp(0.0, max_y))
    }
}

/// World height of an imported PDF page scaled to the 1000-unit page width.
pub fn pdf_page_height(width_pt: f32, height_pt: f32) -> f32 {
    if !(width_pt.is_finite() && height_pt.is_finite()) || width_pt <= 0.0 || height_pt <= 0.0 {
        return PAGE_HEIGHT;
    }
    (PAGE_WIDTH * height_pt / width_pt).clamp(MIN_PDF_PAGE_HEIGHT, MAX_PDF_PAGE_HEIGHT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_pages_are_1000_square_and_stacked_without_gaps() {
        let s = PageStack::blank(3);
        assert_eq!(s.len(), 3);
        for (i, p) in s.pages().iter().enumerate() {
            assert_eq!(p.width, 1000.0);
            assert_eq!(p.height, 1000.0);
            assert_eq!(p.top, 1000.0 * i as f32);
        }
        assert_eq!(s.total_height(), 3000.0);
        assert_eq!(s.page_index_at(0.0), Some(0));
        assert_eq!(s.page_index_at(999.9), Some(0));
        assert_eq!(s.page_index_at(1000.0), Some(1));
        assert_eq!(s.page_index_at(99_999.0), Some(2));
    }

    #[test]
    fn appends_pages_to_cover_content_below_the_end() {
        let mut s = PageStack::blank(1);
        assert_eq!(s.ensure_covers(900.0), 0);
        assert_eq!(s.ensure_covers(2500.0), 2);
        assert_eq!(s.len(), 3);
        assert_eq!(s.pages()[2].top, 2000.0);
    }

    #[test]
    fn pdf_pages_keep_their_aspect_ratio() {
        let s = PageStack::from_pdf_sizes(&[(595.0, 842.0), (842.0, 595.0)]);
        assert!((s.pages()[0].height - 1415.1).abs() < 0.5);
        assert!((s.pages()[1].height - 706.6).abs() < 0.5);
        assert_eq!(s.pages()[1].top, s.pages()[0].height);
        assert_eq!(s.pages()[1].pdf_page, Some(1));
    }

    #[test]
    fn clamp_keeps_points_on_the_page() {
        let s = PageStack::blank(2);
        assert_eq!(s.clamp_point(-5.0, -5.0), (0.0, 0.0));
        assert_eq!(s.clamp_point(1500.0, 99_999.0), (1000.0, 3000.0));
        let r = ViewportRect::new(0.0, 900.0, 10.0, 1100.0);
        assert_eq!(s.intersecting(&r).count(), 2);
    }

    #[test]
    fn near_end_detection_uses_the_bottom_of_the_last_page() {
        let s = PageStack::blank(2);
        assert!(!s.is_near_end(1949.0, 50.0));
        assert!(s.is_near_end(1950.0, 50.0));
        assert!(s.is_near_end(2600.0, 50.0));
        assert!(!s.is_near_end(f32::NAN, 50.0));
    }

    #[test]
    fn trimming_keeps_written_pdf_and_first_pages() {
        let mut s = PageStack::blank(5);
        // Content reaches into page 2 (index 1): pages 3–5 are blank.
        assert_eq!(s.trim_trailing_blank(1200.0, 1), 3);
        assert_eq!(s.len(), 2);
        // An empty notebook keeps its first page.
        let mut empty = PageStack::blank(4);
        assert_eq!(empty.trim_trailing_blank(0.0, 1), 3);
        assert_eq!(empty.len(), 1);
        // Imported PDF pages are never removed, only blank pages appended after them.
        let mut pdf = PageStack::from_pdf_sizes(&[(595.0, 842.0), (595.0, 842.0)]);
        pdf.append_blank();
        pdf.append_blank();
        assert_eq!(pdf.trim_trailing_blank(0.0, 1), 2);
        assert_eq!(pdf.len(), 2);
    }

    #[test]
    fn page_count_is_capped() {
        let mut s = PageStack::blank(MAX_PAGES);
        assert!(s.append_blank().is_none());
    }
}

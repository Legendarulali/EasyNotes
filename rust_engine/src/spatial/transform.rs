//! Bounding-box transformation algorithms for the selection engine (scale + drag).

use crate::geometry::{TransformMatrix, ViewportRect};

/// Smallest allowed scale factor (prevents collapsing / flipping a selection).
pub const MIN_SCALE: f32 = 0.02;
pub const MAX_SCALE: f32 = 50.0;

/// Maps a selection's bounding box onto a new one:
/// `p' = origin + (p - origin) · scale + delta`, with `origin` = the box's top-left corner.
///
/// Any corner-handle resize can be expressed this way: e.g. dragging the top-left handle
/// with the bottom-right corner pinned is a scale about the top-left plus a translation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundsTransform {
    pub origin_x: f32,
    pub origin_y: f32,
    pub scale_x: f32,
    pub scale_y: f32,
    pub dx: f32,
    pub dy: f32,
}

impl BoundsTransform {
    pub fn new(bounds: &ViewportRect, scale_x: f32, scale_y: f32, dx: f32, dy: f32) -> Self {
        let sane = |s: f32| {
            if s.is_finite() {
                s.abs().clamp(MIN_SCALE, MAX_SCALE)
            } else {
                1.0
            }
        };
        let finite = |v: f32| if v.is_finite() { v } else { 0.0 };
        Self {
            origin_x: bounds.left,
            origin_y: bounds.top,
            scale_x: sane(scale_x),
            scale_y: sane(scale_y),
            dx: finite(dx),
            dy: finite(dy),
        }
    }

    pub fn is_identity(&self) -> bool {
        self.scale_x == 1.0 && self.scale_y == 1.0 && self.dx == 0.0 && self.dy == 0.0
    }

    pub fn matrix(&self) -> TransformMatrix {
        TransformMatrix::scale_about(
            self.origin_x,
            self.origin_y,
            self.scale_x,
            self.scale_y,
            self.dx,
            self.dy,
        )
    }

    pub fn apply_rect(&self, r: &ViewportRect) -> ViewportRect {
        let m = self.matrix();
        let a = m.apply(crate::geometry::Vec2::new(r.left, r.top));
        let b = m.apply(crate::geometry::Vec2::new(r.right, r.bottom));
        ViewportRect::new(a.x, a.y, b.x, b.y)
    }

    /// Hard boundary: shifts the translation so the transformed `bounds` never crosses
    /// into negative coordinates (the canvas only extends right and down).
    pub fn clamped_to_positive(mut self, bounds: &ViewportRect) -> Self {
        let out = self.apply_rect(bounds);
        if out.left < 0.0 {
            self.dx -= out.left;
        }
        if out.top < 0.0 {
            self.dy -= out.top;
        }
        self
    }

    /// Page column boundary: shifts the translation left so the transformed `bounds` ends
    /// at `max_x` at the latest, without ever pushing its left edge below 0 (a selection
    /// wider than the page stays left-aligned).
    pub fn clamped_to_width(mut self, bounds: &ViewportRect, max_x: f32) -> Self {
        let out = self.apply_rect(bounds);
        let overflow = out.right - max_x;
        if overflow > 0.0 {
            self.dx -= overflow.min(out.left.max(0.0));
        }
        self
    }

    /// Isotropic factor used for text and stroke widths.
    pub fn uniform_scale(&self) -> f32 {
        (self.scale_x * self.scale_y).sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_about_top_left_then_translate() {
        let b = ViewportRect::new(100.0, 100.0, 200.0, 150.0);
        let t = BoundsTransform::new(&b, 2.0, 0.5, 10.0, -5.0);
        let out = t.apply_rect(&b);
        assert_eq!(out, ViewportRect::new(110.0, 95.0, 310.0, 120.0));
    }

    #[test]
    fn clamps_negative_moves() {
        let b = ViewportRect::new(10.0, 10.0, 50.0, 50.0);
        let t = BoundsTransform::new(&b, 1.0, 1.0, -100.0, -3.0).clamped_to_positive(&b);
        let out = t.apply_rect(&b);
        assert_eq!(out.left, 0.0);
        assert_eq!(out.top, 7.0);
    }

    #[test]
    fn clamps_to_the_page_column() {
        let b = ViewportRect::new(900.0, 10.0, 950.0, 50.0);
        let t = BoundsTransform::new(&b, 1.0, 1.0, 200.0, 0.0).clamped_to_width(&b, 1000.0);
        assert_eq!(t.apply_rect(&b).right, 1000.0);
        // Wider than the page: stays left-aligned instead of going negative.
        let wide = ViewportRect::new(0.0, 0.0, 800.0, 10.0);
        let t = BoundsTransform::new(&wide, 2.0, 1.0, 0.0, 0.0).clamped_to_width(&wide, 1000.0);
        assert_eq!(t.apply_rect(&wide).left, 0.0);
    }
}

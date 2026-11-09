//! Basic geometric primitives shared by the whole engine.
//!
//! Coordinate system: world units, origin at the top-left of the page, X grows to the
//! right and Y grows downwards (same as Flutter). One world unit is one CSS pixel
//! (1/96 inch), which keeps the paper grids physically meaningful for PDF export.

use std::ops::{Add, Mul, Sub};

/// A single input sample coming from the stylus / finger / mouse.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StrokePoint {
    pub x: f32,
    pub y: f32,
    /// Normalised pressure in `0.0..=1.0`. Devices without pressure should send `0.5`,
    /// which maps to the brush's nominal width and opacity.
    pub pressure: f32,
}

impl StrokePoint {
    pub fn new(x: f32, y: f32, pressure: f32) -> Self {
        Self { x, y, pressure }
    }

    pub fn pos(&self) -> Vec2 {
        Vec2::new(self.x, self.y)
    }
}

/// Axis-aligned rectangle in world coordinates (`left <= right`, `top <= bottom`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ViewportRect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

impl ViewportRect {
    pub fn new(left: f32, top: f32, right: f32, bottom: f32) -> Self {
        Self {
            left,
            top,
            right,
            bottom,
        }
        .normalized()
    }

    pub fn from_xywh(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self::new(x, y, x + w, y + h)
    }

    /// Swaps edges if the rectangle was given "inside out" (e.g. a drag from bottom-right to top-left).
    pub fn normalized(self) -> Self {
        Self {
            left: self.left.min(self.right),
            top: self.top.min(self.bottom),
            right: self.left.max(self.right),
            bottom: self.top.max(self.bottom),
        }
    }

    /// Bounding box of a point cloud. Returns `None` for an empty iterator.
    pub fn from_points<I: IntoIterator<Item = Vec2>>(points: I) -> Option<Self> {
        let mut it = points.into_iter();
        let first = it.next()?;
        let mut r = Self {
            left: first.x,
            top: first.y,
            right: first.x,
            bottom: first.y,
        };
        for p in it {
            r.left = r.left.min(p.x);
            r.top = r.top.min(p.y);
            r.right = r.right.max(p.x);
            r.bottom = r.bottom.max(p.y);
        }
        Some(r)
    }

    pub fn width(&self) -> f32 {
        self.right - self.left
    }

    pub fn height(&self) -> f32 {
        self.bottom - self.top
    }

    pub fn center(&self) -> Vec2 {
        Vec2::new(
            (self.left + self.right) * 0.5,
            (self.top + self.bottom) * 0.5,
        )
    }

    pub fn inflate(&self, d: f32) -> Self {
        Self {
            left: self.left - d,
            top: self.top - d,
            right: self.right + d,
            bottom: self.bottom + d,
        }
    }

    pub fn union(&self, o: &Self) -> Self {
        Self {
            left: self.left.min(o.left),
            top: self.top.min(o.top),
            right: self.right.max(o.right),
            bottom: self.bottom.max(o.bottom),
        }
    }

    pub fn intersects(&self, o: &Self) -> bool {
        self.left <= o.right && o.left <= self.right && self.top <= o.bottom && o.top <= self.bottom
    }

    /// `true` if `o` lies completely inside `self`.
    pub fn contains_rect(&self, o: &Self) -> bool {
        o.left >= self.left && o.right <= self.right && o.top >= self.top && o.bottom <= self.bottom
    }

    pub fn contains(&self, p: Vec2) -> bool {
        p.x >= self.left && p.x <= self.right && p.y >= self.top && p.y <= self.bottom
    }

    pub fn translate(&self, dx: f32, dy: f32) -> Self {
        Self {
            left: self.left + dx,
            top: self.top + dy,
            right: self.right + dx,
            bottom: self.bottom + dy,
        }
    }
}

/// Lightweight 2D vector used internally by the geometry algorithms.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}

impl Vec2 {
    pub const ZERO: Vec2 = Vec2 { x: 0.0, y: 0.0 };

    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn from_angle(a: f32) -> Self {
        Self::new(a.cos(), a.sin())
    }

    pub fn dot(self, o: Self) -> f32 {
        self.x * o.x + self.y * o.y
    }

    /// Z component of the 3D cross product.
    pub fn cross(self, o: Self) -> f32 {
        self.x * o.y - self.y * o.x
    }

    pub fn length(self) -> f32 {
        self.x.hypot(self.y)
    }

    pub fn distance(self, o: Self) -> f32 {
        (self - o).length()
    }

    pub fn normalized(self) -> Self {
        let l = self.length();
        if l <= f32::EPSILON {
            Self::ZERO
        } else {
            Self::new(self.x / l, self.y / l)
        }
    }

    /// Rotates the vector by +90° (in a Y-down system this points to the right of travel).
    pub fn perp(self) -> Self {
        Self::new(-self.y, self.x)
    }

    pub fn angle(self) -> f32 {
        self.y.atan2(self.x)
    }

    pub fn rotate(self, angle: f32) -> Self {
        let (s, c) = angle.sin_cos();
        Self::new(self.x * c - self.y * s, self.x * s + self.y * c)
    }

    pub fn lerp(self, o: Self, t: f32) -> Self {
        self + (o - self) * t
    }
}

impl Add for Vec2 {
    type Output = Vec2;
    fn add(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x + o.x, self.y + o.y)
    }
}

impl Sub for Vec2 {
    type Output = Vec2;
    fn sub(self, o: Vec2) -> Vec2 {
        Vec2::new(self.x - o.x, self.y - o.y)
    }
}

impl Mul<f32> for Vec2 {
    type Output = Vec2;
    fn mul(self, s: f32) -> Vec2 {
        Vec2::new(self.x * s, self.y * s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rect_normalizes_and_intersects() {
        let r = ViewportRect::new(10.0, 10.0, 0.0, 0.0);
        assert_eq!(r, ViewportRect::new(0.0, 0.0, 10.0, 10.0));
        assert!(r.intersects(&ViewportRect::new(5.0, 5.0, 20.0, 20.0)));
        assert!(!r.intersects(&ViewportRect::new(11.0, 0.0, 20.0, 5.0)));
        assert!(r.contains_rect(&ViewportRect::new(1.0, 1.0, 9.0, 9.0)));
    }
}

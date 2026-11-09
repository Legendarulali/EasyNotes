//! Sticky notes: independent, movable and resizable canvas objects.

use super::point::ViewportRect;

pub const MIN_NOTE_SIZE: f32 = 48.0;
pub const DEFAULT_NOTE_FONT_SIZE: f32 = 16.0;

#[derive(Debug, Clone, PartialEq)]
pub struct StickyNote {
    pub id: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    /// ARGB background colour.
    pub color: u32,
    pub text: String,
    pub font_size: f32,
}

impl StickyNote {
    pub fn rect(&self) -> ViewportRect {
        ViewportRect::from_xywh(self.x, self.y, self.width, self.height)
    }

    /// Enforces the engine's invariants: positive quadrant, minimum size, sane font.
    pub fn sanitized(mut self) -> Self {
        let finite_or = |v: f32, d: f32| if v.is_finite() { v } else { d };
        self.x = finite_or(self.x, 0.0).max(0.0);
        self.y = finite_or(self.y, 0.0).max(0.0);
        self.width = finite_or(self.width, 180.0).max(MIN_NOTE_SIZE);
        self.height = finite_or(self.height, 140.0).max(MIN_NOTE_SIZE);
        self.font_size = finite_or(self.font_size, DEFAULT_NOTE_FONT_SIZE).clamp(6.0, 200.0);
        self
    }
}

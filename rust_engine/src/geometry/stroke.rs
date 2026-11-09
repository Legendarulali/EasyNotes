//! Stroke model, tool profiles and render-geometry generation.
//!
//! A [`Stroke`] stores its points in *local* space plus an affine `transform_matrix`
//! (world = M · local). Transforms from the selection engine only touch the matrix, so
//! moving or resizing thousands of points is O(1) per stroke until geometry is rebuilt.

use super::outline::{build_outline, flatten};
use super::point::{StrokePoint, Vec2, ViewportRect};

/// Drawing tools understood by the engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ToolType {
    /// Solid ink, pressure-sensitive width and opacity.
    Pen,
    /// Textured, semi-translucent graphite with soft pressure scaling.
    Pencil,
    /// Wide semi-transparent marker, rendered beneath ink with multiply blending.
    Highlighter,
    /// Stroke eraser.
    Eraser,
    /// Places sticky notes; never produces strokes.
    StickyNote,
}

impl ToolType {
    /// Whether this tool produces ink strokes.
    pub fn is_ink(self) -> bool {
        matches!(
            self,
            ToolType::Pen | ToolType::Pencil | ToolType::Highlighter
        )
    }

    /// Width multiplier for a given pressure. Calibrated so `pressure = 0.5` yields 1.0,
    /// i.e. devices without pressure draw at the nominal brush width.
    pub fn width_factor(self, pressure: f32) -> f32 {
        let p = pressure.clamp(0.0, 1.0);
        match self {
            ToolType::Pen => 0.45 + 1.1 * p,
            // "Soft" scaling: graphite thickens only slightly when pressed harder.
            ToolType::Pencil => 0.75 + 0.5 * p,
            _ => 1.0,
        }
    }

    /// Opacity multiplier for the stroke's mean pressure.
    pub fn opacity_factor(self, mean_pressure: f32) -> f32 {
        let p = mean_pressure.clamp(0.0, 1.0);
        match self {
            ToolType::Pen => (0.8 + 0.4 * p).min(1.0),
            ToolType::Pencil => (0.35 + 0.9 * p).min(0.95),
            _ => 1.0,
        }
    }
}

/// Brush parameters chosen in the UI for the stroke being drawn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Brush {
    /// ARGB colour (`0xAARRGGBB`).
    pub color: u32,
    /// Nominal stroke width in world units.
    pub width: f32,
    /// Base opacity `0..=1` (e.g. ~0.35 for the highlighter).
    pub opacity: f32,
}

impl Default for Brush {
    fn default() -> Self {
        Self {
            color: 0xFF1A1A1A,
            width: 3.0,
            opacity: 1.0,
        }
    }
}

/// Recognised geometric intent of a stroke.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShapeKind {
    Freehand,
    /// Auto-corrected rectangle: points are the 4 corners plus the closing corner.
    Rectangle,
    /// Open piece of a geometric shape (e.g. a rectangle cut by the partial eraser):
    /// straight segments drawn with constant width and sharp (miter) corners.
    Polyline,
}

/// 2D affine transform. `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TransformMatrix {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub tx: f32,
    pub ty: f32,
}

impl Default for TransformMatrix {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl TransformMatrix {
    pub const IDENTITY: TransformMatrix = TransformMatrix {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        tx: 0.0,
        ty: 0.0,
    };

    pub fn translation(dx: f32, dy: f32) -> Self {
        Self {
            tx: dx,
            ty: dy,
            ..Self::IDENTITY
        }
    }

    /// Scale about `(ox, oy)` followed by a translation of `(dx, dy)`:
    /// `p' = o + (p - o)·s + d`.
    pub fn scale_about(ox: f32, oy: f32, sx: f32, sy: f32, dx: f32, dy: f32) -> Self {
        Self {
            a: sx,
            b: 0.0,
            c: 0.0,
            d: sy,
            tx: ox - ox * sx + dx,
            ty: oy - oy * sy + dy,
        }
    }

    pub fn apply(&self, p: Vec2) -> Vec2 {
        Vec2::new(
            self.a * p.x + self.c * p.y + self.tx,
            self.b * p.x + self.d * p.y + self.ty,
        )
    }

    /// Returns `other ∘ self` (apply `self` first, then `other`).
    pub fn then(&self, o: &TransformMatrix) -> TransformMatrix {
        TransformMatrix {
            a: o.a * self.a + o.c * self.b,
            b: o.b * self.a + o.d * self.b,
            c: o.a * self.c + o.c * self.d,
            d: o.b * self.c + o.d * self.d,
            tx: o.a * self.tx + o.c * self.ty + o.tx,
            ty: o.b * self.tx + o.d * self.ty + o.ty,
        }
    }

    /// Isotropic scale factor used to scale stroke widths (`sqrt(|det|)`).
    pub fn width_scale(&self) -> f32 {
        (self.a * self.d - self.b * self.c).abs().sqrt()
    }

    pub fn is_identity(&self) -> bool {
        *self == Self::IDENTITY
    }
}

/// How Flutter / the PDF exporter should draw a [`StrokeRender`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderKind {
    /// `geometry` is a closed outline polygon: fill it with the non-zero rule.
    FilledOutline,
    /// `geometry` is a centre line: stroke it with `width`, square caps, round joins.
    OpenPolyline,
    /// `geometry` is a closed polygon (geometric shape): stroke it with `width` and miter joins.
    ClosedPolygon,
    /// `geometry` is an open piece of a geometric shape: stroke it with `width`, miter
    /// joins and butt caps.
    OpenShape,
}

/// Render-ready, world-space geometry for one stroke. This is what crosses the FFI
/// boundary for drawing, so Flutter never re-implements tessellation.
#[derive(Debug, Clone, PartialEq)]
pub struct StrokeRender {
    pub id: String,
    pub tool: ToolType,
    pub kind: RenderKind,
    /// ARGB colour.
    pub color: u32,
    /// Final opacity `0..=1` (brush opacity × pressure factor).
    pub opacity: f32,
    /// Stroke width for `OpenPolyline` / `ClosedPolygon` (world units).
    pub width: f32,
    /// Flattened `[x0, y0, x1, y1, ...]` world coordinates.
    pub geometry: Vec<f32>,
    pub bounds: ViewportRect,
}

/// A committed ink stroke.
#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub id: String,
    /// Local-space points (already cleaned and smoothed).
    pub points: Vec<StrokePoint>,
    /// ARGB colour.
    pub color: u32,
    /// Nominal width in local units.
    pub width: f32,
    /// Final stroke opacity.
    pub alpha: f32,
    pub tool_type: ToolType,
    pub transform_matrix: TransformMatrix,
    pub shape: ShapeKind,
}

impl Stroke {
    /// Points with `transform_matrix` applied.
    pub fn world_points(&self) -> Vec<StrokePoint> {
        if self.transform_matrix.is_identity() {
            return self.points.clone();
        }
        self.points
            .iter()
            .map(|p| {
                let w = self.transform_matrix.apply(p.pos());
                StrokePoint::new(w.x, w.y, p.pressure)
            })
            .collect()
    }

    /// Nominal width after the transform's isotropic scale.
    pub fn world_width(&self) -> f32 {
        self.width * self.transform_matrix.width_scale()
    }

    fn mean_pressure(&self) -> f32 {
        if self.points.is_empty() {
            return 0.5;
        }
        self.points.iter().map(|p| p.pressure).sum::<f32>() / self.points.len() as f32
    }

    /// Constant width used for polyline / polygon renderings.
    fn constant_width(&self) -> f32 {
        self.world_width() * self.tool_type.width_factor(self.mean_pressure())
    }

    /// Largest half-width this stroke can be drawn with (for bounds and hit testing).
    pub fn max_half_width(&self) -> f32 {
        let max_factor = match self.render_kind() {
            RenderKind::FilledOutline => self
                .points
                .iter()
                .map(|p| self.tool_type.width_factor(p.pressure))
                .fold(0.0f32, f32::max),
            _ => self.tool_type.width_factor(self.mean_pressure()),
        };
        // Square caps / miter joins can extend up to ~0.71·w beyond the centre line.
        0.75 * self.world_width() * max_factor.max(0.1)
    }

    pub fn render_kind(&self) -> RenderKind {
        match (self.shape, self.tool_type) {
            (ShapeKind::Rectangle, _) => RenderKind::ClosedPolygon,
            (ShapeKind::Polyline, _) => RenderKind::OpenShape,
            (_, ToolType::Highlighter) => RenderKind::OpenPolyline,
            _ => RenderKind::FilledOutline,
        }
    }

    /// World-space bounding box including the stroke's thickness.
    pub fn bounds(&self) -> ViewportRect {
        let pts = self.world_points();
        ViewportRect::from_points(pts.iter().map(|p| p.pos()))
            .unwrap_or(ViewportRect::new(0.0, 0.0, 0.0, 0.0))
            .inflate(self.max_half_width() + 0.5)
    }

    pub fn render(&self) -> StrokeRender {
        let world = self.world_points();
        let kind = self.render_kind();
        let geometry = match kind {
            RenderKind::FilledOutline => {
                let scale = self.world_width();
                let samples: Vec<(Vec2, f32)> = world
                    .iter()
                    .map(|p| {
                        (
                            p.pos(),
                            0.5 * scale * self.tool_type.width_factor(p.pressure),
                        )
                    })
                    .collect();
                flatten(&build_outline(&samples))
            }
            RenderKind::OpenPolyline | RenderKind::OpenShape => flatten_points(&world),
            RenderKind::ClosedPolygon => {
                let mut pts = world;
                // Drop the explicit closing point; the renderer closes the path itself.
                if pts.len() > 2 && pts.first().map(|p| p.pos()) == pts.last().map(|p| p.pos()) {
                    pts.pop();
                }
                flatten_points(&pts)
            }
        };
        StrokeRender {
            id: self.id.clone(),
            tool: self.tool_type,
            kind,
            color: self.color,
            opacity: self.alpha,
            width: self.constant_width(),
            geometry,
            bounds: self.bounds(),
        }
    }
}

fn flatten_points(points: &[StrokePoint]) -> Vec<f32> {
    let mut out = Vec::with_capacity(points.len() * 2);
    for p in points {
        out.push(p.x);
        out.push(p.y);
    }
    out
}

/// Cleans raw input: clamps to the positive quadrant, drops near-duplicate samples and
/// applies a light `[1 2 1]` smoothing to positions and pressure (endpoints are kept).
pub fn process_input(raw: &[StrokePoint], width: f32) -> Vec<StrokePoint> {
    let min_spacing = (0.12 * width).clamp(0.35, 2.0);
    let mut pts: Vec<StrokePoint> = Vec::with_capacity(raw.len());
    for p in raw {
        if !(p.x.is_finite() && p.y.is_finite()) {
            continue;
        }
        let q = StrokePoint::new(p.x.max(0.0), p.y.max(0.0), sanitize_pressure(p.pressure));
        match pts.last() {
            Some(last) if last.pos().distance(q.pos()) < min_spacing => {
                // Keep the strongest pressure of merged samples so dots don't vanish.
                let l = pts.last_mut().unwrap();
                l.pressure = l.pressure.max(q.pressure);
            }
            _ => pts.push(q),
        }
    }
    // Make sure the very last sample (where the pen lifted) is represented.
    if let (Some(last_raw), Some(last)) = (raw.last(), pts.last()) {
        let q = StrokePoint::new(
            last_raw.x.max(0.0),
            last_raw.y.max(0.0),
            sanitize_pressure(last_raw.pressure),
        );
        if q.pos() != last.pos() && q.x.is_finite() && q.y.is_finite() && pts.len() > 1 {
            *pts.last_mut().unwrap() = q;
        }
    }
    if pts.len() < 3 {
        return pts;
    }
    let mut smoothed = pts.clone();
    for i in 1..pts.len() - 1 {
        let (a, b, c) = (pts[i - 1], pts[i], pts[i + 1]);
        smoothed[i] = StrokePoint::new(
            (a.x + 2.0 * b.x + c.x) * 0.25,
            (a.y + 2.0 * b.y + c.y) * 0.25,
            (a.pressure + 2.0 * b.pressure + c.pressure) * 0.25,
        );
    }
    smoothed
}

fn sanitize_pressure(p: f32) -> f32 {
    if p.is_finite() {
        p.clamp(0.0, 1.0)
    } else {
        0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stroke(points: Vec<StrokePoint>, tool: ToolType) -> Stroke {
        Stroke {
            id: "s1".into(),
            points,
            color: 0xFF000000,
            width: 4.0,
            alpha: 1.0,
            tool_type: tool,
            transform_matrix: TransformMatrix::IDENTITY,
            shape: ShapeKind::Freehand,
        }
    }

    #[test]
    fn matrix_composition_matches_sequential_application() {
        let m1 = TransformMatrix::scale_about(10.0, 10.0, 2.0, 3.0, 5.0, -1.0);
        let m2 = TransformMatrix::translation(7.0, 9.0);
        let p = Vec2::new(13.0, 4.0);
        let seq = m2.apply(m1.apply(p));
        let comp = m1.then(&m2).apply(p);
        assert!((seq.x - comp.x).abs() < 1e-4 && (seq.y - comp.y).abs() < 1e-4);
    }

    #[test]
    fn render_kinds_follow_tool_and_shape() {
        let pts = vec![
            StrokePoint::new(0.0, 0.0, 0.5),
            StrokePoint::new(10.0, 0.0, 0.5),
        ];
        assert_eq!(
            stroke(pts.clone(), ToolType::Pen).render().kind,
            RenderKind::FilledOutline
        );
        assert_eq!(
            stroke(pts.clone(), ToolType::Highlighter).render().kind,
            RenderKind::OpenPolyline
        );
        let mut s = stroke(pts, ToolType::Pencil);
        s.shape = ShapeKind::Rectangle;
        assert_eq!(s.render().kind, RenderKind::ClosedPolygon);
        s.shape = ShapeKind::Polyline;
        assert_eq!(s.render().kind, RenderKind::OpenShape);
    }

    #[test]
    fn transformed_bounds_follow_matrix() {
        let mut s = stroke(
            vec![
                StrokePoint::new(10.0, 10.0, 0.5),
                StrokePoint::new(20.0, 20.0, 0.5),
            ],
            ToolType::Pen,
        );
        s.transform_matrix = TransformMatrix::translation(100.0, 50.0);
        let b = s.bounds();
        assert!(b.left > 100.0 && b.top > 50.0 && b.right < 130.0);
    }

    #[test]
    fn process_input_clamps_and_dedupes() {
        let raw = vec![
            StrokePoint::new(-5.0, 3.0, 0.5),
            StrokePoint::new(-5.0, 3.0, 0.9),
            StrokePoint::new(10.0, 3.0, 0.5),
            StrokePoint::new(20.0, 3.0, f32::NAN),
        ];
        let out = process_input(&raw, 3.0);
        assert_eq!(out.len(), 3);
        assert!(out.iter().all(|p| p.x >= 0.0 && p.pressure <= 1.0));
    }
}

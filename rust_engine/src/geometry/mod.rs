pub mod outline;
pub mod point;
pub mod shape_detector;
pub mod sticky_note;
pub mod stroke;

pub use point::{StrokePoint, Vec2, ViewportRect};
pub use shape_detector::detect_and_snap_rectangle;
pub use sticky_note::StickyNote;
pub use stroke::{Brush, RenderKind, ShapeKind, Stroke, StrokeRender, ToolType, TransformMatrix};

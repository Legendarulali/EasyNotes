//! Paper styles. The specification lives in Rust so the Flutter canvas and the PDF
//! exporter draw byte-for-byte identical grids.

/// World units per millimetre (1 unit = 1/96 inch).
pub const UNITS_PER_MM: f32 = 96.0 / 25.4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PaperStyle {
    /// Plain white board.
    Whiteboard,
    /// Ruled paper ("dictando") with a left margin line.
    Dictando,
    /// 5 mm square grid ("matematică").
    Matematica,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperKind {
    Plain,
    Lined,
    Grid,
}

/// Geometry and colours of a paper style, in world units / ARGB.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PaperSpec {
    pub kind: PaperKind,
    pub background: u32,
    pub line_color: u32,
    /// Distance between lines (lined) or grid cells (grid).
    pub spacing: f32,
    pub line_width: f32,
    /// Y of the first ruled line (lined paper).
    pub first_line_y: f32,
    /// X of the vertical margin line, `0` when there is none.
    pub margin_x: f32,
    pub margin_color: u32,
}

impl PaperStyle {
    pub fn spec(self) -> PaperSpec {
        match self {
            PaperStyle::Whiteboard => PaperSpec {
                kind: PaperKind::Plain,
                background: 0xFFFFFFFF,
                line_color: 0x00000000,
                spacing: 0.0,
                line_width: 0.0,
                first_line_y: 0.0,
                margin_x: 0.0,
                margin_color: 0x00000000,
            },
            PaperStyle::Dictando => PaperSpec {
                kind: PaperKind::Lined,
                background: 0xFFFFFEF8,
                line_color: 0xFF9DB8D9,
                spacing: 8.0 * UNITS_PER_MM,
                line_width: 0.9,
                first_line_y: 20.0 * UNITS_PER_MM,
                margin_x: 25.0 * UNITS_PER_MM,
                margin_color: 0xFFE57373,
            },
            PaperStyle::Matematica => PaperSpec {
                kind: PaperKind::Grid,
                background: 0xFFFFFFFF,
                line_color: 0xFFB5CBE3,
                spacing: 5.0 * UNITS_PER_MM,
                line_width: 0.7,
                first_line_y: 0.0,
                margin_x: 0.0,
                margin_color: 0x00000000,
            },
        }
    }
}

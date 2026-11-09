//! Notebook persistence: a small, versioned, zlib-compressed JSON format.
//!
//! ```text
//! file := MAGIC (8 bytes) || zlib(JSON(StoredDocument))
//! ```
//!
//! Enum values are stored as stable strings (not Rust variant indices), coordinates are
//! rounded to 1/100 unit, and every field added later must be `#[serde(default)]`, so
//! older files keep loading. Imported PDFs are stored next to the document by the app;
//! only page indices into them are serialised here.

use super::page::{CanvasPage, DocumentKind, PageStack};
use super::paper::PaperStyle;
use crate::geometry::{ShapeKind, StickyNote, Stroke, StrokePoint, ToolType, TransformMatrix};
use anyhow::{bail, Context, Result};
use miniz_oxide::deflate::compress_to_vec_zlib;
use miniz_oxide::inflate::decompress_to_vec_zlib_with_limit;
use serde::{Deserialize, Serialize};

pub const MAGIC: &[u8; 8] = b"EZNOTE\x01\n";
pub const FORMAT_VERSION: u32 = 1;
/// Decompressed size limit (protects against corrupt / hostile files).
const MAX_JSON_BYTES: usize = 1 << 30;

/// Everything that makes up a saved document (cloned out of the engine).
#[derive(Debug, Clone, PartialEq)]
pub struct DocumentData {
    pub kind: DocumentKind,
    pub paper: PaperStyle,
    pub pages: Vec<CanvasPage>,
    pub strokes: Vec<Stroke>,
    pub notes: Vec<StickyNote>,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredDocument {
    version: u32,
    kind: String,
    paper: String,
    #[serde(default)]
    pages: Vec<StoredPage>,
    #[serde(default)]
    strokes: Vec<StoredStroke>,
    #[serde(default)]
    notes: Vec<StoredNote>,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredPage {
    height: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pdf_page: Option<u32>,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredStroke {
    tool: String,
    #[serde(default = "freehand")]
    shape: String,
    color: u32,
    width: f32,
    alpha: f32,
    #[serde(default = "identity")]
    transform: [f32; 6],
    /// Flattened `[x, y, pressure, ...]` local-space samples.
    points: Vec<f32>,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredNote {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: u32,
    #[serde(default)]
    text: String,
    #[serde(default = "default_font_size")]
    font_size: f32,
}

fn freehand() -> String {
    "freehand".into()
}

fn identity() -> [f32; 6] {
    [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
}

fn default_font_size() -> f32 {
    crate::geometry::sticky_note::DEFAULT_NOTE_FONT_SIZE
}

// ---------------------------------------------------------------------------- names

pub fn kind_name(k: DocumentKind) -> &'static str {
    match k {
        DocumentKind::Notebook => "notebook",
        DocumentKind::Whiteboard => "whiteboard",
        DocumentKind::PdfAnnotation => "pdf",
    }
}

pub fn parse_kind(s: &str) -> Option<DocumentKind> {
    Some(match s {
        "notebook" => DocumentKind::Notebook,
        "whiteboard" => DocumentKind::Whiteboard,
        "pdf" => DocumentKind::PdfAnnotation,
        _ => return None,
    })
}

pub fn paper_name(p: PaperStyle) -> &'static str {
    match p {
        PaperStyle::Whiteboard => "whiteboard",
        PaperStyle::Dictando => "dictando",
        PaperStyle::Matematica => "matematica",
    }
}

pub fn parse_paper(s: &str) -> Option<PaperStyle> {
    Some(match s {
        "whiteboard" => PaperStyle::Whiteboard,
        "dictando" => PaperStyle::Dictando,
        "matematica" => PaperStyle::Matematica,
        _ => return None,
    })
}

fn tool_name(t: ToolType) -> &'static str {
    match t {
        ToolType::Pen => "pen",
        ToolType::Pencil => "pencil",
        ToolType::Highlighter => "highlighter",
        ToolType::Eraser => "eraser",
        ToolType::StickyNote => "sticky_note",
    }
}

fn parse_tool(s: &str) -> Option<ToolType> {
    Some(match s {
        "pen" => ToolType::Pen,
        "pencil" => ToolType::Pencil,
        "highlighter" => ToolType::Highlighter,
        _ => return None, // eraser / sticky tools never produce strokes
    })
}

fn shape_name(s: ShapeKind) -> &'static str {
    match s {
        ShapeKind::Freehand => "freehand",
        ShapeKind::Rectangle => "rectangle",
        ShapeKind::Polyline => "polyline",
    }
}

fn parse_shape(s: &str) -> ShapeKind {
    match s {
        "rectangle" => ShapeKind::Rectangle,
        "polyline" => ShapeKind::Polyline,
        _ => ShapeKind::Freehand,
    }
}

fn round2(v: f32) -> f32 {
    (v * 100.0).round() / 100.0
}

fn round3(v: f32) -> f32 {
    (v * 1000.0).round() / 1000.0
}

fn finite_or(v: f32, fallback: f32) -> f32 {
    if v.is_finite() {
        v
    } else {
        fallback
    }
}

// ---------------------------------------------------------------------------- encode / decode

/// Serialises `data` into the on-disk format.
pub fn encode(data: &DocumentData) -> Result<Vec<u8>> {
    let stored = StoredDocument {
        version: FORMAT_VERSION,
        kind: kind_name(data.kind).into(),
        paper: paper_name(data.paper).into(),
        pages: data
            .pages
            .iter()
            .map(|p| StoredPage {
                height: round2(p.height),
                pdf_page: p.pdf_page,
            })
            .collect(),
        strokes: data
            .strokes
            .iter()
            .filter(|s| s.tool_type.is_ink() && !s.points.is_empty())
            .map(|s| {
                let m = s.transform_matrix;
                StoredStroke {
                    tool: tool_name(s.tool_type).into(),
                    shape: shape_name(s.shape).into(),
                    color: s.color,
                    width: s.width,
                    alpha: round3(s.alpha),
                    transform: [m.a, m.b, m.c, m.d, m.tx, m.ty],
                    points: s
                        .points
                        .iter()
                        .flat_map(|p| [round2(p.x), round2(p.y), round3(p.pressure)])
                        .collect(),
                }
            })
            .collect(),
        notes: data
            .notes
            .iter()
            .map(|n| StoredNote {
                x: round2(n.x),
                y: round2(n.y),
                width: round2(n.width),
                height: round2(n.height),
                color: n.color,
                text: n.text.clone(),
                font_size: n.font_size,
            })
            .collect(),
    };
    let json = serde_json::to_vec(&stored).context("serialising document")?;
    let mut out = Vec::with_capacity(json.len() / 3 + MAGIC.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&compress_to_vec_zlib(&json, 6));
    Ok(out)
}

/// Parses the on-disk format. Stroke / note ids are left empty (the engine assigns them).
pub fn decode(bytes: &[u8]) -> Result<DocumentData> {
    let Some(payload) = bytes.strip_prefix(MAGIC.as_slice()) else {
        bail!("not an EasyNotes document");
    };
    let json = decompress_to_vec_zlib_with_limit(payload, MAX_JSON_BYTES)
        .map_err(|e| anyhow::anyhow!("corrupt document data: {e:?}"))?;
    let stored: StoredDocument = serde_json::from_slice(&json).context("parsing document")?;
    if stored.version > FORMAT_VERSION {
        bail!(
            "document was saved by a newer EasyNotes (format {}); please update the app",
            stored.version
        );
    }
    let kind = parse_kind(&stored.kind).unwrap_or(DocumentKind::Notebook);
    let paper = parse_paper(&stored.paper).unwrap_or(PaperStyle::Whiteboard);
    let pages = if kind.is_paged() {
        let heights: Vec<(f32, Option<u32>)> = stored
            .pages
            .iter()
            .map(|p| (p.height, p.pdf_page))
            .collect();
        let stack = if heights.is_empty() {
            PageStack::blank(1)
        } else {
            PageStack::from_heights(&heights)
        };
        stack.pages().to_vec()
    } else {
        Vec::new()
    };

    let strokes = stored
        .strokes
        .into_iter()
        .filter_map(|s| {
            let tool = parse_tool(&s.tool)?;
            let points: Vec<StrokePoint> = s
                .points
                .as_chunks::<3>()
                .0
                .iter()
                .filter(|[x, y, _]| x.is_finite() && y.is_finite())
                .map(|&[x, y, p]| StrokePoint::new(x, y, finite_or(p, 0.5).clamp(0.0, 1.0)))
                .collect();
            if points.is_empty() {
                return None;
            }
            let t = s.transform.map(|v| finite_or(v, 0.0));
            let matrix = TransformMatrix {
                a: t[0],
                b: t[1],
                c: t[2],
                d: t[3],
                tx: t[4],
                ty: t[5],
            };
            Some(Stroke {
                id: String::new(),
                points,
                color: s.color,
                width: finite_or(s.width, 3.0).clamp(0.05, 500.0),
                alpha: finite_or(s.alpha, 1.0).clamp(0.0, 1.0),
                tool_type: tool,
                transform_matrix: if t[0] * t[3] - t[1] * t[2] == 0.0 {
                    TransformMatrix::IDENTITY
                } else {
                    matrix
                },
                shape: parse_shape(&s.shape),
            })
        })
        .collect();

    let notes = stored
        .notes
        .into_iter()
        .map(|n| StickyNote {
            id: String::new(),
            x: n.x,
            y: n.y,
            width: n.width,
            height: n.height,
            color: n.color,
            text: n.text,
            font_size: n.font_size,
        })
        .collect();

    Ok(DocumentData {
        kind,
        paper,
        pages,
        strokes,
        notes,
    })
}

/// Writes `bytes` to `path` via a temporary file + rename, so a crash mid-save never
/// leaves a truncated document behind.
pub fn write_atomic(path: &str, bytes: &[u8]) -> Result<()> {
    let target = std::path::Path::new(path);
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
    }
    let tmp = target.with_extension("tmp");
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, target).with_context(|| format!("replacing {path}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> DocumentData {
        DocumentData {
            kind: DocumentKind::Notebook,
            paper: PaperStyle::Dictando,
            pages: PageStack::blank(2).pages().to_vec(),
            strokes: vec![Stroke {
                id: "s1".into(),
                points: vec![
                    StrokePoint::new(10.123, 20.456, 0.5),
                    StrokePoint::new(30.0, 40.0, 0.75),
                ],
                color: 0xFF112233,
                width: 2.5,
                alpha: 0.9,
                tool_type: ToolType::Pen,
                transform_matrix: TransformMatrix::translation(5.0, 6.0),
                shape: ShapeKind::Freehand,
            }],
            notes: vec![StickyNote {
                id: "n2".into(),
                x: 100.0,
                y: 200.0,
                width: 160.0,
                height: 120.0,
                color: 0xFFFFF59D,
                text: "Notă ăîșț".into(),
                font_size: 16.0,
            }],
        }
    }

    #[test]
    fn round_trips_through_the_file_format() {
        let data = sample();
        let bytes = encode(&data).unwrap();
        assert!(bytes.starts_with(MAGIC));
        let back = decode(&bytes).unwrap();
        assert_eq!(back.kind, DocumentKind::Notebook);
        assert_eq!(back.paper, PaperStyle::Dictando);
        assert_eq!(back.pages.len(), 2);
        assert_eq!(back.strokes.len(), 1);
        let s = &back.strokes[0];
        assert_eq!((s.points[0].x, s.points[0].y), (10.12, 20.46));
        assert_eq!(s.transform_matrix, TransformMatrix::translation(5.0, 6.0));
        assert_eq!(back.notes[0].text, "Notă ăîșț");
    }

    #[test]
    fn rejects_foreign_files() {
        assert!(decode(b"%PDF-1.7 hello").is_err());
        let mut bad = MAGIC.to_vec();
        bad.extend_from_slice(b"garbage");
        assert!(decode(&bad).is_err());
    }

    #[test]
    fn atomic_write_replaces_existing_file() {
        let dir = std::env::temp_dir().join("easynotes_storage_test");
        let path = dir.join("doc.enote");
        let path = path.to_str().unwrap();
        write_atomic(path, b"one").unwrap();
        write_atomic(path, b"two").unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"two");
    }
}

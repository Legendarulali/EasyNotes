//! EasyNotes core engine.
//!
//! Layout:
//! - [`geometry`]  – points, strokes, outline tessellation, rectangle recognition, sticky notes
//! - [`spatial`]   – QuadTree index, hit testing and bounding-box transforms
//! - [`document`]  – the in-memory document / editing engine (selection, clipboard, eraser)
//! - [`export`]    – vector PDF export
//! - [`api`]       – the thread-safe surface exposed to Flutter through `flutter_rust_bridge`

pub mod api;
pub mod document;
pub mod export;
pub mod geometry;
pub mod spatial;

mod frb_generated;

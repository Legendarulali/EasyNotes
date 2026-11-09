//! Re-embeds pages of an imported PDF into an export as Form XObjects.
//!
//! Each source page becomes one Form XObject: its (decompressed, concatenated) content
//! streams are recompressed into the form, its inherited `/Resources` are deep-copied
//! (fonts, images, nested forms, …) with every indirect object renumbered into the
//! output file, and the form's `/BBox` is the page's crop box. The annotation layer is
//! then drawn on top, so exported PDFs keep the original's vector art and selectable text
//! instead of a rasterised copy.

use crate::document::pdf_importer::{inherited, load_pdf, page_geometry, PageGeometry};
use anyhow::Result;
use lopdf::{Document, Object, ObjectId};
use miniz_oxide::deflate::compress_to_vec_zlib;
use pdf_writer::{Filter, Name, Null, Obj, Pdf, Rect, Ref, Str};
use std::collections::HashMap;

/// Nesting limit for copied arrays / dictionaries (guards against hostile files).
const MAX_DEPTH: usize = 64;
/// Upper bound for one page's decompressed content.
const MAX_PAGE_CONTENT: usize = 256 * 1024 * 1024;

/// Sequential indirect-object id allocator shared by the exporter and the embedder.
#[derive(Debug)]
pub struct RefAlloc {
    next: i32,
}

impl Default for RefAlloc {
    fn default() -> Self {
        Self::new()
    }
}

impl RefAlloc {
    pub fn new() -> Self {
        Self { next: 1 }
    }

    pub fn bump(&mut self) -> Ref {
        let r = Ref::new(self.next);
        self.next += 1;
        r
    }
}

/// Source pages to embed, keyed by output order.
pub struct PdfEmbedder {
    doc: Document,
    pages: Vec<ObjectId>,
    forms: Vec<(Ref, usize)>,
    by_page: HashMap<usize, Ref>,
}

impl PdfEmbedder {
    pub fn new(bytes: &[u8]) -> Result<Self> {
        let doc = load_pdf(bytes)?;
        let pages = doc.page_iter().collect();
        Ok(Self {
            doc,
            pages,
            forms: Vec::new(),
            by_page: HashMap::new(),
        })
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    pub fn geometry(&self, page: usize) -> Option<PageGeometry> {
        self.pages.get(page).map(|&id| page_geometry(&self.doc, id))
    }

    /// Reserves (once per source page) the Form XObject for `page`.
    pub fn form(&mut self, page: usize, alloc: &mut RefAlloc) -> Option<Ref> {
        if page >= self.pages.len() {
            return None;
        }
        if let Some(&r) = self.by_page.get(&page) {
            return Some(r);
        }
        let r = alloc.bump();
        self.by_page.insert(page, r);
        self.forms.push((r, page));
        Some(r)
    }

    /// Writes every reserved form plus all objects they reference.
    pub fn write(self, pdf: &mut Pdf, alloc: &mut RefAlloc) {
        let PdfEmbedder {
            doc, pages, forms, ..
        } = self;
        let mut copier = Copier {
            doc: &doc,
            map: HashMap::new(),
            pending: Vec::new(),
        };
        for (form_ref, page) in forms {
            let page_id = pages[page];
            let g = page_geometry(&doc, page_id);
            let content = doc
                .get_page_content_with_limit(page_id, MAX_PAGE_CONTENT)
                .unwrap_or_default();
            let compressed = compress_to_vec_zlib(&content, 6);
            let resources = inherited(&doc, page_id, b"Resources");
            let group = doc
                .get_dictionary(page_id)
                .ok()
                .and_then(|d| d.get(b"Group").ok());
            let mut form = pdf.form_xobject(form_ref, &compressed);
            form.filter(Filter::FlateDecode);
            form.bbox(Rect::new(g.crop[0], g.crop[1], g.crop[2], g.crop[3]));
            if let Some(res) = resources {
                copier.write_value(form.insert(Name(b"Resources")), res, alloc, 0);
            }
            if let Some(group) = group {
                copier.write_value(form.insert(Name(b"Group")), group, alloc, 0);
            }
        }
        while let Some(id) = copier.pending.pop() {
            copier.write_indirect(pdf, id, alloc);
        }
    }
}

/// Deep-copies lopdf objects into the pdf-writer output, renumbering references.
struct Copier<'d> {
    doc: &'d Document,
    map: HashMap<ObjectId, Ref>,
    pending: Vec<ObjectId>,
}

impl<'d> Copier<'d> {
    fn reference(&mut self, id: ObjectId, alloc: &mut RefAlloc) -> Ref {
        if let Some(&r) = self.map.get(&id) {
            return r;
        }
        let r = alloc.bump();
        self.map.insert(id, r);
        self.pending.push(id);
        r
    }

    fn write_value(&mut self, obj: Obj<'_>, value: &Object, alloc: &mut RefAlloc, depth: usize) {
        if depth > MAX_DEPTH {
            obj.primitive(Null);
            return;
        }
        match value {
            Object::Null => obj.primitive(Null),
            Object::Boolean(b) => obj.primitive(*b),
            Object::Integer(i) => {
                obj.primitive((*i).clamp(i32::MIN as i64, i32::MAX as i64) as i32)
            }
            Object::Real(r) => obj.primitive(if r.is_finite() { *r } else { 0.0 }),
            Object::Name(n) => obj.primitive(Name(n)),
            Object::String(s, _) => obj.primitive(Str(s)),
            Object::Array(items) => {
                let mut arr = obj.array();
                for item in items {
                    self.write_value(arr.push(), item, alloc, depth + 1);
                }
            }
            Object::Dictionary(dict) => {
                let mut d = obj.dict();
                for (key, v) in dict.iter() {
                    // Never drag the source page tree along.
                    if key.as_slice() == b"Parent" {
                        continue;
                    }
                    self.write_value(d.insert(Name(key)), v, alloc, depth + 1);
                }
            }
            // Streams are always indirect; a direct one is malformed.
            Object::Stream(_) => obj.primitive(Null),
            Object::Reference(id) => {
                let r = self.reference(*id, alloc);
                obj.primitive(r);
            }
        }
    }

    fn write_indirect(&mut self, pdf: &mut Pdf, id: ObjectId, alloc: &mut RefAlloc) {
        let r = self.map[&id];
        let doc = self.doc;
        match doc.objects.get(&id) {
            Some(Object::Stream(stream)) => {
                let mut s = pdf.stream(r, &stream.content);
                for (key, v) in stream.dict.iter() {
                    if key.as_slice() == b"Length" {
                        continue; // pdf-writer writes the real length
                    }
                    self.write_value(s.insert(Name(key)), v, alloc, 1);
                }
            }
            Some(other) => self.write_value(pdf.indirect(r), other, alloc, 0),
            None => pdf.indirect(r).primitive(Null),
        }
    }
}

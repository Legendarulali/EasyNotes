//! Several documents open at once (editor tabs).
//!
//! The editing API works on one *active* document. The others are parked whole, so their
//! undo / redo history, selection, spatial index and even an unfinished stroke survive a tab
//! switch untouched. Switching moves the engines, it never copies or rebuilds them: it costs
//! the same for an empty page and a 500-page notebook.
//!
//! Documents are addressed by *slots*: small integers handed out by the caller, one per
//! open tab. Slot [`Workspace::SCRATCH`] always resolves: it is the document the API works on
//! before any tab binds its own, and the one that takes over when the active tab closes.

use super::{ClipItem, Engine};
use std::collections::HashMap;

pub struct Workspace {
    active_slot: u32,
    active: Engine,
    parked: HashMap<u32, Engine>,
}

impl Default for Workspace {
    fn default() -> Self {
        Self::new()
    }
}

impl Workspace {
    /// Slot of the document that is active when no tab is bound.
    pub const SCRATCH: u32 = 0;

    pub fn new() -> Self {
        Self {
            active_slot: Self::SCRATCH,
            active: Engine::new(),
            parked: HashMap::new(),
        }
    }

    pub fn active_slot(&self) -> u32 {
        self.active_slot
    }

    pub fn active(&self) -> &Engine {
        &self.active
    }

    pub fn active_mut(&mut self) -> &mut Engine {
        &mut self.active
    }

    /// The document of `slot`, active or parked.
    pub fn get(&self, slot: u32) -> Option<&Engine> {
        if slot == self.active_slot {
            Some(&self.active)
        } else {
            self.parked.get(&slot)
        }
    }

    /// Makes `slot` the active document. Returns `false` (and changes nothing) when there is
    /// no such document; the scratch slot is recreated on demand.
    pub fn activate(&mut self, slot: u32) -> bool {
        if slot == self.active_slot {
            return true;
        }
        let next = match self.parked.remove(&slot) {
            Some(doc) => doc,
            None if slot == Self::SCRATCH => Engine::new(),
            None => return false,
        };
        let previous_slot = self.active_slot;
        let previous = self.swap_in(slot, next);
        self.parked.insert(previous_slot, previous);
        true
    }

    /// Puts `doc` into `slot`, replacing whatever was there. A parked slot stays parked.
    pub fn install(&mut self, slot: u32, doc: Engine) {
        if slot == self.active_slot {
            self.swap_in(slot, doc);
        } else {
            self.parked.insert(slot, doc);
        }
    }

    /// Drops the document of `slot`. Closing the active one makes the scratch document
    /// active.
    pub fn close(&mut self, slot: u32) {
        if slot != self.active_slot {
            self.parked.remove(&slot);
            return;
        }
        let scratch = if slot == Self::SCRATCH {
            Engine::new()
        } else {
            self.parked.remove(&Self::SCRATCH).unwrap_or_default()
        };
        self.swap_in(Self::SCRATCH, scratch);
    }

    /// Slots of the open documents other than the scratch one, ascending.
    pub fn slots(&self) -> Vec<u32> {
        let mut slots: Vec<u32> = self
            .parked
            .keys()
            .copied()
            .chain(std::iter::once(self.active_slot))
            .filter(|&s| s != Self::SCRATCH)
            .collect();
        slots.sort_unstable();
        slots
    }

    /// Activates `next` under `slot` and returns the previously active engine. The clipboard
    /// moves along, so copying in one tab and pasting in another works.
    fn swap_in(&mut self, slot: u32, mut next: Engine) -> Engine {
        next.adopt_clipboard(self.active.take_clipboard());
        self.active_slot = slot;
        std::mem::replace(&mut self.active, next)
    }
}

impl Engine {
    fn take_clipboard(&mut self) -> Vec<ClipItem> {
        self.paste_count = 0;
        std::mem::take(&mut self.clipboard)
    }

    /// Pastes into another document start from the target spot again (no cascade).
    fn adopt_clipboard(&mut self, items: Vec<ClipItem>) {
        self.clipboard = items;
        self.paste_count = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{DocumentKind, PaperStyle};
    use crate::geometry::{Brush, StrokePoint, ToolType};

    fn draw(e: &mut Engine, y: f32) {
        e.begin_stroke(ToolType::Pen, Brush::default());
        for i in 0..10 {
            e.add_point(StrokePoint::new(100.0 + i as f32 * 20.0, y, 0.5));
        }
        e.finish_stroke(ToolType::Pen, false)
            .expect("stroke committed");
    }

    fn notebook() -> Engine {
        Engine::with_kind(DocumentKind::Notebook, PaperStyle::Dictando)
    }

    #[test]
    fn switching_keeps_each_documents_content_and_history() {
        let mut ws = Workspace::new();
        ws.install(1, notebook());
        ws.install(2, notebook());
        assert_eq!(ws.slots(), vec![1, 2]);

        assert!(ws.activate(1));
        draw(ws.active_mut(), 100.0);
        draw(ws.active_mut(), 200.0);
        assert!(ws.activate(2));
        draw(ws.active_mut(), 300.0);
        assert_eq!(ws.active().item_count(), 1);

        assert!(ws.activate(1));
        assert_eq!(ws.active().item_count(), 2);
        assert!(
            ws.active_mut().undo().is_some(),
            "history survived the switch"
        );
        assert_eq!(ws.active().item_count(), 1);
        assert!(ws.active().can_redo());

        assert!(ws.activate(2));
        assert_eq!(ws.active().item_count(), 1);
        assert!(ws.active().can_undo());
        assert!(
            !ws.active().can_redo(),
            "undo in one tab does not touch another"
        );
    }

    #[test]
    fn an_unfinished_stroke_waits_in_its_parked_document() {
        let mut ws = Workspace::new();
        ws.install(1, notebook());
        ws.install(2, notebook());
        ws.activate(1);
        let e = ws.active_mut();
        e.begin_stroke(ToolType::Pen, Brush::default());
        e.add_point(StrokePoint::new(10.0, 10.0, 0.5));
        ws.activate(2);
        assert!(ws.active().preview().is_none());
        ws.activate(1);
        let e = ws.active_mut();
        e.add_point(StrokePoint::new(200.0, 40.0, 0.5));
        assert!(e.finish_stroke(ToolType::Pen, false).is_some());
    }

    #[test]
    fn the_clipboard_follows_the_active_document() {
        let mut ws = Workspace::new();
        ws.install(1, notebook());
        ws.install(2, Engine::new());
        ws.activate(1);
        draw(ws.active_mut(), 100.0);
        let e = ws.active_mut();
        e.select_in_rect(crate::geometry::ViewportRect::new(0.0, 0.0, 1000.0, 1000.0));
        assert_eq!(e.copy_selection(), 1);

        ws.activate(2);
        assert!(ws.active().has_clipboard());
        let pasted = ws.active_mut().paste_clipboard(500.0, 500.0);
        assert_eq!(pasted.upserted_strokes.len(), 1);
        assert_eq!(ws.active().item_count(), 1);
        ws.activate(1);
        assert!(ws.active().has_clipboard());
        assert_eq!(
            ws.active().item_count(),
            1,
            "pasting elsewhere left the source alone"
        );
    }

    #[test]
    fn unknown_slots_and_closing() {
        let mut ws = Workspace::new();
        assert!(!ws.activate(7), "nothing installed under 7");
        assert_eq!(ws.active_slot(), Workspace::SCRATCH);

        // Installing into the active slot replaces the document but keeps the clipboard.
        ws.install(3, notebook());
        ws.activate(3);
        draw(ws.active_mut(), 100.0);
        ws.install(3, notebook());
        assert_eq!(ws.active_slot(), 3);
        assert_eq!(ws.active().item_count(), 0);
        assert!(!ws.active().can_undo());

        ws.install(4, notebook());
        ws.close(4);
        assert!(ws.get(4).is_none());
        assert_eq!(
            ws.active_slot(),
            3,
            "closing a parked tab leaves the active one alone"
        );

        ws.close(3);
        assert_eq!(ws.active_slot(), Workspace::SCRATCH);
        assert!(ws.slots().is_empty());
        assert!(ws.activate(Workspace::SCRATCH));
    }
}

//! Undo / redo history.
//!
//! Every document edit is recorded as a list of per-item state changes: for each touched
//! item key, the state before the edit and the state after it (`None` = the item does not
//! exist). Undo writes the "before" states back, redo the "after" states. Because item
//! keys are never reused, a restored item gets its old id and z-position back, and every
//! kind of edit (drawing, both erasers, transforms, duplicate / cut / paste / delete,
//! sticky notes, clearing) is handled by the same two code paths.
//!
//! Recording works like a transaction: the engine calls [`History::begin`], snapshots each
//! item with [`History::record`] *before* mutating it, and finishes with [`History::end`].
//! Nested begin / end pairs merge into the outermost one, which is how a whole eraser drag
//! (many FFI calls) becomes a single undo step.
//!
//! Moves and resizes only change a stroke's transform matrix, so they are stored as
//! matrix pairs instead of full point copies. The undo stack is capped at
//! [`HISTORY_LIMIT`] steps and roughly [`HISTORY_BYTE_BUDGET`] bytes; the oldest steps
//! are dropped first.

use crate::geometry::{StickyNote, Stroke, StrokePoint, TransformMatrix};
use std::collections::{BTreeMap, VecDeque};

/// Maximum number of undo steps kept.
pub const HISTORY_LIMIT: usize = 100;
/// Approximate memory budget of the undo stack (point and text copies).
pub const HISTORY_BYTE_BUDGET: usize = 64 << 20;

/// A document item as stored in the history.
#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Stroke(Stroke),
    Note(StickyNote),
}

impl Item {
    fn cost(&self) -> usize {
        match self {
            Item::Stroke(s) => {
                std::mem::size_of::<Stroke>() + s.points.len() * std::mem::size_of::<StrokePoint>()
            }
            Item::Note(n) => std::mem::size_of::<StickyNote>() + n.text.len(),
        }
    }
}

/// State of one item before an edit, captured on first touch.
#[derive(Debug, Clone)]
enum Snapshot {
    Item(Option<Item>),
    /// Only the stroke's transform has changed so far (no point copy taken).
    Transform(TransformMatrix),
}

/// How one item changed in an edit.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    /// The item appeared, disappeared or was replaced.
    Item {
        key: u64,
        before: Option<Item>,
        after: Option<Item>,
    },
    /// Only a stroke's transform changed (move / resize).
    Transform {
        key: u64,
        before: TransformMatrix,
        after: TransformMatrix,
    },
}

impl Change {
    pub fn key(&self) -> u64 {
        match self {
            Change::Item { key, .. } | Change::Transform { key, .. } => *key,
        }
    }

    fn cost(&self) -> usize {
        let base = std::mem::size_of::<Change>();
        match self {
            Change::Item { before, after, .. } => {
                base + before.as_ref().map_or(0, Item::cost) + after.as_ref().map_or(0, Item::cost)
            }
            Change::Transform { .. } => base,
        }
    }
}

/// One undo step.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// Changes in key order (keys are unique within an entry).
    pub changes: Vec<Change>,
    cost: usize,
}

impl Entry {
    fn new(changes: Vec<Change>) -> Self {
        let cost = changes.iter().map(Change::cost).sum();
        Self { changes, cost }
    }
}

/// Undo / redo stacks plus the edit being recorded.
#[derive(Debug, Default)]
pub struct History {
    undo: VecDeque<Entry>,
    redo: Vec<Entry>,
    undo_bytes: usize,
    /// Before-states of the edit being recorded, by key.
    recording: BTreeMap<u64, Snapshot>,
    depth: u32,
}

impl History {
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn undo_len(&self) -> usize {
        self.undo.len()
    }

    pub fn redo_len(&self) -> usize {
        self.redo.len()
    }

    /// Whether an edit is being recorded.
    pub fn is_recording(&self) -> bool {
        self.depth > 0
    }

    /// Opens an edit (nested calls merge into the outermost edit).
    pub fn begin(&mut self) {
        self.depth += 1;
    }

    /// Captures the state of `key` before it is mutated (only the first call per key and
    /// edit counts). Does nothing outside an edit.
    pub fn record(&mut self, key: u64, current: impl FnOnce() -> Option<Item>) {
        if self.depth == 0 {
            return;
        }
        match self.recording.get(&key) {
            None => {
                self.recording.insert(key, Snapshot::Item(current()));
            }
            Some(Snapshot::Transform(matrix)) => {
                // Upgrade to a full snapshot: up to now only the matrix has changed.
                let matrix = *matrix;
                let before = current().map(|item| match item {
                    Item::Stroke(s) => Item::Stroke(Stroke {
                        transform_matrix: matrix,
                        ..s
                    }),
                    other => other,
                });
                self.recording.insert(key, Snapshot::Item(before));
            }
            Some(Snapshot::Item(_)) => {}
        }
    }

    /// Captures a stroke's transform before only its matrix is changed.
    pub fn record_transform(&mut self, key: u64, matrix: TransformMatrix) {
        if self.depth > 0 {
            self.recording
                .entry(key)
                .or_insert(Snapshot::Transform(matrix));
        }
    }

    /// Closes an edit. When the outermost edit closes, `current` is asked for the state
    /// of every touched item and the edit becomes an undo step (unless nothing changed).
    /// A new step clears the redo stack. Returns whether a step was pushed.
    pub fn end(&mut self, current: impl Fn(u64) -> Option<Item>) -> bool {
        if self.depth == 0 {
            return false;
        }
        self.depth -= 1;
        if self.depth > 0 {
            return false;
        }
        let recording = std::mem::take(&mut self.recording);
        let changes: Vec<Change> = recording
            .into_iter()
            .filter_map(|(key, snapshot)| diff(key, snapshot, current(key)))
            .collect();
        if changes.is_empty() {
            return false;
        }
        self.redo.clear();
        self.push_undo(Entry::new(changes));
        true
    }

    fn push_undo(&mut self, entry: Entry) {
        self.undo_bytes += entry.cost;
        self.undo.push_back(entry);
        while self.undo.len() > HISTORY_LIMIT
            || (self.undo_bytes > HISTORY_BYTE_BUDGET && self.undo.len() > 1)
        {
            if let Some(old) = self.undo.pop_front() {
                self.undo_bytes -= old.cost;
            }
        }
    }

    /// Takes the most recent undo step (it moves to the redo stack via [`Self::push_redo`]).
    pub fn pop_undo(&mut self) -> Option<Entry> {
        let entry = self.undo.pop_back()?;
        self.undo_bytes -= entry.cost;
        Some(entry)
    }

    pub fn push_redo(&mut self, entry: Entry) {
        self.redo.push(entry);
    }

    /// Takes the most recently undone step (it moves back via [`Self::push_undone`]).
    pub fn pop_redo(&mut self) -> Option<Entry> {
        self.redo.pop()
    }

    /// Puts a redone step back on the undo stack without clearing the redo stack.
    pub fn push_undone(&mut self, entry: Entry) {
        self.push_undo(entry);
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }
}

/// The change between a recorded snapshot and the current state, `None` if equal.
fn diff(key: u64, snapshot: Snapshot, after: Option<Item>) -> Option<Change> {
    match snapshot {
        // Removing or replacing a stroke always takes a full snapshot first (upgrading this
        // one), so a transform-only snapshot still refers to an existing stroke here.
        Snapshot::Transform(before) => match after {
            Some(Item::Stroke(s)) if s.transform_matrix != before => Some(Change::Transform {
                key,
                before,
                after: s.transform_matrix,
            }),
            _ => None,
        },
        Snapshot::Item(before) => {
            if before == after {
                return None;
            }
            if let (Some(Item::Stroke(a)), Some(Item::Stroke(b))) = (&before, &after) {
                if same_except_transform(a, b) {
                    return Some(Change::Transform {
                        key,
                        before: a.transform_matrix,
                        after: b.transform_matrix,
                    });
                }
            }
            Some(Change::Item { key, before, after })
        }
    }
}

fn same_except_transform(a: &Stroke, b: &Stroke) -> bool {
    a.id == b.id
        && a.color == b.color
        && a.width == b.width
        && a.alpha == b.alpha
        && a.tool_type == b.tool_type
        && a.shape == b.shape
        && a.points == b.points
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::{ShapeKind, ToolType};

    fn stroke(id: &str, x: f32) -> Item {
        Item::Stroke(Stroke {
            id: id.into(),
            points: vec![
                StrokePoint::new(x, 0.0, 0.5),
                StrokePoint::new(x + 10.0, 0.0, 0.5),
            ],
            color: 0xFF000000,
            width: 3.0,
            alpha: 1.0,
            tool_type: ToolType::Pen,
            transform_matrix: TransformMatrix::IDENTITY,
            shape: ShapeKind::Freehand,
        })
    }

    #[test]
    fn nested_edits_merge_and_noops_are_dropped() {
        let mut h = History::default();
        h.begin();
        h.record(1, || None);
        h.begin();
        h.record(1, || Some(stroke("s1", 0.0))); // ignored: already recorded
        h.record(2, || Some(stroke("s2", 5.0)));
        assert!(!h.end(|_| None), "inner end does not commit");
        // Key 1 was created, key 2 deleted.
        assert!(h.end(|k| (k == 1).then(|| stroke("s1", 0.0))));
        assert_eq!(h.undo_len(), 1);
        let entry = h.pop_undo().unwrap();
        assert_eq!(entry.changes.len(), 2);

        // An edit that ends where it started leaves no step.
        h.begin();
        h.record(3, || Some(stroke("s3", 1.0)));
        assert!(!h.end(|_| Some(stroke("s3", 1.0))));
        assert!(!h.can_undo());
    }

    #[test]
    fn transform_only_changes_are_stored_as_matrices() {
        let mut h = History::default();
        h.begin();
        h.record_transform(7, TransformMatrix::IDENTITY);
        let moved = |_: u64| {
            let Item::Stroke(mut s) = stroke("s7", 0.0) else {
                unreachable!()
            };
            s.transform_matrix = TransformMatrix::translation(5.0, 0.0);
            Some(Item::Stroke(s))
        };
        assert!(h.end(moved));
        let entry = h.pop_undo().unwrap();
        assert!(matches!(entry.changes[0], Change::Transform { key: 7, .. }));
    }

    #[test]
    fn new_steps_clear_redo_and_the_stack_is_capped() {
        let mut h = History::default();
        for i in 0..(HISTORY_LIMIT as u64 + 20) {
            h.begin();
            h.record(i, || None);
            h.end(|k| Some(stroke(&format!("s{k}"), 0.0)));
        }
        assert_eq!(h.undo_len(), HISTORY_LIMIT);
        let e = h.pop_undo().unwrap();
        h.push_redo(e);
        assert!(h.can_redo());
        h.begin();
        h.record(999, || None);
        h.end(|_| Some(stroke("s999", 0.0)));
        assert!(!h.can_redo());
    }
}

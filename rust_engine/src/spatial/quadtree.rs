//! Region QuadTree over axis-aligned bounding boxes.
//!
//! The canvas is infinite towards +X / +Y only (negative coordinates are clamped away by
//! the engine), so the root is anchored at the origin and grows by doubling towards the
//! bottom-right whenever an item falls outside of it: the old root simply becomes the
//! new root's top-left quadrant. Items that straddle quadrant borders live in the
//! smallest node that fully contains them.

use crate::geometry::{Vec2, ViewportRect};
use std::collections::HashMap;

const MAX_ITEMS: usize = 8;
const MAX_DEPTH: u32 = 14;
const INITIAL_SIZE: f32 = 2048.0;
/// Hard limit to avoid unbounded growth from corrupt coordinates.
const MAX_SIZE: f32 = 1.0e8;

#[derive(Debug)]
struct Node {
    bounds: ViewportRect,
    items: Vec<(u64, ViewportRect)>,
    children: Option<Box<[Node; 4]>>,
}

impl Node {
    fn new(bounds: ViewportRect) -> Self {
        Self {
            bounds,
            items: Vec::new(),
            children: None,
        }
    }

    fn child_bounds(&self) -> [ViewportRect; 4] {
        let b = self.bounds;
        let c = b.center();
        [
            ViewportRect::new(b.left, b.top, c.x, c.y),
            ViewportRect::new(c.x, b.top, b.right, c.y),
            ViewportRect::new(b.left, c.y, c.x, b.bottom),
            ViewportRect::new(c.x, c.y, b.right, b.bottom),
        ]
    }

    fn insert(&mut self, key: u64, rect: ViewportRect, depth: u32) {
        if let Some(children) = self.children.as_mut() {
            for child in children.iter_mut() {
                if child.bounds.contains_rect(&rect) {
                    child.insert(key, rect, depth + 1);
                    return;
                }
            }
            self.items.push((key, rect));
            return;
        }
        self.items.push((key, rect));
        if self.items.len() > MAX_ITEMS && depth < MAX_DEPTH {
            self.split(depth);
        }
    }

    fn split(&mut self, depth: u32) {
        let [a, b, c, d] = self.child_bounds();
        self.children = Some(Box::new([
            Node::new(a),
            Node::new(b),
            Node::new(c),
            Node::new(d),
        ]));
        let items = std::mem::take(&mut self.items);
        for (key, rect) in items {
            self.insert(key, rect, depth);
        }
    }

    fn remove(&mut self, key: u64, rect: &ViewportRect) -> bool {
        if let Some(pos) = self.items.iter().position(|(k, _)| *k == key) {
            self.items.swap_remove(pos);
            return true;
        }
        if let Some(children) = self.children.as_mut() {
            for child in children.iter_mut() {
                if child.bounds.contains_rect(rect) && child.remove(key, rect) {
                    return true;
                }
            }
        }
        false
    }

    fn query(&self, area: &ViewportRect, out: &mut Vec<u64>) {
        for (key, rect) in &self.items {
            if rect.intersects(area) {
                out.push(*key);
            }
        }
        if let Some(children) = self.children.as_ref() {
            for child in children.iter() {
                if child.bounds.intersects(area) {
                    child.query(area, out);
                }
            }
        }
    }

    fn count(&self) -> usize {
        self.items.len()
            + self
                .children
                .as_ref()
                .map_or(0, |c| c.iter().map(Node::count).sum())
    }
}

/// Spatial index mapping item keys to bounding boxes.
#[derive(Debug)]
pub struct QuadTree {
    root: Node,
    locations: HashMap<u64, ViewportRect>,
}

impl Default for QuadTree {
    fn default() -> Self {
        Self::new()
    }
}

impl QuadTree {
    pub fn new() -> Self {
        Self {
            root: Node::new(ViewportRect::new(0.0, 0.0, INITIAL_SIZE, INITIAL_SIZE)),
            locations: HashMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.locations.len()
    }

    pub fn is_empty(&self) -> bool {
        self.locations.is_empty()
    }

    pub fn clear(&mut self) {
        *self = Self::new();
    }

    pub fn bounds_of(&self, key: u64) -> Option<ViewportRect> {
        self.locations.get(&key).copied()
    }

    /// Inserts or updates `key`.
    pub fn insert(&mut self, key: u64, rect: ViewportRect) {
        if self.locations.contains_key(&key) {
            self.remove(key);
        }
        self.grow_to_fit(&rect);
        self.root.insert(key, rect, 0);
        self.locations.insert(key, rect);
    }

    pub fn remove(&mut self, key: u64) -> bool {
        match self.locations.remove(&key) {
            Some(rect) => self.root.remove(key, &rect),
            None => false,
        }
    }

    /// Keys whose bounding boxes intersect `area`.
    pub fn query(&self, area: &ViewportRect) -> Vec<u64> {
        let mut out = Vec::new();
        self.root.query(area, &mut out);
        out
    }

    /// Keys whose bounding boxes come within `radius` of `p`.
    pub fn query_point(&self, p: Vec2, radius: f32) -> Vec<u64> {
        self.query(&ViewportRect::new(
            p.x - radius,
            p.y - radius,
            p.x + radius,
            p.y + radius,
        ))
    }

    /// Number of entries reachable through the tree (used to validate invariants).
    pub fn node_item_count(&self) -> usize {
        self.root.count()
    }

    fn grow_to_fit(&mut self, rect: &ViewportRect) {
        while (rect.right > self.root.bounds.right || rect.bottom > self.root.bounds.bottom)
            && self.root.bounds.width() < MAX_SIZE
        {
            let size = self.root.bounds.width() * 2.0;
            let mut new_root = Node::new(ViewportRect::new(0.0, 0.0, size, size));
            let old = std::mem::replace(
                &mut self.root,
                Node::new(ViewportRect::new(0.0, 0.0, 0.0, 0.0)),
            );
            let old_bounds = old.bounds;
            let [tl, tr, bl, br] = new_root.child_bounds();
            let mut old = old;
            // Items poking outside the old root (e.g. negative coords) must move up a level.
            let (inside, outside): (Vec<_>, Vec<_>) = old
                .items
                .drain(..)
                .partition(|(_, r)| old_bounds.contains_rect(r));
            old.items = inside;
            new_root.items = outside;
            new_root.children = Some(Box::new([old, Node::new(tr), Node::new(bl), Node::new(br)]));
            debug_assert_eq!(tl, old_bounds);
            self.root = new_root;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f32, y: f32, s: f32) -> ViewportRect {
        ViewportRect::from_xywh(x, y, s, s)
    }

    #[test]
    fn insert_query_remove() {
        let mut qt = QuadTree::new();
        for i in 0..200u64 {
            let x = (i % 20) as f32 * 50.0;
            let y = (i / 20) as f32 * 50.0;
            qt.insert(i, rect(x, y, 10.0));
        }
        assert_eq!(qt.len(), 200);
        assert_eq!(qt.node_item_count(), 200);
        let hits = qt.query(&ViewportRect::new(0.0, 0.0, 60.0, 60.0));
        let mut hits = hits;
        hits.sort();
        assert_eq!(hits, vec![0, 1, 20, 21]);
        assert!(qt.remove(21));
        assert!(!qt.remove(21));
        assert_eq!(
            qt.query(&ViewportRect::new(40.0, 40.0, 60.0, 60.0)),
            Vec::<u64>::new()
        );
        assert_eq!(qt.node_item_count(), 199);
    }

    #[test]
    fn grows_towards_bottom_right_and_keeps_items() {
        let mut qt = QuadTree::new();
        qt.insert(1, rect(10.0, 10.0, 5.0));
        qt.insert(2, ViewportRect::new(-3.0, -3.0, 4.0, 4.0));
        qt.insert(3, rect(50_000.0, 70_000.0, 20.0));
        assert_eq!(qt.node_item_count(), 3);
        assert_eq!(qt.query(&rect(0.0, 0.0, 20.0,)).len(), 2);
        assert_eq!(qt.query(&rect(49_990.0, 69_990.0, 40.0)), vec![3]);
        // Update moves the item.
        qt.insert(3, rect(5.0, 5.0, 2.0));
        assert!(qt.query(&rect(49_990.0, 69_990.0, 40.0)).is_empty());
        assert_eq!(qt.len(), 3);
        assert_eq!(qt.node_item_count(), 3);
    }
}

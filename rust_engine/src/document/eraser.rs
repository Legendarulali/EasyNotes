//! Eraser geometry.
//!
//! The eraser is a disc of radius `r`. Between two pointer samples it sweeps a capsule
//! (segment `a–b` inflated by `r`), so fast movements never skip over thin strokes.
//!
//! * [`EraserMode::Stroke`] deletes every stroke the capsule touches.
//! * [`EraserMode::Partial`] ("classic" eraser) cuts the stroke's centre line where it
//!   passes through the capsule and keeps the remaining pieces as separate strokes.
//!
//! Cutting is exact per segment: the distance from a point moving linearly along a stroke
//! segment to the (convex) capsule axis is a convex function of the segment parameter `t`,
//! so the erased part of each segment is a single interval `[t0, t1]`. We locate its
//! minimum with a ternary search and both boundaries by bisection.

use crate::geometry::{StrokePoint, Vec2, ViewportRect};
use crate::spatial::hit_test::distance_to_segment;

/// How the eraser treats the strokes it touches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EraserMode {
    /// Deletes the whole stroke on contact.
    Stroke,
    /// Splits / shortens strokes, removing only what lies under the eraser.
    Partial,
}

/// Surviving pieces shorter than this (world units) are dropped as crumbs.
const MIN_PIECE_LENGTH: f32 = 0.75;
const TERNARY_STEPS: usize = 40;
const BISECTION_STEPS: usize = 24;

/// Capsule swept by the eraser disc between two consecutive samples.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EraserSweep {
    pub a: Vec2,
    pub b: Vec2,
    pub radius: f32,
}

impl EraserSweep {
    pub fn new(a: Vec2, b: Vec2, radius: f32) -> Self {
        let radius = if radius.is_finite() {
            radius.max(0.5)
        } else {
            0.5
        };
        Self { a, b, radius }
    }

    /// Bounding box of the capsule grown by `extra` (e.g. a stroke's half width).
    pub fn bounds(&self, extra: f32) -> ViewportRect {
        ViewportRect::new(self.a.x, self.a.y, self.b.x, self.b.y).inflate(self.radius + extra)
    }

    /// Distance from `p` to the capsule's axis.
    pub fn axis_distance(&self, p: Vec2) -> f32 {
        distance_to_segment(p, self.a, self.b)
    }

    /// Whether any part of the polyline comes within `reach` of the axis.
    pub fn touches(&self, pts: &[Vec2], closed: bool, reach: f32) -> bool {
        match pts.len() {
            0 => false,
            1 => self.axis_distance(pts[0]) <= reach,
            n => {
                let segs = (0..n - 1)
                    .map(|i| (pts[i], pts[i + 1]))
                    .chain(closed.then(|| (pts[n - 1], pts[0])));
                segs.into_iter()
                    .any(|(p, q)| erased_interval(p, q, self, reach).is_some())
            }
        }
    }
}

/// Outcome of partially erasing one stroke.
#[derive(Debug, Clone, PartialEq)]
pub enum CutOutcome {
    /// The eraser missed the stroke.
    Untouched,
    /// Nothing worth keeping is left.
    Erased,
    /// Remaining pieces, in drawing order.
    Split(Vec<Vec<StrokePoint>>),
}

/// Parameter interval `[t0, t1] ⊂ [0, 1]` of segment `p–q` lying within `reach` of the
/// sweep axis, or `None` if the segment stays outside.
pub fn erased_interval(p: Vec2, q: Vec2, sweep: &EraserSweep, reach: f32) -> Option<(f32, f32)> {
    let f = |t: f32| sweep.axis_distance(p.lerp(q, t));
    // Cheap rejection: the whole segment is farther than `reach` from the capsule's box.
    let seg_box = ViewportRect::new(p.x, p.y, q.x, q.y);
    let reach_box = ViewportRect::new(sweep.a.x, sweep.a.y, sweep.b.x, sweep.b.y).inflate(reach);
    if !seg_box.intersects(&reach_box) {
        return None;
    }
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..TERNARY_STEPS {
        let m1 = lo + (hi - lo) / 3.0;
        let m2 = hi - (hi - lo) / 3.0;
        if f(m1) <= f(m2) {
            hi = m2;
        } else {
            lo = m1;
        }
    }
    let t_min = 0.5 * (lo + hi);
    if f(t_min) > reach {
        return None;
    }
    let t0 = if f(0.0) <= reach {
        0.0
    } else {
        // f(lo) > reach >= f(hi)
        let (mut lo, mut hi) = (0.0f32, t_min);
        for _ in 0..BISECTION_STEPS {
            let mid = 0.5 * (lo + hi);
            if f(mid) > reach {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        hi
    };
    let t1 = if f(1.0) <= reach {
        1.0
    } else {
        // f(lo) <= reach < f(hi)
        let (mut lo, mut hi) = (t_min, 1.0f32);
        for _ in 0..BISECTION_STEPS {
            let mid = 0.5 * (lo + hi);
            if f(mid) <= reach {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        lo
    };
    Some((t0, t1))
}

fn lerp_point(p: StrokePoint, q: StrokePoint, t: f32) -> StrokePoint {
    StrokePoint::new(
        p.x + (q.x - p.x) * t,
        p.y + (q.y - p.y) * t,
        p.pressure + (q.pressure - p.pressure) * t,
    )
}

fn polyline_length(pts: &[StrokePoint]) -> f32 {
    pts.windows(2)
        .map(|w| w[0].pos().distance(w[1].pos()))
        .sum()
}

/// Cuts the part of `points` within `reach` of the sweep axis.
///
/// `closed` marks an explicitly closed outline (first point repeated at the end, as in
/// recognised rectangles): a piece running through the start/end point is re-joined so a
/// cut rectangle becomes one open polyline rather than two.
pub fn cut_polyline(
    points: &[StrokePoint],
    closed: bool,
    sweep: &EraserSweep,
    reach: f32,
) -> CutOutcome {
    let n = points.len();
    if n == 0 {
        return CutOutcome::Untouched;
    }
    let inside = |p: &StrokePoint| sweep.axis_distance(p.pos()) <= reach;
    if n == 1 {
        return if inside(&points[0]) {
            CutOutcome::Erased
        } else {
            CutOutcome::Untouched
        };
    }

    let mut pieces: Vec<Vec<StrokePoint>> = Vec::new();
    let mut current: Vec<StrokePoint> = Vec::new();
    let mut touched = false;
    let starts_outside = !inside(&points[0]);
    if starts_outside {
        current.push(points[0]);
    } else {
        touched = true;
    }

    for i in 0..n - 1 {
        let (p, q) = (points[i], points[i + 1]);
        match erased_interval(p.pos(), q.pos(), sweep, reach) {
            None => {
                if current.is_empty() {
                    current.push(p);
                }
                current.push(q);
            }
            Some((t0, t1)) => {
                touched = true;
                if t0 > 0.0 {
                    if current.is_empty() {
                        current.push(p);
                    }
                    current.push(lerp_point(p, q, t0));
                }
                if !current.is_empty() {
                    pieces.push(std::mem::take(&mut current));
                }
                if t1 < 1.0 {
                    current.push(lerp_point(p, q, t1));
                    current.push(q);
                }
            }
        }
    }
    let ends_outside = !current.is_empty();
    if ends_outside {
        pieces.push(current);
    }
    if !touched {
        return CutOutcome::Untouched;
    }

    // Closed outline cut somewhere in the middle: the last piece continues into the first.
    if closed && starts_outside && ends_outside && pieces.len() >= 2 {
        let first = pieces.remove(0);
        let last = pieces.last_mut().expect("at least one piece left");
        last.extend(first.into_iter().skip(1));
    }

    pieces.retain(|p| p.len() >= 2 && polyline_length(p) >= MIN_PIECE_LENGTH);
    if pieces.is_empty() {
        CutOutcome::Erased
    } else {
        CutOutcome::Split(pieces)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(x0: f32, x1: f32, y: f32, n: usize) -> Vec<StrokePoint> {
        (0..=n)
            .map(|i| StrokePoint::new(x0 + (x1 - x0) * i as f32 / n as f32, y, 0.5))
            .collect()
    }

    fn sweep_at(x: f32, y: f32, r: f32) -> EraserSweep {
        EraserSweep::new(Vec2::new(x, y), Vec2::new(x, y), r)
    }

    #[test]
    fn erasing_the_middle_splits_into_two_pieces() {
        let pts = line(0.0, 100.0, 50.0, 10);
        let CutOutcome::Split(pieces) = cut_polyline(&pts, false, &sweep_at(50.0, 50.0, 5.0), 5.0)
        else {
            panic!("expected a split");
        };
        assert_eq!(pieces.len(), 2);
        let end_of_first = pieces[0].last().unwrap().x;
        let start_of_second = pieces[1][0].x;
        assert!((end_of_first - 45.0).abs() < 0.01, "{end_of_first}");
        assert!((start_of_second - 55.0).abs() < 0.01, "{start_of_second}");
        assert_eq!(pieces[0][0].x, 0.0);
        assert_eq!(pieces[1].last().unwrap().x, 100.0);
    }

    #[test]
    fn erasing_an_end_shortens_the_stroke() {
        let pts = line(0.0, 100.0, 50.0, 10);
        let CutOutcome::Split(pieces) =
            cut_polyline(&pts, false, &sweep_at(100.0, 50.0, 10.0), 10.0)
        else {
            panic!("expected a split");
        };
        assert_eq!(pieces.len(), 1);
        assert!((pieces[0].last().unwrap().x - 90.0).abs() < 0.01);
    }

    #[test]
    fn sweep_between_samples_cuts_lines_it_crosses() {
        // The eraser jumps from above to below the line: both samples miss it, the sweep
        // between them must not.
        let pts = line(0.0, 100.0, 50.0, 4);
        let sweep = EraserSweep::new(Vec2::new(30.0, 0.0), Vec2::new(30.0, 100.0), 3.0);
        assert!(
            matches!(cut_polyline(&pts, false, &sweep, 3.0), CutOutcome::Split(p) if p.len() == 2)
        );
    }

    #[test]
    fn missing_and_covering_strokes() {
        let pts = line(0.0, 10.0, 50.0, 4);
        assert_eq!(
            cut_polyline(&pts, false, &sweep_at(5.0, 200.0, 5.0), 5.0),
            CutOutcome::Untouched
        );
        assert_eq!(
            cut_polyline(&pts, false, &sweep_at(5.0, 50.0, 30.0), 30.0),
            CutOutcome::Erased
        );
    }

    #[test]
    fn cut_rectangle_stays_one_open_polyline() {
        let rect = vec![
            StrokePoint::new(0.0, 0.0, 0.5),
            StrokePoint::new(100.0, 0.0, 0.5),
            StrokePoint::new(100.0, 60.0, 0.5),
            StrokePoint::new(0.0, 60.0, 0.5),
            StrokePoint::new(0.0, 0.0, 0.5),
        ];
        // Cut the middle of the right edge.
        let CutOutcome::Split(pieces) = cut_polyline(&rect, true, &sweep_at(100.0, 30.0, 4.0), 4.0)
        else {
            panic!("expected a split");
        };
        assert_eq!(pieces.len(), 1);
        let p = &pieces[0];
        assert!((p[0].y - 34.0).abs() < 0.01 && p[0].x == 100.0);
        assert!((p.last().unwrap().y - 26.0).abs() < 0.01);
        // Corners survive: (100,60) (0,60) (0,0) (100,0) are all in the piece.
        for c in [(100.0, 60.0), (0.0, 60.0), (0.0, 0.0), (100.0, 0.0)] {
            assert!(p.iter().any(|q| (q.x, q.y) == c), "missing corner {c:?}");
        }
    }

    #[test]
    fn interval_is_exact_for_perpendicular_crossing() {
        let sweep = sweep_at(50.0, 0.0, 10.0);
        let (t0, t1) =
            erased_interval(Vec2::new(0.0, 0.0), Vec2::new(100.0, 0.0), &sweep, 10.0).unwrap();
        assert!((t0 - 0.4).abs() < 1e-4 && (t1 - 0.6).abs() < 1e-4);
    }
}

//! Geometric shape recognition: snaps hand-drawn rectangles / quadrilaterals to a clean,
//! sharp-cornered rectangle the moment the pen lifts.
//!
//! The whole pipeline is linear in the number of input samples plus one fixed-size pass
//! over a resampled outline, so it runs in microseconds inside `finish_stroke` — the
//! snapped shape is what the very next frame shows:
//!
//! 1. **Closure gate** (O(n), first): pen-up must land close to pen-down relative to the
//!    shape size; a short overshoot past the start corner is trimmed. Open strokes bail out
//!    here before any other work.
//! 2. **Resample** the closed loop to [`RESAMPLE`] equidistant samples (zoom independent)
//!    and smooth away hand jitter.
//! 3. **Corner detection** ("short straw"): at a corner the chord spanning a window of
//!    samples is much shorter than the typical chord. Exactly four corners are required, so
//!    circles (no corners), triangles and pentagons are rejected.
//! 4. **Validation**: every side must be straight and every corner roughly 90°. Sloppy
//!    quadrilaterals (slight trapezoids / parallelograms) pass and get squared up.
//! 5. **Snap**: the dominant orientation comes from the side directions (4θ averaging),
//!    each side is placed at the mean position of its samples, rotations within
//!    [`AXIS_SNAP_DEG`] become exactly axis-aligned. Corners are emitted in the user's
//!    drawing direction, starting at the corner nearest the pen-down point.

use super::point::{StrokePoint, Vec2};

/// Rectangles rotated less than this are snapped to perfectly axis-aligned ones.
pub const AXIS_SNAP_DEG: f32 = 8.0;
/// Number of samples the closed outline is resampled to.
pub const RESAMPLE: usize = 128;

const MIN_POINTS: usize = 6;
const MIN_DIAGONAL: f32 = 24.0;
/// Pen-up may land at most this share of the mean side length away from pen-down.
const CLOSURE_RATIO: f32 = 0.25;
/// …but tiny shapes always get at least this much slack (world units).
const CLOSURE_MIN: f32 = 6.0;
/// The closing point is searched for in the stroke's tail only (overshoot trimming).
const CLOSURE_SEARCH_FROM: f32 = 0.6;
/// Longest overshoot past the closing point that is silently dropped (share of a side).
const MAX_OVERSHOOT: f32 = 0.35;
/// Half-width (in samples) of the chord window used for corner detection.
const STRAW_WINDOW: usize = 5;
/// A sample is a corner candidate when its chord is below this share of the median chord.
const CORNER_STRAW_RATIO: f32 = 0.86;
/// Samples next to a corner are ignored when fitting the sides (rounded corners).
const CORNER_GUARD: usize = 2;
/// Accepted corner angles: 90° ± this.
const MAX_CORNER_ERROR_DEG: f32 = 28.0;
/// Side straightness: max / RMS distance of samples to the side's line, relative to its length.
const MAX_EDGE_DEVIATION: f32 = 0.12;
const MAX_EDGE_RMS: f32 = 0.05;
/// Traced length must be consistent with a single pass around the snapped perimeter.
const MIN_PATH_RATIO: f32 = 0.75;
const MAX_PATH_RATIO: f32 = 1.5;

/// Result of a successful rectangle fit.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RectangleFit {
    /// Corners in drawing order (no closing duplicate).
    pub corners: [Vec2; 4],
    /// Rotation of the rectangle in radians (0 when axis-aligned).
    pub angle: f32,
    pub width: f32,
    pub height: f32,
}

/// Detects rectangular intent. On success returns 5 points: the 4 corners followed by the
/// first corner again (an explicitly closed loop), all carrying the stroke's mean pressure.
pub fn detect_and_snap_rectangle(points: &[StrokePoint]) -> Option<Vec<StrokePoint>> {
    let fit = fit_rectangle(points)?;
    let pressure = points.iter().map(|p| p.pressure).sum::<f32>() / points.len() as f32;
    let mut out: Vec<StrokePoint> = fit
        .corners
        .iter()
        .map(|c| StrokePoint::new(c.x.max(0.0), c.y.max(0.0), pressure))
        .collect();
    out.push(out[0]);
    Some(out)
}

pub fn fit_rectangle(points: &[StrokePoint]) -> Option<RectangleFit> {
    if points.len() < MIN_POINTS {
        return None;
    }
    let pts: Vec<Vec2> = points.iter().map(|p| p.pos()).collect();
    let (min, max) = pts.iter().fold(
        (Vec2::new(f32::MAX, f32::MAX), Vec2::new(f32::MIN, f32::MIN)),
        |(lo, hi), p| {
            (
                Vec2::new(lo.x.min(p.x), lo.y.min(p.y)),
                Vec2::new(hi.x.max(p.x), hi.y.max(p.y)),
            )
        },
    );
    if !(max - min).length().is_finite() || (max - min).length() < MIN_DIAGONAL {
        return None;
    }

    // 1. Closure gate.
    let closed = close_loop(&pts)?;
    let outline = &pts[..=closed.end];

    // 2. Resample + smooth.
    let samples = smooth_closed(&resample_closed(outline, closed.perimeter, RESAMPLE), 2);

    // 3. Corners.
    let corners = find_corners(&samples)?;

    // 4. Sides: line fit, straightness, corner angles.
    let sides = fit_sides(&samples, &corners)?;
    let mut turn_sign = 0.0f32;
    for k in 0..4 {
        let (a, b) = (sides[(k + 3) % 4].dir, sides[k].dir);
        let turn = a.cross(b).atan2(a.dot(b));
        if (turn.abs().to_degrees() - 90.0).abs() > MAX_CORNER_ERROR_DEG {
            return None;
        }
        // Convex: every corner turns the same way.
        if turn_sign != 0.0 && turn.signum() != turn_sign {
            return None;
        }
        turn_sign = turn.signum();
    }

    // 5. Orientation and placement.
    let (c4, s4) = sides.iter().fold((0.0f32, 0.0f32), |(c, s), side| {
        let phi = side.dir.angle();
        (
            c + side.length * (4.0 * phi).cos(),
            s + side.length * (4.0 * phi).sin(),
        )
    });
    let angle = s4.atan2(c4) / 4.0;
    let frame = Frame::new(angle);
    let mut u_edges = Vec::with_capacity(2);
    let mut v_edges = Vec::with_capacity(2);
    let mut kinds = [false; 4];
    for (k, side) in sides.iter().enumerate() {
        let along_u = side.dir.dot(frame.u).abs() >= side.dir.dot(frame.v).abs();
        kinds[k] = along_u;
        // A side running along `u` fixes a `v` coordinate and vice versa.
        if along_u {
            v_edges.push(side.centroid.dot(frame.v));
        } else {
            u_edges.push(side.centroid.dot(frame.u));
        }
    }
    if kinds[0] == kinds[1] || kinds[1] == kinds[2] || kinds[2] == kinds[3] {
        return None;
    }
    let (u_min, u_max) = (u_edges[0].min(u_edges[1]), u_edges[0].max(u_edges[1]));
    let (v_min, v_max) = (v_edges[0].min(v_edges[1]), v_edges[0].max(v_edges[1]));
    let (w, h) = (u_max - u_min, v_max - v_min);
    let (min_side, max_side) = (w.min(h), w.max(h));
    if min_side < 8.0_f32.max(0.06 * max_side) {
        return None;
    }
    let ratio = closed.perimeter / (2.0 * (w + h));
    if !(MIN_PATH_RATIO..=MAX_PATH_RATIO).contains(&ratio) {
        return None;
    }

    // Build the clean rectangle, snapping near-axis rotations to exactly 0.
    let center = frame.to_world((u_min + u_max) * 0.5, (v_min + v_max) * 0.5);
    let snapped = if angle.abs() < AXIS_SNAP_DEG.to_radians() {
        0.0
    } else {
        angle
    };
    let out_frame = Frame::new(snapped);
    let (hw, hh) = (w * 0.5, h * 0.5);
    let mut rect: Vec<Vec2> = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        .iter()
        .map(|&(u, v)| center + out_frame.u * u + out_frame.v * v)
        .collect();

    // Match the user's drawing direction and start corner.
    let drawn = polygon_area(outline).signum();
    if drawn != 0.0 && drawn != polygon_area(&rect).signum() {
        rect.reverse();
    }
    let start = rect
        .iter()
        .enumerate()
        .min_by(|a, b| a.1.distance(pts[0]).total_cmp(&b.1.distance(pts[0])))
        .map_or(0, |(i, _)| i);
    rect.rotate_left(start);

    Some(RectangleFit {
        corners: [rect[0], rect[1], rect[2], rect[3]],
        angle: snapped,
        width: w,
        height: h,
    })
}

// ------------------------------------------------------------------------- closure

struct ClosedLoop {
    /// Index of the sample that closes the loop (overshoot after it is dropped).
    end: usize,
    /// Traced length of the loop including the closing gap.
    perimeter: f32,
}

/// The pen-down / pen-up proximity test. Finds the tail sample closest to the start point
/// (so an overshoot past the starting corner is tolerated) and checks the remaining gap.
fn close_loop(pts: &[Vec2]) -> Option<ClosedLoop> {
    let n = pts.len();
    let start = pts[0];
    let from = ((n as f32 * CLOSURE_SEARCH_FROM) as usize).clamp(1, n - 1);
    let (end, gap) = (from..n)
        .map(|i| (i, pts[i].distance(start)))
        .min_by(|a, b| a.1.total_cmp(&b.1))?;
    let traced: f32 = pts[..=end].windows(2).map(|w| w[0].distance(w[1])).sum();
    let perimeter = traced + gap;
    let mean_side = perimeter / 4.0;
    if gap > (CLOSURE_RATIO * mean_side).max(CLOSURE_MIN) {
        return None;
    }
    let overshoot: f32 = pts[end..].windows(2).map(|w| w[0].distance(w[1])).sum();
    if overshoot > MAX_OVERSHOOT * mean_side {
        return None;
    }
    Some(ClosedLoop { end, perimeter })
}

/// `k` points equally spaced along the closed polyline `pts` (closing segment included).
fn resample_closed(pts: &[Vec2], perimeter: f32, k: usize) -> Vec<Vec2> {
    let n = pts.len();
    let step = perimeter / k as f32;
    let mut out = Vec::with_capacity(k);
    let (mut seg, mut seg_start) = (0usize, 0.0f32);
    for i in 0..k {
        let d = i as f32 * step;
        loop {
            let (a, b) = (pts[seg], pts[(seg + 1) % n]);
            let len = a.distance(b);
            if seg_start + len >= d || seg + 1 >= n {
                let t = if len > f32::EPSILON {
                    ((d - seg_start) / len).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                out.push(a.lerp(b, t));
                break;
            }
            seg_start += len;
            seg += 1;
        }
    }
    out
}

/// Cyclic `[1 2 1]` smoothing, `passes` times.
fn smooth_closed(pts: &[Vec2], passes: usize) -> Vec<Vec2> {
    let n = pts.len();
    let mut cur = pts.to_vec();
    for _ in 0..passes {
        cur = (0..n)
            .map(|i| (cur[(i + n - 1) % n] + cur[i] * 2.0 + cur[(i + 1) % n]) * 0.25)
            .collect();
    }
    cur
}

// ------------------------------------------------------------------------- corners

/// Indices (ascending) of exactly four corners in the resampled loop.
fn find_corners(q: &[Vec2]) -> Option<[usize; 4]> {
    let k = q.len();
    let w = STRAW_WINDOW;
    let straws: Vec<f32> = (0..k)
        .map(|i| q[(i + w) % k].distance(q[(i + k - w) % k]))
        .collect();
    let mut sorted = straws.clone();
    sorted.sort_by(f32::total_cmp);
    let median = sorted[k / 2];
    if median <= f32::EPSILON {
        return None;
    }
    let threshold = CORNER_STRAW_RATIO * median;
    let mut corners = Vec::with_capacity(4);
    for i in 0..k {
        let s = straws[i];
        if s >= threshold {
            continue;
        }
        // Strict local minimum within the window (ties resolved towards the first index).
        let is_min = (1..=w).all(|d| s < straws[(i + k - d) % k])
            && (1..=w).all(|d| s <= straws[(i + d) % k]);
        if is_min {
            corners.push(i);
            if corners.len() > 4 {
                return None;
            }
        }
    }
    (corners.len() == 4).then(|| [corners[0], corners[1], corners[2], corners[3]])
}

struct Side {
    /// Unit direction, oriented along the drawing direction.
    dir: Vec2,
    centroid: Vec2,
    length: f32,
}

/// Fits a line to the samples between consecutive corners and checks straightness.
fn fit_sides(q: &[Vec2], corners: &[usize; 4]) -> Option<[Side; 4]> {
    let k = q.len();
    let mut sides: Vec<Side> = Vec::with_capacity(4);
    for c in 0..4 {
        let (a, b) = (corners[c], corners[(c + 1) % 4]);
        let span = (b + k - a) % k;
        if span < 3 {
            return None;
        }
        let guard = if span > 2 * CORNER_GUARD + 3 {
            CORNER_GUARD
        } else {
            0
        };
        let samples: Vec<Vec2> = (guard..=span - guard).map(|d| q[(a + d) % k]).collect();
        let m = samples.len() as f32;
        let centroid = samples.iter().fold(Vec2::ZERO, |acc, &p| acc + p) * (1.0 / m);
        let (mut sxx, mut syy, mut sxy) = (0.0f32, 0.0f32, 0.0f32);
        for p in &samples {
            let d = *p - centroid;
            sxx += d.x * d.x;
            syy += d.y * d.y;
            sxy += d.x * d.y;
        }
        let mut dir = Vec2::from_angle(0.5 * (2.0 * sxy).atan2(sxx - syy));
        if dir.dot(q[b] - q[a]) < 0.0 {
            dir = dir * -1.0;
        }
        let normal = dir.perp();
        let (mut lo, mut hi, mut max_dev, mut sq) = (f32::MAX, f32::MIN, 0.0f32, 0.0f32);
        for d in 0..=span {
            let p = q[(a + d) % k] - centroid;
            let t = p.dot(dir);
            lo = lo.min(t);
            hi = hi.max(t);
        }
        for p in &samples {
            let dev = (*p - centroid).dot(normal).abs();
            max_dev = max_dev.max(dev);
            sq += dev * dev;
        }
        let length = hi - lo;
        let rms = (sq / m).sqrt();
        if length <= 1.0
            || max_dev > (MAX_EDGE_DEVIATION * length).max(3.0)
            || rms > (MAX_EDGE_RMS * length).max(1.5)
        {
            return None;
        }
        sides.push(Side {
            dir,
            centroid,
            length,
        });
    }
    let mut it = sides.into_iter();
    Some([it.next()?, it.next()?, it.next()?, it.next()?])
}

// ------------------------------------------------------------------------- helpers

/// Orthonormal frame rotated by `angle`.
#[derive(Debug, Clone, Copy)]
struct Frame {
    u: Vec2,
    v: Vec2,
}

impl Frame {
    fn new(angle: f32) -> Self {
        let u = Vec2::from_angle(angle);
        Self { u, v: u.perp() }
    }

    fn to_world(self, u: f32, v: f32) -> Vec2 {
        self.u * u + self.v * v
    }
}

/// Signed shoelace area.
pub fn polygon_area(poly: &[Vec2]) -> f32 {
    if poly.len() < 3 {
        return 0.0;
    }
    let mut a = 0.0;
    for i in 0..poly.len() {
        a += poly[i].cross(poly[(i + 1) % poly.len()]);
    }
    a * 0.5
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    /// Deterministic pseudo-random jitter (no external RNG dependency).
    fn jitter(i: usize, amp: f32) -> f32 {
        let x = ((i as f32 * 12.9898).sin() * 43758.547).fract();
        (x * 2.0 - 1.0) * amp
    }

    fn trace(corners: &[Vec2], steps: usize, wobble: f32, offset: Vec2) -> Vec<StrokePoint> {
        let mut out = Vec::new();
        let mut i = 0;
        for seg in corners.windows(2) {
            for k in 0..steps {
                let p = seg[0].lerp(seg[1], k as f32 / steps as f32);
                out.push(StrokePoint::new(
                    offset.x + p.x + jitter(i, wobble),
                    offset.y + p.y + jitter(i + 7, wobble),
                    0.5,
                ));
                i += 1;
            }
        }
        out
    }

    fn hand_drawn_rect(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        angle_deg: f32,
        wobble: f32,
    ) -> Vec<StrokePoint> {
        let rot = angle_deg.to_radians();
        let corners: Vec<Vec2> = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h), (0.0, 0.0)]
            .iter()
            .map(|&(a, b)| Vec2::new(a, b).rotate(rot))
            .collect();
        let mut out = trace(&corners, 25, wobble, Vec2::new(x, y));
        // Slight overshoot past the starting corner, as people usually do.
        let p = Vec2::new(4.0, 0.0).rotate(rot);
        out.push(StrokePoint::new(x + p.x, y + p.y, 0.5));
        out
    }

    fn assert_axis_aligned_rectangle(out: &[StrokePoint]) {
        assert_eq!(out.len(), 5);
        assert_eq!(out[0], out[4]);
        for w in out.windows(2) {
            let dx = (w[1].x - w[0].x).abs();
            let dy = (w[1].y - w[0].y).abs();
            assert!(dx < 1e-3 || dy < 1e-3, "edge not axis aligned: {dx} {dy}");
        }
        for i in 0..4 {
            let (a, b, c) = (out[i].pos(), out[i + 1].pos(), out[(i + 2) % 4].pos());
            assert!((b - a).dot(c - b).abs() < 1e-2, "corner {i} is not 90°");
        }
    }

    #[test]
    fn detects_and_axis_aligns_wobbly_rectangle() {
        let pts = hand_drawn_rect(100.0, 80.0, 200.0, 120.0, 3.0, 3.0);
        let out = detect_and_snap_rectangle(&pts).expect("rectangle expected");
        assert_axis_aligned_rectangle(&out);
        // Size close to what was drawn.
        let w = (out[0].x - out[2].x).abs();
        let h = (out[0].y - out[2].y).abs();
        assert!(
            (w - 200.0).abs() < 12.0 && (h - 120.0).abs() < 12.0,
            "{w}x{h}"
        );
    }

    #[test]
    fn keeps_intentional_rotation() {
        let pts = hand_drawn_rect(300.0, 300.0, 160.0, 100.0, 30.0, 1.5);
        let fit = fit_rectangle(&pts).expect("rotated rectangle expected");
        assert!(
            (fit.angle.abs().to_degrees() - 30.0).abs() < 3.0,
            "{}",
            fit.angle.to_degrees()
        );
    }

    #[test]
    fn squares_up_a_sloppy_quadrilateral() {
        // Slight trapezoid: the bottom edge is longer and the right side leans outwards.
        let quad = [
            Vec2::new(0.0, 0.0),
            Vec2::new(180.0, 6.0),
            Vec2::new(196.0, 130.0),
            Vec2::new(-8.0, 124.0),
            Vec2::new(0.0, 0.0),
        ];
        let pts = trace(&quad, 30, 1.0, Vec2::new(60.0, 60.0));
        let out = detect_and_snap_rectangle(&pts).expect("quadrilateral should snap");
        assert_axis_aligned_rectangle(&out);
    }

    #[test]
    fn starts_mid_edge_and_closes_with_a_small_gap() {
        // Start in the middle of the top edge, stop a bit short of the start.
        let path = [
            Vec2::new(100.0, 0.0),
            Vec2::new(200.0, 0.0),
            Vec2::new(200.0, 140.0),
            Vec2::new(0.0, 140.0),
            Vec2::new(0.0, 0.0),
            Vec2::new(86.0, 2.0),
        ];
        let pts = trace(&path, 24, 1.0, Vec2::new(40.0, 40.0));
        let out = detect_and_snap_rectangle(&pts).expect("rectangle expected");
        assert_axis_aligned_rectangle(&out);
    }

    #[test]
    fn rejects_circle() {
        let pts: Vec<StrokePoint> = (0..=80)
            .map(|i| {
                let a = 2.0 * PI * i as f32 / 80.0;
                StrokePoint::new(200.0 + 60.0 * a.cos(), 200.0 + 60.0 * a.sin(), 0.5)
            })
            .collect();
        assert!(detect_and_snap_rectangle(&pts).is_none());
    }

    #[test]
    fn rejects_triangle_and_pentagon() {
        let tri = [
            Vec2::new(0.0, 0.0),
            Vec2::new(200.0, 0.0),
            Vec2::new(100.0, 150.0),
            Vec2::new(0.0, 0.0),
        ];
        assert!(detect_and_snap_rectangle(&trace(&tri, 30, 0.0, Vec2::new(50.0, 50.0))).is_none());
        let penta: Vec<Vec2> = (0..=5)
            .map(|i| Vec2::from_angle(2.0 * PI * i as f32 / 5.0) * 100.0)
            .collect();
        assert!(
            detect_and_snap_rectangle(&trace(&penta, 30, 0.0, Vec2::new(200.0, 200.0))).is_none()
        );
    }

    #[test]
    fn rejects_open_stroke_and_straight_line() {
        let line: Vec<StrokePoint> = (0..40)
            .map(|i| StrokePoint::new(i as f32 * 5.0, 10.0, 0.5))
            .collect();
        assert!(detect_and_snap_rectangle(&line).is_none());
        // U shape (three sides only).
        let u = [
            Vec2::new(0.0, 0.0),
            Vec2::new(0.0, 100.0),
            Vec2::new(150.0, 100.0),
            Vec2::new(150.0, 0.0),
            Vec2::new(150.0, 0.0),
        ];
        assert!(detect_and_snap_rectangle(&trace(&u, 30, 0.0, Vec2::new(20.0, 20.0))).is_none());
    }

    #[test]
    fn rejects_rectangle_with_a_long_tail() {
        let mut pts = hand_drawn_rect(100.0, 100.0, 200.0, 120.0, 0.0, 0.0);
        for i in 1..40 {
            pts.push(StrokePoint::new(
                104.0 + i as f32 * 4.0,
                100.0 - i as f32 * 3.0,
                0.5,
            ));
        }
        assert!(detect_and_snap_rectangle(&pts).is_none());
    }

    #[test]
    fn rejects_double_traced_loop() {
        let r = [
            Vec2::new(0.0, 0.0),
            Vec2::new(200.0, 0.0),
            Vec2::new(200.0, 100.0),
            Vec2::new(0.0, 100.0),
            Vec2::new(0.0, 0.0),
            Vec2::new(200.0, 0.0),
            Vec2::new(200.0, 100.0),
            Vec2::new(0.0, 100.0),
            Vec2::new(0.0, 0.0),
        ];
        assert!(detect_and_snap_rectangle(&trace(&r, 20, 0.5, Vec2::new(10.0, 10.0))).is_none());
    }
}

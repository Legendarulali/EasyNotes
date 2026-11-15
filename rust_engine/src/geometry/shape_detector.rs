//! Geometric shape recognition: the moment the pen lifts, a hand-drawn stroke that looks
//! like a line, a circle / ellipse, a polygon or a five-pointed star is replaced by clean
//! geometry.
//!
//! The pipeline is linear in the number of input samples plus a few passes over a
//! fixed-size resampled outline, so it runs in a few tens of microseconds inside
//! `finish_stroke` (release build) and the snapped shape is what the very next frame shows:
//!
//! 1. **Closure gate** (O(n), first): pen-up must land close to pen-down relative to the
//!    traced length; a short overshoot past the start is trimmed. *Open* strokes can only
//!    become a **straight line**: the ends must be far apart, no sample may stray from the
//!    chord by more than a small share of its length, and the path may not double back.
//! 2. **Resample** the closed loop to [`RESAMPLE`] equidistant samples (zoom independent)
//!    and smooth away hand jitter.
//! 3. **Corners**: Ramer–Douglas–Peucker on the loop, then corners that are too close
//!    together (one rounded corner) are merged and nearly flat vertices dropped.
//! 4. **Polygon** (3–8 corners): every side must be straight — small deviation and RMS
//!    from its fitted line, and no *bow* (a side bulging consistently to one side is an
//!    arc). With 5+ corners the loop's turning must also be concentrated at the corners,
//!    which tells an octagon from a circle. The total turning of the sides separates
//!    simple polygons (±360°) from a pentagram (±720°). Vertices are the intersections
//!    of neighbouring side lines, so rounded corners come out sharp.
//!    * 3 → triangle: equilateral when regular, otherwise the side nearest to horizontal
//!      is levelled.
//!    * 4 → trapezoid when one pair of sides is parallel and the other clearly converges
//!      (isosceles when the legs mirror each other); else the sharp 90° rectangle /
//!      square (sloppy quadrilaterals are squared up); else a clean quadrilateral.
//!    * 5 with ±720° turning → regular five-pointed star (pentagram).
//!    * 5–8 → clean polygon, regular when sides and angles are uniform.
//! 5. **Ellipse**: otherwise the loop's area moments define an ellipse; the samples'
//!    radial residual against it must be small, the traced length must match its
//!    perimeter and no sharp corner may stick out. An aspect ratio within 15 % of 1:1
//!    makes a circle.
//!
//! Closed shapes keep the user's drawing direction and start at the vertex nearest to
//! the pen-down point; rotations within [`AXIS_SNAP_DEG`] of the axes are removed.

use super::point::{StrokePoint, Vec2};
use super::stroke::ShapeKind;
use std::f32::consts::{PI, TAU};

/// Rectangles, trapezoids and ellipses rotated less than this are made axis-aligned.
pub const AXIS_SNAP_DEG: f32 = 8.0;
/// Number of samples the closed outline is resampled to.
pub const RESAMPLE: usize = 128;
/// The resampled outline is smoothed over at least this distance (world units, std. dev.
/// of the smoothing kernel), with 2–6 `[1 2 1]` passes.
const SMOOTHING_RADIUS: f32 = 2.0;

const MIN_POINTS: usize = 6;
const MIN_DIAGONAL: f32 = 24.0;
/// Handwriting guard: closed letters ("O", "0", "D") written at text size must stay ink,
/// so circles / ellipses need a larger bounding-box diagonal (56 units ≈ 15 mm)…
const MIN_ELLIPSE_DIAGONAL: f32 = 56.0;
/// …and so do polygons with 5+ corners and stars. Triangles and rectangles keep the
/// general minimum (small boxes and bullets still snap).
const MIN_COMPLEX_POLYGON_DIAGONAL: f32 = 40.0;

// Closure gate.
/// Pen-up may land at most this share of a quarter of the traced length from pen-down.
const CLOSURE_RATIO: f32 = 0.25;
/// …but tiny shapes always get at least this much slack (world units).
const CLOSURE_MIN: f32 = 6.0;
/// The closing point is searched for in the stroke's tail only (overshoot trimming).
const CLOSURE_SEARCH_FROM: f32 = 0.6;
/// Longest overshoot past the closing point that is silently dropped (share of a quarter
/// of the traced length).
const MAX_OVERSHOOT: f32 = 0.35;

// Straight lines (open strokes).
/// Shorter strokes stay ink (letters such as "l" or "1" are not lines). 48 units ≈ 13 mm.
const MIN_LINE_LENGTH: f32 = 48.0;
/// Largest distance of any sample from the start–end chord, relative to its length…
const LINE_MAX_DEVIATION: f32 = 0.045;
/// …with this much absolute slack for short lines (world units).
const LINE_MIN_SLACK: f32 = 2.0;
/// Traced length / chord: rejects strokes that wiggle or double back along the line.
const LINE_MAX_PATH_RATIO: f32 = 1.1;
/// Lines this close to horizontal / vertical become exactly horizontal / vertical.
const LINE_AXIS_SNAP_DEG: f32 = 5.0;

// Corners.
/// RDP tolerance, relative to the loop's bounding-box diagonal.
const RDP_EPSILON: f32 = 0.035;
/// Vertices turning less than this are not corners.
const MIN_TURN_DEG: f32 = 25.0;
/// Corners closer than this (in resampled samples, ≈ 6 % of the perimeter) merge.
const MIN_EDGE_SAMPLES: usize = 8;
/// Samples next to a corner are ignored when fitting the sides (rounded corners).
const CORNER_GUARD: usize = 2;
const MAX_POLYGON_SIDES: usize = 8;
/// Half-width (samples) of the window around a corner that its turning is summed over.
const CORNER_WINDOW: usize = 3;
/// RDP vertices move to the sharpest turn within this many samples (≈ 4 % of the loop),
/// measured between chords spanning [`CORNER_SNAP_WINDOW`] samples (wide enough to
/// average out hand jitter, which also turns sharply but only over a sample or two).
const CORNER_SNAP_SAMPLES: usize = 5;
const CORNER_SNAP_WINDOW: usize = 5;
/// With 5+ corners, each must make at least this share of its turn within the window.
const MIN_CORNER_SHARPNESS: f32 = 0.5;

// Sides.
/// Side straightness: max / RMS distance of samples to the side's line, and the mean
/// signed distance to its chord (bow), all relative to its length.
const MAX_EDGE_DEVIATION: f32 = 0.12;
const MAX_EDGE_RMS: f32 = 0.05;
const MAX_EDGE_BOW: f32 = 0.045;
/// Absolute slack (world units) for those limits on short sides; the bow and RMS get a
/// fraction of it (after resampling and smoothing, jitter is well below a unit).
const EDGE_SLACK: f32 = 0.8;
/// A corner must turn this many times more than the sides beside it bend (see
/// [`Side::straight_beside`]): separates polygons, even with slightly bowed sides, from
/// curves that RDP cut into short pieces.
const CORNER_OVER_BOW: f32 = 20.0;

// Rectangles.
/// Accepted rectangle corners: 90° ± this.
const MAX_CORNER_ERROR_DEG: f32 = 28.0;
/// Rectangles whose short / long side ratio exceeds this become squares.
const SQUARE_RATIO: f32 = 0.92;

// Trapezoids.
/// The parallel pair may differ by at most this angle.
const PARALLEL_TOL_DEG: f32 = 10.0;
/// The legs must converge by at least this angle (sloppy rectangles stay rectangles).
const TRAPEZOID_MIN_CONVERGENCE_DEG: f32 = 18.0;
/// The shorter parallel side must be at most this share of the longer one.
const TRAPEZOID_MAX_BASE_RATIO: f32 = 0.88;
/// Legs mirror each other (isosceles) when the bases' midpoints are offset by at most
/// this share of half the width difference.
const ISOSCELES_TOLERANCE: f32 = 0.35;

// Regular polygons and stars.
/// 5–8-gons become regular when the side lengths' coefficient of variation and every
/// corner's deviation from the regular angle stay within these…
const REGULAR_SIDE_CV: f32 = 0.15;
const REGULAR_ANGLE_TOL_DEG: f32 = 12.0;
/// …triangles only when they are close to equilateral (a scalene triangle stays scalene).
const EQUILATERAL_SIDE_CV: f32 = 0.06;
const EQUILATERAL_ANGLE_TOL_DEG: f32 = 6.0;
/// A regular polygon / star this close to "vertex up" or "side up" is snapped upright.
const ORIENTATION_SNAP_DEG: f32 = 6.0;
/// Each pentagram tip turns ~144°; accept down to this.
const STAR_MIN_TURN_DEG: f32 = 108.0;
const STAR_MAX_RADIUS_CV: f32 = 0.25;

// Ellipses.
const ELLIPSE_MEAN_RESIDUAL: f32 = 0.07;
const ELLIPSE_MAX_RESIDUAL: f32 = 0.2;
/// Traced length / ellipse perimeter.
const ELLIPSE_PATH_RATIO: (f32, f32) = (0.85, 1.25);
/// Half-width (samples) of the window used to look for sharp corners.
const ELLIPSE_TURN_WINDOW: usize = 4;
/// Minor / major axis ratio at or above which the ellipse becomes a circle.
const CIRCLE_ASPECT: f32 = 0.85;
/// Largest distance between the true ellipse and its polygon (world units).
const ELLIPSE_CHORD_TOLERANCE: f32 = 0.2;
const ELLIPSE_MIN_VERTICES: usize = 32;
const ELLIPSE_MAX_VERTICES: usize = 128;

// Every closed shape.
/// Traced length must be consistent with a single pass around the snapped outline.
const MIN_PATH_RATIO: f32 = 0.75;
const MAX_PATH_RATIO: f32 = 1.5;

/// What a stroke was recognised as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShapeClass {
    Line,
    Circle,
    Ellipse,
    Triangle,
    Rectangle,
    Square,
    Trapezoid,
    /// Any other clean four-sided polygon (parallelogram, kite, …).
    Quadrilateral,
    Pentagon,
    Hexagon,
    Heptagon,
    Octagon,
    /// Regular five-pointed star drawn as a pentagram (self-intersecting outline).
    Star,
}

impl ShapeClass {
    /// How a stroke with this shape is stored and rendered.
    pub fn stroke_shape(self) -> ShapeKind {
        match self {
            ShapeClass::Line => ShapeKind::Line,
            ShapeClass::Circle | ShapeClass::Ellipse => ShapeKind::Ellipse,
            ShapeClass::Rectangle | ShapeClass::Square => ShapeKind::Rectangle,
            _ => ShapeKind::Polygon,
        }
    }

    fn polygon(sides: usize) -> Option<Self> {
        Some(match sides {
            3 => ShapeClass::Triangle,
            4 => ShapeClass::Quadrilateral,
            5 => ShapeClass::Pentagon,
            6 => ShapeClass::Hexagon,
            7 => ShapeClass::Heptagon,
            8 => ShapeClass::Octagon,
            _ => return None,
        })
    }
}

/// A recognised shape: its class and the clean geometry replacing the stroke's samples.
#[derive(Debug, Clone, PartialEq)]
pub struct DetectedShape {
    pub kind: ShapeClass,
    /// A line's two end points, or a closed shape's vertices followed by the first vertex
    /// again (an explicitly closed loop). All carry the stroke's mean pressure.
    pub points: Vec<StrokePoint>,
}

/// Recognises the stroke's shape, `None` when it should stay freehand ink.
pub fn detect_shape(points: &[StrokePoint]) -> Option<DetectedShape> {
    if points.len() < MIN_POINTS {
        return None;
    }
    let pts: Vec<Vec2> = points.iter().map(StrokePoint::pos).collect();
    let (lo, hi) = bounds(&pts);
    let diagonal = (hi - lo).length();
    if !diagonal.is_finite() || diagonal < MIN_DIAGONAL {
        return None;
    }
    let (kind, outline) = match close_loop(&pts) {
        Some(closed) => recognize_closed(&pts, &closed)?,
        None => (ShapeClass::Line, fit_line(&pts)?),
    };
    let pressure = points.iter().map(|p| p.pressure).sum::<f32>() / points.len() as f32;
    let mut out: Vec<StrokePoint> = outline
        .iter()
        .map(|c| StrokePoint::new(c.x.max(0.0), c.y.max(0.0), pressure))
        .collect();
    if kind != ShapeClass::Line {
        out.push(out[0]);
    }
    Some(DetectedShape { kind, points: out })
}

// ------------------------------------------------------------------------- lines

fn fit_line(pts: &[Vec2]) -> Option<Vec<Vec2>> {
    let (a, b) = (pts[0], *pts.last()?);
    let chord = a.distance(b);
    if chord < MIN_LINE_LENGTH {
        return None;
    }
    let traced: f32 = pts.windows(2).map(|w| w[0].distance(w[1])).sum();
    if traced > LINE_MAX_PATH_RATIO * chord {
        return None;
    }
    let dir = (b - a) * (1.0 / chord);
    let normal = dir.perp();
    let slack = (LINE_MAX_DEVIATION * chord).max(LINE_MIN_SLACK);
    if pts.iter().any(|p| (*p - a).dot(normal).abs() > slack) {
        return None;
    }
    // Least-squares direction through all samples; the ends are projected onto it.
    let c = mean(pts);
    let mut fitted = principal_direction(pts, c).unwrap_or(dir);
    if fitted.dot(dir) < 0.0 {
        fitted = fitted * -1.0;
    }
    let mut p0 = c + fitted * (a - c).dot(fitted);
    let mut p1 = c + fitted * (b - c).dot(fitted);
    let angle = (p1 - p0).angle();
    let axis = snap_to_axes(angle, LINE_AXIS_SNAP_DEG);
    if axis != angle {
        let mid = (p0 + p1) * 0.5;
        let half = Vec2::from_angle(axis) * (p0.distance(p1) * 0.5);
        p0 = mid - half;
        p1 = mid + half;
    }
    Some(vec![p0, p1])
}

// ------------------------------------------------------------------------- closure

struct ClosedLoop {
    /// Index of the sample that closes the loop (overshoot after it is dropped).
    end: usize,
    /// Traced length of the loop including the closing gap.
    perimeter: f32,
}

/// The pen-down / pen-up proximity test. Finds the tail sample closest to the start point
/// (so an overshoot past the start is tolerated) and checks the remaining gap.
fn close_loop(pts: &[Vec2]) -> Option<ClosedLoop> {
    let n = pts.len();
    let start = pts[0];
    let from = ((n as f32 * CLOSURE_SEARCH_FROM) as usize).clamp(1, n - 1);
    let (end, gap) = (from..n)
        .map(|i| (i, pts[i].distance(start)))
        .min_by(|a, b| a.1.total_cmp(&b.1))?;
    let traced: f32 = pts[..=end].windows(2).map(|w| w[0].distance(w[1])).sum();
    let perimeter = traced + gap;
    let quarter = perimeter / 4.0;
    if gap > (CLOSURE_RATIO * quarter).max(CLOSURE_MIN) {
        return None;
    }
    let overshoot: f32 = pts[end..].windows(2).map(|w| w[0].distance(w[1])).sum();
    if overshoot > MAX_OVERSHOOT * quarter {
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

/// The closed outline resampled to [`RESAMPLE`] points and smoothed over a fixed distance
/// rather than a fixed number of samples: on small loops the samples are close together
/// and pen jitter would otherwise look like corners.
fn loop_samples(outline: &[Vec2], perimeter: f32) -> Vec<Vec2> {
    smooth_closed(
        &resample_closed(outline, perimeter, RESAMPLE),
        smoothing_passes(perimeter / RESAMPLE as f32),
    )
}

/// `[1 2 1]` passes giving a kernel of [`SMOOTHING_RADIUS`] at this sample spacing.
fn smoothing_passes(spacing: f32) -> usize {
    ((2.0 * (SMOOTHING_RADIUS / spacing).powi(2)).ceil() as usize).clamp(2, 6)
}

/// Samples next to a corner that smoothing has rounded off: [`CORNER_GUARD`], more when
/// the loop was smoothed harder (the rounding spreads over ~2 kernel widths).
fn corner_guard(q: &[Vec2]) -> usize {
    let k = q.len();
    let spacing = (0..8)
        .map(|i| q[i * k / 8].distance(q[(i * k / 8 + 1) % k]))
        .sum::<f32>()
        / 8.0;
    let kernel = (smoothing_passes(spacing) as f32 / 2.0).sqrt();
    CORNER_GUARD.max((2.0 * kernel).ceil() as usize)
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

/// What the user drew, for orienting the clean shape.
struct Drawn {
    pen_down: Vec2,
    /// Sign of the traced loop's area (drawing direction).
    sign: f32,
    /// Traced length of the loop.
    perimeter: f32,
}

fn recognize_closed(pts: &[Vec2], closed: &ClosedLoop) -> Option<(ShapeClass, Vec<Vec2>)> {
    let outline = &pts[..=closed.end];
    let q = loop_samples(outline, closed.perimeter);
    let drawn = Drawn {
        pen_down: pts[0],
        sign: polygon_area(outline).signum(),
        perimeter: closed.perimeter,
    };
    let (lo, hi) = bounds(&q);
    let diagonal = (hi - lo).length();
    let corners = find_corners(&q, RDP_EPSILON * diagonal);
    if (3..=MAX_POLYGON_SIDES).contains(&corners.len()) {
        if let Some((kind, outline)) = fit_polygon(&q, &corners, &drawn) {
            let complex = outline.len() >= 5 || kind == ShapeClass::Star;
            if !complex || diagonal >= MIN_COMPLEX_POLYGON_DIAGONAL {
                return Some((kind, outline));
            }
        }
    }
    if diagonal < MIN_ELLIPSE_DIAGONAL {
        return None;
    }
    fit_ellipse(&q, &drawn)
}

// ------------------------------------------------------------------------- corners

/// Indices (ascending) of the loop's dominant corners: Ramer–Douglas–Peucker between the
/// two samples farthest apart, then merging of crowded corners and flat vertices.
fn find_corners(q: &[Vec2], epsilon: f32) -> Vec<usize> {
    let c = mean(q);
    let far = |from: Vec2| {
        (0..q.len())
            .max_by(|&i, &j| q[i].distance(from).total_cmp(&q[j].distance(from)))
            .unwrap_or(0)
    };
    let a = far(c);
    let b = far(q[a]);
    if a == b || epsilon <= 0.0 {
        return Vec::new();
    }
    let mut corners = vec![a];
    rdp(q, a, b, epsilon, &mut corners);
    corners.push(b);
    rdp(q, b, a, epsilon, &mut corners);
    corners.sort_unstable();
    corners.dedup();
    simplify_corners(q, corners)
}

/// Appends (in loop order) the RDP vertices strictly between `from` and `to`.
fn rdp(q: &[Vec2], from: usize, to: usize, epsilon: f32, out: &mut Vec<usize>) {
    let k = q.len();
    let span = (to + k - from) % k;
    if span < 2 {
        return;
    }
    let (p, r) = (q[from], q[to]);
    let (mut best, mut best_d) = (from, 0.0f32);
    for d in 1..span {
        let i = (from + d) % k;
        let dist = segment_distance(q[i], p, r);
        if dist > best_d {
            best = i;
            best_d = dist;
        }
    }
    if best_d > epsilon {
        rdp(q, from, best, epsilon, out);
        out.push(best);
        rdp(q, best, to, epsilon, out);
    }
}

fn simplify_corners(q: &[Vec2], mut c: Vec<usize>) -> Vec<usize> {
    let k = q.len();
    // Turning over a short window: peaks at corners (also smoothed / rounded ones).
    let (w, r) = (CORNER_SNAP_WINDOW, CORNER_SNAP_SAMPLES);
    let local_turn = |i: usize| signed_turn(q[i] - q[(i + k - w) % k], q[(i + w) % k] - q[i]).abs();
    // RDP can place a vertex just beside a corner (on a side running parallel to the
    // chord it split), or two vertices at both ends of a rounded corner: snapping every
    // vertex to the turning peak nearby puts them on the corner (and merges such pairs).
    for ci in c.iter_mut() {
        *ci = (0..=2 * r)
            .map(|d| (*ci + k + d - r) % k)
            .max_by(|&a, &b| local_turn(a).total_cmp(&local_turn(b)))
            .unwrap_or(*ci);
    }
    c.sort_unstable();
    c.dedup();
    loop {
        let n = c.len();
        if n < 3 {
            return c;
        }
        // Two corners close together are one (rounded) corner: keep their midpoint.
        if let Some(i) = (0..n).find(|&i| (c[(i + 1) % n] + k - c[i]) % k < MIN_EDGE_SAMPLES) {
            let j = (i + 1) % n;
            let span = (c[j] + k - c[i]) % k;
            c[i] = (c[i] + span / 2) % k;
            c.remove(j);
            c.sort_unstable();
            c.dedup();
            continue;
        }
        // Drop the flattest vertex while it barely turns.
        let turn = |i: usize| {
            let (a, b, d) = (q[c[(i + n - 1) % n]], q[c[i]], q[c[(i + 1) % n]]);
            signed_turn(b - a, d - b).abs()
        };
        let (i, t) = (0..n)
            .map(|i| (i, turn(i)))
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap_or((0, PI));
        if t < MIN_TURN_DEG.to_radians() {
            c.remove(i);
            continue;
        }
        return c;
    }
}

/// How sharp the least sharp corner is: the share of the turn between its two fitted
/// sides that the outline makes within [`CORNER_WINDOW`] samples of it. A drawn corner
/// (even a slightly rounded one) scores near 1; a vertex that RDP placed on a curve
/// scores roughly the window's share of the neighbouring arcs.
fn corner_sharpness(q: &[Vec2], corners: &[usize], fitted_turns: &[f32]) -> f32 {
    let k = q.len();
    let w = CORNER_WINDOW;
    let step_turn = |i: usize| signed_turn(q[i] - q[(i + k - 1) % k], q[(i + 1) % k] - q[i]);
    corners
        .iter()
        .zip(fitted_turns)
        .map(|(&c, &fitted)| {
            let local: f32 = (0..=2 * w).map(|d| step_turn((c + k + d - w) % k)).sum();
            if fitted.abs() <= f32::EPSILON {
                0.0
            } else {
                local.abs() / fitted.abs()
            }
        })
        .fold(f32::INFINITY, f32::min)
}

// ------------------------------------------------------------------------- polygons

#[derive(Debug, Clone, Copy)]
struct Side {
    /// Unit direction, oriented along the drawing direction.
    dir: Vec2,
    centroid: Vec2,
    length: f32,
    /// Mean signed distance of the samples from their chord (world units, unsigned).
    bow: f32,
    chord: f32,
}

impl Side {
    /// Whether this side is straight enough next to a corner turning by `turn` (radians):
    /// an arc turning about `12 · bow / chord`, a corner must turn [`CORNER_OVER_BOW`]
    /// times more than its sides bend.
    fn straight_beside(&self, turn: f32) -> bool {
        self.bow <= (turn.abs() / CORNER_OVER_BOW * self.chord).max(0.25 * EDGE_SLACK)
    }
}

/// Fits a line to the samples between two corners and checks that they are straight.
fn fit_side(q: &[Vec2], a: usize, b: usize) -> Option<Side> {
    let k = q.len();
    let span = (b + k - a) % k;
    if span < 3 {
        return None;
    }
    let guard = corner_guard(q);
    let guard = if span > 2 * guard + 3 { guard } else { 0 };
    let samples: Vec<Vec2> = (guard..=span - guard).map(|d| q[(a + d) % k]).collect();
    let m = samples.len() as f32;
    let centroid = mean(&samples);
    let mut dir = principal_direction(&samples, centroid)?;
    if dir.dot(q[b] - q[a]) < 0.0 {
        dir = dir * -1.0;
    }
    let normal = dir.perp();
    let (mut lo, mut hi) = (f32::MAX, f32::MIN);
    for d in 0..=span {
        let t = (q[(a + d) % k] - centroid).dot(dir);
        lo = lo.min(t);
        hi = hi.max(t);
    }
    let (mut max_dev, mut sq) = (0.0f32, 0.0f32);
    for p in &samples {
        let dev = (*p - centroid).dot(normal).abs();
        max_dev = max_dev.max(dev);
        sq += dev * dev;
    }
    let length = hi - lo;
    let rms = (sq / m).sqrt();
    // Bow: an arc bulges to one side of its chord all along, a hand-drawn side does not.
    let (s0, s1) = (samples[0], samples[samples.len() - 1]);
    let chord = s0.distance(s1);
    let bow = if chord > f32::EPSILON {
        let n = (s1 - s0).perp() * (1.0 / chord);
        samples.iter().map(|p| (*p - s0).dot(n)).sum::<f32>() / m
    } else {
        f32::INFINITY
    };
    if length <= 1.0
        || max_dev > (MAX_EDGE_DEVIATION * length).max(EDGE_SLACK)
        || rms > (MAX_EDGE_RMS * length).max(0.5 * EDGE_SLACK)
        || bow.abs() > (MAX_EDGE_BOW * chord).max(0.25 * EDGE_SLACK)
    {
        return None;
    }
    Some(Side {
        dir,
        centroid,
        length,
        bow: bow.abs(),
        chord,
    })
}

fn fit_polygon(q: &[Vec2], corners: &[usize], drawn: &Drawn) -> Option<(ShapeClass, Vec<Vec2>)> {
    // Fit the sides. A corner that barely turns, or turns hardly more than its sides
    // bend (a vertex RDP put on a curve), is no corner: drop the weakest and refit.
    let mut corners = corners.to_vec();
    let sides = loop {
        let n = corners.len();
        if n < 3 {
            return None;
        }
        let sides = (0..n)
            .map(|i| fit_side(q, corners[i], corners[(i + 1) % n]))
            .collect::<Option<Vec<Side>>>()?;
        let weakest = (0..n)
            .map(|i| {
                let (before, after) = (&sides[(i + n - 1) % n], &sides[i]);
                let turn = signed_turn(before.dir, after.dir);
                let sharp = turn.abs() >= MIN_TURN_DEG.to_radians()
                    && before.straight_beside(turn)
                    && after.straight_beside(turn);
                (i, turn.abs(), sharp)
            })
            .filter(|&(_, _, sharp)| !sharp)
            .min_by(|a, b| a.1.total_cmp(&b.1));
        match weakest {
            Some((i, _, _)) => {
                corners.remove(i);
            }
            None => break sides,
        }
    };
    let corners = corners.as_slice();
    let n = corners.len();
    // Turn at corner i: from side i-1 to side i.
    let turns: Vec<f32> = (0..n)
        .map(|i| signed_turn(sides[(i + n - 1) % n].dir, sides[i].dir))
        .collect();
    // Curves cut into many short "sides" (small ellipses, a "D", a heart) pass the
    // straightness test, but their vertices are not corners.
    if n >= 5 && corner_sharpness(q, corners, &turns) < MIN_CORNER_SHARPNESS {
        return None;
    }
    let winding = (turns.iter().sum::<f32>() / TAU).round() as i32;
    let convex = turns.iter().all(|t| t.signum() == turns[0].signum());
    let verts = corner_points(q, corners, &sides);
    let is_star = n == 5
        && winding.abs() == 2
        && convex
        && turns
            .iter()
            .all(|t| t.abs() >= STAR_MIN_TURN_DEG.to_radians());
    let (kind, verts) = if is_star {
        (ShapeClass::Star, fit_star(&verts)?)
    } else if winding.abs() == 1 && is_simple(&verts) {
        match n {
            3 => (ShapeClass::Triangle, fit_triangle(verts)),
            4 => fit_quadrilateral(&sides, verts)?,
            _ => {
                let regular = if convex {
                    regularize(&verts, REGULAR_SIDE_CV, REGULAR_ANGLE_TOL_DEG)
                } else {
                    None
                };
                (ShapeClass::polygon(n)?, regular.unwrap_or(verts))
            }
        }
    } else {
        return None;
    };
    if !plausible_outline(&verts, drawn.perimeter) {
        return None;
    }
    Some((kind, orient(verts, drawn)))
}

/// Corner `i` is where the lines of sides `i - 1` and `i` meet (sharp even when the drawn
/// corner was rounded); the corner sample itself when they are close to parallel.
fn corner_points(q: &[Vec2], corners: &[usize], sides: &[Side]) -> Vec<Vec2> {
    let n = corners.len();
    (0..n)
        .map(|i| {
            let (s0, s1) = (&sides[(i + n - 1) % n], &sides[i]);
            let sample = q[corners[i]];
            line_intersection(s0.centroid, s0.dir, s1.centroid, s1.dir)
                .filter(|p| p.distance(sample) <= 0.35 * s0.length.min(s1.length))
                .unwrap_or(sample)
        })
        .collect()
}

fn fit_triangle(verts: Vec<Vec2>) -> Vec<Vec2> {
    if let Some(regular) = regularize(&verts, EQUILATERAL_SIDE_CV, EQUILATERAL_ANGLE_TOL_DEG) {
        return regular;
    }
    // Level the side closest to horizontal (the base) when it is nearly horizontal.
    let mut v = verts;
    let (i, dev) = (0..3)
        .map(|i| (i, horizontal_deviation_deg(v[i], v[(i + 1) % 3])))
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .unwrap_or((0, 90.0));
    if dev <= AXIS_SNAP_DEG {
        let j = (i + 1) % 3;
        let y = (v[i].y + v[j].y) * 0.5;
        v[i].y = y;
        v[j].y = y;
    }
    v
}

fn fit_quadrilateral(sides: &[Side], verts: Vec<Vec2>) -> Option<(ShapeClass, Vec<Vec2>)> {
    if let Some(trapezoid) = fit_trapezoid(sides, &verts) {
        return Some((ShapeClass::Trapezoid, trapezoid));
    }
    if let Some(rectangle) = square_up(sides) {
        return Some(rectangle);
    }
    Some((ShapeClass::Quadrilateral, verts))
}

/// One pair of opposite sides parallel, the other clearly converging.
fn fit_trapezoid(sides: &[Side], verts: &[Vec2]) -> Option<Vec<Vec2>> {
    for j in 0..2 {
        let (b0, b1) = (sides[j], sides[j + 2]);
        let (l0, l1) = (sides[j + 1], sides[(j + 3) % 4]);
        if line_angle_deg(b0.dir, b1.dir) > PARALLEL_TOL_DEG
            || line_angle_deg(l0.dir, l1.dir) < TRAPEZOID_MIN_CONVERGENCE_DEG
        {
            continue;
        }
        // Frame along the mean direction of the bases, snapped to the axes.
        let psi = snap_to_axes(mean_line_angle(&[b0, b1]), AXIS_SNAP_DEG);
        let (u, v) = (Vec2::from_angle(psi), Vec2::from_angle(psi).perp());
        // Base 0 runs from vertex j to j + 1, base 1 from j + 2 to j + 3.
        let bases = [
            ([j, j + 1], b0.centroid.dot(v)),
            ([j + 2, (j + 3) % 4], b1.centroid.dot(v)),
        ];
        let s = |i: usize| verts[i].dot(u);
        let width = |ids: [usize; 2]| (s(ids[1]) - s(ids[0])).abs();
        let middle = |ids: [usize; 2]| (s(ids[0]) + s(ids[1])) * 0.5;
        let (w0, w1) = (width(bases[0].0), width(bases[1].0));
        if w0.min(w1) < 4.0 || w0.min(w1) / w0.max(w1) > TRAPEZOID_MAX_BASE_RATIO {
            return None;
        }
        let (m0, m1) = (middle(bases[0].0), middle(bases[1].0));
        let isosceles = (m0 - m1).abs() <= ISOSCELES_TOLERANCE * 0.5 * (w0 - w1).abs();
        let mut out = verts.to_vec();
        for (ids, h) in bases {
            let (w, m) = (width(ids), middle(ids));
            let centre = if isosceles { (m0 + m1) * 0.5 } else { m };
            for i in ids {
                let side = if s(i) >= m { 0.5 } else { -0.5 };
                out[i] = u * (centre + side * w) + v * h;
            }
        }
        return Some(out);
    }
    None
}

/// The sharp 90° rectangle / square for a quadrilateral with roughly right corners.
fn square_up(sides: &[Side]) -> Option<(ShapeClass, Vec<Vec2>)> {
    let mut turn_sign = 0.0f32;
    for k in 0..4 {
        let turn = signed_turn(sides[(k + 3) % 4].dir, sides[k].dir);
        if (turn.abs().to_degrees() - 90.0).abs() > MAX_CORNER_ERROR_DEG {
            return None;
        }
        if turn_sign != 0.0 && turn.signum() != turn_sign {
            return None;
        }
        turn_sign = turn.signum();
    }
    // Dominant orientation from the side directions (4θ averaging), each side placed at
    // the mean position of its samples.
    let (c4, s4) = sides.iter().fold((0.0f32, 0.0f32), |(c, s), side| {
        let phi = side.dir.angle();
        (
            c + side.length * (4.0 * phi).cos(),
            s + side.length * (4.0 * phi).sin(),
        )
    });
    let angle = s4.atan2(c4) / 4.0;
    let u = Vec2::from_angle(angle);
    let v = u.perp();
    let mut u_edges = Vec::with_capacity(2);
    let mut v_edges = Vec::with_capacity(2);
    let mut along = [false; 4];
    for (k, side) in sides.iter().enumerate() {
        along[k] = side.dir.dot(u).abs() >= side.dir.dot(v).abs();
        // A side running along `u` fixes a `v` coordinate and vice versa.
        if along[k] {
            v_edges.push(side.centroid.dot(v));
        } else {
            u_edges.push(side.centroid.dot(u));
        }
    }
    if along[0] == along[1] || along[1] == along[2] || along[2] == along[3] {
        return None;
    }
    let (u_min, u_max) = (u_edges[0].min(u_edges[1]), u_edges[0].max(u_edges[1]));
    let (v_min, v_max) = (v_edges[0].min(v_edges[1]), v_edges[0].max(v_edges[1]));
    let (mut w, mut h) = (u_max - u_min, v_max - v_min);
    let (min_side, max_side) = (w.min(h), w.max(h));
    if min_side < 8.0_f32.max(0.06 * max_side) {
        return None;
    }
    let class = if min_side / max_side >= SQUARE_RATIO {
        let side = (w + h) * 0.5;
        (w, h) = (side, side);
        ShapeClass::Square
    } else {
        ShapeClass::Rectangle
    };
    let center = u * ((u_min + u_max) * 0.5) + v * ((v_min + v_max) * 0.5);
    let snapped = snap_to_axes(angle, AXIS_SNAP_DEG);
    let (u, v) = (Vec2::from_angle(snapped), Vec2::from_angle(snapped).perp());
    let (hw, hh) = (w * 0.5, h * 0.5);
    let rect = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        .iter()
        .map(|&(a, b)| center + u * a + v * b)
        .collect();
    Some((class, rect))
}

/// The regular polygon closest to `verts` when its sides and angles are uniform enough
/// (side-length CV ≤ `side_cv`, every turn within `angle_tol_deg` of the regular one):
/// same centre, mean radius, best-fitting rotation (snapped upright when close).
fn regularize(verts: &[Vec2], side_cv: f32, angle_tol_deg: f32) -> Option<Vec<Vec2>> {
    let n = verts.len();
    let lengths: Vec<f32> = (0..n)
        .map(|i| verts[i].distance(verts[(i + 1) % n]))
        .collect();
    let mean_len = lengths.iter().sum::<f32>() / n as f32;
    if mean_len <= f32::EPSILON {
        return None;
    }
    let var = lengths
        .iter()
        .map(|l| (l - mean_len) * (l - mean_len))
        .sum::<f32>()
        / n as f32;
    if var.sqrt() / mean_len > side_cv {
        return None;
    }
    let step = TAU / n as f32;
    for i in 0..n {
        let turn = signed_turn(
            verts[i] - verts[(i + n - 1) % n],
            verts[(i + 1) % n] - verts[i],
        );
        if (turn.abs() - step).abs() > angle_tol_deg.to_radians() {
            return None;
        }
    }
    let center = mean(verts);
    let radius = verts.iter().map(|p| p.distance(center)).sum::<f32>() / n as f32;
    let phase = fit_phase(verts, center, n);
    let dir = if polygon_area(verts) < 0.0 { -1.0 } else { 1.0 };
    Some(place_on_circle(
        center, radius, phase, step, dir, verts[0], 1,
    ))
}

/// Regular pentagram through the five tips (in drawing order).
fn fit_star(tips: &[Vec2]) -> Option<Vec<Vec2>> {
    let center = mean(tips);
    let radii: Vec<f32> = tips.iter().map(|t| t.distance(center)).collect();
    let r = radii.iter().sum::<f32>() / 5.0;
    let var = radii.iter().map(|x| (x - r) * (x - r)).sum::<f32>() / 5.0;
    if r <= f32::EPSILON || var.sqrt() / r > STAR_MAX_RADIUS_CV {
        return None;
    }
    let step = TAU / 5.0;
    let phase = fit_phase(tips, center, 5);
    // Consecutive tips of a pentagram are two steps (144°) apart.
    let turn = wrap_angle((tips[1] - center).angle() - (tips[0] - center).angle());
    let dir = if turn < 0.0 { -1.0 } else { 1.0 };
    Some(place_on_circle(center, r, phase, step, dir, tips[0], 2))
}

/// Rotation (mod `2π / n`) of an `n`-fold symmetric vertex set, snapped to "vertex up" or
/// "side up" when within [`ORIENTATION_SNAP_DEG`].
fn fit_phase(verts: &[Vec2], center: Vec2, n: usize) -> f32 {
    let nf = n as f32;
    let (c, s) = verts.iter().fold((0.0f32, 0.0f32), |(c, s), p| {
        let a = (*p - center).angle() * nf;
        (c + a.cos(), s + a.sin())
    });
    let phase = s.atan2(c) / nf;
    let step = TAU / nf;
    // Screen "up" is -y.
    for upright in [-PI / 2.0, -PI / 2.0 + step / 2.0] {
        let diff = phase - upright;
        let diff = diff - (diff / step).round() * step;
        if diff.abs() <= ORIENTATION_SNAP_DEG.to_radians() {
            return phase - diff;
        }
    }
    phase
}

/// `n` points on a circle: the first at the `phase`-aligned angle nearest to `first`, the
/// following ones `stride` steps further each in direction `dir`.
fn place_on_circle(
    center: Vec2,
    radius: f32,
    phase: f32,
    step: f32,
    dir: f32,
    first: Vec2,
    stride: usize,
) -> Vec<Vec2> {
    let n = (TAU / step).round() as usize;
    let a0 = (first - center).angle();
    let start = phase + ((a0 - phase) / step).round() * step;
    (0..n)
        .map(|i| center + Vec2::from_angle(start + dir * step * (i * stride) as f32) * radius)
        .collect()
}

/// Sides are long enough and the traced length matches one pass around the outline.
fn plausible_outline(verts: &[Vec2], traced: f32) -> bool {
    let n = verts.len();
    let lengths: Vec<f32> = (0..n)
        .map(|i| verts[i].distance(verts[(i + 1) % n]))
        .collect();
    let longest = lengths.iter().copied().fold(0.0f32, f32::max);
    let total: f32 = lengths.iter().sum();
    if total <= f32::EPSILON || lengths.iter().any(|&l| l < (0.04 * longest).max(6.0)) {
        return false;
    }
    (MIN_PATH_RATIO..=MAX_PATH_RATIO).contains(&(traced / total))
}

/// Matches the user's drawing direction and starts at the vertex nearest to pen-down.
fn orient(mut verts: Vec<Vec2>, drawn: &Drawn) -> Vec<Vec2> {
    let sign = polygon_area(&verts).signum();
    if drawn.sign != 0.0 && sign != 0.0 && sign != drawn.sign {
        verts.reverse();
    }
    let start = verts
        .iter()
        .enumerate()
        .min_by(|a, b| {
            a.1.distance(drawn.pen_down)
                .total_cmp(&b.1.distance(drawn.pen_down))
        })
        .map_or(0, |(i, _)| i);
    verts.rotate_left(start);
    verts
}

/// No two non-adjacent edges cross.
fn is_simple(verts: &[Vec2]) -> bool {
    let n = verts.len();
    for i in 0..n {
        for j in i + 2..n {
            if i == 0 && j == n - 1 {
                continue;
            }
            let (a, b) = (verts[i], verts[(i + 1) % n]);
            let (c, d) = (verts[j], verts[(j + 1) % n]);
            let o1 = (b - a).cross(c - a);
            let o2 = (b - a).cross(d - a);
            let o3 = (d - c).cross(a - c);
            let o4 = (d - c).cross(b - c);
            if o1 * o2 < 0.0 && o3 * o4 < 0.0 {
                return false;
            }
        }
    }
    true
}

// ------------------------------------------------------------------------- ellipses

fn fit_ellipse(q: &[Vec2], drawn: &Drawn) -> Option<(ShapeClass, Vec<Vec2>)> {
    let k = q.len();
    // Area moments of the loop (shoelace / Green's theorem), in f64 around the sample
    // mean so far-away whiteboard coordinates keep their precision.
    let origin = mean(q);
    let (mut area, mut cx, mut cy) = (0.0f64, 0.0f64, 0.0f64);
    let (mut sxx, mut syy, mut sxy) = (0.0f64, 0.0f64, 0.0f64);
    for i in 0..k {
        let (p, r) = (q[i] - origin, q[(i + 1) % k] - origin);
        let (x0, y0, x1, y1) = (p.x as f64, p.y as f64, r.x as f64, r.y as f64);
        let cross = x0 * y1 - x1 * y0;
        area += cross;
        cx += (x0 + x1) * cross;
        cy += (y0 + y1) * cross;
        sxx += (x0 * x0 + x0 * x1 + x1 * x1) * cross;
        syy += (y0 * y0 + y0 * y1 + y1 * y1) * cross;
        sxy += (x0 * y1 + 2.0 * x0 * y0 + 2.0 * x1 * y1 + x1 * y0) * cross;
    }
    area *= 0.5;
    if !area.is_finite() || area.abs() < 1.0 {
        return None;
    }
    cx /= 6.0 * area;
    cy /= 6.0 * area;
    let mxx = sxx / (12.0 * area) - cx * cx;
    let myy = syy / (12.0 * area) - cy * cy;
    let mxy = sxy / (24.0 * area) - cx * cy;
    // A filled ellipse with semi-axes a ≥ b has covariance eigenvalues a²/4 and b²/4.
    let half_trace = 0.5 * (mxx + myy);
    let disc = (0.25 * (mxx - myy) * (mxx - myy) + mxy * mxy).sqrt();
    let (l1, l2) = (half_trace + disc, half_trace - disc);
    if !(l2 > 0.0 && l1.is_finite()) {
        return None;
    }
    let (ra, rb) = ((2.0 * l1.sqrt()) as f32, (2.0 * l2.sqrt()) as f32);
    let theta = (0.5 * (2.0 * mxy).atan2(mxx - myy)) as f32;
    let center = origin + Vec2::new(cx as f32, cy as f32);
    let (u, v) = (Vec2::from_angle(theta), Vec2::from_angle(theta).perp());

    // Every sample must lie close to the ellipse (normalised radial residual).
    let (mut sum, mut worst) = (0.0f32, 0.0f32);
    for p in q {
        let d = *p - center;
        let res = ((d.dot(u) / ra).hypot(d.dot(v) / rb) - 1.0).abs();
        sum += res;
        worst = worst.max(res);
    }
    if sum / k as f32 > ELLIPSE_MEAN_RESIDUAL || worst > ELLIPSE_MAX_RESIDUAL {
        return None;
    }
    // Isoperimetric consistency: the traced length matches the ellipse's perimeter
    // (Ramanujan), so spiky or double-traced loops do not pass.
    let perimeter = PI * (3.0 * (ra + rb) - ((3.0 * ra + rb) * (ra + 3.0 * rb)).sqrt());
    let ratio = drawn.perimeter / perimeter;
    if !(ELLIPSE_PATH_RATIO.0..=ELLIPSE_PATH_RATIO.1).contains(&ratio) {
        return None;
    }
    // No sharp corners: nowhere may the loop turn much faster than the fitted ellipse
    // does at its sharpest point (curvature a / b² at the ends of the major axis).
    let w = ELLIPSE_TURN_WINDOW;
    let window_arc = drawn.perimeter * (2 * w) as f32 / k as f32;
    let allowed = (1.5 * window_arc * ra / (rb * rb) + 20f32.to_radians()).min(PI);
    let sharpest = (0..k)
        .map(|i| signed_turn(q[i] - q[(i + k - w) % k], q[(i + w) % k] - q[i]).abs())
        .fold(0.0f32, f32::max);
    if sharpest > allowed {
        return None;
    }

    let (class, ra, rb, theta) = if rb / ra >= CIRCLE_ASPECT {
        let r = 0.5 * (ra + rb);
        (ShapeClass::Circle, r, r, 0.0)
    } else {
        (
            ShapeClass::Ellipse,
            ra,
            rb,
            snap_to_axes(theta, AXIS_SNAP_DEG),
        )
    };
    let (u, v) = (Vec2::from_angle(theta), Vec2::from_angle(theta).perp());
    let count = (PI / (1.0 - ELLIPSE_CHORD_TOLERANCE / ra).clamp(-1.0, 1.0).acos()).ceil();
    let count = (count as usize).clamp(ELLIPSE_MIN_VERTICES, ELLIPSE_MAX_VERTICES);
    // Start at the pen-down point and run in the drawing direction.
    let d = drawn.pen_down - center;
    let t0 = (d.dot(v) / rb).atan2(d.dot(u) / ra);
    let dir = if drawn.sign < 0.0 { -1.0 } else { 1.0 };
    let outline = (0..count)
        .map(|i| {
            let t = t0 + dir * TAU * i as f32 / count as f32;
            center + u * (ra * t.cos()) + v * (rb * t.sin())
        })
        .collect();
    Some((class, outline))
}

// ------------------------------------------------------------------------- helpers

fn bounds(pts: &[Vec2]) -> (Vec2, Vec2) {
    pts.iter().fold(
        (Vec2::new(f32::MAX, f32::MAX), Vec2::new(f32::MIN, f32::MIN)),
        |(lo, hi), p| {
            (
                Vec2::new(lo.x.min(p.x), lo.y.min(p.y)),
                Vec2::new(hi.x.max(p.x), hi.y.max(p.y)),
            )
        },
    )
}

fn mean(pts: &[Vec2]) -> Vec2 {
    if pts.is_empty() {
        return Vec2::ZERO;
    }
    pts.iter().fold(Vec2::ZERO, |acc, &p| acc + p) * (1.0 / pts.len() as f32)
}

/// Unit direction of the least-squares line through `pts` (around their mean `c`).
fn principal_direction(pts: &[Vec2], c: Vec2) -> Option<Vec2> {
    let (mut sxx, mut syy, mut sxy) = (0.0f32, 0.0f32, 0.0f32);
    for p in pts {
        let d = *p - c;
        sxx += d.x * d.x;
        syy += d.y * d.y;
        sxy += d.x * d.y;
    }
    if sxx + syy <= f32::EPSILON {
        return None;
    }
    Some(Vec2::from_angle(0.5 * (2.0 * sxy).atan2(sxx - syy)))
}

fn segment_distance(p: Vec2, a: Vec2, b: Vec2) -> f32 {
    let ab = b - a;
    let len2 = ab.dot(ab);
    if len2 <= f32::EPSILON {
        return p.distance(a);
    }
    let t = ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
    p.distance(a + ab * t)
}

/// Where the line through `p` along `d` meets the line through `r` along `e`.
fn line_intersection(p: Vec2, d: Vec2, r: Vec2, e: Vec2) -> Option<Vec2> {
    let den = d.cross(e);
    if den.abs() < 1e-4 {
        return None;
    }
    Some(p + d * ((r - p).cross(e) / den))
}

/// Signed angle turning from direction `a` to direction `b`, in `(-π, π]`.
fn signed_turn(a: Vec2, b: Vec2) -> f32 {
    a.cross(b).atan2(a.dot(b))
}

fn wrap_angle(a: f32) -> f32 {
    let a = a % TAU;
    if a > PI {
        a - TAU
    } else if a <= -PI {
        a + TAU
    } else {
        a
    }
}

/// `angle` moved onto the nearest axis direction (multiple of 90°) when within `tol_deg`.
fn snap_to_axes(angle: f32, tol_deg: f32) -> f32 {
    let quarter = PI / 2.0;
    let axis = (angle / quarter).round() * quarter;
    if (angle - axis).abs() <= tol_deg.to_radians() {
        axis
    } else {
        angle
    }
}

/// Angle in degrees between two undirected lines, in `[0, 90]`.
fn line_angle_deg(a: Vec2, b: Vec2) -> f32 {
    a.dot(b).abs().min(1.0).acos().to_degrees()
}

/// How far the segment `a`–`b` is from horizontal, in degrees `[0, 90]`.
fn horizontal_deviation_deg(a: Vec2, b: Vec2) -> f32 {
    line_angle_deg((b - a).normalized(), Vec2::new(1.0, 0.0))
}

/// Length-weighted mean direction (mod π) of the given sides.
fn mean_line_angle(sides: &[Side]) -> f32 {
    let (c, s) = sides.iter().fold((0.0f32, 0.0f32), |(c, s), side| {
        let phi = 2.0 * side.dir.angle();
        (c + side.length * phi.cos(), s + side.length * phi.sin())
    });
    0.5 * s.atan2(c)
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

    /// Deterministic pseudo-random jitter (no external RNG dependency).
    fn jitter(i: usize, amp: f32) -> f32 {
        let x = ((i as f32 * 12.9898).sin() * 43758.547).fract();
        (x * 2.0 - 1.0) * amp
    }

    /// Traces the polyline through `corners` with `steps` samples per segment.
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
        if let Some(last) = corners.last() {
            out.push(StrokePoint::new(offset.x + last.x, offset.y + last.y, 0.5));
        }
        out
    }

    /// A closed loop through `corners` (the first corner is repeated at the end).
    fn closed(corners: &[(f32, f32)], steps: usize, wobble: f32) -> Vec<StrokePoint> {
        let mut path: Vec<Vec2> = corners.iter().map(|&(x, y)| Vec2::new(x, y)).collect();
        path.push(path[0]);
        trace(&path, steps, wobble, Vec2::ZERO)
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

    /// Parametric ellipse traced once (plus the closing sample), with radial wobble.
    fn hand_drawn_ellipse(
        center: Vec2,
        a: f32,
        b: f32,
        angle_deg: f32,
        wobble: f32,
    ) -> Vec<StrokePoint> {
        let rot = angle_deg.to_radians();
        (0..=90)
            .map(|i| {
                let t = TAU * i as f32 / 90.0;
                let r = 1.0 + jitter(i, wobble);
                let p = Vec2::new(a * r * t.cos(), b * r * t.sin()).rotate(rot) + center;
                StrokePoint::new(p.x, p.y, 0.5)
            })
            .collect()
    }

    fn regular(n: usize, center: Vec2, radius: f32, phase_deg: f32) -> Vec<(f32, f32)> {
        (0..n)
            .map(|i| {
                let a = phase_deg.to_radians() + TAU * i as f32 / n as f32;
                let p = center + Vec2::from_angle(a) * radius;
                (p.x, p.y)
            })
            .collect()
    }

    fn detect(points: &[StrokePoint]) -> DetectedShape {
        detect_shape(points).expect("a shape should be recognised")
    }

    fn vertices(shape: &DetectedShape) -> Vec<Vec2> {
        let p = &shape.points;
        assert_eq!(p.first(), p.last(), "closed shapes repeat the first point");
        p[..p.len() - 1].iter().map(StrokePoint::pos).collect()
    }

    fn side_lengths(v: &[Vec2]) -> Vec<f32> {
        (0..v.len())
            .map(|i| v[i].distance(v[(i + 1) % v.len()]))
            .collect()
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

    // ----------------------------------------------------------------- lines

    #[test]
    fn snaps_a_wobbly_line_and_levels_it() {
        let pts = trace(
            &[Vec2::new(100.0, 100.0), Vec2::new(400.0, 108.0)],
            60,
            1.2,
            Vec2::ZERO,
        );
        let s = detect(&pts);
        assert_eq!(s.kind, ShapeClass::Line);
        assert_eq!(s.points.len(), 2);
        assert!((s.points[0].y - s.points[1].y).abs() < 1e-3, "levelled");
        let len = s.points[0].pos().distance(s.points[1].pos());
        assert!((len - 300.0).abs() < 4.0, "{len}");
        assert!(s.points[0].x < s.points[1].x, "keeps the drawing direction");
    }

    #[test]
    fn keeps_the_angle_of_a_diagonal_line() {
        let pts = trace(
            &[Vec2::new(300.0, 300.0), Vec2::new(120.0, 140.0)],
            50,
            1.0,
            Vec2::ZERO,
        );
        let s = detect(&pts);
        assert_eq!(s.kind, ShapeClass::Line);
        let d = s.points[1].pos() - s.points[0].pos();
        let expected = Vec2::new(-180.0, -160.0).angle();
        assert!((d.angle() - expected).abs() < 2f32.to_radians());
    }

    #[test]
    fn curved_short_or_bent_open_strokes_stay_ink() {
        // A gentle arc (sagitta 10 % of the chord).
        let arc: Vec<StrokePoint> = (0..=60)
            .map(|i| {
                let t = i as f32 / 60.0;
                StrokePoint::new(100.0 + 300.0 * t, 200.0 - 120.0 * t * (1.0 - t), 0.5)
            })
            .collect();
        assert!(detect_shape(&arc).is_none());
        // Short straight stroke (a letter "l").
        let short = trace(
            &[Vec2::new(10.0, 10.0), Vec2::new(10.0, 40.0)],
            20,
            0.0,
            Vec2::ZERO,
        );
        assert!(detect_shape(&short).is_none());
        // "L" and zig-zag.
        let l = trace(
            &[
                Vec2::new(0.0, 0.0),
                Vec2::new(0.0, 150.0),
                Vec2::new(120.0, 150.0),
            ],
            30,
            0.0,
            Vec2::new(20.0, 20.0),
        );
        assert!(detect_shape(&l).is_none());
        let zigzag: Vec<Vec2> = (0..12)
            .map(|i| Vec2::new(i as f32 * 25.0, if i % 2 == 0 { 0.0 } else { 20.0 }))
            .collect();
        assert!(detect_shape(&trace(&zigzag, 8, 0.0, Vec2::new(50.0, 50.0))).is_none());
        // Back and forth along a line.
        let back = trace(
            &[
                Vec2::new(0.0, 0.0),
                Vec2::new(200.0, 0.0),
                Vec2::new(60.0, 1.0),
            ],
            30,
            0.0,
            Vec2::new(10.0, 10.0),
        );
        assert!(detect_shape(&back).is_none());
    }

    // ----------------------------------------------------------------- ellipses

    #[test]
    fn detects_a_circle() {
        let center = Vec2::new(300.0, 300.0);
        let s = detect(&hand_drawn_ellipse(center, 80.0, 76.0, 0.0, 0.03));
        assert_eq!(s.kind, ShapeClass::Circle);
        let v = vertices(&s);
        assert!(v.len() >= ELLIPSE_MIN_VERTICES);
        let c = mean(&v);
        assert!(c.distance(center) < 3.0, "{c:?}");
        let r = v[0].distance(c);
        assert!((r - 78.0).abs() < 4.0, "{r}");
        for p in &v {
            assert!((p.distance(c) - r).abs() < 0.05, "perfectly round");
        }
        // Starts where the pen went down (angle 0 → right of the centre).
        assert!(v[0].x > center.x + 60.0);
    }

    #[test]
    fn detects_ellipses_and_keeps_intentional_rotation() {
        let center = Vec2::new(400.0, 300.0);
        // Direction of the vertex farthest from the centre = the major axis.
        let major_axis = |v: &[Vec2]| {
            let c = mean(v);
            v.iter().copied().fold(Vec2::ZERO, |best, p| {
                if (p - c).length() > best.length() {
                    p - c
                } else {
                    best
                }
            })
        };
        let s = detect(&hand_drawn_ellipse(center, 150.0, 60.0, 30.0, 0.02));
        assert_eq!(s.kind, ShapeClass::Ellipse);
        let far = major_axis(&vertices(&s));
        assert!((far.length() - 150.0).abs() < 8.0, "{}", far.length());
        let angle = far.angle().to_degrees().rem_euclid(180.0);
        assert!((angle - 30.0).abs() < 3.0, "{angle}");
        // Nearly axis-aligned ellipses become axis-aligned.
        let s = detect(&hand_drawn_ellipse(center, 150.0, 70.0, 4.0, 0.02));
        assert_eq!(s.kind, ShapeClass::Ellipse);
        let angle = major_axis(&vertices(&s))
            .angle()
            .to_degrees()
            .rem_euclid(180.0);
        assert!(angle.min(180.0 - angle) < 2.0, "{angle}");
    }

    // ----------------------------------------------------------------- polygons

    #[test]
    fn detects_a_triangle_and_levels_its_base() {
        let s = detect(&closed(
            &[(100.0, 300.0), (320.0, 306.0), (180.0, 120.0)],
            30,
            1.0,
        ));
        assert_eq!(s.kind, ShapeClass::Triangle);
        let v = vertices(&s);
        assert_eq!(v.len(), 3);
        let base: Vec<&Vec2> = v.iter().filter(|p| p.y > 250.0).collect();
        assert_eq!(base.len(), 2);
        assert!((base[0].y - base[1].y).abs() < 1e-3, "base levelled");
        // Corners land where the drawn sides meet.
        assert!(v.iter().any(|p| p.distance(Vec2::new(180.0, 120.0)) < 8.0));
    }

    #[test]
    fn regular_triangle_becomes_equilateral() {
        let pts = closed(&regular(3, Vec2::new(300.0, 300.0), 120.0, -88.0), 30, 1.0);
        let s = detect(&pts);
        assert_eq!(s.kind, ShapeClass::Triangle);
        let v = vertices(&s);
        let l = side_lengths(&v);
        assert!(l.iter().all(|x| (x - l[0]).abs() < 0.05), "{l:?}");
        // Snapped upright: apex straight above the centre, flat base.
        let apex = v
            .iter()
            .copied()
            .fold(v[0], |a, p| if p.y < a.y { p } else { a });
        assert!((apex.x - mean(&v).x).abs() < 0.05);
    }

    #[test]
    fn detects_and_axis_aligns_wobbly_rectangle() {
        let pts = hand_drawn_rect(100.0, 80.0, 200.0, 120.0, 3.0, 3.0);
        let s = detect(&pts);
        assert_eq!(s.kind, ShapeClass::Rectangle);
        assert_axis_aligned_rectangle(&s.points);
        let w = (s.points[0].x - s.points[2].x).abs();
        let h = (s.points[0].y - s.points[2].y).abs();
        assert!(
            (w - 200.0).abs() < 12.0 && (h - 120.0).abs() < 12.0,
            "{w}x{h}"
        );
    }

    #[test]
    fn keeps_intentional_rotation() {
        let s = detect(&hand_drawn_rect(300.0, 300.0, 160.0, 100.0, 30.0, 1.5));
        assert_eq!(s.kind, ShapeClass::Rectangle);
        let v = vertices(&s);
        let long = side_lengths(&v)
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .map(|(i, _)| v[(i + 1) % 4] - v[i])
            .unwrap();
        let angle = long.angle().to_degrees().rem_euclid(180.0);
        assert!((angle - 30.0).abs() < 3.0, "{angle}");
    }

    #[test]
    fn squares_up_a_sloppy_quadrilateral() {
        // Slight trapezoid: the bottom edge is longer and the right side leans outwards.
        let s = detect(&closed(
            &[(60.0, 60.0), (240.0, 66.0), (256.0, 190.0), (52.0, 184.0)],
            30,
            1.0,
        ));
        assert_eq!(s.kind, ShapeClass::Rectangle);
        assert_axis_aligned_rectangle(&s.points);
    }

    #[test]
    fn nearly_square_rectangles_become_squares() {
        let s = detect(&hand_drawn_rect(100.0, 100.0, 150.0, 142.0, 0.0, 1.0));
        assert_eq!(s.kind, ShapeClass::Square);
        let l = side_lengths(&vertices(&s));
        assert!(l.iter().all(|x| (x - l[0]).abs() < 1e-2), "{l:?}");
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
        let s = detect(&trace(&path, 24, 1.0, Vec2::new(40.0, 40.0)));
        assert_eq!(s.kind, ShapeClass::Rectangle);
        assert_axis_aligned_rectangle(&s.points);
    }

    #[test]
    fn detects_an_isosceles_trapezoid() {
        let s = detect(&closed(
            &[
                (160.0, 100.0),
                (290.0, 104.0),
                (352.0, 222.0),
                (98.0, 218.0),
            ],
            30,
            1.0,
        ));
        assert_eq!(s.kind, ShapeClass::Trapezoid);
        let v = vertices(&s);
        let mut top: Vec<Vec2> = v.iter().copied().filter(|p| p.y < 160.0).collect();
        let mut bottom: Vec<Vec2> = v.iter().copied().filter(|p| p.y > 160.0).collect();
        assert_eq!((top.len(), bottom.len()), (2, 2));
        top.sort_by(|a, b| a.x.total_cmp(&b.x));
        bottom.sort_by(|a, b| a.x.total_cmp(&b.x));
        assert!((top[0].y - top[1].y).abs() < 1e-3 && (bottom[0].y - bottom[1].y).abs() < 1e-3);
        // Mirror symmetric around one vertical axis.
        let (mt, mb) = (
            (top[0].x + top[1].x) / 2.0,
            (bottom[0].x + bottom[1].x) / 2.0,
        );
        assert!((mt - mb).abs() < 1e-2, "{mt} {mb}");
        assert!((top[1].x - top[0].x - 130.0).abs() < 10.0);
        assert!((bottom[1].x - bottom[0].x - 254.0).abs() < 10.0);
    }

    #[test]
    fn right_trapezoid_keeps_its_right_angle_side() {
        let s = detect(&closed(
            &[
                (100.0, 100.0),
                (220.0, 100.0),
                (320.0, 240.0),
                (100.0, 240.0),
            ],
            30,
            0.5,
        ));
        assert_eq!(s.kind, ShapeClass::Trapezoid);
        let v = vertices(&s);
        let left: Vec<&Vec2> = v.iter().filter(|p| p.x < 140.0).collect();
        assert_eq!(left.len(), 2);
        assert!((left[0].x - left[1].x).abs() < 4.0, "{left:?}");
    }

    #[test]
    fn detects_regular_pentagon_hexagon_and_octagon() {
        for (n, class) in [
            (5, ShapeClass::Pentagon),
            (6, ShapeClass::Hexagon),
            (8, ShapeClass::Octagon),
        ] {
            let pts = closed(&regular(n, Vec2::new(400.0, 400.0), 110.0, 13.0), 24, 1.0);
            let s = detect(&pts);
            assert_eq!(s.kind, class, "{n} sides");
            let v = vertices(&s);
            assert_eq!(v.len(), n);
            let l = side_lengths(&v);
            assert!(l.iter().all(|x| (x - l[0]).abs() < 0.05), "{n}: {l:?}");
            let c = mean(&v);
            assert!(c.distance(Vec2::new(400.0, 400.0)) < 3.0);
        }
    }

    #[test]
    fn irregular_polygons_get_crisp_edges_but_keep_their_shape() {
        // A "house": square body with a roof.
        let house = [
            (100.0, 200.0),
            (100.0, 360.0),
            (300.0, 360.0),
            (300.0, 200.0),
            (200.0, 110.0),
        ];
        let s = detect(&closed(&house, 30, 1.0));
        assert_eq!(s.kind, ShapeClass::Pentagon);
        let v = vertices(&s);
        for (x, y) in house {
            let target = Vec2::new(x, y);
            assert!(
                v.iter().any(|p| p.distance(target) < 8.0),
                "missing corner {target:?} in {v:?}"
            );
        }
    }

    #[test]
    fn detects_a_five_pointed_star() {
        let tips = regular(5, Vec2::new(400.0, 400.0), 150.0, -86.0);
        // Pentagram order: every second tip.
        let order: Vec<(f32, f32)> = (0..5).map(|i| tips[(2 * i) % 5]).collect();
        let s = detect(&closed(&order, 40, 1.5));
        assert_eq!(s.kind, ShapeClass::Star);
        let v = vertices(&s);
        assert_eq!(v.len(), 5);
        let c = mean(&v);
        for p in &v {
            assert!((p.distance(c) - v[0].distance(c)).abs() < 0.05);
        }
        // Consecutive points are 144° apart (the outline crosses itself)…
        let step = wrap_angle((v[1] - c).angle() - (v[0] - c).angle()).abs();
        assert!((step.to_degrees() - 144.0).abs() < 0.1);
        // …and the star stands upright.
        assert!(v.iter().any(|p| (p.x - c.x).abs() < 0.05 && p.y < c.y));
    }

    // ----------------------------------------------------------------- rejections

    #[test]
    fn rejects_open_and_messy_strokes() {
        // U shape (three sides only).
        let u = trace(
            &[
                Vec2::new(0.0, 0.0),
                Vec2::new(0.0, 100.0),
                Vec2::new(150.0, 100.0),
                Vec2::new(150.0, 0.0),
            ],
            30,
            0.0,
            Vec2::new(20.0, 20.0),
        );
        assert!(detect_shape(&u).is_none());
        // Rectangle with a long tail.
        let mut tail = hand_drawn_rect(100.0, 100.0, 200.0, 120.0, 0.0, 0.0);
        for i in 1..40 {
            tail.push(StrokePoint::new(
                104.0 + i as f32 * 4.0,
                100.0 - i as f32 * 3.0,
                0.5,
            ));
        }
        assert!(detect_shape(&tail).is_none());
        // Figure eight.
        let eight: Vec<StrokePoint> = (0..=120)
            .map(|i| {
                let t = TAU * i as f32 / 120.0;
                StrokePoint::new(300.0 + 120.0 * t.sin(), 300.0 + 60.0 * (2.0 * t).sin(), 0.5)
            })
            .collect();
        assert!(detect_shape(&eight).is_none());
        // Spiky scribble.
        let scribble: Vec<(f32, f32)> = (0..14)
            .map(|i| {
                let a = TAU * i as f32 / 14.0;
                let r = if i % 2 == 0 {
                    120.0
                } else {
                    70.0 + 30.0 * (i as f32).sin()
                };
                (300.0 + r * a.cos(), 300.0 + r * a.sin())
            })
            .collect();
        assert!(detect_shape(&closed(&scribble, 8, 0.5)).is_none());
        // Tiny loop.
        assert!(detect_shape(&closed(
            &regular(4, Vec2::new(50.0, 50.0), 8.0, 45.0),
            6,
            0.0
        ))
        .is_none());
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
        assert!(detect_shape(&trace(&r, 20, 0.5, Vec2::new(10.0, 10.0))).is_none());
    }

    #[test]
    fn far_away_whiteboard_coordinates_keep_their_precision() {
        let center = Vec2::new(60_000.0, 45_000.0);
        let s = detect(&hand_drawn_ellipse(center, 90.0, 88.0, 0.0, 0.02));
        assert_eq!(s.kind, ShapeClass::Circle);
        assert!(mean(&vertices(&s)).distance(center) < 3.0);
    }

    /// Closed letters written at text size stay ink.
    #[test]
    fn letter_sized_loops_stay_ink() {
        // A capital "O" on 8 mm ruled paper: ~22 × 30 units.
        let o = hand_drawn_ellipse(Vec2::new(100.0, 100.0), 11.0, 15.0, 0.0, 0.01);
        assert!(detect_shape(&o).is_none());
        // A small hexagon-like scribble of the same size.
        let small = closed(&regular(6, Vec2::new(100.0, 100.0), 13.0, 0.0), 8, 0.2);
        assert!(detect_shape(&small).is_none());
        // Small boxes (check boxes) still snap.
        let boxed = detect(&hand_drawn_rect(50.0, 50.0, 20.0, 20.0, 0.0, 0.3));
        assert_eq!(boxed.kind, ShapeClass::Square);
    }

    // ----------------------------------------------------------------- robustness sweep

    /// Low-frequency wobble plus a little white noise, passed through the engine's own
    /// input cleaning ([`process_input`]) like a real stroke.
    fn hand_path(path: &[Vec2], spacing: f32, wobble: f32, seed: f32) -> Vec<StrokePoint> {
        use crate::geometry::stroke::process_input;
        let noise = |i: usize| {
            let x = ((i as f32 * 12.9898 + seed * 78.233).sin() * 43758.547).fract();
            x * 2.0 - 1.0
        };
        let (mut out, mut s, mut i) = (Vec::new(), 0.0f32, 0usize);
        for w in path.windows(2) {
            let len = w[0].distance(w[1]);
            let steps = (len / spacing).ceil().max(1.0) as usize;
            let normal = (w[1] - w[0]).normalized().perp();
            for k in 0..steps {
                let p = w[0].lerp(w[1], k as f32 / steps as f32)
                    + normal * (wobble * (s / 55.0 + seed).sin() + 0.4 * noise(i));
                out.push(StrokePoint::new(p.x, p.y + 0.3 * noise(i + 99), 0.5));
                s += len / steps as f32;
                i += 1;
            }
        }
        let end = path[path.len() - 1];
        out.push(StrokePoint::new(end.x, end.y, 0.5));
        process_input(&out, 3.0)
    }

    /// Every shape at 4 sizes × 4 rotations × 3 wobble amplitudes × 2 sampling densities
    /// (96 variants): positives must be recognised as their class nearly always, curves
    /// that are not shapes must nearly never snap.
    #[test]
    fn recognition_is_robust_to_size_rotation_and_jitter() {
        use std::collections::{BTreeMap, HashMap};
        let c = Vec2::new(500.0, 500.0);
        let closed_path = |v: Vec<Vec2>| {
            let mut v = v;
            v.push(v[0]);
            v
        };
        let rot = |v: Vec<Vec2>, a: f32| -> Vec<Vec2> {
            v.into_iter().map(|p| c + (p - c).rotate(a)).collect()
        };
        let ngon = |n: usize, r: f32, phase: f32| -> Vec<Vec2> {
            (0..n)
                .map(|i| c + Vec2::from_angle(phase + TAU * i as f32 / n as f32) * r)
                .collect()
        };
        let mut results: BTreeMap<&str, HashMap<Option<ShapeClass>, u32>> = BTreeMap::new();
        for size in [40.0f32, 80.0, 160.0, 300.0] {
            for angle in [0.0f32, 4.0, 15.0, 33.0] {
                let a = angle.to_radians();
                for wobble in [0.5f32, 1.5, 3.0] {
                    for spacing in [2.0f32, 6.0] {
                        let s = size;
                        let ellipse: Vec<Vec2> = (0..96)
                            .map(|i| {
                                let t = TAU * i as f32 / 96.0;
                                c + Vec2::new(s * t.cos(), 0.45 * s * t.sin()).rotate(a)
                            })
                            .collect();
                        let tips = ngon(5, s, a - PI / 2.0);
                        let mut d = vec![c + Vec2::new(0.0, -s), c + Vec2::new(0.0, s)];
                        d.extend((1..40).map(|i| {
                            let t = PI / 2.0 - PI * i as f32 / 40.0;
                            c + Vec2::new(0.8 * s * t.cos(), s * t.sin())
                        }));
                        let heart: Vec<Vec2> = (0..80)
                            .map(|i| {
                                let t = TAU * i as f32 / 80.0;
                                let x = 16.0 * t.sin().powi(3);
                                let y = 13.0 * t.cos()
                                    - 5.0 * (2.0 * t).cos()
                                    - 2.0 * (3.0 * t).cos()
                                    - (4.0 * t).cos();
                                c + Vec2::new(x, -y) * (s / 16.0)
                            })
                            .collect();
                        let cases: Vec<(&str, Vec<Vec2>)> = vec![
                            (
                                "line",
                                rot(vec![c - Vec2::new(s, 0.0), c + Vec2::new(s, 0.0)], a),
                            ),
                            ("circle", closed_path(ngon(96, s, a))),
                            ("ellipse", closed_path(ellipse)),
                            (
                                "triangle",
                                closed_path(rot(
                                    vec![
                                        c + Vec2::new(-s, 0.6 * s),
                                        c + Vec2::new(s, 0.6 * s),
                                        c + Vec2::new(-0.3 * s, -0.8 * s),
                                    ],
                                    a,
                                )),
                            ),
                            ("equilateral", closed_path(ngon(3, s, a - PI / 2.0))),
                            (
                                "rectangle",
                                closed_path(rot(
                                    vec![
                                        c + Vec2::new(-s, -0.6 * s),
                                        c + Vec2::new(s, -0.6 * s),
                                        c + Vec2::new(s, 0.6 * s),
                                        c + Vec2::new(-s, 0.6 * s),
                                    ],
                                    a,
                                )),
                            ),
                            ("square", closed_path(ngon(4, s, a + PI / 4.0))),
                            (
                                "trapezoid",
                                closed_path(rot(
                                    vec![
                                        c + Vec2::new(-0.5 * s, -0.5 * s),
                                        c + Vec2::new(0.5 * s, -0.5 * s),
                                        c + Vec2::new(s, 0.5 * s),
                                        c + Vec2::new(-s, 0.5 * s),
                                    ],
                                    a,
                                )),
                            ),
                            ("pentagon", closed_path(ngon(5, s, a))),
                            ("hexagon", closed_path(ngon(6, s, a))),
                            ("octagon", closed_path(ngon(8, s, a))),
                            (
                                "star",
                                closed_path((0..5).map(|i| tips[(2 * i) % 5]).collect()),
                            ),
                            (
                                "arc",
                                (0..=40)
                                    .map(|i| {
                                        c + Vec2::from_angle(a + 0.8 * PI * i as f32 / 40.0) * s
                                    })
                                    .collect(),
                            ),
                            ("D", closed_path(rot(d, a))),
                            ("heart", closed_path(heart)),
                            (
                                "spiral",
                                (0..=80)
                                    .map(|i| {
                                        let f = i as f32 / 80.0;
                                        c + Vec2::from_angle(3.0 * TAU * f) * (s * (0.3 + 0.7 * f))
                                    })
                                    .collect(),
                            ),
                        ];
                        let seed = size + angle * 3.1 + wobble * 7.7 + spacing;
                        for (name, path) in cases {
                            let got = detect_shape(&hand_path(&path, spacing, wobble, seed))
                                .map(|d| d.kind);
                            *results.entry(name).or_default().entry(got).or_default() += 1;
                        }
                    }
                }
            }
        }
        let count =
            |name: &str, class: Option<ShapeClass>| results[name].get(&class).copied().unwrap_or(0);
        for (name, class) in [
            ("line", ShapeClass::Line),
            ("circle", ShapeClass::Circle),
            ("ellipse", ShapeClass::Ellipse),
            ("triangle", ShapeClass::Triangle),
            ("equilateral", ShapeClass::Triangle),
            ("rectangle", ShapeClass::Rectangle),
            ("square", ShapeClass::Square),
            ("trapezoid", ShapeClass::Trapezoid),
            ("pentagon", ShapeClass::Pentagon),
            ("hexagon", ShapeClass::Hexagon),
            ("octagon", ShapeClass::Octagon),
            ("star", ShapeClass::Star),
        ] {
            assert!(
                count(name, Some(class)) >= 93,
                "{name}: {:?}",
                results[name]
            );
        }
        for name in ["arc", "D", "heart", "spiral"] {
            assert!(count(name, None) >= 90, "{name}: {:?}", results[name]);
        }
    }

    /// Recognition must finish well within a frame. Debug builds are ~20× slower, so the
    /// 100 µs budget is only asserted for optimised builds (`cargo test --release`).
    #[test]
    fn recognition_is_fast() {
        let center = Vec2::new(400.0, 400.0);
        let tips = regular(5, center, 150.0, -90.0);
        let star: Vec<(f32, f32)> = (0..5).map(|i| tips[(2 * i) % 5]).collect();
        let cases: Vec<(&str, Vec<StrokePoint>)> = vec![
            (
                "line",
                trace(
                    &[Vec2::new(10.0, 10.0), Vec2::new(600.0, 30.0)],
                    600,
                    1.0,
                    Vec2::ZERO,
                ),
            ),
            (
                "rectangle",
                closed(
                    &[
                        (100.0, 100.0),
                        (500.0, 100.0),
                        (500.0, 300.0),
                        (100.0, 300.0),
                    ],
                    150,
                    1.5,
                ),
            ),
            ("octagon", closed(&regular(8, center, 200.0, 0.0), 75, 1.5)),
            ("star", closed(&star, 120, 1.5)),
            ("circle", {
                let mut c = hand_drawn_ellipse(center, 200.0, 190.0, 0.0, 0.02);
                // Densify to ~600 samples.
                c = c
                    .windows(2)
                    .flat_map(|w| {
                        (0..7).map(move |k| {
                            let p = w[0].pos().lerp(w[1].pos(), k as f32 / 7.0);
                            StrokePoint::new(p.x, p.y, 0.5)
                        })
                    })
                    .collect();
                c
            }),
            (
                "freehand",
                trace(
                    &[
                        Vec2::new(0.0, 0.0),
                        Vec2::new(300.0, 80.0),
                        Vec2::new(120.0, 260.0),
                    ],
                    300,
                    3.0,
                    Vec2::new(20.0, 20.0),
                ),
            ),
        ];
        for (name, pts) in &cases {
            let runs = 50;
            let start = std::time::Instant::now();
            for _ in 0..runs {
                std::hint::black_box(detect_shape(std::hint::black_box(pts)));
            }
            let per_call = start.elapsed() / runs;
            println!(
                "{name}: {} samples, {per_call:?} per recognition",
                pts.len()
            );
            if !cfg!(debug_assertions) {
                assert!(per_call.as_micros() < 100, "{name} took {per_call:?}");
            }
        }
    }
}

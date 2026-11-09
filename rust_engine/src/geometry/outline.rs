//! Variable-width stroke tessellation.
//!
//! Converts a centre line with a per-sample radius into a single closed outline polygon
//! that is filled with the non-zero winding rule. Because the whole stroke is one fill,
//! a translucent pen never shows darker "beads" where segments overlap.
//!
//! Joins follow the approach used by Skia's stroker: the outer side of a turn receives a
//! round arc, the inner side is routed through the pivot (centre) point so the non-zero
//! fill never leaves holes at sharp corners.

use super::point::Vec2;
use std::f32::consts::PI;

/// Turns sharper than this (radians) get an explicit round join.
const JOIN_THRESHOLD: f32 = 15.0 * PI / 180.0;
/// Angular resolution of arcs.
const ARC_STEP: f32 = PI / 10.0;

/// Builds the outline polygon for `samples` (`(position, radius)`).
pub fn build_outline(samples: &[(Vec2, f32)]) -> Vec<Vec2> {
    let samples: Vec<(Vec2, f32)> = dedupe(samples);
    match samples.len() {
        0 => return Vec::new(),
        1 => return circle(samples[0].0, samples[0].1.max(0.25)),
        _ => {}
    }

    let n = samples.len();
    let dirs: Vec<Vec2> = (0..n - 1)
        .map(|i| (samples[i + 1].0 - samples[i].0).normalized())
        .collect();
    let mut left: Vec<Vec2> = Vec::with_capacity(n * 2); // +normal side
    let mut right: Vec<Vec2> = Vec::with_capacity(n * 2); // -normal side

    let (p0, r0) = samples[0];
    let n0 = dirs[0].perp();
    left.push(p0 + n0 * r0);
    right.push(p0 - n0 * r0);

    for i in 1..n - 1 {
        let (p, r) = samples[i];
        let d_in = dirs[i - 1];
        let d_out = dirs[i];
        let n_in = d_in.perp();
        let n_out = d_out.perp();
        let cos_turn = d_in.dot(d_out).clamp(-1.0, 1.0);
        let turn = cos_turn.acos();

        if turn < JOIN_THRESHOLD {
            // Nearly straight: a single averaged-normal offset on each side.
            let m = (n_in + n_out).normalized();
            let m = if m == Vec2::ZERO { n_out } else { m };
            left.push(p + m * r);
            right.push(p - m * r);
            continue;
        }

        if d_in.cross(d_out) > 0.0 {
            // Turning towards +normal: left is the inner side, right the outer side.
            left.push(p + n_in * r);
            left.push(p);
            left.push(p + n_out * r);
            push_arc(
                &mut right,
                p,
                r,
                (n_in * -1.0).angle(),
                (n_out * -1.0).angle(),
            );
        } else {
            // Turning towards -normal: right is the inner side.
            push_arc(&mut left, p, r, n_in.angle(), n_out.angle());
            right.push(p - n_in * r);
            right.push(p);
            right.push(p - n_out * r);
        }
    }

    let (pn, rn) = samples[n - 1];
    let nn = dirs[n - 2].perp();
    left.push(pn + nn * rn);
    right.push(pn - nn * rn);

    let mut outline = left;
    // End cap: sweep from +normal, around the tip, to -normal.
    push_cap(&mut outline, pn, rn, nn.angle());
    outline.extend(right.into_iter().rev());
    // Start cap: sweep from -normal, around the tail, back to +normal.
    push_cap(&mut outline, p0, r0, (n0 * -1.0).angle());
    outline
}

/// Flattens `[Vec2]` into `[x0, y0, x1, y1, ...]`.
pub fn flatten(points: &[Vec2]) -> Vec<f32> {
    let mut out = Vec::with_capacity(points.len() * 2);
    for p in points {
        out.push(p.x);
        out.push(p.y);
    }
    out
}

fn dedupe(samples: &[(Vec2, f32)]) -> Vec<(Vec2, f32)> {
    let mut out: Vec<(Vec2, f32)> = Vec::with_capacity(samples.len());
    for &(p, r) in samples {
        if !(p.x.is_finite() && p.y.is_finite() && r.is_finite()) {
            continue;
        }
        match out.last_mut() {
            Some(last) if last.0.distance(p) < 1e-3 => last.1 = last.1.max(r),
            _ => out.push((p, r.max(0.05))),
        }
    }
    out
}

fn circle(c: Vec2, r: f32) -> Vec<Vec2> {
    let steps = ((r * 2.0).ceil() as usize).clamp(12, 48);
    (0..steps)
        .map(|k| c + Vec2::from_angle(2.0 * PI * k as f32 / steps as f32) * r)
        .collect()
}

/// Arc around `c` from angle `a0` to `a1` taking the short way round (excluding
/// nothing: both endpoints are emitted).
fn push_arc(out: &mut Vec<Vec2>, c: Vec2, r: f32, a0: f32, a1: f32) {
    let mut delta = a1 - a0;
    while delta > PI {
        delta -= 2.0 * PI;
    }
    while delta < -PI {
        delta += 2.0 * PI;
    }
    let steps = ((delta.abs() / ARC_STEP).ceil() as usize).max(1);
    for k in 0..=steps {
        let a = a0 + delta * k as f32 / steps as f32;
        out.push(c + Vec2::from_angle(a) * r);
    }
}

/// Semicircular cap starting at angle `from` and sweeping -π (clockwise in maths terms),
/// endpoints excluded because they are already part of the side polylines.
fn push_cap(out: &mut Vec<Vec2>, c: Vec2, r: f32, from: f32) {
    let steps = ((PI / ARC_STEP).ceil() as usize).max(2);
    for k in 1..steps {
        let a = from - PI * k as f32 / steps as f32;
        out.push(c + Vec2::from_angle(a) * r);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn polygon_area(poly: &[Vec2]) -> f32 {
        let mut a = 0.0;
        for i in 0..poly.len() {
            let p = poly[i];
            let q = poly[(i + 1) % poly.len()];
            a += p.cross(q);
        }
        a * 0.5
    }

    #[test]
    fn straight_stroke_outline_has_expected_area() {
        let samples: Vec<(Vec2, f32)> = (0..=10)
            .map(|i| (Vec2::new(i as f32 * 10.0, 0.0), 2.0))
            .collect();
        let outline = build_outline(&samples);
        // Rectangle 100 x 4 plus a full circle of radius 2 from the caps.
        let expected = 100.0 * 4.0 + PI * 4.0;
        let area = polygon_area(&outline).abs();
        assert!(
            (area - expected).abs() / expected < 0.05,
            "area {area} vs {expected}"
        );
    }

    #[test]
    fn single_point_becomes_dot() {
        let outline = build_outline(&[(Vec2::new(5.0, 5.0), 3.0)]);
        assert!(outline.len() >= 12);
        assert!(outline
            .iter()
            .all(|p| (p.distance(Vec2::new(5.0, 5.0)) - 3.0).abs() < 1e-3));
    }

    #[test]
    fn sharp_turn_produces_finite_outline() {
        let samples = vec![
            (Vec2::new(0.0, 0.0), 2.0),
            (Vec2::new(50.0, 0.0), 2.0),
            (Vec2::new(0.0, 1.0), 2.0),
        ];
        let outline = build_outline(&samples);
        assert!(outline.len() > 8);
        assert!(outline.iter().all(|p| p.x.is_finite() && p.y.is_finite()));
    }
}

//! Precise hit-testing primitives used after the QuadTree broad phase.

use crate::geometry::Vec2;

/// Even-odd ray casting test.
pub fn point_in_polygon(p: Vec2, poly: &[Vec2]) -> bool {
    if poly.len() < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[j]);
        if (a.y > p.y) != (b.y > p.y) {
            let x_cross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
            if p.x < x_cross {
                inside = !inside;
            }
        }
        j = i;
    }
    inside
}

/// Distance from `p` to the segment `a`–`b`.
pub fn distance_to_segment(p: Vec2, a: Vec2, b: Vec2) -> f32 {
    let ab = b - a;
    let len2 = ab.dot(ab);
    if len2 <= f32::EPSILON {
        return p.distance(a);
    }
    let t = ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
    p.distance(a + ab * t)
}

/// Minimum distance from `p` to a polyline (optionally closed).
pub fn distance_to_polyline(p: Vec2, pts: &[Vec2], closed: bool) -> f32 {
    match pts.len() {
        0 => f32::INFINITY,
        1 => p.distance(pts[0]),
        _ => {
            let mut best = f32::INFINITY;
            for w in pts.windows(2) {
                best = best.min(distance_to_segment(p, w[0], w[1]));
            }
            if closed {
                best = best.min(distance_to_segment(p, pts[pts.len() - 1], pts[0]));
            }
            best
        }
    }
}

/// Unflattens `[x0, y0, x1, y1, ...]`.
pub fn unflatten(coords: &[f32]) -> Vec<Vec2> {
    (0..coords.len() / 2)
        .map(|i| Vec2::new(coords[2 * i], coords[2 * i + 1]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn polygon_containment() {
        let sq = [
            Vec2::new(0.0, 0.0),
            Vec2::new(10.0, 0.0),
            Vec2::new(10.0, 10.0),
            Vec2::new(0.0, 10.0),
        ];
        assert!(point_in_polygon(Vec2::new(5.0, 5.0), &sq));
        assert!(!point_in_polygon(Vec2::new(15.0, 5.0), &sq));
    }

    #[test]
    fn segment_distance() {
        let d = distance_to_segment(
            Vec2::new(5.0, 3.0),
            Vec2::new(0.0, 0.0),
            Vec2::new(10.0, 0.0),
        );
        assert!((d - 3.0).abs() < 1e-5);
        let d = distance_to_polyline(
            Vec2::new(-4.0, 0.0),
            &[Vec2::new(0.0, 0.0), Vec2::new(10.0, 0.0)],
            false,
        );
        assert!((d - 4.0).abs() < 1e-5);
    }
}

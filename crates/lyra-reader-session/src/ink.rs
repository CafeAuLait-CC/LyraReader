//! Exact, platform-independent partial ink erasure. Matches the macOS capsule model;
//! only cut boundaries are interpolated, and surviving stored vertices stay unchanged.
use lyra_reader_core::Point;

const EPSILON: f64 = 1e-12;

#[derive(Clone, Debug)]
pub struct InkStrokeSplitter {
    points: Vec<Point>,
    reach: f64,
    removed: Vec<Vec<(f64, f64)>>,
    removes_point: bool,
}

fn distance(p: Point, a: Point, b: Point) -> f64 {
    let (x, y) = (b.x - a.x, b.y - a.y);
    let length = x * x + y * y;
    let t = if length > 0.0 {
        ((p.x - a.x) * x + (p.y - a.y) * y) / length
    } else {
        0.0
    }
    .clamp(0.0, 1.0);
    (p.x - a.x - t * x).hypot(p.y - a.y - t * y)
}
fn interpolate(a: Point, b: Point, t: f64) -> Point {
    if t <= 0.0 {
        a
    } else if t >= 1.0 {
        b
    } else {
        Point::new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}
fn interval(
    first: Point,
    second: Point,
    start: Point,
    end: Point,
    reach: f64,
) -> Option<(f64, f64)> {
    let (ux, uy, vx, vy, wx, wy) = (
        second.x - first.x,
        second.y - first.y,
        end.x - start.x,
        end.y - start.y,
        first.x - start.x,
        first.y - start.y,
    );
    let (a, b, c, d, e) = (
        ux * ux + uy * uy,
        ux * vx + uy * vy,
        vx * vx + vy * vy,
        wx * ux + wy * uy,
        wx * vx + wy * vy,
    );
    let mut candidates = vec![0.0, 1.0];
    let determinant = a * c - b * b;
    if determinant.abs() > EPSILON {
        let t = (b * e - c * d) / determinant;
        let s = (b * t + e) / c;
        if (0.0..=1.0).contains(&t) && (0.0..=1.0).contains(&s) {
            candidates.push(t);
        }
    }
    if a > EPSILON {
        candidates.extend([-d / a, (b - d) / a]);
    }
    let at = |t| distance(interpolate(first, second, t), start, end);
    let middle = candidates
        .into_iter()
        .map(|t| t.clamp(0.0, 1.0))
        .min_by(|a, b| at(*a).total_cmp(&at(*b)))?;
    let closest = at(middle);
    if closest > reach + 1e-9 || reach > 0.0 && closest >= reach {
        return None;
    }
    let lower = if at(0.0) <= reach {
        0.0
    } else {
        let (mut outside, mut inside) = (0.0, middle);
        for _ in 0..48 {
            let mid = (outside + inside) / 2.0;
            if at(mid) <= reach {
                inside = mid;
            } else {
                outside = mid;
            }
        }
        inside
    };
    let upper = if at(1.0) <= reach {
        1.0
    } else {
        let (mut inside, mut outside) = (middle, 1.0);
        for _ in 0..48 {
            let mid = (outside + inside) / 2.0;
            if at(mid) <= reach {
                inside = mid;
            } else {
                outside = mid;
            }
        }
        inside
    };
    (upper - lower > EPSILON).then_some((lower, upper))
}

impl InkStrokeSplitter {
    pub fn new(points: Vec<Point>, reach: f64) -> Self {
        Self {
            removed: vec![vec![]; points.len().saturating_sub(1)],
            points,
            reach: if reach.is_finite() {
                reach.max(0.0)
            } else {
                reach
            },
            removes_point: false,
        }
    }
    /// Return true only when the union of removed capsule intervals grows.
    pub fn remove(&mut self, start: Point, end: Point) -> bool {
        if !self.reach.is_finite()
            || [start, end]
                .iter()
                .chain(&self.points)
                .any(|p| !p.x.is_finite() || !p.y.is_finite())
        {
            return false;
        }
        if self.points.len() == 1 {
            if !self.removes_point && distance(self.points[0], start, end) <= self.reach {
                self.removes_point = true;
                return true;
            }
            return false;
        }
        let mut changed = false;
        for (index, pair) in self.points.windows(2).enumerate() {
            let (a, b) = (pair[0], pair[1]);
            if a.x.max(b.x) < start.x.min(end.x) - self.reach
                || a.x.min(b.x) > start.x.max(end.x) + self.reach
                || a.y.max(b.y) < start.y.min(end.y) - self.reach
                || a.y.min(b.y) > start.y.max(end.y) + self.reach
            {
                continue;
            }
            let Some(cut) = interval(a, b, start, end, self.reach) else {
                continue;
            };
            let old = &self.removed[index];
            let mut all = old.clone();
            all.push(cut);
            all.sort_by(|a, b| a.0.total_cmp(&b.0));
            let mut merged: Vec<(f64, f64)> = vec![];
            for item in all {
                if let Some(last) = merged.last_mut()
                    && item.0 <= last.1 + EPSILON
                {
                    last.1 = last.1.max(item.1);
                } else {
                    merged.push(item);
                }
            }
            if merged != *old {
                self.removed[index] = merged;
                changed = true;
            }
        }
        changed
    }
    pub fn surviving_paths(&self) -> Vec<Vec<Point>> {
        if self.points.len() < 2 {
            return if self.removes_point || self.points.is_empty() {
                vec![]
            } else {
                vec![self.points.clone()]
            };
        }
        let mut result = vec![];
        let mut current = vec![];
        let finish = |current: &mut Vec<Point>, result: &mut Vec<Vec<Point>>| {
            if current.len() >= 2 {
                result.push(std::mem::take(current));
            } else {
                current.clear();
            }
        };
        for (i, pair) in self.points.windows(2).enumerate() {
            let (first, second) = (pair[0], pair[1]);
            let mut cursor = 0.0;
            for &(lower, upper) in &self.removed[i] {
                if lower > cursor + EPSILON {
                    if current.is_empty() {
                        current.push(interpolate(first, second, cursor));
                    }
                    current.push(interpolate(first, second, lower));
                }
                // A cut starting at an existing vertex must also disconnect the prior
                // segment. Otherwise a fully removed middle segment could be bridged.
                finish(&mut current, &mut result);
                cursor = cursor.max(upper);
            }
            if cursor < 1.0 - EPSILON {
                if current.is_empty() {
                    current.push(interpolate(first, second, cursor));
                }
                current.push(second);
            } else {
                finish(&mut current, &mut result);
            }
        }
        finish(&mut current, &mut result);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn p(x: f64, y: f64) -> Point {
        Point::new(x, y)
    }
    #[test]
    fn capsule_cuts_between_samples_without_moving_original_vertices() {
        let original = vec![p(0., 0.), p(20., 0.), p(80., 0.), p(100., 0.)];
        let mut split = InkStrokeSplitter::new(original.clone(), 9.);
        assert!(split.remove(p(50., -20.), p(50., 20.)));
        let paths = split.surviving_paths();
        assert_eq!(paths.len(), 2);
        assert_eq!(&paths[0][..2], &original[..2]);
        assert_eq!(&paths[1][1..], &original[2..]);
        assert!((paths[0][2].x - 41.).abs() < 1e-10);
        assert!((paths[1][0].x - 59.).abs() < 1e-10);
        assert!(!split.remove(p(50., -20.), p(50., 20.)));
    }
    #[test]
    fn merged_cuts_are_independent_of_direction_and_frequency() {
        let mut a = InkStrokeSplitter::new(vec![p(0., 0.), p(100., 0.)], 5.);
        let mut b = a.clone();
        a.remove(p(30., 0.), p(60., 0.));
        b.remove(p(60., 0.), p(45., 0.));
        b.remove(p(45., 0.), p(30., 0.));
        let (left, right) = (a.surviving_paths(), b.surviving_paths());
        assert_eq!(left.len(), right.len());
        for (a, b) in left.iter().flatten().zip(right.iter().flatten()) {
            assert!((a.x - b.x).abs() < 1e-10 && (a.y - b.y).abs() < 1e-10);
        }
        assert!(!b.remove(p(45., 0.), p(45., 0.)));
    }
    #[test]
    fn tangent_miss_and_full_coverage() {
        let points = vec![p(0., 0.), p(100., 0.)];
        let mut a = InkStrokeSplitter::new(points.clone(), 8.);
        assert!(!a.remove(p(50., 8.), p(50., 8.)));
        assert_eq!(a.surviving_paths(), vec![points]);
        assert!(!a.remove(p(0., 20.), p(100., 20.)));
        assert!(a.remove(p(-20., 0.), p(120., 0.)));
        assert!(a.surviving_paths().is_empty());
    }
    #[test]
    fn removed_middle_segment_cannot_bridge_disconnected_survivors() {
        let mut a =
            InkStrokeSplitter::new(vec![p(0., 0.), p(20., 0.), p(80., 0.), p(100., 0.)], 1.);
        a.remove(p(20., 0.), p(80., 0.));
        let paths = a.surviving_paths();
        assert_eq!(paths.len(), 2);
        assert!((paths[0].last().unwrap().x - 19.).abs() < 1e-10);
        assert!((paths[1][0].x - 81.).abs() < 1e-10);
    }
    #[test]
    fn empty_one_point_and_invalid_pointer_are_bounded() {
        let mut empty = InkStrokeSplitter::new(vec![], 8.);
        assert!(!empty.remove(p(0., 0.), p(1., 1.)));
        let mut point = InkStrokeSplitter::new(vec![p(2., 2.)], 1.);
        assert!(!point.remove(p(f64::NAN, 0.), p(0., 0.)));
        assert!(point.remove(p(0., 2.), p(4., 2.)));
        assert!(point.surviving_paths().is_empty());
    }
}

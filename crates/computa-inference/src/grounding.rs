use serde::{Deserialize, Serialize};
pub const AGREEMENT_THRESHOLD: f64 = 0.03;
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
impl Point {
    pub fn valid(self, width: u32, height: u32) -> Option<Self> {
        (self.x.is_finite()
            && self.y.is_finite()
            && self.x >= 0.0
            && self.y >= 0.0
            && self.x < f64::from(width)
            && self.y < f64::from(height))
        .then_some(self)
    }
    fn distance(self, other: Self) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct Selection {
    pub point: Point,
    pub used_showui: bool,
    pub selected_pair: [&'static str; 2],
    pub initial_distance_normalized_diagonal: Option<f64>,
    pub selected_distance_normalized_diagonal: f64,
}
#[derive(Clone, Copy, Debug, thiserror::Error, Eq, PartialEq)]
pub enum GroundingRefusal {
    #[error("Fewer than two grounders returned a valid point.")]
    InsufficientValidPoints,
    #[error("No two grounders agree within the required threshold.")]
    NoPairAgreement,
    #[error("Screenshot dimensions are invalid.")]
    Dimensions,
}
pub fn requires_showui(
    go: Option<Point>,
    owl: Option<Point>,
    width: u32,
    height: u32,
) -> (bool, Option<f64>) {
    let pair = go
        .and_then(|p| p.valid(width, height))
        .zip(owl.and_then(|p| p.valid(width, height)));
    if let Some((a, b)) = pair {
        let distance = a.distance(b);
        (
            distance > AGREEMENT_THRESHOLD * f64::from(width).hypot(f64::from(height)),
            Some(distance),
        )
    } else {
        (true, None)
    }
}
pub fn select(
    go: Option<Point>,
    owl: Option<Point>,
    show: Option<Point>,
    width: u32,
    height: u32,
) -> Result<Selection, GroundingRefusal> {
    if width == 0 || height == 0 {
        return Err(GroundingRefusal::Dimensions);
    }
    let (used_showui, initial) = requires_showui(go, owl, width, height);
    let valid: Vec<_> = [
        ("goclick", go),
        ("gui_owl_2b", owl),
        ("showui", if used_showui { show } else { None }),
    ]
    .into_iter()
    .filter_map(|(name, p)| p.and_then(|p| p.valid(width, height)).map(|p| (name, p)))
    .collect();
    if valid.len() < 2 {
        return Err(GroundingRefusal::InsufficientValidPoints);
    }
    let mut best = (valid[0], valid[1]);
    let mut distance = best.0.1.distance(best.1.1);
    if used_showui {
        for a in 0..valid.len() {
            for b in a + 1..valid.len() {
                let candidate = valid[a].1.distance(valid[b].1);
                if candidate < distance {
                    best = (valid[a], valid[b]);
                    distance = candidate;
                }
            }
        }
    }
    let diagonal = f64::from(width).hypot(f64::from(height));
    if distance > AGREEMENT_THRESHOLD * diagonal {
        return Err(GroundingRefusal::NoPairAgreement);
    }
    Ok(Selection {
        point: Point {
            x: (best.0.1.x + best.1.1.x) / 2.0,
            y: (best.0.1.y + best.1.1.y) / 2.0,
        },
        used_showui,
        selected_pair: [best.0.0, best.1.0],
        initial_distance_normalized_diagonal: initial.map(|d| d / diagonal),
        selected_distance_normalized_diagonal: distance / diagonal,
    })
}
pub fn showui_point(text: &str, width: u32, height: u32) -> Option<Point> {
    let text = text.trim();
    let normalized = if text.starts_with('(') && text.ends_with(')') {
        format!("[{}]", &text[1..text.len() - 1])
    } else {
        text.into()
    };
    let value = computa_contracts::strict_json::parse(normalized.as_bytes()).ok()?;
    let values = value.as_array()?;
    if values.len() != 2 {
        return None;
    }
    let (x, y) = (values[0].as_f64()?, values[1].as_f64()?);
    if !x.is_finite() || !y.is_finite() || !(0.0..=1.0).contains(&x) || !(0.0..=1.0).contains(&y) {
        return None;
    }
    Point {
        x: x * f64::from(width),
        y: y * f64::from(height),
    }
    .valid(width, height)
}
pub fn goclick_point(text: &str, width: u32, height: u32) -> Option<Point> {
    let pattern =
        regex::Regex::new(r"^\s*(?:<s>)?\(\s*<loc_(\d+)>\s*,\s*<loc_(\d+)>\s*\)\s*(?:</s>)?\s*$")
            .ok()?;
    let captures = pattern.captures(text)?;
    let x = captures[1].parse::<u32>().ok()?;
    let y = captures[2].parse::<u32>().ok()?;
    if x > 999 || y > 999 {
        return None;
    }
    Point {
        x: f64::from(x) * f64::from(width) / 1000.0,
        y: f64::from(y) * f64::from(height) / 1000.0,
    }
    .valid(width, height)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn threshold_and_fallback_rule_match_frozen_cascade() {
        let a = Point { x: 10.0, y: 10.0 };
        let b = Point { x: 12.0, y: 12.0 };
        let far = Point { x: 90.0, y: 90.0 };
        let selected = select(Some(a), Some(b), Some(far), 100, 100).unwrap();
        assert!(!selected.used_showui);
        assert_eq!(selected.point, Point { x: 11.0, y: 11.0 });
        let selected = select(Some(a), Some(far), Some(b), 100, 100).unwrap();
        assert!(selected.used_showui);
        assert_eq!(selected.selected_pair, ["goclick", "showui"]);
        assert_eq!(
            select(Some(a), Some(far), None, 100, 100).unwrap_err(),
            GroundingRefusal::NoPairAgreement
        );
    }
    #[test]
    fn bool_nan_edges_and_invalid_points_are_not_candidates() {
        assert!(showui_point("[true,0.5]", 100, 100).is_none());
        assert!(showui_point("[1,1]", 100, 100).is_none());
        assert!(
            Point {
                x: f64::NAN,
                y: 0.0
            }
            .valid(100, 100)
            .is_none()
        );
        assert_eq!(
            select(None, None, Some(Point { x: 1.0, y: 1.0 }), 100, 100).unwrap_err(),
            GroundingRefusal::InsufficientValidPoints
        );
    }
}

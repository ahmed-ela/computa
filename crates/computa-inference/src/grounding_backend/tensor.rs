//! Bounds shared by the three explicit visual model architectures.
use mlex::{Array, Error, Result};
use serde_json::Value;
pub(super) fn required_i32(cfg: &Value, key: &str, low: i32, high: i32) -> Result<i32> {
    cfg[key]
        .as_i64()
        .and_then(|n| i32::try_from(n).ok())
        .filter(|n| *n >= low && *n <= high)
        .ok_or_else(|| Error::Config(format!("visual model {key} outside [{low},{high}]")))
}
pub(super) fn required_list(cfg: &Value, key: &str, low: i32, high: i32) -> Result<Vec<i32>> {
    let arr = cfg[key]
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 64)
        .ok_or_else(|| Error::Config(format!("visual model {key}")))?;
    arr.iter()
        .map(|v| {
            v.as_i64()
                .and_then(|n| i32::try_from(n).ok())
                .filter(|n| *n >= low && *n <= high)
                .ok_or_else(|| Error::Config(format!("visual model {key} bounds")))
        })
        .collect()
}
pub(super) fn shape(value: &Array, rank: usize) -> Result<()> {
    if value.shape().len() == rank && value.shape().iter().all(|d| *d > 0) {
        Ok(())
    } else {
        Err(Error::Model("visual model tensor shape".into()))
    }
}
pub(super) fn check_alive(alive: &mut impl FnMut() -> bool) -> Result<()> {
    if alive() {
        Ok(())
    } else {
        Err(Error::Model("visual_grounding_cancelled".into()))
    }
}

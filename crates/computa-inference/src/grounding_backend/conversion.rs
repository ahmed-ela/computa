//! Florence's publisher/MLX sanitization, expressed as local tensor operations.
//! No architecture substitution, imported Python or remotely executed processor.
use mlex::{Array, Error, Result, ops};
use serde_json::{Value, json};
use std::collections::HashMap;

pub fn sanitize_florence(weights: HashMap<String, Array>) -> Result<HashMap<String, Array>> {
    let mut output = HashMap::with_capacity(weights.len() + 1);
    for (name, tensor) in weights {
        if name.contains("final_logits_bias") || name.contains("position_ids") {
            continue;
        }
        let dims = tensor.shape();
        let transpose = if name.contains("convs") && name.contains("proj.weight") {
            if dims.len() != 4 {
                return Err(Error::Model("Florence patch convolution rank".into()));
            }
            // Exact mlx-vlm VisionModel check_array_shape predicate.
            !(dims[0] >= dims[1] && dims[0] >= dims[2] && dims[1] == dims[2])
        } else if name.contains("blocks") && name.contains("dw.weight") {
            if dims.len() != 4 {
                return Err(Error::Model("Florence depthwise convolution rank".into()));
            }
            dims[1] < dims[3]
        } else {
            false
        };
        let tensor = if transpose {
            ops::contiguous(&ops::transpose_axes(&tensor, &[0, 2, 3, 1])?)?
        } else {
            tensor
        };
        output.insert(name, tensor);
    }
    // The GoClick source omits a tied lm_head. Preserve a separate head when
    // present, matching Model.sanitize rather than overriding learned weights.
    if !output.contains_key("language_model.lm_head.weight") {
        let shared = output
            .get("language_model.model.shared.weight")
            .ok_or_else(|| Error::Model("Florence shared embedding is absent".into()))?
            .clone();
        output.insert("language_model.lm_head.weight".into(), shared);
    }
    Ok(output)
}
/// Match CLIP's runtime defaults while requiring the pinned checkpoint's actual
/// size/mean/std. Missing checkpoint-specific values cannot be invented.
pub fn florence_processor_config(mut cfg: Value) -> Result<Value> {
    let fields = cfg
        .as_object_mut()
        .ok_or_else(|| Error::Config("Florence processor object".into()))?;
    for (name, value) in [
        ("do_resize", json!(true)),
        ("do_rescale", json!(true)),
        ("do_normalize", json!(true)),
        ("do_center_crop", json!(false)),
        ("resample", json!(3)),
        ("rescale_factor", json!(1.0 / 255.0)),
    ] {
        fields.entry(name).or_insert(value);
    }
    let dimensions = &cfg["size"];
    if !["height", "width"].iter().all(|key| {
        dimensions[*key]
            .as_u64()
            .is_some_and(|v| (1..=2048).contains(&v))
    }) || cfg["do_resize"] != true
        || cfg["do_rescale"] != true
        || cfg["do_normalize"] != true
        || cfg["do_center_crop"] != false
        || cfg["resample"] != 3
        || cfg["rescale_factor"]
            .as_f64()
            .is_none_or(|f| !f.is_finite() || f <= 0.0)
    {
        return Err(Error::Config(
            "Florence pinned resize/normalization configuration".into(),
        ));
    }
    for name in ["image_mean", "image_std"] {
        let values = cfg[name]
            .as_array()
            .filter(|v| v.len() == 3)
            .ok_or_else(|| Error::Config("Florence RGB normalization values".into()))?;
        if values.iter().any(|v| {
            v.as_f64()
                .is_none_or(|v| !v.is_finite() || (name == "image_std" && v <= 0.0))
        }) {
            return Err(Error::Config("Florence RGB normalization values".into()));
        }
    }
    Ok(cfg)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_convolution_layout_and_tied_head_match_the_pinned_mlx_sanitizers() {
        let values: Vec<f32> = (0..4 * 2 * 3 * 3).map(|i| i as f32).collect();
        let original = Array::from_slice(&values, &[4, 2, 3, 3]);
        let shared = Array::from_slice(&[1.0f32, 2.0, 3.0, 4.0], &[2, 2]);
        let mut converted = sanitize_florence(HashMap::from([
            ("vision_tower.convs.0.proj.weight".into(), original),
            ("language_model.model.shared.weight".into(), shared),
            (
                "language_model.final_logits_bias".into(),
                Array::from_slice(&[4.0f32], &[1]),
            ),
            (
                "vision_tower.position_ids".into(),
                Array::from_slice(&[0u32], &[1]),
            ),
        ]))
        .unwrap();
        let convolution = converted
            .remove("vision_tower.convs.0.proj.weight")
            .unwrap();
        assert_eq!(convolution.shape(), [4, 3, 3, 2]);
        let expected: Vec<f32> = (0..4)
            .flat_map(|out| {
                (0..3).flat_map(move |h| {
                    (0..3)
                        .flat_map(move |w| (0..2).map(move |input| values_index(out, input, h, w)))
                })
            })
            .collect();
        assert_eq!(convolution.to_vec_f32().unwrap(), expected);
        assert_eq!(
            converted["language_model.lm_head.weight"]
                .to_vec_f32()
                .unwrap(),
            [1.0, 2.0, 3.0, 4.0]
        );
        assert!(!converted.contains_key("language_model.final_logits_bias"));
        assert!(!converted.contains_key("vision_tower.position_ids"));
    }
    fn values_index(out: i32, input: i32, h: i32, w: i32) -> f32 {
        (out * 18 + input * 9 + h * 3 + w) as f32
    }
    #[test]
    fn converted_weights_are_not_transposed_twice_and_processor_does_not_guess_geometry() {
        let output = sanitize_florence(HashMap::from([
            (
                "vision_tower.convs.0.proj.weight".into(),
                ops::zeros(&[4, 3, 3, 2], mlex::Dtype::Float32).unwrap(),
            ),
            (
                "language_model.model.shared.weight".into(),
                ops::zeros(&[2, 2], mlex::Dtype::Float32).unwrap(),
            ),
            (
                "language_model.lm_head.weight".into(),
                ops::ones(&[2, 2], mlex::Dtype::Float32).unwrap(),
            ),
        ]))
        .unwrap();
        assert_eq!(
            output["vision_tower.convs.0.proj.weight"].shape(),
            [4, 3, 3, 2]
        );
        assert_eq!(
            output["language_model.lm_head.weight"]
                .to_vec_f32()
                .unwrap(),
            [1.0; 4]
        );
        let cfg=florence_processor_config(json!({"size":{"height":768,"width":768},"image_mean":[0.485,0.456,0.406],"image_std":[0.229,0.224,0.225]})).unwrap();
        assert_eq!(cfg["resample"], 3);
        assert_eq!(cfg["do_center_crop"], false);
        assert!(
            florence_processor_config(
                json!({"image_mean":[0.485,0.456,0.406],"image_std":[0.229,0.224,0.225]})
            )
            .is_err()
        );
    }
}

//! Native Qwen2-VL (ShowUI) and Qwen3-VL (GUI-Owl) tensor architectures.
//! Architecture and processor reference: upstream mlx-vlm (MIT) and the
//! pinned Hugging Face model configs. No remote code or cross-request caches.
use super::tensor::{check_alive, required_i32, required_list, shape};
use image::RgbImage;
use mlex::{
    Array, Dtype, Error, Result,
    models::cache::KvCache,
    nn::{Embedding, LayerNorm, Linear, RmsNorm, WeightMap},
    ops::{self, AttentionMask},
    tokenizer::{ChatMessage, ContentPart, Tokenizer},
};
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Family {
    Qwen2,
    Qwen3,
}
fn config_error(message: &str) -> Error {
    Error::Config(format!("Qwen visual model {message}"))
}
fn model_error(message: &str) -> Error {
    Error::Model(format!("Qwen visual model {message}"))
}
fn number(cfg: &Value, key: &str, low: f64, high: f64) -> Result<f64> {
    cfg[key]
        .as_f64()
        .filter(|n| n.is_finite() && *n >= low && *n <= high)
        .ok_or_else(|| config_error(key))
}
fn exact_shape(x: &Array, expected: &[i32]) -> Result<()> {
    if x.shape() == expected {
        Ok(())
    } else {
        Err(model_error("weight dimensions"))
    }
}
fn linear(w: &mut WeightMap, path: &str, input: i32, output: i32, bias: bool) -> Result<Linear> {
    let l = w.linear(path)?;
    match &l {
        Linear::Dense(d) => {
            exact_shape(&d.weight, &[output, input])?;
            if bias != d.bias.is_some() {
                return Err(model_error("linear bias"));
            }
            if let Some(b) = &d.bias {
                exact_shape(b, &[output])?;
            }
        }
        Linear::Quantized(q) => {
            shape(&q.weight, 2)?;
            shape(&q.scales, 2)?;
            if ![2, 4, 8].contains(&q.params.bits) || q.params.group_size <= 0 {
                return Err(model_error("quantized linear parameters"));
            }
            if q.weight.dim(0) != output
                || q.scales.dim(0) != output
                || q.weight.dim(1) * (32 / q.params.bits) != input
                || input % q.params.group_size != 0
                || q.scales.dim(1) != input / q.params.group_size
                || bias != q.bias.is_some()
            {
                return Err(model_error("quantized linear dimensions"));
            }
            if let Some(b) = &q.bias {
                exact_shape(b, &[output])?;
            }
            if let Some(b) = &q.biases {
                exact_shape(b, &q.scales.shape())?;
            }
        }
    }
    Ok(l)
}
fn layer_norm(w: &mut WeightMap, path: &str, dim: i32) -> Result<LayerNorm> {
    let n = w.layer_norm(path, 1e-6)?;
    exact_shape(&n.weight, &[dim])?;
    exact_shape(
        n.bias
            .as_ref()
            .ok_or_else(|| model_error("layer norm bias"))?,
        &[dim],
    )?;
    Ok(n)
}
fn rms_norm(w: &mut WeightMap, path: &str, dim: i32, eps: f32) -> Result<RmsNorm> {
    let n = w.rms_norm(path, eps)?;
    exact_shape(&n.weight, &[dim])?;
    Ok(n)
}
fn canonical(key: &str, family: Family) -> String {
    match family {
        Family::Qwen2 => {
            if let Some(s) = key.strip_prefix("visual.") {
                format!("vision_tower.{s}")
            } else if let Some(s) = key.strip_prefix("model.") {
                format!("language_model.model.{s}")
            } else if let Some(s) = key.strip_prefix("lm_head.") {
                format!("language_model.lm_head.{s}")
            } else {
                key.to_owned()
            }
        }
        Family::Qwen3 => {
            if let Some(s) = key
                .strip_prefix("model.visual.")
                .or_else(|| key.strip_prefix("visual."))
            {
                format!("vision_tower.{s}")
            } else if let Some(s) = key.strip_prefix("model.language_model.") {
                format!("language_model.model.{s}")
            } else if let Some(s) = key.strip_prefix("lm_head.") {
                format!("language_model.lm_head.{s}")
            } else {
                key.to_owned()
            }
        }
    }
}
fn sanitize(w: &mut WeightMap, family: Family) -> Result<()> {
    let mut names = BTreeSet::new();
    for key in w.keys() {
        if !names.insert(canonical(key, family)) {
            return Err(model_error("ambiguous weight names"));
        }
    }
    let mut quant_names = BTreeSet::new();
    for key in w.quantization().per_layer.keys() {
        if !quant_names.insert(canonical(key, family)) {
            return Err(model_error("ambiguous quantization names"));
        }
    }
    w.rename_keys(|key| Some(canonical(key, family)));
    w.normalize_quant_keys(|key| Some(canonical(key, family)));
    Ok(())
}

#[derive(Clone)]
struct ImageProcessor {
    patch: i32,
    merge: i32,
    min_pixels: u64,
    max_pixels: u64,
    mean: [f32; 3],
    std: [f32; 3],
    scale: f64,
}
struct Patches {
    pixels: Vec<f32>,
    grid_h: i32,
    grid_w: i32,
}
impl ImageProcessor {
    fn load(cfg: &Value, patch: i32, merge: i32, temporal: i32) -> Result<Self> {
        for key in ["do_resize", "do_rescale", "do_normalize", "do_convert_rgb"] {
            if cfg[key].as_bool().is_some_and(|v| !v) {
                return Err(config_error("image transforms"));
            }
        }
        if cfg["resample"].as_i64().is_some_and(|v| v != 3) {
            return Err(config_error("image resampler"));
        }
        if required_i32(cfg, "patch_size", 1, 64)? != patch
            || required_i32(cfg, "merge_size", 1, 8)? != merge
            || required_i32(cfg, "temporal_patch_size", 1, 8)? != temporal
        {
            return Err(config_error("image grid disagrees with vision"));
        }
        let bound = |legacy: &str, size: &str| -> Result<u64> {
            cfg[legacy]
                .as_u64()
                .or_else(|| cfg["size"][size].as_u64())
                .filter(|n| *n >= 1 && *n <= 32 * 1024 * 1024)
                .ok_or_else(|| config_error("image pixel bounds"))
        };
        let (min_pixels, max_pixels) = (
            bound("min_pixels", "shortest_edge")?,
            bound("max_pixels", "longest_edge")?,
        );
        if min_pixels > max_pixels {
            return Err(config_error("image pixel range"));
        }
        let channels = |key: &str| -> Result<[f32; 3]> {
            let values = cfg[key]
                .as_array()
                .filter(|a| a.len() == 3)
                .ok_or_else(|| config_error(key))?;
            let mut result = [0.0; 3];
            for (i, v) in values.iter().enumerate() {
                result[i] = v
                    .as_f64()
                    .filter(|n| n.is_finite() && *n >= -10.0 && *n <= 10.0)
                    .ok_or_else(|| config_error(key))? as f32;
            }
            Ok(result)
        };
        let mean = channels("image_mean")?;
        let std = channels("image_std")?;
        if std.iter().any(|v| *v <= 0.0) {
            return Err(config_error("image std"));
        }
        let scale = cfg["rescale_factor"].as_f64().unwrap_or(1.0 / 255.0);
        if !scale.is_finite() || scale <= 0.0 || scale > 1.0 {
            return Err(config_error("rescale factor"));
        }
        Ok(Self {
            patch,
            merge,
            min_pixels,
            max_pixels,
            mean,
            std,
            scale,
        })
    }
    fn resized(&self, h: u32, w: u32) -> Result<(u32, u32)> {
        smart_resize(
            h,
            w,
            (self.patch * self.merge) as u32,
            self.min_pixels,
            self.max_pixels,
        )
    }
    fn process(&self, rgb: &RgbImage) -> Result<Patches> {
        let (h, w) = self.resized(rgb.height(), rgb.width())?;
        let rgb = if (h, w) == (rgb.height(), rgb.width()) {
            rgb.clone()
        } else {
            super::processor::bicubic(rgb, w, h)
        };
        let (gh, gw) = (h as i32 / self.patch, w as i32 / self.patch);
        let size = (gh as usize)
            .checked_mul(gw as usize)
            .and_then(|n| n.checked_mul((self.patch * self.patch * 3) as usize))
            .filter(|n| *n <= 3 * 32 * 1024 * 1024)
            .ok_or_else(|| model_error("image allocation bound"))?;
        let mut pixels = Vec::with_capacity(size);
        // Preserve Qwen's merge-block ordering; PatchEmbed repeats this static
        // frame across the temporal dimension without prematurely rounding
        // the checkpoint's temporal weights into a folded kernel.
        for (row, col) in block_positions(gh, gw, self.merge)? {
            for py in 0..self.patch {
                for px in 0..self.patch {
                    let v = rgb
                        .get_pixel(
                            (col * self.patch + px) as u32,
                            (row * self.patch + py) as u32,
                        )
                        .0;
                    for (c, byte) in v.into_iter().enumerate() {
                        let scaled = (f64::from(byte) * self.scale) as f32;
                        pixels.push((scaled - self.mean[c]) / self.std[c]);
                    }
                }
            }
        }
        Ok(Patches {
            pixels,
            grid_h: gh,
            grid_w: gw,
        })
    }
}
fn smart_resize(h: u32, w: u32, factor: u32, min: u64, max: u64) -> Result<(u32, u32)> {
    if h == 0
        || w == 0
        || factor == 0
        || min > max
        || f64::from(h.max(w)) / f64::from(h.min(w)) > 200.0
    {
        return Err(config_error("image aspect ratio"));
    }
    let f = f64::from(factor);
    let (mut rh, mut rw) = (
        (f64::from(h) / f).round_ties_even().max(1.0) * f,
        (f64::from(w) / f).round_ties_even().max(1.0) * f,
    );
    if rh * rw > max as f64 {
        let beta = ((f64::from(h) * f64::from(w)) / max as f64).sqrt();
        rh = ((f64::from(h) / beta / f).floor()).max(1.0) * f;
        rw = ((f64::from(w) / beta / f).floor()).max(1.0) * f;
    } else if rh * rw < min as f64 {
        let beta = (min as f64 / (f64::from(h) * f64::from(w))).sqrt();
        rh = (f64::from(h) * beta / f).ceil().max(1.0) * f;
        rw = (f64::from(w) * beta / f).ceil().max(1.0) * f;
    }
    if rh * rw > 32.0 * 1024.0 * 1024.0 || rh > 32768.0 || rw > 32768.0 {
        return Err(model_error("resized image bound"));
    }
    Ok((rh as u32, rw as u32))
}
fn block_positions(h: i32, w: i32, merge: i32) -> Result<Vec<(i32, i32)>> {
    if h <= 0
        || w <= 0
        || merge <= 0
        || h % merge != 0
        || w % merge != 0
        || i64::from(h) * i64::from(w) > 131072
    {
        return Err(model_error("patch grid"));
    }
    let mut coords = Vec::with_capacity((h * w) as usize);
    for bh in 0..h / merge {
        for bw in 0..w / merge {
            for ih in 0..merge {
                for iw in 0..merge {
                    coords.push((bh * merge + ih, bw * merge + iw));
                }
            }
        }
    }
    Ok(coords)
}

struct PatchEmbed {
    weight: Array,
    bias: Option<Array>,
    patch: i32,
    temporal: i32,
    output: i32,
}
impl PatchEmbed {
    fn load(
        w: &mut WeightMap,
        hidden: i32,
        patch: i32,
        temporal: i32,
        family: Family,
    ) -> Result<Self> {
        let mut weight = w.take("vision_tower.patch_embed.proj.weight")?;
        if weight.shape() == [hidden, 3, temporal, patch, patch] {
            weight = ops::transpose_axes(&weight, &[0, 2, 3, 4, 1])?;
        }
        exact_shape(&weight, &[hidden, temporal, patch, patch, 3])?;
        let weight = ops::reshape(&weight, &[hidden, temporal * patch * patch * 3])?;
        let bias = w.take_optional("vision_tower.patch_embed.proj.bias");
        if bias.is_some() != (family == Family::Qwen3) {
            return Err(model_error("patch bias"));
        }
        if let Some(b) = &bias {
            exact_shape(b, &[hidden])?;
        }
        Ok(Self {
            weight,
            bias,
            patch,
            temporal,
            output: hidden,
        })
    }
    fn forward(&self, p: &Patches) -> Result<Array> {
        let input = ops::astype(
            &Array::from_slice(
                &p.pixels,
                &[p.grid_h * p.grid_w, self.patch * self.patch * 3],
            ),
            self.weight.dtype(),
        )?;
        let input = ops::reshape(
            &ops::broadcast_to(
                &ops::reshape(
                    &input,
                    &[p.grid_h * p.grid_w, 1, self.patch * self.patch * 3],
                )?,
                &[
                    p.grid_h * p.grid_w,
                    self.temporal,
                    self.patch * self.patch * 3,
                ],
            )?,
            &[
                p.grid_h * p.grid_w,
                self.temporal * self.patch * self.patch * 3,
            ],
        )?;
        let out = ops::matmul(&input, &ops::transpose_axes(&self.weight, &[1, 0])?)?;
        let out = match &self.bias {
            Some(b) => ops::add(&out, b)?,
            None => out,
        };
        exact_shape(&out, &[p.grid_h * p.grid_w, self.output])?;
        Ok(out)
    }
}
struct Merger {
    norm: LayerNorm,
    fc1: Linear,
    fc2: Linear,
    merged: i32,
    post: bool,
}
impl Merger {
    fn load(
        w: &mut WeightMap,
        p: &str,
        hidden: i32,
        out: i32,
        merge: i32,
        family: Family,
        post: bool,
    ) -> Result<Self> {
        let merged = hidden * merge * merge;
        let (norm, a, b) = if family == Family::Qwen2 {
            ("ln_q", "mlp.0", "mlp.2")
        } else {
            ("norm", "linear_fc1", "linear_fc2")
        };
        Ok(Self {
            norm: layer_norm(
                w,
                &format!("{p}.{norm}"),
                if post { merged } else { hidden },
            )?,
            fc1: linear(w, &format!("{p}.{a}"), merged, merged, true)?,
            fc2: linear(w, &format!("{p}.{b}"), merged, out, true)?,
            merged,
            post,
        })
    }
    fn forward(&self, x: &Array) -> Result<Array> {
        let x = if self.post {
            self.norm.forward(&ops::reshape(x, &[-1, self.merged])?)?
        } else {
            ops::reshape(&self.norm.forward(x)?, &[-1, self.merged])?
        };
        self.fc2.forward(&ops::gelu_erf(&self.fc1.forward(&x)?)?)
    }
}
struct VisionBlock {
    norm1: LayerNorm,
    norm2: LayerNorm,
    qkv: Linear,
    proj: Linear,
    fc1: Linear,
    fc2: Linear,
    heads: i32,
    family: Family,
}
impl VisionBlock {
    fn load(
        w: &mut WeightMap,
        p: &str,
        hidden: i32,
        intermediate: i32,
        heads: i32,
        family: Family,
    ) -> Result<Self> {
        let (a, b) = if family == Family::Qwen2 {
            ("fc1", "fc2")
        } else {
            ("linear_fc1", "linear_fc2")
        };
        Ok(Self {
            norm1: layer_norm(w, &format!("{p}.norm1"), hidden)?,
            norm2: layer_norm(w, &format!("{p}.norm2"), hidden)?,
            qkv: linear(w, &format!("{p}.attn.qkv"), hidden, hidden * 3, true)?,
            proj: linear(w, &format!("{p}.attn.proj"), hidden, hidden, true)?,
            fc1: linear(w, &format!("{p}.mlp.{a}"), hidden, intermediate, true)?,
            fc2: linear(w, &format!("{p}.mlp.{b}"), intermediate, hidden, true)?,
            heads,
            family,
        })
    }
    fn forward(&self, x: &Array, angles: &Array) -> Result<Array> {
        let (seq, hidden) = (x.dim(0), x.dim(1));
        let qkv = ops::reshape(
            &self.qkv.forward(&self.norm1.forward(x)?)?,
            &[seq, 3, self.heads, hidden / self.heads],
        )?;
        let part = |i| -> Result<Array> {
            ops::transpose_axes(
                &ops::reshape(
                    &ops::slice(
                        &qkv,
                        &[0, i, 0, 0],
                        &[seq, i + 1, self.heads, hidden / self.heads],
                    )?,
                    &[1, seq, self.heads, hidden / self.heads],
                )?,
                &[0, 2, 1, 3],
            )
        };
        let (q, k, v) = (
            rotate(&part(0)?, angles, false)?,
            rotate(&part(1)?, angles, false)?,
            part(2)?,
        );
        let result = ops::scaled_dot_product_attention(
            &q,
            &k,
            &v,
            (hidden as f32 / self.heads as f32).powf(-0.5),
            AttentionMask::None,
        )?;
        let result = ops::reshape(
            &ops::transpose_axes(&result, &[0, 2, 1, 3])?,
            &[seq, hidden],
        )?;
        let x = ops::add(x, &self.proj.forward(&result)?)?;
        let feed = self.fc1.forward(&self.norm2.forward(&x)?)?;
        let feed = if self.family == Family::Qwen2 {
            ops::multiply(&feed, &ops::sigmoid(&ops::scale_by(&feed, 1.702)?)?)?
        } else {
            ops::gelu_tanh(&feed)?
        };
        ops::add(&x, &self.fc2.forward(&feed)?)
    }
}
struct Vision {
    patch: PatchEmbed,
    blocks: Vec<VisionBlock>,
    merger: Merger,
    pos: Option<Array>,
    deep: Vec<(usize, Merger)>,
    heads: i32,
    hidden: i32,
    merge: i32,
}
struct VisualFeatures {
    main: Array,
    deep: Vec<Array>,
}
impl Vision {
    fn load(
        w: &mut WeightMap,
        cfg: &Value,
        family: Family,
        text_hidden: i32,
    ) -> Result<(Self, ImageGrid)> {
        let hidden = required_i32(
            cfg,
            if family == Family::Qwen2 {
                "embed_dim"
            } else {
                "hidden_size"
            },
            4,
            8192,
        )?;
        let heads = required_i32(cfg, "num_heads", 1, 128)?;
        let depth = required_i32(cfg, "depth", 1, 64)?;
        let merge = required_i32(cfg, "spatial_merge_size", 1, 8)?;
        let patch = required_i32(cfg, "patch_size", 1, 64)?;
        let temporal = required_i32(cfg, "temporal_patch_size", 1, 8)?;
        if hidden % heads != 0
            || (hidden / heads) % 4 != 0
            || required_i32(cfg, "in_channels", 3, 3)? != 3
        {
            return Err(config_error("vision heads"));
        }
        let out = required_i32(
            cfg,
            if family == Family::Qwen2 {
                "hidden_size"
            } else {
                "out_hidden_size"
            },
            4,
            8192,
        )?;
        if out != text_hidden {
            return Err(config_error("vision output"));
        }
        let intermediate = if family == Family::Qwen2 {
            let value = hidden as f64 * number(cfg, "mlp_ratio", 1.0, 16.0)?;
            if value.fract() != 0.0 {
                return Err(config_error("vision intermediate"));
            }
            value as i32
        } else {
            required_i32(cfg, "intermediate_size", 4, 131072)?
        };
        let patch_layer = PatchEmbed::load(w, hidden, patch, temporal, family)?;
        let mut blocks = Vec::with_capacity(depth as usize);
        for i in 0..depth {
            blocks.push(VisionBlock::load(
                w,
                &format!("vision_tower.blocks.{i}"),
                hidden,
                intermediate,
                heads,
                family,
            )?);
        }
        let merger = Merger::load(w, "vision_tower.merger", hidden, out, merge, family, false)?;
        let (pos, deep) = if family == Family::Qwen3 {
            let count = required_i32(cfg, "num_position_embeddings", 1, 65536)?;
            if ((count as f64).sqrt() as i32).pow(2) != count {
                return Err(config_error("vision position square"));
            }
            let pos = w.take("vision_tower.pos_embed.weight")?;
            exact_shape(&pos, &[count, hidden])?;
            let indexes = required_list(cfg, "deepstack_visual_indexes", 0, depth - 1)?;
            if indexes.len() > depth as usize || indexes.windows(2).any(|v| v[0] >= v[1]) {
                return Err(config_error("deepstack indexes"));
            }
            let mut deep = Vec::new();
            for (i, index) in indexes.into_iter().enumerate() {
                deep.push((
                    index as usize,
                    Merger::load(
                        w,
                        &format!("vision_tower.deepstack_merger_list.{i}"),
                        hidden,
                        out,
                        merge,
                        family,
                        true,
                    )?,
                ));
            }
            (Some(pos), deep)
        } else {
            (None, Vec::new())
        };
        Ok((
            Self {
                patch: patch_layer,
                blocks,
                merger,
                pos,
                deep,
                heads,
                hidden,
                merge,
            },
            ImageGrid {
                patch,
                merge,
                temporal,
            },
        ))
    }
    fn forward(&self, p: &Patches, alive: &mut impl FnMut() -> bool) -> Result<VisualFeatures> {
        let mut x = self.patch.forward(p)?;
        if let Some(table) = &self.pos {
            x = ops::add(
                &x,
                &interpolate_positions(table, p.grid_h, p.grid_w, self.merge)?,
            )?;
        }
        let angles = vision_angles(p.grid_h, p.grid_w, self.merge, self.hidden / self.heads)?;
        let mut deep = Vec::with_capacity(self.deep.len());
        for (i, block) in self.blocks.iter().enumerate() {
            check_alive(alive)?;
            x = block.forward(&x, &angles)?;
            if let Some((_, merger)) = self.deep.iter().find(|(index, _)| *index == i) {
                deep.push(merger.forward(&x)?);
            }
            x.eval()?;
        }
        let main = self.merger.forward(&x)?;
        main.eval()?;
        for item in &deep {
            item.eval()?;
        }
        check_alive(alive)?;
        Ok(VisualFeatures { main, deep })
    }
}
struct ImageGrid {
    patch: i32,
    merge: i32,
    temporal: i32,
}
fn vision_angles(h: i32, w: i32, merge: i32, head: i32) -> Result<Array> {
    let mut values = Vec::with_capacity((h * w * head / 2) as usize);
    for (row, col) in block_positions(h, w, merge)? {
        for pos in [row, col] {
            for i in 0..head / 4 {
                values.push(pos as f32 / 10000_f32.powf(2.0 * i as f32 / (head / 2) as f32));
            }
        }
    }
    let half = Array::from_slice(&values, &[h * w, head / 2]);
    ops::reshape(
        &ops::concatenate(&[&half, &half], -1)?,
        &[1, 1, h * w, head],
    )
}
fn interpolate_positions(table: &Array, h: i32, w: i32, merge: i32) -> Result<Array> {
    let side = (table.dim(0) as f64).sqrt() as i32;
    let coords = block_positions(h, w, merge)?;
    let seq = coords.len() as i32;
    let mut output: Option<Array> = None;
    for corner in 0..4 {
        let mut indexes = Vec::with_capacity(coords.len());
        let mut weights = Vec::with_capacity(coords.len());
        for &(row, col) in &coords {
            let y = if h == 1 {
                0.0
            } else {
                row as f32 * (side - 1) as f32 / (h - 1) as f32
            };
            let x = if w == 1 {
                0.0
            } else {
                col as f32 * (side - 1) as f32 / (w - 1) as f32
            };
            let (y0, x0) = (y as i32, x as i32);
            let (dy, dx) = (y - y0 as f32, x - x0 as f32);
            let row = if corner >= 2 {
                (y0 + 1).min(side - 1)
            } else {
                y0
            };
            let col = if corner % 2 == 1 {
                (x0 + 1).min(side - 1)
            } else {
                x0
            };
            indexes.push(row * side + col);
            weights.push(
                (if corner >= 2 { dy } else { 1.0 - dy })
                    * (if corner % 2 == 1 { dx } else { 1.0 - dx }),
            );
        }
        let values = ops::take_axis(table, &Array::from_slice(&indexes, &[seq]), 0)?;
        let weights = ops::astype(&Array::from_slice(&weights, &[seq, 1]), table.dtype())?;
        let term = ops::multiply(&values, &weights)?;
        output = Some(match output {
            Some(old) => ops::add(&old, &term)?,
            None => term,
        });
    }
    output.ok_or_else(|| model_error("position interpolation"))
}
fn rotate(x: &Array, angles: &Array, float_compute: bool) -> Result<Array> {
    let dtype = x.dtype();
    let x = if float_compute {
        ops::astype(x, Dtype::Float32)?
    } else {
        x.clone()
    };
    let dims = x.shape();
    let head = x.dim(-1);
    let mut half_stop = dims.clone();
    half_stop[3] = head / 2;
    let a = ops::slice(&x, &[0, 0, 0, 0], &half_stop)?;
    let b = ops::slice(&x, &[0, 0, 0, head / 2], &dims)?;
    let rotated = ops::concatenate(&[&ops::negative(&b)?, &a], -1)?;
    let cosine = ops::cos(angles)?;
    let sine = ops::sin(angles)?;
    ops::astype(
        &ops::add(
            &ops::multiply(&x, &cosine)?,
            &ops::multiply(&rotated, &sine)?,
        )?,
        dtype,
    )
}

struct TextBlock {
    input: RmsNorm,
    post: RmsNorm,
    q: Linear,
    k: Linear,
    v: Linear,
    o: Linear,
    qnorm: Option<RmsNorm>,
    knorm: Option<RmsNorm>,
    gate: Linear,
    up: Linear,
    down: Linear,
    heads: i32,
    kv_heads: i32,
    head: i32,
}
impl TextBlock {
    fn load(w: &mut WeightMap, p: &str, cfg: &Value, family: Family) -> Result<Self> {
        let hidden = required_i32(cfg, "hidden_size", 4, 16384)?;
        let heads = required_i32(cfg, "num_attention_heads", 1, 128)?;
        let kv_heads = required_i32(cfg, "num_key_value_heads", 1, 128)?;
        let head = if family == Family::Qwen2 {
            hidden / heads
        } else {
            cfg["head_dim"]
                .as_i64()
                .map(|n| i32::try_from(n).unwrap_or(0))
                .unwrap_or(hidden / heads)
        };
        if hidden % heads != 0 || head <= 0 || head > 1024 || head % 2 != 0 || heads % kv_heads != 0
        {
            return Err(config_error("language heads"));
        }
        let intermediate = required_i32(cfg, "intermediate_size", 4, 131072)?;
        let eps = number(cfg, "rms_norm_eps", 1e-9, 0.001)? as f32;
        let a = format!("{p}.self_attn");
        let m = format!("{p}.mlp");
        Ok(Self {
            input: rms_norm(w, &format!("{p}.input_layernorm"), hidden, eps)?,
            post: rms_norm(w, &format!("{p}.post_attention_layernorm"), hidden, eps)?,
            q: linear(
                w,
                &format!("{a}.q_proj"),
                hidden,
                heads * head,
                family == Family::Qwen2,
            )?,
            k: linear(
                w,
                &format!("{a}.k_proj"),
                hidden,
                kv_heads * head,
                family == Family::Qwen2,
            )?,
            v: linear(
                w,
                &format!("{a}.v_proj"),
                hidden,
                kv_heads * head,
                family == Family::Qwen2,
            )?,
            o: linear(w, &format!("{a}.o_proj"), heads * head, hidden, false)?,
            qnorm: if family == Family::Qwen3 {
                Some(rms_norm(w, &format!("{a}.q_norm"), head, eps)?)
            } else {
                None
            },
            knorm: if family == Family::Qwen3 {
                Some(rms_norm(w, &format!("{a}.k_norm"), head, eps)?)
            } else {
                None
            },
            gate: linear(w, &format!("{m}.gate_proj"), hidden, intermediate, false)?,
            up: linear(w, &format!("{m}.up_proj"), hidden, intermediate, false)?,
            down: linear(w, &format!("{m}.down_proj"), intermediate, hidden, false)?,
            heads,
            kv_heads,
            head,
        })
    }
    fn forward(&self, x: &Array, angles: &Array, cache: &mut KvCache) -> Result<Array> {
        let len = x.dim(1);
        let input = self.input.forward(x)?;
        let q = ops::reshape(&self.q.forward(&input)?, &[1, len, self.heads, self.head])?;
        let k = ops::reshape(
            &self.k.forward(&input)?,
            &[1, len, self.kv_heads, self.head],
        )?;
        let q = match &self.qnorm {
            Some(n) => n.forward(&q)?,
            None => q,
        };
        let k = match &self.knorm {
            Some(n) => n.forward(&k)?,
            None => k,
        };
        let q = rotate(&ops::transpose_axes(&q, &[0, 2, 1, 3])?, angles, true)?;
        let k = rotate(&ops::transpose_axes(&k, &[0, 2, 1, 3])?, angles, true)?;
        let v = ops::transpose_axes(
            &ops::reshape(
                &self.v.forward(&input)?,
                &[1, len, self.kv_heads, self.head],
            )?,
            &[0, 2, 1, 3],
        )?;
        let offset = cache.offset();
        let (k, v) = cache.update_and_fetch(k, v)?;
        let attended = if len == 1 {
            ops::scaled_dot_product_attention(
                &q,
                &k,
                &v,
                (self.head as f32).powf(-0.5),
                AttentionMask::None,
            )?
        } else if offset == 0 {
            ops::scaled_dot_product_attention(
                &q,
                &k,
                &v,
                (self.head as f32).powf(-0.5),
                AttentionMask::Causal,
            )?
        } else {
            let mask = ops::sliding_window_mask(len, offset + len, offset, i32::MAX, q.dtype())?;
            ops::scaled_dot_product_attention_masked(
                &q,
                &k,
                &v,
                (self.head as f32).powf(-0.5),
                &mask,
            )?
        };
        let attended = ops::reshape(
            &ops::transpose_axes(&attended, &[0, 2, 1, 3])?,
            &[1, len, self.heads * self.head],
        )?;
        let x = ops::add(x, &self.o.forward(&attended)?)?;
        let normalized = self.post.forward(&x)?;
        let gate = self.gate.forward(&normalized)?;
        let gated = ops::multiply(
            &ops::multiply(&gate, &ops::sigmoid(&gate)?)?,
            &self.up.forward(&normalized)?,
        )?;
        let out = ops::add(&x, &self.down.forward(&gated)?)?;
        // Force caches as well as the residual to avoid retaining old lazy
        // computation graphs across prefill chunks or decoder steps.
        k.eval()?;
        v.eval()?;
        Ok(out)
    }
}
struct Positions {
    axes: Vec<[i32; 3]>,
    image_start: usize,
    image_len: usize,
    next: i32,
}
fn prompt_positions(
    tokens: &[u32],
    image: u32,
    start: u32,
    end: u32,
    h: i32,
    w: i32,
) -> Result<Positions> {
    let image_start = tokens
        .iter()
        .position(|id| *id == image)
        .ok_or_else(|| model_error("missing image marker"))?;
    let count = (h * w) as usize;
    if count == 0
        || image_start == 0
        || tokens[image_start - 1] != start
        || image_start + count >= tokens.len()
        || tokens[image_start + count] != end
        || tokens[image_start..image_start + count]
            .iter()
            .any(|id| *id != image)
        || tokens.iter().filter(|id| **id == image).count() != count
        || tokens.iter().filter(|id| **id == start).count() != 1
        || tokens.iter().filter(|id| **id == end).count() != 1
    {
        return Err(model_error("image marker bundle"));
    }
    let mut axes = Vec::with_capacity(tokens.len());
    for i in 0..image_start {
        axes.push([i as i32; 3]);
    }
    for row in 0..h {
        for col in 0..w {
            axes.push([
                image_start as i32,
                image_start as i32 + row,
                image_start as i32 + col,
            ]);
        }
    }
    let base = image_start as i32 + h.max(w);
    for i in 0..tokens.len() - image_start - count {
        axes.push([base + i as i32; 3]);
    }
    let next = axes
        .iter()
        .flat_map(|a| a.iter())
        .copied()
        .max()
        .ok_or_else(|| model_error("empty positions"))?
        + 1;
    Ok(Positions {
        axes,
        image_start,
        image_len: count,
        next,
    })
}
fn selector(family: Family, sections: &[i32], head: i32) -> Result<Vec<usize>> {
    if sections.len() != 3
        || sections.iter().any(|n| *n < 0)
        || sections.iter().sum::<i32>() != head / 2
    {
        return Err(config_error("mrope sections"));
    }
    let mut selected = vec![0; head as usize / 2];
    if family == Family::Qwen2 {
        let mut offset = sections[0] as usize;
        for (dim, length) in sections.iter().enumerate().skip(1) {
            selected[offset..offset + *length as usize].fill(dim);
            offset += *length as usize;
        }
    } else {
        let freq = selected.len();
        for (dim, length) in sections.iter().enumerate().skip(1) {
            for selected in selected
                .iter_mut()
                .take((*length as usize * 3).min(freq))
                .skip(dim)
                .step_by(3)
            {
                *selected = dim;
            }
        }
    }
    Ok(selected)
}
fn language_angles(positions: &[[i32; 3]], selector: &[usize], theta: f32) -> Result<Array> {
    let head = selector.len() * 2;
    let mut angles = Vec::with_capacity(positions.len() * selector.len());
    for pos in positions {
        for (i, axis) in selector.iter().enumerate() {
            angles.push(pos[*axis] as f32 / theta.powf(2.0 * i as f32 / head as f32));
        }
    }
    let half = Array::from_slice(&angles, &[positions.len() as i32, selector.len() as i32]);
    ops::reshape(
        &ops::concatenate(&[&half, &half], -1)?,
        &[1, 1, positions.len() as i32, head as i32],
    )
}

pub(super) struct QwenVl {
    tokenizer: Tokenizer,
    processor: ImageProcessor,
    vision: Vision,
    embedding: Embedding,
    layers: Vec<TextBlock>,
    norm: RmsNorm,
    lm_head: Option<Linear>,
    selector: Vec<usize>,
    theta: f32,
    hidden: i32,
    vocab: i32,
    context: i32,
    image: u32,
    vision_start: u32,
    vision_end: u32,
    video: u32,
}
impl QwenVl {
    pub(super) fn load(
        w: &mut WeightMap,
        cfg: &Value,
        processor: &Value,
        mut tokenizer: Tokenizer,
    ) -> Result<Self> {
        let family = match cfg["model_type"].as_str() {
            Some("qwen2_vl") => Family::Qwen2,
            Some("qwen3_vl") => Family::Qwen3,
            _ => return Err(config_error("architecture")),
        };
        let text = if cfg["text_config"].is_object() {
            &cfg["text_config"]
        } else {
            cfg
        };
        if text["hidden_act"].as_str().is_some_and(|v| v != "silu")
            || text["use_sliding_window"].as_bool() == Some(true)
            || text["attention_bias"].as_bool() == Some(true) && family == Family::Qwen3
            || text["use_final_norm"].as_bool() == Some(false)
        {
            return Err(config_error("language configuration"));
        }
        let hidden = required_i32(text, "hidden_size", 4, 16384)?;
        let vocab = required_i32(text, "vocab_size", 256, 262144)?;
        let depth = required_i32(text, "num_hidden_layers", 1, 128)?;
        let context = required_i32(text, "max_position_embeddings", 128, 131072)?;
        let theta = number(text, "rope_theta", 1.0, 1e9)? as f32;
        let eps = number(text, "rms_norm_eps", 1e-9, 0.001)? as f32;
        let rope = &text["rope_scaling"];
        if rope["rope_type"]
            .as_str()
            .or_else(|| rope["type"].as_str())
            .is_some_and(|v| v != "default")
        {
            return Err(config_error("rope scaling"));
        }
        let sections = required_list(rope, "mrope_section", 0, 512)?;
        let heads = required_i32(text, "num_attention_heads", 1, 128)?;
        let head = if family == Family::Qwen2 {
            hidden / heads
        } else {
            text["head_dim"]
                .as_i64()
                .map(|n| i32::try_from(n).unwrap_or(0))
                .unwrap_or(hidden / heads)
        };
        let selector = selector(family, &sections, head)?;
        sanitize(w, family)?;
        let (vision, grid) = Vision::load(w, &cfg["vision_config"], family, hidden)?;
        let processor = ImageProcessor::load(processor, grid.patch, grid.merge, grid.temporal)?;
        let embedding = w.embedding("language_model.model.embed_tokens")?;
        match &embedding {
            Embedding::Dense { weight } => exact_shape(weight, &[vocab, hidden])?,
            Embedding::Quantized {
                weight,
                scales,
                params,
                ..
            } => {
                if ![2, 4, 8].contains(&params.bits)
                    || params.group_size <= 0
                    || hidden % params.group_size != 0
                {
                    return Err(model_error("quantized embedding parameters"));
                }
                exact_shape(weight, &[vocab, hidden / (32 / params.bits)])?;
                exact_shape(scales, &[vocab, hidden / params.group_size])?;
            }
        }
        let mut layers = Vec::with_capacity(depth as usize);
        for i in 0..depth {
            layers.push(TextBlock::load(
                w,
                &format!("language_model.model.layers.{i}"),
                text,
                family,
            )?);
        }
        if vision.deep.len() > layers.len() {
            return Err(config_error("deepstack exceeds language layers"));
        }
        let norm = rms_norm(w, "language_model.model.norm", hidden, eps)?;
        let tied = text["tie_word_embeddings"]
            .as_bool()
            .or_else(|| cfg["tie_word_embeddings"].as_bool())
            .ok_or_else(|| config_error("tied embeddings"))?;
        let lm_head = if tied {
            // Some non-quantized publishers serialize the identical tied
            // lm_head too. Require exact equality before dropping that copy.
            if w.contains("language_model.lm_head.weight") {
                let duplicate = w.take("language_model.lm_head.weight")?;
                let Embedding::Dense { weight } = &embedding else {
                    return Err(model_error("quantized duplicate tied head"));
                };
                exact_shape(&duplicate, &weight.shape())?;
                let same = ops::astype(&ops::equal(&duplicate, weight)?, Dtype::UInt32)?;
                let count = ops::sum_axes(&same, &[0, 1], false)?.item_u32()?;
                if count as usize != weight.size() {
                    return Err(model_error("unequal tied head"));
                }
            }
            None
        } else {
            Some(linear(w, "language_model.lm_head", hidden, vocab, false)?)
        };
        if w.keys().next().is_some() {
            return Err(model_error("unexpected checkpoint tensors"));
        }
        let id = |key: &str, default: u32| -> Result<u32> {
            cfg[key]
                .as_u64()
                .map(|n| u32::try_from(n).unwrap_or(u32::MAX))
                .or_else(|| text[key].as_u64().map(|n| n as u32))
                .unwrap_or(default)
                .checked_add(0)
                .filter(|n| *n < vocab as u32)
                .ok_or_else(|| config_error("special token"))
        };
        let image = id("image_token_id", 151655)?;
        let vision_start = id("vision_start_token_id", 151652)?;
        let vision_end = id("vision_end_token_id", 151653)?;
        let video = id("video_token_id", 151656)?;
        if let Some(eos) = text["eos_token_id"]
            .as_u64()
            .or_else(|| cfg["eos_token_id"].as_u64())
        {
            if eos >= vocab as u64 {
                return Err(config_error("eos token"));
            }
            tokenizer.add_eos_id(eos as u32);
        }
        if tokenizer.eos_token_ids().is_empty() {
            return Err(config_error("missing eos token"));
        }
        Ok(Self {
            tokenizer,
            processor,
            vision,
            embedding,
            layers,
            norm,
            lm_head,
            selector,
            theta,
            hidden,
            vocab,
            context,
            image,
            vision_start,
            vision_end,
            video,
        })
    }
    pub(super) fn generate(
        &self,
        png: &[u8],
        messages: &[ChatMessage],
        max_tokens: usize,
        alive: &mut impl FnMut() -> bool,
    ) -> Result<String> {
        if max_tokens == 0 || max_tokens > 2048 {
            return Err(config_error("generation bound"));
        }
        check_alive(alive)?;
        let images = messages.iter().flat_map(|m| m.images()).collect::<Vec<_>>();
        if images.len() != 1
            || images[0].bytes != png
            || messages
                .iter()
                .any(|m| m.audios().next().is_some() || m.videos().next().is_some())
            || messages.iter().flat_map(|m| &m.content).any(|p| match p {
                ContentPart::Text(t) => [
                    "<|image_pad|>",
                    "<|video_pad|>",
                    "<|vision_start|>",
                    "<|vision_end|>",
                ]
                .iter()
                .any(|s| t.contains(s)),
                _ => false,
            })
        {
            return Err(model_error("single screenshot content"));
        }
        let rgb = super::processor::png(png).map_err(|_| model_error("bounded PNG"))?;
        let patches = self.processor.process(&rgb)?;
        let prompt = self
            .tokenizer
            .apply_chat_template_full(messages, true, None, Some(false))?;
        let raw = self.tokenizer.encode(&prompt)?;
        if raw.iter().filter(|id| **id == self.image).count() != 1 || raw.contains(&self.video) {
            return Err(model_error("template image marker"));
        }
        let count = (patches.grid_h * patches.grid_w
            / (self.processor.merge * self.processor.merge)) as usize;
        let len = raw
            .len()
            .checked_add(count - 1)
            .ok_or_else(|| model_error("prompt overflow"))?;
        if len + max_tokens > self.context as usize || raw.iter().any(|id| *id >= self.vocab as u32)
        {
            return Err(model_error("visual context exceeded"));
        }
        let mut tokens = Vec::with_capacity(len);
        for id in raw {
            if id == self.image {
                tokens.extend(std::iter::repeat_n(id, count));
            } else {
                tokens.push(id);
            }
        }
        let pos = prompt_positions(
            &tokens,
            self.image,
            self.vision_start,
            self.vision_end,
            patches.grid_h / self.processor.merge,
            patches.grid_w / self.processor.merge,
        )?;
        let visual = self.vision.forward(&patches, alive)?;
        exact_shape(&visual.main, &[count as i32, self.hidden])?;
        let mut caches = (0..self.layers.len())
            .map(|_| KvCache::new())
            .collect::<Vec<_>>();
        let mut last = None;
        // Bounded prefill follows the existing 512-token MLX path. The
        // image/deepstack additions are sliced to each exact chunk.
        for begin in (0..tokens.len()).step_by(512) {
            check_alive(alive)?;
            let end = (begin + 512).min(tokens.len());
            let ids = Array::from_slice(&tokens[begin..end], &[1, (end - begin) as i32]);
            let mut x = self.embedding.forward(&ids)?;
            let overlap_begin = begin.max(pos.image_start);
            let overlap_end = end.min(pos.image_start + pos.image_len);
            if overlap_begin < overlap_end {
                let features = ops::reshape(
                    &ops::slice(
                        &visual.main,
                        &[(overlap_begin - pos.image_start) as i32, 0],
                        &[(overlap_end - pos.image_start) as i32, self.hidden],
                    )?,
                    &[1, (overlap_end - overlap_begin) as i32, self.hidden],
                )?;
                x = ops::slice_update(
                    &x,
                    &ops::astype(&features, x.dtype())?,
                    &[0, (overlap_begin - begin) as i32, 0],
                    &[1, (overlap_end - begin) as i32, self.hidden],
                )?;
            }
            let angles = language_angles(&pos.axes[begin..end], &self.selector, self.theta)?;
            for (i, (layer, cache)) in self.layers.iter().zip(caches.iter_mut()).enumerate() {
                check_alive(alive)?;
                x = layer.forward(&x, &angles, cache)?;
                if i < visual.deep.len() && overlap_begin < overlap_end {
                    let local_begin = (overlap_begin - begin) as i32;
                    let local_end = (overlap_end - begin) as i32;
                    let existing =
                        ops::slice(&x, &[0, local_begin, 0], &[1, local_end, self.hidden])?;
                    let features = ops::reshape(
                        &ops::slice(
                            &visual.deep[i],
                            &[(overlap_begin - pos.image_start) as i32, 0],
                            &[(overlap_end - pos.image_start) as i32, self.hidden],
                        )?,
                        &[1, local_end - local_begin, self.hidden],
                    )?;
                    let update = ops::add(&existing, &ops::astype(&features, x.dtype())?)?;
                    x = ops::slice_update(
                        &x,
                        &update,
                        &[0, local_begin, 0],
                        &[1, local_end, self.hidden],
                    )?;
                }
                x.eval()?;
            }
            last = Some(ops::slice(
                &x,
                &[0, (end - begin - 1) as i32, 0],
                &[1, (end - begin) as i32, self.hidden],
            )?);
        }
        let mut x = last.ok_or_else(|| model_error("empty prefill"))?;
        let mut generated = Vec::with_capacity(max_tokens);
        for step in 0..max_tokens {
            check_alive(alive)?;
            let normalized = self.norm.forward(&x)?;
            let logits = match &self.lm_head {
                Some(head) => head.forward(&normalized)?,
                None => self.embedding.as_linear(&normalized)?,
            };
            let id = ops::argmax_axis(&logits, -1, false)?.item_u32()?;
            if self.tokenizer.eos_token_ids().contains(&id) {
                let text = self.tokenizer.decode(&generated)?;
                if text.len() > 16_000 {
                    return Err(model_error("output bytes exceeded"));
                }
                check_alive(alive)?;
                return Ok(text);
            }
            if id >= self.vocab as u32
                || [self.image, self.vision_start, self.vision_end, self.video].contains(&id)
            {
                return Err(model_error("invalid generated token"));
            }
            generated.push(id);
            if self.tokenizer.decode(&generated)?.len() > 16_000 {
                return Err(model_error("output bytes exceeded"));
            }
            if step + 1 == max_tokens {
                break;
            }
            let next = pos
                .next
                .checked_add(step as i32)
                .filter(|n| *n < self.context)
                .ok_or_else(|| model_error("position overflow"))?;
            let angles = language_angles(&[[next; 3]], &self.selector, self.theta)?;
            x = self.embedding.forward(&Array::from_slice(&[id], &[1, 1]))?;
            for (layer, cache) in self.layers.iter().zip(caches.iter_mut()) {
                check_alive(alive)?;
                x = layer.forward(&x, &angles, cache)?;
                x.eval()?;
            }
        }
        Err(model_error("generation did not reach EOS"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mlex::quant::Quantization;
    use std::collections::HashMap;

    // Frozen outputs from the actual upstream mlx-vlm Qwen2/3 VisionModel
    // and decoder layers, evaluated with deterministic synthetic weights.
    // Production and tests execute only Rust; no interpreter is required to
    // consume this independent numerical reference.
    fn fixture(name: &str) -> Value {
        serde_json::from_slice::<Value>(include_bytes!("qwen-fixtures.json")).unwrap()[name].clone()
    }
    fn weights(f: &Value) -> WeightMap {
        let tensors = f["weights"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, tensor)| {
                let shape = tensor["shape"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_i64().unwrap() as i32)
                    .collect::<Vec<_>>();
                let values = tensor["values"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|n| n.as_f64().unwrap() as f32)
                    .collect::<Vec<_>>();
                (name.clone(), Array::from_slice(&values, &shape))
            })
            .collect::<HashMap<_, _>>();
        WeightMap::new(tensors, Quantization::default())
    }
    fn floats(f: &Value) -> Vec<f32> {
        f.as_array()
            .unwrap()
            .iter()
            .map(|n| n.as_f64().unwrap() as f32)
            .collect()
    }
    fn near(actual: &[f32], expected: &[f32]) {
        assert_eq!(actual.len(), expected.len());
        for (i, (a, b)) in actual.iter().zip(expected).enumerate() {
            assert!(
                a.is_finite() && (a - b).abs() < 2e-6,
                "tensor index {i}: actual {a}, expected {b}"
            );
        }
    }
    #[test]
    fn both_vision_architectures_match_upstream_numerical_fixtures() {
        for (name, family) in [
            ("qwen2_vision", Family::Qwen2),
            ("qwen3_vision", Family::Qwen3),
        ] {
            let f = fixture(name);
            let mut weights = weights(&f);
            let (vision, _) = Vision::load(&mut weights, &f["config"], family, 8).unwrap();
            assert_eq!(weights.keys().count(), 0);
            let p = Patches {
                pixels: floats(&f["pixels"]),
                grid_h: 4,
                grid_w: 4,
            };
            let actual = vision.forward(&p, &mut || true).unwrap();
            near(&actual.main.to_vec_f32().unwrap(), &floats(&f["main"]));
            let expected = f["deep"].as_array().unwrap();
            assert_eq!(actual.deep.len(), expected.len());
            for (a, e) in actual.deep.iter().zip(expected) {
                near(&a.to_vec_f32().unwrap(), &floats(e));
            }
            assert!(vision.forward(&p, &mut || false).is_err());
        }
    }
    #[test]
    fn grouped_text_attention_matches_upstream_and_chunked_prefill() {
        for (name, family) in [("qwen2_text", Family::Qwen2), ("qwen3_text", Family::Qwen3)] {
            let f = fixture(name);
            let mut weights = weights(&f);
            let block = TextBlock::load(&mut weights, "layer", &f["config"], family).unwrap();
            assert_eq!(weights.keys().count(), 0);
            let input = Array::from_slice(&floats(&f["input"]), &[1, 5, 16]);
            let positions = f["positions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| {
                    let row = row.as_array().unwrap();
                    [
                        row[0].as_i64().unwrap() as i32,
                        row[1].as_i64().unwrap() as i32,
                        row[2].as_i64().unwrap() as i32,
                    ]
                })
                .collect::<Vec<_>>();
            let selected = selector(family, &[1, 1, 2], 8).unwrap();
            let angles = language_angles(&positions, &selected, 10000.0).unwrap();
            let actual = block
                .forward(&input, &angles, &mut KvCache::new())
                .unwrap()
                .to_vec_f32()
                .unwrap();
            near(&actual, &floats(&f["output"]));
            let mut cache = KvCache::new();
            let mut chunked = Vec::new();
            for (begin, end) in [(0, 2), (2, 4), (4, 5)] {
                let chunk = ops::slice(&input, &[0, begin, 0], &[1, end, 16]).unwrap();
                let angles =
                    language_angles(&positions[begin as usize..end as usize], &selected, 10000.0)
                        .unwrap();
                chunked.extend(
                    block
                        .forward(&chunk, &angles, &mut cache)
                        .unwrap()
                        .to_vec_f32()
                        .unwrap(),
                );
                assert_eq!(cache.offset(), end);
            }
            near(&chunked, &actual);
        }
    }
    fn tiny_model(family: Family) -> QwenVl {
        let dir = tempfile::tempdir().unwrap();
        let mut vocabulary = serde_json::Map::new();
        let names = [
            "<eos>",
            "<|image_pad|>",
            "<|vision_start|>",
            "<|vision_end|>",
            "<|video_pad|>",
            "[UNK]",
            "six",
            "seven",
            "tail",
            "answer",
        ];
        for id in 0..256 {
            vocabulary.insert(
                if id < names.len() {
                    names[id].to_owned()
                } else {
                    format!("token_{id}")
                },
                serde_json::json!(id),
            );
        }
        let added=names.iter().enumerate().take(5).map(|(id,name)|serde_json::json!({"id":id,"content":name,"single_word":false,"lstrip":false,"rstrip":false,"normalized":false,"special":true})).collect::<Vec<_>>();
        std::fs::write(dir.path().join("tokenizer.json"),serde_json::to_vec(&serde_json::json!({
            "version":"1.0","truncation":null,"padding":null,"added_tokens":added,"normalizer":null,
            "pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,
            "model":{"type":"WordLevel","vocab":vocabulary,"unk_token":"[UNK]"}
        })).unwrap()).unwrap();
        std::fs::write(
            dir.path().join("tokenizer_config.json"),
            br#"{"eos_token":"<eos>"}"#,
        )
        .unwrap();
        std::fs::write(
            dir.path().join("chat_template.jinja"),
            "<|vision_start|><|image_pad|><|vision_end|> tail",
        )
        .unwrap();
        let tokenizer = Tokenizer::load(dir.path()).unwrap();
        let f = fixture(if family == Family::Qwen2 {
            "qwen2_vision"
        } else {
            "qwen3_vision"
        });
        let mut w = weights(&f);
        let mut embedding = vec![0_f32; 256 * 8];
        embedding[8 * 8..9 * 8].fill(1.0);
        w.insert(
            "language_model.model.embed_tokens.weight".into(),
            Array::from_slice(&embedding, &[256, 8]),
        );
        let insert_norm = |w: &mut WeightMap, p: &str, dim: i32| {
            w.insert(
                format!("{p}.weight"),
                Array::from_slice(&vec![1_f32; dim as usize], &[dim]),
            );
        };
        let insert_linear = |w: &mut WeightMap, p: &str, input: i32, out: i32, bias: bool| {
            w.insert(
                format!("{p}.weight"),
                Array::from_slice(&vec![0_f32; (input * out) as usize], &[out, input]),
            );
            if bias {
                w.insert(
                    format!("{p}.bias"),
                    Array::from_slice(&vec![0_f32; out as usize], &[out]),
                );
            }
        };
        for i in 0..2 {
            let p = format!("language_model.model.layers.{i}");
            insert_norm(&mut w, &format!("{p}.input_layernorm"), 8);
            insert_norm(&mut w, &format!("{p}.post_attention_layernorm"), 8);
            for name in ["q_proj", "k_proj", "v_proj"] {
                insert_linear(
                    &mut w,
                    &format!("{p}.self_attn.{name}"),
                    8,
                    8,
                    family == Family::Qwen2,
                );
            }
            insert_linear(&mut w, &format!("{p}.self_attn.o_proj"), 8, 8, false);
            if family == Family::Qwen3 {
                insert_norm(&mut w, &format!("{p}.self_attn.q_norm"), 8);
                insert_norm(&mut w, &format!("{p}.self_attn.k_norm"), 8);
            }
            for name in ["gate_proj", "up_proj"] {
                insert_linear(&mut w, &format!("{p}.mlp.{name}"), 8, 16, false);
            }
            insert_linear(&mut w, &format!("{p}.mlp.down_proj"), 16, 8, false);
        }
        insert_norm(&mut w, "language_model.model.norm", 8);
        let mut head = vec![0_f32; 256 * 8];
        head[9 * 8..10 * 8].fill(1.0);
        w.insert(
            "language_model.lm_head.weight".into(),
            Array::from_slice(&head, &[256, 8]),
        );
        let mut text = serde_json::json!({"model_type":"qwen2_vl","hidden_size":8,"intermediate_size":16,"num_hidden_layers":2,"num_attention_heads":1,"num_key_value_heads":1,"head_dim":8,"vocab_size":256,"rms_norm_eps":1e-6,"max_position_embeddings":128,"rope_theta":10000.0,"rope_scaling":{"type":"default","mrope_section":[1,1,2]},"tie_word_embeddings":false,"eos_token_id":0});
        let mut cfg = if family == Family::Qwen2 {
            text.clone()
        } else {
            text["model_type"] = serde_json::json!("qwen3_vl_text");
            serde_json::json!({"model_type":"qwen3_vl","text_config":text})
        };
        cfg["vision_config"] = f["config"].clone();
        cfg["image_token_id"] = serde_json::json!(1);
        cfg["vision_start_token_id"] = serde_json::json!(2);
        cfg["vision_end_token_id"] = serde_json::json!(3);
        cfg["video_token_id"] = serde_json::json!(4);
        let processor = serde_json::json!({"patch_size":1,"merge_size":2,"temporal_patch_size":2,"size":{"shortest_edge":4,"longest_edge":16384},"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5]});
        QwenVl::load(&mut w, &cfg, &processor, tokenizer).unwrap()
    }
    fn png_fixture(width: u32, height: u32) -> Vec<u8> {
        let mut output = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(RgbImage::from_pixel(
            width,
            height,
            image::Rgb([80, 120, 160]),
        ))
        .write_to(&mut output, image::ImageFormat::Png)
        .unwrap();
        output.into_inner()
    }
    #[test]
    fn full_native_pipeline_reaches_eos_without_cross_request_state() {
        let png = png_fixture(2, 2);
        for family in [Family::Qwen2, Family::Qwen3] {
            let model = tiny_model(family);
            let messages = [ChatMessage::user_with_image("locate", png.clone())];
            assert_eq!(
                model.generate(&png, &messages, 4, &mut || true).unwrap(),
                "answer"
            );
            assert_eq!(
                model.generate(&png, &messages, 4, &mut || true).unwrap(),
                "answer"
            );
            assert!(
                model
                    .generate(&png, &messages, 1, &mut || true)
                    .unwrap_err()
                    .to_string()
                    .contains("EOS")
            );
            assert!(model.generate(&png, &messages, 4, &mut || false).is_err());
            assert!(
                model
                    .generate(
                        &png,
                        &[ChatMessage::user_with_image("<|image_pad|>", png.clone())],
                        4,
                        &mut || true
                    )
                    .is_err()
            );
            assert!(
                model
                    .generate(&png, &[ChatMessage::user("no attachment")], 4, &mut || true)
                    .is_err()
            );
            let large = png_fixture(32, 32);
            let large_messages = [ChatMessage::user_with_image("locate", large.clone())];
            assert!(
                model
                    .generate(&large, &large_messages, 4, &mut || true)
                    .unwrap_err()
                    .to_string()
                    .contains("context")
            );
        }
    }
    #[test]
    fn merge_order_and_image_normalization_match_qwen_processor() {
        let cfg = serde_json::json!({"patch_size":1,"merge_size":2,"temporal_patch_size":2,"size":{"shortest_edge":16,"longest_edge":16},"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"rescale_factor":1.0/255.0});
        let proc = ImageProcessor::load(&cfg, 1, 2, 2).unwrap();
        let rgb = RgbImage::from_fn(4, 4, |x, y| image::Rgb([(x + y * 4) as u8, 127, 255]));
        let p = proc.process(&rgb).unwrap();
        let expected = [0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15];
        for (i, byte) in expected.iter().enumerate() {
            assert_eq!(
                p.pixels[i * 3],
                ((f64::from(*byte) / 255.0) as f32 - 0.5) / 0.5
            );
            assert_eq!(p.pixels[i * 3 + 2], 1.0);
        }
    }
    #[test]
    fn smart_resize_uses_python_ties_even_and_area_bounds() {
        assert_eq!(smart_resize(70, 126, 28, 1, 12845056).unwrap(), (56, 112));
        assert_eq!(
            smart_resize(1080, 1920, 28, 3136, 12845056).unwrap(),
            (1092, 1932)
        );
        assert_eq!(smart_resize(8, 8, 32, 65536, 16777216).unwrap(), (256, 256));
        assert!(smart_resize(1, 201, 28, 3136, 12845056).is_err());
    }
    #[test]
    fn chunked_and_interleaved_mrope_preserve_model_layout() {
        let chunk = selector(Family::Qwen2, &[16, 24, 24], 128).unwrap();
        assert_eq!(&chunk[..16], vec![0; 16]);
        assert_eq!(&chunk[16..40], vec![1; 24]);
        assert_eq!(&chunk[40..], vec![2; 24]);
        let owl = selector(Family::Qwen3, &[24, 20, 20], 128).unwrap();
        assert_eq!(&owl[..6], &[0, 1, 2, 0, 1, 2]);
        assert_eq!(&owl[60..], &[0, 0, 0, 0]);
        assert!(selector(Family::Qwen2, &[16, 24, 25], 128).is_err());
    }
    #[test]
    fn compact_visual_positions_continue_from_max_axis_and_reject_extra_markers() {
        let mut ids = vec![1, 2, 10];
        ids.extend([11; 6]);
        ids.extend([12, 3, 4]);
        let p = prompt_positions(&ids, 11, 10, 12, 2, 3).unwrap();
        assert_eq!(
            p.axes[3..9],
            [
                [3, 3, 3],
                [3, 3, 4],
                [3, 3, 5],
                [3, 4, 3],
                [3, 4, 4],
                [3, 4, 5]
            ]
        );
        assert_eq!(p.axes[9..], [[6; 3], [7; 3], [8; 3]]);
        assert_eq!(p.next, 9);
        ids.push(11);
        assert!(prompt_positions(&ids, 11, 10, 12, 2, 3).is_err());
    }
    #[test]
    fn learned_positions_bilinear_interpolation_and_merge_order() {
        let table = Array::from_slice(&[0_f32, 2.0, 4.0, 6.0], &[4, 1]);
        let out = interpolate_positions(&table, 4, 4, 2)
            .unwrap()
            .to_vec_f32()
            .unwrap();
        assert!((out[0] - 0.0).abs() < 1e-6);
        assert!((out[1] - 2.0 / 3.0).abs() < 1e-6);
        assert!((out[2] - 4.0 / 3.0).abs() < 1e-6);
        assert!((out[3] - 2.0).abs() < 1e-6);
        assert!((out[15] - 6.0).abs() < 1e-6);
    }
    #[test]
    fn vision_rope_rotates_matching_height_and_width_halves() {
        let angles = vision_angles(2, 2, 2, 4).unwrap();
        let x = Array::from_slice(&[1_f32; 16], &[1, 1, 4, 4]);
        let values = rotate(&x, &angles, false).unwrap().to_vec_f32().unwrap();
        assert_eq!(&values[..4], &[1.0; 4]);
        assert!((values[5] - (1_f32.cos() - 1_f32.sin())).abs() < 1e-6);
        assert!((values[7] - (1_f32.cos() + 1_f32.sin())).abs() < 1e-6);
    }
}

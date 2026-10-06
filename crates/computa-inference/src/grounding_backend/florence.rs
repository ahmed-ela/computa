//! Florence-2/BART plus DaViT, matching the pinned GoClick MLX conversion.
//! Architecture reference: mlx-vlm's Florence2 (MIT), not a decoder-only substitute.
use super::tensor::{check_alive, required_i32, required_list, shape};
use mlex::{
    Array, Error, Result,
    models::base::{merge_heads, split_heads},
    models::cache::KvCache,
    nn::{Embedding, LayerNorm, Linear, WeightMap},
    ops::{self, AttentionMask},
};
use serde_json::Value;

struct Conv {
    weight: Array,
    bias: Option<Array>,
    stride: i32,
    padding: i32,
    groups: i32,
}
impl Conv {
    fn load(w: &mut WeightMap, path: &str, stride: i32, padding: i32, groups: i32) -> Result<Self> {
        let mut weight = w.take(&format!("{path}.weight"))?;
        let dims = weight.shape();
        if dims.len() != 4 {
            return Err(Error::Model("Florence convolution rank".into()));
        }
        // Converted MLX convolutions are OHWI. Original OIHW imports are only
        // transposed when their exact kernel/channel structure proves that layout.
        if dims[1] != dims[2] && dims[2] == dims[3] {
            weight = ops::transpose_axes(&weight, &[0, 2, 3, 1])?;
        }
        Ok(Self {
            weight,
            bias: w.take_optional(&format!("{path}.bias")),
            stride,
            padding,
            groups,
        })
    }
    fn forward(&self, x: &Array) -> Result<Array> {
        let y = ops::conv2d(
            x,
            &self.weight,
            (self.stride, self.stride),
            (self.padding, self.padding),
            (1, 1),
            self.groups,
        )?;
        match &self.bias {
            Some(b) => ops::add(&y, b),
            None => Ok(y),
        }
    }
}
struct VisionBlock {
    conv1: Option<Conv>,
    norm: LayerNorm,
    qkv: Linear,
    proj: Linear,
    conv2: Option<Conv>,
    ffn_norm: LayerNorm,
    fc1: Linear,
    fc2: Linear,
    heads: i32,
    window: i32,
    channel: bool,
}
impl VisionBlock {
    // These are the independently pinned stage dimensions and switches; keeping
    // them explicit prevents accidental cross-stage configuration reuse.
    #[allow(clippy::too_many_arguments)]
    fn load(
        w: &mut WeightMap,
        p: &str,
        dim: i32,
        heads: i32,
        window: i32,
        channel: bool,
        conv_attn: bool,
        conv_ffn: bool,
    ) -> Result<Self> {
        let name = if channel {
            "channel_attn"
        } else {
            "window_attn"
        };
        Ok(Self {
            conv1: if conv_attn {
                Some(Conv::load(w, &format!("{p}.conv1.fn.dw"), 1, 1, dim)?)
            } else {
                None
            },
            norm: w.layer_norm(&format!("{p}.{name}.norm"), 1e-5)?,
            qkv: w.linear(&format!("{p}.{name}.fn.qkv"))?,
            proj: w.linear(&format!("{p}.{name}.fn.proj"))?,
            conv2: if conv_ffn {
                Some(Conv::load(w, &format!("{p}.conv2.fn.dw"), 1, 1, dim)?)
            } else {
                None
            },
            ffn_norm: w.layer_norm(&format!("{p}.ffn.norm"), 1e-5)?,
            fc1: w.linear(&format!("{p}.ffn.fn.net.fc1"))?,
            fc2: w.linear(&format!("{p}.ffn.fn.net.fc2"))?,
            heads,
            window,
            channel,
        })
    }
    fn conv_residual(conv: &Conv, x: &Array, h: i32, w: i32) -> Result<Array> {
        let d = x.dim(2);
        let spatial = ops::reshape(x, &[1, h, w, d])?;
        ops::add(x, &ops::reshape(&conv.forward(&spatial)?, &[1, h * w, d])?)
    }
    fn forward(&self, x: &Array, h: i32, w: i32) -> Result<Array> {
        let mut x = x.clone();
        if let Some(conv) = &self.conv1 {
            x = Self::conv_residual(conv, &x, h, w)?;
        }
        let normalized = self.norm.forward(&x)?;
        let c = x.dim(2);
        let attended = if self.channel {
            let parts = ops::split(&self.qkv.forward(&normalized)?, 3, -1)?;
            let q = ops::swapaxes(&split_heads(&parts[0], 1, h * w, self.heads)?, -1, -2)?;
            let k = split_heads(&parts[1], 1, h * w, self.heads)?;
            let v = ops::swapaxes(&split_heads(&parts[2], 1, h * w, self.heads)?, -1, -2)?;
            let q = ops::scale_by(&q, ((h * w) as f32).powf(-0.5))?;
            let a = ops::softmax_axis(&ops::matmul(&q, &k)?, -1, false)?;
            let result = ops::swapaxes(&ops::matmul(&a, &v)?, -1, -2)?;
            self.proj.forward(&merge_heads(&result, 1, h * w)?)?
        } else {
            let size = self.window;
            let hp = ((h + size - 1) / size) * size;
            let wp = ((w + size - 1) / size) * size;
            let spatial = ops::reshape(&normalized, &[1, h, w, c])?;
            let padded = pad_hw(&spatial, hp, wp)?;
            let windows = partition(&padded, size)?;
            let count = windows.dim(0);
            let tokens = size * size;
            let windows = ops::reshape(&windows, &[count, tokens, c])?;
            let parts = ops::split(&self.qkv.forward(&windows)?, 3, -1)?;
            let (q, k, v) = (
                split_heads(&parts[0], count, tokens, self.heads)?,
                split_heads(&parts[1], count, tokens, self.heads)?,
                split_heads(&parts[2], count, tokens, self.heads)?,
            );
            // DaViT explicitly scales Q before matmul and softmax. Keep that
            // BF16 rounding order rather than replacing it with fused SDPA.
            let q = ops::scale_by(&q, ((c / self.heads) as f32).powf(-0.5))?;
            let weights =
                ops::softmax_axis(&ops::matmul(&q, &ops::swapaxes(&k, -1, -2)?)?, -1, false)?;
            let out = ops::matmul(&weights, &v)?;
            let out = self.proj.forward(&merge_heads(&out, count, tokens)?)?;
            let out = reverse(&ops::reshape(&out, &[count, size, size, c])?, size, hp, wp)?;
            ops::reshape(
                &ops::slice(&out, &[0, 0, 0, 0], &[1, h, w, c])?,
                &[1, h * w, c],
            )?
        };
        x = ops::add(&x, &attended)?;
        if let Some(conv) = &self.conv2 {
            x = Self::conv_residual(conv, &x, h, w)?;
        }
        let feed = self.fc2.forward(&ops::gelu_erf(
            &self.fc1.forward(&self.ffn_norm.forward(&x)?)?,
        )?)?;
        ops::add(&x, &feed)
    }
}
fn pad_hw(x: &Array, h: i32, w: i32) -> Result<Array> {
    let original = x.shape();
    let out = ops::zeros(&[original[0], h, w, original[3]], x.dtype())?;
    ops::slice_update(&out, x, &[0, 0, 0, 0], &original)
}
fn partition(x: &Array, size: i32) -> Result<Array> {
    let s = x.shape();
    let x = ops::reshape(x, &[s[0], s[1] / size, size, s[2] / size, size, s[3]])?;
    ops::reshape(
        &ops::transpose_axes(&x, &[0, 1, 3, 2, 4, 5])?,
        &[-1, size, size, s[3]],
    )
}
fn reverse(x: &Array, size: i32, h: i32, w: i32) -> Result<Array> {
    let c = x.dim(3);
    let x = ops::reshape(x, &[1, h / size, w / size, size, size, c])?;
    ops::reshape(
        &ops::transpose_axes(&x, &[0, 1, 3, 2, 4, 5])?,
        &[1, h, w, c],
    )
}
struct Stage {
    conv: Conv,
    norm: LayerNorm,
    pre_norm: bool,
    blocks: Vec<(VisionBlock, VisionBlock)>,
}
struct Davit {
    stages: Vec<Stage>,
}
impl Davit {
    fn load(w: &mut WeightMap, cfg: &Value) -> Result<Self> {
        let dims = required_list(cfg, "dim_embed", 1, 8192)?;
        let depths = required_list(cfg, "depths", 1, 64)?;
        let heads = required_list(cfg, "num_heads", 1, 128)?;
        let groups = required_list(cfg, "num_groups", 1, 128)?;
        let stride = required_list(cfg, "patch_stride", 1, 32)?;
        let padding = required_list(cfg, "patch_padding", 0, 32)?;
        let prenorm = cfg["patch_prenorm"]
            .as_array()
            .ok_or_else(|| Error::Config("patch_prenorm".into()))?;
        if [
            depths.len(),
            heads.len(),
            groups.len(),
            stride.len(),
            padding.len(),
            prenorm.len(),
        ]
        .iter()
        .any(|n| *n != dims.len())
        {
            return Err(Error::Config("DaViT stages disagree".into()));
        }
        let window = required_i32(cfg, "window_size", 1, 64)?;
        let mut stages = Vec::new();
        for i in 0..dims.len() {
            if dims[i] % heads[i] != 0 || dims[i] % groups[i] != 0 {
                return Err(Error::Config("DaViT head/group dimension".into()));
            }
            let p = format!("vision_tower.convs.{i}");
            let mut blocks = Vec::new();
            for j in 0..depths[i] {
                let p = format!("vision_tower.blocks.{i}.{j}");
                let ca = cfg["conv_at_attn"].as_bool().unwrap_or(true);
                let cf = cfg["conv_at_ffn"].as_bool().unwrap_or(true);
                blocks.push((
                    VisionBlock::load(
                        w,
                        &format!("{p}.spatial_block"),
                        dims[i],
                        heads[i],
                        window,
                        false,
                        ca,
                        cf,
                    )?,
                    VisionBlock::load(
                        w,
                        &format!("{p}.channel_block"),
                        dims[i],
                        groups[i],
                        window,
                        true,
                        ca,
                        cf,
                    )?,
                ));
            }
            stages.push(Stage {
                conv: Conv::load(w, &format!("{p}.proj"), stride[i], padding[i], 1)?,
                norm: w.layer_norm(&format!("{p}.norm"), 1e-5)?,
                pre_norm: prenorm[i]
                    .as_bool()
                    .ok_or_else(|| Error::Config("patch_prenorm".into()))?,
                blocks,
            });
        }
        Ok(Self { stages })
    }
    fn forward(&self, pixels: &Array, alive: &mut impl FnMut() -> bool) -> Result<Array> {
        shape(pixels, 4)?;
        let mut x = ops::transpose_axes(pixels, &[0, 2, 3, 1])?;
        let mut h = pixels.dim(2);
        let mut w = pixels.dim(3);
        for (i, stage) in self.stages.iter().enumerate() {
            check_alive(alive)?;
            if i > 0 {
                if stage.pre_norm {
                    x = stage.norm.forward(&x)?;
                }
                x = ops::reshape(&x, &[1, h, w, x.dim(2)])?;
            }
            x = stage.conv.forward(&x)?;
            h = x.dim(1);
            w = x.dim(2);
            x = ops::reshape(&x, &[1, h * w, x.dim(3)])?;
            if !stage.pre_norm {
                x = stage.norm.forward(&x)?;
            }
            for (spatial, channel) in &stage.blocks {
                check_alive(alive)?;
                x = spatial.forward(&x, h, w)?;
                x = channel.forward(&x, h, w)?;
                x.eval()?;
            }
        }
        Ok(x)
    }
}
struct Attention {
    q: Linear,
    k: Linear,
    v: Linear,
    out: Linear,
    heads: i32,
}
impl Attention {
    fn load(w: &mut WeightMap, p: &str, heads: i32) -> Result<Self> {
        Ok(Self {
            q: w.linear(&format!("{p}.q_proj"))?,
            k: w.linear(&format!("{p}.k_proj"))?,
            v: w.linear(&format!("{p}.v_proj"))?,
            out: w.linear(&format!("{p}.out_proj"))?,
            heads,
        })
    }
    fn forward(
        &self,
        x: &Array,
        source: Option<&Array>,
        cache: Option<&mut KvCache>,
        cross_cache: Option<&mut Option<(Array, Array)>>,
        causal: bool,
    ) -> Result<Array> {
        let b = x.dim(0);
        let n = x.dim(1);
        let q = split_heads(&self.q.forward(x)?, b, n, self.heads)?;
        let (k, v) = if let Some(source) = source {
            if let Some(cached) = cross_cache {
                if let Some((k, v)) = cached {
                    (k.clone(), v.clone())
                } else {
                    let pair = (
                        split_heads(&self.k.forward(source)?, b, source.dim(1), self.heads)?,
                        split_heads(&self.v.forward(source)?, b, source.dim(1), self.heads)?,
                    );
                    *cached = Some(pair.clone());
                    pair
                }
            } else {
                (
                    split_heads(&self.k.forward(source)?, b, source.dim(1), self.heads)?,
                    split_heads(&self.v.forward(source)?, b, source.dim(1), self.heads)?,
                )
            }
        } else {
            let k = split_heads(&self.k.forward(x)?, b, n, self.heads)?;
            let v = split_heads(&self.v.forward(x)?, b, n, self.heads)?;
            match cache {
                Some(c) => c.update_and_fetch(k, v)?,
                None => (k, v),
            }
        };
        let mask = if causal && n > 1 {
            AttentionMask::Causal
        } else {
            AttentionMask::None
        };
        let result =
            ops::scaled_dot_product_attention(&q, &k, &v, (q.dim(3) as f32).powf(-0.5), mask)?;
        self.out.forward(&merge_heads(&result, b, n)?)
    }
}
struct EncoderLayer {
    attention: Attention,
    norm: LayerNorm,
    fc1: Linear,
    fc2: Linear,
    final_norm: LayerNorm,
}
impl EncoderLayer {
    fn load(w: &mut WeightMap, p: &str, heads: i32) -> Result<Self> {
        Ok(Self {
            attention: Attention::load(w, &format!("{p}.self_attn"), heads)?,
            norm: w.layer_norm(&format!("{p}.self_attn_layer_norm"), 1e-5)?,
            fc1: w.linear(&format!("{p}.fc1"))?,
            fc2: w.linear(&format!("{p}.fc2"))?,
            final_norm: w.layer_norm(&format!("{p}.final_layer_norm"), 1e-5)?,
        })
    }
    fn forward(&self, x: &Array) -> Result<Array> {
        let x = self.norm.forward(&ops::add(
            x,
            &self.attention.forward(x, None, None, None, false)?,
        )?)?;
        self.final_norm.forward(&ops::add(
            &x,
            &self.fc2.forward(&ops::gelu_erf(&self.fc1.forward(&x)?)?)?,
        )?)
    }
}
struct DecoderLayer {
    attention: Attention,
    norm: LayerNorm,
    cross: Attention,
    cross_norm: LayerNorm,
    fc1: Linear,
    fc2: Linear,
    final_norm: LayerNorm,
}
impl DecoderLayer {
    fn load(w: &mut WeightMap, p: &str, heads: i32) -> Result<Self> {
        Ok(Self {
            attention: Attention::load(w, &format!("{p}.self_attn"), heads)?,
            norm: w.layer_norm(&format!("{p}.self_attn_layer_norm"), 1e-5)?,
            cross: Attention::load(w, &format!("{p}.encoder_attn"), heads)?,
            cross_norm: w.layer_norm(&format!("{p}.encoder_attn_layer_norm"), 1e-5)?,
            fc1: w.linear(&format!("{p}.fc1"))?,
            fc2: w.linear(&format!("{p}.fc2"))?,
            final_norm: w.layer_norm(&format!("{p}.final_layer_norm"), 1e-5)?,
        })
    }
    fn forward(&self, x: &Array, encoder: &Array, cache: &mut DecoderCache) -> Result<Array> {
        let x = self.norm.forward(&ops::add(
            x,
            &self
                .attention
                .forward(x, None, Some(&mut cache.own), None, true)?,
        )?)?;
        let x = self.cross_norm.forward(&ops::add(
            &x,
            &self
                .cross
                .forward(&x, Some(encoder), None, Some(&mut cache.cross), false)?,
        )?)?;
        self.final_norm.forward(&ops::add(
            &x,
            &self.fc2.forward(&ops::gelu_erf(&self.fc1.forward(&x)?)?)?,
        )?)
    }
}
struct DecoderCache {
    own: KvCache,
    cross: Option<(Array, Array)>,
}
pub(super) struct Florence {
    vision: Davit,
    row: Embedding,
    column: Embedding,
    projection: Array,
    projection_norm: LayerNorm,
    feature_sources: Vec<String>,
    shared: Embedding,
    head: Option<Linear>,
    encoder_pos: Embedding,
    encoder_norm: LayerNorm,
    encoder_layers: Vec<EncoderLayer>,
    decoder_pos: Embedding,
    decoder_norm: LayerNorm,
    decoder_layers: Vec<DecoderLayer>,
    max_positions: i32,
    decoder_start: u32,
    eos: u32,
    bos: u32,
    scale: f32,
}
impl Florence {
    pub(super) fn load(w: &mut WeightMap, cfg: &Value) -> Result<Self> {
        if cfg["model_type"] != "florence2" {
            return Err(Error::Config("GoClick requires Florence2".into()));
        }
        let text = &cfg["text_config"];
        let dim = required_i32(text, "d_model", 16, 8192)?;
        let enc_heads = required_i32(text, "encoder_attention_heads", 1, 128)?;
        let dec_heads = required_i32(text, "decoder_attention_heads", 1, 128)?;
        if dim % enc_heads != 0
            || dim % dec_heads != 0
            || text["activation_function"]
                .as_str()
                .is_some_and(|s| s != "gelu")
            || cfg["image_pos_embed"]["type"]
                .as_str()
                .is_some_and(|s| s != "learned_abs_2d")
            || cfg["visual_temporal_embedding"]["type"]
                .as_str()
                .is_some_and(|s| s != "COSINE")
        {
            return Err(Error::Config(
                "Florence position/activation contract".into(),
            ));
        }
        let default_sources = serde_json::json!(["temporal_avg_pool", "spatial_avg_pool"]);
        let sources = cfg
            .get("image_feature_source")
            .unwrap_or(&default_sources)
            .as_array()
            .ok_or_else(|| Error::Config("image_feature_source".into()))?
            .iter()
            .map(|s| {
                s.as_str()
                    .filter(|s| {
                        matches!(*s, "temporal_avg_pool" | "spatial_avg_pool" | "last_frame")
                    })
                    .map(str::to_owned)
                    .ok_or_else(|| Error::Config("image_feature_source".into()))
            })
            .collect::<Result<Vec<_>>>()?;
        let mut enc = Vec::new();
        for i in 0..required_i32(text, "encoder_layers", 1, 64)? {
            enc.push(EncoderLayer::load(
                w,
                &format!("language_model.model.encoder.layers.{i}"),
                enc_heads,
            )?);
        }
        let mut dec = Vec::new();
        for i in 0..required_i32(text, "decoder_layers", 1, 64)? {
            dec.push(DecoderLayer::load(
                w,
                &format!("language_model.model.decoder.layers.{i}"),
                dec_heads,
            )?);
        }
        // The pin's sanitizer drops final_logits_bias and uses a tied lm_head
        // only when that separate head was omitted by the checkpoint.
        let head = if w.contains("language_model.lm_head.weight") {
            Some(w.linear("language_model.lm_head")?)
        } else {
            None
        };
        let bos = text["bos_token_id"].as_u64().unwrap_or(0) as u32;
        let eos = text["eos_token_id"].as_u64().unwrap_or(2) as u32;
        Ok(Self {
            vision: Davit::load(w, &cfg["vision_config"])?,
            row: w.embedding("image_pos_embed.row_embeddings")?,
            column: w.embedding("image_pos_embed.column_embeddings")?,
            projection: w.take("image_projection")?,
            projection_norm: w.layer_norm("image_proj_norm", 1e-5)?,
            feature_sources: sources,
            shared: w.embedding("language_model.model.shared")?,
            head,
            encoder_pos: w.embedding("language_model.model.encoder.embed_positions")?,
            encoder_norm: w.layer_norm("language_model.model.encoder.layernorm_embedding", 1e-5)?,
            encoder_layers: enc,
            decoder_pos: w.embedding("language_model.model.decoder.embed_positions")?,
            decoder_norm: w.layer_norm("language_model.model.decoder.layernorm_embedding", 1e-5)?,
            decoder_layers: dec,
            max_positions: required_i32(text, "max_position_embeddings", 16, 16384)?,
            decoder_start: text["decoder_start_token_id"].as_u64().unwrap_or(2) as u32,
            bos,
            eos,
            scale: if text["scale_embedding"] == true {
                (dim as f32).sqrt()
            } else {
                1.0
            },
        })
    }
    pub(super) fn generate(
        &self,
        pixels: &Array,
        tokens: &[u32],
        alive: &mut impl FnMut() -> bool,
    ) -> Result<Vec<u32>> {
        check_alive(alive)?;
        let features = self.vision.forward(pixels, alive)?;
        let dim = features.dim(2);
        let n = features.dim(1);
        let side = (n as f64).sqrt() as i32;
        if side * side != n {
            return Err(Error::Model("Florence features must be square".into()));
        }
        let ids: Vec<i32> = (0..side).collect();
        let rows = self.row.forward(&Array::from_slice(&ids, &[side]))?;
        let cols = self.column.forward(&Array::from_slice(&ids, &[side]))?;
        let rows = ops::broadcast_to(
            &ops::reshape(&rows, &[side, 1, -1])?,
            &[side, side, rows.dim(1)],
        )?;
        let cols = ops::broadcast_to(
            &ops::reshape(&cols, &[1, side, -1])?,
            &[side, side, cols.dim(1)],
        )?;
        let pos = ops::reshape(&ops::concatenate(&[&cols, &rows], -1)?, &[1, n, dim])?;
        // T=1 cosine temporal embedding is [sin(0),cos(0)] interleaved.
        let temporal: Vec<f32> = (0..dim)
            .map(|i| if i % 2 == 0 { 0.0 } else { 1.0 })
            .collect();
        let features = ops::add(
            &ops::add(&features, &pos)?,
            &ops::astype(
                &Array::from_slice(&temporal, &[1, 1, dim]),
                features.dtype(),
            )?,
        )?;
        let pooled = ops::mean_axes(&features, &[1], true)?;
        let selected: Vec<&Array> = self
            .feature_sources
            .iter()
            .map(|s| {
                if s == "spatial_avg_pool" {
                    &pooled
                } else {
                    &features
                }
            })
            .collect();
        let image = self.projection_norm.forward(&ops::matmul(
            &ops::concatenate(&selected, 1)?,
            &self.projection,
        )?)?;
        let mut prompt = vec![self.bos];
        prompt.extend_from_slice(tokens);
        prompt.push(self.eos);
        let prompt = Array::from_slice(&prompt, &[1, prompt.len() as i32]);
        let text = self.shared.forward(&prompt)?;
        let mut encoder = ops::scale_by(&ops::concatenate(&[&image, &text], 1)?, self.scale)?;
        let total = encoder.dim(1);
        if total > self.max_positions {
            return Err(Error::Model("Florence encoder context".into()));
        }
        let positions: Vec<i32> = (2..total + 2).collect();
        encoder = self.encoder_norm.forward(&ops::add(
            &encoder,
            &self
                .encoder_pos
                .forward(&Array::from_slice(&positions, &[1, total]))?,
        )?)?;
        for layer in &self.encoder_layers {
            check_alive(alive)?;
            encoder = layer.forward(&encoder)?;
            encoder.eval()?;
        }
        let mut caches: Vec<_> = self
            .decoder_layers
            .iter()
            .map(|_| DecoderCache {
                own: KvCache::new(),
                cross: None,
            })
            .collect();
        let mut input = self.decoder_start;
        let mut result = Vec::new();
        for step in 0..32 {
            check_alive(alive)?;
            let embed = self.shared.forward(&Array::from_slice(&[input], &[1, 1]))?;
            let pos = self
                .decoder_pos
                .forward(&Array::from_slice(&[step + 2], &[1, 1]))?;
            let mut x = self.decoder_norm.forward(&ops::add(&embed, &pos)?)?;
            for (layer, cache) in self.decoder_layers.iter().zip(caches.iter_mut()) {
                check_alive(alive)?;
                x = layer.forward(&x, &encoder, cache)?;
            }
            let logits = match &self.head {
                Some(head) => head.forward(&x)?,
                None => self.shared.as_linear(&x)?,
            };
            input = ops::argmax_axis(&logits, -1, false)?.item_u32()?;
            result.push(input);
            if input == self.eos {
                return Ok(result);
            }
        }
        Err(Error::Model(
            "GoClick output reached its 32-token limit without EOS".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mlex::{Dtype, quant::Quantization};
    use serde_json::json;
    use std::collections::HashMap;
    fn reference_array(value: &Value) -> Array {
        let shape: Vec<i32> = value["shape"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap() as i32)
            .collect();
        let values: Vec<f32> = value["values"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_f64().unwrap() as f32)
            .collect();
        Array::from_slice(&values, &shape)
    }
    fn reference_weights(value: &Value) -> WeightMap {
        let weights = value["weights"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, record)| (format!("layer.{name}"), reference_array(record)))
            .collect();
        WeightMap::new(weights, Quantization::default())
    }
    fn assert_reference(actual: &Array, expected: &Value) {
        let expected = reference_array(expected);
        assert_eq!(actual.shape(), expected.shape());
        let actual = ops::contiguous(actual).unwrap().to_vec_f32().unwrap();
        let expected = expected.to_vec_f32().unwrap();
        let difference = actual
            .iter()
            .zip(&expected)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        assert!(
            difference < 0.00002,
            "Florence upstream numerical difference {difference}"
        );
    }
    #[test]
    fn davit_attention_and_bart_cached_layers_match_upstream_numerical_fixtures() {
        // Frozen, synthetic mlx-vlm outputs. Tests and production require no
        // Python import or network; publisher source hashes live in the fixture.
        let fixtures: Value = serde_json::from_str(include_str!("florence-fixtures.json")).unwrap();
        for (name, channel) in [("spatial", false), ("channel", true)] {
            let fixture = &fixtures["cases"][name];
            let mut weights = reference_weights(fixture);
            let block =
                VisionBlock::load(&mut weights, "layer", 4, 2, 2, channel, true, true).unwrap();
            assert_reference(
                &block
                    .forward(&reference_array(&fixture["input"]), 3, 5)
                    .unwrap(),
                &fixture["output"],
            );
            assert_eq!(weights.keys().count(), 0);
        }
        let fixture = &fixtures["cases"]["encoder"];
        let mut weights = reference_weights(fixture);
        let layer = EncoderLayer::load(&mut weights, "layer", 2).unwrap();
        assert_reference(
            &layer.forward(&reference_array(&fixture["input"])).unwrap(),
            &fixture["output"],
        );
        assert_eq!(weights.keys().count(), 0);
        let fixture = &fixtures["cases"]["decoder"];
        let mut weights = reference_weights(fixture);
        let layer = DecoderLayer::load(&mut weights, "layer", 2).unwrap();
        let input = reference_array(&fixture["input"]);
        let encoder = reference_array(&fixture["encoder"]);
        let mut cache = DecoderCache {
            own: KvCache::new(),
            cross: None,
        };
        let mut outputs = Vec::new();
        for index in 0..2 {
            let token = ops::slice(&input, &[0, index, 0], &[1, index + 1, 4]).unwrap();
            outputs.push(layer.forward(&token, &encoder, &mut cache).unwrap());
        }
        let output_refs: Vec<_> = outputs.iter().collect();
        assert_reference(
            &ops::concatenate(&output_refs, 1).unwrap(),
            &fixture["output"],
        );
        assert_eq!(weights.keys().count(), 0);
    }
    fn tensor(t: &mut HashMap<String, Array>, name: &str, dims: &[i32], value: f32) {
        t.insert(
            name.into(),
            ops::full_f32(dims, value, Dtype::Float32).unwrap(),
        );
    }
    fn norm(t: &mut HashMap<String, Array>, p: &str, d: i32, bias: f32) {
        tensor(t, &format!("{p}.weight"), &[d], 1.0);
        tensor(t, &format!("{p}.bias"), &[d], bias);
    }
    fn linear(t: &mut HashMap<String, Array>, p: &str, input: i32, output: i32) {
        tensor(t, &format!("{p}.weight"), &[output, input], 0.0);
        tensor(t, &format!("{p}.bias"), &[output], 0.0);
    }
    fn attention(t: &mut HashMap<String, Array>, p: &str, d: i32) {
        for key in ["q_proj", "k_proj", "v_proj", "out_proj"] {
            linear(t, &format!("{p}.{key}"), d, d)
        }
    }
    fn fixture() -> (Value, WeightMap) {
        let d = 16;
        let cfg = json!({"model_type":"florence2","vision_config":{"dim_embed":[16],"depths":[1],"num_heads":[2],"num_groups":[2],"patch_stride":[2],"patch_padding":[1],"patch_prenorm":[false],"window_size":2},"text_config":{"d_model":16,"encoder_attention_heads":2,"decoder_attention_heads":2,"encoder_layers":1,"decoder_layers":1,"max_position_embeddings":32}});
        let mut t = HashMap::new();
        tensor(
            &mut t,
            "vision_tower.convs.0.proj.weight",
            &[d, 3, 3, 3],
            0.05,
        );
        tensor(&mut t, "vision_tower.convs.0.proj.bias", &[d], 0.0);
        norm(&mut t, "vision_tower.convs.0.norm", d, 0.0);
        for (kind, attn) in [
            ("spatial_block", "window_attn"),
            ("channel_block", "channel_attn"),
        ] {
            let p = format!("vision_tower.blocks.0.0.{kind}");
            for conv in ["conv1", "conv2"] {
                tensor(
                    &mut t,
                    &format!("{p}.{conv}.fn.dw.weight"),
                    &[d, 3, 3, 1],
                    0.1,
                );
                tensor(&mut t, &format!("{p}.{conv}.fn.dw.bias"), &[d], 0.0);
            }
            norm(&mut t, &format!("{p}.{attn}.norm"), d, 0.0);
            linear(&mut t, &format!("{p}.{attn}.fn.qkv"), d, d * 3);
            linear(&mut t, &format!("{p}.{attn}.fn.proj"), d, d);
            norm(&mut t, &format!("{p}.ffn.norm"), d, 0.0);
            linear(&mut t, &format!("{p}.ffn.fn.net.fc1"), d, d * 4);
            linear(&mut t, &format!("{p}.ffn.fn.net.fc2"), d * 4, d);
        }
        tensor(
            &mut t,
            "image_pos_embed.row_embeddings.weight",
            &[8, 8],
            0.0,
        );
        tensor(
            &mut t,
            "image_pos_embed.column_embeddings.weight",
            &[8, 8],
            0.0,
        );
        tensor(&mut t, "image_projection", &[d, d], 0.1);
        norm(&mut t, "image_proj_norm", d, 0.0);
        tensor(&mut t, "language_model.model.shared.weight", &[32, d], 0.0);
        tensor(&mut t, "language_model.lm_head.weight", &[32, d], 0.0);
        tensor(&mut t, "language_model.lm_head.bias", &[32], 0.0);
        t.insert(
            "language_model.lm_head.bias".into(),
            Array::from_slice(
                &(0..32)
                    .map(|i| if i == 2 { 1.0 } else { 0.0 })
                    .collect::<Vec<f32>>(),
                &[32],
            ),
        );
        for part in ["encoder", "decoder"] {
            let p = format!("language_model.model.{part}");
            tensor(
                &mut t,
                &format!("{p}.embed_positions.weight"),
                &[34, d],
                0.0,
            );
            norm(&mut t, &format!("{p}.layernorm_embedding"), d, 0.0);
            let p = format!("{p}.layers.0");
            attention(&mut t, &format!("{p}.self_attn"), d);
            norm(&mut t, &format!("{p}.self_attn_layer_norm"), d, 0.0);
            linear(&mut t, &format!("{p}.fc1"), d, d * 4);
            linear(&mut t, &format!("{p}.fc2"), d * 4, d);
            norm(&mut t, &format!("{p}.final_layer_norm"), d, 0.0);
            if part == "decoder" {
                attention(&mut t, &format!("{p}.encoder_attn"), d);
                norm(&mut t, &format!("{p}.encoder_attn_layer_norm"), d, 0.0);
            }
        }
        (cfg, WeightMap::new(t, Quantization::default()))
    }
    #[test]
    fn synthetic_florence_runs_davit_encoder_cross_attention_and_eos() {
        let (cfg, mut weights) = fixture();
        let model = Florence::load(&mut weights, &cfg).unwrap();
        let pixels = ops::full_f32(&[1, 3, 4, 4], 0.5, Dtype::Float32).unwrap();
        assert_eq!(
            model.generate(&pixels, &[3, 4], &mut || true).unwrap(),
            vec![2]
        );
        assert!(model.generate(&pixels, &[3, 4], &mut || false).is_err());
        assert_eq!(weights.keys().count(), 0);
    }
    #[test]
    fn spatial_windows_preserve_exact_order_and_padding() {
        let values: Vec<f32> = (0..15).map(|n| n as f32).collect();
        let x = Array::from_slice(&values, &[1, 3, 5, 1]);
        let padded = pad_hw(&x, 4, 6).unwrap();
        let windows = partition(&padded, 2).unwrap();
        assert_eq!(windows.shape(), vec![6, 2, 2, 1]);
        let reconstructed = reverse(&windows, 2, 4, 6).unwrap();
        assert_eq!(
            ops::contiguous(&ops::slice(&reconstructed, &[0, 0, 0, 0], &[1, 3, 5, 1]).unwrap())
                .unwrap()
                .to_vec_f32()
                .unwrap(),
            values
        );
    }
}

//! Deterministic native conversion of the two exact pinned raw grounding models.
//! The format has independent artifact pins; it never claims legacy byte hashes.
use super::conversion::{florence_processor_config, sanitize_florence};
use mlex::{Array, Dtype, Error, Result, ops, ops::QuantMode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{Read, Write},
    path::Path,
};
pub const FORMAT_VERSION: &str = "computa-mlx-affine-v1";
pub const SOURCE_MANIFEST: &[u8] = include_bytes!("source-manifest.json");
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactPin {
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TensorPin {
    pub dtype: String,
    pub shape: Vec<i32>,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConversionReport {
    pub schema_version: u32,
    pub converter: String,
    pub source_manifest_sha256: String,
    pub model: String,
    pub files: BTreeMap<String, ArtifactPin>,
    pub tensors: BTreeMap<String, TensorPin>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Sources {
    schema_version: u32,
    models: BTreeMap<String, Source>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    schema_version: u32,
    repo: String,
    revision: String,
    total_bytes: u64,
    files: Vec<SourceFile>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceFile {
    path: String,
    size: u64,
    sha256: Option<String>,
    #[serde(rename = "gitBlobSHA1")]
    git_blob_sha1: Option<String>,
}
fn err(message: impl std::fmt::Display) -> Error {
    Error::Model(format!("Native grounding conversion: {message}"))
}
fn io<T>(value: std::io::Result<T>) -> Result<T> {
    value.map_err(err)
}
fn alive(check: &mut impl FnMut() -> bool) -> Result<()> {
    if check() {
        Ok(())
    } else {
        Err(err("cancelled"))
    }
}
fn open(path: &Path) -> Result<fs::File> {
    let file = io(fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path))?;
    let metadata = io(file.metadata())?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err(err("expected a nonlinked regular source file"));
    }
    Ok(file)
}
fn unchanged(before: &fs::Metadata, after: &fs::Metadata) -> bool {
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}
fn hash(path: &Path, check: &mut impl FnMut() -> bool) -> Result<ArtifactPin> {
    let mut file = open(path)?;
    let metadata = io(file.metadata())?;
    let mut sha = Sha256::new();
    let mut buf = [0u8; 1024 * 1024];
    let mut bytes = 0u64;
    loop {
        alive(check)?;
        let n = io(file.read(&mut buf))?;
        if n == 0 {
            break;
        }
        bytes = bytes
            .checked_add(n as u64)
            .ok_or_else(|| err("size overflow"))?;
        if bytes > metadata.len() {
            return Err(err("source changed while hashing"));
        }
        sha.update(&buf[..n]);
    }
    if bytes != metadata.len() || !unchanged(&metadata, &io(file.metadata())?) {
        return Err(err("source changed while hashing"));
    }
    Ok(ArtifactPin {
        bytes,
        sha256: hex::encode(sha.finalize()),
    })
}
fn verify_source(
    directory: &Path,
    source: &Source,
    check: &mut impl FnMut() -> bool,
) -> Result<()> {
    if source.schema_version != 1
        || source.revision.len() != 40
        || source.repo.is_empty()
        || source.files.iter().map(|f| f.size).sum::<u64>() != source.total_bytes
    {
        return Err(err("compiled source pin differs"));
    }
    let names = io(fs::read_dir(directory))?
        .map(|entry| entry.map(|e| e.file_name().to_string_lossy().into_owned()))
        .collect::<std::io::Result<std::collections::BTreeSet<_>>>()
        .map_err(err)?;
    if names != source.files.iter().map(|p| p.path.clone()).collect() {
        return Err(err("source file list differs"));
    }
    for pin in &source.files {
        alive(check)?;
        if Path::new(&pin.path).components().count() != 1 || pin.path.contains(['\\', '\0']) {
            return Err(err("source path"));
        }
        let path = directory.join(&pin.path);
        let observed = hash(&path, check)?;
        if observed.bytes != pin.size {
            return Err(err("source byte pin differs"));
        }
        match (&pin.sha256, &pin.git_blob_sha1) {
            (Some(expected), None) if expected == &observed.sha256 => {}
            (None, Some(expected)) => {
                let mut file = open(&path)?;
                let metadata = io(file.metadata())?;
                let mut sha = sha1::Sha1::new();
                sha.update(format!("blob {}\0", pin.size).as_bytes());
                let mut buffer = [0u8; 64 * 1024];
                loop {
                    alive(check)?;
                    let n = io(file.read(&mut buffer))?;
                    if n == 0 {
                        break;
                    }
                    sha.update(&buffer[..n]);
                }
                if !unchanged(&metadata, &io(file.metadata())?)
                    || hex::encode(sha.finalize()) != *expected
                {
                    return Err(err("source Git-blob pin differs"));
                }
            }
            _ => return Err(err("source digest pin differs")),
        }
    }
    Ok(())
}
fn json_file(path: &Path) -> Result<Value> {
    let mut file = open(path)?;
    let mut bytes = Vec::new();
    io((&mut file)
        .take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes))?;
    if bytes.len() > 16 * 1024 * 1024 {
        return Err(err("metadata exceeds bound"));
    }
    computa_contracts::strict_json::parse(&bytes).map_err(err)
}
fn new_file(path: &Path) -> Result<fs::File> {
    io(fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path))
}
fn save_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut output = new_file(path)?;
    let bytes = serde_json::to_vec_pretty(value).map_err(err)?;
    io(output.write_all(&bytes))?;
    io(output.write_all(b"\n"))?;
    io(output.sync_all())
}
fn qwen3_sanitize(weights: HashMap<String, Array>, cfg: &Value) -> Result<HashMap<String, Array>> {
    let vision = &cfg["vision_config"];
    let number = |key: &str| {
        vision[key]
            .as_i64()
            .and_then(|n| i32::try_from(n).ok())
            .filter(|n| *n > 0)
            .ok_or_else(|| err("vision dimensions"))
    };
    let (dim, channels, temporal, patch) = (
        number("hidden_size")?,
        number("in_channels")?,
        number("temporal_patch_size")?,
        number("patch_size")?,
    );
    let tied = cfg["text_config"]["tie_word_embeddings"]
        .as_bool()
        .unwrap_or(false);
    let mut output = HashMap::new();
    for (name, tensor) in weights {
        if name.contains("position_ids") {
            continue;
        }
        let name = if let Some(tail) = name.strip_prefix("model.visual.") {
            format!("vision_tower.{tail}")
        } else if let Some(tail) = name.strip_prefix("model.language_model.") {
            format!("language_model.model.{tail}")
        } else if let Some(tail) = name.strip_prefix("lm_head.") {
            format!("language_model.lm_head.{tail}")
        } else {
            name
        };
        if tied && name == "language_model.lm_head.weight" {
            continue;
        }
        let tensor = if name == "vision_tower.patch_embed.proj.weight" {
            if tensor.shape() != [dim, channels, temporal, patch, patch] {
                return Err(err("original Qwen3 vision convolution dimensions"));
            }
            ops::contiguous(&ops::transpose_axes(&tensor, &[0, 2, 3, 4, 1])?)?
        } else {
            tensor
        };
        if output.insert(name, tensor).is_some() {
            return Err(err("ambiguous canonical tensor name"));
        }
    }
    Ok(output)
}
fn multimodal(name: &str) -> bool {
    [
        "vision_model",
        "vision_tower",
        "vl_connector",
        "sam_model",
        "audio_model",
        "audio_tower",
        "code_predictor",
        "img_projector",
        "multi_modal_projector",
        "patch_merge_mlp",
    ]
    .iter()
    .any(|part| name.contains(part))
}
/// Same eligible Linear/Embedding modules as mlx-vlm0.7.1's default affine
/// converter; raw parameters, norms and convolution kernels stay BF16.
fn quantize(
    weights: HashMap<String, Array>,
    check: &mut impl FnMut() -> bool,
) -> Result<BTreeMap<String, Array>> {
    let mut output = BTreeMap::new();
    let ordered: BTreeMap<_, _> = weights.into_iter().collect();
    for (name, value) in ordered {
        alive(check)?;
        if !matches!(
            value.dtype(),
            Dtype::Float16 | Dtype::Float32 | Dtype::BFloat16
        ) {
            return Err(err("unexpected raw tensor dtype"));
        }
        let value = ops::astype(&value, Dtype::BFloat16)?;
        if name.ends_with(".weight")
            && value.ndim() == 2
            && value.dim(1) % 64 == 0
            && !multimodal(&name)
        {
            let prefix = name.strip_suffix(".weight").unwrap();
            let (packed, scales, biases) = ops::quantize(&value, 64, 4, QuantMode::Affine)?;
            packed.eval()?;
            scales.eval()?;
            output.insert(format!("{prefix}.scales"), scales);
            output.insert(
                format!("{prefix}.biases"),
                biases.ok_or_else(|| err("affine quantization biases absent"))?,
            );
            output.insert(name, packed);
        } else {
            value.eval()?;
            output.insert(name, value);
        }
    }
    Ok(output)
}
const FLORENCE_PREFIX: [&str; 4] = ["<image>", "</od>", "<ocr>", "</ocr>"];
const FLORENCE_SUFFIX: [&str; 20] = [
    "<cap>",
    "</cap>",
    "<ncap>",
    "</ncap>",
    "<dcap>",
    "</dcap>",
    "<grounding>",
    "</grounding>",
    "<seg>",
    "</seg>",
    "<sep>",
    "<region_cap>",
    "</region_cap>",
    "<region_to_desciption>",
    "</region_to_desciption>",
    "<proposal>",
    "</proposal>",
    "<poly>",
    "</poly>",
    "<and>",
];
/// The pinned raw BART vocabulary lacks the processor's trained location
/// tokens. Match Florence's original bootstrap IDs and AddedToken flags. The
/// final image placeholder51289 is processor-only and never fed to embeddings.
fn florence_tokenizer(mut tokenizer: Value) -> Result<Value> {
    let vocab = tokenizer["model"]["vocab"]
        .as_object()
        .ok_or_else(|| err("Florence tokenizer vocabulary"))?;
    let mut next = vocab
        .values()
        .map(|v| v.as_u64().ok_or_else(|| err("Florence tokenizer ID")))
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .max()
        .and_then(|v| v.checked_add(1))
        .ok_or_else(|| err("Florence tokenizer extent"))?;
    if next != 50265 {
        return Err(err("Florence tokenizer base vocabulary"));
    }
    let existing = tokenizer["added_tokens"]
        .as_array()
        .ok_or_else(|| err("Florence tokenizer added tokens"))?;
    if existing.len() != 5
        || existing
            .iter()
            .any(|t| t["id"].as_u64().is_none_or(|id| id >= next))
    {
        return Err(err("Florence raw special tokens"));
    }
    let mut tokens = FLORENCE_PREFIX
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    tokens.extend((0..1000).map(|i| format!("<loc_{i}>")));
    tokens.extend(FLORENCE_SUFFIX.iter().map(|s| s.to_string()));
    tokens.push("<florence_image>".into());
    if tokens
        .iter()
        .any(|t| vocab.contains_key(t) || existing.iter().any(|a| a["content"].as_str() == Some(t)))
    {
        return Err(err("Florence duplicate token"));
    }
    let added = tokenizer["added_tokens"].as_array_mut().unwrap();
    for token in tokens {
        added.push(json!({"id":next,"content":token,"single_word":false,"lstrip":false,"rstrip":false,"normalized":false,"special":true}));
        next += 1;
    }
    if next != 51290 {
        return Err(err("Florence trained token extent"));
    }
    Ok(tokenizer)
}
fn florence_tokenizer_config(mut config: Value) -> Result<Value> {
    let object = config
        .as_object_mut()
        .ok_or_else(|| err("Florence tokenizer configuration"))?;
    for (name, value) in [
        ("bos_token", "<s>"),
        ("eos_token", "</s>"),
        ("pad_token", "<pad>"),
        ("unk_token", "<unk>"),
        ("mask_token", "<mask>"),
    ] {
        object.insert(name.into(), Value::String(value.into()));
    }
    Ok(config)
}
fn tensor_type(tensor: &Array) -> Result<(&'static str, u64)> {
    match tensor.dtype() {
        Dtype::BFloat16 => Ok(("BF16", 2)),
        Dtype::UInt32 => Ok(("U32", 4)),
        _ => Err(err("converted tensor dtype")),
    }
}
/// Sorted header and little-endian contiguous logical tensor data. Chunked
/// extraction preserves BF16 bits and avoids retaining an extra model-sized Vec.
fn save_weights(
    path: &Path,
    weights: &BTreeMap<String, Array>,
    check: &mut impl FnMut() -> bool,
) -> Result<BTreeMap<String, TensorPin>> {
    let mut header = BTreeMap::<String, Value>::new();
    header.insert(
        "__metadata__".into(),
        json!({"format":"mlx","computa_conversion":FORMAT_VERSION}),
    );
    let mut offset = 0u64;
    for (name, value) in weights {
        if name == "__metadata__" || name.is_empty() {
            return Err(err("invalid tensor name"));
        }
        let (dtype, width) = tensor_type(value)?;
        let size = (value.size() as u64)
            .checked_mul(width)
            .ok_or_else(|| err("tensor size overflow"))?;
        let end = offset
            .checked_add(size)
            .ok_or_else(|| err("weight size overflow"))?;
        header.insert(
            name.clone(),
            json!({"dtype":dtype,"shape":value.shape(),"data_offsets":[offset,end]}),
        );
        offset = end;
    }
    let mut bytes = serde_json::to_vec(&header).map_err(err)?;
    let padding = (8 - bytes.len() % 8) % 8;
    bytes.extend(std::iter::repeat_n(b' ', padding));
    let mut file = new_file(path)?;
    io(file.write_all(&(bytes.len() as u64).to_le_bytes()))?;
    io(file.write_all(&bytes))?;
    let mut records = BTreeMap::new();
    for (name, value) in weights {
        alive(check)?;
        let (dtype, width) = tensor_type(value)?;
        let flat = ops::reshape(value, &[-1])?;
        let mut hash = Sha256::new();
        let total = value.size();
        if total > i32::MAX as usize {
            return Err(err("tensor exceeds native indexing bound"));
        }
        for start in (0..total).step_by(262144) {
            alive(check)?;
            let end = (start + 262144).min(total);
            let slice = ops::contiguous(&ops::slice(&flat, &[start as i32], &[end as i32])?)?;
            let mut data = Vec::with_capacity((end - start) * width as usize);
            match value.dtype() {
                Dtype::BFloat16 => {
                    for n in slice.to_vec_f32()? {
                        if !n.is_finite() {
                            return Err(err("nonfinite converted weight"));
                        }
                        data.extend_from_slice(&((n.to_bits() >> 16) as u16).to_le_bytes());
                    }
                }
                Dtype::UInt32 => {
                    for n in slice.to_vec_u32()? {
                        data.extend_from_slice(&n.to_le_bytes());
                    }
                }
                _ => return Err(err("converted dtype")),
            }
            hash.update(&data);
            io(file.write_all(&data))?;
        }
        records.insert(
            name.clone(),
            TensorPin {
                dtype: dtype.into(),
                shape: value.shape(),
                bytes: total as u64 * width,
                sha256: hex::encode(hash.finalize()),
            },
        );
    }
    io(file.sync_all())?;
    Ok(records)
}
/// Input is reverified against the compiled closed original source pins. Output
/// must be a fresh private directory selected only by the native installer.
pub fn convert(
    model: &str,
    source: &Path,
    destination: &Path,
    mut check: impl FnMut() -> bool,
) -> Result<ConversionReport> {
    if !matches!(model, "goclick-base-4bit" | "gui-owl-2b") {
        return Err(err("only exact raw GoClick/Owl conversion is supported"));
    }
    if !source.is_absolute() || !destination.is_absolute() || destination.exists() {
        return Err(err("expected absolute source and fresh output"));
    }
    let sources: Sources = serde_json::from_value(
        computa_contracts::strict_json::parse(SOURCE_MANIFEST).map_err(err)?,
    )
    .map_err(err)?;
    if sources.schema_version != 1 {
        return Err(err("source schema"));
    }
    let source_pin = sources
        .models
        .get(model)
        .ok_or_else(|| err("source model pin"))?;
    verify_source(source, source_pin, &mut check)?;
    alive(&mut check)?;
    let mut cfg = json_file(&source.join("config.json"))?;
    let mut weights = HashMap::new();
    mlex::weights::load_file(&source.join("model.safetensors"), &mut weights)?;
    let weights = if model == "goclick-base-4bit" {
        sanitize_florence(weights)?
    } else {
        qwen3_sanitize(weights, &cfg)?
    };
    let weights = quantize(weights, &mut check)?;
    io(fs::create_dir(destination))?;
    io(fs::set_permissions(
        destination,
        fs::Permissions::from_mode(0o700),
    ))?;
    let tensors = save_weights(&destination.join("model.safetensors"), &weights, &mut check)?;
    let total = tensors.values().map(|t| t.bytes).sum::<u64>();
    save_json(
        &destination.join("model.safetensors.index.json"),
        &json!({"metadata":{"total_size":total},"weight_map":tensors.keys().map(|k|(k.clone(),"model.safetensors")).collect::<BTreeMap<_,_>>()}),
    )?;
    let object = cfg.as_object_mut().ok_or_else(|| err("config object"))?;
    object.remove("_name_or_path");
    object.remove("torch_dtype");
    let quant = json!({"group_size":64,"bits":4,"mode":"affine"});
    object.insert("quantization".into(), quant.clone());
    object.insert("quantization_config".into(), quant);
    save_json(&destination.join("config.json"), &cfg)?;
    for pin in &source_pin.files {
        alive(&mut check)?;
        if matches!(
            pin.path.as_str(),
            "config.json" | "model.safetensors" | "model.safetensors.index.json"
        ) {
            continue;
        }
        if model == "goclick-base-4bit" && pin.path == "tokenizer.json" {
            save_json(
                &destination.join(&pin.path),
                &florence_tokenizer(json_file(&source.join(&pin.path))?)?,
            )?;
        } else if model == "goclick-base-4bit" && pin.path == "tokenizer_config.json" {
            save_json(
                &destination.join(&pin.path),
                &florence_tokenizer_config(json_file(&source.join(&pin.path))?)?,
            )?;
        } else if model == "goclick-base-4bit" && pin.path == "preprocessor_config.json" {
            save_json(
                &destination.join(&pin.path),
                &florence_processor_config(json_file(&source.join(&pin.path))?)?,
            )?;
        } else {
            let mut input = open(&source.join(&pin.path))?;
            let mut output = new_file(&destination.join(&pin.path))?;
            io(std::io::copy(&mut input, &mut output))?;
            io(output.sync_all())?;
        }
    }
    let mut files = BTreeMap::new();
    for entry in io(fs::read_dir(destination))? {
        let entry = io(entry)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| err("non-UTF8 output path"))?;
        files.insert(name, hash(&entry.path(), &mut check)?);
    }
    let report = ConversionReport {
        schema_version: 1,
        converter: FORMAT_VERSION.into(),
        source_manifest_sha256: hex::encode(Sha256::digest(SOURCE_MANIFEST)),
        model: model.into(),
        files,
        tensors,
    };
    save_json(&destination.join("native-conversion.json"), &report)?;
    io(fs::File::open(destination)?.sync_all())?;
    Ok(report)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn florence_processor_token_ids_flags_and_location_extent_match_upstream() {
        let fixture: Value =
            serde_json::from_str(include_str!("florence-tokenizer-fixture.json")).unwrap();
        let original = json!({"model":{"vocab":{"<s>":0,"<pad>":1,"</s>":2,"<unk>":3,"<mask>":50264}},"added_tokens":fixture["added_tokens"].as_array().unwrap()[..5]});
        let converted = florence_tokenizer(original).unwrap();
        let added = converted["added_tokens"].as_array().unwrap();
        assert_eq!(converted["added_tokens"], fixture["added_tokens"]);
        assert_eq!(added.len(), 1030);
        for (id, text) in [
            (50265, "<image>"),
            (50266, "</od>"),
            (50269, "<loc_0>"),
            (51268, "<loc_999>"),
            (51269, "<cap>"),
            (51288, "<and>"),
            (51289, "<florence_image>"),
        ] {
            let token = added.iter().find(|t| t["id"] == id).unwrap();
            assert_eq!(token["content"], text);
            assert_eq!(token["special"], true);
            assert_eq!(token["normalized"], false);
        }
        assert!(florence_tokenizer(converted).is_err());
    }
    #[test]
    fn native_affine_quantization_matches_frozen_upstream_packed_bits_scales_and_biases() {
        let fixture: Value = serde_json::from_str(include_str!("quant-fixtures.json")).unwrap();
        assert_eq!(fixture["mlx_version"], "0.32.2");
        let values: Vec<f32> = (0..256)
            .map(|i| ((i * 17 % 97) as f32 - 48.0) / 16.0)
            .collect();
        let source = ops::astype(&Array::from_slice(&values, &[2, 128]), Dtype::BFloat16).unwrap();
        let (packed, scales, biases) = ops::quantize(&source, 64, 4, QuantMode::Affine).unwrap();
        let expected = |key: &str| {
            fixture[key]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_u64().unwrap() as u32)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            ops::contiguous(&packed).unwrap().to_vec_u32().unwrap(),
            expected("packed")
        );
        for (array, key) in [
            (scales, "scales_bf16_bits"),
            (biases.unwrap(), "biases_bf16_bits"),
        ] {
            assert_eq!(array.dtype(), Dtype::BFloat16);
            let bits = ops::contiguous(&array)
                .unwrap()
                .to_vec_f32()
                .unwrap()
                .into_iter()
                .map(|n| n.to_bits() >> 16)
                .collect::<Vec<_>>();
            assert_eq!(bits, expected(key));
        }
    }
    #[test]
    fn deterministic_tensor_data_roundtrips_bf16_quantized_embedding_and_raw_vision() {
        let values: Vec<f32> = (0..256)
            .map(|i| ((i * 17 % 97) as f32 - 48.0) / 16.0)
            .collect();
        let quantized = quantize(
            HashMap::from([
                (
                    "language_model.model.embed_tokens.weight".into(),
                    Array::from_slice(&values, &[2, 128]),
                ),
                (
                    "vision_tower.proj.weight".into(),
                    Array::from_slice(&values, &[2, 128]),
                ),
                (
                    "image_projection".into(),
                    Array::from_slice(
                        &[f32::from_bits(0x38000100), f32::from_bits(0xc0490fdb)],
                        &[1, 2],
                    ),
                ),
            ]),
            &mut || true,
        )
        .unwrap();
        assert_eq!(
            quantized["language_model.model.embed_tokens.weight"].dtype(),
            Dtype::UInt32
        );
        assert_eq!(
            quantized["vision_tower.proj.weight"].dtype(),
            Dtype::BFloat16
        );
        assert_eq!(quantized["image_projection"].dtype(), Dtype::BFloat16);
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a.safetensors");
        let b = dir.path().join("b.safetensors");
        let pins = save_weights(&a, &quantized, &mut || true).unwrap();
        save_weights(&b, &quantized, &mut || true).unwrap();
        assert_eq!(fs::read(&a).unwrap(), fs::read(&b).unwrap());
        let mut loaded = HashMap::new();
        mlex::weights::load_file(&a, &mut loaded).unwrap();
        assert_eq!(loaded.len(), quantized.len());
        for (index, (name, value)) in quantized.into_iter().enumerate() {
            assert_eq!(loaded[&name].shape(), value.shape());
            assert_eq!(loaded[&name].dtype(), value.dtype());
            let observed = save_weights(
                &dir.path().join(format!("tensor-{index}.safetensors")),
                &BTreeMap::from([(name.clone(), loaded.remove(&name).unwrap())]),
                &mut || true,
            )
            .unwrap();
            assert_eq!(observed[&name], pins[&name]);
        }
        assert!(
            save_weights(
                &dir.path().join("cancel.safetensors"),
                &BTreeMap::from([(
                    "x".into(),
                    ops::astype(&Array::from_slice(&[1.0f32], &[1]), Dtype::BFloat16).unwrap()
                )]),
                &mut || false
            )
            .is_err()
        );
    }
}

use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::models::{LocalModel, ModelId};
use serde_json::Value;
use std::{
    collections::HashMap,
    io::Cursor,
    path::{Path, PathBuf},
};

pub const MAX_BODY: usize = 32 * 1024 * 1024;
pub const MAX_IMAGE: usize = 10 * 1024 * 1024;
pub const MAX_IMAGE_PIXELS: u64 = 16_777_216;
pub const CONTEXT_LIMIT: usize = 16384;
pub const MAX_OUTPUT: usize = 4096;

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum RequestError {
    #[error("Select an installed supported local model.")]
    Model,
    #[error("Full-history streaming requests with store=false are required.")]
    Stateful,
    #[error("Unsupported inference option.")]
    Option,
    #[error("Invalid local inference request.")]
    Invalid,
    #[error("Screenshot budget, encoding, or format is invalid.")]
    Image,
    #[error("Only text and inline screenshots are supported.")]
    Media,
    #[error("Input nesting or request size limit exceeded.")]
    Limit,
}
#[derive(Clone, Debug)]
pub struct Request {
    pub model: LocalModel,
    pub raw: Value,
    pub max_output_tokens: usize,
    pub thinking_budget: usize,
}
pub fn parse(data: &[u8], models: &HashMap<LocalModel, PathBuf>) -> Result<Request, RequestError> {
    if data.len() > MAX_BODY {
        return Err(RequestError::Limit);
    }
    let raw = computa_contracts::strict_json::parse(data).map_err(|_| RequestError::Invalid)?;
    let object = raw.as_object().ok_or(RequestError::Invalid)?;
    let model = match object
        .get("model")
        .and_then(Value::as_str)
        .and_then(|id| ModelId::parse(id).ok())
    {
        Some(ModelId::Local(model))
            if model.supports_headless_mlx() && models.contains_key(&model) =>
        {
            model
        }
        _ => return Err(RequestError::Model),
    };
    if raw["store"] != false
        || raw["stream"] != true
        || object
            .get("previous_response_id")
            .is_some_and(|v| !v.is_null() && v != "")
    {
        return Err(RequestError::Stateful);
    }
    for key in [
        "adapter_path",
        "adapters",
        "draft_model",
        "trust_remote_code",
        "messages",
        "audio",
        "video",
        "images",
        "max_tokens",
        "tool_parser",
        "thinking_start_token",
        "thinking_end_token",
    ] {
        if object.contains_key(key) {
            return Err(RequestError::Option);
        }
    }
    let max_output_tokens = object
        .get("max_output_tokens")
        .map_or(Ok(MAX_OUTPUT), |v| {
            v.as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .filter(|n| (1..=MAX_OUTPUT).contains(n))
                .ok_or(RequestError::Option)
        })?;
    let thinking_budget = object.get("thinking_budget").map_or(Ok(512), |v| {
        v.as_u64()
            .and_then(|n| usize::try_from(n).ok())
            .filter(|n| (1..=512).contains(n))
            .ok_or(RequestError::Option)
    })?;
    let input = object
        .get("input")
        .filter(|v| v.is_string() || v.is_array())
        .ok_or(RequestError::Invalid)?;
    let mut count = 0;
    let mut bytes = 0;
    let mut stack = vec![(input, 0)];
    while let Some((item, depth)) = stack.pop() {
        if depth > 64 {
            return Err(RequestError::Limit);
        }
        match item {
            Value::Array(items) => stack.extend(items.iter().map(|i| (i, depth + 1))),
            Value::Object(object) => {
                match object.get("type").and_then(Value::as_str) {
                    Some(
                        "input_audio" | "input_video" | "input_file" | "file" | "audio_url"
                        | "video_url",
                    ) => return Err(RequestError::Media),
                    Some("input_image" | "image_url") => {
                        let source = object
                            .get("image_url")
                            .and_then(|v| v.as_str().or_else(|| v.get("url")?.as_str()))
                            .ok_or(RequestError::Image)?;
                        let image = decode_image(source)?;
                        count += 1;
                        bytes += image.len();
                        if count > 8 || bytes > 16 * 1024 * 1024 {
                            return Err(RequestError::Image);
                        }
                    }
                    _ => {}
                }
                stack.extend(
                    object
                        .values()
                        .filter(|v| v.is_array() || v.is_object())
                        .map(|v| (v, depth + 1)),
                );
            }
            _ => {}
        }
    }
    Ok(Request {
        model,
        raw,
        max_output_tokens,
        thinking_budget,
    })
}
pub fn decode_image(source: &str) -> Result<Vec<u8>, RequestError> {
    if source.len() > MAX_IMAGE * 4 / 3 + 128 {
        return Err(RequestError::Image);
    }
    let (prefix, payload) = source.split_once(',').ok_or(RequestError::Image)?;
    let format = match prefix {
        "data:image/png;base64" => image::ImageFormat::Png,
        "data:image/jpeg;base64" => image::ImageFormat::Jpeg,
        _ => return Err(RequestError::Image),
    };
    let bytes = STANDARD.decode(payload).map_err(|_| RequestError::Image)?;
    if bytes.len() > MAX_IMAGE {
        return Err(RequestError::Image);
    }
    let dimensions = image::ImageReader::with_format(Cursor::new(&bytes), format)
        .into_dimensions()
        .map_err(|_| RequestError::Image)?;
    if dimensions.0 == 0
        || dimensions.1 == 0
        || u64::from(dimensions.0) * u64::from(dimensions.1) > MAX_IMAGE_PIXELS
    {
        return Err(RequestError::Image);
    }
    let mut reader = image::ImageReader::with_format(Cursor::new(&bytes), format);
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(64 * 1024 * 1024);
    limits.max_image_width = Some(dimensions.0);
    limits.max_image_height = Some(dimensions.1);
    reader.limits(limits);
    reader.decode().map_err(|_| RequestError::Image)?;
    Ok(bytes)
}
pub fn discover_models(root: &Path, fallback: Option<&Path>) -> HashMap<LocalModel, PathBuf> {
    let mut result = HashMap::new();
    for model in [LocalModel::Qwen35_4b, LocalModel::Qwen35_9b] {
        for root in [Some(root), fallback].into_iter().flatten() {
            let path = root.join(model.model_id());
            if path.join("config.json").is_file()
                && let Ok(path) = path.canonicalize()
            {
                result.insert(model, path);
                break;
            }
        }
    }
    result
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct ContextBudget {
    pub input_tokens: usize,
    pub max_output_tokens: usize,
    pub context_limit: usize,
    pub required_tokens: usize,
    pub available_input_tokens: usize,
}
pub fn context_budget(input: usize, output: usize) -> Option<ContextBudget> {
    if !(1..=MAX_OUTPUT).contains(&output) {
        return None;
    }
    let required = input.checked_add(output)?;
    (required > CONTEXT_LIMIT).then_some(ContextBudget {
        input_tokens: input,
        max_output_tokens: output,
        context_limit: CONTEXT_LIMIT,
        required_tokens: required,
        available_input_tokens: CONTEXT_LIMIT - output,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn models() -> HashMap<LocalModel, PathBuf> {
        HashMap::from([(LocalModel::Qwen35_4b, PathBuf::from("/local"))])
    }
    fn request() -> Value {
        json!({"model":LocalModel::Qwen35_4b.model_id(),"store":false,"stream":true,"input":"hello"})
    }
    #[test]
    fn request_cannot_enable_remote_code_downloads_or_cross_model_state() {
        for key in [
            "trust_remote_code",
            "adapter_path",
            "draft_model",
            "messages",
        ] {
            let mut r = request();
            r[key] = Value::Null;
            assert_eq!(
                parse(r.to_string().as_bytes(), &models()).unwrap_err(),
                RequestError::Option
            );
        }
        for (key, value) in [
            ("model", json!("browser/claude")),
            ("store", json!(true)),
            ("stream", json!(false)),
            ("max_output_tokens", json!(true)),
            ("thinking_budget", json!(513)),
        ] {
            let mut r = request();
            r[key] = value;
            assert!(parse(r.to_string().as_bytes(), &models()).is_err());
        }
    }
    #[test]
    fn nested_tool_result_media_is_validated() {
        for source in [
            "https://example.test/a.png",
            "file:///private/a",
            "data:image/png;base64,AAA=",
        ] {
            let mut r = request();
            r["input"] = json!([{"type":"function_call_output","call_id":"a","output":[{"type":"input_image","image_url":source}]}]);
            assert_eq!(
                parse(r.to_string().as_bytes(), &models()).unwrap_err(),
                RequestError::Image
            );
        }
    }
    #[test]
    fn four_k_capture_preserves_original_pixels_without_resizing() {
        let image = image::RgbImage::from_pixel(3840, 2160, image::Rgb([23, 42, 97]));
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let source = format!("data:image/png;base64,{}", STANDARD.encode(png.get_ref()));
        assert_eq!(decode_image(&source).unwrap(), png.into_inner());
    }
    #[test]
    fn owned_and_legacy_catalog_weights_coexist_without_downloads() {
        let temp = tempfile::tempdir().unwrap();
        let owned = temp.path().join("owned");
        let legacy = temp.path().join("legacy");
        for (root, model) in [
            (&owned, LocalModel::Qwen35_4b),
            (&legacy, LocalModel::Qwen35_4b),
            (&legacy, LocalModel::Qwen35_9b),
        ] {
            let path = root.join(model.model_id());
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(path.join("config.json"), b"{}").unwrap();
        }
        let found = discover_models(&owned, Some(&legacy));
        assert_eq!(found.len(), 2);
        assert!(found[&LocalModel::Qwen35_4b].starts_with(owned.canonicalize().unwrap()));
        assert!(found[&LocalModel::Qwen35_9b].starts_with(legacy.canonicalize().unwrap()));
    }
    #[test]
    fn context_evidence_is_numeric_and_bound_to_actual_token_allowance() {
        assert!(context_budget(12288, 4096).is_none());
        assert_eq!(context_budget(12289, 4096).unwrap().required_tokens, 16385);
        assert!(context_budget(20000, 4097).is_none());
    }
}

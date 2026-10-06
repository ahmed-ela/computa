//! Private, bounded stdio protocol for the app-owned visual model worker.
//! Requests carry pixels, never paths, executable names or model selections.
use serde::{Deserialize, Deserializer, Serialize, de::DeserializeOwned};
use std::collections::BTreeMap;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;
pub const METHOD_VERSION: &str = "goclick-guiowl-showui-agreement-v2";
pub const WARMUP_TARGET: &str = "Click the Search projects field.";
pub const MAX_PNG_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_BASE64_BYTES: usize = MAX_PNG_BYTES.div_ceil(3) * 4;
pub const MAX_REQUEST_FRAME: usize = 16 * 1024 * 1024;
pub const MAX_RESPONSE_FRAME: usize = 16 * 1024;
pub const MAX_PIXELS: u64 = 16_777_216;

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
#[error("The grounding worker returned invalid or unrelated evidence.")]
pub struct WireError;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Sha256(String);
impl Sha256 {
    pub fn new(value: String) -> Result<Self, WireError> {
        if value.len() != 64
            || !value
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(WireError);
        }
        Ok(Self(value))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl<'de> Deserialize<'de> for Sha256 {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(de)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub enum ModelName {
    #[serde(rename = "goclick-base-4bit")]
    GoClick,
    #[serde(rename = "gui-owl-2b")]
    GuiOwl,
    #[serde(rename = "showui-2b-4bit")]
    ShowUi,
}
impl ModelName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::GoClick => "goclick-base-4bit",
            Self::GuiOwl => "gui-owl-2b",
            Self::ShowUi => "showui-2b-4bit",
        }
    }
}
pub const MODELS: [ModelName; 3] = [ModelName::GoClick, ModelName::GuiOwl, ModelName::ShowUi];

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureBinding {
    pub instance: Uuid,
    pub request_id: Uuid,
    pub generation: Uuid,
    pub capture_id: Uuid,
    pub png_sha256: Sha256,
    pub target_sha256: Sha256,
    pub width: u32,
    pub height: u32,
}
impl CaptureBinding {
    pub fn validate(&self) -> Result<(), WireError> {
        if [
            self.instance,
            self.request_id,
            self.generation,
            self.capture_id,
        ]
        .iter()
        .any(Uuid::is_nil)
            || self.width == 0
            || self.height == 0
            || self.width > 8192
            || self.height > 8192
            || u64::from(self.width) * u64::from(self.height) > MAX_PIXELS
        {
            return Err(WireError);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Ground {
        binding: CaptureBinding,
        png_base64: String,
        target: String,
    },
    /// Closed benchmark warmup; it returns no coordinates and accepts no target
    /// or model choices. Native desktop inference sends only Ground requests.
    Warmup {
        binding: CaptureBinding,
        png_base64: String,
    },
    Shutdown {
        instance: Uuid,
    },
}
impl Request {
    pub fn validate(&self) -> Result<(), WireError> {
        match self {
            Self::Warmup {
                binding,
                png_base64,
            } => {
                binding.validate()?;
                if png_base64.is_empty()
                    || png_base64.len() > MAX_BASE64_BYTES
                    || !png_base64
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
                {
                    return Err(WireError);
                }
                Ok(())
            }
            Self::Ground {
                binding,
                png_base64,
                target,
            } => {
                binding.validate()?;
                if png_base64.is_empty()
                    || png_base64.len() > MAX_BASE64_BYTES
                    || !png_base64
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
                    || target.is_empty()
                    || target.trim() != target
                    || target.len() > 4096
                    || target.chars().count() > 512
                    || target.chars().any(char::is_control)
                {
                    return Err(WireError);
                }
                Ok(())
            }
            Self::Shutdown { instance } => {
                if instance.is_nil() {
                    Err(WireError)
                } else {
                    Ok(())
                }
            }
        }
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PixelPoint {
    pub x: f64,
    pub y: f64,
}
impl PixelPoint {
    fn valid(self, binding: &CaptureBinding) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.x >= 0.0
            && self.y >= 0.0
            && self.x < f64::from(binding.width)
            && self.y < f64::from(binding.height)
    }
    fn distance(self, other: Self) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GroundingResult {
    pub point: PixelPoint,
    pub used_showui: bool,
    pub selected_pair: [ModelName; 2],
    pub initial_distance_normalized_diagonal: Option<f64>,
    pub selected_distance_normalized_diagonal: f64,
    pub model_points: BTreeMap<ModelName, Option<PixelPoint>>,
    pub model_seconds: BTreeMap<ModelName, f64>,
    pub elapsed_seconds: f64,
}
impl GroundingResult {
    /// Recompute the frozen cascade; the worker cannot choose a convenient pair,
    /// skip its fallback, substitute a model or return a fabricated midpoint.
    pub fn validate(&self, binding: &CaptureBinding) -> Result<(), WireError> {
        binding.validate()?;
        if self.model_points.keys().copied().collect::<Vec<_>>() != MODELS
            || !self.point.valid(binding)
            || self
                .model_points
                .values()
                .flatten()
                .any(|p| !p.valid(binding))
            || !self.elapsed_seconds.is_finite()
            || !(0.0..=60.0).contains(&self.elapsed_seconds)
            || self
                .model_seconds
                .values()
                .any(|s| !s.is_finite() || *s < 0.0 || *s > self.elapsed_seconds)
        {
            return Err(WireError);
        }
        let diagonal = f64::from(binding.width).hypot(f64::from(binding.height));
        let go = self.model_points[&ModelName::GoClick];
        let owl = self.model_points[&ModelName::GuiOwl];
        let show = self.model_points[&ModelName::ShowUi];
        let initial_pixels = go.zip(owl).map(|(a, b)| a.distance(b));
        let initial = initial_pixels.map(|distance| distance / diagonal);
        let used_showui = initial_pixels.is_none_or(|distance| distance > 0.03 * diagonal);
        let expected_times = if used_showui {
            MODELS.to_vec()
        } else {
            MODELS[..2].to_vec()
        };
        if self.used_showui != used_showui
            || (!used_showui && show.is_some())
            || self.model_seconds.keys().copied().collect::<Vec<_>>() != expected_times
            || !same_optional(initial, self.initial_distance_normalized_diagonal)
        {
            return Err(WireError);
        }
        let points: Vec<_> = MODELS
            .into_iter()
            .filter_map(|name| self.model_points[&name].map(|point| (name, point)))
            .collect();
        if points.len() < 2 {
            return Err(WireError);
        }
        let mut pair = (points[0], points[1]);
        let mut distance = pair.0.1.distance(pair.1.1);
        if used_showui {
            for a in 0..points.len() {
                for b in a + 1..points.len() {
                    let candidate = points[a].1.distance(points[b].1);
                    if candidate < distance {
                        pair = (points[a], points[b]);
                        distance = candidate;
                    }
                }
            }
        }
        let midpoint = PixelPoint {
            x: (pair.0.1.x + pair.1.1.x) / 2.0,
            y: (pair.0.1.y + pair.1.1.y) / 2.0,
        };
        if distance > 0.03 * diagonal
            || self.selected_pair != [pair.0.0, pair.1.0]
            || !near(
                distance / diagonal,
                self.selected_distance_normalized_diagonal,
            )
            || midpoint.distance(self.point) > 1e-9
        {
            return Err(WireError);
        }
        Ok(())
    }
}
fn near(a: f64, b: f64) -> bool {
    a.is_finite() && b.is_finite() && (a - b).abs() <= 1e-12
}
fn same_optional(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => near(a, b),
        _ => false,
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusalCode {
    MissingModels,
    Installation,
    InvalidImage,
    InvalidTarget,
    InvalidRequest,
    Processor,
    Cancelled,
    Model,
    NoAgreement,
    Platform,
}
impl RefusalCode {
    pub fn message(self) -> &'static str {
        match self {
            Self::MissingModels => {
                "The three pinned visual grounding models are not installed. No model was downloaded."
            }
            Self::Installation => "The pinned visual grounding installation could not be verified.",
            Self::InvalidImage => {
                "The visual worker rejected the screenshot's pixels or dimensions."
            }
            Self::InvalidTarget => "The visual worker rejected the bounded target description.",
            Self::InvalidRequest => "The visual worker rejected an invalid or repeated request.",
            Self::Processor => "The pinned visual processor is unsupported.",
            Self::Cancelled => "Visual grounding was cancelled or exceeded its deadline.",
            Self::Model => "A visual model failed; no coordinate was authorized.",
            Self::NoAgreement => "The visual models did not agree; no coordinate was authorized.",
            Self::Platform => "Native visual inference requires Apple Silicon macOS.",
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum Response {
    Ready {
        protocol_version: u32,
        method_version: String,
        instance: Uuid,
        parent_pid: u32,
        model_names: [ModelName; 3],
    },
    Grounded {
        binding: CaptureBinding,
        result: GroundingResult,
    },
    Warmed {
        binding: CaptureBinding,
        elapsed_seconds: f64,
    },
    /// A complete frozen cascade refused the point. This contains timing only,
    /// never coordinates, raw model output, or action authority.
    Unagreed {
        binding: CaptureBinding,
        elapsed_seconds: f64,
    },
    Refused {
        instance: Uuid,
        binding: Option<CaptureBinding>,
        code: RefusalCode,
    },
    Stopped {
        instance: Uuid,
    },
}
pub fn decode<T: DeserializeOwned>(bytes: &[u8], maximum: usize) -> Result<T, WireError> {
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(WireError);
    }
    serde_json::from_value(crate::strict_json::parse(bytes).map_err(|_| WireError)?)
        .map_err(|_| WireError)
}
pub fn encode<T: Serialize>(value: &T, maximum: usize) -> Result<Vec<u8>, WireError> {
    let bytes = serde_json::to_vec(value).map_err(|_| WireError)?;
    if bytes.is_empty() || bytes.len() > maximum {
        Err(WireError)
    } else {
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn benchmark_warmup_is_closed_and_returns_no_coordinate_authority() {
        let (binding, _) = fixture();
        let request = Request::Warmup {
            binding: binding.clone(),
            png_base64: "AAAA".into(),
        };
        request.validate().unwrap();
        let mut value = serde_json::to_value(request).unwrap();
        value["target"] = serde_json::json!("arbitrary target");
        assert!(
            decode::<Request>(&serde_json::to_vec(&value).unwrap(), MAX_REQUEST_FRAME).is_err()
        );
        let mut response = serde_json::to_value(Response::Warmed {
            binding,
            elapsed_seconds: 1.0,
        })
        .unwrap();
        response["point"] = serde_json::json!({"x":10,"y":10});
        assert!(
            decode::<Response>(&serde_json::to_vec(&response).unwrap(), MAX_RESPONSE_FRAME)
                .is_err()
        );
    }
    fn fixture() -> (CaptureBinding, GroundingResult) {
        (
            CaptureBinding {
                instance: Uuid::new_v4(),
                request_id: Uuid::new_v4(),
                generation: Uuid::new_v4(),
                capture_id: Uuid::new_v4(),
                png_sha256: Sha256::new("a".repeat(64)).unwrap(),
                target_sha256: Sha256::new("b".repeat(64)).unwrap(),
                width: 100,
                height: 100,
            },
            GroundingResult {
                point: PixelPoint { x: 11.0, y: 10.0 },
                used_showui: false,
                selected_pair: [ModelName::GoClick, ModelName::GuiOwl],
                initial_distance_normalized_diagonal: Some(2.0 / 100.0f64.hypot(100.0)),
                selected_distance_normalized_diagonal: 2.0 / 100.0f64.hypot(100.0),
                model_points: BTreeMap::from([
                    (ModelName::GoClick, Some(PixelPoint { x: 10.0, y: 10.0 })),
                    (ModelName::GuiOwl, Some(PixelPoint { x: 12.0, y: 10.0 })),
                    (ModelName::ShowUi, None),
                ]),
                model_seconds: BTreeMap::from([
                    (ModelName::GoClick, 0.1),
                    (ModelName::GuiOwl, 0.2),
                ]),
                elapsed_seconds: 0.4,
            },
        )
    }
    #[test]
    fn authority_rejects_repeated_unknown_fields_paths_and_wrong_hash_types() {
        assert!(decode::<Request>(br#"{"operation":"shutdown","instance":"00000000-0000-0000-0000-000000000001","instance":"00000000-0000-0000-0000-000000000002"}"#,MAX_REQUEST_FRAME).is_err());
        assert!(decode::<Request>(br#"{"operation":"shutdown","instance":"00000000-0000-0000-0000-000000000001","model_path":"/tmp/other"}"#,MAX_REQUEST_FRAME).is_err());
        assert!(serde_json::from_str::<Sha256>("true").is_err());
        assert!(Sha256::new("A".repeat(64)).is_err());
        assert!(
            decode::<Response>(&vec![b' '; MAX_RESPONSE_FRAME + 1], MAX_RESPONSE_FRAME).is_err()
        );
    }
    #[test]
    fn agreement_requires_exact_frozen_midpoint_cascade_and_model_names() {
        let (binding, mut result) = fixture();
        assert!(result.validate(&binding).is_ok());
        result.point.x += 0.01;
        assert!(result.validate(&binding).is_err());
        result.point.x -= 0.01;
        result
            .model_points
            .insert(ModelName::ShowUi, Some(PixelPoint { x: 11.0, y: 10.0 }));
        assert!(result.validate(&binding).is_err());
        result
            .model_points
            .insert(ModelName::GuiOwl, Some(PixelPoint { x: 90.0, y: 90.0 }));
        result.used_showui = true;
        result.selected_pair = [ModelName::GoClick, ModelName::ShowUi];
        result.point = PixelPoint { x: 10.5, y: 10.0 };
        result.initial_distance_normalized_diagonal =
            Some(80.0f64.hypot(80.0) / 100.0f64.hypot(100.0));
        result.selected_distance_normalized_diagonal = 1.0 / 100.0f64.hypot(100.0);
        result.model_seconds.insert(ModelName::ShowUi, 0.05);
        assert!(result.validate(&binding).is_ok());
        result.selected_pair = [ModelName::GuiOwl, ModelName::ShowUi];
        assert!(result.validate(&binding).is_err());
    }
    #[test]
    fn captures_and_targets_are_bounded_without_pixel_rescaling() {
        let (mut binding, _) = fixture();
        binding.width = 3840;
        binding.height = 2160;
        assert!(binding.validate().is_ok());
        let req = Request::Ground {
            binding: binding.clone(),
            png_base64: "AA==".into(),
            target: "Click button".into(),
        };
        assert!(req.validate().is_ok());
        binding.width = 8192;
        binding.height = 8192;
        assert!(binding.validate().is_err());
        if let Request::Ground {
            binding: _,
            png_base64: _,
            mut target,
        } = req
        {
            target.push('\0');
            let req = Request::Ground {
                binding,
                png_base64: "AA==".into(),
                target,
            };
            assert!(req.validate().is_err());
        }
    }
}

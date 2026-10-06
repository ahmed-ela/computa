//! Explicit synthetic/recorded experiments over an owned Rust Responses worker.
//! Function calls in responses are retained as data and never dispatched.
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};
#[derive(Clone, Copy, Debug, Deserialize, Serialize, clap::ValueEnum, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceArm {
    Baseline,
    Association,
    Checkpoint,
}
impl EvidenceArm {
    fn name(self) -> &'static str {
        match self {
            Self::Baseline => "baseline",
            Self::Association => "association",
            Self::Checkpoint => "checkpoint",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, clap::ValueEnum, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceMode {
    Pipeline,
    Corrupt,
}
#[derive(Debug)]
pub struct EvidenceRunOptions {
    pub template: PathBuf,
    pub policy: PathBuf,
    pub compact: PathBuf,
    pub prefix: PathBuf,
    pub images: PathBuf,
    pub output: PathBuf,
    pub endpoint: String,
    pub observation: String,
    pub split: String,
    pub arms: Vec<EvidenceArm>,
    pub mode: EvidenceMode,
}
pub struct EvidenceReplayOptions {
    pub template: PathBuf,
    pub policy: PathBuf,
    pub compact: PathBuf,
    pub prefix: PathBuf,
    pub rollout: PathBuf,
    pub output: PathBuf,
    pub endpoint: String,
    pub observation: String,
    pub arms: Vec<EvidenceArm>,
}
pub struct EvidenceRetentionOptions {
    pub baseline: PathBuf,
    pub exporter: PathBuf,
    pub output: PathBuf,
    pub endpoint: Option<String>,
    pub observation: Option<String>,
    pub verify_only: bool,
}
fn fresh_output(output: &Path) -> Result<PathBuf> {
    let output = private_output(output)?;
    ensure(
        std::fs::read_dir(&output)
            .map_err(|_| BenchmarkError("evidence_output_inventory_failed"))?
            .next()
            .is_none(),
        "evidence_fresh_private_output_required",
    )?;
    Ok(output)
}
fn arms(arms: &[EvidenceArm], corrupt: bool) -> Result<()> {
    ensure(
        !arms.is_empty()
            && arms.len() <= 3
            && arms.iter().enumerate().all(|(n, a)| !arms[..n].contains(a))
            && (!corrupt || !arms.contains(&EvidenceArm::Checkpoint)),
        "evidence_invalid_arms",
    )
}
fn message(text: &str) -> Value {
    json!({"type":"message","role":"user","content":[{"type":"input_text","text":text}]})
}
fn template(path: &Path) -> Result<Value> {
    let raw = read(path)?;
    let value = if raw.starts_with(b"POST /v1/responses HTTP/1.1\r\n") {
        let end = raw
            .windows(4)
            .position(|v| v == b"\r\n\r\n")
            .ok_or(BenchmarkError("evidence_template_header_missing"))?;
        ensure(end <= 32768, "evidence_template_header_bound")?;
        let header = std::str::from_utf8(&raw[..end])
            .map_err(|_| BenchmarkError("evidence_template_header_utf8"))?;
        let mut length = None;
        for line in header.lines().skip(1) {
            let (key, value) = line
                .split_once(':')
                .ok_or(BenchmarkError("evidence_template_header_invalid"))?;
            ensure(
                !key.eq_ignore_ascii_case("transfer-encoding"),
                "evidence_chunked_template_unsupported",
            )?;
            if key.eq_ignore_ascii_case("content-length") {
                ensure(length.is_none(), "evidence_duplicate_content_length")?;
                length = value.trim().parse::<usize>().ok();
            }
        }
        ensure(
            length == Some(raw.len() - end - 4),
            "evidence_template_content_length_mismatch",
        )?;
        parse(&raw[end + 4..])?
    } else {
        parse(&raw)?
    };
    ensure(
        value["model"] == MODEL
            && value["tools"].as_array().is_some_and(|v| v.len() == 13)
            && value["instructions"]
                .as_str()
                .is_some_and(|s| !s.trim().is_empty()),
        "evidence_template_model_instructions_tools_mismatch",
    )?;
    Ok(value)
}
struct Peer {
    client: reqwest::Client,
    endpoint: String,
    observer: ObservationMode,
}
impl Peer {
    fn new(endpoint: &str, observation: &str) -> Result<Self> {
        let url = reqwest::Url::parse(endpoint)
            .map_err(|_| BenchmarkError("evidence_loopback_endpoint_required"))?;
        ensure(
            url.scheme() == "http"
                && url.host_str() == Some("127.0.0.1")
                && url.port().is_some_and(|p| p >= 1024)
                && url.username().is_empty()
                && url.password().is_none()
                && url.path() == "/"
                && url.query().is_none()
                && url.fragment().is_none(),
            "evidence_loopback_endpoint_required",
        )?;
        let observer = ObservationMode::parse(observation)?;
        ensure(
            matches!(observer, ObservationMode::RustBoundary { .. }),
            "evidence_explicit_owned_rust_observer_required",
        )?;
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(180))
            .build()
            .map_err(|_| BenchmarkError("evidence_http_client_failed"))?;
        Ok(Self {
            client,
            endpoint: url.as_str().trim_end_matches('/').into(),
            observer,
        })
    }
    async fn bytes(&self, mut response: reqwest::Response, maximum: usize) -> Result<Vec<u8>> {
        ensure(
            response.status().is_success(),
            "evidence_provider_http_failure",
        )?;
        let mut bytes = vec![];
        while let Some(part) = response
            .chunk()
            .await
            .map_err(|_| BenchmarkError("evidence_response_transport_failed"))?
        {
            ensure(
                bytes.len() + part.len() <= maximum,
                "evidence_response_size_bound",
            )?;
            bytes.extend_from_slice(&part);
        }
        Ok(bytes)
    }
    async fn idle(&self) -> Result<()> {
        let response = self
            .client
            .get(format!(
                "{}{path}",
                self.endpoint,
                path = self.observer.path()
            ))
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|_| BenchmarkError("evidence_health_transport_failed"))?;
        let value = parse(&self.bytes(response, 64 * 1024).await?)?;
        ensure(
            self.observer.inspect(&value, MODEL)?["idle"] == true
                && value["selected_model"] == MODEL,
            "evidence_exact_model_idle_unconfirmed",
        )
    }
    async fn infer(&self, output: &Path, id: &str, stage: &str, request: &Value) -> Result<Value> {
        self.idle().await?;
        ensure(
            request.to_string().len() <= MAX_FILE
                && request["stream"] == true
                && request["store"] == false,
            "evidence_native_full_history_stream_required",
        )?;
        save(output, &format!("{id}-{stage}-request.json"), request)?;
        let started = Instant::now();
        let response = self
            .client
            .post(format!("{}/v1/responses", self.endpoint))
            .json(request)
            .send()
            .await
            .map_err(|_| BenchmarkError("evidence_inference_transport_failed"))?;
        let raw = self.bytes(response, 8 * 1024 * 1024).await?;
        super::opaque::write_new(output, &format!("{id}-{stage}-response.sse"), &raw)?;
        let text =
            std::str::from_utf8(&raw).map_err(|_| BenchmarkError("evidence_response_utf8"))?;
        let mut decoder = SseDecoder::default();
        let events = decoder.push(text)?;
        decoder.finish()?;
        let endings = events
            .iter()
            .filter(|e| e["type"] == "response.completed" || e["type"] == "response.incomplete")
            .collect::<Vec<_>>();
        ensure(
            endings.len() == 1
                && !events.iter().any(|e| {
                    matches!(
                        e["type"].as_str(),
                        Some("error" | "provider.error" | "response.failed")
                    )
                }),
            "evidence_response_terminal_mismatch",
        )?;
        let result = &endings[0]["response"];
        ensure(
            result["error"].is_null() && result["model"] == MODEL && result["output"].is_array(),
            "evidence_model_response_invalid",
        )?;
        let created = events
            .iter()
            .filter(|e| e["type"] == "response.created")
            .collect::<Vec<_>>();
        ensure(
            created.len() == 1
                && result["id"].as_str().is_some_and(|id| !id.is_empty())
                && created[0]["response"]["id"] == result["id"]
                && ((endings[0]["type"] == "response.completed"
                    && result["status"] == "completed")
                    || (endings[0]["type"] == "response.incomplete"
                        && result["status"] == "incomplete")),
            "evidence_response_identity_or_status_mismatch",
        )?;
        let text = consistent_text(&events, result)?;
        let calls = result["output"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|i| i["type"] == "function_call")
            .cloned()
            .collect::<Vec<_>>();
        self.idle().await?;
        Ok(
            json!({"text":text,"status":result["status"],"calls":calls,"elapsed_ms":started.elapsed().as_secs_f64()*1000.,"usage":result["usage"],"incomplete_details":result["incomplete_details"],"noToolsExecuted":true}),
        )
    }
}
fn request(template: &Value, arm: EvidenceArm, input: Vec<Value>, tools: Value) -> Result<Value> {
    let (_, candidates) = evidence_corpus()?;
    let instructions = template["instructions"].as_str().unwrap().to_owned()
        + if arm == EvidenceArm::Association {
            "\n"
        } else {
            ""
        }
        + if arm == EvidenceArm::Association {
            &candidates.association
        } else {
            ""
        };
    Ok(
        json!({"model":MODEL,"instructions":instructions,"input":input,"tools":tools,"stream":true,"store":false,"temperature":0.1,"max_output_tokens":2048}),
    )
}
fn png(path: &Path) -> Result<Vec<u8>> {
    let raw = read_bounded(path, 2 * 1024 * 1024)?;
    ensure(
        raw.starts_with(b"\x89PNG\r\n\x1a\n") && raw.len() >= 33,
        "evidence_bounded_png_required",
    )?;
    Ok(raw)
}
fn receipt(id: &str, ax: &str, png: &[u8]) -> Vec<Value> {
    vec![
        json!({"type":"function_call","call_id":id,"name":"computer_v2_capture","arguments":"{\"include_accessibility\":true}"}),
        json!({"type":"function_call_output","call_id":id,"output":[{"type":"input_text","text":ax},{"type":"input_image","image_url":format!("data:image/png;base64,{}",STANDARD.encode(png))}]}),
    ]
}
fn answered(result: &Value) -> bool {
    result["status"] == "completed"
        && result["calls"].as_array().is_some_and(|v| v.is_empty())
        && result["text"].as_str().is_some_and(|s| !s.is_empty())
}
pub async fn evidence_run(options: &EvidenceRunOptions) -> Result<Value> {
    arms(&options.arms, options.mode == EvidenceMode::Corrupt)?;
    ensure(
        matches!(options.split.as_str(), "development" | "holdout"),
        "evidence_frozen_split_required",
    )?;
    let output = fresh_output(&options.output)?;
    let template = template(&options.template)?;
    let (policy, compact, prefix) = (
        read_text(&options.policy)?,
        read_text(&options.compact)?,
        read_text(&options.prefix)?,
    );
    ensure(
        !policy.is_empty() && !compact.is_empty() && !prefix.is_empty(),
        "evidence_production_policy_templates_required",
    )?;
    let peer = Peer::new(&options.endpoint, &options.observation)?;
    let (fixtures, candidates) = evidence_corpus()?;
    let fixtures = fixtures
        .into_iter()
        .filter(|f| {
            matches!(
                (&f.split, options.split.as_str()),
                (super::evidence::EvidenceSplit::Development, "development")
                    | (super::evidence::EvidenceSplit::Holdout, "holdout")
            )
        })
        .filter(|f| {
            options.mode != EvidenceMode::Corrupt || poisoned_memory_checkpoint(f).is_some()
        })
        .collect::<Vec<_>>();
    let mut summary = json!({"scope":"synthetic association experiment; not App Server or desktop acceptance","mode":options.mode,"split":options.split,"model":MODEL,"state":"running","failure":null,
        "instructionSHA256":hash(template["instructions"].to_string()),"toolsSHA256":hash(template["tools"].to_string()),"policySHA256":hash(&policy),"templateSHA256":hash(read(&options.template)?),
        "fixtureSHA256":hash(serde_json::to_vec(&fixtures).map_err(|_|BenchmarkError("evidence_fixture_serialization"))?),"plannedLanes":fixtures.len()*options.arms.len(),"attemptedRequests":0,"rows":[],
        "differencesFromProduction":["synthetic screenshot and AX text","constructed summary and receipt context","temperature=0.1","2048 token stage budget","stream=true/store=false owned Rust protocol","JSON answer requirement","no tool execution"],"noToolsExecuted":true});
    let work:Result<()> = async {
        save(&output,"summary.json",&summary)?;
        for (n,f) in fixtures.iter().enumerate() {
            let pixels=png(&options.images.join(format!("{}.png",f.id)))?;
            let current=receipt("call_synthetic_capture",&f.ax,&pixels);
            let mut prior=vec![];
            if let Some(old)=&f.prior_observation { prior=receipt("call_synthetic_prior",&old.ax,&png(&options.images.join(format!("{}-prior.png",f.id)))?); }
            let original=vec![message(&policy),message(&f.prompt)];
            for i in 0..options.arms.len() {
                let arm=options.arms[(n+i)%options.arms.len()]; let id=format!("{}-{}",f.id,arm.name());
                let mut row=json!({"id":id,"arm":arm,"case":f.id,"tags":f.tags,"expected":f.expected,"pngSHA256":hash(&pixels),"state":"running"});
                let index=summary["rows"].as_array().unwrap().len(); summary["rows"].as_array_mut().unwrap().push(row.clone()); save(&output,"summary.json",&summary)?;
                let sampled=if options.mode==EvidenceMode::Corrupt {json!({"text":poisoned_memory_checkpoint(f).unwrap(),"calls":[],"status":"completed","elapsed_ms":0.,"syntheticCorruption":true})} else {
                    let mut history=original.clone();history.extend(prior.clone());history.extend(current.clone());history.push(message(if arm==EvidenceArm::Checkpoint{&candidates.checkpoint}else{&compact}));
                    summary["attemptedRequests"]=json!(summary["attemptedRequests"].as_u64().unwrap()+1);save(&output,"summary.json",&summary)?;
                    peer.infer(&output,&id,"summary",&request(&template,arm,history,json!([]))?).await?
                };
                row["summary"]=sampled.clone();
                if !answered(&sampled) { row["state"]=json!("summary_incomplete");row["elapsed_ms"]=sampled["elapsed_ms"].clone(); }
                else {
                    let mut history=original.clone();history.push(message(&format!("{prefix}\n{}",sampled["text"].as_str().unwrap())));
                    if !prior.is_empty() {
                        let mut retained=prior.clone();retained[1]["output"]=json!([{"type":"input_text","text":f.prior_observation.as_ref().unwrap().ax},{"type":"input_text","text":"[Earlier image omitted during local compaction; newest eligible capture retained.]"}]);history.extend(retained);
                    }
                    history.extend(current.clone());summary["attemptedRequests"]=json!(summary["attemptedRequests"].as_u64().unwrap()+1);save(&output,"summary.json",&summary)?;
                    let final_result=peer.infer(&output,&id,"final",&request(&template,arm,history,template["tools"].clone())?).await?;
                    let mut score=score_evidence_answer(final_result["text"].as_str().unwrap(),&f.expected); if !answered(&final_result){score.exact=false;}
                    row["state"]=json!(if final_result["status"]!="completed"{"incomplete"}else if !final_result["calls"].as_array().unwrap().is_empty(){"tool_requested_not_executed"}else{"answered"});
                    row["elapsed_ms"]=json!(sampled["elapsed_ms"].as_f64().unwrap()+final_result["elapsed_ms"].as_f64().unwrap());row["score"]=serde_json::to_value(score).map_err(|_|BenchmarkError("evidence_score_serialization"))?;row["final"]=final_result;
                }
                summary["rows"][index]=row;save(&output,"summary.json",&summary)?;
            }
        }
        Ok(())
    }.await;
    summary["state"] = json!(if work.is_ok() { "completed" } else { "stopped" });
    if let Err(error) = work {
        summary["failure"] = json!(error.0);
    }
    save(&output, "summary.json", &summary)?;
    Ok(redacted(&summary))
}
fn redacted(summary: &Value) -> Value {
    let mut value = summary.clone();
    if let Some(rows) = value["rows"].as_array_mut() {
        for row in rows {
            for key in ["summary", "final", "expected"] {
                row.as_object_mut().unwrap().remove(key);
            }
        }
    }
    value
}
pub async fn evidence_retention(options: &EvidenceRetentionOptions) -> Result<Value> {
    let baseline = read(&options.baseline)?;
    let exporter = read(&options.exporter)?;
    let prepared = prepare_retention_replay(&parse(&baseline)?, &parse(&exporter)?)?;
    let output = fresh_output(&options.output)?;
    let mut summary = prepared.audit;
    summary["baselineFileSHA256"] = json!(hash(baseline));
    summary["exporterFileSHA256"] = json!(hash(exporter));
    summary["state"] = json!("verified_only");
    save(&output, "summary.json", &summary)?;
    if !options.verify_only {
        ensure(
            summary["changedOutputCount"]
                .as_u64()
                .is_some_and(|n| n > 0),
            "evidence_no_changed_output_to_replay",
        )?;
        let peer = Peer::new(
            options
                .endpoint
                .as_deref()
                .ok_or(BenchmarkError("evidence_endpoint_required"))?,
            options
                .observation
                .as_deref()
                .ok_or(BenchmarkError("evidence_observer_required"))?,
        )?;
        // All retained request fields remain exact except the explicitly recorded transport variant.
        let mut request = prepared.request;
        request["stream"] = json!(true);
        request["store"] = json!(false);
        summary["transportVariant"] =
            json!("stream=true/store=false; all non-transport retained fields exact");
        match peer.infer(&output, "retention", "final", &request).await {
            Ok(result) => {
                summary["state"] = json!(if answered(&result) {
                    "answered_requires_blinded_audit"
                } else {
                    "incomplete_or_tool_requested_not_executed"
                });
                summary["responseSHA256"] = json!(hash(result.to_string()));
                summary["elapsed_ms"] = result["elapsed_ms"].clone();
            }
            Err(error) => {
                summary["state"] = json!("stopped");
                summary["failure"] = json!(error.0);
            }
        }
        save(&output, "summary.json", &summary)?;
    }
    Ok(summary)
}
pub async fn evidence_regression(options: &EvidenceReplayOptions) -> Result<Value> {
    arms(&options.arms, false)?;
    ensure(
        !options.arms.contains(&EvidenceArm::Checkpoint),
        "evidence_regression_two_frozen_arms_only",
    )?;
    let template = template(&options.template)?;
    let policy = read_text(&options.policy)?;
    let compact = read_text(&options.compact)?;
    let prefix = read_text(&options.prefix)?;
    let raw = super::rollouts::read_large_rollout(&options.rollout)?;
    let records = raw
        .lines()
        .filter(|s| !s.trim().is_empty())
        .map(|s| parse(s.as_bytes()))
        .collect::<Result<Vec<_>>>()?;
    let prepared = prepare_recorded_regression(&records, &prefix, &policy)?;
    let output = fresh_output(&options.output)?;
    let peer = Peer::new(&options.endpoint, &options.observation)?;
    let mut summary = json!({"scope":"recorded regression reconstructed history; blinded audit required","state":"running","failure":null,"rolloutSHA256":hash(raw),"preflight":prepared.audit,"rows":[],"noToolsExecuted":true,
        "differencesFromProduction":["reconstructed guardian history not original model wire","summary removed by exact bytes and provenance","reasoning omitted","retained policy prepended","temperature=0.1","2048 token stage budget","stream=true/store=false owned Rust protocol","no tool execution"]});
    let work:Result<()> = async {
        for arm in &options.arms {
            let id=arm.name();let mut history=prepared.summary_history.clone();history.push(message(&compact));
            let sampled=peer.infer(&output,id,"summary",&request(&template,*arm,history,json!([]))?).await?;
            let mut row=json!({"arm":arm,"state":"summary_incomplete","summary":sampled});
            if answered(&sampled) {
                let mut history=prepared.continuation.clone();history[prepared.summary_index]["content"]=json!([{"type":"input_text","text":format!("{prefix}\n{}",sampled["text"].as_str().unwrap())}]);
                ensure(history.iter().enumerate().all(|(n,v)|n==prepared.summary_index || *v==prepared.continuation[n]),"evidence_continuation_retained_fields_changed")?;
                let result=peer.infer(&output,id,"final",&request(&template,*arm,history,template["tools"].clone())?).await?;
                row["state"]=json!(if answered(&result){"answered_requires_blinded_audit"}else{"incomplete_or_tool_requested_not_executed"});row["final"]=result;
            }
            summary["rows"].as_array_mut().unwrap().push(row);save(&output,"summary.json",&summary)?;
        }
        Ok(())
    }.await;
    summary["state"] = json!(if work.is_ok() { "completed" } else { "stopped" });
    if let Err(error) = work {
        summary["failure"] = json!(error.0);
    }
    save(&output, "summary.json", &summary)?;
    Ok(redacted(&summary))
}
pub fn summarize_evidence(summary: &Value) -> Result<Value> {
    let rows = summary["rows"]
        .as_array()
        .ok_or(BenchmarkError("evidence_summary_rows_required"))?;
    ensure(rows.len() <= 1000, "evidence_summary_row_bound")?;
    let mut grouped: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for row in rows {
        let arm = row["arm"]
            .as_str()
            .filter(|s| ["baseline", "association", "checkpoint"].contains(s))
            .ok_or(BenchmarkError("evidence_summary_arm_invalid"))?;
        grouped.entry(arm.into()).or_default().push(row);
    }
    let median = |mut values: Vec<f64>| -> Option<f64> {
        values.sort_by(f64::total_cmp);
        let n = values.len();
        if n == 0 {
            None
        } else if n.is_multiple_of(2) {
            Some((values[n / 2 - 1] + values[n / 2]) / 2.)
        } else {
            Some(values[n / 2])
        }
    };
    let mut arms = vec![];
    for (arm, rows) in grouped {
        let answered = rows
            .iter()
            .filter(|r| r["state"] == "answered")
            .copied()
            .collect::<Vec<_>>();
        let sum = |key: &str| {
            answered
                .iter()
                .filter_map(|r| r["score"][key].as_u64())
                .sum::<u64>()
        };
        arms.push(json!({"arm":arm,"lanes":rows.len(),"answered":answered.len(),"exact":answered.iter().filter(|r|r["score"]["exact"]==true).count(),"validJSON":answered.iter().filter(|r|r["score"]["valid"]==true).count(),"unsupported":sum("unsupported"),"omitted":sum("omitted"),"extra":sum("extra"),
            "noCompletion":rows.iter().filter(|r|r["state"]!="answered").map(|r|json!({"id":r["id"],"state":r["state"]})).collect::<Vec<_>>(),"medianMsAllFinishedLanes":median(rows.iter().filter_map(|r|r["elapsed_ms"].as_f64()).filter(|v|v.is_finite()&&*v>=0.).collect()),"medianMsAnsweredLanes":median(answered.iter().filter_map(|r|r["elapsed_ms"].as_f64()).filter(|v|v.is_finite()&&*v>=0.).collect())}));
    }
    Ok(
        json!({"state":summary["state"],"split":summary["split"],"attemptedRequests":summary["attemptedRequests"],"arms":arms}),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn experiment_arms_and_owned_peer_are_closed() {
        assert!(arms(&[EvidenceArm::Baseline, EvidenceArm::Association], true).is_ok());
        assert!(arms(&[EvidenceArm::Baseline, EvidenceArm::Baseline], false).is_err());
        assert!(arms(&[EvidenceArm::Checkpoint], true).is_err());
        assert!(Peer::new("http://example.test:1234/", "metrics").is_err());
        assert!(Peer::new("http://127.0.0.1:32170/", "metrics").is_err());
        assert!(
            Peer::new(
                "http://127.0.0.1:32170/",
                &format!("rust:{}", uuid::Uuid::new_v4())
            )
            .is_ok()
        );
    }
    #[test]
    fn incomplete_lanes_never_count_as_exact_answers() {
        let summary = json!({"state":"completed","rows":[{"id":"a","arm":"baseline","state":"incomplete","elapsed_ms":5,"score":{"exact":true,"valid":true}},{"id":"b","arm":"baseline","state":"answered","elapsed_ms":7,"score":{"exact":false,"valid":true,"unsupported":1,"omitted":2,"extra":0}}]});
        let result = summarize_evidence(&summary).unwrap();
        assert_eq!(result["arms"][0]["exact"], 0);
        assert_eq!(result["arms"][0]["answered"], 1);
        assert_eq!(result["arms"][0]["medianMsAllFinishedLanes"], 6.);
    }
}

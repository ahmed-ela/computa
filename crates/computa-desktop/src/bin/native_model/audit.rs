//! Finite allowlisted wire projection. Neither model prose, image bytes,
//! bootstrap/configuration nor authentication/history values are persisted.
use computa_runtime::rpc::{WireDirection, WireObservationError, WireObserver};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    sync::Mutex,
};
pub fn hash(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes.as_ref()))
}
fn identifier(v: &Value) -> Option<&str> {
    v.as_str().filter(|s| {
        !s.is_empty()
            && s.len() <= 256
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-.:".contains(c))
    })
}
pub fn hash_value(v: &Value) -> String {
    hash(serde_json::to_vec(v).unwrap_or_default())
}
#[derive(Default)]
pub struct State {
    pub rows: Vec<Value>,
    pub thread: Option<String>,
    pub turns: Vec<String>,
    pub first_delta: Option<(String, String, u64)>,
    pub completed: Vec<(String, String, String, u64)>,
    pub calls: Vec<(String, String, String, String, u64)>,
    pub replies: Vec<(String, bool, u64)>,
    pub unexpected: bool,
    pub final_agents: Vec<(String, String, String)>,
    pub public_hashes: HashMap<(String, String), Sha256>,
}
pub struct Audit {
    pub state: Mutex<State>,
    file: Mutex<File>,
    bytes: Mutex<usize>,
}
impl Audit {
    pub fn create(path: &Path) -> std::io::Result<Self> {
        Ok(Self {
            state: Mutex::new(State::default()),
            file: Mutex::new(
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(path)?,
            ),
            bytes: Mutex::new(0),
        })
    }
    pub fn sync(&self) -> std::io::Result<()> {
        self.file
            .lock()
            .map_err(|_| std::io::Error::other("audit lock"))?
            .sync_all()
    }
}
impl WireObserver for Audit {
    fn observe(
        &self,
        direction: WireDirection,
        sequence: u64,
        frame: &Value,
    ) -> Result<(), WireObservationError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| WireObservationError::Persistence)?;
        if state.rows.len() >= 8192 {
            return Err(WireObservationError::Capacity);
        }
        let inbound = direction == WireDirection::Inbound;
        let method = match frame["method"].as_str() {
            Some(
                m @ ("initialize"
                | "initialized"
                | "thread/start"
                | "thread/resume"
                | "thread/read"
                | "thread/list"
                | "thread/turns/list"
                | "turn/start"
                | "turn/started"
                | "turn/completed"
                | "turn/interrupt"
                | "item/started"
                | "item/completed"
                | "item/tool/call"
                | "item/agentMessage/delta"
                | "item/reasoning/textDelta"
                | "item/reasoning/summaryTextDelta"
                | "item/commandExecution/requestApproval"
                | "item/fileChange/requestApproval"
                | "serverRequest/resolved"
                | "thread/status/changed"
                | "error"),
            ) => m,
            Some(_) => "other",
            None => "reply",
        };
        let params = &frame["params"];
        let item = &params["item"];
        if matches!(
            item["type"].as_str(),
            Some(
                "commandExecution" | "fileChange" | "mcpToolCall" | "webSearch" | "imageGeneration"
            )
        ) {
            state.unexpected = true;
            return Err(WireObservationError::Rejected);
        }
        let thread = identifier(&params["threadId"]);
        let turn = identifier(&params["turnId"]);
        if inbound
            && method == "item/agentMessage/delta"
            && let (Some(t), Some(u), Some(delta)) = (thread, turn, params["delta"].as_str())
        {
            state
                .public_hashes
                .entry((t.into(), u.into()))
                .or_default()
                .update(delta.as_bytes());
        }
        if inbound
            && method == "item/completed"
            && item["type"] == "agentMessage"
            && let (Some(t), Some(u), Some(text)) = (thread, turn, item["text"].as_str())
        {
            if state.final_agents.len() >= 32 {
                return Err(WireObservationError::Capacity);
            }
            state
                .final_agents
                .push((t.into(), u.into(), hash(text.trim())));
        }
        if inbound && method == "turn/started" {
            if let Some(id) = identifier(&params["turn"]["id"]) {
                state.turns.push(id.into())
            }
            if let Some(t) = thread {
                state.thread = Some(t.into())
            }
        }
        if inbound
            && matches!(
                method,
                "item/agentMessage/delta"
                    | "item/reasoning/textDelta"
                    | "item/reasoning/summaryTextDelta"
            )
            && params["delta"].as_str().is_some_and(|d| !d.is_empty())
            && let (Some(t), Some(u)) = (thread, turn)
            && state.first_delta.is_none()
        {
            state.first_delta = Some((t.into(), u.into(), sequence))
        }
        if inbound
            && method == "turn/completed"
            && let (Some(t), Some(u), Some(status)) = (
                thread,
                identifier(&params["turn"]["id"]),
                params["turn"]["status"].as_str(),
            )
            && matches!(status, "completed" | "interrupted" | "failed")
        {
            state
                .completed
                .push((t.into(), u.into(), status.into(), sequence))
        }
        if inbound && method == "item/tool/call" {
            let (t, u, c, n) = (
                thread,
                turn,
                identifier(&params["callId"]),
                params["tool"].as_str(),
            );
            let (Some(t), Some(u), Some(c), Some(n)) = (t, u, c, n) else {
                return Err(WireObservationError::Rejected);
            };
            if !n.starts_with("computer_v2_")
                || n.len() > 64
                || state.calls.iter().any(|row| row.2 == c)
            {
                return Err(WireObservationError::Rejected);
            }
            state
                .calls
                .push((t.into(), u.into(), c.into(), n.into(), sequence));
        }
        if method == "reply"
            && let Some(id) = frame.get("id")
        {
            let id = match id {
                Value::String(s) if s.len() <= 256 => s.clone(),
                Value::Number(n) => n.to_string(),
                _ => return Err(WireObservationError::Rejected),
            };
            state
                .replies
                .push((id, frame.get("error").is_none(), sequence));
        }
        let row = json!({"sequence":sequence,"direction":if inbound{"inbound"}else{"outbound"},"method":method,"rpc_error":frame.get("error").is_some(),
            "rpc_id":frame.get("id").filter(|id|id.is_number()||identifier(id).is_some()),
            "thread_id":thread,"turn_id":turn.or_else(||identifier(&params["turn"]["id"])),
            "call_id":identifier(&params["callId"]),"tool":params["tool"].as_str().or_else(||item["tool"].as_str()).filter(|s|s.starts_with("computer_v2_")&&s.len()<=64),
            "item_id":identifier(&item["id"]),"item_type":item["type"].as_str().filter(|s|matches!(*s,"dynamicToolCall"|"agentMessage"|"userMessage"|"reasoning"|"contextCompaction")),
            "item_status":item["status"].as_str().filter(|s|matches!(*s,"inProgress"|"completed"|"failed")),"turn_status":params["turn"]["status"].as_str().filter(|s|matches!(*s,"inProgress"|"completed"|"failed"|"interrupted")),
            "delta_length":params["delta"].as_str().map(str::len),"delta_sha256":params["delta"].as_str().map(hash),
            "arguments_sha256":params.get("arguments").or_else(||item.get("arguments")).map(hash_value),"content_sha256":item.get("contentItems").map(hash_value),
            "reply_content_sha256":frame["result"].get("contentItems").map(hash_value),"reply_success":frame["result"].get("success").and_then(Value::as_bool),"item_success":item.get("success").and_then(Value::as_bool),
            "final_agent_sha256":if inbound&&method=="item/completed"&&item["type"]=="agentMessage"{item["text"].as_str().map(|s|hash(s.trim()))}else{None},
            "thread_start_model":if !inbound&&method=="thread/start"{params["model"].as_str().filter(|s|matches!(*s,"lmstudio-community/Qwen3.5-4B-MLX-4bit"|"lmstudio-community/Qwen3.5-9B-MLX-4bit"))}else{None},
            "dynamic_tool_names":if !inbound&&method=="thread/start"{params["dynamicTools"].as_array().map(|tools|tools.iter().filter_map(|t|t["name"].as_str()).filter(|s|s.starts_with("computer_v2_")&&s.len()<=64).collect::<Vec<_>>())}else{None}});
        let mut data = serde_json::to_vec(&row).map_err(|_| WireObservationError::Rejected)?;
        data.push(b'\n');
        let mut bytes = self
            .bytes
            .lock()
            .map_err(|_| WireObservationError::Persistence)?;
        *bytes = bytes
            .checked_add(data.len())
            .ok_or(WireObservationError::Capacity)?;
        if *bytes > 8 * 1024 * 1024 {
            return Err(WireObservationError::Capacity);
        }
        self.file
            .lock()
            .map_err(|_| WireObservationError::Persistence)?
            .write_all(&data)
            .map_err(|_| WireObservationError::Persistence)?;
        state.rows.push(row);
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finite_projection_never_persists_private_configuration_or_prose() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audit.jsonl");
        let audit = Audit::create(&path).unwrap();
        let secret = "qualification-private-auth-token-and-history";
        audit.observe(WireDirection::Outbound, 1, &json!({"id":1,"method":"thread/start","params":{"model":"lmstudio-community/Qwen3.5-4B-MLX-4bit","config":{"Authorization":secret},"dynamicTools":[{"name":"computer_v2_status","description":secret}]}})).unwrap();
        audit.observe(WireDirection::Inbound, 2, &json!({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":secret}})).unwrap();
        audit
            .observe(
                WireDirection::Inbound,
                3,
                &json!({"method":secret,"params":{"item":{"type":secret,"status":secret}}}),
            )
            .unwrap();
        audit.sync().unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert!(!String::from_utf8(bytes).unwrap().contains(secret));
        let s = audit.state.lock().unwrap();
        assert_eq!(
            s.rows[0]["thread_start_model"],
            "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        );
        assert_eq!(s.rows[1]["delta_sha256"], hash(secret));
        assert_eq!(s.rows[2]["method"], "other");
        assert!(s.rows[2]["item_type"].is_null());
    }
    #[test]
    fn unexpected_cli_execution_is_rejected_before_audit_acceptance() {
        let dir = tempfile::tempdir().unwrap();
        let audit = Audit::create(&dir.path().join("audit.jsonl")).unwrap();
        assert!(matches!(audit.observe(WireDirection::Inbound, 1, &json!({"method":"item/started","params":{"item":{"type":"commandExecution","command":"private command"}}})), Err(WireObservationError::Rejected)));
        let s = audit.state.lock().unwrap();
        assert!(s.unexpected);
        assert!(s.rows.is_empty());
    }
    #[test]
    fn exhausted_metadata_capacity_does_not_accept_or_write_an_extra_row() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audit.jsonl");
        let audit = Audit::create(&path).unwrap();
        audit.state.lock().unwrap().rows.resize(8192, Value::Null);
        assert!(matches!(
            audit.observe(WireDirection::Inbound, 8193, &json!({"id":1,"result":{}})),
            Err(WireObservationError::Capacity)
        ));
        assert_eq!(std::fs::metadata(path).unwrap().len(), 0);
    }
}

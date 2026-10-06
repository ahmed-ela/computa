use computa_contracts::models::WebProvider;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;
pub const READY_MS: u64 = 45_000;
pub const TURN_MS: u64 = 180_000;
pub const STABLE_MS: u64 = 1_600;
pub const LEDGER_KEY: &str = "computaOwnedWebProviderTabsV1";
pub const RECEIPTS_KEY: &str = "computaClosedWebProviderReceiptsV1";
pub fn fresh(provider: WebProvider, raw: &str) -> bool {
    url::Url::parse(raw).is_ok_and(|u| {
        u.origin().ascii_serialization() == provider.origin()
            && match provider {
                WebProvider::Chatgpt => u.path() == "/",
                WebProvider::Claude => u.path() == "/new",
                WebProvider::Gemini => {
                    let p = u.path().trim_matches('/');
                    p == "app" || {
                        let a: Vec<_> = p.split('/').collect();
                        a.len() == 3
                            && a[0] == "u"
                            && a[1].bytes().all(|b| b.is_ascii_digit())
                            && a[2] == "app"
                    }
                }
            }
    })
}
pub fn conversation(provider: WebProvider, raw: &str) -> Option<String> {
    let u = url::Url::parse(raw).ok()?;
    if u.origin().ascii_serialization() != provider.origin() {
        return None;
    }
    let p = u.path().trim_end_matches('/');
    let segment = p.rsplit('/').next()?;
    let prefix = &p[..p.len() - segment.len()];
    let allowed = match provider {
        WebProvider::Claude => false,
        WebProvider::Chatgpt => {
            prefix == "/c/"
                && (segment
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                    || segment
                        .strip_prefix("local-chatgpt%3A")
                        .or_else(|| segment.strip_prefix("local-chatgpt:"))
                        .is_some_and(|id| {
                            id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                        }))
        }
        WebProvider::Gemini => {
            prefix == "/app/" || {
                let a: Vec<_> = prefix.trim_matches('/').split('/').collect();
                a.len() == 3
                    && a[0] == "u"
                    && a[1].bytes().all(|b| b.is_ascii_digit())
                    && a[2] == "app"
            }
        }
    };
    if allowed && !segment.is_empty() {
        Some(format!("{}{p}", provider.origin()))
    } else {
        None
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub source_epoch: Option<String>,
    pub token: String,
    pub tab_id: i64,
    pub provider: WebProvider,
    pub generation: String,
    pub revision: u64,
    pub state: String,
    pub created: u64,
    pub cleanup: String,
    pub sequence: u64,
    pub confirmed_user_count: u64,
    pub pending_submission: bool,
    pub document_loader_id: Option<String>,
    pub response: String,
    pub submitted: bool,
    pub conversation: Option<String>,
    pub conversation_identity: Option<String>,
    pub promoted: bool,
    pub revoked: bool,
    pub ownership_lost: bool,
    pub temporary: bool,
    pub temporary_requested: bool,
    pub recovered: bool,
    pub first_user_marker: Option<String>,
    pub first_user_identity: Option<String>,
    pub first_user_fingerprint: Option<String>,
    pub baseline: u64,
    pub last_changed: u64,
    pub turn_started: u64,
    pub failure: Option<String>,
}
impl Session {
    pub fn new(
        token: String,
        tab_id: i64,
        provider: WebProvider,
        generation: String,
        revision: u64,
        now: u64,
    ) -> Self {
        Self {
            source_epoch: None,
            token,
            tab_id,
            provider,
            generation,
            revision,
            state: "loading".into(),
            created: now,
            cleanup: "pending".into(),
            sequence: 0,
            confirmed_user_count: 0,
            pending_submission: false,
            document_loader_id: None,
            response: String::new(),
            submitted: false,
            conversation: None,
            conversation_identity: None,
            promoted: false,
            revoked: false,
            ownership_lost: false,
            temporary: false,
            temporary_requested: false,
            recovered: false,
            first_user_marker: None,
            first_user_identity: None,
            first_user_fingerprint: None,
            baseline: 0,
            last_changed: now,
            turn_started: now,
            failure: None,
        }
    }
    pub fn initial(&self) -> bool {
        self.provider == WebProvider::Claude
            && self.state == "loading"
            && !self.submitted
            && self.document_loader_id.is_none()
            && !self.ownership_lost
            && !self.recovered
            && self.sequence == 0
            && self.confirmed_user_count == 0
    }
    pub fn snapshot(&self) -> Value {
        json!({"sessionToken":self.token,"provider":self.provider,"state":self.state,"sequence":self.sequence,"text":self.response,"cleanup":self.cleanup,"error":self.failure.as_ref().map(|code|json!({"code":code}))})
    }
    pub fn ledger(&self) -> Value {
        json!({"token":self.token,"tabId":self.tab_id,"provider":self.provider,"generation":self.generation,"sourceEpoch":self.source_epoch,"revision":self.revision,"conversation":self.conversation,"submitted":self.submitted,"temporary":self.temporary,"conversationIdentity":self.conversation_identity,"promoted":self.promoted,"documentLoaderId":self.document_loader_id,"sequence":self.sequence,"confirmedUserCount":self.confirmed_user_count,"firstUserMarker":self.first_user_marker,"firstUserIdentity":self.first_user_identity,"firstUserFingerprint":self.first_user_fingerprint,"pendingSubmission":self.pending_submission,"ownershipLost":self.ownership_lost,"cleanup":self.cleanup})
    }
    pub fn user_counts(&self, action: &str) -> Result<Vec<u64>, String> {
        if self.ownership_lost
            || if self.pending_submission {
                self.sequence != self.confirmed_user_count + 1
            } else {
                self.sequence != self.confirmed_user_count
            }
        {
            return Err("web_conversation_changed".into());
        }
        match action {
            "prepare" if self.pending_submission => Err("web_conversation_changed".into()),
            "submit" if !self.pending_submission => Err("web_conversation_changed".into()),
            "prepare" => Ok(vec![self.sequence]),
            "submit" => Ok(vec![self.confirmed_user_count]),
            _ => Ok(if self.pending_submission {
                vec![self.confirmed_user_count, self.sequence]
            } else {
                vec![self.confirmed_user_count]
            }),
        }
    }
    pub fn validate_observation(
        &mut self,
        observation: &Observation,
        action: &str,
    ) -> Result<(), String> {
        if self.provider == WebProvider::Claude {
            if !self.user_counts(action)?.contains(&observation.user_count)
                || self.state == "running"
                    && action == "inspect"
                    && observation.response_count > self.baseline
                    && !observation.text.is_empty()
                    && observation.user_count != self.sequence
            {
                return self.lose("web_conversation_changed");
            }
            if observation.user_count > 0 {
                let Some(marker) = self.first_user_marker.as_ref() else {
                    return self.lose("web_conversation_changed");
                };
                let body = normalize(&observation.first_body);
                let hash = hex::encode(Sha256::digest(body.as_bytes()));
                if !body
                    .lines()
                    .any(|line| line.trim() == format!("Computa session marker: {marker}"))
                    || observation.first_id.is_empty()
                    || body.len() > 180_200
                    || self
                        .first_user_identity
                        .as_ref()
                        .is_some_and(|id| id != &observation.first_id)
                    || self
                        .first_user_fingerprint
                        .as_ref()
                        .is_some_and(|old| old != &hash)
                {
                    return self.lose("web_conversation_changed");
                }
                if self.first_user_fingerprint.is_none() {
                    if !matches!(action, "inspect" | "enableTemporary") {
                        return self.lose("web_conversation_changed");
                    }
                    self.first_user_identity = Some(observation.first_id.clone());
                    self.first_user_fingerprint = Some(hash);
                }
            }
            if self.pending_submission
                && action == "inspect"
                && observation.user_count == self.sequence
            {
                self.confirmed_user_count = self.sequence;
                self.pending_submission = false;
            }
        }
        Ok(())
    }
    pub fn lose<T>(&mut self, code: &str) -> Result<T, String> {
        self.ownership_lost = true;
        Err(code.into())
    }
}
pub fn normalize(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .nfc()
        .collect::<String>()
        .trim()
        .to_owned()
}
#[derive(Clone, Debug, Default)]
pub struct Observation {
    pub url: String,
    pub composer: bool,
    pub composer_text: String,
    pub temporary: bool,
    pub user_count: u64,
    pub response_count: u64,
    pub busy: bool,
    pub interrupted: bool,
    pub answer_complete: bool,
    pub text: String,
    pub first_body: String,
    pub first_id: String,
    pub conversation_identity: Option<String>,
    pub sign_in: bool,
}
fn count(facts: &Value, key: &str) -> u64 {
    facts[key].as_array().map_or(0, |nodes| nodes.len() as u64)
}
fn last<'a>(facts: &'a Value, key: &str) -> Option<&'a Value> {
    facts[key].as_array()?.last()
}
fn has(facts: &Value, key: &str) -> bool {
    count(facts, key) > 0
}
fn node_text(node: Option<&Value>) -> String {
    node.and_then(|node| node["text"].as_str())
        .unwrap_or("")
        .trim()
        .into()
}
pub fn observe(provider: WebProvider, result: &Value) -> Result<Observation, String> {
    let url = result["url"]
        .as_str()
        .ok_or("web_invalid_document")?
        .to_owned();
    let f = result
        .get("facts")
        .filter(|f| f.is_object())
        .ok_or("web_invalid_document")?;
    let answers = if has(f, "answers") {
        &f["answers"]
    } else {
        &f["fallbackAnswers"]
    };
    let answer = answers.as_array().and_then(|a| a.last());
    let identity = if provider == WebProvider::Chatgpt {
        let identities: std::collections::BTreeSet<_> = f["identities"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|node| {
                node["attributes"]["data-chatgpt-selection-conversation-id"].as_str()
            })
            .collect();
        if identities.len() == 1 {
            identities.first().map(|id| (*id).to_owned())
        } else {
            None
        }
    } else {
        None
    };
    let temporary = match provider {
        WebProvider::Chatgpt => {
            has(f, "exit")
                || url::Url::parse(&url).is_ok_and(|u| {
                    u.query_pairs()
                        .any(|(key, value)| key == "temporary-chat" && value == "true")
                }) && f["save"].as_array().into_iter().flatten().any(|node| {
                    node_text(Some(node)) == "Save chat"
                        || node["attributes"]["aria-label"] == "Save chat"
                })
        }
        WebProvider::Claude => {
            has(f, "exit")
                && url::Url::parse(&url)
                    .is_ok_and(|u| u.query_pairs().any(|(k, _)| k == "incognito"))
                && f["badge"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|node| node_text(Some(node)) == "Incognito chat")
        }
        WebProvider::Gemini => {
            has(f, "exit")
                || f["badge"].as_array().into_iter().flatten().any(|node| {
                    matches!(
                        node_text(Some(node)).as_str(),
                        "Just stopping by?" | "Temporary Chat"
                    )
                })
        }
    };
    let interrupted =
        node_text(last(f, "status")).replace('’', "'") == "Claude's response was interrupted.";
    Ok(Observation {
        url,
        composer: has(f, "composer"),
        composer_text: last(f, "composer")
            .and_then(|n| n["value"].as_str())
            .unwrap_or("")
            .into(),
        temporary,
        user_count: count(f, "users"),
        response_count: answers.as_array().map_or(0, |a| a.len() as u64),
        busy: has(f, "stop") || has(f, "streaming"),
        interrupted,
        answer_complete: !interrupted
            && answer.is_some_and(|node| {
                node["copyEnabled"] == true
                    && (provider != WebProvider::Claude || node["streaming"] == "false")
            }),
        text: node_text(answer),
        first_body: f["users"][0]["text"].as_str().unwrap_or("").into(),
        first_id: f["users"][0]["ownerId"].as_str().unwrap_or("").into(),
        conversation_identity: identity,
        sign_in: !has(f, "composer")
            && f["auth"].as_array().into_iter().flatten().any(|node| {
                let text = node_text(Some(node)).to_lowercase();
                text.starts_with("log in") || text.starts_with("sign in")
            }),
    })
}
pub fn dom_plan(provider: WebProvider, url: &str) -> Value {
    let mut queries = vec![];
    let mut add = |key: &str, selector: &str, visible: bool, extra: Value| {
        let mut value = json!({"key":key,"selector":selector,"visible":visible});
        if let Some(map) = extra.as_object() {
            for (k, v) in map {
                value[k] = v.clone();
            }
        }
        queries.push(value);
    };
    match provider {
        WebProvider::Chatgpt => {
            add(
                "composer",
                "#prompt-textarea, [contenteditable=true][aria-label='Ask ChatGPT'], textarea[data-testid='prompt-textarea']",
                true,
                json!({"limit":1}),
            );
            add(
                "answers",
                "[data-markdown-text-style='assistant-message']",
                true,
                json!({"copySelector":".turn-action-controls button[aria-label='Copy'],button[data-testid='copy-turn-action-button'],button[aria-label='Copy']","countSelector":"[data-markdown-text-style='assistant-message']","ancestorDepth":10}),
            );
            add(
                "fallbackAnswers",
                "[data-message-author-role='assistant']",
                true,
                json!({"textSelector":".markdown","copySelector":"button[aria-label='Copy'],button[data-testid='copy-turn-action-button']","countSelector":"[data-message-author-role='assistant']","ancestorDepth":10}),
            );
            add(
                "users",
                "[data-message-author-role='user'],[data-markdown-text-style='user-message']",
                false,
                json!({"text":false}),
            );
            add(
                "identities",
                "[data-chatgpt-selection-conversation-id]",
                true,
                json!({"attributes":["data-chatgpt-selection-conversation-id"]}),
            );
            add(
                "exit",
                "button[aria-label='Turn off temporary chat']",
                true,
                json!({"limit":1}),
            );
            add("save", "button", true, json!({"attributes":["aria-label"]}));
            add(
                "stop",
                "button[data-testid='stop-button'],button[aria-label='Stop streaming'],button[aria-label='Stop generating'],button[aria-label='Stop']",
                true,
                json!({"limit":1}),
            );
        }
        WebProvider::Gemini => {
            add(
                "composer",
                "rich-textarea [contenteditable=true],div.ql-editor[contenteditable=true]",
                true,
                json!({"limit":1}),
            );
            add(
                "answers",
                ".model-response-text,model-response .markdown",
                true,
                json!({"outerOnly":true,"copySelector":"button[aria-label*='Good response'],button[aria-label*='Copy'],button[data-test-id='copy-button']","ancestorSelector":"model-response"}),
            );
            add("users", "user-query", false, json!({"text":false}));
            add(
                "exit",
                "button[aria-label='Turn off temporary chat'],button[aria-label='Exit temporary chat']",
                true,
                json!({}),
            );
            add(
                "badge",
                "h1,h2,span.info-text",
                true,
                json!({"excludeClosest":"button,[role=menu],[role=tooltip],model-response,user-query"}),
            );
            add(
                "toggle",
                "button[aria-label='Temporary chat']",
                true,
                json!({"limit":1}),
            );
            add(
                "stop",
                "button[aria-label='Stop response'],button[aria-label='Stop generating'],button[aria-label='Stop'],button.stop-button",
                true,
                json!({"limit":1}),
            );
        }
        WebProvider::Claude => {
            add(
                "composer",
                "[data-testid='chat-input'][contenteditable=true][role=textbox]",
                true,
                json!({"limit":1}),
            );
            add(
                "answers",
                "[data-testid='assistant-message'] [data-perf-reply-text]",
                true,
                json!({"copySelector":"[data-testid='message-actions'] button[data-testid='action-bar-copy'][aria-label='Copy']","ancestorSelector":"[role=article]","countSelector":"[data-testid='assistant-message']","streamingSelector":"[data-testid='assistant-message']"}),
            );
            add(
                "users",
                "[data-testid='user-message']",
                false,
                json!({"ownerId":true,"firstTextOnly":true}),
            );
            add(
                "exit",
                "button[aria-label='Exit incognito']",
                true,
                json!({"limit":1}),
            );
            add(
                "badge",
                ".animate-incognito-header-in span",
                true,
                json!({}),
            );
            add(
                "toggle",
                "button[aria-label='Use incognito']",
                true,
                json!({"limit":1}),
            );
            add(
                "stop",
                "button[aria-label='Stop response']",
                true,
                json!({"limit":1}),
            );
            add(
                "streaming",
                "[data-testid='assistant-message'][data-is-streaming=true]",
                true,
                json!({"text":false}),
            );
            add(
                "status",
                "[data-testid='response-status-announcer'][role=status]",
                true,
                json!({}),
            );
        }
    }
    add("auth", "a,button", true, json!({"limit":1000}));
    json!({"url":url,"queries":queries})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_are_provider_specific() {
        assert!(fresh(
            WebProvider::Claude,
            "https://claude.ai/new?incognito="
        ));
        assert!(!fresh(WebProvider::Claude, "https://claude.ai/chat/a"));
        assert!(!fresh(WebProvider::Claude, "https://claude.ai.evil/new"));
        assert_eq!(
            conversation(
                WebProvider::Chatgpt,
                "https://chatgpt.com/c/a?temporary-chat=true"
            ),
            Some("https://chatgpt.com/c/a".into())
        );
    }
    #[test]
    fn first_user_marker_body_and_identity_cannot_be_replaced() {
        let mut s = Session::new("s".into(), 1, WebProvider::Claude, "g".into(), 1, 0);
        s.submitted = true;
        s.state = "running".into();
        s.sequence = 1;
        s.pending_submission = true;
        s.first_user_marker = Some("nonce".into());
        let mut o = Observation {
            user_count: 1,
            first_body: "Computa session marker: nonce\n\nOwned prompt".into(),
            first_id: "owned".into(),
            ..Default::default()
        };
        s.validate_observation(&o, "inspect").unwrap();
        assert!(!s.pending_submission);
        o.first_id = "replacement".into();
        assert!(s.validate_observation(&o, "prepare").is_err());
        assert!(s.ownership_lost);
    }
    #[test]
    fn ledger_excludes_transcripts() {
        let mut s = Session::new("s".into(), 1, WebProvider::Claude, "g".into(), 1, 0);
        s.response = "private".into();
        assert!(!s.ledger().to_string().contains("private"));
    }
}

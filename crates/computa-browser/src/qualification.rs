//! File-only fixture preparation and exact-owned read-only qualification oracles.
//! Preparing a fixture does not launch or authorize Chrome. The trusted native
//! model-driven test host owns launch, approvals, resources and cleanup.
use crate::{
    BrowserError,
    leases::{Attachment, BrowserControl, BrowserOwnership},
};
use computa_contracts::appserver::{ContentItem, ToolOutput};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_SNAPSHOT_CALLS: usize = 3;
#[derive(Debug, thiserror::Error)]
pub enum QualificationError {
    #[error("Chrome qualification evidence is invalid ({0})")]
    Evidence(&'static str),
    #[error("{0}")]
    Browser(#[from] BrowserError),
}
type Result<T> = std::result::Result<T, QualificationError>;
fn ensure(ok: bool, code: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(QualificationError::Evidence(code))
    }
}
fn digest(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes.as_ref()))
}
#[derive(Clone, Debug)]
pub struct ChromeFixture {
    pub trial_id: Uuid,
    pub file: PathBuf,
    pub file_sha256: String,
    pub url: String,
    pub heading: String,
    pub completion_token: String,
    pub open_arguments: Value,
    pub prompt: String,
}
/// Write only bounded static HTML into the already-owned private trial directory.
pub fn prepare(directory: &Path, trial_id: Uuid) -> Result<ChromeFixture> {
    ensure(directory.is_absolute(), "absolute_private_trial_required")?;
    let metadata = std::fs::symlink_metadata(directory)
        .map_err(|_| QualificationError::Evidence("private_trial_unavailable"))?;
    // SAFETY: getuid is a scalar process identity query.
    let uid = unsafe { libc::getuid() };
    ensure(
        metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && metadata.uid() == uid
            && metadata.permissions().mode() & 0o077 == 0,
        "private_trial_required",
    )?;
    let directory = directory
        .canonicalize()
        .map_err(|_| QualificationError::Evidence("private_trial_unavailable"))?;
    let nonce = trial_id.simple().to_string();
    let heading = format!("COMPUTA_MATRIX_CHROME_HEADING_{nonce}");
    let completion_token = format!("COMPUTA_MATRIX_CHROME_OK_{nonce}");
    let html = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>{heading}</title></head><body><main><h1>{heading}</h1><p>Disposable read-only browser qualification fixture.</p></main></body></html>"
    );
    let file = directory.join("chrome-qualification.html");
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&file)
        .map_err(|_| QualificationError::Evidence("new_private_fixture_required"))?;
    output
        .write_all(html.as_bytes())
        .and_then(|_| output.sync_all())
        .map_err(|_| QualificationError::Evidence("fixture_write_failed"))?;
    let url = url::Url::from_file_path(&file)
        .map_err(|_| QualificationError::Evidence("fixture_url_invalid"))?
        .to_string();
    let open_arguments = json!({"bundle_id":"com.google.Chrome","url":url,"browser_mode":"isolated","activation":"foreground"});
    let prompt = format!(
        "Call computer_v2_open exactly once with {open_arguments}. Then call computer_v2_read_page with exactly {{\"query\":\"{heading}\"}}. If the snapshot does not yet show an AXHeading for {heading}, retry the same read-only page read until it does, using at most {MAX_SNAPSHOT_CALLS} snapshot calls total. Stop retrying when the heading appears. Confirm the final AXSNAPSHOT shows the exact heading {heading}. Only after that observation, reply with exactly {completion_token}. If the heading never appears, report failure instead of the token. Use no other tools; do not click, type, or navigate elsewhere."
    );
    Ok(ChromeFixture {
        trial_id,
        file,
        file_sha256: digest(html),
        url,
        heading,
        completion_token,
        open_arguments,
        prompt,
    })
}
fn verify_file(fixture: &ChromeFixture) -> Result<()> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&fixture.file)
        .map_err(|_| QualificationError::Evidence("fixture_unavailable"))?;
    let metadata = file
        .metadata()
        .map_err(|_| QualificationError::Evidence("fixture_unavailable"))?;
    ensure(
        metadata.is_file() && metadata.len() <= 8192,
        "fixture_changed",
    )?;
    let mut bytes = vec![];
    file.take(8193)
        .read_to_end(&mut bytes)
        .map_err(|_| QualificationError::Evidence("fixture_unavailable"))?;
    ensure(
        bytes.len() <= 8192 && digest(bytes) == fixture.file_sha256,
        "fixture_changed",
    )
}
#[derive(Clone, Debug)]
pub struct QualificationCall {
    pub name: String,
    pub arguments: Value,
    pub output: ToolOutput,
}
fn text(output: &ToolOutput) -> Result<String> {
    ensure(
        output.success && !output.content.is_empty() && output.content.len() <= 8,
        "tool_result_unsuccessful",
    )?;
    let mut text = String::new();
    for content in &output.content {
        let ContentItem::Text { text: part } = content else {
            return Err(QualificationError::Evidence(
                "unexpected_image_or_action_result",
            ));
        };
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(part);
        ensure(text.len() <= 65_536, "tool_text_bound")?;
    }
    Ok(text)
}
// Quote-aware tokens keep marker-looking text inside quoted fields inert.
fn tokens(line: &str) -> Result<Vec<&str>> {
    let (mut start, mut quoted, mut escaped) = (0, false, false);
    let mut result = vec![];
    for (index, character) in line.char_indices() {
        if quoted {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                quoted = false;
            }
        } else if character == '"' {
            quoted = true;
        } else if character == ' ' {
            if start < index {
                result.push(&line[start..index]);
            }
            start = index + 1;
        } else if matches!(character, '\t' | '\r') {
            return Err(QualificationError::Evidence("invalid_snapshot_field"));
        }
    }
    ensure(!quoted && !escaped, "invalid_snapshot_field")?;
    if start < line.len() {
        result.push(&line[start..]);
    }
    Ok(result)
}
fn unique<'a>(tokens: &[&'a str], key: &str) -> Result<&'a str> {
    let prefix = format!("{key}=");
    let values = tokens
        .iter()
        .filter_map(|token| token.strip_prefix(&prefix))
        .collect::<Vec<_>>();
    ensure(values.len() == 1, "snapshot_field_missing_or_duplicate")?;
    Ok(values[0])
}
fn snapshot_heading(text: &str, heading: &str) -> Result<(Uuid, bool)> {
    let mut lines = text.lines();
    let header = tokens(
        lines
            .next()
            .ok_or(QualificationError::Evidence("snapshot_header_missing"))?,
    )?;
    ensure(
        header.first() == Some(&"AXSNAPSHOT"),
        "snapshot_header_missing",
    )?;
    let id = Uuid::parse_str(unique(&header, "id")?)
        .map_err(|_| QualificationError::Evidence("snapshot_identity_invalid"))?;
    ensure(
        unique(&header, "snapshot_id")? == id.to_string(),
        "snapshot_identity_invalid",
    )?;
    let expected = utf8_range(heading);
    let mut matched = 0;
    for line in lines.filter(|line| line.starts_with('#')) {
        let fields = tokens(line)?;
        let role = fields
            .iter()
            .filter_map(|field| field.strip_prefix("role="))
            .collect::<Vec<_>>();
        if role.as_slice() != ["\"AXHeading\""] {
            continue;
        }
        let names = fields
            .iter()
            .filter_map(|field| field.strip_prefix("title="))
            .collect::<Vec<_>>();
        if names.len() != 1 {
            continue;
        }
        let decoded: String = serde_json::from_str(names[0])
            .map_err(|_| QualificationError::Evidence("snapshot_field_invalid"))?;
        if decoded == heading && unique(&fields, "utf8")? == expected {
            matched += 1;
        }
    }
    ensure(matched <= 1, "heading_duplicate")?;
    Ok((id, matched == 1))
}
fn utf8_range(heading: &str) -> String {
    format!("0..{}/{}", heading.len(), heading.len())
}
/// Exact tool transcript oracle. It cannot establish dispatch identity or
/// current DOM alone; combine it with independent_heading and wire/rollout audit.
pub fn verify_tools(
    fixture: &ChromeFixture,
    calls: &[QualificationCall],
    assistant: &str,
    approved_opens: usize,
    unexpected_approvals: usize,
) -> Result<Value> {
    verify_file(fixture)?;
    ensure(
        (2..=MAX_SNAPSHOT_CALLS + 1).contains(&calls.len())
            && approved_opens == 1
            && unexpected_approvals == 0,
        "tool_or_approval_order_invalid",
    )?;
    ensure(
        calls[0].name == "computer_v2_open" && calls[0].arguments == fixture.open_arguments,
        "open_arguments_changed",
    )?;
    let opened = text(&calls[0].output)?;
    ensure(
        opened.lines().next() == Some("BOUND_BROWSER_TAB mode=isolated activation=foreground"),
        "owned_open_result_required",
    )?;
    let mut snapshots = std::collections::HashSet::new();
    let mut observed = false;
    for call in &calls[1..] {
        ensure(
            !observed
                && call.name == "computer_v2_read_page"
                && call.arguments == json!({"query":fixture.heading}),
            "read_order_or_arguments_changed",
        )?;
        let (id, found) = snapshot_heading(&text(&call.output)?, &fixture.heading)?;
        ensure(snapshots.insert(id), "snapshot_reused")?;
        observed = found;
    }
    ensure(
        observed && assistant.trim() == fixture.completion_token,
        "heading_or_exact_terminal_missing",
    )?;
    Ok(
        json!({"protocol":"computa-owned-chrome-matrix-v1","trial_id":fixture.trial_id,"file_sha256":fixture.file_sha256,
        "tool_order_verified":true,"snapshot_calls":calls.len()-1,"exact_heading_observed":true,"approved_opens":1,"unexpected_approvals":0,
        "scope_variant":"private owned Chrome file fixture; no extension activation or user tab mutation","current_dom_requires_independent_check":true}),
    )
}
fn frame(value: &Value, fixture: &ChromeFixture) -> Result<Value> {
    let frame = &value["frameTree"]["frame"];
    let valid = |value: &Value| {
        value
            .as_str()
            .is_some_and(|text| !text.is_empty() && text.len() <= 256)
    };
    ensure(
        valid(&frame["id"])
            && valid(&frame["loaderId"])
            && frame["url"] == fixture.url
            && frame["urlFragment"].as_str().is_none_or(str::is_empty),
        "owned_document_changed",
    )?;
    Ok(json!({"id":frame["id"],"loaderId":frame["loaderId"],"url":frame["url"]}))
}
/// Read only the exact native-retained owned receipt. Never attaches a target,
/// navigates, evaluates script, adopts user Chrome or mutates a document.
pub async fn independent_heading(
    controller: &dyn BrowserControl,
    attachment: &Attachment,
    fixture: &ChromeFixture,
) -> Result<Value> {
    verify_file(fixture)?;
    ensure(
        controller.ownership() == BrowserOwnership::Owned && attachment.url == fixture.url,
        "exact_owned_receipt_required",
    )?;
    let inventory = controller.inventory().await?;
    ensure(
        inventory.len() == 1
            && inventory[0].target_id == attachment.target_id
            && inventory[0].url == fixture.url,
        "owned_target_changed",
    )?;
    let before = frame(
        &controller
            .command(&attachment.attachment_token, "Page.getFrameTree", json!({}))
            .await?,
        fixture,
    )?;
    let tree = controller
        .command(
            &attachment.attachment_token,
            "Accessibility.getFullAXTree",
            json!({"depth":64}),
        )
        .await?;
    let nodes = tree["nodes"]
        .as_array()
        .ok_or(QualificationError::Evidence("invalid_ax_response"))?;
    ensure(
        nodes.len() <= 12_000 && tree["macrouseSourceTruncated"] != true,
        "truncated_independent_observation",
    )?;
    let headings = nodes
        .iter()
        .filter(|node| {
            node["ignored"] != true
                && node["role"]["value"] == "heading"
                && node["name"]["value"] == fixture.heading
                && node["frameId"]
                    .as_str()
                    .is_none_or(|id| Some(id) == before["id"].as_str())
        })
        .collect::<Vec<_>>();
    ensure(
        headings.len() == 1
            && headings[0]["nodeId"]
                .as_str()
                .is_some_and(|id| !id.is_empty() && id.len() <= 256),
        "independent_heading_missing_or_duplicate",
    )?;
    let after = frame(
        &controller
            .command(&attachment.attachment_token, "Page.getFrameTree", json!({}))
            .await?,
        fixture,
    )?;
    ensure(before == after, "owned_document_changed")?;
    verify_file(fixture)?;
    Ok(
        json!({"protocol":"computa-owned-chrome-independent-v1","trial_id":fixture.trial_id,"generation":controller.generation(),
        "bridge_epoch":controller.bridge_epoch(),"target_id":attachment.target_id,"frame":before,"heading_node_id":headings[0]["nodeId"],
        "heading":fixture.heading,"file_sha256":fixture.file_sha256,"read_only":true,"owned_identity_checked_by_transport":true}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn ready() -> (tempfile::TempDir, ChromeFixture) {
        let root = tempfile::tempdir().unwrap();
        std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let fixture = prepare(root.path(), Uuid::new_v4()).unwrap();
        (root, fixture)
    }
    fn calls(fixture: &ChromeFixture) -> Vec<QualificationCall> {
        let id = Uuid::new_v4();
        vec![
            QualificationCall {
                name: "computer_v2_open".into(),
                arguments: fixture.open_arguments.clone(),
                output: ToolOutput::text(
                    "BOUND_BROWSER_TAB mode=isolated activation=foreground\nExact owned process.",
                    true,
                ),
            },
            QualificationCall {
                name: "computer_v2_read_page".into(),
                arguments: json!({"query":fixture.heading}),
                output: ToolOutput::text(
                    format!(
                        "AXSNAPSHOT id={id} snapshot_id={id} pid=0 target_generation={}\n#1 r_ref=r_example role=\"AXHeading\" title=\"{}\" utf8={} content_kind=visible_label\n",
                        Uuid::new_v4(),
                        fixture.heading,
                        utf8_range(&fixture.heading)
                    ),
                    true,
                ),
            },
        ]
    }
    #[test]
    fn fixture_and_transcript_require_exact_owned_scope_and_literal_observed_heading() {
        let (root, fixture) = ready();
        assert!(fixture.url.starts_with("file:///"));
        assert!(fixture.prompt.contains("at most 3 snapshot calls"));
        let original = calls(&fixture);
        assert!(verify_tools(&fixture, &original, &fixture.completion_token, 1, 0).is_ok());
        let mut changed = original.clone();
        changed[0].arguments["browser_mode"] = json!("existing");
        assert!(verify_tools(&fixture, &changed, &fixture.completion_token, 1, 0).is_err());
        let mut changed = original.clone();
        changed.push(changed[1].clone());
        assert!(verify_tools(&fixture, &changed, &fixture.completion_token, 1, 0).is_err());
        let mut changed = original.clone();
        let valid_id = Uuid::new_v4();
        changed[1].output = ToolOutput::text(
            format!(
                "AXSNAPSHOT id={} snapshot_id={}\n#1 role=\"AXStaticText\" title=\"role=\\\"AXHeading\\\" {}\" utf8={}\n",
                valid_id,
                valid_id,
                fixture.heading,
                utf8_range(&fixture.heading)
            ),
            true,
        );
        assert!(verify_tools(&fixture, &changed, &fixture.completion_token, 1, 0).is_err());
        std::fs::write(root.path().join("chrome-qualification.html"), "replacement").unwrap();
        assert!(verify_tools(&fixture, &original, &fixture.completion_token, 1, 0).is_err());
    }
    struct RecordedOwned {
        fixture: ChromeFixture,
        changed: bool,
        borrowed: bool,
        calls: std::sync::Mutex<usize>,
    }
    #[async_trait::async_trait]
    impl BrowserControl for RecordedOwned {
        fn generation(&self) -> Uuid {
            Uuid::nil()
        }
        fn bridge_epoch(&self) -> Uuid {
            Uuid::nil()
        }
        fn ownership(&self) -> BrowserOwnership {
            if self.borrowed {
                BrowserOwnership::Borrowed
            } else {
                BrowserOwnership::Owned
            }
        }
        async fn inventory(
            &self,
        ) -> std::result::Result<Vec<crate::leases::Candidate>, BrowserError> {
            Ok(vec![crate::leases::Candidate {
                target_id: "target".into(),
                title: self.fixture.heading.clone(),
                url: self.fixture.url.clone(),
                availability: "busy".into(),
            }])
        }
        async fn attach(&self, _: &str) -> std::result::Result<Attachment, BrowserError> {
            panic!("independent oracle must never attach")
        }
        async fn command(
            &self,
            _: &str,
            method: &str,
            params: Value,
        ) -> std::result::Result<Value, BrowserError> {
            let mut calls = self.calls.lock().unwrap();
            *calls += 1;
            Ok(match method {
                "Page.getFrameTree" => {
                    assert_eq!(params, json!({}));
                    json!({"frameTree":{"frame":{"id":"frame","loaderId":if self.changed&&*calls==3{"changed"}else{"loader"},"url":self.fixture.url}}})
                }
                "Accessibility.getFullAXTree" => {
                    assert_eq!(params, json!({"depth":64}));
                    json!({"nodes":[{"nodeId":"heading","frameId":"frame","role":{"value":"heading"},"name":{"value":self.fixture.heading}}]})
                }
                _ => panic!("unexpected read or mutation"),
            })
        }
        async fn detach(&self, _: &str) -> std::result::Result<(), BrowserError> {
            panic!("independent oracle must never detach")
        }
        async fn shutdown(&self) -> Vec<Value> {
            panic!("independent oracle must never terminate")
        }
    }
    #[tokio::test]
    async fn independent_oracle_uses_only_retained_owned_read_receipt_and_rejects_loader_replacement()
     {
        let (_root, fixture) = ready();
        let attachment = Attachment {
            attachment_token: Uuid::new_v4().to_string(),
            target_id: "target".into(),
            title: fixture.heading.clone(),
            url: fixture.url.clone(),
        };
        for (changed, borrowed) in [(false, false), (true, false), (false, true)] {
            let controller = RecordedOwned {
                fixture: fixture.clone(),
                changed,
                borrowed,
                calls: Default::default(),
            };
            let result = independent_heading(&controller, &attachment, &fixture).await;
            assert_eq!(result.is_ok(), !changed && !borrowed);
            assert_eq!(
                *controller.calls.lock().unwrap(),
                if borrowed { 0 } else { 3 }
            );
        }
    }
}

use crate::{
    activity::{self, ActivityRow},
    markdown::{self, escape},
    queue::{self, PendingSubmission},
};
use computa_contracts::{
    Identifier,
    ui::{
        AppSnapshot, EntryKind, EntrySnapshot, NativeAction, QueuedPromptStatus, TaskSnapshot, Tone,
    },
};
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub enum UiAction {
    Native(NativeAction),
    Submit(Identifier),
    Suggest(Identifier, String),
    ClearSearch,
    ToggleActivity(String, bool),
    BeginEdit(Identifier, Identifier, String),
    SaveEdit(Identifier, Identifier),
    CancelEdit(Identifier, Identifier),
    Move(Identifier, Identifier, i32),
}
#[derive(Default)]
pub struct LocalState {
    pub search: String,
    pub drafts: HashMap<Identifier, String>,
    pub pending: HashMap<Identifier, PendingSubmission>,
    pub errors: HashMap<Identifier, String>,
    pub activity_open: HashMap<String, bool>,
    pub edits: HashMap<Identifier, (Identifier, String)>,
    pub following: bool,
    pub dragged: Option<Identifier>,
}
pub struct Rendered {
    pub html: String,
    pub actions: Vec<UiAction>,
}
struct Renderer {
    html: String,
    actions: Vec<UiAction>,
}
impl Renderer {
    fn push(&mut self, value: &str) {
        self.html.push_str(value);
    }
    fn action(&mut self, action: UiAction) -> String {
        let id = self.actions.len();
        self.actions.push(action);
        format!("data-action=\"{id}\"")
    }
    fn button(&mut self, label: &str, class: &str, action: UiAction, disabled: bool) {
        let attr = self.action(action);
        self.push(&format!(
            "<button type=\"button\" class=\"{}\" {} {}>{}</button>",
            escape(class),
            attr,
            if disabled { "disabled" } else { "" },
            escape(label)
        ));
    }
    fn native(&mut self, label: &str, class: &str, action: NativeAction) {
        self.button(label, class, UiAction::Native(action), false);
    }
}
pub fn render(snapshot: &AppSnapshot, local: &LocalState, now: f64) -> Rendered {
    let mut r = Renderer {
        html: String::new(),
        actions: Vec::new(),
    };
    let inert = snapshot.is_settings_presented || snapshot.pending_approval_count > 0;
    r.push(&format!(
        "<div class=\"app-shell\"><div class=\"app-panels\" {}>",
        if inert { "inert" } else { "" }
    ));
    r.push("<aside class=\"sidebar\" aria-label=\"Task navigation\"><div class=\"window-drag-strip\"></div><div class=\"sidebar-brand-row\"><strong>Computa</strong></div><nav class=\"primary-nav\" aria-label=\"Primary\">");
    r.native(
        "New task  ⇧⌘N",
        "nav-button new-task-button",
        NativeAction::CreateTask,
    );
    if snapshot.pending_approval_count > 0 {
        r.push(&format!(
            "<div class=\"approval-nav\" role=\"status\">Native approval · {}</div>",
            snapshot.pending_approval_count
        ));
    }
    r.push(&format!("</nav><div class=\"task-search\"><input id=\"task-search\" class=\"task-search-input\" data-field=\"search\" aria-label=\"Search tasks\" placeholder=\"Search tasks\" value=\"{}\">",escape(&local.search)));
    if !local.search.is_empty() {
        r.button("Clear search", "icon-button", UiAction::ClearSearch, false);
    }
    r.push("</div><div class=\"sidebar-section-heading\">Tasks</div><div class=\"task-list\" aria-label=\"Tasks\">");
    let needle = local.search.trim().to_lowercase();
    let mut count = 0;
    for task in &snapshot.tasks {
        if !needle.is_empty()
            && !format!("{} {} {}", task.title, task.summary, task.workspace)
                .to_lowercase()
                .contains(&needle)
        {
            continue;
        }
        count += 1;
        let attr = r.action(UiAction::Native(NativeAction::SelectTask {
            id: task.id.clone(),
        }));
        r.push(&format!("<button type=\"button\" class=\"task-row {}\" {} {}><span class=\"task-row-title\">{}</span><span class=\"task-row-status {}\" aria-hidden=\"true\"></span><span class=\"sr-only\">{}</span><span class=\"task-row-time\">{}</span></button>",if snapshot.selected_task_id.as_ref()==Some(&task.id){"selected"}else{""},attr,if snapshot.selected_task_id.as_ref()==Some(&task.id){"aria-current=\"page\""}else{""},escape(&task.title),tone(task.status_tone),escape(&task.status),relative_time(task.updated_at,now)));
    }
    if count == 0 {
        r.push("<div class=\"sidebar-empty\">No tasks found</div>");
    }
    r.push(&format!("</div><div class=\"sidebar-footer\"><div class=\"runtime-state\"><span class=\"connection-dot {}\"></span><span>{}</span></div>",tone(snapshot.connection.tone),escape(&snapshot.connection.label)));
    r.native("Settings  ⌘,", "profile-button", NativeAction::ShowSettings);
    r.push("</div></aside><main class=\"workspace\">");
    let task = snapshot
        .tasks
        .iter()
        .find(|t| snapshot.selected_task_id.as_ref() == Some(&t.id));
    r.push(&format!(
        "<header class=\"task-toolbar\"><strong>{}</strong><div class=\"toolbar-actions\">",
        escape(
            task.map(|t| if t.title == "Untitled task" {
                "New task"
            } else {
                &t.title
            })
            .unwrap_or("Computa")
        )
    ));
    if let Some(task) = task {
        r.push(&format!(
            "<span class=\"status-label {}\">{}</span>",
            tone(task.status_tone),
            escape(&task.status)
        ));
    }
    r.native("Inspector", "icon-button", NativeAction::ToggleInspector);
    r.native("Browser", "icon-button", NativeAction::ToggleBrowser);
    r.push("</div></header>");
    if let Some(task) = task {
        conversation(&mut r, snapshot, local, task, now);
    } else {
        r.push("<div class=\"no-task-view\"><h1>Computa</h1><p>Fast, Mac-optimized local AI.</p>");
        r.native("New task", "new-task-button", NativeAction::CreateTask);
        r.push("</div>");
    }
    r.push("</main>");
    if snapshot.is_inspector_presented
        && let Some(task) = task
    {
        inspector(&mut r, snapshot, task, now);
    }
    r.push("</div>");
    if snapshot.is_settings_presented && snapshot.pending_approval_count == 0 {
        settings(&mut r, snapshot);
    }
    r.push("</div>");
    Rendered {
        html: r.html,
        actions: r.actions,
    }
}
fn tone(tone: Tone) -> &'static str {
    match tone {
        Tone::Neutral => "tone-neutral",
        Tone::Blue => "tone-blue",
        Tone::Green => "tone-green",
        Tone::Orange => "tone-orange",
        Tone::Red => "tone-red",
        Tone::Purple => "tone-purple",
    }
}
pub fn relative_time(timestamp: f64, now: f64) -> String {
    let seconds = if timestamp.is_finite() && now.is_finite() {
        (now - timestamp).max(0.0).round() as u64
    } else {
        0
    };
    if seconds < 15 {
        "now".into()
    } else if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86400 {
        format!("{}h", seconds / 3600)
    } else {
        format!("{}d", seconds / 86400)
    }
}
fn entry(r: &mut Renderer, snapshot: &AppSnapshot, e: &EntrySnapshot, hide_timing: bool) {
    let selected = snapshot.selected_entry_id.as_ref() == Some(&e.id);
    let attr = r.action(UiAction::Native(NativeAction::SelectEntry {
        id: e.id.clone(),
    }));
    let class = match e.kind {
        EntryKind::User => "user-message",
        EntryKind::Tool => "tool-message",
        EntryKind::System => "system-message",
        _ => "assistant-message",
    };
    r.push(&format!(
        "<article class=\"message-row {class} {}\" {} tabindex=\"0\" aria-label=\"{}\">",
        if selected { "selected" } else { "" },
        attr,
        if e.kind == EntryKind::User {
            "User message"
        } else {
            "Assistant response"
        }
    ));
    match e.kind {
        EntryKind::User => r.push(&format!(
            "<span class=\"user-bubble\">{}</span>",
            escape(&e.body)
        )),
        EntryKind::System => r.push(&format!(
            "<div><strong>{}</strong><p>{}</p></div>",
            escape(&e.title),
            escape(&e.body)
        )),
        EntryKind::Tool => tool(r, e, snapshot.show_tool_payloads),
        _ => {
            if !hide_timing
                && let Some(seconds) = e.worked_for_seconds.filter(|s| s.is_finite() && *s >= 0.0)
            {
                r.push(&format!(
                    "<div class=\"assistant-metadata\">Worked for {}</div>",
                    activity::format_duration(seconds)
                ));
            }
            r.push(&format!(
                "<div class=\"assistant-copy\">{}</div>",
                markdown::render(&e.body)
            ));
        }
    }
    r.push("</article>");
}
fn tool(r: &mut Renderer, e: &EntrySnapshot, payload: bool) {
    if let Some(t) = &e.tool {
        r.push(&format!("<details class=\"tool-card\" {}><summary><span class=\"tool-labels\"><strong class=\"tool-title\">{}</strong><span class=\"tool-summary\">{}</span></span><span class=\"tool-status {}\">{}</span></summary><div class=\"tool-expanded-summary\"><span>{}</span><p>{}</p></div>",if t.status=="Needs approval"{"open"}else{""},escape(&t.name),escape(&t.summary),tone(t.tone),escape(&t.status),escape(&t.name),escape(&t.summary)));
        if payload || t.name == "commandExecution" {
            r.push(&format!(
                "<div class=\"tool-payload\"><div><span>Input</span><pre>{}</pre></div>",
                escape(&t.input)
            ));
            if let Some(out) = &t.output {
                r.push(&format!(
                    "<div><span>Output</span><pre>{}</pre></div>",
                    escape(out)
                ));
            }
            r.push("</div>");
        }
        r.push("</details>");
    }
}
fn conversation(r: &mut Renderer, s: &AppSnapshot, l: &LocalState, t: &TaskSnapshot, now: f64) {
    let rows = activity::timeline(t);
    r.push("<div class=\"conversation-column\"><div class=\"conversation-scroll\" id=\"conversation-scroll\"><div class=\"conversation-content\">");
    if rows.is_empty() {
        r.push("<div class=\"empty-conversation\"><h1>How can I help?</h1><p>Ask a question or give your Mac a task.</p><div class=\"suggestion-grid\">");
        r.button(
            "Check setup",
            "suggestion",
            UiAction::Suggest(
                t.id.clone(),
                "Check computer-use permissions and tell me what is available.".into(),
            ),
            false,
        );
        r.button(
            "Explore apps",
            "suggestion",
            UiAction::Suggest(
                t.id.clone(),
                "List the running applications and summarize what is available.".into(),
            ),
            false,
        );
        r.push("</div></div>");
    }
    for row in rows {
        match row {
            ActivityRow::Entry {
                entry: e,
                hide_answer_metadata,
            } => entry(r, s, &e, hide_answer_metadata),
            ActivityRow::Activity(group) => {
                let key = format!("{}:{}", t.id.as_str(), group.id);
                let open = activity::disclosure_open(
                    group.is_running,
                    group.has_final_answer,
                    l.activity_open.get(&key).copied(),
                );
                let attr = r.action(UiAction::ToggleActivity(key, !open));
                r.push(&format!("<article class=\"message-row activity-message\"><details class=\"reasoning-disclosure {}\" {}><summary {}><span class=\"reasoning-label\" data-clock-start=\"{}\">{}</span> ›</summary><div class=\"activity-body\" role=\"region\" aria-label=\"Activity\">",if group.is_running&&!group.has_final_answer{"is-streaming"}else{""},if open{"open"}else{""},attr,group.started_at.filter(|_|group.is_running&&group.worked_for_seconds.is_none()).map(|n|n.to_string()).unwrap_or_default(),escape(&activity::label(&group,now))));
                if group.entries.is_empty() {
                    r.push("<span class=\"activity-placeholder\">Preparing response…</span>");
                }
                for e in group.entries {
                    entry(r, s, &e, true);
                }
                r.push("</div></details></article>");
            }
        }
    }
    r.push("</div></div><div class=\"composer-zone\">");
    queue_view(r, t, l);
    let value = l.drafts.get(&t.id).map(String::as_str).unwrap_or("");
    let pending = l.pending.contains_key(&t.id);
    let can_submit = !pending
        && queue::valid_prompt(value)
        && (t.model_selectable || t.is_busy || t.queue_paused || !t.queued_prompts.is_empty());
    r.push(&format!("<div class=\"composer-shell\"><textarea id=\"task-prompt\" data-field=\"prompt\" data-task=\"{}\" rows=\"2\" maxlength=\"200000\" aria-label=\"Task prompt\" placeholder=\"{}\">{}</textarea><div class=\"composer-controls\"><div class=\"composer-left\">",escape(t.id.as_str()),if t.is_busy{"Type your next message to queue it…"}else{"Ask a question or describe a task…"},escape(value)));
    model_select(
        r,
        s,
        "task-model",
        &t.model,
        t.model_selectable,
        Some(&t.id),
    );
    r.push("</div><div class=\"composer-right\"><span class=\"send-shortcut\">↵</span>");
    if t.status == "Running" {
        r.native(
            "Stop",
            "stop-button",
            NativeAction::InterruptTask {
                task_id: t.id.clone(),
            },
        );
    }
    r.button(
        if t.is_busy || t.queue_paused || !t.queued_prompts.is_empty() {
            "Queue"
        } else {
            "Send"
        },
        "send-button",
        UiAction::Submit(t.id.clone()),
        !can_submit,
    );
    r.push("</div></div></div>");
    if let Some(error) = l.errors.get(&t.id) {
        r.push(&format!(
            "<span class=\"composer-submit-status tone-red\" role=\"status\">{}</span>",
            escape(error)
        ));
    } else if pending {
        r.push("<span class=\"composer-submit-status\" role=\"status\">Submitting…</span>");
    }
    if s.model_options
        .iter()
        .any(|o| o.id == t.model && o.high_memory)
    {
        r.push("<span class=\"composer-memory-warning\">35B needs a separate download and may exceed available memory on this Mac.</span>");
    }
    r.push("</div></div>");
}
fn model_select(
    r: &mut Renderer,
    s: &AppSnapshot,
    field: &str,
    model: &computa_contracts::models::ModelId,
    enabled: bool,
    task: Option<&Identifier>,
) {
    let selected = s.model_options.iter().find(|o| o.id == *model);
    r.push(&format!("<select class=\"model-picker\" data-field=\"{}\" data-task=\"{}\" aria-label=\"{}\" title=\"{}\" {}>",field,task.map(Identifier::as_str).unwrap_or(""),if field=="task-model"{"Task model"}else{"Default model for new tasks"},escape(selected.map(|o|o.detail.as_str()).unwrap_or(model.as_str())),if enabled{""}else{"disabled"}));
    if selected.is_none() {
        r.push(&format!(
            "<option value=\"{}\" selected>{}</option>",
            escape(model.as_str()),
            escape(model.as_str())
        ));
    }
    for o in &s.model_options {
        r.push(&format!(
            "<option value=\"{}\" {}>{}</option>",
            escape(o.id.as_str()),
            if o.id == *model { "selected" } else { "" },
            escape(o.label.split(" · ").next().unwrap_or(&o.label))
        ));
    }
    r.push("</select>");
}
fn queue_view(r: &mut Renderer, t: &TaskSnapshot, l: &LocalState) {
    if t.queued_prompts.is_empty() {
        return;
    }
    r.push(&format!("<section class=\"prompt-queue\" aria-label=\"Queued messages\" data-drop-task=\"{}\"><div class=\"queue-header\"><strong>Up next · {}</strong>",escape(t.id.as_str()),t.queued_prompts.len()));
    if t.queue_paused {
        r.native(
            "Resume queue",
            "queue-resume-button",
            NativeAction::ResumeQueue {
                task_id: t.id.clone(),
            },
        );
    }
    r.push("</div>");
    if t.queue_paused
        || t.queued_prompts
            .iter()
            .any(|i| i.status == QueuedPromptStatus::Failed)
    {
        r.push("<div class=\"queue-warning\" role=\"status\">The queue is paused or delivery is uncertain and may already have happened. Review the message before resuming or resending.</div>");
    }
    for (index, item) in t.queued_prompts.iter().enumerate() {
        let locked = item.status == QueuedPromptStatus::Sending;
        let edit = l.edits.get(&t.id).filter(|(id, _)| *id == item.id);
        let native_edit = item.status == QueuedPromptStatus::Editing;
        r.push(&format!(
            "<div class=\"queue-item\" draggable=\"{}\" data-queue-id=\"{}\" data-task=\"{}\">",
            !locked && edit.is_none() && !native_edit,
            escape(item.id.as_str()),
            escape(t.id.as_str())
        ));
        if edit.is_some() || native_edit {
            let value = edit.map(|(_, text)| text.as_str()).unwrap_or(&item.text);
            r.push(&format!("<div class=\"queue-edit\"><textarea data-field=\"queue-edit\" data-task=\"{}\" data-item=\"{}\" rows=\"2\" maxlength=\"200000\" aria-label=\"Edit queued message\">{}</textarea>",escape(t.id.as_str()),escape(item.id.as_str()),escape(value)));
            r.button(
                "Cancel",
                "queue-edit-action",
                UiAction::CancelEdit(t.id.clone(), item.id.clone()),
                false,
            );
            r.button(
                "Save",
                "queue-edit-action",
                UiAction::SaveEdit(t.id.clone(), item.id.clone()),
                !queue::valid_prompt(value),
            );
            r.push("</div>");
        } else {
            r.push(&format!("<div class=\"queue-item-copy\"><span class=\"queue-item-text\">{}</span><span class=\"queue-item-status\">{}</span>",escape(&item.text),match item.status{QueuedPromptStatus::Queued=>"Queued",QueuedPromptStatus::Editing=>"Editing",QueuedPromptStatus::Sending=>"Sending",QueuedPromptStatus::Failed=>"Needs attention"}));
            if let Some(error) = &item.error {
                r.push(&format!(
                    "<span class=\"queue-item-error\">{}</span>",
                    escape(error)
                ));
            }
            r.push("</div><details class=\"queue-menu-content\"><summary aria-label=\"Queued message actions\">•••</summary>");
            if t.can_steer && item.status == QueuedPromptStatus::Queued {
                r.native(
                    "Steer into current turn",
                    "queue-action",
                    NativeAction::SteerQueuedPrompt {
                        task_id: t.id.clone(),
                        id: item.id.clone(),
                    },
                );
            }
            r.button(
                "Move up",
                "queue-action",
                UiAction::Move(t.id.clone(), item.id.clone(), -1),
                locked
                    || index == 0
                    || t.queued_prompts
                        .get(index.wrapping_sub(1))
                        .is_some_and(|i| i.status == QueuedPromptStatus::Sending),
            );
            r.button(
                "Move down",
                "queue-action",
                UiAction::Move(t.id.clone(), item.id.clone(), 1),
                locked || index + 1 == t.queued_prompts.len(),
            );
            r.button(
                "Edit",
                "queue-action",
                UiAction::BeginEdit(t.id.clone(), item.id.clone(), item.text.clone()),
                locked || l.edits.get(&t.id).is_some_and(|(id, _)| *id != item.id),
            );
            r.button(
                "Delete",
                "queue-action",
                UiAction::Native(NativeAction::DeleteQueuedPrompt {
                    task_id: t.id.clone(),
                    id: item.id.clone(),
                }),
                locked,
            );
            r.push("</details>");
        }
        r.push("</div>");
    }
    r.push("</section>");
}
fn inspector(r: &mut Renderer, s: &AppSnapshot, t: &TaskSnapshot, now: f64) {
    let e = t
        .entries
        .iter()
        .find(|e| s.selected_entry_id.as_ref() == Some(&e.id));
    r.push("<aside class=\"inspector\" aria-label=\"Task inspector\"><div class=\"inspector-header\"><strong>Details</strong>");
    r.native(
        "Close inspector",
        "icon-button",
        NativeAction::ToggleInspector,
    );
    r.push(&format!("</div><div class=\"inspector-scroll\"><section class=\"inspector-section\"><h2>Task</h2><dl><dt>Status</dt><dd>{}</dd><dt>Model</dt><dd>{}</dd><dt>Workspace</dt><dd class=\"mono\">{}</dd><dt>Updated</dt><dd>{}</dd></dl></section><section class=\"inspector-section\"><h2>Selected event</h2>",escape(&t.status),escape(t.model.as_str()),escape(&t.workspace),relative_time(t.updated_at,now)));
    if let Some(e) = e {
        r.push(&format!(
            "<strong>{}</strong><div class=\"inspector-event-copy\">{}</div>",
            escape(&e.title),
            escape(&e.body)
        ));
        if s.show_tool_payloads
            && let Some(tool) = &e.tool
        {
            r.push(&format!(
                "<div class=\"inspector-payload\">Input<pre>{}</pre></div>",
                escape(&tool.input)
            ));
        }
    } else {
        r.push("<p>Select a transcript event to inspect it.</p>");
    }
    r.push("</section></div></aside>");
}
fn settings(r: &mut Renderer, s: &AppSnapshot) {
    use computa_contracts::ui::{AccessMode, Appearance, PermissionStatus};
    r.push("<div class=\"modal-backdrop\" role=\"presentation\"><section class=\"settings-modal\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"settings-title\"><header><h1 id=\"settings-title\">Settings</h1>");
    r.native(
        "Close settings",
        "icon-button",
        NativeAction::DismissSettings,
    );
    r.push("</header><div class=\"settings-content\"><section><h2>Appearance</h2><label class=\"setting-row\"><strong>Color scheme</strong><select data-field=\"appearance\" aria-label=\"Color scheme\">");
    for (value, label, mode) in [
        ("system", "System", Appearance::System),
        ("light", "Light", Appearance::Light),
        ("dark", "Dark", Appearance::Dark),
    ] {
        r.push(&format!(
            "<option value=\"{value}\" {}>{label}</option>",
            if mode == s.appearance { "selected" } else { "" }
        ));
    }
    r.push("</select></label></section><section><h2>Local runtime</h2><label class=\"setting-row\"><strong>Default model</strong>");
    model_select(r, s, "default-model", &s.default_model, true, None);
    r.push("</label>");
    if let Some(model) = s.model_options.iter().find(|o| o.id == s.default_model) {
        r.push(&format!(
            "<p class=\"model-note\">{}</p>",
            escape(&model.detail)
        ));
    }
    r.push(&format!("<div class=\"setting-row\">Connection <span>{}</span></div></section><section><h2>Agent interface</h2><label class=\"setting-row\"><strong>Show tool input and output</strong><input type=\"checkbox\" role=\"switch\" data-field=\"payloads\" aria-label=\"Show tool input and output\" {}></label><div class=\"setting-row\"><span><strong>Access mode</strong><small>Close Settings to change this using the native menu at the bottom of the app.</small></span><span>{}</span></div></section><section><h2>Computer use</h2><p>New tasks use the latest computer tools. Existing task history is kept.</p>",escape(&s.connection.label),if s.show_tool_payloads{"checked"}else{""},if s.access_mode==AccessMode::FullAccess{"Full access"}else{"Ask every time"}));
    for (label, status, action) in [
        (
            "Accessibility",
            s.permissions.accessibility,
            NativeAction::RequestAccessibilityPermission,
        ),
        (
            "Screen Recording",
            s.permissions.screen_recording,
            NativeAction::RequestScreenRecordingPermission,
        ),
    ] {
        let granted = status == PermissionStatus::Granted;
        r.push(&format!("<div class=\"setting-row permission-row\"><strong>{label}</strong><span class=\"permission-controls\"><span>{}</span>",if granted{"Granted"}else{"Not granted"}));
        r.button(
            if granted { "Granted" } else { "Request access" },
            "permission-request-button",
            UiAction::Native(action),
            granted,
        );
        r.push("</span></div>");
    }
    r.push("<details class=\"permission-help\"><summary>About computer access</summary><p>macOS permissions are separate from access mode. Both modes keep tool validation and permission checks. Access mode resets to Ask every time when you relaunch.</p></details>");
    r.native(
        "Refresh permission status",
        "refresh-button",
        NativeAction::RefreshPermissions,
    );
    r.push("</section></div><footer>");
    r.native("Done", "button", NativeAction::DismissSettings);
    r.push("</footer></section></div>");
}

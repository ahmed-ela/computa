use crate::{
    activity, queue,
    render::{self, LocalState, UiAction},
};
use computa_contracts::{
    Identifier,
    models::ModelId,
    ui::{AppSnapshot, Appearance, NativeAction, QueuedPromptStatus},
};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{JsCast, prelude::*};
use web_sys::{
    Document, Element, Event, HtmlElement, HtmlInputElement, HtmlSelectElement,
    HtmlTextAreaElement, KeyboardEvent,
};

type FocusKey = (String, Option<String>, Option<String>, Option<String>);
struct App {
    snapshot: Option<AppSnapshot>,
    local: LocalState,
    actions: Vec<UiAction>,
    listeners: Vec<Closure<dyn FnMut(Event)>>,
    receive: Option<Closure<dyn FnMut(JsValue)>>,
    clock: Option<Closure<dyn FnMut()>>,
    composing: bool,
    settings_visible: bool,
    return_focus: Option<FocusKey>,
}
thread_local! {static APP:RefCell<Option<Rc<RefCell<App>>>>=const{RefCell::new(None)};}
fn document() -> Result<Document, JsValue> {
    web_sys::window()
        .and_then(|w| w.document())
        .ok_or_else(|| JsValue::from_str("Document unavailable"))
}
fn identifier(value: Option<String>) -> Option<Identifier> {
    Identifier::new(value?).ok()
}
fn target(event: &Event) -> Option<Element> {
    event.target()?.dyn_into::<Element>().ok()
}
fn report(error: JsValue) {
    web_sys::console::error_1(&error);
}
fn post(action: &NativeAction) -> Result<(), JsValue> {
    let window = web_sys::window().ok_or_else(|| JsValue::from_str("Native bridge unavailable"))?;
    let ipc = js_sys::Reflect::get(&window, &JsValue::from_str("ipc"))?;
    let function = js_sys::Reflect::get(&ipc, &JsValue::from_str("postMessage"))?
        .dyn_into::<js_sys::Function>()?;
    let payload =
        serde_json::to_string(action).map_err(|_| JsValue::from_str("Invalid native action"))?;
    function.call1(&ipc, &JsValue::from_str(&payload))?;
    Ok(())
}

#[wasm_bindgen(start)]
pub fn start() -> Result<(), JsValue> {
    let root_document = document()?;
    let app = Rc::new(RefCell::new(App {
        snapshot: None,
        local: LocalState {
            following: true,
            ..Default::default()
        },
        actions: Vec::new(),
        listeners: Vec::new(),
        receive: None,
        clock: None,
        composing: false,
        settings_visible: false,
        return_focus: None,
    }));
    APP.with(|slot| *slot.borrow_mut() = Some(app.clone()));
    let root = root_document
        .get_element_by_id("root")
        .ok_or_else(|| JsValue::from_str("Missing interface root"))?;
    root.set_inner_html("<main class=\"loading-view\"><strong>Starting Computa</strong><span>Connecting the native runtime…</span></main>");
    let receive_app = app.clone();
    let receiver =
        Closure::wrap(Box::new(move |value: JsValue| {
            match serde_wasm_bindgen::from_value::<AppSnapshot>(value) {
                Ok(snapshot) => {
                    receive_snapshot(&receive_app, snapshot);
                    if let Err(error) = redraw(&receive_app) {
                        report(error);
                    }
                }
                Err(_) => report(JsValue::from_str("Invalid native snapshot")),
            }
        }) as Box<dyn FnMut(JsValue)>);
    js_sys::Reflect::set(
        &web_sys::window().unwrap(),
        &JsValue::from_str("__localCodexReceiveState"),
        receiver.as_ref(),
    )?;
    app.borrow_mut().receive = Some(receiver);
    for name in [
        "click",
        "input",
        "keydown",
        "scroll",
        "dragstart",
        "dragover",
        "drop",
        "dragend",
        "compositionstart",
        "compositionend",
    ] {
        let event_app = app.clone();
        let kind = name.to_owned();
        let listener = Closure::wrap(Box::new(move |event: Event| {
            if let Err(error) = handle(&event_app, &kind, event) {
                report(error);
            }
        }) as Box<dyn FnMut(Event)>);
        root_document.add_event_listener_with_callback_and_bool(
            name,
            listener.as_ref().unchecked_ref(),
            name == "scroll",
        )?;
        app.borrow_mut().listeners.push(listener);
    }
    let clock = Closure::wrap(Box::new(move || {
        if let Ok(document) = document() {
            if let Ok(nodes) = document.query_selector_all("[data-clock-start]") {
                for i in 0..nodes.length() {
                    if let Some(element) = nodes.item(i).and_then(|n| n.dyn_into::<Element>().ok())
                    {
                        if let Some(start) = element
                            .get_attribute("data-clock-start")
                            .and_then(|s| s.parse::<f64>().ok())
                            .filter(|n| n.is_finite())
                        {
                            element.set_text_content(Some(&format!(
                                "Working for {}",
                                activity::format_duration(js_sys::Date::now() / 1000.0 - start)
                            )));
                        }
                    }
                }
            }
        }
    }) as Box<dyn FnMut()>);
    web_sys::window()
        .unwrap()
        .set_interval_with_callback_and_timeout_and_arguments_0(
            clock.as_ref().unchecked_ref(),
            1000,
        )?;
    app.borrow_mut().clock = Some(clock);
    if post(&NativeAction::Ready).is_err() {
        root.set_inner_html("<main class=\"loading-view\" role=\"alert\"><strong>Native bridge unavailable</strong><span>Open this interface from the Computa macOS application.</span></main>");
    }
    Ok(())
}

fn receive_snapshot(app: &Rc<RefCell<App>>, snapshot: AppSnapshot) {
    let mut app = app.borrow_mut();
    if app
        .snapshot
        .as_ref()
        .is_some_and(|old| old.revision > snapshot.revision)
    {
        return;
    }
    if app
        .snapshot
        .as_ref()
        .and_then(|s| s.selected_task_id.as_ref())
        != snapshot.selected_task_id.as_ref()
    {
        app.local.following = true;
    }
    let pending: Vec<_> = app
        .local
        .pending
        .iter()
        .map(|(id, p)| (id.clone(), p.clone()))
        .collect();
    for (task, pending) in pending {
        let current = app
            .local
            .drafts
            .get(&task)
            .map(String::as_str)
            .unwrap_or("");
        if let Some(result) =
            queue::resolve_receipt(current, &pending, &task, &snapshot.prompt_receipts)
        {
            app.local.drafts.insert(task.clone(), result.draft);
            app.local.pending.remove(&task);
            match result.error {
                Some(error) => {
                    app.local.errors.insert(task, error);
                }
                None => {
                    app.local.errors.remove(&task);
                }
            }
        }
    }
    app.snapshot = Some(snapshot);
}

fn redraw(app: &Rc<RefCell<App>>) -> Result<(), JsValue> {
    let document = document()?;
    let mut app = app.borrow_mut();
    if app.composing
        && app
            .snapshot
            .as_ref()
            .is_some_and(|s| s.pending_approval_count == 0)
    {
        return Ok(());
    }
    let Some(snapshot) = app.snapshot.clone() else {
        return Ok(());
    };
    let active = document.active_element();
    let focus = active.as_ref().map(|e| {
        (
            e.id(),
            e.get_attribute("data-field"),
            e.get_attribute("data-task"),
            e.get_attribute("data-item"),
        )
    });
    let selection = active
        .as_ref()
        .and_then(|e| e.dyn_ref::<HtmlTextAreaElement>())
        .map(|e| {
            (
                e.selection_start().ok().flatten(),
                e.selection_end().ok().flatten(),
            )
        });
    let scroll = document
        .get_element_by_id("conversation-scroll")
        .and_then(|e| e.dyn_into::<HtmlElement>().ok())
        .map(|e| e.scroll_top());
    let approvals = snapshot.pending_approval_count > 0;
    let settings = snapshot.is_settings_presented && !approvals;
    let entering_settings = settings && !app.settings_visible;
    let leaving_settings = !settings && app.settings_visible;
    if entering_settings {
        app.return_focus = focus.clone();
    }
    app.settings_visible = settings;
    let appearance = match snapshot.appearance {
        Appearance::System => "system",
        Appearance::Light => "light",
        Appearance::Dark => "dark",
    };
    if let Some(root) = document.document_element() {
        root.set_attribute("data-appearance", appearance)?;
    }
    let rendered = render::render(&snapshot, &app.local, js_sys::Date::now() / 1000.0);
    document
        .get_element_by_id("root")
        .ok_or_else(|| JsValue::from_str("Missing interface root"))?
        .set_inner_html(&rendered.html);
    app.actions = rendered.actions;
    if let Some(element) = document
        .get_element_by_id("conversation-scroll")
        .and_then(|e| e.dyn_into::<HtmlElement>().ok())
    {
        element.set_scroll_top(if app.local.following {
            element.scroll_height()
        } else {
            scroll.unwrap_or_default()
        });
    }
    if !approvals {
        if let Some(key) = if leaving_settings {
            app.return_focus.take()
        } else {
            focus
        } {
            let element = focus_element(&document, &key);
            if let Some(element) = element {
                if let Some(html) = element.dyn_ref::<HtmlElement>() {
                    html.focus()?;
                }
                if let (Some(textarea), Some((Some(start), Some(end)))) =
                    (element.dyn_ref::<HtmlTextAreaElement>(), selection)
                {
                    textarea.set_selection_range(start, end)?;
                }
            }
        }
    }
    if entering_settings {
        if let Some(control) = document
            .query_selector(
                "[role=dialog] button:not(:disabled),[role=dialog] select:not(:disabled)",
            )?
            .and_then(|e| e.dyn_into::<HtmlElement>().ok())
        {
            control.focus()?;
        }
    } else if leaving_settings
        && document
            .active_element()
            .is_none_or(|e| e.tag_name() == "BODY")
    {
        if let Some(prompt) = document
            .get_element_by_id("task-prompt")
            .and_then(|e| e.dyn_into::<HtmlElement>().ok())
        {
            prompt.focus()?;
        }
    }
    if let Some(textarea) = document
        .get_element_by_id("task-prompt")
        .and_then(|e| e.dyn_into::<HtmlTextAreaElement>().ok())
    {
        textarea.style().set_property("height", "auto")?;
        textarea.style().set_property(
            "height",
            &format!("{}px", textarea.scroll_height().min(200)),
        )?;
    }
    Ok(())
}
fn focus_element(document: &Document, key: &FocusKey) -> Option<Element> {
    let (id, field, task, item) = key;
    if !id.is_empty() {
        return document.get_element_by_id(id);
    }
    if field.is_none() {
        return None;
    }
    document
        .query_selector_all("[data-field]")
        .ok()
        .and_then(|nodes| {
            (0..nodes.length()).find_map(|i| {
                let e = nodes.item(i)?.dyn_into::<Element>().ok()?;
                (e.get_attribute("data-field") == *field
                    && e.get_attribute("data-task") == *task
                    && e.get_attribute("data-item") == *item)
                    .then_some(e)
            })
        })
}
fn refresh_editor_controls(app: &Rc<RefCell<App>>, target: &Element) -> Result<(), JsValue> {
    let document = document()?;
    let app = app.borrow();
    let Some(snapshot) = &app.snapshot else {
        return Ok(());
    };
    for (index, action) in app.actions.iter().enumerate() {
        let enabled = match action {
            UiAction::Submit(id) => snapshot
                .tasks
                .iter()
                .find(|t| t.id == *id)
                .is_some_and(|t| {
                    snapshot.pending_approval_count == 0
                        && !app.local.pending.contains_key(id)
                        && queue::valid_prompt(
                            app.local.drafts.get(id).map(String::as_str).unwrap_or(""),
                        )
                        && (t.model_selectable
                            || t.is_busy
                            || t.queue_paused
                            || !t.queued_prompts.is_empty())
                }),
            UiAction::SaveEdit(task, item) => app
                .local
                .edits
                .get(task)
                .is_some_and(|(id, value)| id == item && queue::valid_prompt(value)),
            _ => continue,
        };
        if let Some(button) = document.query_selector(&format!("[data-action='{index}']"))? {
            if enabled {
                button.remove_attribute("disabled")?;
            } else {
                button.set_attribute("disabled", "")?;
            }
        }
    }
    if let Some(error) = document.query_selector(".composer-submit-status.tone-red")? {
        error.remove();
    }
    if let Some(textarea) = target.dyn_ref::<HtmlTextAreaElement>() {
        textarea.style().set_property("height", "auto")?;
        textarea.style().set_property(
            "height",
            &format!("{}px", textarea.scroll_height().min(200)),
        )?;
    }
    Ok(())
}

fn perform(app: &Rc<RefCell<App>>, action: UiAction) -> Result<(), JsValue> {
    let native = match action {
        UiAction::Native(action) => Some(action),
        UiAction::ClearSearch => {
            app.borrow_mut().local.search.clear();
            None
        }
        UiAction::Suggest(task, value) => {
            app.borrow_mut().local.drafts.insert(task, value);
            None
        }
        UiAction::ToggleActivity(key, open) => {
            app.borrow_mut().local.activity_open.insert(key, open);
            None
        }
        UiAction::Submit(task) => {
            let mut app = app.borrow_mut();
            if app.local.pending.contains_key(&task) {
                return Ok(());
            }
            let Some(snapshot) = &app.snapshot else {
                return Ok(());
            };
            let Some(t) = snapshot.tasks.iter().find(|t| t.id == task) else {
                return Ok(());
            };
            if !(t.model_selectable || t.is_busy || t.queue_paused || !t.queued_prompts.is_empty())
            {
                return Ok(());
            }
            let draft = app.local.drafts.get(&task).cloned().unwrap_or_default();
            if !queue::valid_prompt(&draft) {
                return Ok(());
            }
            let request_id = Identifier::new(uuid::Uuid::new_v4().to_string())
                .map_err(|_| JsValue::from_str("Invalid request ID"))?;
            let action = NativeAction::SubmitPrompt {
                request_id: request_id.clone(),
                task_id: task.clone(),
                prompt: draft.trim().into(),
            };
            app.local
                .pending
                .insert(task.clone(), queue::PendingSubmission { request_id, draft });
            app.local.errors.remove(&task);
            app.local.following = true;
            Some(action)
        }
        UiAction::BeginEdit(task, id, text) => {
            app.borrow_mut()
                .local
                .edits
                .insert(task.clone(), (id.clone(), text));
            Some(NativeAction::BeginQueueEdit { task_id: task, id })
        }
        UiAction::SaveEdit(task, id) => {
            let mut app = app.borrow_mut();
            let text = app
                .local
                .edits
                .get(&task)
                .filter(|(edit, _)| *edit == id)
                .map(|(_, v)| v.clone())
                .or_else(|| {
                    app.snapshot
                        .as_ref()?
                        .tasks
                        .iter()
                        .find(|t| t.id == task)?
                        .queued_prompts
                        .iter()
                        .find(|i| i.id == id)
                        .map(|i| i.text.clone())
                })
                .unwrap_or_default();
            if !queue::valid_prompt(&text) {
                return Ok(());
            }
            app.local.edits.remove(&task);
            Some(NativeAction::EditQueuedPrompt {
                task_id: task,
                id,
                prompt: text.trim().into(),
            })
        }
        UiAction::CancelEdit(task, id) => {
            app.borrow_mut().local.edits.remove(&task);
            Some(NativeAction::CancelQueueEdit { task_id: task, id })
        }
        UiAction::Move(task, id, direction) => {
            let app = app.borrow();
            let Some(t) = app
                .snapshot
                .as_ref()
                .and_then(|s| s.tasks.iter().find(|t| t.id == task))
            else {
                return Ok(());
            };
            let Some(before_id) = queue::move_before(&t.queued_prompts, &id, direction) else {
                return Ok(());
            };
            if t.queued_prompts.iter().any(|i| {
                (i.id == id || Some(&i.id) == before_id.as_ref())
                    && i.status == QueuedPromptStatus::Sending
            }) {
                return Ok(());
            }
            Some(NativeAction::MoveQueuedPrompt {
                task_id: task,
                id,
                before_id,
            })
        }
    };
    if let Some(action) = native {
        if let Err(error) = post(&action) {
            if let NativeAction::SubmitPrompt { task_id, .. } = &action {
                app.borrow_mut().local.errors.insert(
                    task_id.clone(),
                    "Delivery is uncertain. Wait for the native receipt before retrying.".into(),
                );
            }
            redraw(app)?;
            return Err(error);
        }
    }
    redraw(app)
}

fn handle(app: &Rc<RefCell<App>>, kind: &str, event: Event) -> Result<(), JsValue> {
    let Some(target) = target(&event) else {
        return Ok(());
    };
    // Native approval makes the entire WebView inert; this also fences delayed events.
    if app
        .borrow()
        .snapshot
        .as_ref()
        .is_some_and(|s| s.pending_approval_count > 0)
    {
        return Ok(());
    }
    match kind {
        "compositionstart" => app.borrow_mut().composing = true,
        "compositionend" => {
            app.borrow_mut().composing = false;
            redraw(app)?;
        }
        "click" => {
            if target.class_list().contains("modal-backdrop") {
                return perform(app, UiAction::Native(NativeAction::DismissSettings));
            }
            if let Some(control) = target.closest("[data-action]")? {
                if control.has_attribute("disabled") {
                    return Ok(());
                }
                if let Some(index) = control
                    .get_attribute("data-action")
                    .and_then(|s| s.parse::<usize>().ok())
                {
                    let action = app.borrow().actions.get(index).cloned();
                    if let Some(action) = action {
                        event.prevent_default();
                        perform(app, action)?;
                    }
                }
            }
        }
        "input" => {
            let field = target.get_attribute("data-field").unwrap_or_default();
            let task = identifier(target.get_attribute("data-task"));
            let value = target
                .dyn_ref::<HtmlTextAreaElement>()
                .map(HtmlTextAreaElement::value)
                .or_else(|| {
                    target
                        .dyn_ref::<HtmlInputElement>()
                        .map(HtmlInputElement::value)
                })
                .or_else(|| {
                    target
                        .dyn_ref::<HtmlSelectElement>()
                        .map(HtmlSelectElement::value)
                })
                .unwrap_or_default();
            let native = match field.as_str() {
                "search" => {
                    app.borrow_mut().local.search = value;
                    None
                }
                "prompt" => {
                    if let Some(task) = task {
                        let mut app = app.borrow_mut();
                        app.local.errors.remove(&task);
                        app.local.drafts.insert(task, value);
                    }
                    None
                }
                "queue-edit" => {
                    if let (Some(task), Some(item)) =
                        (task, identifier(target.get_attribute("data-item")))
                    {
                        app.borrow_mut().local.edits.insert(task, (item, value));
                    }
                    None
                }
                "task-model" => task.and_then(|task_id| {
                    ModelId::parse(&value)
                        .ok()
                        .map(|model_id| NativeAction::SetTaskModel { task_id, model_id })
                }),
                "default-model" => ModelId::parse(&value)
                    .ok()
                    .map(|model_id| NativeAction::SetDefaultModel { model_id }),
                "appearance" => match value.as_str() {
                    "system" => Some(NativeAction::SetAppearance {
                        value: Appearance::System,
                    }),
                    "light" => Some(NativeAction::SetAppearance {
                        value: Appearance::Light,
                    }),
                    "dark" => Some(NativeAction::SetAppearance {
                        value: Appearance::Dark,
                    }),
                    _ => None,
                },
                "payloads" => target
                    .dyn_ref::<HtmlInputElement>()
                    .map(|i| NativeAction::SetShowToolPayloads { value: i.checked() }),
                _ => None,
            };
            if let Some(action) = native {
                post(&action)?;
            }
            if matches!(field.as_str(), "prompt" | "queue-edit") {
                refresh_editor_controls(app, &target)?;
            } else {
                redraw(app)?;
            }
        }
        "keydown" => {
            let key = event
                .dyn_ref::<KeyboardEvent>()
                .ok_or_else(|| JsValue::from_str("Invalid keyboard event"))?;
            if key.is_composing() || key.repeat() {
                return Ok(());
            }
            let settings = app
                .borrow()
                .snapshot
                .as_ref()
                .is_some_and(|s| s.is_settings_presented);
            if settings {
                if key.key() == "Escape" {
                    event.prevent_default();
                    return perform(app, UiAction::Native(NativeAction::DismissSettings));
                }
                if key.key() == "Tab" {
                    trap_focus(&event, key.shift_key())?;
                    return Ok(());
                }
            }
            if key.meta_key() && key.key().eq_ignore_ascii_case("k") && !settings {
                event.prevent_default();
                if let Some(e) = document()?
                    .get_element_by_id("task-search")
                    .and_then(|e| e.dyn_into::<HtmlElement>().ok())
                {
                    e.focus()?;
                }
                return Ok(());
            }
            let task = identifier(target.get_attribute("data-task"));
            match target.get_attribute("data-field").as_deref() {
                Some("prompt")
                    if queue::submit_key(
                        &key.key(),
                        key.shift_key(),
                        key.is_composing(),
                        key.key_code(),
                        key.repeat(),
                    ) =>
                {
                    if let Some(task) = task {
                        event.prevent_default();
                        perform(app, UiAction::Submit(task))?;
                    }
                }
                Some("queue-edit") => {
                    if let (Some(task), Some(item)) =
                        (task, identifier(target.get_attribute("data-item")))
                    {
                        if key.key() == "Escape" {
                            event.prevent_default();
                            perform(app, UiAction::CancelEdit(task, item))?;
                        } else if queue::submit_key(
                            &key.key(),
                            key.shift_key(),
                            false,
                            key.key_code(),
                            false,
                        ) {
                            event.prevent_default();
                            perform(app, UiAction::SaveEdit(task, item))?;
                        }
                    }
                }
                _ => {
                    if key.key() == "Enter" || key.key() == " " {
                        if let Some(index) = target
                            .get_attribute("data-action")
                            .and_then(|s| s.parse::<usize>().ok())
                        {
                            let action = app.borrow().actions.get(index).cloned();
                            if let Some(action) = action {
                                event.prevent_default();
                                perform(app, action)?;
                            }
                        }
                    }
                }
            }
        }
        "scroll" => {
            if target.id() == "conversation-scroll" {
                if let Some(e) = target.dyn_ref::<HtmlElement>() {
                    app.borrow_mut().local.following =
                        e.scroll_height() - e.scroll_top() - e.client_height() <= 48;
                }
            }
        }
        "dragstart" => {
            if let Some(row) = target.closest("[data-queue-id]")? {
                if row.get_attribute("draggable").as_deref() == Some("true") {
                    app.borrow_mut().local.dragged = identifier(row.get_attribute("data-queue-id"));
                }
            }
        }
        "dragend" => app.borrow_mut().local.dragged = None,
        "dragover" => {
            if app.borrow().local.dragged.is_some() && target.closest("[data-drop-task]")?.is_some()
            {
                event.prevent_default();
            }
        }
        "drop" => drop_prompt(app, &event, &target)?,
        _ => {}
    }
    Ok(())
}
fn trap_focus(event: &Event, shift: bool) -> Result<(), JsValue> {
    let document = document()?;
    let Some(dialog) = document.query_selector("[role=dialog]")? else {
        return Ok(());
    };
    let nodes = dialog.query_selector_all(
        "button:not(:disabled),select:not(:disabled),input:not(:disabled),summary,[tabindex='0']",
    )?;
    let controls: Vec<HtmlElement> = (0..nodes.length())
        .filter_map(|i| nodes.item(i)?.dyn_into().ok())
        .collect();
    let (Some(first), Some(last)) = (controls.first(), controls.last()) else {
        return Ok(());
    };
    let active = document.active_element();
    let inside = active.as_ref().is_some_and(|a| dialog.contains(Some(a)));
    if !inside {
        event.prevent_default();
        first.focus()?;
    } else if shift && active.as_ref() == Some(first.as_ref()) {
        event.prevent_default();
        last.focus()?;
    } else if !shift && active.as_ref() == Some(last.as_ref()) {
        event.prevent_default();
        first.focus()?;
    }
    Ok(())
}
fn drop_prompt(app: &Rc<RefCell<App>>, event: &Event, target: &Element) -> Result<(), JsValue> {
    let Some(task_element) = target.closest("[data-drop-task]")? else {
        return Ok(());
    };
    let Some(task) = identifier(task_element.get_attribute("data-drop-task")) else {
        return Ok(());
    };
    let Some(id) = app.borrow().local.dragged.clone() else {
        return Ok(());
    };
    event.prevent_default();
    event.stop_propagation();
    let row = target.closest("[data-queue-id]")?;
    let before = {
        let app = app.borrow();
        let Some(t) = app
            .snapshot
            .as_ref()
            .and_then(|s| s.tasks.iter().find(|t| t.id == task))
        else {
            return Ok(());
        };
        if !t
            .queued_prompts
            .iter()
            .any(|i| i.id == id && i.status != QueuedPromptStatus::Sending)
        {
            return Ok(());
        }
        if let Some(row) = row {
            let Some(target) = identifier(row.get_attribute("data-queue-id")) else {
                return Ok(());
            };
            let y = event
                .dyn_ref::<web_sys::DragEvent>()
                .map(|e| e.client_y() as f64)
                .unwrap_or(0.0);
            let bounds = row.get_bounding_client_rect();
            let Some(before) = queue::drop_before(
                &t.queued_prompts,
                &id,
                &target,
                y >= bounds.top() + bounds.height() / 2.0,
            ) else {
                return Ok(());
            };
            if t.queued_prompts
                .iter()
                .any(|i| Some(&i.id) == before.as_ref() && i.status == QueuedPromptStatus::Sending)
            {
                return Ok(());
            }
            before
        } else {
            None
        }
    };
    app.borrow_mut().local.dragged = None;
    perform(
        app,
        UiAction::Native(NativeAction::MoveQueuedPrompt {
            task_id: task,
            id,
            before_id: before,
        }),
    )
}

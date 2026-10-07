use crate::{Effect, Engine, Event};
use computa_contracts::{chrome::EXTENSION_ID, models::WebProvider};
use serde_json::{Value, json};
use uuid::Uuid;
const INSTALL: &str = "79e4505e-e068-4c75-87ca-309c060a8c41";
fn bootstrap() -> Engine {
    let mut engine = Engine::new(
        INSTALL.into(),
        EXTENSION_ID.into(),
        Uuid::new_v4().to_string(),
    );
    let effects=engine.dispatch(Event::Bootstrap{local:json!({"macndashChromeBridgeV1":{"installationId":INSTALL,"pairingToken":"a".repeat(64),"suspended":false}}),session:json!({}),now:0});
    assert!(effects.iter().any(|e| matches!(e, Effect::Connect { .. })));
    let effects = request(
        &mut engine,
        "authorizeSession",
        json!({"installationId":INSTALL,"pairingToken":"a".repeat(64),"temporaryTabsVersion":1}),
        0,
    );
    assert!(response(&effects)["ok"] == true);
    engine
}
fn request(engine: &mut Engine, op: &str, params: Value, now: u64) -> Vec<Effect> {
    engine.dispatch(Event::Native{message:json!({"version":1,"id":Uuid::new_v4(),"operation":op,"params":params,"generation":"g"}),now,connection:0})
}
fn response(effects: &[Effect]) -> Value {
    effects
        .iter()
        .rev()
        .find_map(|e| {
            if let Effect::Emit { message, .. } = e {
                if message.get("id").is_some() {
                    Some(message.clone())
                } else {
                    None
                }
            } else {
                None
            }
        })
        .unwrap_or(Value::Null)
}
fn chrome(effects: &[Effect]) -> (u64, String, Value) {
    effects
        .iter()
        .find_map(|e| {
            if let Effect::Chrome {
                id, api, params, ..
            } = e
            {
                Some((*id, api.clone(), params.clone()))
            } else {
                None
            }
        })
        .expect("Chrome effect")
}
fn reply(engine: &mut Engine, effects: &[Effect], value: Value, now: u64) -> Vec<Effect> {
    let (id, _, _) = chrome(effects);
    engine.dispatch(Event::ChromeReply {
        id,
        result: Some(value),
        error: None,
        now,
    })
}
fn start(engine: &mut Engine, provider: WebProvider) -> String {
    let e = request(engine, "webProviderStart", json!({"provider":provider}), 0);
    assert_eq!(chrome(&e).1, "tabs.create");
    assert_eq!(chrome(&e).2[0]["active"], false);
    let e = reply(engine, &e, json!({"id":42,"active":false}), 0);
    let e = reply(engine, &e, json!({}), 0);
    response(&e)["result"]["sessionToken"]
        .as_str()
        .unwrap()
        .into()
}
fn facts(provider: WebProvider) -> Value {
    json!({"url":match provider{WebProvider::Chatgpt=>"https://chatgpt.com/?temporary-chat=true",WebProvider::Gemini=>"https://gemini.google.com/app",WebProvider::Claude=>"https://claude.ai/new?incognito="},"facts":{"composer":[{"text":"","value":"","enabled":true}],"answers":[],"users":[],"exit":[{}],"badge":[{"text":if provider==WebProvider::Claude{"Incognito chat"}else{"Temporary Chat"}}]}})
}
fn frame(provider: WebProvider, loader: &str) -> Value {
    json!({"frameTree":{"frame":{"id":"f","url":facts(provider)["url"],"loaderId":loader}}})
}
fn read(
    engine: &mut Engine,
    mut effects: Vec<Effect>,
    provider: WebProvider,
    result: Value,
    now: u64,
) -> Vec<Effect> {
    effects = reply(engine, &effects, frame(provider, "loader"), now);
    effects = reply(engine, &effects, json!({"executionContextId":9}), now);
    if provider == WebProvider::Claude {
        effects = reply(engine, &effects, frame(provider, "loader"), now);
    }
    reply(engine, &effects, json!({"result":{"value":result}}), now)
}
fn ready(engine: &mut Engine, provider: WebProvider) -> String {
    let token = start(engine, provider);
    let e = request(engine, "webProviderPoll", json!({"sessionToken":token}), 0);
    let e = read(engine, e, provider, facts(provider), 0);
    assert_eq!(response(&e)["result"]["state"], "ready");
    token
}

#[test]
fn pairing_generation_and_replay_admission_are_rust_owned() {
    let mut engine = bootstrap();
    let generation=engine.dispatch(Event::Native{message:json!({"version":1,"id":"again","operation":"authorizeSession","params":{"installationId":INSTALL,"pairingToken":"a".repeat(64)},"generation":"g"}),now:0,connection:0});
    assert_eq!(
        response(&generation)["error"]["code"],
        "duplicate_generation"
    );
    let request = json!({"version":1,"id":"same","operation":"ping","params":{},"generation":"g"});
    assert_eq!(
        response(&engine.dispatch(Event::Native {
            message: request.clone(),
            now: 0,
            connection: 0
        }))["ok"],
        true
    );
    assert_eq!(
        response(&engine.dispatch(Event::Native {
            message: request,
            now: 0,
            connection: 0
        }))["error"]["code"],
        "duplicate_request"
    );
}
#[test]
fn external_internal_prefix_cannot_bypass_authorization() {
    let mut engine = bootstrap();
    let e=engine.dispatch(Event::Native{message:json!({"version":1,"id":"internal-forged","operation":"inventory","params":{},"generation":"wrong"}),now:0,connection:0});
    assert_eq!(response(&e)["error"]["code"], "unauthorized");
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
}
#[test]
fn all_providers_start_only_in_owned_inactive_tabs_and_require_temporary_readiness() {
    for provider in [
        WebProvider::Chatgpt,
        WebProvider::Gemini,
        WebProvider::Claude,
    ] {
        let mut e = bootstrap();
        let token = ready(&mut e, provider);
        assert_eq!(e.sessions[&token].state, "ready");
        if provider == WebProvider::Claude {
            assert_eq!(
                e.sessions[&token].document_loader_id.as_deref(),
                Some("loader")
            );
        }
    }
}
#[test]
fn invalid_initial_read_is_bounded_and_does_not_lose_document_authority() {
    let mut engine = bootstrap();
    let token = start(&mut engine, WebProvider::Claude);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        1,
    );
    let e = reply(&mut engine, &e, json!({}), 1);
    assert_eq!(response(&e)["result"]["state"], "loading");
    assert!(!engine.sessions[&token].ownership_lost);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        45_000,
    );
    let e = reply(&mut engine, &e, json!({}), 45_000);
    assert_eq!(response(&e)["result"]["state"], "failed");
    assert_eq!(
        response(&e)["result"]["error"]["code"],
        "web_invalid_document"
    );
}
#[test]
fn initial_loader_replacement_retries_without_dom_mutations() {
    let mut engine = bootstrap();
    let token = start(&mut engine, WebProvider::Claude);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        0,
    );
    let e = reply(&mut engine, &e, frame(WebProvider::Claude, "before"), 0);
    let e = reply(&mut engine, &e, json!({"executionContextId":9}), 0);
    let e = reply(&mut engine, &e, frame(WebProvider::Claude, "after"), 0);
    assert_eq!(response(&e)["result"]["state"], "loading");
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
    assert!(!engine.sessions[&token].ownership_lost);
}
#[test]
fn ready_document_replacement_blocks_insertion_and_cleanup() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    let e = request(
        &mut engine,
        "webProviderSend",
        json!({"sessionToken":token,"prompt":"hello"}),
        1,
    );
    let e = reply(
        &mut engine,
        &e,
        frame(WebProvider::Claude, "replacement"),
        1,
    );
    assert_eq!(response(&e)["error"]["code"], "web_document_changed");
    assert!(engine.sessions[&token].ownership_lost);
    let e = request(
        &mut engine,
        "webProviderFinish",
        json!({"sessionToken":token}),
        1,
    );
    assert_eq!(response(&e)["result"]["cleanup"], "failed");
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
}
#[test]
fn prompt_submission_records_authority_before_click_and_includes_unique_first_marker() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    let e = request(
        &mut engine,
        "webProviderSend",
        json!({"sessionToken":token,"prompt":"hello"}),
        1,
    );
    let e = read(
        &mut engine,
        e,
        WebProvider::Claude,
        facts(WebProvider::Claude),
        1,
    );
    let e = read(
        &mut engine,
        e,
        WebProvider::Claude,
        json!({"acted":true}),
        1,
    );
    assert_eq!(chrome(&e).2[1], "Page.getFrameTree");
    let e = reply(&mut engine, &e, frame(WebProvider::Claude, "loader"), 1);
    assert_eq!(chrome(&e).2[1], "Input.insertText");
    assert!(
        chrome(&e).2[2]["text"]
            .as_str()
            .unwrap()
            .starts_with("Computa session marker: ")
    );
    let e = reply(&mut engine, &e, json!({}), 1);
    assert!(engine.sessions[&token].submitted);
    assert!(engine.sessions[&token].pending_submission);
    assert_eq!(engine.sessions[&token].sequence, 1);
    let e = read(
        &mut engine,
        e,
        WebProvider::Claude,
        json!({"acted":true}),
        1,
    );
    assert_eq!(response(&e)["result"]["state"], "running");
}
#[test]
fn closing_an_unsent_tab_frees_capacity_and_prunes_ledger_without_chrome_actions() {
    let mut engine = bootstrap();
    for _ in 0..5 {
        let token = start(&mut engine, WebProvider::Claude);
        let e = engine.dispatch(Event::Removed { tab_id: 42, now: 1 });
        assert!(!engine.sessions.contains_key(&token));
        assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
        assert!(e.iter().any(|e| if let Effect::Store { value, .. } = e {
            value[providers_key()].as_array().is_some_and(Vec::is_empty)
        } else {
            false
        }));
    }
}
fn providers_key() -> &'static str {
    crate::providers::LEDGER_KEY
}

fn clone_workspace(engine: &mut Engine) -> (String, String) {
    let task = Uuid::new_v4().to_string();
    let source = json!({"id":"source","type":"page","tabId":10,"title":"Fixture","url":"https://example.test/","attached":false});
    let e = request(
        engine,
        "createTemporary",
        json!({"sourceTargetID":"source","expectedSourceURL":"https://example.test/","taskNonce":task}),
        0,
    );
    let e = reply(engine, &e, json!([source.clone()]), 0);
    let e = reply(
        engine,
        &e,
        json!({"id":10,"windowId":1,"url":"https://example.test/"}),
        0,
    );
    let e = reply(engine, &e, json!([source]), 0);
    assert_eq!(chrome(&e).1, "tabs.create");
    assert_eq!(chrome(&e).2[0]["active"], false);
    let tab = json!({"id":11,"windowId":1,"url":"https://example.test/","active":false,"pinned":false,"groupId":-1});
    let e = reply(engine, &e, tab.clone(), 0);
    let e = reply(engine, &e, tab, 0);
    let e = reply(
        engine,
        &e,
        json!([{"id":"owned-clone","type":"page","tabId":11,"url":"https://example.test/","attached":false}]),
        0,
    );
    assert_eq!(response(&e)["ok"], true);
    let token = response(&e)["result"]["leaseToken"]
        .as_str()
        .unwrap()
        .to_owned();
    (task, token)
}
#[test]
fn workspace_cleanup_requires_exact_inactive_unattached_clone() {
    let mut engine = bootstrap();
    let (task, token) = clone_workspace(&mut engine);
    let e = request(
        &mut engine,
        "releaseTemporary",
        json!({"leaseToken":token,"taskNonce":task}),
        1,
    );
    assert_eq!(chrome(&e).1, "tabs.get");
    let e = reply(
        &mut engine,
        &e,
        json!({"id":11,"windowId":1,"url":"https://example.test/","active":false,"pinned":false}),
        1,
    );
    let e = reply(
        &mut engine,
        &e,
        json!([{"id":"owned-clone","type":"page","tabId":11,"url":"https://example.test/","attached":false}]),
        1,
    );
    assert_eq!(chrome(&e).1, "tabs.remove");
    assert_eq!(chrome(&e).2, json!([11]));
    let e = reply(&mut engine, &e, json!({}), 1);
    assert_eq!(response(&e)["result"]["closed"], true);
}
#[test]
fn user_activation_permanently_retains_owned_clone_and_never_closes_source() {
    let mut engine = bootstrap();
    let (task, token) = clone_workspace(&mut engine);
    engine.dispatch(Event::Activated { tab_id: 11, now: 1 });
    let e = request(
        &mut engine,
        "releaseTemporary",
        json!({"leaseToken":token,"taskNonce":task}),
        1,
    );
    assert_eq!(response(&e)["result"]["retained"], true);
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
    assert!(!engine.temporary.leases[&token].cleanup_safe);
}
#[test]
fn unknown_timeout_revokes_admission_without_replaying_the_operation() {
    let mut engine = bootstrap();
    let e = request(
        &mut engine,
        "webProviderStart",
        json!({"provider":"claude"}),
        0,
    );
    let (id, _, _) = chrome(&e);
    let e = engine.dispatch(Event::ChromeReply {
        id,
        result: None,
        error: Some("timeout".into()),
        now: 3001,
    });
    assert_eq!(response(&e)["error"]["code"], "chrome_timeout");
    assert_eq!(engine.status()["suspended"], true);
    let e = request(
        &mut engine,
        "webProviderStart",
        json!({"provider":"claude"}),
        3002,
    );
    assert_eq!(response(&e)["error"]["code"], "unauthorized");
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
    let e = engine.dispatch(Event::ChromeReply {
        id,
        result: Some(json!({"id":42,"active":false,"url":"https://claude.ai/new"})),
        error: None,
        now: 3003,
    });
    assert_eq!(chrome(&e).1, "tabs.remove");
    assert_eq!(chrome(&e).2, json!([42]));
}
#[test]
fn host_loss_never_replays_pending_creation_but_late_receipt_is_exactly_cleaned() {
    let mut engine = bootstrap();
    let e = request(
        &mut engine,
        "webProviderStart",
        json!({"provider":"claude"}),
        0,
    );
    let (id, _, _) = chrome(&e);
    engine.dispatch(Event::HostDisconnected {
        now: 1,
        connection: 0,
    });
    assert!(!engine.permits(id));
    let e = engine.dispatch(Event::ChromeReply {
        id,
        result: Some(json!({"id":42,"active":false,"url":"https://claude.ai/new"})),
        error: None,
        now: 2,
    });
    assert_eq!(chrome(&e).1, "tabs.remove");
    assert_eq!(chrome(&e).2, json!([42]));
}
#[test]
fn stale_port_disconnect_does_not_revoke_current_generation() {
    let mut engine = bootstrap();
    let e = engine.dispatch(Event::HostDisconnected {
        now: 1,
        connection: u64::MAX,
    });
    assert!(e.is_empty());
    assert_eq!(engine.status()["connected"], true);
}
#[test]
fn paired_host_reconnect_keeps_one_capped_timer_past_five_failures_without_replaying() {
    let mut engine = bootstrap();
    let mut stale_timer = None;
    for attempt in 0..20u64 {
        let effects = engine.dispatch(Event::HostDisconnected {
            now: attempt * 30_000,
            connection: 0,
        });
        assert!(
            !effects
                .iter()
                .any(|effect| matches!(effect, Effect::Chrome { .. }))
        );
        let schedules = effects
            .iter()
            .filter_map(|effect| {
                if let Effect::Schedule { token, after_ms } = effect {
                    Some((*token, *after_ms))
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        assert_eq!(schedules.len(), 1);
        let (token, delay) = schedules[0];
        assert_eq!(delay, (1000 * (1u64 << attempt.min(5))).min(30_000));
        if let Some(stale) = stale_timer {
            assert!(
                engine
                    .dispatch(Event::Timer {
                        token: stale,
                        now: attempt * 30_000
                    })
                    .is_empty()
            );
        }
        let effects = engine.dispatch(Event::Timer {
            token,
            now: attempt * 30_000 + delay,
        });
        assert_eq!(
            effects
                .iter()
                .filter(|effect| matches!(effect, Effect::Connect { .. }))
                .count(),
            1
        );
        assert!(
            !effects
                .iter()
                .any(|effect| matches!(effect, Effect::Chrome { .. } | Effect::Schedule { .. }))
        );
        assert!(effects.iter().all(
            |effect| !matches!(effect, Effect::Emit { message, .. } if message.get("id").is_some())
        ));
        stale_timer = Some(token);
    }
    let effects = engine.dispatch(Event::Native {
        message: json!({"version":1,"id":Uuid::new_v4(),"operation":"authorizeSession",
            "params":{"installationId":INSTALL,"pairingToken":"a".repeat(64)},
            "generation":"new-connection"}),
        now: 600_000,
        connection: 0,
    });
    assert_eq!(response(&effects)["ok"], true);
    let effects = engine.dispatch(Event::HostDisconnected {
        now: 600_001,
        connection: 0,
    });
    assert!(
        effects
            .iter()
            .any(|effect| matches!(effect, Effect::Schedule { after_ms: 1000, .. }))
    );
}
#[test]
fn popup_rejects_webpage_and_other_extension_ingress() {
    let engine = bootstrap();
    assert!(!engine.accepts_popup(&json!({"id":EXTENSION_ID,"url":"https://example.com"})));
    assert!(!engine.accepts_popup(
        &json!({"id":"other","url":format!("chrome-extension://{EXTENSION_ID}/popup.html")})
    ));
    assert!(!engine.accepts_popup(&json!({"id":EXTENSION_ID,"url":format!("chrome-extension://{EXTENSION_ID}/popup.html"),"tab":{"id":1}})));
}

fn submit_claude(engine: &mut Engine, token: &str) {
    let e = request(
        engine,
        "webProviderSend",
        json!({"sessionToken":token,"prompt":"hello"}),
        1,
    );
    let e = read(
        engine,
        e,
        WebProvider::Claude,
        facts(WebProvider::Claude),
        1,
    );
    let e = read(engine, e, WebProvider::Claude, json!({"acted":true}), 1);
    let e = reply(engine, &e, frame(WebProvider::Claude, "loader"), 1);
    let e = reply(engine, &e, json!({}), 1);
    let e = read(engine, e, WebProvider::Claude, json!({"acted":true}), 1);
    assert_eq!(response(&e)["result"]["state"], "running");
}
fn completed_facts(engine: &Engine, token: &str) -> Value {
    let mut value = facts(WebProvider::Claude);
    value["facts"]["users"] = json!([{"text":format!("Computa session marker: {}\n\nhello",engine.sessions[token].first_user_marker.as_ref().unwrap()),"ownerId":"owned-first"}]);
    value["facts"]["answers"] = json!([{"text":"{\"message\":\"Hello\",\"tool_calls\":[]}","copyEnabled":true,"streaming":"false"}]);
    value
}
#[test]
fn complete_claude_turn_pins_first_message_and_closes_only_verified_temporary_tab() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    submit_claude(&mut engine, &token);
    let facts = completed_facts(&engine, &token);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        10,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts.clone(), 10);
    assert_eq!(response(&e)["result"]["state"], "running");
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        1610,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts.clone(), 1610);
    assert_eq!(response(&e)["result"]["state"], "complete");
    assert!(engine.sessions[&token].first_user_fingerprint.is_some());
    let e = request(
        &mut engine,
        "webProviderFinish",
        json!({"sessionToken":token}),
        1611,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts, 1611);
    assert_eq!(chrome(&e).1, "debugger.detach");
    let e = reply(&mut engine, &e, json!({}), 1611);
    assert_eq!(chrome(&e).1, "tabs.remove");
    assert_eq!(chrome(&e).2, json!([42]));
    let e = reply(&mut engine, &e, json!({}), 1611);
    assert_eq!(response(&e)["result"]["cleanup"], "temporary_closed");
    assert!(!engine.sessions.contains_key(&token));
}
#[test]
fn interrupted_response_is_failed_but_owned_temporary_cleanup_still_succeeds() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    submit_claude(&mut engine, &token);
    let mut facts = completed_facts(&engine, &token);
    facts["facts"]["status"] = json!([{"text":"Claude’s response was interrupted."}]);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        10,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts.clone(), 10);
    assert_eq!(
        response(&e)["result"]["error"]["code"],
        "web_response_interrupted"
    );
    let e = request(
        &mut engine,
        "webProviderFinish",
        json!({"sessionToken":token}),
        11,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts, 11);
    assert_eq!(chrome(&e).1, "debugger.detach");
}
#[test]
fn same_count_spa_replacement_cannot_submit_or_be_closed() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    submit_claude(&mut engine, &token);
    let original = completed_facts(&engine, &token);
    let e = request(
        &mut engine,
        "webProviderPoll",
        json!({"sessionToken":token}),
        10,
    );
    read(&mut engine, e, WebProvider::Claude, original.clone(), 10);
    let mut replacement = original;
    replacement["facts"]["users"][0]["ownerId"] = json!("replacement-first");
    let e = request(
        &mut engine,
        "webProviderFinish",
        json!({"sessionToken":token}),
        11,
    );
    let e = read(&mut engine, e, WebProvider::Claude, replacement, 11);
    assert_eq!(response(&e)["result"]["cleanup"], "failed");
    assert!(engine.sessions[&token].ownership_lost);
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
}
#[test]
fn restored_receipt_attaches_only_for_identity_checked_cleanup() {
    let mut original = bootstrap();
    let token = ready(&mut original, WebProvider::Claude);
    submit_claude(&mut original, &token);
    let facts = completed_facts(&original, &token);
    let e = request(
        &mut original,
        "webProviderPoll",
        json!({"sessionToken":token}),
        10,
    );
    read(&mut original, e, WebProvider::Claude, facts.clone(), 10);
    let ledger = original.sessions[&token].ledger();
    let mut restored = Engine::new(
        INSTALL.into(),
        EXTENSION_ID.into(),
        Uuid::new_v4().to_string(),
    );
    let e = restored.dispatch(Event::Bootstrap {
        local: json!({}),
        session: json!({providers_key():[ledger]}),
        now: 0,
    });
    assert_eq!(chrome(&e).1, "debugger.attach");
    assert_eq!(chrome(&e).2, json!([{"tabId":42},"1.3"]));
    let e = reply(&mut restored, &e, json!({}), 1);
    let mut replacement = facts;
    replacement["facts"]["users"][0]["ownerId"] = json!("replacement");
    let e = read(&mut restored, e, WebProvider::Claude, replacement, 1);
    assert!(restored.sessions[&token].ownership_lost);
    assert!(!e.iter().any(|e| matches!(e, Effect::Chrome { .. })));
}

#[test]
fn terminal_receipt_requires_close_ack_and_survives_worker_restart() {
    let mut engine = bootstrap();
    let token = ready(&mut engine, WebProvider::Claude);
    submit_claude(&mut engine, &token);
    let facts = completed_facts(&engine, &token);
    let old_epoch = engine.sessions[&token].source_epoch.clone().unwrap();
    let e = request(
        &mut engine,
        "webProviderFinish",
        json!({"sessionToken":token}),
        5,
    );
    let e = read(&mut engine, e, WebProvider::Claude, facts, 5);
    let e = reply(&mut engine, &e, json!({}), 5);
    let (id, _, _) = chrome(&e);
    let initial = engine.dispatch(Event::Native {
        message: json!({"version":1,"event":"requestHello"}),
        now: 6,
        connection: 0,
    });
    assert!(initial.iter().any(|effect|matches!(effect,Effect::Emit{message,..}if message["event"]=="hello"&&message["cleanupReceipts"].as_array().unwrap().is_empty())));
    engine.dispatch(Event::HostDisconnected {
        now: 7,
        connection: 0,
    });
    let terminal = engine.dispatch(Event::ChromeReply {
        id,
        result: Some(json!({})),
        error: None,
        now: 8,
    });
    let ledger = terminal
        .iter()
        .find_map(|effect| {
            if let Effect::Store { area, value } = effect {
                (area == "session"
                    && !value[crate::providers::RECEIPTS_KEY]
                        .as_array()
                        .unwrap()
                        .is_empty())
                .then_some(value.clone())
            } else {
                None
            }
        })
        .unwrap();
    let receipt = &ledger[crate::providers::RECEIPTS_KEY][0];
    assert_eq!(receipt["sessionToken"], token);
    assert_eq!(receipt["sourceEpoch"], old_epoch);
    assert_eq!(receipt["generation"], "g");
    assert_eq!(receipt["cleanup"], "temporary_closed");
    let mut restored = Engine::new(
        INSTALL.into(),
        EXTENSION_ID.into(),
        Uuid::new_v4().to_string(),
    );
    let effects=restored.dispatch(Event::Bootstrap{local:json!({"macndashChromeBridgeV1":{"installationId":INSTALL,"pairingToken":"a".repeat(64)}}),session:ledger,now:0});
    assert!(effects.iter().any(|effect|matches!(effect,Effect::Emit{message,..}if message["event"]=="hello"&&message["cleanupReceipts"][0]["sourceEpoch"]==old_epoch)));
}

# Website model choices

Computa's Swift desktop runtime discovers model choices from the signed-in ChatGPT, Gemini, and Claude websites and sends website inference through its owned embedded browser. A concrete choice requests an exact website model key and label. It does not identify an immutable backend model version.

**Complete live qualification of all advertised choices is pending.** Earlier provider-default harness results in [BACKGROUND-WEBSITE-SESSIONS.md](BACKGROUND-WEBSITE-SESSIONS.md) and [EMBEDDED-PROVIDERS-QUALIFICATION.md](EMBEDDED-PROVIDERS-QUALIFICATION.md) do not establish that every concrete choice works. Automated fixtures, source changes, builds, installed-app behavior, and live provider results are separate evidence.

## Discovery and selector

After the privileged app UI and its background render host are ready, `AppState` starts one bounded discovery pass. Refresh requests share an in-flight pass. Each provider is inspected sequentially in an app-owned background `WKWebView` using the same persistent sign-in profile as the human browser. These pages are excluded from the human tab strip; the background-session ownership and cleanup rules still apply.

The fixed provider adapters inspect the actual model picker. They open supported menus when necessary, read enabled model-family leaves, and close menus they opened. They do not populate the selector from marketing documentation, an API model catalog, or an assistant's self-description. Disabled choices, upgrades, descriptions, effort controls, and ambiguous or duplicate menu identities are not advertised as selectable models. A changed or unsupported website menu can make discovery fail; the parser does not guess its meaning.

Each successful provider result replaces that provider's cached choices. A provider failure leaves its previous cache intact and reports a provider-specific refresh error. Therefore a cached option is a previous observation, not a guarantee that the current account can still use it. Inference must verify it again. The cache is stored under `Computa.websiteModelChoices.v1`, with at most 32 choices per provider, 96 overall, and a 100 KiB read bound.

The selector includes each provider's legacy **Website default** and its discovered concrete choices. A valid saved choice absent from the current cache remains visible as unavailable, preserving its identity in history and defaults. The UI disables unavailable options. An invalid saved website ID is also unavailable and cannot become local inference.

This contract covers model families. Thinking mode, reasoning effort, and other generation settings are separate controls and are not encoded as additional model choices. Selecting a family does not promise a particular effort setting. Provider documentation also treats these settings separately; see [Claude's model, effort, and thinking settings](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings) and [Gemini's model and feature availability](https://support.google.com/gemini/answer/16275805?hl=en).

## Stable local identity

`WebsiteModelChoice` has three fields: `provider`, `key`, and `label`. Providers are exactly `chatgpt`, `gemini`, or `claude`. Keys and labels must each be 1–128 UTF-8 bytes, NFC normalized, without control characters or surrounding whitespace. Duplicate keys or duplicate labels invalidate a provider discovery result.

A concrete local model ID is:

```text
browser/<provider>/choice/<unpadded-base64url-of-canonical-JSON>
```

The encoded JSON contains exactly `key` and `label`, with sorted keys. The provider is in the path. Parsing requires the canonical round trip, so extra or duplicate fields, alternate encodings, padding, and malformed identities are rejected. The ID is self-contained: restoring a chat does not depend on a mutable global model-name registry.

The native start request passes the provider and a `modelChoice` string containing canonical JSON with exactly `key`, `label`, and `provider`. An inference request retains the full concrete model ID. Labels are not silently rewritten or mapped to another website family.

The old IDs `browser/chatgpt`, `browser/gemini`, and `browser/claude` remain compatible with saved chats and defaults. They request the website's default selection and carry no exact-choice claim. The native runtime accepts missing legacy evidence for compatibility; it requires evidence for concrete IDs. Existing local transcripts remain local, and neither changing models nor cleaning up a website conversation deletes the Computa transcript.

## Session pinning and failure behavior

A website session is pinned to its owning Computa task, provider, route, session token, and exact local model ID. Tool continuations reuse that session only while those identities remain identical. Before a model or provider switch, the server finishes any retained old session through its original transport and exact token, and requires cleanup reported as `deleted` or `not_created`. Only then may it start the replacement. Unconfirmed cleanup blocks the replacement and retains ownership for another cleanup attempt, including when the previous turn's cleanup failed and the UI subsequently changed providers. Runtime provider changes also use the existing retirement and cleanup path.

The selected choice is verified during preparation, immediately before Send in the provider adapter, on admitted ready/running/complete snapshots, and with a fresh native verification after awaited adapter results. These checks run alongside the existing session-token, document-generation, route, conversation, first-user fingerprint, and response-ownership checks. A proof copied from an earlier page or from before an asynchronous mutation is insufficient.

During initial preparation, an already claimed concrete model-selection phase can advance while its owned popup hides the composer or temporary-mode control. Native inspection still requires zero users, zero responses, no conversation URL, the same document generation and route, and a previously verified temporary session. This branch cannot claim selection from an arbitrary hidden editor or bypass initial composer/mode preparation. It admits ready state only after the selection operation returns exact proof and a fresh native model verification succeeds. Ready confirms that proof and current temporary mode; the later prepare operation independently checks the actual composer before inserting any prompt.

After clicking a different ChatGPT model family, the adapter observes closure of its owned picker and performs a fresh selection read within one shared 1,800 ms deadline. A family choice can return to its associated parent popup. Under the unchanged fresh-session identity and empty-message guards, the adapter may dismiss that exact associated popup once with Escape. The closure attempt is claimed before dispatch; an unrelated or ambiguous menu, trigger drift, lost acknowledgment, or repeated settlement fails. A hidden checked family radio remains diagnostic data, not selected-model proof.

If the first primary opening of the fresh read is not acknowledged within at most 900 ms, this specific post-selection read may make one extra opening after reinspection. The same single enabled trigger must still be closed, all associated menus absent, and the exact owned document URL, provider origin, and token unchanged. The session must remain temporary and empty: native expected user counts exactly `[0]`, zero actual users and assistants, no submitted first message, and no bound private or native first-message fingerprint. The extra-opening flag is claimed before clicking and cannot reset on another invocation.

While the owned model menu is open, its modal can hide the temporary-mode control from Accessibility. Continuous checks retain the same identity, first-message, and empty-session guards; temporary-mode visibility is checked again with the full guard at closed settlement, before either primary opening, and after acknowledged owned closure before returning proof. Actual selected-model evidence and full native ownership validation still gate Send. Elapsed time or rendering callbacks do not prove selection or a framework commit, and paused rendering callbacks cannot authorize a weaker proof. General and established-session reads receive no extra-opening allowance. Family selection, secondary navigation, closure, editor actions, and Send cannot be replayed by this recovery. Thrown click failures, lost adapter callbacks or closure acknowledgments, ambiguous controls, and mismatches fail.

All three fixed provider adapters recheck their actual current temporary-mode controls after the final awaited selected-model read and owned-popup closure for concrete inference actions, including a verification before the first message. The check uses a provider callback that reads the current DOM, not the earlier snapshot's mode flag. Missing or failed current mode proof rejects the result. Discovery, selection, diagnostics, Stop, and legacy actions without an expected concrete choice retain their existing mode checks.

Read-only model observations share one allowance to discard a crossed observation and take a fresh full `inspect`. This can handle the user DOM appearing for an already acknowledged Send, or a provider framework replacing an already pinned first-message root and payload body. Replacement recovery requires both old objects to be disconnected, different connected current objects, the same user count and exact normalized payload, the same marker and existing provider identity, and a freshly computed fingerprint matching both native and private pins. Owner, document, temporary-mode, and fresh-node checks still apply. Changed content, a wrong marker or identity, and another replacement during verification fail. The allowance stays consumed through nested model checks and route refreshes; it does not permit another insertion, Send, or mutation retry.

Nested read-only checks also preserve a finite route-refresh allowance for genuine first-conversation creation or ChatGPT's owned local-to-public conversation promotion. They discard each crossed result and use a fresh full `inspect`, retaining document generation, private ownership, temporary mode, and first-message lineage requirements. During the first submitted inference only, before any conversation is bound, an empty-to-local ChatGPT transition may retain one refresh for that local route's subsequent public promotion. The local-to-public edge consumes it. Direct empty-to-public creation or promotion of an already bound local conversation consumes the original allowance immediately. Another local route, public-to-public change, foreign provider route, or document change cannot acquire another refresh. This monotonic route graph does not reset the separate consumed observation allowance or relax editor-action route checks. Unknown or unrelated navigation remains an ownership failure.

Missing or malformed choice proof produces `modelUnverified`; an observed different selection or response attribution produces `modelMismatch`; an unavailable menu choice produces `modelUnavailable`. The runtime does not admit the response, substitute a different family or provider, route to a local model, or replay the prompt automatically. A website can still accept a Send before a later mismatch is detected; rejection of that response is not a claim that nothing reached the website. An uncertain Send acknowledgment does not authorize another Send.

The embedded transport uses versioned page-change notifications to wake response reads. Reading a new snapshot still validates the choice; an event is not itself model evidence. Website usage limits and sign-in requirements continue to apply.

## Host tool handoff

Every website inference receives a fresh contract built from that request's validated tool schemas, including tool-result continuations. The contract frames the exchange as a structured-output RPC request to Computa's local host functions. The model retains its website identity and governing rules; serialized application roles do not replace them. References to a Computa or local-assistant persona inside serialized instructions label the application's task context, not the website model's identity or native capabilities. The complete original Responses request is preserved inside the application-context envelope, including the user's scope, history, current function schemas, and `tool_choice`.

For a supported authorized operation that remains necessary, the model can return ordinary website text containing the offered `tool_calls` JSON for Computa's external local parser. The website does not execute that JSON. Computa validates the envelope, enforces native permissions and approvals, executes admitted host requests, and supplies their matching outputs to a subsequent inference. Offering a tool does not require a call, and the model must not fabricate execution or revive historical tool names. Unsupported or denied operations remain subject to the actual native restrictions. A refusal or final answer without the requested native observation is a failed tool qualification even if the website response and native turn complete normally.

For a final reply, Computa unwraps the `text` value of the `message` envelope before displaying it to the user. A user's instruction to return only file contents therefore applies to that value; the website transport still requires the single JSON envelope. The fresh handoff states this explicitly. It does not relax the strict parser, repair malformed output, change the original request serialization, or allow a plain-text answer to replace the required envelope.

This handoff does not register website-native tools or give the website direct filesystem access. The owned model conversation is not a computer-tool target. The current built-in WebKit browser has no general tab driver; ordinary browser tools, when offered, use an authorized Chrome connection. Local terminal and native-app capabilities depend on the schemas and permissions actually offered for the inference. Full Access changes eligible approval handling, not sandbox or macOS access boundaries.

## What model verification proves

The native parser accepts this bounded evidence schema:

```json
{
  "selected": { "key": "<observed key>", "label": "<observed label>" },
  "verification": "website_selection",
  "source": "model_picker_label"
}
```

`source` is optional and, when present, must be `model_picker_label`, `checked_model_option`, or `selected_model_indicator`. The last represents an explicit website selected-row indicator verified with its exact model-family label; focus or active styling alone cannot establish selection. The selected key and label must exactly match the requested concrete choice. All three sources remain selection-only proof, supported explicitly as `website_selection`.

When the website exposes response attribution, evidence can instead contain:

```json
{
  "selected": { "key": "<observed key>", "label": "<observed label>" },
  "verification": "response_reported",
  "source": "checked_model_option",
  "response": {
    "key": "<response model key>",
    "label": "<response model label>",
    "source": "response_attribute"
  }
}
```

Response sources are limited to `response_attribute` and `response_label`. Response identity must equal the selected identity exactly. `response_reported` without response attribution, or `website_selection` with response attribution, is malformed. Unknown fields, sources, verification levels, types, and unbounded identities are rejected.

| Evidence | Supported conclusion |
| --- | --- |
| Fresh `website_selection` | The website controls showed the requested choice at the checked stages. |
| Matching `response_reported` | The website additionally attributed the captured response to that choice. |
| Response `model` field | Echoes the requested local ID; it is not independent provenance. |
| Assistant self-identification, output quality, timing, or a correct marker | Does not establish model identity. |

Independent native evidence is included in Responses metadata at `metadata.computa_website_model` when present. No evidence is invented for a legacy response that lacks it. Website attribution is still a website label, not cryptographic attestation or disclosure of the actual backend build. Backend version remains unknown, including for automatic routing or silent provider fallbacks that the website does not expose. Receipts must retain the distinction between selection-only and response-reported proof.

## Private native evidence records

The desktop runtime configures a private sidecar directory at:

```text
<runtime CodexHome>/WebsiteModelEvidence-v1/<local-task-UUID>.jsonl
```

The local Computa `taskID` and App Server `threadID` are distinct identifiers. The filename and `taskID` use the local task UUID. After starting or resuming the App Server thread, runtime registration adds the actual native `threadID` to subsequent records. A record without that mapping cannot independently be matched to a native rollout thread.

Each verified inference has an `inferenceID` and records these phases:

- `submission_verified`: persisted after a successful Send acknowledgment. The adapter checked the choice immediately before Send; this record is not a timestamped `before_send` event.
- `complete`: persisted after response proof and the tool/final envelope have validated, before returning the response stream.

Schema version 1 records contain UTC timestamps, local task ID, registered native thread ID when available, exact model ID, provider, inference ID, phase, session token, inference sequence, document generation, actual pre-Send `baselineResponseCount`, latest observed `responseCount`, optional first-user SHA-256 fingerprint, and model evidence. The fingerprint is omitted until it is bound. Records contain no raw prompt, tool payload, response text, cookies, or credentials.

A fast response can already be rendered when the Send acknowledgment returns. Its actual acknowledgment count remains truthful; the exporter does not replace it with the earlier baseline. A completion must exceed the count before Send, and may equal the acknowledgment count. Both count fields are required bounded integers from 0 through 10,000, excluding booleans. The baseline stays identical through an inference, actual snapshots stay monotonic, and the next inference's baseline equals the prior completed count.

The store uses directory mode `0700` and file mode `0600`, tightens an existing directory's permissions, refuses direct directory/file symlinks, and writes atomically. A record is bounded to 4,096 bytes; each file to 1 MiB; creation of new files to a directory with fewer than 256 entries. Sequence and response count must be bounded integers, excluding booleans. Invalid context or failed persistence skips the record; missing records cannot be treated as successful qualification. This is a bounded evidence store, not an unbounded transcript or a tamper-proof audit log.

## Qualification requirements

Automated coverage exercises catalog identity and restoration, provider refresh isolation, unavailable selector states, concrete routing, adapter menu discovery and selection, exact associated parent-popup dismissal and bounded primary-opening recovery after ChatGPT family changes, paused rendering callbacks and crossed fresh-session scope, exact session reuse, cleanup before switching, wrong or stale choice proof, finite response-attribution sources, metadata distinct from request echoes, native exporter scope/permissions/bounds, current host-tool schemas and unchanged request serialization, and asynchronous page changes. Synthetic provider fixtures test these contracts; they do not establish current live website compatibility.

A live qualification receipt for each advertised choice must correlate the following independently:

1. The actual account's discovered menu choice and exact local model ID.
2. The installed desktop app's native rollout `session_meta.payload.id` and exact turn ID, with `task_started`/`task_complete` time bounds and the same concrete ID in turn context.
3. Raw app-produced sidecar lines within that turn window, with `threadID` equal to the rollout ID, a stable separate local `taskID` matching the sidecar filename, and matched submission/completion inference IDs.
4. One owned website session and document generation, contiguous non-overlapping inference sequences, matching pre-Send baselines, monotonic actual response snapshots, a completed count exceeding its baseline, and stable first-user fingerprint through a tool continuation. The next baseline must equal the prior completed count; a completed count need not exceed an acknowledgment count that already observed the answer.
5. An actual native tool read of a fresh local marker absent from the prompt, successful correlated tool output, and the exact clean final answer.
6. Selection-only versus response-reported website proof for each inference, with no claim of backend identity when it is absent.

Raw exports and their digests must be retained before later turns append records. A manually assembled evidence wrapper, requested-model echo, or copied historical provider result cannot replace the native export. Send counts, cleanup success, browser focus behavior, installed artifact identity, and human selector behavior require their own observations; the sidecar alone does not prove them. Per-choice results belong to their exact signed installed candidate and independently observed running executable. Preserve passes and failures from earlier candidates separately rather than aggregating them into the current candidate's matrix. Preparing fresh fixtures, signing a build, or declaring a native turn complete cannot establish a live harness pass.

Negative live and fixture checks must include unavailable choices, changed selections before Send and before response admission, conflicting attribution, stale documents, invalid IDs, unsupported menus, interrupted cleanup, and uncertain acknowledgment. They must confirm failure without silent fallback, automatic replay, or unverified response admission. Synthetic negative coverage and a completed positive marker turn are separate evidence.

### Current candidate17 qualification

The 0.4.0 (17) Release candidate was built, signed and installed. The source-to-staged resource inventories, staged-to-installed executable/runtime digests, bundle identity, version/build and strict deep code-signature checks passed. The running installed executable was observed separately by the root tester; the receipt collector did not inspect its process or browser UI.

Four fresh tasks passed the strict receipt collector on this candidate. One additional task failed, and five choices remain unattempted:

| Provider | Website family | Candidate17 live result |
| --- | --- | --- |
| ChatGPT | Latest | Verified native file read, clean final, two paired selection-only inferences. |
| ChatGPT | GPT-5.6 Sol | Verified native file read, clean final, two paired selection-only inferences. |
| ChatGPT | GPT-5.5 | Verified native file read, clean final, two paired selection-only inferences. |
| Gemini | 3.5 Flash-Lite | Verified native file read, clean final, two paired selection-only inferences. |
| Gemini | 3.1 Pro | Failed page inspection; no native tool call, clean final or exported choice proof. |
| Gemini | 3.8 Flash | Not attempted on candidate17; human Google verification and confirmed session cleanup/capacity remain required. |
| Claude | Sonnet 5.5, Haiku 4.5, Sonnet 5, Sonnet 4.6 | Not attempted on candidate17; the website displays free messages returning at `12:00PM`. Its timezone was not established. |

Each positive task used the ordinary file-read request with a new unknown marker and no manually supplied tool instructions. Raw closed native rollouts, exact thread/turn/time/model scope, registered task sidecars, artifact references and byte digests were archived before collection. All four positive tasks contained one correlated successful native terminal read, an exact clean final and two complete contiguous inference proof pairs. Their website proof remains selection-only; response-specific attribution and backend version remain unknown. The root tester reported the human Browser pane off and the private inference views hidden; those visibility observations are separate from the receipt's model and execution evidence.

Gemini temporarily showed its normal signed-in composer, allowing the fresh Flash-Lite task to complete. The subsequent Pro task failed page inspection at 14:00:43 UTC. At 14:05 UTC the root tester's protected human Gemini tab again displayed Google's unusual-traffic verification page with no usable composer. No CAPTCHA had been completed, and human verification remained pending. This later human-tab observation does not establish the failed Pro view's destination or exact cause. The missing sidecar does not prove zero website Sends, confirmed cleanup or available browser capacity. Gemini Flash remains unattempted until verification and cleanup/capacity are confirmed. At the same observation, Claude's new-chat page displayed `Your free messages return at 12:00PM`; the four fresh Claude fixtures remain unused until actual availability is observed.

Automated validation completed 187 unique native tests in nine classes in one zero-failure run (158.555 seconds), 248 provider adapter tests, 116 Web UI tests and TypeScript checking, 79 independent receipt/diagnostic/installed-identity QA oracles, and one Rust unsupported-routing boundary test. The interrupted original candidate16 native run is not a passing suite. Current source tests, artifact identity, the four live positives, one failure and five unattempted choices remain distinct claims. Product code and installed build17 are unchanged; this qualification update requires no new product test run or build. Complete qualification of all ten choices is still pending.

### Recorded candidate16 live results

The signed installed 0.4.0 (16) desktop candidate attempted all ten original choices on October 7, 2026. Each task used a plain request to read a fresh local file and return its contents. The native transport added its automatic background-only interaction policy; the user prompt supplied no tool names, harness instructions, or expected marker. Immutable raw rollouts, native sidecars when available, installed-artifact identity, and independent receipts were retained in the local qualification workspace.

| Provider | Website family | Full marker-turn result on candidate16 |
| --- | --- | --- |
| ChatGPT | GPT-5.5 | Verified native file read, clean final, two paired selection-only inferences. |
| ChatGPT | GPT-5.6 Sol | Verified native file read, clean final, two paired selection-only inferences. |
| ChatGPT | Latest | Failed malformed response envelope after one native file read; no clean final. |
| Gemini | 3.8 Flash | Verified native file read, clean final, two paired selection-only inferences. |
| Gemini | 3.5 Flash-Lite | Failed page inspection; no admitted native tool or exported choice proof. |
| Gemini | 3.1 Pro | Failed page inspection; no admitted native tool or exported choice proof. |
| Claude | Sonnet 4.6 | Verified native file read, clean final, two paired selection-only inferences. |
| Claude | Sonnet 5 | Failed malformed response envelope before any admitted native tool. |
| Claude | Haiku 4.5 | Failed malformed response envelope before any admitted native tool. |
| Claude | Sonnet 5.5 | Website usage limit after one native file read; no clean final. |

A separate fresh Latest retry on the same candidate failed ownership validation at `route_after`, with no native tool call or clean final. Its raw evidence and failed receipt remain separate from the original Latest attempt. Candidate17's subsequent route change and fresh fixtures do not convert that failure into a pass.

The two Gemini inspection failures logged an unexpected provider host without publishing its URL; cleanup was unconfirmed. A later human-browser observation showed Google's unusual-traffic verification page. That later observation does not prove the earlier redirect's destination. Further Gemini execution is gated by human verification and confirmed session cleanup/capacity. Further Claude execution is gated by the actual website usage-limit reset. Historical passes from candidate16 or earlier builds cannot substitute for fresh candidate17 receipts.

All four candidate16 positive receipts establish the website's selected family at submission and completion, alongside genuine local execution and the exact final marker. They contain no response-specific attribution or backend-version proof. Sidecar absence in a failed case establishes missing exported evidence, not zero website Sends, confirmed cleanup, or browser capacity.

## Rust boundary

This feature targets the Swift desktop runtime. Rust's model contract explicitly rejects concrete `browser/.../choice/...` IDs with `UnsupportedWebsiteModelChoice`; its external/local inference path cannot accept them accidentally. Rust concrete website selection remains unqualified and unsupported. The contract rejection test is a compatibility guard, not qualification of a Rust website transport. See [RUST-MIGRATION.md](RUST-MIGRATION.md) for the migration gate.

## Implementation references

- `Sources/Computa/Models/WebsiteModelCatalog.swift`: canonical IDs, validation, cache, and saved-choice options.
- `Sources/Computa/State/AppState.swift` and `WebUI/src/ModelSelector.tsx`: discovery lifecycle and selector states.
- `Sources/Computa/Browser/EmbeddedWebModelTransport.swift` and `Sources/Computa/Resources/BrowserModels/*.js`: owned-page discovery, selection, and fresh verification.
- `Sources/Computa/Browser/WebsiteModelEvidence.swift`: strict evidence levels and attribution identities.
- `Sources/Computa/Runtime/WebModelServer.swift` and `WebModelResponseCodec.swift`: session pinning, response admission, metadata, and private records.
- `Tests/ComputaTests/WebsiteModelCatalogTests.swift`, `WebsiteModelStateTests.swift`, `WebsiteModelEvidenceTests.swift`, `WebModelServerTests.swift`, and `EmbeddedWebModelTransportTests.swift`: native contract and failure coverage.
- `Scripts/embedded-model-choice-tests.ts` and provider adapter tests: deterministic DOM fixtures.
- `crates/computa-contracts/src/models.rs`: explicit Rust rejection of unqualified concrete choices.

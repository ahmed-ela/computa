# Kimi, Qwen and DeepSeek website adapters

Status: candidate build384 preparation, 2026-11-02 UTC. Installed 0.8.0 (383),
source `bc9173ff7c6566b1d3dd074dfcf3801be7b895a7`, failed Kimi's startup model
discovery before any prompt. Kimi Instant therefore did not appear in the
selector. Candidate384 addresses a reproduced initial-render failure path;
installed recovery and tool-use qualification remain pending. Qwen and DeepSeek
have no enabled native website adapter yet. PR #20 remains draft.

The requested route is each provider's signed-in website in Computa's browser.
Qwen's website is separate from Alibaba's existing Qwen 3.7 Flash API option.
Do not seed website choices from API catalogs or marketing model lists.

## Prepared implementation

- Provider-first menus recognize Kimi, Qwen and DeepSeek with bundled icons.
  They expose only supplied concrete choices, hide Website default and retain
  missing saved selections as disabled. No placeholder choices are supplied.
- Existing native providers declare their session lifecycle exhaustively:
  ChatGPT, Gemini and Claude use temporary chats; Groq clears the visible
  transcript; Kimi explicitly deletes its owned saved conversation. A future
  provider cannot inherit temporary mode merely by being different from Groq.
- Model selection, ownership, response acceptance and cleanup remain separate
  verification requirements. No retries or parsing protections changed.

Validation: 21 model-selector tests (404 assertions), WebUI type checking,
and 10 focused real-WebKit lifecycle tests passed. The latter include changed
ownership, lost temporary proof, ambiguous clearing controls and delayed or
unacknowledged cleanup without repeated actions. These are preparation and
regression results, not qualification of a new adapter.

Kimi's fixed adapter and native transport now implement one fresh inference
per saved conversation. The native Send claim precedes dispatch; a finite
acknowledgment binds only that click to the exact outbound digest, owner and
document. Provisional routes cannot authorize an answer. The canonical route
must independently prove the complete first user message, including the native
session marker, before response or deletion authority is acquired.

Deletion claims the header menu, Delete selection and confirmation separately,
once each. Subsequent observations are read-only. Success requires the exact
confirmed operation, return to the fresh page, an empty composer/transcript,
disconnected captured roots/dialog and removal of the owned history link.
It does not prove remote erasure. Ambiguous dispatch, foreign routes or lost
acknowledgments retain failure and the owned view instead of replaying actions.

The original plain WebKit fixture exposed rendered paragraph spacing and
smart-quote changes during prompt insertion. Its escaped `insertHTML` solution
passed that fixture, but a draft-only check in the actual Kimi Lexical editor
caught a missing behavior: the editor applies input asynchronously and flattens
the inserted paragraph HTML. The candidate was withheld before installation.
In the same approved test tab, one `insertText` operation instead preserved exact
multiline text, quotes and trailing spaces after asynchronous reconciliation,
in a `p > span[data-lexical-text="true"]` structure. No provider message was sent;
the draft was cleared and both developer settings restored. The corrected adapter
claims one text insertion, then uses the existing event-driven readiness wait
for exact settled readback before Send. Empty pending input grants no Send or
conversation authority; changed, replaced, cancelled or late drafts cannot be
reinserted. No fixed delay or text normalization was added.

The real-WebKit controlled-editor fixture now obtains its payload from the actual
`beforeinput` event, cancels default editing and commits asynchronously. A bounded
comparison established that unhandled default editing emits smart-quote replacement
events, whereas the controlled path returns success and preserves all input bytes.
This reproduces the live DOM result without claiming Kimi's exact framework version.
The corrected resource passed 39 JavaScript tests/349 assertions and 30 Kimi native
tests, including the full harness payload, delayed/failed insertion, deletion and
the actual WebKit-to-server durable receipt. Installed qualification remains pending.

Validation passed 31 JavaScript tests/242 assertions and 21 Kimi native tests
(10 contract and 11 real-WebKit cases). The native cases are included in the
230-test instruction/codec/correction/Kimi integration run, not additional to
it. They cover the full harness prompt, provisional/canonical transitions,
malformed output, delayed cleanup, cancellation and thrown callbacks after
Send or deletion confirmation. These fixture results support the installed
pilot; they do not establish live completion or cross-site tool reliability.
Only Instant is admitted: K3.1 Pro, K2.8 Preview, K3 and unknown/agent-family
choices remain unavailable to native inference.
The final Instant catalog-admission change and added native discovery regression
also passed a separate 51-test run: 12 existing transport, 11 Kimi contract,
12 Kimi real-WebKit and 16 catalog cases. These overlap the earlier batch and
must not be summed as independent coverage. Installed discovery and live
tool-use qualification remain pending.

A preinstall audit found that Kimi was absent from the durable cleanup receipt
provider enum and the persisted human-verification checkpoint set. Native
deletion had passed, but the missing receipt identity would have prevented the
server from saving its confirmation and releasing the response. Both finite
provider sets now include Kimi. A separate 24-test gate passed, including an
actual offline WebKit → server → durable deletion receipt/reload/retry workflow,
receipt schema/identity checks and checkpoint persistence. No affected build
was signed or installed. Shared server and app-state fixtures now use Kimi's
single admitted Instant choice; they do not invent a default or second model.

The broader shared integration gate passed 227 tests, with the optional synthetic
performance benchmark skipped. A separate 24-test failure-history gate passed:
Kimi's fixed unsupported-literal-response diagnostic now persists and restores
the exact failed turn, while altered or foreign-provider envelopes are rejected.
These counts include overlapping persistence coverage; they are not additional
live-provider qualifications. The subsequent nonempty production Lexical check
found the asynchronous insertion gap described above; its corrected focused gates
passed before installation.

## Live observations

### Build383 startup discovery and candidate384

After build383 was signed and installed, Settings showed `Kimi: The owned model
page or conversation changed (js_document_changed). No prompt was replayed.`
The normal Kimi tab was signed in at its root page. No native prompt was sent;
no Kimi choices were saved or exposed. The provider registry, snapshot bridge
and frontend all recognize Kimi: the selector intentionally hides Website
default and waits for concrete observed choices. The failure receipt is
`work/new-website-providers-20261102/build383/kimi-discovery-failure383.json`.

An offline reproduction removed each initial composer, Send control, model
trigger or model label in turn. All four returned `document_changed` with a
fixed structural detail that native code previously collapsed into the same
`js_document_changed` reason. This reproduces the reported error class; it does
not yet identify which control failed in the installed session.

Candidate384 accepts only a metadata-only pending signal while the untouched,
empty owned root is still mounting its first controls. It retains the existing
DOM wakeups and preparation deadline; it adds no fixed delay or input retry.
Any controls already seen are pinned. Duplicate or hidden controls, an existing
draft or transcript, changed owner/document/route, replaced controls and missing
controls after the first complete read or model claim still fail. Pending
hydration cannot supply readiness, model, conversation or Send authority.
Native diagnostics record only fixed action/error/detail identifiers; unexpected
JavaScript exceptions expose a fixed enum rather than arbitrary exception text.

The initial updated JavaScript suite passed 46 tests and 485 assertions, including
partial mounting, eventual discovery, changed bindings, post-claim disappearance
and no mutation while waiting. Native gate21 passed 46 tests: 13 saved-conversation
contract, 21 real-WebKit and 12 existing transport cases. Gate20's one failing
test had inspected a cached ready Poll snapshot after removing controls; it now
exercises Send's strict pre-input reinspection and proves zero input/Send. This
corrected the test boundary without relaxing production verification.

The subsequent attribute-only mounting check extends Kimi's existing observer
to the six selector attributes (`role`, `contenteditable`, `data-lexical-editor`,
`data-testid`, `aria-haspopup`, `id`). They emit wakeups only. Groq's observer
filter is unchanged. Kimi/Groq's focused JavaScript gate passed 109 tests and
1,390 assertions, including the new signal test and exact shared-core prefixes.
Final native gate22 passed 47 tests, including the real-WebKit case that restores
only the existing editor's `contenteditable` attribute and completes discovery
without input or Send. These overlapping fixture runs do not establish a live
fix, successful installed discovery, a response or tool-use qualification.

### Direct website observations before native qualification

Kimi's approved test tab uses `https://www.kimi.ai/`. Its model menu offered
K3.1 Pro, K2.8 Preview and Instant, plus K3 in the More models submenu. Two
harmless Instant JSON marker requests returned the exact expected objects.
No local tools were requested. The second approved Inspector check captured
the Lexical composer, enabled Send, exact user/assistant containers, literal
JSON code and assistant action rail. Thinking/tool-flow nodes are separate
from the final answer; an adapter must not treat their text as response text.

Submission first changed to a provisional `/chat/p…` route, then a final
`/chat/…` identifier. The adapter must bind any transition to the exact first
user message and owned document rather than adopting an arbitrary new URL.
Kimi uses a Lexical contenteditable composer and explicit saved-chat deletion.
For the synthetic conversation, the current-chat menu's Delete action opened
a confirmation; confirming once returned to the home page, cleared the
composer and removed that test row from rendered history. No deletion toast or
remote-erasure guarantee was established. This manual UI observation does not
alone establish an automated deletion-completion contract. The second test
confirmed the current header's ARIA-linked menu, a `confirm-dialog` with a
dedicated confirmation button, and the subsequent empty home page with no
test entry. Both test conversations are deleted. The original K3/High
selection, split position and developer settings were restored. No more
than the two approved messages were sent to the inspected Kimi tab.

Qwen is now signed in in Computa. Two bounded direct website checks on build382
selected Qwen3.7-Plus and Qwen3.8-Max, sent one harmless marker each and observed
the exact requested replies. Each test conversation was deleted through its
scoped menu and confirmation; the post-delete observations were retained.
These were direct website/DOM checks, not native harness requests or API tests.
The native Qwen adapter, completion/ownership contract and tool workflows remain
unqualified. Evidence is retained privately as `qwen-plus-direct-observation.json`
and `qwen-max-direct-observation.json` in
`work/new-website-providers-20261102/`.

DeepSeek is now signed in through the recognized existing account. Two bounded
direct checks, with DeepThink off and on, returned the exact raw JSON markers.
Each owned test conversation was deleted through its history entry and modal;
the fresh route, empty composer/transcript and absent test entry were verified.
Its page exposes a DeepThink mode toggle, not a named backend model picker.
Both responses had already finished by the first read, so a negative streaming
completion check and native harness qualification remain pending. Existing human
conversations were untouched. All three provider Inspector settings and Safari's
developer setting were restored after the approved two-message-per-provider scope.

## Remaining gates

1. Build and install candidate384 after its passing native gate, then verify Kimi Instant
   discovery, fresh replies and exact saved-conversation deletion before
   qualifying browser, terminal and file tasks. The provider catalog also
   drives automatic startup discovery; build383's discovery attempt failed.
2. Finish Qwen's fixed adapter and native ownership/cleanup integration from
   the observed website controls; keep it outside public discovery meanwhile.
3. Integrate DeepSeek's observed mode controls and scoped deletion chain, then
   verify its completion signal while an actual response is still streaming.
4. Preserve the same negative fixtures for route/model changes, duplicate
   controls, uncertain Send, lost ownership and delayed/unconfirmed deletion.
5. Record each installed model's actual tool results and durable cleanup
   separately. Fixture passes and direct markers do not qualify native tasks.

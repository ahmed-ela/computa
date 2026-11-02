# Kimi, Qwen and DeepSeek website adapters

Status: preparation in progress, 2026-11-02 UTC. The installed app remains
0.8.0 (381); none of these three native adapters is enabled yet.

The requested route is each provider's signed-in website in Computa's browser.
Qwen's website is separate from Alibaba's existing Qwen 3.7 Flash API option.
Do not seed website choices from API catalogs or marketing model lists.

## Prepared implementation

- Provider-first menus recognize Kimi, Qwen and DeepSeek with bundled icons.
  They expose only supplied concrete choices, hide Website default and retain
  missing saved selections as disabled. No placeholder choices are supplied.
- Existing native providers declare their session lifecycle exhaustively:
  ChatGPT, Gemini and Claude use temporary chats; Groq clears the visible
  transcript. A future provider cannot inherit temporary mode merely by being
  different from Groq.
- Model selection, ownership, response acceptance and cleanup remain separate
  verification requirements. No retries or parsing protections changed.

Validation: 21 model-selector tests (404 assertions), WebUI type checking,
and 10 focused real-WebKit lifecycle tests passed. The latter include changed
ownership, lost temporary proof, ambiguous clearing controls and delayed or
unacknowledged cleanup without repeated actions. These are preparation and
regression results, not qualification of a new adapter.

## Live observations

Kimi's approved test tab uses `https://www.kimi.ai/`. Its model menu offered
K3.1 Pro, K2.8 Preview and Instant, plus a More models submenu. The Instant
row was checked before a single harmless JSON marker request; its returned
code block matched the expected object exactly. No local tools were requested.

Submission first changed to a provisional `/chat/p…` route, then a final
`/chat/…` identifier. The adapter must bind any transition to the exact first
user message and owned document rather than adopting an arbitrary new URL.
Kimi uses a Lexical contenteditable composer and explicit saved-chat deletion.
For the synthetic conversation, the current-chat menu's Delete action opened
a confirmation; confirming once returned to the home page, cleared the
composer and removed that test row from rendered history. No deletion toast or
remote-erasure guarantee was established. This manual UI observation does not
yet establish an automated deletion-completion contract.

The user reported Qwen and DeepSeek signed in and authorized bounded Inspector
checks of all three existing test tabs. Their live response/deletion contracts
remain to be captured. Existing human conversations must remain untouched.

## Remaining gates

1. Capture each site's concrete model controls, enabled Send, exact user/answer
   containers, terminal completion signal and scoped deletion confirmation.
2. Implement the fixed adapters and explicit saved-conversation deletion
   lifecycle with one-dispatch operation claims and observation-only recovery.
3. Add fixtures for route/model changes, duplicate controls, uncertain Send,
   loss of ownership, delayed deletion and persistence failures.
4. Register providers for startup discovery only after discovery and inference
   both work. The current provider catalog also drives automatic discovery.
5. Qualify fresh replies and browser, terminal and file tasks through the
   installed app, with exact model/response and durable cleanup evidence.

# Computa extension engine

`Engine::dispatch` is the production owner of pairing, replay/generation admission,
finite command policy, temporary-copy leases, provider readiness, mutation guards,
timeouts, cancellation and cleanup. `platform/service-worker.js` executes returned
Chrome effects and routes events; `platform/dom.js` executes generic query plans
and atomic guards from Rust. Neither chooses providers or grants permission.

The generated Wasm module runs in the MV3 service worker. ChatGPT and Gemini use
temporary chat; Claude uses incognito. Claude binds the main document loader,
exact user-message counts, an unpredictable first-prompt marker, the first user
message ancestor ID and SHA-256 of its normalized rendered body. A document or
conversation replacement permanently removes mutation and cleanup authority.
Initial Claude read-only document/context races are retried for at most 45 seconds
before the first document is bound. Mutation failures are never retried.

The session ledger contains ownership evidence only, without transcript or prompt
bodies. Cleanup requires the exact bound conversation and temporary-mode evidence.
Successfully submitted temporary sessions report `temporary_closed`; unsent
sessions report `not_created`. These mean that the owned browser session closed,
not that the provider's separate safety-retention copy was erased. A replacement,
takeover or uncertain close retains a cleanup warning.

The separate bounded terminal-receipt ledger stores at most 64 verified tab-close
acknowledgements. Receipts carry the original epoch, generation, session token and
provider and survive a worker restart. The native proof store additionally requires
the original installation and pairing material on a newly verified native link.
They can settle an old cleanup request, but never restore mutation authority.

Run native policy tests with `cargo test -p computa-extension -p computa-contracts`.
After building the Wasm target and generating web bindings, run
`node crates/computa-extension/tests/wasm-smoke.mjs <generated-binding-directory>`.
This smoke test exercises actual generated bindings and JSON effect IDs; it does
not substitute for Chrome integration or live provider qualification.

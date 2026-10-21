# ChatGPT completion admission

ChatGPT's decoded `message_stream_complete` event can bypass the 1600ms quiet
fallback only when it refers to the submitted input and to the exact final
answer currently displayed. The event is an optional hint to run the existing
full verification; it cannot provide a transport response or dispatch tools.

`chatgpt-completion.js` observes an already initialized decoder in the recognized
website runtime. Its bounded, single-use lease binds the input's exact SHA-256,
sequence, one Send, decoder instance, conversation, and observed message lineage.
A successful final message with a subsequent terminal event is required. The
observer preserves the original decoder result or error and restores its own
wrapper on revocation. Unsupported runtime versions and response formats retain
the quiet fallback; no network stream interception or alternate Send path is used.

`ChatGPTResponseCompletion` binds that hint to the native view, document generation,
private owner, sequence, and original response deadline. The adapter then matches
its source text and assistant message ID to the current DOM. The transport retains
fresh model, Chat product, Temporary mode, user-message ownership, response-count,
nonbusy, and completion-control verification. It checks that the native receipt
is still current after the final await and immediately before publication.

Late mutations, errors, cancellation, navigation, another Send, conflicting IDs,
or expired leases revoke the hint. Empty or partial DOM, missing controls, changed
model or ownership, and unsupported text representations cannot use the fast path.
Tool envelopes still go through the normal parser and permission checks. A fenced
JSON envelope can match only an accepted literal code body or the specifically
observed DIL paragraph/span structure. The latter must retain the same message ID,
visible literal text, and exact source relation, including the observed outer
`<escape>` wrapper when present. This is a bounded representation match, not a
general Markdown or DIL parser. Extra prose, hidden content, ambiguous structure,
or different bytes retain the quiet fallback.

The optimization does not remove the 1600ms fallback globally. The recognized
runtime signature is deliberately narrow; website updates can reduce fast-path
coverage without admitting an unverified response.

## Validation

The final source passed 444 JavaScript tests (426 adapter and 18 decoder-observer
cases) and 48 selected native tests. These cover exact input hashing and lineage,
terminal ordering, retained rounds, duplicate streams, original decoder return/error
preservation, lease boundaries, and real WKWebView message delivery. Native cases
exercise fast completion before 1600ms only after fresh full proof, absent/stale
signals, delayed or changed DOM, final-await mutation/cancellation/revocation,
optimistic-to-durable user rendering, exact-body expansion, route promotion, and
the unchanged quiet fallback. Tests do not establish an installed-provider result.

Signed Computa 0.7.0 (188) was built from executable source
`909c9224906f38a3c0fc87e71f6f43a58ab831ea`; the native-focus and Gemini diagnostic
compiler flags are OFF. A later documentation-only commit does not change that
installed executable's source identity.

Validation receipts (SHA-256):

- Adapter suite: `832515f65fc9e1f3e0e230488b940295fe326e13cb674ef975b47b933dcf07bd`.
- Decoder-observer suite: `444da87e3b096a73670a2bd5931a00cdc85ef5ce3b8a755298543bfa2160dd46`.
- Native preservation suite: `995ac82ccc818f740b2f8cb010180c396910ad03bcf3df00d2c1470b60b74d5b`.
- Installed verifier: `d13130c67e309b1ef1bfdfa21d2b730efe87f342be99a729fed5cd4d824622ce`.

The build-186 trial failed an existing Temporary-mode check on the observed
optimistic direct `SPAN` body. Build 187 accepted its exact SVG outline, visibility,
scope and child counts, but then bound the full optimistic body before the regular
view replaced and clipped it. That attempt failed ownership verification. Neither
failed attempt qualifies a performance result; both are retained.

That optimistic body can briefly contain the full prompt before the regular view
collapses it behind Show more. A pending submission in this exact optimistic
shape therefore supplies no ownership or response proof. The existing document
events wake a fresh read after the regular view appears; normal expansion and
full-text hashing then establish ownership. This does not add a timer, replay
Send, rebind an already verified message, or extend the response deadline.

The first Send also retains a fresh product/Temporary recheck before native accepts
its acknowledgment. This narrowly scoped read returns only those controls; it
cannot pin the optimistic user body or publish a response. A route promotion
retains that scope and the original deadline. Ownership is established by the
normal acknowledged read after the durable message appears.

## Installed benchmark method and limits

Each prespecified pair uses the exact captured native payload, the same resolved
normal ChatGPT latest/Instant model, a fresh Temporary conversation and one Send.
Product/model proofs, current full-user-byte proof and task-owned cleanup are
required independently of the clocks. Failed and unqualified attempts remain in
the evidence; different response representations are recorded rather than silently
normalized or excluded.

The new direct diagnostic measures Send to correlated terminal admission and Send
to a matching final-message DOM-complete candidate. Its later full-user hash and
fresh ordered after-model reads are separate qualification steps. These are not
historical Probe5 first-text timestamps. Native logs measure the admitted candidate,
fresh final verification and transport completion; they do not timestamp provider
terminal decoding, so they cannot establish a native terminal-to-DOM interval.
Clock epochs and phase boundaries remain separate. The native isolated profile,
direct human profile, provider variability and fixed trial order also prevent
labeling an entire paired wall-clock difference as app overhead.

The [build-185 focus controls](CHATGPT-PRESEND-PROFILE.md#installed-build-185-native-focus-qualification)
remain historical evidence: both conditions used the focus-diagnostic-enabled
artifact; the normal condition had no acquisition. The achieved focus change did
not remove the measured gap, and first-text and completion-candidate endpoints
differed. Their 1780/1777ms candidate-to-completion observations are not a pooled
or controlled baseline for this new mechanism.

The observer recognizes one website runtime signature and complete single-text-part
terminal format. Unsupported signals or text relations retain the 1600ms fallback;
model, product, ownership and deadline failures still fail closed. Observer arming
has a separate preparation cap of one second before Send. Fast-path coverage and
end-to-end latency must therefore be measured on the installed provider, not
inferred from source or the removed fallback phase alone.

## Installed build-188 observations

Two completed native requests each had their own byte-identical 51,657-byte direct
control. Both pairs passed the declared terminal/DOM endpoint qualification,
current full-user proof, fresh latest/Instant model proof and owned cleanup.
The requests used different nonces/generated IDs; they are not one byte-identical
all-native A/B experiment.

| Pair | Native turn start → verified transport complete | First native candidate → complete | Native final full proof |
| --- | ---: | ---: | ---: |
| 1 | 5126ms | 396ms | 163ms |
| 2 | 6187ms | 155ms | 154ms |

| Pair | Direct prepared-page Send → terminal | Direct Send → matched complete DOM | Direct terminal → DOM |
| --- | ---: | ---: | ---: |
| 1 | 3213ms | 4030ms | 817ms |
| 2 | 3658ms | 4159ms | 501ms |

Both native requests used decoded-terminal admission without waiting the full
1600ms. Pair 1 changed its candidate before final proof; its latest candidate to
completion was 164ms, while the table retains the first-candidate interval. This
shows the fast path running after verification, not a universal end-to-end
speedup. The historical quiet fallback remains implemented and separately tested.

Native UI-before-Send to verified transport completion was approximately 6478ms
and 8632ms. Those host-wall estimates include preparation; the direct page clocks
start after preparation. Direct full-body expansion/hash and after-model proof
were collected later with operator delay. Do not subtract or divide these unlike
endpoints as app overhead or automatic verification latency. Pair 1 returned a
fenced message envelope; pair 2 returned plain HI. Raw source and DOM relations
were retained. Early Running UI, the zero-Send setup failure, legacy root-lease
invalidations, and the failed build-186/187 attempts remain in their original
scopes and were not promoted into these results.

Saved two-pair audit: `native188-two-pair-analysis1.json`, SHA-256
`340b5073eb1c0fc2b545cdcca8502439ca5359aca4633e33d9a4a34d9e0fa10b`.
These two pairs establish the observed mechanism and declared endpoint results,
not a reliability rate or a provider latency distribution.

## Installed tool workflow checks

Both fresh V87 tasks passed all 12 workflow checks each. Each task inspected and
patched only its isolated helper, preserved the unrelated note and tests, ran
four unit tests and the helper command, opened the built-in browser, submitted
one exact flight reference, returned the displayed departure/gate/receipt, and
closed its created tab. Eight additional independent test executions passed;
protected-file and allowed-diff checks passed. No native terminal errors,
nonzero command exits, failed website inferences or unverified browser calls
were recorded. All 22 website inferences were saved and closed.

The fixture server was stopped and reaped; its PID was absent and its loopback
port refused connections. Both browser tabs were closed. Safari's temporary
Show features for web developers setting was restored off. These controlled
workflows establish the observed code/terminal/browser behavior, not universal
provider reliability.

Evidence: `optimized188-fixtures1.json`, SHA-256
`c782d6045c7131548b47fe52ed89183fd22f6624f29f315f8b86a0af1813369f`;
independent verifier results `ba531d720b7ed3ba2fd65e7e5cf9509a44b0dc5a9d0c8b637962c1a9ceb2ebff`
and `c30bfea074009e62a722cbd3911148b9c89ce2c7c81ab9f8e31a27b86b90671a`.

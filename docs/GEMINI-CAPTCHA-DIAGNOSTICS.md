# Automatic Gemini CAPTCHA evidence

Starting with Computa 0.7.0 build 333, the persistent built-in browser saves a
small local incident report when a trusted Google verification response or
page is observed, or the Gemini adapter reports verification required. The
capture runs automatically; Web Inspector and its developer settings are not
needed. This adds evidence for the unresolved recurrence, not a prevention fix.

Installed-source checkpoint: `f58c5c7d92324d5a24fcc28d1ea175452acad170`.
On October 31, 2026 at 10:41 UTC (06:41 EDT), one fresh Gemini 3.5 Flash-Lite
request passed in 8.035 seconds without a challenge. The
[dated recovery record](GEMINI-HARNESS-QUALIFICATION.md#october-31-dated-recovery-and-merge-checkpoint)
separates the earlier approved CAPTCHA recovery from this diagnostic change and
records the exact last action, validation and remaining limits.

Reports live in:

```text
~/Library/Application Support/LocalCodex/CodexHome/GeminiCAPTCHADiagnostics-v1/<incident-uuid>.json
```

The directory is private (`0700`), files are private (`0600`), and reports remain
after tab cleanup and app restart. Successful persistence means a complete
write, file sync, atomic publication, directory sync and readback succeeded
while the exact view was still registered. `geminiCAPTCHADiagnostic` in the app
log records the incident ID and `result=saved` or `result=not_saved`. Nothing is
uploaded automatically.

## What is captured

- Up to 32 allowlisted main-frame request, redirect-callback and response
  observations from that physical tab, with callback-time generation IDs,
  millisecond timestamps and dropped-event counts.
- Request method and cache policy, and whether Cookie, Referer and Authorization
  fields were exposed in the delegate's request metadata. Absent fields remain
  unknown. Values and request bodies are never retained.
- The existing finite response projection: destination category, HTTP status,
  Cache-Control flags and bucketed Date/Age/Expires metadata.
- Up to eight existing shared-profile cookie timeline events, including sample
  age/context, pending/unavailable outcomes, budget gaps and dropped counts.
  They are historical observations, not a fresh read of this request's cookies.
- The incident's tab/generation IDs, human/model/tool role, trigger and available
  finite native loading/commit/finish/error facts.

No raw URLs or query strings, cookie values, arbitrary headers, prompts, answers,
page text, screenshots, account/profile identifiers or secret-derived hashes are
stored. Unknowns are explicit. Public WebKit callbacks cannot establish which
cookies reached Google, the network-versus-cache source, or a complete redirect
chain. Request callbacks may precede a document-generation change; event
generations are observation context, not proof of a shared navigation token.

## Ordering and bounds

The response callback captures before allowing navigation to proceed. Native
page and adapter detection cover failures without such a response. `closeTab`
has a final fallback before removing the entry, changing its generation,
detaching delegates or stopping loading. Cancellation and shutdown use that
same ordering. A saved provider gate inherited by another task does not create
fictitious request evidence for that task.

The first report for a generation is immutable and repeated detection is
deduplicated. If the challenge response callback arrives after a native or
adapter capture, one linked supplement preserves the newly available response;
its preceding capture ID does not assert that the earlier save succeeded.
A failed save gets at most one retry with the same frozen report at teardown.
There are at most eight save attempts per minute, with explicit
log outcomes when the budget is exhausted. No extra navigation, page evaluation,
cookie read, CAPTCHA completion or five-second diagnostic hold is introduced.
Verification and cleanup authority remain unchanged.

Storage keeps the latest 16 reports and caps report data at 64 KiB each and the
directory's recognized evidence at 1 MiB. Retention removes only validated,
privately owned generated report files. Unsafe entries, unavailable parents,
disk errors or exhausted bounds produce an explicit save failure; they do not
replace the original website error or prevent normal cleanup. The filesystem
sync can add local I/O latency on the failure path, but successful requests do
not write reports.

## Validation scope

All 219 focused native tests passed, including 34 new diagnostic tests. The
focused tests cover the finite projection and secret exclusion, bounded
history, storage permissions and atomicity, retention, save-before-close
ordering, invalid target rejection, and failure paths. They use synthetic
metadata and local pages, without sending traffic to Google. Live recurrence
evidence must still be interpreted separately; this feature does not establish
the cause of Google's CAPTCHA or guarantee it will never recur.

The current Gemini adapter does not emit the generic JavaScript
`website_verification_required` result, so that defensive transport branch is
compiled but not exercised by the fixture suite. Native response, trusted URL,
cleanup-first, cancellation and shutdown paths are exercised. The test receipts
are in `native333-full-repaired/{plan.json,test.log,result.json}` under the local
Gemini qualification evidence root. Earlier failed runs are retained: one test
helper syntax error and temporary-directory aliases were corrected without
changing production path validation.

# Guarded headless MLX transport: first live run

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

This is a synthetic transport result, **not** an end-to-end Computa computer-use
or native App Server pass. The root operator ran the bundled guarded backend
serially on loopback with Qwen3.5-4B MLX 4-bit. No real computer/shell tool was
executed. Production instructions and inherited policy were retained. Requests
used full history, `store:false`, temperature 0.1, and a 4096-output-token cap;
medium reasoning was used except the first-public-text cancellation request,
which explicitly disabled reasoning. The server's thinking budget was 512.

Private evidence directory: `/tmp/heydash-mlx-guarded-20260925.yinNsm`.
Evidence is mode 0700/0600; raw prompts, screenshots and reasoning are not
reproduced here. The process was subsequently stopped by the root operator.

## Results

| Gate | Result | Observed latency |
| --- | --- | ---: |
| Exact text marker | Pass: public answer and streamed/final text agree | 8.073 s total; first public text 7.956 s |
| Read-only tool + result continuation | Pass: exact arguments/call ID, lifecycle and answer | 1.338 s call + 0.702 s continuation |
| Screenshot inside tool result | **Strict gate failed**: output used a Markdown JSON fence | 1.606 s call + 5.046 s continuation |
| Disconnect after first public text + next request | Pass | Disconnect 0.454 s; next response 3.606 s |
| Immediate disconnect after `response.created` + next request | Pass at that observable boundary | Disconnect 7.249 ms; next response 3.560 s |

These are one-off timings, not medians, throughput benchmarks or a matched
LM Studio comparison. The first text request includes backend/model startup
effects. Its 526 output tokens include reasoning and answer; token counts are
not synonymous with public-token generation speed.

### Screenshot result remains a strict failure

Independent read-only auditing of the recorded image events confirmed:

- Exactly one successful terminal envelope with the expected model/response
  identity and internally consistent token usage.
- Public deltas and final public text match byte-for-byte.
- The read-only image fixture function used the exact matching call ID in its
  continuation, with one actual `input_image` inside `function_call_output`.
- The public fenced payload's values were `left: Queued`, `right: Complete`,
  matching the independent frozen-image oracle.
- The requested bare JSON format was not respected. `JSON.parse` correctly
  failed on the fence; neither the original gate nor its oracle was changed.

Thus the image transport and observed semantic reading worked, but **the image
compound gate did not pass**. This is not evidence of universal vision accuracy.

### Cancellation limits

The immediate early trial received only one `response.created` event at
7.167 ms and disconnected at 7.249 ms. It received no public text or terminal
event. That may precede the upstream call to `generate`, so it does not establish
cancellation during GPU prefill or the pre-iterator ownership race.

Both cancellation cases reported guarded `busy:false` afterward and passed an
independent following request. The health endpoint exposes neither worker
in-flight count nor internal queue depth; both remain `null` in the audit.
**GPU drain was not independently proved.** A separate controlled delayed
disconnect is justified and has been prepared, but was not part of this run.

Final reported MLX allocator counters were active **3,186,852,706 bytes**, cache
**46,938,310 bytes**, peak **4,293,731,218 bytes**. These are not the process's
physical footprint or total unified-memory usage, and do not show memory freed
on process exit.

## Provenance audit

All nine saved request/event pairs were rehashed from their parsed canonical
JSON and matched their recorded SHA-256 values. The four benchmark source files
also matched the summary's recorded hashes **before** the later delayed-probe
extension. The extension deliberately changes runner/cancellation hashes; it
does not modify this historical evidence or redefine the immediate-early gate.

| Artifact | SHA-256 recorded for this run |
| --- | --- |
| Raw summary file | `9a31fda13d2d62c2d10b9b1be708a95b47d468a156bcf51831bf8305ee58cb37` |
| Runner | `20e4140ea016d54eac40d549cdf06e8a8d5b7940bf9c65c3b0c1908bea510741` |
| Stream contract | `9dd29596035a2d32d2a4723756785b837f5aad086b34acfcad4f59ca1eabf565` |
| Observation helper | `634057bbff395fd8c0274cd927b24028fb8e2406d9a9348dfeb05bc6c5cd0394` |
| Cancellation helper | `17245d7bc59a21af069f96e4021e9c3847ccab702b185d5bc6f7d592510956bc` |
| Frozen screenshot | `4b77a20428bfdba6c236967ccca4f266992c81c0c98dd0bdb192e9a84964aa56` |
| Image continuation request | `ff274be503adc01d00b9c2b38f5a1f78dbc5a980e54eee7e91d850038a9b3f2c` |
| Image continuation events | `3e73f01ffe5dfb266a808c0f0ee418326086a279c5ce3c8b1245f2acfef66dbd` |

The runner summary freezes its own client/source/input provenance. It does not
itself capture the server binary/source hash; use the owning session's separate
runtime/build evidence for that boundary. Current edited server source alone
must not be substituted as proof of the exact implementation used historically.

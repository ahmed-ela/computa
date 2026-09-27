# Next task: evidence-based lookup comparison

Status: pending. Run the baseline comparison **before** implementing the broader
content/evidence changes. Do not treat the existing pagination fix as a completed
lookup-quality fix.

## 1. Establish the result in Chrome

- [ ] Use Chrome to perform the user's task:

  > there was a chat thread in chatgpt on chrome that had a list of all research papers that came out from openai can you find it

- [ ] Verify the candidate from its actual displayed content and source URL,
  not its title or sidebar. A matching conversation does not establish that its
  paper list is exhaustive or factually complete.
- [ ] Preserve existing tabs and drafts. Do not send website messages. Keep
  personal conversation content and URLs out of committed benchmark artifacts.

## 2. Measure unchanged Mactopus

- [ ] Submit the same task to a fresh chat in the installed Mactopus with
  Qwen 3.5 4B. Do not provide the answer, candidate title/URL, or a tool sequence.
- [ ] Avoid contaminating the starting state: do not leave the discovered
  conversation newly opened, selected, or attached by Codex as a shortcut or
  debugger conflict. Record any unavoidable starting-state differences.
- [ ] Observe the production app's own tool calls and task-scoped recording.
  Record elapsed time, input/output successes and failures, inventory coverage,
  document coverage, continuation use, compactions, and final-answer support.
- [ ] Distinguish failure to read/search from a verified negative result. Do
  not count listing tab metadata as reading those pages.

## 3. Implement the generalized fix from the measured gap

- [ ] Distinguish metadata, navigation, UI controls, and readable content using
  observed structure. Main-region membership alone is not content evidence:
  toolbars can live inside main regions.
- [ ] Expose useful content efficiently with explicit source, field, and output
  truncation. Keep controls/navigation reachable and preserve action authority.
- [ ] Support bounded continued reading when the exposed evidence is insufficient.
  Do not hardcode ChatGPT, paper names, this thread, or a particular site.
- [ ] Preserve host-owned read coverage across compaction so summaries cannot
  promote incomplete observations into an exhaustive inspection. Accumulate
  coverage only within the same immutable source observation, filters, and
  subtree; never combine different captures into apparent completeness.
- [ ] Match evidence requirements to the conclusion: a title lookup can use
  metadata; content lookup needs supporting content; an itinerary answer needs
  observed itinerary details. Structural checks do not guarantee semantic truth.

## 4. Validate generalization

- [ ] Repeat the original blind lookup and compare with the unchanged baseline.
- [ ] Test different task types: exact-title lookup, document-content lookup,
  email/detail extraction, and a native-app read, preferably with inert fixtures.
- [ ] Cover misleading sidebar matches, controls inside main regions, absent
  landmarks, truncated fields/trees, virtualized content, stale/replaced source
  observations, pagination, and compaction without replaying completed actions.
- [ ] Report correctness, unsupported claims, refusals, latency, and coverage
  separately. Preserve background-only operation, permissions, pairing, chats,
  and existing user tabs. No production-readiness claim from one successful task.

## Current evidence

The existing read-continuation patch passed 1,580 tests (49 skipped) and a signed
Release build. It is installed locally. A read-only installed-app trial retrieved
all 42 current tab entries via the new inventory continuation without the old
cursor error. That trial **failed** the lookup: Qwen consumed no page-content
continuations and relied on navigation/title information. Two later presses were
rejected before dispatch; the trial was stopped after 88.322 seconds. Two
compactions completed, but no verified matching answer was produced. This is a
pagination-path success, not a content-search success or the comparison above.

The interrupted follow-up began investigation only; the broader generalized fix
and the independent Chrome-versus-Mactopus comparison have not been implemented
or completed. See [the current contract](docs/BROWSER-READ-CONTINUATIONS.md).

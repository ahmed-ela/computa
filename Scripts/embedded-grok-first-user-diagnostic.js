// Failure-only, closed metadata. Never return prompt/page text, markers, hashes
// or DOM identifiers. A diagnostic read must not replace the original failure.
function computaGrokFirstUserFailure(c, state, stage, reason, transcript, identity = 'not_checked') {
  const failure = { computaAdapterFailure: true, error: 'conversation_changed', detail: 'first_user_message' };
  try {
    const cap = 220001, bounded = text => typeof text === 'string' && text.length < cap ? text : null;
    const body = transcript?.body || null;
    const rawObserved = typeof transcript?.text === 'string' ? transcript.text : body ? body.innerText : null;
    const rawExpected = typeof state.prompt === 'string' ? state.prompt : null;
    const observed = bounded(rawObserved) === null ? null : c.bodyText(rawObserved);
    const expected = bounded(rawExpected) === null ? null : c.bodyText(rawExpected);
    const rawContent = body ? body.textContent : null;
    const content = bounded(rawContent) === null ? null : c.bodyText(rawContent);
    const length = text => typeof text === 'string' ? Math.min(cap, text.length) : null;
    const lines = text => {
      if (typeof text !== 'string' || text.length >= cap) return null;
      let count = 1;
      for (let index = 0; index < text.length && count < cap; index++) if (text[index] === '\n') count++;
      return count;
    };
    const comparable = observed !== null && expected !== null;
    const difference = !comparable ? 'unavailable' : observed === expected ? 'none'
      : observed.replace(/\n+/g, '\n') === expected.replace(/\n+/g, '\n') ? 'blank_lines'
      : observed.replace(/\s/g, '') === expected.replace(/\s/g, '') ? 'whitespace' : 'other';
    failure.grokFirstUserFailureDiagnostic = {
      version: 1, stage, reason, users: Math.min(4, transcript?.users?.length || 0),
      answers: Math.min(4, transcript?.answers?.length || 0), bodies: Math.min(4, transcript?.bodies?.length || 0),
      bodyVisible: body ? c.visible(body) : null,
      // 220001 is a saturation sentinel, not an exact oversized length.
      observedUTF16: length(observed ?? rawObserved), expectedUTF16: length(expected ?? rawExpected),
      observedLines: lines(observed ?? rawObserved), expectedLines: lines(expected ?? rawExpected),
      textContentMatches: content !== null && expected !== null ? content === expected : null,
      innerTextMatches: comparable ? observed === expected : null, textDifference: difference, identity,
    };
  } catch { /* Preserve the original failure even if metadata cannot be read. */ }
  throw failure;
}

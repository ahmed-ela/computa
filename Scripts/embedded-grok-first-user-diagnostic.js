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
    // Locate only an already-rejected, bounded literal mismatch. All values are
    // offsets, counts or closed categories; no expected/observed text escapes.
    if (reason === 'payload_text' && comparable && observed !== expected) {
      let offset = 0, expectedEnd = expected.length, observedEnd = observed.length;
      while (offset < expectedEnd && offset < observedEnd && expected[offset] === observed[offset]) offset++;
      while (expectedEnd > offset && observedEnd > offset && expected[expectedEnd - 1] === observed[observedEnd - 1]) {
        expectedEnd--; observedEnd--;
      }
      const row = (text, index) => {
        index = Math.min(index, text.length);
        const start = text.lastIndexOf('\n', index - 1) + 1;
        const next = text.indexOf('\n', index), end = next < 0 ? text.length : next;
        const value = text.slice(start, end), trimmed = value.trim();
        const kind = !trimmed ? 'blank' : trimmed.startsWith('Computa session marker: ') ? 'marker'
          : /^`{3,}/.test(trimmed) ? 'fence' : /^[{\[]/.test(trimmed) ? 'json_like'
          : /^[A-Za-z]/.test(trimmed) ? 'prose' : 'other';
        return { line: lines(text.slice(0, start)), column: index - start + 1, length: value.length, kind };
      };
      const firstExpected = row(expected, offset), firstObserved = row(observed, offset);
      const lastExpected = row(expected, Math.max(offset, expectedEnd - 1));
      const lastObserved = row(observed, Math.max(offset, observedEnd - 1));
      const fixed = ['COMPUTA_CURRENT_RUNTIME_CONTRACT:', 'COMPLETE_RESPONSES_REQUEST_JSON:',
        'COMPUTA_CURRENT_USER_LOCATOR:', 'COMPUTA_LOCAL_RESPONSE_HANDOFF:', 'Computa session marker: '];
      const positions = fixed.map(marker => {
        const key = '\n' + marker, first = expected.startsWith(marker) ? 0 : expected.indexOf(key) + 1;
        return first < 0 || (first === 0 && !expected.startsWith(marker))
          || expected.indexOf(key, first + marker.length) >= 0 ? -1 : first;
      });
      let component = 'unknown';
      if (positions.every((value, index) => value >= 0 && (index === 0 || value > positions[index - 1]))) {
        const names = ['runtime', 'request', 'current_user', 'response', 'marker'];
        for (let index = 0; index < positions.length; index++) if (offset >= positions[index]) component = names[index];
      }
      const near = (text, character) => {
        let count = 0;
        for (let index = Math.max(0, offset - 32); index < Math.min(text.length, offset + 32); index++) {
          if (text[index] === character) count++;
        }
        return count;
      };
      failure.grokFirstUserFailureDiagnostic.mismatch = {
        offset, line: firstExpected.line, column: firstExpected.column, component,
        lastExpectedLine: lastExpected.line, lastObservedLine: lastObserved.line,
        expectedFirstLineLength: firstExpected.length, observedFirstLineLength: firstObserved.length,
        expectedLastLineLength: lastExpected.length, observedLastLineLength: lastObserved.length,
        expectedFirstKind: firstExpected.kind, observedFirstKind: firstObserved.kind,
        expectedLastKind: lastExpected.kind, observedLastKind: lastObserved.kind,
        nearBackticksExpected: near(expected, '`'), nearBackticksObserved: near(observed, '`'),
        nearBackslashesExpected: near(expected, '\\'), nearBackslashesObserved: near(observed, '\\'),
      };
    }
  } catch { /* Preserve the original failure even if metadata cannot be read. */ }
  throw failure;
}

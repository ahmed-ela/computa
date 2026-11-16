// Grok initially mounts its first user/answer articles with visibility:hidden
// and can replace them before revealing them. This is only a negative read:
// no hidden node is bound, hashed, or exposed as response/cleanup authority.
function computaGrokTranscriptRenderingPending(c, state, input, guard, privateEvidence, modelEvidence) {
  if (input.action !== 'inspect' || input.allowGrokTranscriptRenderingPending !== true
    || !state.submitted || !state.privateEntered || state.stopped || state.first
    || input.expectedFirstUserFingerprint != null || input.allowFirstUserBinding !== true
    || !Array.isArray(input.expectedUserCounts) || input.expectedUserCounts.length !== 2
    || input.expectedUserCounts[0] !== 0 || input.expectedUserCounts[1] !== 1
    || typeof state.prompt !== 'string' || !c.uuid(state.marker)
    || input.expectedFirstUserMarker !== state.marker || !c.equalChoice(state.grokExpectedModel, input.expectedModelChoice)) return false;
  guard();
  const users = c.nodes(document, '[data-testid="user-message"]', 4);
  const answers = c.nodes(document, '[data-testid="assistant-message"]', 4);
  if (users.length !== 1 || answers.length > 1) return false;
  const roots = [...users, ...answers];
  const logs = c.nodes(document, 'div[role="log"][data-testid="chat-transcript-scroller"]', 4);
  if (logs.length !== 1) return false;
  const log = logs[0];
  const hasLayout = node => node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).display !== 'none'
    && !node.closest('[hidden], [inert], [aria-hidden="true"], [contenteditable], pre, code');
  if (!hasLayout(log) || log.closest('[data-testid="user-message"], [data-testid="assistant-message"]')) return false;
  if (roots.some(node => node.getAttribute('role') !== 'article' || !hasLayout(node)
    || getComputedStyle(node).visibility !== 'hidden'
    || node.closest('[role="log"][data-testid="chat-transcript-scroller"]') !== log)) return false;
  const bodies = c.nodes(users[0], 'span[data-bubble-text]', 4);
  if (bodies.length !== 1 || !hasLayout(bodies[0])
    || getComputedStyle(bodies[0]).visibility !== 'hidden'
    || bodies[0].closest('[data-testid="user-message"]') !== users[0]) return false;
  // Equality is a rejection guard, never a hidden-body ownership proof.
  const text = c.bodyText(bodies[0].textContent), line = `Computa session marker: ${state.marker}`;
  if (text !== c.bodyText(state.prompt) || !text.endsWith('\n\n' + line)
    || text.split('\n').filter(value => value === line).length !== 1) return false;
  if (!privateEvidence() || !c.equalChoice(modelEvidence()?.selected, state.grokExpectedModel)) return false;
  guard();
  return true;
}

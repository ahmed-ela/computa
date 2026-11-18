// One Grok-only wake per pending read. Layout completion never grants an
// action: the next adapter invocation repeats every identity and hit check.
function computaGrokAwaitLayout(c, state, node, isCurrent, occluder = null) {
  const originalDocument = document, owner = state.owner, generation = state.generation;
  const chains = [...new Set([node, occluder].filter(Boolean))].map(root => {
    const ancestors = [];
    for (let current = root; current; current = current.parentElement) ancestors.push(current);
    return { root, ancestors };
  });
  const targets = new Set(chains.flatMap(chain => chain.ancestors));
  const types = ['transitionend', 'transitioncancel', 'animationend', 'animationcancel'];
  state.layoutWait?.remove();
  const wait = { remove: () => {
    for (const type of types) originalDocument.removeEventListener(type, wake, true);
    if (state.layoutWait === wait) state.layoutWait = null;
  } };
  const wake = event => {
    const current = state.layoutWait === wait && document === originalDocument && state.document === originalDocument
      && state.owner === owner && state.generation === generation && c.context() && isCurrent()
      && chains.every(({ root, ancestors }) => root.isConnected && ancestors.every(ancestor => ancestor.contains(root)));
    if (!current) { wait.remove(); return; }
    if (!targets.has(event.target)) return;
    wait.remove();
    try { window.webkit?.messageHandlers?.computaChatGPTSignal?.postMessage({ ownerToken: owner, kind: 'dom_changed' }); }
    catch { /* A missing wake channel cannot grant readiness. */ }
  };
  state.layoutWait = wait;
  for (const type of types) originalDocument.addEventListener(type, wake, true);
}

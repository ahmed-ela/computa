async function computaDOM(plan) {
  // Platform-only DOM primitives. Selectors, guards, limits and actions come
  // from the Rust policy engine; this program contains no provider branches.
  if (window !== window.top || document.URL !== plan.url) return { error: "document_changed" };
  const visible = node => !!node && node.isConnected && node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== "hidden" && !node.closest('[inert],[aria-hidden="true"]');
  const enabled = node => visible(node) && !node.disabled && node.getAttribute("aria-disabled") !== "true";
  const facts = {};
  for (const query of plan.queries) {
    let nodes = [...document.querySelectorAll(query.selector)];
    if (query.visible) nodes = nodes.filter(visible);
    if (query.excludeClosest) nodes = nodes.filter(node => !node.closest(query.excludeClosest));
    if (query.outerOnly) nodes = nodes.filter(node => !nodes.some(other => node !== other && other.contains(node)));
    if (query.limit) nodes = nodes.slice(0, query.limit);
    facts[query.key] = nodes.map((node, index) => {
      const textNode = query.textSelector ? node.querySelector(query.textSelector) || node : node;
      const text = query.text === false || (query.firstTextOnly && index > 0) ? "" : (textNode.innerText || textNode.textContent || "");
      if (text.length > 220001) return { overflow: true };
      const value = typeof node.value === "string" ? node.value : (node.innerText || node.textContent || "");
      const result = { text, value: query.key === "composer" ? value : "", enabled: enabled(node) };
      if (query.attributes) result.attributes = Object.fromEntries(query.attributes.map(key => [key, node.getAttribute(key)]));
      if (query.ownerId) result.ownerId = node.closest("[id]")?.getAttribute("id") || "";
      if (query.streamingSelector) result.streaming = node.closest(query.streamingSelector)?.getAttribute("data-is-streaming") || "";
      if (query.copySelector) {
        let ancestor = query.ancestorSelector ? node.closest(query.ancestorSelector) : node;
        const depth = query.ancestorSelector ? 1 : query.ancestorDepth || 1;
        result.copyEnabled = false;
        for (let index = 0; ancestor && index < depth; index++, ancestor = ancestor.parentElement) {
          if (query.countSelector && ancestor.querySelectorAll(query.countSelector).length > 1) break;
          const copy = ancestor.querySelector(query.copySelector);
          if (enabled(copy)) { result.copyEnabled = true; break; }
        }
      }
      return result;
    });
  }
  if (Object.values(facts).some(nodes => nodes.some(node => node.overflow))) return { error: "response_too_large" };
  if (plan.guards) {
    for (const [key, expected] of Object.entries(plan.guards)) {
      if (JSON.stringify(facts[key]) !== JSON.stringify(expected)) return { error: "conversation_changed" };
    }
  }
  if (plan.action) {
    if (document.URL !== plan.url) return { error: "document_changed" };
    const node = [...document.querySelectorAll(plan.action.selector)].find(visible);
    if (!enabled(node)) return { acted: false };
    if (plan.action.kind === "focus") {
      HTMLElement.prototype.focus.call(node);
      return { acted: document.activeElement === node || node.contains(document.activeElement) };
    }
    if (plan.action.kind === "click") { HTMLElement.prototype.click.call(node); return { acted: true }; }
    return { error: "unknown_action" };
  }
  return { url: document.URL, facts };
}

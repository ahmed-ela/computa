// Negative website status only. No response, ownership or cleanup authority.
function computaGrokUsageLimited(c) {
  const authored = node => node.closest('[data-testid="user-message"], [data-testid="assistant-message"], [contenteditable], pre, code');
  const cards = c.nodes(document, 'div[data-testid="usage-limit-notice"][role="status"][aria-live="polite"][data-slot="alert"]', 4)
    .filter(node => c.visible(node) && !authored(node));
  if (cards.length !== 1) return false;
  const card = cards[0], parent = card.parentElement;
  if (parent?.tagName !== 'DIV' || !/^response-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(parent.getAttribute('id') || '')) return false;
  const contents = c.nodes(card, 'div[data-slot="alert-content"]', 4), titles = c.nodes(card, 'p[data-slot="alert-title"]', 4);
  const buttons = c.nodes(card, 'button', 4);
  if (contents.length !== 1 || contents[0].parentElement !== card || titles.length !== 1
    || titles[0].parentElement !== contents[0] || buttons.length !== 1
    || ![contents[0], titles[0], buttons[0]].every(c.visible)) return false;
  return c.normalize(titles[0].textContent) === 'Free tier limit reached'
    && c.normalize(contents[0].textContent) === 'Free tier limit reachedTry again later or upgrade for much higher limits and premium features.'
    && c.normalize(buttons[0].textContent) === 'Upgrade';
}

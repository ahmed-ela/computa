export async function copyText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(text); return; } catch { /* Try the WebKit custom-scheme fallback. */ }
  }
  const previous = document.activeElement as HTMLElement | null;
  const field = document.createElement('textarea');
  field.value = text;
  field.style.cssText = 'position:fixed;left:-10000px;top:0';
  document.body.appendChild(field);
  try {
    field.select();
    if (!document.execCommand('copy')) throw new Error('Copy failed. Select the text and copy it manually.');
  } finally {
    field.remove();
    previous?.focus({ preventScroll: true });
  }
}

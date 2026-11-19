export async function copyText(text: string, html?: string): Promise<void> {
  try {
    if (html !== undefined && navigator.clipboard?.write && typeof ClipboardItem !== 'undefined') {
      await navigator.clipboard.write([new ClipboardItem({
        'text/plain': new Blob([text], { type: 'text/plain' }),
        'text/html': new Blob([html], { type: 'text/html' }),
      })]);
      return;
    }
    if (html === undefined && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch {
    // The app's custom WebKit scheme also supports the synchronous copy event.
  }
  const previous = document.activeElement as HTMLElement | null;
  const field = document.createElement('textarea');
  field.value = text;
  field.style.cssText = 'position:fixed;left:-10000px;top:0';
  document.body.appendChild(field);
  let wroteHTML = false;
  function writeFormats(event: ClipboardEvent) {
    if (html === undefined || !event.clipboardData) return;
    event.clipboardData.setData('text/plain', text);
    event.clipboardData.setData('text/html', html);
    event.preventDefault();
    wroteHTML = true;
  }
  try {
    field.select();
    if (html !== undefined) document.addEventListener('copy', writeFormats);
    if (!document.execCommand('copy') || (html !== undefined && !wroteHTML)) {
      throw new Error('Copy failed. Select the text and copy it manually.');
    }
  } finally {
    if (html !== undefined) document.removeEventListener('copy', writeFormats);
    field.remove();
    previous?.focus({ preventScroll: true });
  }
}

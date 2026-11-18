// Grok's editable grows inside nested overflow scrollports. The viewport-only
// midpoint can be outside those scrollports even while the editor is visible.
// This opt-in changes only that editor's geometry; it does not search for an
// alternative point around an overlay or change any other provider's checks.
function computaGrokEditorHit(c, editor) {
  return c.hitFailure(editor, (left, top, right, bottom) => {
    const clipping = new Set(['auto', 'scroll', 'hidden', 'clip']);
    let depth = 0;
    for (let node = editor; node; node = node.parentElement) {
      if (++depth > 64 || !node.isConnected || !node.contains(editor)) return false;
      const style = getComputedStyle(node);
      // The observed boxes have no transforms or nonrectangular clipping.
      // Do not guess transformed client coordinates or paint-containment clips.
      if (['transform', 'translate', 'rotate', 'scale', 'perspective', 'clipPath'].some(key =>
        style[key] && style[key] !== 'none') || style.zoom && !['1', 'normal'].includes(style.zoom)
        || /\b(?:paint|strict|content)\b/.test(style.contain || '')) return false;
      if (node === editor) continue;
      const clipX = clipping.has(style.overflowX), clipY = clipping.has(style.overflowY);
      if (!clipX && !clipY) continue;
      const rect = node.getBoundingClientRect();
      const x = rect.left + node.clientLeft, y = rect.top + node.clientTop;
      const width = node.clientWidth, height = node.clientHeight;
      if (![rect.left, rect.top, rect.width, rect.height, node.clientLeft, node.clientTop,
        x, y, width, height, x + width, y + height].every(Number.isFinite)
        || rect.width <= 0 || rect.height <= 0 || width < 0 || height < 0) return false;
      if (clipX) { left = Math.max(left, x); right = Math.min(right, x + width); }
      if (clipY) { top = Math.max(top, y); bottom = Math.min(bottom, y + height); }
      if (right <= left || bottom <= top) return false;
    }
    // Exactly one point, chosen from the intersected clip boxes. The browser
    // must still identify the exact owned editor (or its descendant) there.
    return editor.contains(document.elementFromPoint((left + right) / 2, (top + bottom) / 2));
  }) === null;
}

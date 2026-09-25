import { cloneElement, createElement, isValidElement, type ElementDescriptor, type OctaneNode } from 'octane';
import { Lexer, type MarkedToken, type Token, type Tokens } from 'marked';
import { decodeHTMLStrict } from 'entities/decode';

const element = (tag: string, children: OctaneNode, props: Record<string, unknown> = {}) =>
  createElement(tag, { ...props, children });

function safeLink(href: string): string | null {
  try {
    const url = new URL(href);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
  } catch {
    return null;
  }
}

function tableCell(cell: Tokens.TableCell, heading: boolean, index: number): ElementDescriptor {
  return element(heading ? 'th' : 'td', renderTokens(cell.tokens), {
    key: index,
    ...(heading ? { scope: 'col' } : {}),
    ...(cell.align ? { style: { textAlign: cell.align } } : {}),
  });
}

function renderTokens(tokens: Token[]): OctaneNode[] {
  return tokens.map((token, index): OctaneNode => {
    const content = renderToken(token);
    return isValidElement(content) ? cloneElement(content, { key: `${token.type}-${index}` }) : content;
  });
}

function renderToken(token: Token): OctaneNode {
    // Only built-in lexer tokens are used; no extensions or HTML renderer run.
    const node = token as MarkedToken;
    switch (node.type) {
      case 'space':
      case 'def':
        return null;
      case 'paragraph':
        return element('p', renderTokens(node.tokens));
      case 'text':
        // Decode the original spelling exactly once: the lexer may already
        // decode numeric references in `text`, but retain named references.
        return node.tokens ? renderTokens(node.tokens) : decodeHTMLStrict(node.raw);
      case 'escape':
        return node.text;
      case 'strong':
      case 'em':
      case 'del':
        return element(node.type, renderTokens(node.tokens));
      case 'heading':
        return element(`h${Math.max(1, Math.min(6, node.depth))}`, renderTokens(node.tokens));
      case 'br':
        return element('br', null);
      case 'hr':
        return element('hr', null);
      case 'codespan':
        return element('code', node.text);
      case 'code':
        // Preserve indentation and interior blank lines exactly, including an
        // unfinished fence. Never trim token fragments or syntax-highlight HTML.
        return element('pre', element('code', node.text), { tabIndex: 0 });
      case 'blockquote':
        return element('blockquote', renderTokens(node.tokens));
      case 'list':
        return element(node.ordered ? 'ol' : 'ul', node.items.map((item, index) =>
          element('li', [
            item.task ? (item.checked ? '☑ ' : '☐ ') : null,
            renderTokens(item.tokens),
          ], { key: index })), node.ordered ? { start: typeof node.start === 'number' ? node.start : 1 } : {});
      case 'link': {
        const href = safeLink(node.autolink ? node.href : decodeHTMLStrict(node.href));
        const label = node.autolink ? node.text : renderTokens(node.tokens);
        return href
          ? element('a', label, { href, rel: 'noreferrer noopener', title: node.title ? decodeHTMLStrict(node.title) : undefined })
          : element('span', label);
      }
      case 'image':
        // Generated text must not trigger remote loads or insert active media.
        return element('span', `[Image: ${node.text || 'image'}]`);
      case 'html':
        // The model is untrusted. Literal HTML remains escaped Octane text.
        return element(node.block ? 'p' : 'span', node.text);
      case 'table':
        return element('div', element('table', [
          element('thead', element('tr', node.header.map((cell, index) => tableCell(cell, true, index))), { key: 'head' }),
          element('tbody', node.rows.map((row, index) => element('tr', row.map((cell, cellIndex) => tableCell(cell, false, cellIndex)), { key: index })), { key: 'body' }),
        ]), { className: 'response-table', role: 'region', 'aria-label': 'Response table', tabIndex: 0 });
      default:
        return token.raw;
    }
}

export function ResponseMarkdown({ text }: { text: string }): ElementDescriptor {
  // Parsing the complete body removes presentation-only blank-line tokens. Raw
  // runtime/state/inspector text is never rewritten, and code whitespace survives.
  let children: OctaneNode;
  try {
    children = renderTokens(Lexer.lex(text, { gfm: true, breaks: false }));
  } catch {
    children = element('p', text, { className: 'response-plain-text' });
  }
  return element('div', children, { className: 'assistant-copy' });
}

import { describe, expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'octane/server';
import { ResponseMarkdown } from '../src/ResponseMarkdown';

// Exercise real Octane element serialization, not a separate HTML renderer.
function render(text: string): string {
  return renderToStaticMarkup(ResponseMarkdown({ text })).html;
}

function tags(html: string, tag: string): number {
  return (html.match(new RegExp(`<${tag}(?:\\s[^>]*)?>`, 'g')) ?? []).length;
}

function unescapeText(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#(?:39|x27);/g, "'")
    .replace(/&amp;/g, '&');
}

describe('ResponseMarkdown', () => {
  test('renders paragraphs without creating blocks for surrounding blank lines', () => {
    const html = render('\n\nFirst paragraph.\n\n\nSecond paragraph.\n\n');
    expect(tags(html, 'p')).toBe(2);
    expect(html).toMatch(/<p(?:\s[^>]*)?>First paragraph\.<\/p>/);
    expect(html).toMatch(/<p(?:\s[^>]*)?>Second paragraph\.<\/p>/);
    expect(html).not.toMatch(/<p(?:\s[^>]*)?>\s*<\/p>/);
    expect(html).not.toMatch(/<br\b/);
  });

  test('renders a soft source line wrap as one flowing paragraph', () => {
    const html = render('A sentence that wraps\nonto the next source line.');
    expect(tags(html, 'p')).toBe(1);
    expect(html).toMatch(/wraps\s+onto/);
    expect(html).not.toMatch(/<br\b/);
  });

  test('handles whitespace-only output without empty paragraph artifacts', () => {
    const html = render(' \n\t\n ');
    expect(tags(html, 'p')).toBe(0);
    expect(tags(html, 'pre')).toBe(0);
  });

  test('renders heading and inline emphasis as semantic elements', () => {
    const html = render('## A useful heading\n\nUse **bold**, *emphasis*, and `inline code`.');
    expect(html).toMatch(/<h2(?:\s[^>]*)?>A useful heading<\/h2>/);
    expect(html).toMatch(/<strong(?:\s[^>]*)?>bold<\/strong>/);
    expect(html).toMatch(/<em(?:\s[^>]*)?>emphasis<\/em>/);
    expect(html).toMatch(/<code(?:\s[^>]*)?>inline code<\/code>/);
  });

  test('renders nested unordered lists without flattening their structure', () => {
    const html = render('- Parent item\n  - Nested item\n- Another parent');
    expect(tags(html, 'ul')).toBe(2);
    expect(tags(html, 'li')).toBe(3);
    expect(html).toMatch(/<li\b[^>]*>[\s\S]*Parent item[\s\S]*<ul\b[^>]*>[\s\S]*Nested item[\s\S]*<\/ul>[\s\S]*<\/li>/);
  });

  test('preserves an ordered list starting number', () => {
    const html = render('3. Third step\n4. Fourth step');
    expect(html).toMatch(/<ol\b[^>]*\bstart="3"/);
    expect(tags(html, 'li')).toBe(2);
    expect(html).toContain('Third step');
    expect(html).toContain('Fourth step');
  });

  test('preserves zero as a valid ordered list starting number', () => {
    const html = render('0. Zero step\n1. First step');
    expect(html).toMatch(/<ol\b[^>]*\bstart="0"/);
    expect(tags(html, 'li')).toBe(2);
  });

  test('preserves fenced code indentation, internal blank lines, and literal markup', () => {
    const source = '  first = "<tag>";\n\n\tsecond = first;';
    const html = render(`\n\n\`\`\`ts\n${source}\n\`\`\`\n\n`);
    const code = html.match(/<pre\b[^>]*>\s*<code\b[^>]*>([\s\S]*?)<\/code>\s*<\/pre>/)?.[1];
    expect(code).toBeDefined();
    // A conventional single final newline is presentation-neutral; all original
    // indentation and the internal blank line must survive exactly.
    expect(unescapeText(code!).replace(/\n$/, '')).toBe(source);
    expect(html).not.toContain('<tag>');
  });

  test('renders an unfinished fence safely while cumulative output is incomplete', () => {
    const html = render('Before the code.\n\n```js\n  const value = "<script>";');
    expect(tags(html, 'pre')).toBe(1);
    expect(html).toContain('  const value =');
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toMatch(/<script\b/);
  });

  test('shows model-authored HTML as literal text instead of active elements', () => {
    const html = render('<script>alert("no")</script>\n\nInline <img src=x onerror=alert(1)> text.');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('&lt;img');
    expect(html).not.toMatch(/<(?:script|img)\b/i);
  });

  test('decodes named and numeric entities exactly once in ordinary text', () => {
    const html = render('Tom &amp; Jerry &lt;tag&gt; &copy; &#169; &#x1F680;');
    const paragraph = html.match(/<p\b[^>]*>([\s\S]*?)<\/p>/)?.[1];
    expect(paragraph).toBeDefined();
    expect(unescapeText(paragraph!)).toBe('Tom & Jerry <tag> © © 🚀');
    expect(html).not.toContain('&amp;amp;');
    expect(html).not.toContain('<tag>');
  });

  test('does not recursively decode doubly encoded entities', () => {
    const html = render('Named: &amp;amp; Numeric: &#38;amp; Hex: &#x26;lt;');
    const paragraph = html.match(/<p\b[^>]*>([\s\S]*?)<\/p>/)?.[1];
    expect(paragraph).toBeDefined();
    expect(unescapeText(paragraph!)).toBe('Named: &amp; Numeric: &amp; Hex: &lt;');
  });

  test('decoded entities remain safe text and cannot introduce active HTML', () => {
    const html = render('&lt;img src=x onerror=alert(1)&gt; and &#60;script&#62;bad()&#60;/script&#62;');
    expect(html).toContain('&lt;img');
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toMatch(/<(?:img|script)\b/i);
  });

  test('leaves literal entity notation in inline and fenced code untouched', () => {
    const html = render('`&lt;tag&gt; &amp; &#38;amp;`\n\n```text\n&lt;tag&gt; &amp; &#38;amp;\n```');
    const codeBodies = Array.from(html.matchAll(/<code\b[^>]*>([\s\S]*?)<\/code>/g), (match) => match[1]);
    expect(codeBodies).toHaveLength(2);
    for (const body of codeBodies) {
      expect(unescapeText(body).replace(/\n$/, '')).toBe('&lt;tag&gt; &amp; &#38;amp;');
    }
  });

  test('preserves backslash-escaped entities and raw HTML entity notation', () => {
    const html = render('\\&amp;\n\n<div data-label="&amp;">literal &lt;text&gt;</div>');
    expect(html).toContain('&amp;amp;');
    expect(html).toContain('&lt;div data-label="&amp;amp;"&gt;literal &amp;lt;text&amp;gt;&lt;/div&gt;');
    expect(html).not.toMatch(/<div data-label=/);
  });

  test('keeps HTTP and HTTPS links usable with their readable labels', () => {
    const html = render('[Secure docs](https://example.com/docs?q=1&lang=en) and [Local docs](http://127.0.0.1:5179/).');
    expect(tags(html, 'a')).toBe(2);
    expect(html).toContain('href="https://example.com/docs?q=1&amp;lang=en"');
    expect(html).toContain('href="http://127.0.0.1:5179/"');
    expect(html).toContain('Secure docs');
    expect(html).toContain('Local docs');
  });

  test('decodes Markdown link labels, destinations, and titles once', () => {
    const html = render('[A &amp; B](https://example.com/?a=1&amp;b=2 "Docs &amp; details")');
    expect(tags(html, 'a')).toBe(1);
    expect(html).toContain('href="https://example.com/?a=1&amp;b=2"');
    expect(html).toContain('title="Docs &amp; details"');
    expect(html).toContain('>A &amp; B</a>');
    expect(html).not.toContain('&amp;amp;');
  });

  test.each([
    '[Unsafe](<jav&#x61;script:alert(1)>)',
    '[Unsafe](<javascript&colon;alert(1)>)',
    '[Unsafe](<data&colon;text/html,hello>)',
  ])('keeps an entity-encoded unsafe link inert: %s', (source) => {
    const html = render(source);
    expect(html).toContain('Unsafe');
    expect(tags(html, 'a')).toBe(0);
    expect(html).not.toMatch(/\bhref=/i);
  });

  test('preserves literal entity notation in autolink URLs and their labels', () => {
    const html = render('<https://example.com/?a=1&amp;b=2>');
    expect(tags(html, 'a')).toBe(1);
    expect(html).toContain('href="https://example.com/?a=1&amp;amp;b=2"');
    expect(html).toContain('>https://example.com/?a=1&amp;amp;b=2</a>');
  });

  test.each([
    'javascript:alert(1)',
    'JaVaScRiPt:alert(1)',
    'data:text/html,hello',
    'file:///etc/hosts',
    'mailto:person@example.com',
    'localcodex-app://ui/index.html',
    '//example.com/path',
    '/relative/path',
    '#section',
  ])('leaves a non-HTTP(S) destination inert: %s', (destination) => {
    const html = render(`[Readable label](<${destination}>)`);
    expect(html).toContain('Readable label');
    expect(tags(html, 'a')).toBe(0);
    expect(html).not.toMatch(/\bhref=/i);
  });

  test('does not create image/network-loading elements from Markdown images', () => {
    const html = render('![Image description](https://example.com/tracking.png)');
    expect(html).toContain('Image description');
    expect(html).not.toMatch(/<(?:img|picture|source|iframe|object)\b/i);
    expect(html).not.toMatch(/\bsrc(?:set)?=/i);
  });

  test('renders table cells and inline formatting without exposing Markdown pipes', () => {
    const html = render('| Model | Result |\n| --- | ---: |\n| **Qwen** | 42 |');
    expect(tags(html, 'table')).toBe(1);
    expect(tags(html, 'th')).toBe(2);
    expect(tags(html, 'td')).toBe(2);
    expect(html).toMatch(/<strong(?:\s[^>]*)?>Qwen<\/strong>/);
    expect(html).toContain('42');
    expect(html).not.toContain('| ---');
  });

  test('re-renders complete cumulative text without losing token-boundary spaces', () => {
    let cumulative = '';
    for (const delta of ['\n\nHello', ' ', 'world', '.\n\n**A', ' useful', ' reply', '**']) {
      cumulative += delta;
      const html = render(cumulative);
      expect(html).not.toContain('undefined');
      expect(html).not.toContain('[object Object]');
      if (cumulative.includes('Hello world')) expect(html).toContain('Hello world');
    }
    const html = render(cumulative);
    expect(tags(html, 'p')).toBe(2);
    expect(html).toMatch(/<strong(?:\s[^>]*)?>A useful reply<\/strong>/);
  });
});

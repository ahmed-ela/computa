import { afterEach, expect, mock, test } from 'bun:test';
import { copyText } from '../src/clipboard';

const text = '  first\tline\n\n<second> & 🙂  \n';
const originals = new Map<string, PropertyDescriptor | undefined>();
function install(name: string, value: object) {
  originals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { configurable: true, value });
}
afterEach(() => {
  for (const [name, descriptor] of originals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
  originals.clear();
});

test('copies only the original plain text through the clipboard API', async () => {
  const writeText = mock(async (_value: string) => {});
  install('navigator', { clipboard: { writeText } });
  await copyText(text);
  expect(writeText.mock.calls).toEqual([[text]]);
});

const markdown = '**Result**\n\n```ts\n  const a = 1;\n\n```\n' + '🙂\tmore\n'.repeat(3000) + '  END\n';
const html = '<p><strong>Result</strong></p><pre><code>  const a = 1;\n</code></pre>'
  + '<p>' + '🙂\tmore\n'.repeat(3000) + '  END</p>';

test('writes the entire Markdown source and rendered HTML together in one clipboard item', async () => {
  class Item {
    constructor(readonly data: Record<string, Blob>) {}
  }
  install('ClipboardItem', Item);
  const write = mock(async (_items: Item[]) => {});
  install('navigator', { clipboard: { write } });
  await copyText(markdown, html);
  expect(write).toHaveBeenCalledTimes(1);
  const [item] = write.mock.calls[0][0];
  expect(Object.keys(item.data).sort()).toEqual(['text/html', 'text/plain']);
  expect(await item.data['text/plain'].text()).toBe(markdown);
  expect(await item.data['text/html'].text()).toBe(html);
});

for (const response of ['copy event', 'event without data', 'no event', 'rejected command']) {
  test('rich copy falls back after a rejected write: ' + response, async () => {
    install('ClipboardItem', class {});
    const write = mock(async () => { throw new Error('Denied'); });
    install('navigator', { clipboard: { write } });
    const field = { value: '', style: {}, select: mock(), remove: mock() };
    const focus = mock();
    const target = new EventTarget();
    const data = new Map<string, string>();
    const makeCopyEvent = () => Object.assign(new Event('copy', { cancelable: true }), {
      clipboardData: response === 'event without data' ? null : { setData: data.set.bind(data) },
    });
    install('document', Object.assign(target, {
      activeElement: { focus }, body: { appendChild: mock() }, createElement: () => field,
      execCommand: () => {
        if (response !== 'no event') target.dispatchEvent(makeCopyEvent());
        return response !== 'rejected command';
      },
    }));
    if (response === 'copy event') {
      await copyText(markdown, html);
      expect(data.get('text/plain')).toBe(markdown);
      expect(data.get('text/html')).toBe(html);
    } else await expect(copyText(markdown, html)).rejects.toThrow();
    expect(write).toHaveBeenCalledTimes(1);
    expect(field.remove).toHaveBeenCalledTimes(1);
    expect(focus).toHaveBeenCalledTimes(1);
    data.clear();
    expect(target.dispatchEvent(makeCopyEvent())).toBe(true);
    expect(data.size).toBe(0);
  });
}

for (const scenario of ['unavailable', 'rejected', 'failed copy', 'throwing copy']) {
  test('custom-scheme clipboard fallback with ' + scenario, async () => {
    const field = { value: '', style: { cssText: '' }, select: mock(), remove: mock() };
    const focus = mock();
    install('navigator', scenario === 'rejected' ? {
      clipboard: { writeText: async () => { throw new Error('Denied'); } },
    } : {});
    install('document', {
      activeElement: { focus }, body: { appendChild: mock() }, createElement: () => field,
      execCommand: (command: string) => {
        expect(command).toBe('copy');
        expect(field.value).toBe(text);
        expect(field.select).toHaveBeenCalledTimes(1);
        if (scenario === 'throwing copy') throw new Error('Clipboard unavailable');
        return scenario !== 'failed copy';
      },
    });
    if (scenario === 'failed copy' || scenario === 'throwing copy') await expect(copyText(text)).rejects.toThrow();
    else await copyText(text);
    expect(field.remove).toHaveBeenCalledTimes(1);
    expect(focus).toHaveBeenCalledTimes(1);
  });
}

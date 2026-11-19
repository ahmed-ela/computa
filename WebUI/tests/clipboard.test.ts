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

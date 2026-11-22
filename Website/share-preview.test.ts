import { expect, test } from 'bun:test';

test('the static homepage advertises a public logo with matching image metadata', async () => {
  const html = await Bun.file(new URL('./index.html', import.meta.url)).text();
  const tags = new Map<string, string | null>();
  new HTMLRewriter().on('head meta', {
    element(meta) {
      const key = meta.getAttribute('property') ?? meta.getAttribute('name');
      if (key) tags.set(key, meta.getAttribute('content'));
    },
  }).transform(html);

  expect(tags.get('og:type')).toBe('website');
  expect(tags.get('og:title')).toBe('Kolmogor');
  expect(tags.get('og:description')).toBeTruthy();
  expect(tags.get('og:url')).toBe('https://kolmogor.com/');
  const image = new URL(tags.get('og:image')!);
  expect(image.origin).toBe('https://kolmogor.com');
  expect(tags.get('og:image:type')).toBe('image/png');
  expect(tags.get('og:image:alt')).toBeTruthy();
  expect(tags.get('twitter:card')).toBe('summary_large_image');
  expect(tags.get('twitter:image')).toBe(image.href);
  expect(tags.get('twitter:image:alt')).toBe(tags.get('og:image:alt'));

  const png = Buffer.from(await Bun.file(new URL('./public' + image.pathname, import.meta.url)).arrayBuffer());
  expect(png.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
  expect(png.readUInt32BE(16)).toBe(Number(tags.get('og:image:width')));
  expect(png.readUInt32BE(20)).toBe(Number(tags.get('og:image:height')));
});

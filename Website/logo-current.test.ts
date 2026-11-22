import { expect, test } from 'bun:test';
import { createLogoCurrent, LOGO_SIZE } from './src/logoCurrent';

test('the current carries color past the old loop period and preserves the source outline', async () => {
  const field = new Int8Array(await Bun.file(new URL('./src/logo-current.bin', import.meta.url)).arrayBuffer());
  const colors = new Uint8ClampedArray(LOGO_SIZE * LOGO_SIZE * 4);
  for (let pixel = 0; pixel < colors.length / 4; pixel++) {
    colors[pixel * 4] = pixel % LOGO_SIZE % 256;
    colors[pixel * 4 + 1] = Math.floor(pixel / LOGO_SIZE) % 256;
    colors[pixel * 4 + 3] = pixel % 17 === 0 ? 0 : 255;
  }
  const image = { width: LOGO_SIZE, height: LOGO_SIZE, data: colors.slice() } as ImageData;
  const current = createLogoCurrent(image, field);
  current.paint();
  expect(image.data).toEqual(colors);
  let previous = image.data.slice();
  for (let interval = 0; interval < 2; interval++) {
    for (let tick = 0; tick < 432; tick++) current.step(); // 14.4 seconds at 30 Hz
    current.paint();
    let moved = 0;
    let changedAlpha = 0;
    for (let i = 0; i < colors.length; i += 4) {
      if (image.data[i] !== previous[i] || image.data[i + 1] !== previous[i + 1]) moved++;
      if (image.data[i + 3] !== colors[i + 3]) changedAlpha++;
    }
    expect(moved).toBeGreaterThan(1000);
    expect(changedAlpha).toBe(0);
    previous = image.data.slice();
  }
});

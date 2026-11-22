// Each grid cell stores two (x, y) velocity vectors from the approved flow.
// The signed bytes use six units per artwork pixel; the grid is half resolution.
export const LOGO_SIZE = 320;
const GRID_SIZE = LOGO_SIZE / 2;
export const FIELD_BYTES = GRID_SIZE * GRID_SIZE * 4;
const TICK = 1 / 30;
export const TICK_MS = 1000 * TICK;

function samplePosition(value: number, size: number) {
  return Math.max(0, Math.min(size - 1.001, value));
}

function sampleGrid(grid: Float32Array, cell: number, x: number, y: number) {
  const below = cell + GRID_SIZE;
  return (grid[cell] * (1 - x) + grid[cell + 1] * x) * (1 - y)
    + (grid[below] * (1 - x) + grid[below + 1] * x) * y;
}

export function createLogoCurrent(pixels: ImageData, field: Int8Array) {
  if (field.length !== FIELD_BYTES || pixels.width !== LOGO_SIZE || pixels.height !== LOGO_SIZE) {
    throw new Error('Logo flow dimensions do not match the artwork.');
  }
  const output = pixels.data;
  const original = output.slice();
  const movingCells: number[] = [];
  const coloredPixels: number[] = [];
  for (let i = 0; i < field.length; i += 4) {
    if (field[i] || field[i + 1] || field[i + 2] || field[i + 3]) movingCells.push(i / 4);
  }
  for (let i = 0; i < original.length; i += 4) {
    if (original[i + 3] > 220) coloredPixels.push(i / 4);
  }

  const cellCount = GRID_SIZE * GRID_SIZE;
  let offsetX = new Float32Array(cellCount);
  let offsetY = new Float32Array(cellCount);
  let nextX = new Float32Array(cellCount);
  let nextY = new Float32Array(cellCount);
  let time = 0;
  const damping = Math.exp(-TICK / 10.5);

  function step() {
    // Independent phase speeds steer the current. Offsets carry over between ticks.
    const phase = 0.119 * (time + 0.5 * TICK);
    const first = (0.44 + 0.51 * Math.sin(phase + 1.12)
      + 0.24 * Math.sin(phase * Math.sqrt(3) - 0.8)) * 0.30 / 12;
    const second = (0.75 * Math.cos(phase * Math.sqrt(2) - 0.42)
      + 0.38 * Math.sin(phase * Math.sqrt(5) + 0.32)) * 0.36 / 12;

    for (const cell of movingCells) {
      const i = cell * 4;
      const x = cell % GRID_SIZE;
      const y = Math.floor(cell / GRID_SIZE);
      const fromX = samplePosition(x - TICK * (first * field[i] + second * field[i + 2]), GRID_SIZE);
      const fromY = samplePosition(y - TICK * (first * field[i + 1] + second * field[i + 3]), GRID_SIZE);
      const left = Math.floor(fromX);
      const top = Math.floor(fromY);
      const fromCell = top * GRID_SIZE + left;
      nextX[cell] = damping * (sampleGrid(offsetX, fromCell, fromX - left, fromY - top) + fromX - x);
      nextY[cell] = damping * (sampleGrid(offsetY, fromCell, fromX - left, fromY - top) + fromY - y);
    }
    [offsetX, nextX] = [nextX, offsetX];
    [offsetY, nextY] = [nextY, offsetY];
    time += TICK;
  }

  function paint() {
    // Always sample the original pigment through the moving coordinates. Repeated
    // resampling of the previous frame would progressively blur the highlights.
    for (const pixel of coloredPixels) {
      const x = pixel % LOGO_SIZE;
      const y = Math.floor(pixel / LOGO_SIZE);
      const gridX = samplePosition((x - 0.5) / 2, GRID_SIZE);
      const gridY = samplePosition((y - 0.5) / 2, GRID_SIZE);
      const cell = Math.floor(gridY) * GRID_SIZE + Math.floor(gridX);
      const fx = gridX - Math.floor(gridX);
      const fy = gridY - Math.floor(gridY);
      const sourceX = samplePosition(x + 2 * sampleGrid(offsetX, cell, fx, fy), LOGO_SIZE);
      const sourceY = samplePosition(y + 2 * sampleGrid(offsetY, cell, fx, fy), LOGO_SIZE);
      const dx = sourceX - Math.floor(sourceX);
      const dy = sourceY - Math.floor(sourceY);
      const topLeft = 4 * (Math.floor(sourceY) * LOGO_SIZE + Math.floor(sourceX));
      const topRight = topLeft + 4;
      const bottomLeft = topLeft + 4 * LOGO_SIZE;
      const bottomRight = bottomLeft + 4;
      const w0 = (1 - dx) * (1 - dy) * original[topLeft + 3];
      const w1 = dx * (1 - dy) * original[topRight + 3];
      const w2 = (1 - dx) * dy * original[bottomLeft + 3];
      const w3 = dx * dy * original[bottomRight + 3];
      const coverage = w0 + w1 + w2 + w3;
      for (let c = 0; c < 3; c++) {
        output[pixel * 4 + c] = coverage > 127
          ? (original[topLeft + c] * w0 + original[topRight + c] * w1
            + original[bottomLeft + c] * w2 + original[bottomRight + c] * w3) / coverage
          : original[pixel * 4 + c];
      }
    }
  }

  return { step, paint };
}

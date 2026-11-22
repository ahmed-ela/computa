import { useEffect, useRef } from 'octane';
import fieldURL from './logo-current.bin?url';
import { createLogoCurrent, LOGO_SIZE, TICK_MS } from './logoCurrent';

function animateLogo(image: HTMLImageElement, canvas: HTMLCanvasElement) {
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  const request = new AbortController();
  let startRequested = false;
  let startPlayback: (() => void) | undefined;
  let frame = 0;

  function syncPlayback() {
    cancelAnimationFrame(frame);
    if (motion.matches) canvas.hidden = true;
    if (request.signal.aborted || motion.matches || document.hidden) return;
    if (startPlayback) {
      startPlayback();
    } else if (!startRequested) {
      startRequested = true;
      // The ordinary image remains visible if canvas or its field is unavailable.
      void initialize().catch(() => { canvas.hidden = true; });
    }
  }

  async function initialize() {
    const context = canvas.getContext('2d');
    if (!context) return;
    const [response] = await Promise.all([fetch(fieldURL, { signal: request.signal }), image.decode()]);
    if (!response.ok) return;
    const field = new Int8Array(await response.arrayBuffer());
    if (request.signal.aborted) return;
    context.drawImage(image, 0, 0, LOGO_SIZE, LOGO_SIZE);
    const pixels = context.getImageData(0, 0, LOGO_SIZE, LOGO_SIZE);
    const current = createLogoCurrent(pixels, field);
    let last = 0;
    let remainder = 0;

    function render(now: number) {
      remainder += Math.min(120, now - last);
      last = now;
      if (remainder >= TICK_MS) {
        while (remainder >= TICK_MS) {
          current.step();
          remainder -= TICK_MS;
        }
        current.paint();
        context!.putImageData(pixels, 0, 0);
        canvas.hidden = false;
      }
      frame = requestAnimationFrame(render);
    }

    startPlayback = () => {
      last = performance.now();
      remainder = 0;
      frame = requestAnimationFrame(render);
    };
    syncPlayback();
  }

  motion.addEventListener('change', syncPlayback);
  document.addEventListener('visibilitychange', syncPlayback);
  syncPlayback();
  return () => {
    request.abort();
    cancelAnimationFrame(frame);
    motion.removeEventListener('change', syncPlayback);
    document.removeEventListener('visibilitychange', syncPlayback);
  };
}

export function Logo() {
  const image = useRef<HTMLImageElement | null>(null);
  const canvas = useRef<HTMLCanvasElement | null>(null);
  useEffect(() => {
    if (image.current && canvas.current) return animateLogo(image.current, canvas.current);
  }, []);
  return (
    <div className="logo">
      <img ref={image} src="/computa-pastel.png" alt="Computa" width={LOGO_SIZE} height={LOGO_SIZE} />
      <canvas ref={canvas} width={LOGO_SIZE} height={LOGO_SIZE} aria-hidden="true" hidden />
    </div>
  );
}

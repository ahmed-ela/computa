import RFB from '@novnc/novnc';
export function view(target, password, disconnected) {
  const url = new URL('/api/display', location.origin);
  url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const rfb = new RFB(target, url.href, { credentials: { password } });
  rfb.scaleViewport = true;
  rfb.clipViewport = false;
  rfb.addEventListener('disconnect', disconnected, { once: true });
  return () => rfb.disconnect();
}

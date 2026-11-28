// Stdio adapter for Codex's local app-server WebSocket. Paths come from the native
// host. No network endpoint, credentials, or thread settings come from the page.
import { createInterface } from 'node:readline';
import WebSocket from 'ws';

const socket = process.argv[2];
if (!socket?.startsWith('/') || socket.includes(':')) process.exit(1);
const client = new WebSocket(`ws+unix://${socket}:/rpc`, {
  handshakeTimeout: 4000, maxPayload: 8 * 1024 * 1024, perMessageDeflate: false,
});
const input = createInterface({ input: process.stdin });
input.pause();
client.on('open', () => {
  input.on('line', line => client.send(line));
  input.resume();
});
client.on('message', (bytes, binary) => {
  if (binary || bytes.includes(10)) return client.terminate();
  process.stdout.write(bytes);
  process.stdout.write('\n');
});
input.on('close', () => client.terminate());
client.on('error', () => process.exit(1));
client.on('close', () => process.exit(0));

import {readFileSync} from 'node:fs';
import {request} from 'node:https';
import {timingSafeEqual} from 'node:crypto';

const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount';
const providers = new Map([['codex', 'cli'], ['claude', 'claude'], ['antigravity', 'antigravity']]);

function kube(method, path, body) {
  const data = body && JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = request({
      hostname: 'kubernetes.default.svc', port: 443, path, method,
      ca: readFileSync(serviceAccount + '/ca.crt'),
      headers: {authorization: 'Bearer ' + readFileSync(serviceAccount + '/token', 'utf8'),
        ...(data && {'content-type': 'application/merge-patch+json'})},
      signal: AbortSignal.timeout(8000),
    }, res => {
      const chunks = [];
      res.on('error', reject);
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        try { resolve({status: res.statusCode, body: JSON.parse(Buffer.concat(chunks))}); }
        catch (error) { reject(error); }
      });
    });
    req.on('error', reject);
    req.end(data);
  });
}

// Each namespace grants this service account access to its one routing secret
// and its provider scale subresources. Workers never receive either credential.
export async function routeSession(req, send, api = kube) {
  const match = /^\/workspaces\/(kolmogor(?:-ws-[a-z0-9](?:[a-z0-9-]{0,47}[a-z0-9])?)?)\/providers\/(codex|claude|antigravity)\/(start|stop)$/.exec(req.url);
  if (!match || req.method !== 'POST') return send(404, {});
  const [, namespace, provider, action] = match;
  const supplied = /^Bearer ([a-f0-9]{64})$/.exec(req.headers.authorization || '')?.[1];
  if (!supplied) return send(403, {});
  const secret = await api('GET', '/api/v1/namespaces/' + namespace + '/secrets/workspace-access');
  if ([403, 404].includes(secret.status)) return send(403, {});
  if (secret.status !== 200) return send(503, {});
  const expected = Buffer.from(secret.body.data.token, 'base64');
  const bytes = Buffer.from(supplied);
  if (bytes.length !== expected.length || !timingSafeEqual(bytes, expected)) return send(403, {});
  const worker = providers.get(provider);
  const scale = await api('PATCH', '/apis/apps/v1/namespaces/' + namespace + '/deployments/' + worker + '/scale',
    {spec: {replicas: action === 'start' ? 1 : 0}});
  if (scale.status !== 200) return send(503, {});
  return send(200, {namespace, provider, deployment: worker, replicas: scale.body.spec.replicas ?? 0});
}

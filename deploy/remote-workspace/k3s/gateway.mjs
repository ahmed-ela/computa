import { timingSafeEqual, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';

const db = new DatabaseSync(process.env.JOB_DB || '/data/jobs.sqlite');
db.exec(`PRAGMA busy_timeout=5000;
  CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY, challenge TEXT NOT NULL, lease TEXT, expires INTEGER,
    result TEXT, created INTEGER NOT NULL
  )`);
const [action, id] = process.argv.slice(2);
if (action === 'submit') {
  const job = {id: randomUUID(), challenge: randomUUID(), operation: 'system-info'};
  db.prepare('INSERT INTO jobs (id,challenge,created) VALUES (?,?,?)').run(job.id, job.challenge, Date.now());
  console.log(JSON.stringify(job));
} else if (action === 'result') {
  const job = db.prepare('SELECT id,challenge,result FROM jobs WHERE id=?').get(id);
  if (!job) throw Error('Unknown job');
  console.log(JSON.stringify({...job, result: JSON.parse(job.result)}));
} else if (action === 'serve') {
  const token = Buffer.from(process.env.WORKER_TOKEN || '');
  if (token.length < 32) throw Error('Configure a worker token');
  const claim = db.prepare(`UPDATE jobs SET lease=?, expires=? WHERE id=(
    SELECT id FROM jobs WHERE result IS NULL AND (expires IS NULL OR expires<=?)
    ORDER BY created,rowid LIMIT 1
  ) RETURNING id,challenge,lease`);
  const complete = db.prepare(`UPDATE jobs SET result=? WHERE id=? AND lease=? AND challenge=?
    AND (result IS NULL OR result=?)`);
  const health = '/ready';
  const server = createServer(async (req,res) => {
    function send(status, obj) {
      res.writeHead(status, {'Content-Type':'application/json','Cache-Control':'no-store'});
      res.end(JSON.stringify(obj));
    }
    try {
      if (req.url === health && req.method === 'GET') return send(200,{ready:true});
      if (req.url !== '/worker' || req.method !== 'POST') return send(404,{});
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 4096) return send(413,{});
        chunks.push(chunk);
      }
      let msg;
      try { msg = JSON.parse(Buffer.concat(chunks)); } catch { return send(400,{}); }
      const supplied = Buffer.from(typeof msg?.token === 'string' ? msg.token : '');
      if (supplied.length !== token.length || !timingSafeEqual(token,supplied)) return send(403,{});
      if (msg.action === 'claim') {
        const deadline = Date.now() + 15000;
        do {
          const now = Date.now();
          const job = claim.get(randomUUID(), now + 60000, now);
          if (job) return send(200,{operation:'system-info', ...job});
          await delay(750);
        } while (!res.destroyed && Date.now() < deadline);
        return send(200,{operation:'idle'});
      }
      if (msg.action !== 'complete') return send(400,{});
      const {id,lease,challenge,os,build,arch,boot} = msg;
      const fields = [id,lease,challenge,os,build,arch,boot];
      if (!fields.every(s => typeof s === 'string' && /^[A-Za-z0-9.-]{1,64}$/.test(s))) return send(400,{});
      const result = JSON.stringify({os,build,arch,boot});
      const {changes} = complete.run(result,id,lease,challenge,result);
      return send(changes ? 200 : 409,{accepted:changes === 1});
    } catch (error) {
      console.error('Worker request failed:',error.name);
      if (!res.headersSent) send(500,{});
    }
  });
  server.listen(8080);
} else {
  throw Error('Use serve, submit, or result JOB_ID');
}

import { createHash, randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { OAuth2Client } from 'google-auth-library';

export const opaque = () => randomBytes(32).toString('base64url');
export const digest = (value) => createHash('sha256').update(value).digest('base64url');
const minute = 60_000;
const validChallenge = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value);

export function workspaceFor(subject) {
  if (typeof subject !== 'string' || !subject || subject.length > 255)
    throw Error('Invalid Google subject');
  return (
    'kolmogor-ws-u-' +
    createHash('sha256')
      .update('https://accounts.google.com\0' + subject)
      .digest('hex')
      .slice(0, 40)
  );
}

export class Accounts {
  constructor(path, now = Date.now) {
    this.now = now;
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS users(subject TEXT PRIMARY KEY, email TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS logins(state TEXT PRIMARY KEY, browser TEXT NOT NULL,
        verifier TEXT NOT NULL, nonce TEXT NOT NULL, appChallenge TEXT NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS grants(ticket TEXT PRIMARY KEY, subject TEXT NOT NULL REFERENCES users,
        challenge TEXT NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, subject TEXT NOT NULL REFERENCES users,
        expires INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS session_expiry ON sessions(expires);`);
  }
  cleanup() {
    for (const table of ['logins', 'grants', 'sessions'])
      this.db.prepare('DELETE FROM ' + table + ' WHERE expires<=?').run(this.now());
  }
  begin(challenge = '') {
    if (challenge !== '' && !validChallenge(challenge)) throw Error('Invalid app challenge');
    this.cleanup();
    if (this.db.prepare('SELECT count(*) AS n FROM logins').get().n >= 512)
      throw Error('Too many sign-ins in progress');
    const state = opaque(),
      browser = opaque(),
      verifier = opaque(),
      nonce = opaque();
    this.db
      .prepare('INSERT INTO logins VALUES(?,?,?,?,?,?)')
      .run(digest(state), digest(browser), verifier, nonce, challenge, this.now() + 10 * minute);
    return { state, browser, verifier, nonce };
  }
  claim(state, browser) {
    if (!validChallenge(state) || !validChallenge(browser)) return undefined;
    return this.db
      .prepare('DELETE FROM logins WHERE state=? AND browser=? AND expires>? RETURNING *')
      .get(digest(state), digest(browser), this.now());
  }
  identify({ sub, email, email_verified, nonce }, login) {
    if (!sub || typeof email !== 'string' || !email || email_verified !== true || nonce !== login.nonce)
      throw Error('Google identity could not be verified');
    workspaceFor(sub);
    this.db
      .prepare('INSERT INTO users VALUES(?,?) ON CONFLICT(subject) DO UPDATE SET email=excluded.email')
      .run(sub, email);
    if (!login.appChallenge) return { session: this.session(sub) };
    const ticket = opaque();
    this.db
      .prepare('INSERT INTO grants VALUES(?,?,?,?)')
      .run(digest(ticket), sub, login.appChallenge, this.now() + minute);
    return { ticket };
  }
  redeem(ticket, verifier) {
    if (!validChallenge(ticket) || !validChallenge(verifier)) return undefined;
    const row = this.db
      .prepare('DELETE FROM grants WHERE ticket=? AND challenge=? AND expires>? RETURNING subject')
      .get(digest(ticket), digest(verifier), this.now());
    return row && this.session(row.subject);
  }
  session(subject) {
    const token = opaque();
    this.db
      .prepare('INSERT INTO sessions VALUES(?,?,?)')
      .run(digest(token), subject, this.now() + 7 * 24 * 60 * minute);
    return token;
  }
  user(token) {
    if (!validChallenge(token)) return undefined;
    return this.db
      .prepare('SELECT users.* FROM sessions JOIN users USING(subject) WHERE token=? AND expires>?')
      .get(digest(token), this.now());
  }
  logout(token) {
    if (validChallenge(token)) this.db.prepare('DELETE FROM sessions WHERE token=?').run(digest(token));
  }
}

export function googleProvider({ clientId, clientSecret, origin }) {
  if (!clientId || !clientSecret) throw Error('Google client credentials are required');
  const client = new OAuth2Client({ clientId, clientSecret, redirectUri: origin + '/oauth/callback' });
  return {
    url(tx) {
      return client.generateAuthUrl({
        scope: ['openid', 'email'],
        state: tx.state,
        nonce: tx.nonce,
        code_challenge: digest(tx.verifier),
        code_challenge_method: 'S256',
        prompt: 'select_account',
      });
    },
    async verify(code, tx) {
      const { tokens } = await client.getToken({ code, codeVerifier: tx.verifier });
      const result = await client.verifyIdToken({ idToken: tokens.id_token, audience: clientId });
      return result.getPayload();
    },
  };
}

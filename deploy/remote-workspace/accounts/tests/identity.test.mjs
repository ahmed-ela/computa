import test from 'node:test';
import assert from 'node:assert/strict';
import { Accounts, opaque, digest, workspaceFor, googleProvider } from '../identity.mjs';

test('login is bound to the originating browser and can be consumed only once', () => {
  const a = new Accounts(':memory:');
  const tx = a.begin();
  assert.equal(a.claim(tx.state, opaque()), undefined);
  const valid = a.claim(tx.state, tx.browser);
  assert.equal(valid.nonce, tx.nonce);
  assert.equal(a.claim(tx.state, tx.browser), undefined);
});
test('native handoff is one-use, bound to PKCE, revocable and time limited', () => {
  let now = 1;
  const a = new Accounts(':memory:', () => now),
    verifier = opaque(),
    tx = a.begin(digest(verifier));
  const login = a.claim(tx.state, tx.browser),
    claims = { sub: '12345', email: 'a@example.invalid', email_verified: true, nonce: tx.nonce };
  assert.throws(() => a.identify({ ...claims, nonce: 'wrong' }, login));
  assert.throws(() => a.identify({ ...claims, email_verified: false }, login));
  const { ticket } = a.identify(claims, login);
  assert.equal(a.redeem(ticket, opaque()), undefined);
  const session = a.redeem(ticket, verifier);
  assert.equal(a.user(session).subject, claims.sub);
  assert.equal(a.redeem(ticket, verifier), undefined);
  a.logout(session);
  assert.equal(a.user(session), undefined);
  const other = a.session(claims.sub);
  now += 8 * 24 * 3600000;
  assert.equal(a.user(other), undefined);
  assert.equal(a.db.prepare('SELECT token FROM sessions').get().token, digest(other));
});
test('email changes keep the workspace and matching emails cannot share an instance', () => {
  const a = new Accounts(':memory:');
  function sign(sub, email) {
    const tx = a.begin();
    return a.user(
      a.identify({ sub, email, email_verified: true, nonce: tx.nonce }, a.claim(tx.state, tx.browser))
        .session
    );
  }
  const first = sign('1', 'one@example.invalid'),
    renamed = sign('1', 'new@example.invalid'),
    other = sign('2', renamed.email);
  assert.equal(workspaceFor(first.subject), workspaceFor(renamed.subject));
  assert.notEqual(workspaceFor(renamed.subject), workspaceFor(other.subject));
});
test('Google authorization uses basic identity scopes, PKCE and nonce', () => {
  const tx = new Accounts(':memory:').begin();
  const provider = googleProvider({
    clientId: 'fixture.apps.googleusercontent.com',
    clientSecret: 'fixture',
    origin: 'https://accounts.example.invalid',
  });
  const url = new URL(provider.url(tx));
  assert.equal(url.origin, 'https://accounts.google.com');
  assert.equal(url.searchParams.get('nonce'), tx.nonce);
  assert.equal(url.searchParams.get('code_challenge'), digest(tx.verifier));
  assert.equal(url.searchParams.get('scope'), 'openid email');
  assert.equal(url.searchParams.has('access_type'), false);
});

// Runs against a disposable account database. No provider credentials or external network required.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import net from 'node:net';
import { Duplex } from 'node:stream';
import { chromium } from 'playwright-core';
import { workspaceAccount } from '../browser-account.cjs';
import { Accounts } from '../identity.mjs';
import { accountServer } from '../server.mjs';

const reservation = net.createServer();
reservation.listen(0, '127.0.0.1');
await once(reservation, 'listening');
const port = reservation.address().port;
await new Promise((resolve) => reservation.close(resolve));
const origin = 'http://127.0.0.1:' + port;
const accounts = new Accounts(':memory:');
const providers = { codex: 'disconnected', claude: 'disconnected', chrome: 'ready' };
const starts = [];
const server = accountServer({
  origin,
  accounts,
  google: {
    url: ({ state }) => origin + '/oauth/callback?code=fixture&state=' + state,
    verify: async (_, tx) => ({
      sub: 'fixture',
      email: 'owner@example.invalid',
      email_verified: true,
      nonce: tx.nonce,
    }),
  },
  broker: {
    async call(_workspace, action, provider, code) {
      if (action === 'ensure') return { ready: true };
      if (action === 'status') return { ready: true, providers };
      if (action === 'code') {
        assert.equal(provider, 'claude');
        assert.equal(code, 'fixture-approval');
        providers.claude = 'connected';
        return { submitted: true };
      }
      starts.push(provider);
      if (provider === 'chrome') return { password: 'fixture' };
      providers[provider] = 'pending';
      return {
        url:
          provider === 'codex'
            ? 'https://auth.openai.com/codex/device'
            : 'https://claude.ai/oauth/authorize?fixture',
        acceptsCode: provider === 'claude',
        message: 'Approve the synthetic connection.',
      };
    },
    async display() {
      return new Duplex({
        read() {},
        write(_, __, done) {
          done();
        },
      });
    },
  },
});
server.listen(port, '127.0.0.1');
await once(server, 'listening');
const macChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let browser;
try {
  browser = await chromium.launch({
    executablePath:
      process.env.CHROME_BIN || (process.platform === 'darwin' ? macChrome : '/usr/bin/google-chrome'),
    headless: true,
  });
  const page = await browser.newPage();
  await page.route('**/*', async (route) => {
    if (new URL(route.request().url()).origin === origin) await route.continue();
    else await route.abort();
  });
  await page.goto(origin);
  await page.getByRole('link', { name: 'Sign in with Google' }).click();
  await page.getByText('owner@example.invalid', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Connect all accounts' }).click();
  await page.getByRole('heading', { name: 'Codex CLI' }).waitFor();
  assert.equal(
    await page.getByRole('link', { name: 'Open sign-in page' }).getAttribute('href'),
    'https://auth.openai.com/codex/device'
  );
  await page.getByRole('button', { name: 'Skip this account' }).click();
  await page.getByLabel('Authorization code').fill('fixture-approval');
  await page.getByRole('button', { name: 'Submit code' }).click();
  await page.getByRole('heading', { name: 'Workspace Chrome' }).waitFor();
  await page.locator('#screen canvas').waitFor({ state: 'attached' });
  assert.deepEqual(starts, ['codex', 'claude', 'chrome']);
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.getByRole('link', { name: 'Sign in with Google' }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Connect all accounts' }).isVisible(), false);
  console.log(
    'Verified Google entry, the three guided connection steps, manual code, browser viewer, and sign-out with a disposable account.'
  );

  const remoteChrome = await browser.newContext();
  await remoteChrome.route('**/*', (route) => route.fulfill({ contentType: 'text/html', body: '<main>Fixture</main>' }));
  const unrelated = await remoteChrome.newPage();
  await unrelated.goto('https://example.invalid/user-work');
  const landing = await remoteChrome.newPage();
  await landing.goto('https://www.google.com/account/about/');
  assert.equal(await workspaceAccount(remoteChrome, 'status'), false);
  assert.equal(await workspaceAccount(remoteChrome, 'start'), false);
  const login = new URL(landing.url());
  assert.equal(login.origin, 'https://accounts.google.com');
  assert.equal(login.searchParams.get('continue'), 'https://myaccount.google.com/');
  const challenge = new URL('/challenge/fixture', login.origin);
  challenge.search = login.search;
  await landing.goto(challenge.href);
  assert.equal(await workspaceAccount(remoteChrome, 'start'), false);
  assert.equal(landing.url(), challenge.href);
  assert.equal(remoteChrome.pages().length, 2);
  assert.equal(unrelated.url(), 'https://example.invalid/user-work');
  await landing.goto('https://myaccount.google.com/');
  assert.equal(await workspaceAccount(remoteChrome, 'status'), false);
  await landing.setContent('<button aria-label="Google Account: fixture">Account</button>');
  assert.equal(await workspaceAccount(remoteChrome, 'status'), true);
  await remoteChrome.close();
  console.log('Verified that Chrome reuses the Google tab, preserves an active challenge, and checks the signed-in account menu.');
} finally {
  await browser?.close();
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  accounts.db.close();
}

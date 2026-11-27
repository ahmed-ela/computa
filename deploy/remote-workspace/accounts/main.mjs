import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Accounts, googleProvider } from './identity.mjs';
import { accountServer } from './server.mjs';
import { workspaceBroker } from './broker-client.mjs';

process.umask(0o077);
const origin = process.env.ACCOUNT_ORIGIN || 'https://accounts.kolmogor.com';
const { web } = JSON.parse(
  readFileSync(process.env.GOOGLE_CLIENT_FILE || '/etc/kolmogor-accounts/google-web.json', 'utf8')
);
if (web?.project_id !== 'kolmogor' || !web.redirect_uris?.includes(origin + '/oauth/callback')) {
  throw Error('The registered Kolmogor Google client and callback are required.');
}
const pilot = new Set(
  (process.env.PILOT_EMAILS || '')
    .split(',')
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean)
);
const publicSignup = process.env.WORKSPACE_SIGNUP === 'public';
if (!publicSignup && !pilot.size) throw Error('Configure pilot emails or enable public signup.');
const server = accountServer({
  admit: (claims) =>
    claims.email_verified === true && (publicSignup || pilot.has(claims.email?.toLowerCase())),
  origin,
  accounts: new Accounts(
    join(process.env.STATE_DIRECTORY || '/var/lib/kolmogor-accounts', 'accounts.sqlite')
  ),
  google: googleProvider({ origin, clientId: web.client_id, clientSecret: web.client_secret }),
  broker: workspaceBroker('/run/kolmogor-broker/accounts.sock'),
});
server.listen(8786, '127.0.0.1');

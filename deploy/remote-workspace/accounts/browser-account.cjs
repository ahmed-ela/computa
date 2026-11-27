const accountOrigin = 'https://myaccount.google.com';
const loginOrigin = 'https://accounts.google.com';

function isWorkspaceLogin(page) {
  const url = new URL(page.url());
  if (url.origin !== loginOrigin) return false;
  try {
    return new URL(url.searchParams.get('continue')).origin === accountOrigin;
  } catch {
    return false;
  }
}

function isAccountLanding(page) {
  const url = new URL(page.url());
  return url.origin === 'https://www.google.com' && /^\/account\/about(?:\/|$)/.test(url.pathname);
}

async function workspaceAccount(context, action) {
  const pages = context.pages();
  let page = pages.find((p) => new URL(p.url()).origin === accountOrigin);
  if (action === 'start') {
    page ??= pages.find(isWorkspaceLogin);
    if (!page) {
      page = pages.find(isAccountLanding) ?? pages.find((p) => p.url() === 'about:blank') ?? await context.newPage();
      const login = new URL('/ServiceLogin', loginOrigin);
      login.searchParams.set('continue', accountOrigin + '/');
      await page.goto(login.href, { waitUntil: 'commit', timeout: 15_000 });
    }
    await page.bringToFront();
  }
  if (!page || new URL(page.url()).origin !== accountOrigin) return false;
  const menuName = { name: /Google Account:/i };
  const accountMenu = page.locator('a[href^="https://accounts.google.com/SignOutOptions"]');
  const namedMenu = page.getByRole('button', menuName).or(page.getByRole('link', menuName));
  return await accountMenu.first().isVisible() || await namedMenu.first().isVisible();
}

module.exports = { workspaceAccount };

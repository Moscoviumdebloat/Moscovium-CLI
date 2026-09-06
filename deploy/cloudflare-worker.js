/**
 * Cloudflare Worker that backs the short `irm moscovium.win | iex` URL.
 *
 * Deploy this on a domain you own, and the one-liner becomes:
 *
 *     irm moscovium.win | iex
 *
 * It proxies rather than redirects. Invoke-RestMethod does follow 302s, so a
 * redirect would work, but proxying means we control the response headers and
 * the client only ever sees one origin. See deploy/README.md for setup.
 */

// Where the script actually lives. Pin a tag instead of a branch if you want
// the short URL to lag behind main until you cut a release.
const UPSTREAM = 'https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1';

// Browsers hitting the domain get sent somewhere human-readable instead of a
// wall of PowerShell.
const LANDING = 'https://github.com/Moscoviumdebloat/Moscovium-CLI';

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405 });
    }

    // A real browser sends an Accept header asking for HTML; irm and curl do not.
    const accept = request.headers.get('accept') || '';
    const wantsHtml = accept.includes('text/html');

    if (wantsHtml && url.pathname === '/') {
      return Response.redirect(LANDING, 302);
    }

    const upstream = await fetch(UPSTREAM, {
      cf: {
        // The script changes rarely; serve it from the edge and let a deploy
        // purge invalidate. Drop this block if you would rather not cache.
        cacheTtl: 300,
        cacheEverything: true,
      },
      headers: { 'User-Agent': 'moscovium-worker' },
    });

    if (!upstream.ok) {
      return new Response(
        `Could not fetch Moscovium CLI from GitHub (HTTP ${upstream.status}).\n` +
          `Try the direct URL instead:\n  irm ${UPSTREAM} | iex\n`,
        { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } }
      );
    }

    const body = await upstream.text();

    return new Response(body, {
      status: 200,
      headers: {
        // charset matters: Invoke-RestMethod decodes the body using it, and
        // getting it wrong corrupts the script.
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'public, max-age=300',
        'x-content-type-options': 'nosniff',
        // Handy for `irm -Method Head` when checking what is deployed.
        'x-moscovium-upstream': UPSTREAM,
      },
    });
  },
};

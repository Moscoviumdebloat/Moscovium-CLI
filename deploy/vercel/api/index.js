/**
 * Vercel edge function behind the short `irm cli.moscovium.xyz | iex` URL.
 *
 * The same shape as deploy/cloudflare-worker.js, for a domain already served by
 * Vercel. It proxies rather than redirects: Invoke-RestMethod does follow 302s,
 * so a redirect would work, but proxying keeps the response headers ours and
 * means the client only ever talks to one origin.
 *
 * Runs on the edge because the whole job is one fetch and a header rewrite, and
 * because the script is nearly 700 KB — served from the nearest region rather
 * than one.
 */

export const config = { runtime: 'edge' };

/**
 * Where the script actually lives.
 *
 * Pointing at `main` means the short URL always serves the current bundle. Swap
 * `main` for a tag to hold it at a release while main moves on.
 */
const UPSTREAM =
  'https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1';

/** Somewhere readable for people who type the address into a browser. */
const LANDING = 'https://github.com/Moscoviumdebloat/Moscovium-CLI';

/** Long enough to be worth caching, short enough that a push is live within minutes. */
const CACHE_SECONDS = 300;

export default async function handler(request) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response('Method not allowed\n', {
      status: 405,
      headers: { 'content-type': 'text/plain; charset=utf-8', allow: 'GET, HEAD' },
    });
  }

  // A browser asks for HTML; irm, iwr and curl do not. Sending a person 700 KB
  // of PowerShell tells them nothing, so they get the repository instead.
  //
  // Because the two answers share one address, the reply must say it depends on
  // the request — see the Vary header below. Without that, whichever answer was
  // cached first is served to everyone, and a cached redirect reaching `irm`
  // breaks the install line for as long as the cache holds it.
  const accept = request.headers.get('accept') || '';
  if (accept.includes('text/html')) {
    return new Response(`Moscovium CLI\n\n${LANDING}\n`, {
      status: 302,
      headers: {
        location: LANDING,
        'content-type': 'text/plain; charset=utf-8',
        vary: 'Accept',
        // Never reused: this answer is only right for a browser, and serving it
        // to `irm` from a cache would break the one thing this address is for.
        'cache-control': 'no-store',
      },
    });
  }

  let upstream;
  try {
    upstream = await fetch(UPSTREAM, {
      headers: { 'user-agent': 'moscovium-cli-vercel' },
      // Vercel's own cache, so a cold function does not re-fetch from GitHub.
      cf: { cacheTtl: CACHE_SECONDS, cacheEverything: true },
    });
  } catch (error) {
    return unavailable(`Could not reach GitHub: ${error.message}`);
  }

  if (!upstream.ok) {
    return unavailable(`GitHub answered HTTP ${upstream.status}.`);
  }

  const script = await upstream.text();

  // A truncated script is worse than no script: PowerShell would run whatever
  // arrived and stop halfway through, in the middle of changing the system.
  if (!script.trim()) {
    return unavailable('GitHub returned an empty file.');
  }

  return new Response(script, {
    status: 200,
    headers: {
      // The charset matters. Invoke-RestMethod decodes the body according to it,
      // and guessing wrong corrupts every non-ASCII character in the script.
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': `public, max-age=${CACHE_SECONDS}`,
      // Keyed on Accept, so the browser answer and this one cannot be confused
      // for each other by anything caching between here and the caller.
      vary: 'Accept',
      'x-content-type-options': 'nosniff',
      // So `irm -Method Head` can show which bundle is being served.
      'x-moscovium-upstream': UPSTREAM,
    },
  });
}

/**
 * A failure somebody can act on.
 *
 * Plain text and not HTML, because the reader is a terminal. It names the direct
 * URL so a person whose install just failed has somewhere to go rather than only
 * a status code.
 */
function unavailable(reason) {
  return new Response(
    `Moscovium CLI could not be served.\n${reason}\n\n` +
      `Use the direct address instead:\n  irm ${UPSTREAM} | iex\n`,
    { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } },
  );
}

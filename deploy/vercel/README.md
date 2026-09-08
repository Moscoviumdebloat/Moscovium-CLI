# `cli.moscovium.xyz` on Vercel

Serves `moscovium.ps1` behind a short address, so the install line is:

```powershell
irm https://cli.moscovium.xyz | iex
```

Deployed as its own Vercel project (`moscovium-cli`) rather than added to the
website, so the site cannot be broken by a change to this and the two deploy
independently.

## The scheme is not optional

`irm cli.moscovium.xyz` — without `https://` — **does not work**, and cannot be
made to on Vercel.

Windows PowerShell assumes `http://` when no scheme is given. Vercel answers
plain HTTP with a **308 Permanent Redirect** to HTTPS, issued by the platform
edge before any function runs, and the `Invoke-RestMethod` in Windows PowerShell
5.1 does not follow a 308:

```
irm cli.moscovium.xyz
  The remote server returned an error: (308) Permanent Redirect.

irm https://cli.moscovium.xyz
  693047 characters
```

Nothing in `vercel.json` or in the function changes this: the redirect is the
platform's forced-HTTPS behaviour and the status code is not configurable.

If the bare form matters more than staying on Vercel, put the domain behind
Cloudflare and use `deploy/cloudflare-worker.js` instead — Cloudflare's *Always
Use HTTPS* answers with a 301, which PowerShell 5.1 does follow. PowerShell 7
follows 308 and works either way.

## How it behaves

| Request | Answer |
|---|---|
| `irm`, `iwr`, `curl` (no `Accept: text/html`) | the script, `text/plain; charset=utf-8` |
| a browser (`Accept: text/html`) | 302 to the GitHub repository |
| anything but GET or HEAD | 405 |
| GitHub unreachable or empty | 502, naming the direct URL to use instead |

Both answers live at one address, so each carries `Vary: Accept` and the
redirect is `no-store`. Without that, whichever answer was cached first is
served to everyone — and a cached redirect reaching `irm` breaks the install
line for as long as the cache holds it. That happened during setup: the script
was cached, and browsers were then served 700 KB of PowerShell.

The charset is stated explicitly because `Invoke-RestMethod` decodes the body
according to it, and getting it wrong corrupts every non-ASCII character.

## Deploying a change

```bash
cd deploy/vercel
vercel deploy --prod
```

The script itself is **not** deployed here — it is fetched from `main` on GitHub
at request time and cached for five minutes, so pushing `moscovium.ps1` is
enough and this project only changes if the serving behaviour does. To hold the
short URL at a release, point `UPSTREAM` in `api/index.js` at a tag.

Checking what is being served, without running it:

```powershell
(irm https://cli.moscovium.xyz).Length
(iwr https://cli.moscovium.xyz -Method Head).Headers['x-moscovium-upstream']
```

# Hosting the `irm` one-liner

Moscovium CLI ships as a single file, `moscovium.ps1`, so the entry point is
just "serve one file over HTTPS". There are two supported ways to do that.

## 1. Raw GitHub — works immediately, nothing to set up

Once `moscovium.ps1` is committed and pushed, this already works:

```powershell
irm https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1 | iex
```

No infrastructure, no DNS, no cost. The only downside is the length.

Pin a tag instead of `main` if you want people to get a fixed version:

```powershell
irm https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/v1.0.0/moscovium.ps1 | iex
```

## 2. Short domain — `irm moscovium.win | iex`

This needs a domain you own on Cloudflare. `cloudflare-worker.js` proxies the
raw GitHub file, and `wrangler.toml` routes your apex domain at it.

```bash
npm install -g wrangler
wrangler login
wrangler deploy --config deploy/wrangler.toml
```

Before deploying, edit both files:

- `wrangler.toml` — set `name`, and change the route pattern and `zone_name`
  to your domain.
- `cloudflare-worker.js` — set `UPSTREAM` to your repo's raw URL if the org or
  repo name differs, and `LANDING` to wherever browsers should go.

Then check it:

```powershell
# Should print the first line of the script, not HTML.
(irm https://moscovium.win) -split "`n" | Select-Object -First 3
```

### Why a Worker rather than a redirect

A plain 301 to raw.githubusercontent.com does work — `Invoke-RestMethod`
follows redirects. The Worker is preferred because it:

- sets `content-type: text/plain; charset=utf-8` explicitly, so
  `Invoke-RestMethod` decodes the body correctly rather than guessing;
- sends browsers to the repo page instead of a wall of PowerShell;
- gives you one place to pin, cache or roll back the served version without
  touching the repo.

### GitHub Pages alternative

If you would rather not run a Worker, GitHub Pages serves the file from a
custom domain too. Add a `CNAME` file and publish `moscovium.ps1` at the site
root. Pages sets `content-type: text/plain` for `.ps1`, which is fine for
`irm`. You lose the browser redirect and the pinning control.

## Verifying a deployment

`tests/Run-Tests.ps1` checks that the committed bundle is current and parses.
To check what a live URL is actually serving:

```powershell
$served = irm https://moscovium.win
$local  = Get-Content .\moscovium.ps1 -Raw
if ($served.Trim() -eq $local.Trim()) { 'in sync' } else { 'DEPLOYED VERSION DIFFERS' }
```

## A note on `irm | iex`

`irm <url> | iex` runs whatever that URL returns, with the privileges of the
shell. That is true of this project and of every other tool distributed this
way. Two things follow, and both are worth telling users in your release notes:

- Anyone who can change what the URL serves can run code on every machine that
  pipes it to `iex`. Protect the repo and the Cloudflare account accordingly.
- Users who want to read before running should fetch first and inspect:

  ```powershell
  $script = irm https://moscovium.win
  $script | Out-File moscovium.ps1     # read it, then:
  .\moscovium.ps1
  ```

The script itself applies the same standard to third parties: WinUtil,
Win11Debloat and any catalog entry with a `scriptUrl` all print their source URL
and require a confirmation before anything is fetched or run.

# Moscovium CLI

The command-line companion to [Moscovium](https://github.com/Moscoviumdebloat/Moscovium),
the Windows debloat and setup toolbox. Same tweaks, same app catalog, and a
window when you want one - all from a single line on a machine you just
finished installing.

```powershell
irm https://raw.githubusercontent.com/Moscoviumdebloat/Moscovium-CLI/main/moscovium.ps1 | iex
```

That drops you into an interactive menu. Nothing is installed, nothing is
downloaded to disk, and no .NET runtime is required — Windows PowerShell 5.1,
which ships with Windows, is enough.

---

## What it does

| | |
|---|---|
| **40 tweaks** | Privacy & telemetry, Explorer & taskbar, gaming & performance, hardware, advanced. Applied, reverted, or reported on. |
| **127 apps** | The full curated winget catalog, plus direct-download and archive installers, across 8 categories. |
| **One-click debloat box** | Six steps behind one prompt: WinUtil preset, Win11Debloat preset, security-only Windows Update, TCP autotuning, CPU priority, dynamic tick. |
| **17 toolbox actions** | WinUtil, Win11Debloat, Windows Update policy, TCP autotuning, dynamic tick, CPU priority, and the classic control panels. |
| **6 guides** | The manual walkthroughs - BIOS, GPU control panels, network - that no tool can do for you. |
| **App store** | Community releases from the Moscovium dev orgs on GitHub. |
| **Personalise** | Cursor schemes, wallpaper, Counter-Strike configs. |
| **Profiles** | Setup checklists, interchangeable with the desktop app's. |
| **Two front-ends** | The same engine drives a terminal UI and a window. `-Gui` opens the window. |

Everything in the tweak and app catalogs is generated directly from the GUI's C#
source, so the two stay in step. See [Keeping up with the GUI](#keeping-up-with-the-gui).

## Two things the desktop app does not do

**Revert.** Before writing anything, the CLI records the prior state of every
registry value it is about to touch — the old value and type, or the fact that
it did not exist, or that its key did not exist. That snapshot goes to
`%LOCALAPPDATA%\Moscovium\backups\`, and `-Revert` replays it: old values
restored, values it introduced deleted, and keys it created removed if they end
up empty again.

```powershell
.\moscovium.ps1 -Apply "Dark Theme"
.\moscovium.ps1 -Revert "Dark Theme"     # exactly back to how it was
```

The four action tweaks — Disk Cleanup, Remove Temp Files, Create Restore Point —
are one-shot and say so. High Performance Power Plan is the exception: it records
the previously active scheme, so it does revert.

**Dry run.** `-DryRun` prints every registry write it would make, then makes
none of them.

```powershell
.\moscovium.ps1 -Apply "Privacy & Telemetry" -DryRun
```

## GUI

`moscovium.ps1 -Gui` opens a window. It is the same file, the same catalogs and
the same engine - not a second implementation.

![The Moscovium GUI](docs/gui.png)

```powershell
irm <url> | iex                                    # menu, then pick GUI
& ([scriptblock]::Create((irm <url>))) -Gui        # straight to the window
.\moscovium.ps1 -Gui
```

The theme is AMOLED: the canvas is true black, so those pixels are simply off on
an OLED panel, and surfaces lift off it in near-black purples rather than greys.

Rows are grouped by category with a count per group, ticking one tints the whole
row, the action buttons say how many are selected and disable when none are, and
the sidebar carries the size of each page. Ctrl+F jumps to the search box on the
current page; Escape clears it.

Every button calls the function the CLI calls: `Invoke-Tweaks`,
`Invoke-AppInstall`, `Invoke-ToolboxAction`, `Invoke-SetupProfile`. What makes
that possible is three optional sinks on the shared context - `Sink`,
`ProgressSink` and `ConfirmSink`. Leave them unset and output goes to the
console; the window sets them, and the identical engine calls end up in the log
pane, the progress bar and modal dialogs instead. There is a test that fails if
the GUI ever grows its own registry writes or winget calls.

It uses WPF, which ships with .NET Framework, so there is still nothing to
install and it still works straight from `irm`. Two consequences worth knowing:

- **WPF needs an STA thread.** `powershell.exe` is STA; `pwsh` is not. Started
  from `pwsh`, the GUI relaunches itself in an STA host rather than failing.
- **Long work runs on the UI thread**, pumping the dispatcher between items, so
  the window keeps painting and the action buttons disable while it runs. It is
  cooperative rather than a background runspace - honest about what it is.

**It is always elevated.** Nearly every tweak writes to `HKLM`, so a
non-elevated window would show a catalog it mostly cannot apply. `-Gui` requests
elevation up front and reopens itself; there is no in-app "restart as admin"
button to explain, and no permanently red "not elevated" badge to ignore.

The one exception is `-Gui -DryRun`, which opens without a UAC prompt, because a
dry run writes nothing and demanding elevation to preview a plan would be
theatre. The header carries a DRY RUN badge so the two are never confused.

## Usage

### Interactive

```powershell
irm <url> | iex          # menu
.\moscovium.ps1          # same, from a local copy
```

Arrow keys move, space toggles, `/` filters, enter confirms, escape goes back.
In a host that cannot read individual keypresses — a redirected stdin, ISE,
`-NonInteractive` — it falls back to numbered prompts rather than failing.

### With arguments

`iex` cannot pass arguments, so use the script-block form:

```powershell
& ([scriptblock]::Create((irm <url>))) -Status
& ([scriptblock]::Create((irm <url>))) -Apply "Privacy & Telemetry" -Yes
```

Or download once and run it as a normal script.

### Tweaks

```powershell
.\moscovium.ps1 -Status                              # what is applied right now
.\moscovium.ps1 -Apply "Disable Telemetry"           # by exact name
.\moscovium.ps1 -Apply "Explorer & Taskbar"          # by category
.\moscovium.ps1 -Apply "Disable *"                   # by wildcard
.\moscovium.ps1 -Apply all -Yes                      # everything, no prompts
.\moscovium.ps1 -Revert "Dark Theme"
```

Names, categories, wildcards, bare substrings and `all` are interchangeable
everywhere. Anything that matches nothing is reported rather than skipped
silently.

### Apps

```powershell
.\moscovium.ps1 -Install 7zip.7zip
.\moscovium.ps1 -Install Browsers                    # a whole category
.\moscovium.ps1 -Install "VLC*",Discord,Git.Git      # mix and match
.\moscovium.ps1 -UpgradeAll                          # winget upgrade --all
.\moscovium.ps1 -VCRuntimes                          # all VC++ redistributables
```

### Toolbox

```powershell
.\moscovium.ps1 -List toolbox
.\moscovium.ps1 -Toolbox oneclick          # the whole debloat box
.\moscovium.ps1 -Toolbox winutil-preset
.\moscovium.ps1 -Toolbox network-better
```

### Profiles

```powershell
.\moscovium.ps1 -Profile .\my-setup.json
.\moscovium.ps1 -Apply "Privacy & Telemetry" -Install Browsers -SaveProfile .\my-setup.json
```

Profiles use the same JSON shape as the desktop app's `SetupProfile`, so one
saved in the GUI runs here and vice versa.

### Everything else

```powershell
.\moscovium.ps1 -Help
.\moscovium.ps1 -List tweaks | apps | toolbox | backups | categories
.\moscovium.ps1 -Search hibernation
```

| Flag | |
|---|---|
| `-DryRun` | print the plan, change nothing |
| `-Yes` | skip confirmations |
| `-Gui` | open the graphical interface |
| `-Elevate` | relaunch elevated immediately |
| `-NoColor` | plain output |
| `-Ascii` | ASCII glyphs instead of box drawing |
| `-NoBanner` | skip the banner |

## How it looks

```
   __  __                                   _
  |  \/  |  ___   ___   ___   ___  __   __ (_) _   _  _ __ ___
  | |\/| | / _ \ / __| / __| / _ \ \ \ / / | || | | || '_ ` _ \
  | |  | || (_) |\__ \| (__ | (_) | \ V /  | || |_| || | | | | |
  |_|  |_| \___/ |___/ \___| \___/   \_/   |_| \__,_||_| |_| |_|

  ──────────────────────────────────────────────────────────────────────────────
  v1.2.0   ·   40 tweaks   ·   127 apps   ·   ● elevated
  ──────────────────────────────────────────────────────────────────────────────

  ─── Privacy & Telemetry ────────────────────────────────────────────────── 6/7
  ◉ Disable Telemetry                             applied
  ◉ Disable Activity History                      applied
  ○ Set Time to UTC

    NVIDIA App  ███████████░░░░░░░░░░░░░░░   42%   87.4 MB / 208.0 MB   8.5 MB/s
```

Everything degrades. On a console that cannot render box drawing the same
screens come out as `---`, `[x]`, `[ ]` and `#`, which is what a fresh Windows
install in legacy conhost gets. `-Ascii` forces that mode; `-NoColor` drops
colour too.

There are no ANSI escape sequences anywhere — legacy conhost does not process
them by default, and a debloat tool is exactly what people run on a machine in
that state. The selection bar, the status colours and the banner gradient are
all built from Write-Host's sixteen colours, which behave identically in conhost
and Windows Terminal.

## Elevation

Most tweaks write to `HKLM` and need administrator rights. Run the CLI from an
elevated prompt, or let it relaunch itself — it will offer, and rebuild your
exact invocation for the elevated child. When it was piped from the network,
the child re-fetches the same URL, so pin that URL if you care.

Unelevated, per-user (`HKCU`) tweaks still apply; the rest are reported as
skipped rather than silently failing.

## Layout

```
moscovium.ps1     the built single-file bundle - this is what irm fetches
build.ps1         bundles src/ + data/ into it
VERSION

src/              function libraries, concatenated in name order
  00-Core         context, output sinks, prompting, elevation
  01-Catalog      catalog loading and name resolution
  05-Theme        terminal capabilities, glyphs, rules, progress
  10-Registry     registry read/write, snapshots, backups
  20-Tweaks       apply, revert, status
  30-Apps         winget, download, zip and script installs
  40-Toolbox      one-shot actions
  50-Profile      setup profiles
  60-Menu         interactive selectors and screens
  70-Gui          the WPF window
  90-Main         argument dispatch

data/             generated catalogs and gui.xaml, embedded at build time
tools/            Sync-Catalog.ps1 and the C# literal parser it uses
tests/            Run-Tests.ps1
deploy/           Cloudflare Worker for the short irm URL
```

`moscovium.ps1` is generated. Edit `src/` and run `./build.ps1`.

### Why a bundle

`irm <url> | iex` has nowhere to put a second file, so everything — the two JSON
catalogs included — is embedded in one script.

`iex` also runs its input in the **caller's** scope. A bare concatenation would
leave sixty-odd functions, a `$Ctx` variable and a modified
`$ErrorActionPreference` sitting in the user's session afterwards. So the bundle
wraps itself in a script block and invokes that; the run gets its own scope and
leaves nothing behind. There is a test for it.

## Building and testing

```powershell
./build.ps1            # regenerate moscovium.ps1
./build.ps1 -Check     # fail if it is stale (CI)
./tests/Run-Tests.ps1
```

The suite covers catalog integrity, name resolution, the registry engine, the
apply/revert round-trip, the theme, menu geometry, profiles, the GUI and the
bundle itself. The registry tests write only to
`HKCU\Software\MoscoviumCliTest`, which they create and remove; no real system
setting is touched.

Two things to expect while it runs:

- A minimised PowerShell window appears for about twelve seconds. That is the
  GUI smoke test launching the **built bundle** with `-Gui`. It has to be the
  bundle rather than `src/`, because the bundle wraps everything in `& { ... }`
  and that scope difference is real: it is where a working GUI and a broken one
  diverge. Run the suite under `powershell.exe`, not `pwsh` — WPF needs STA, and
  the three window-construction tests skip on an MTA host.
- The registry tests briefly create and delete their scratch key.

## Keeping up with the GUI

`tools/Sync-Catalog.ps1` reads `Models/AppTweak.cs` and `Models/SetupProfile.cs`
from the GUI repo and regenerates `data/tweaks.json` and `data/apps.json`. Run it
after the GUI's catalogs change:

```powershell
./tools/Sync-Catalog.ps1                      # clones the GUI repo
./tools/Sync-Catalog.ps1 -GuiPath ../Moscovium # or use a local checkout
./build.ps1
./tests/Run-Tests.ps1
```

The generated files record which GUI commit they came from.

## What came across from the desktop app

Everything except the parts that cannot live in a single script:

| Desktop app | Here |
|---|---|
| Tweaks, App Store, Optimizations, Toolbox, Legacy Menus | ported |
| Guides, CS2/CS:GO configs, Settings | ported |
| Cursors | the mechanism, not the packs - point it at a folder of `.cur`/`.ani` files, or restore the Windows defaults. The bundled schemes are several hundred binary files. |
| Wallpaper | ported |
| Customization page installers | use the winget entries in the app catalog (ExplorerPatcher, StartAllBack, Open-Shell) rather than bundled `.exe` payloads |

## Not ported from the GUI

Two catalog entries are deliberately absent: the **MAS activation** bootstrap and
the **StartAllBack trial reset**. Both exist to circumvent licensing. Everything
else on the GUI's Optimizations, Toolbox, Customization and Legacy Menus pages is
here. The exclusion is one list in `tools/Sync-Catalog.ps1` if you disagree.

Also not ported, because they are inherently graphical: the bundled cursor packs,
wallpaper setting, and the CS2/CS:GO config pages.

## Third-party scripts

WinUtil, Win11Debloat and any catalog entry with a `scriptUrl` run code published
by someone else. The CLI shows the URL *and the exact command* and asks first,
every time. It does not pin or review their contents — nor does the GUI.

The prompt defaults to yes, so Enter runs it. The window closes as soon as you
quit the tool; it only stays open if the script fails outright, so an error like
a bad parameter is still readable instead of flashing past. The CLI waits and
returns to what you were doing once the window closes.

They are launched as `irm <url> | iex` in a **separate PowerShell process**, not
executed inside the CLI. That matters:

- This bundle runs under `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'`, and child scopes inherit both. A
  15,000-line WPF script is not written to survive either.
- WinUtil calls a bare `break` when it self-elevates, which in-process would
  unwind whatever loop the CLI was running, including the menu.
- WinUtil is a WPF app and wants its own host and console.

**On `winutil-preset`:** current WinUtil takes `-Config`, `-Preset` and
`-Offline`. There is no `-Run`, and `-Config` only *preselects* tweaks in the
GUI — you still press Run Tweaks. The desktop app passes `-Config <path> -Run`,
which today fails parameter binding outright, so its "Automated" button does
nothing. The CLI sends `-Config` alone, which is exactly what WinUtil's own
"copy config command" button produces.

`raphi-auto` genuinely is unattended; all 24 of its flags are still valid.

### The one-click box

`-Toolbox oneclick` runs six steps behind a single confirmation, after listing
both third-party URLs and everything it is about to do:

| | |
|---|---|
| 1 | WinUtil with `data/winutil-oneclick.json` — 20 tweaks, restore point first |
| 2 | Win11Debloat with `data/raphi-oneclick.json` — 40 tweaks, `-Silent` |
| 3 | Windows Update set to security-only |
| 4 | TCP autotuning disabled |
| 5 | `Win32PrioritySeparation` = 22 |
| 6 | Dynamic tick disabled |

Steps 5 and 6 need a reboot. Step 1 is the one that is *not* unattended, for
the reason above: WinUtil has no `-Run`, so its window opens with everything
ticked and you press Run Tweaks.

Two things about the presets are worth knowing, because both are constraints
imposed by the tools rather than choices:

**Security updates could not go in the WinUtil preset.** WinUtil exposes it as
`WPFUpdatessecurity`, which is a *Button*, not a checkbox — and `Invoke-WPFImpex`
only restores checkbox selections, filtering names to
`^WPF(?:Install|Tweaks|Toggle|Feature|Appx)`. A config naming it is silently
dropped. So `Set-SecurityUpdatePolicy` in `src/40-Toolbox.ps1` writes the same
policy values `Invoke-WPFUpdatessecurity` does, and it is also available on its
own as `-Toolbox updates-security`.

**Bing removal could not come from WinUtil either.** There is no Bing tweak
anywhere in its 42 `WPFTweaks*` keys. It comes from Win11Debloat's
`DisableBing`, which is in the Raphi preset.

`data/winutil-oneclick.json` is a flat array, which is what current WinUtil
exports — `($selectedApps + $selectedTweaks + ...) | ConvertTo-Json`. The
older `winutil-debloat.json` object form still imports, but through WinUtil's
`$isLegacyConfig` branch.

`data/raphi-oneclick.json` uses Win11Debloat's own `-Config` schema
(`Version` / `Apps` / `Tweaks` / `Deployment`), validated in the test suite
against the same rules `Test-ConfigConsistency` and `Import-ConfigToParams`
apply. Both presets ask their script to take a restore point first.

## Requirements

Windows 10 1809 or newer, Windows PowerShell 5.1 (built in) or PowerShell 7.
`winget` is needed for app installs only; the CLI says so if it is missing.

## Licence

Same as [Moscovium](https://github.com/Moscoviumdebloat/Moscovium).

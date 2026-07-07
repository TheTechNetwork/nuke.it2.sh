# nuke.it2.sh

**Antivirus / EDR search & destroy.** An interactive PowerShell menu — in the
spirit of `get.activated.win` — that removes stubborn security agents from
Windows during offboarding, re-imaging, or a vendor migration. Consumer AV gets
force-removed; tamper-protected EDRs get the supported token/passphrase
uninstall plus leftover cleanup.

Part of the [it2.sh](https://it2.sh) family of one-line tools.

```powershell
# Windows — PowerShell (run as Administrator) — interactive menu
irm nuke.it2.sh | iex
```

Or jump straight to a target by putting it in the URL path — no menu:

```powershell
irm nuke.it2.sh/mcafee | iex     # just McAfee
irm nuke.it2.sh/s1     | iex     # SentinelOne  (alias of /sentinelone)
irm nuke.it2.sh/all    | iex     # every consumer AV in one pass
```

| Path | Runs |
| --- | --- |
| `/mcafee` | McAfee |
| `/norton` · `/symantec` | Norton / Symantec |
| `/avast` · `/avg` | Avast / AVG |
| `/crowdstrike` · `/cs` · `/falcon` | CrowdStrike Falcon |
| `/sentinelone` · `/s1` · `/sentinel` | SentinelOne |
| `/all` | every **consumer** AV (McAfee, Norton, Avast, Bitdefender, ESET, Webroot, Malwarebytes, Kaspersky, Avira) — EDRs are skipped since each needs a token/passphrase |

The target is a fixed alias resolved by the Worker (never free text), so there's
no injection surface. Self-elevation preserves the target — `irm nuke.it2.sh/s1`
relaunches as `irm nuke.it2.sh/s1`.

Not elevated? The tool detects it and offers to relaunch itself as Administrator.

## What you get

A menu. You pick a vendor, type `YES` to confirm, and watch it work:

```
   ███╗   ██╗██╗   ██╗██╗  ██╗███████╗
   ████╗  ██║██║   ██║██║ ██╔╝██╔════╝
   ██╔██╗ ██║██║   ██║█████╔╝ █████╗
   ██║╚██╗██║██║   ██║██╔═██╗ ██╔══╝
   ██║ ╚████║╚██████╔╝██║  ██╗███████╗
   ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
   nuke.it2.sh  —  antivirus search & destroy

  Pick an antivirus to force-remove:

   1) McAfee  —  Total Protection, LiveSafe, Security Scan, WebAdvisor, enterprise agent
   2) Norton / Symantec  —  Norton 360 / Security, NortonLifeLock, Symantec Endpoint Protection
   3) Avast / AVG  —  Avast Antivirus / One and AVG (same engine)
   4) CrowdStrike Falcon  —  Falcon sensor (EDR), needs the maintenance token from your console
   5) SentinelOne  —  S1 agent (EDR), needs the anti-tamper passphrase from your console

   Q) Quit
```

## Supported vendors

**Consumer AV** — official uninstaller → full force-removal:

| Vendor | Path | Public cleaner offered |
| --- | --- | --- |
| **McAfee** | `/mcafee` | MCPR |
| **Norton / Symantec** | `/norton` `/symantec` | — |
| **Avast / AVG** | `/avast` `/avg` | avastclear |
| **Bitdefender** | `/bitdefender` `/bd` | — |
| **ESET** | `/eset` `/nod32` | — |
| **Webroot** | `/webroot` | — |
| **Malwarebytes** | `/malwarebytes` `/mbam` `/mb` | Support Tool (mb-clean) |
| **Kaspersky** | `/kaspersky` `/kav` | kavremover |
| **Avira** | `/avira` | — |

**EDR** — tamper-protected; supported uninstall with a credential from *your*
console, then leftover cleanup (never brute-forced):

| Vendor | Path | Credential |
| --- | --- | --- |
| **CrowdStrike Falcon** | `/crowdstrike` `/cs` `/falcon` | maintenance token |
| **SentinelOne** | `/sentinelone` `/s1` | anti-tamper passphrase |
| **Sophos** | `/sophos` | tamper-off in Central / SophosZap |
| **Trend Micro** (Apex One) | `/trendmicro` `/trend` | unload/uninstall password |
| **BlackBerry / Cylance** | `/cylance` `/blackberry` | uninstall password |
| **VMware Carbon Black** | `/carbonblack` `/cb` | uninstall/company code |

One parametrized engine (`Invoke-GenericAvRemoval`) drives every vendor; each is
just a config entry in the `$script:Vendors` registry. Service/driver name lists
are best-effort and vary by version — the engine also matches each vendor's name
against the service's binary path, so it catches renamed services too.

### A note on the EDRs

CrowdStrike and SentinelOne self-protect at the kernel level. You **cannot**
brute-force-delete a running Falcon or S1 sensor — the driver blocks it, and
trying can leave the machine unbootable. The only supported removal is the
vendor uninstaller with a credential **you** pull from your own console:

- **CrowdStrike** — a *maintenance token* (Falcon → Host setup & management →
  Sensor update policies → uninstall token).
- **SentinelOne** — the *anti-tamper passphrase* (S1 console → Sentinels → the
  endpoint → Actions → Show Passphrase).

The tool prompts for it, runs the supported uninstall, and then cleans up
leftovers. If a core service is still present afterwards (wrong/missing
credential, uninstall protection on), it **stops before the destructive stages**
and tells you what's needed — it does not fight a still-protected agent.

## How consumer-AV removal works

The proper way first, then by force (McAfee shown; every consumer vendor runs
the same stages against its own names):

1. **Official uninstallers** — runs every vendor uninstaller registered in the
   registry (silently where possible). Doing this first keeps Windows Installer
   state clean and lets the vendor unhook its own drivers / WFP filters.
2. **Processes** — kills anything from the vendor still running.
3. **Services & kernel drivers** — stops, disables and deletes them; self-protected
   ones are marked for deletion at reboot.
4. **Scheduled tasks** — unregisters the vendor's tasks.
5. **AppX packages** — removes installed and provisioned Store packages.
6. **Known folders** — force-deletes the vendor's folders under Program Files,
   ProgramData and every user profile, escalating through `takeown` / `icacls`
   and finally queueing locked files for deletion at next reboot.
7. **Registry & autoruns** — removes the vendor's keys and Run entries.
8. **Deep scan (optional)** — sweeps the whole system drive for the vendor's
   name(s) that survived. Matches under program/system locations are deleted;
   matches anywhere else (e.g. your own documents) are **listed for review,
   never auto-deleted**.

Between steps 1 and 2, if the vendor publishes a **public cleaner tool**, the
tool offers to download and run it (opt-in). Wired today: **McAfee MCPR** and
**avastclear** (both verified live). Vendors whose cleaners sit behind a
support/partner portal — Symantec CleanWipe, CrowdStrike `CsUninstallTool`,
SentinelOne's cleaner — are intentionally *not* auto-downloaded; grab those from
your portal and run them yourself.

A full transcript is written to `%TEMP%\AV-Removal-*.log` (path printed at the
end). If anything is genuinely locked, it's queued for deletion on the next
reboot. Whatever survives even that is listed at the end, along with the
vendor-specific fallback tool (McAfee MCPR, Symantec CleanWipe, avastclear, …).

## Safety

This is an aggressive, admin-only cleanup tool. It is built to be careful about
what "aggressive" is allowed to touch:

- **Confirmation required** — you type `YES` before anything is removed.
- **Protected paths** — it refuses to delete drive roots and top-level system
  folders (`C:\`, `C:\Windows`, `C:\Program Files`, `Users`, …), whatever a bad
  wildcard match might hand it.
- **Reparse-point safe** — junctions and symlinks are unlinked as links; the
  recursive delete never follows one into unrelated data.
- **No lingering ACLs** — access it grants to delete a stubborn item is reset if
  the item survives, so nothing is left world-writable.
- **Deep scan is conservative** — outside known program locations it only
  reports; it never deletes your files.

- **EDRs are not brute-forced** — for CrowdStrike / SentinelOne, if the agent is
  still tamper-protected after the supported uninstall, the tool stops rather
  than risk bricking the machine.

> Review [`public/nuke.ps1`](public/nuke.ps1) before running it. It is not
> affiliated with McAfee, Norton, Symantec, Avast, AVG, CrowdStrike,
> SentinelOne, or any vendor named here. Use it only on machines you administer.

## How it works (hosting)

- A Cloudflare Worker is bound to the `nuke.it2.sh` custom domain.
- It does **content negotiation** on the request:
  - Terminals (`curl` / `wget` / PowerShell user-agents) → the raw `nuke.ps1`.
  - Browsers (`Accept: text/html`) → a self-contained explainer page.
- **Path routing:** the first path segment (`/s1`, `/mcafee`, `/all`, …) is
  resolved through a fixed alias table to a canonical vendor key, and the Worker
  prepends `$script:NukeTarget = '<key>'` to the served script so it runs that
  target non-interactively. An unknown segment returns a `404` with the valid
  list. The injected value only ever comes from the allow-list, so it can't be
  used to smuggle PowerShell into the script.
- The script is served from the bound `./public` assets directory — single
  source of truth, no build step.

## Adding a vendor

One engine (`Invoke-GenericAvRemoval`) drives every vendor, so adding one is
usually just data. Drop an object into the `$script:Vendors` registry in
[`public/nuke.ps1`](public/nuke.ps1):

```powershell
[pscustomobject]@{
    Key = 'webroot'; Name = 'Webroot'; Ready = $true; Protected = $false
    Blurb = 'Webroot SecureAnywhere'
    FallbackNote = "Leftovers? Use Webroot's CleanUp tool."
    Config = @{
        DisplayName  = 'Webroot'
        ProductMatch = 'webroot'                 # regex vs "DisplayName Publisher"
        ServiceExact = '^(wrsvc|wrsa|wrkrn|wrbootdrv)$'  # names without the vendor word
        FolderNames  = @('Webroot')
        RegKeys      = @('HKLM:\SOFTWARE\WRData', 'HKLM:\SOFTWARE\WRCore')
        AppxPatterns = @('*webroot*')            # optional
        DeepFilters  = @('*webroot*')            # optional whole-drive sweep
    }
}
```

For a tamper-protected EDR, add `CoreServices = @(...)` (the engine stops if any
survive the uninstall) and a `PreUninstall` scriptblock that runs the vendor's
token/passphrase uninstall. The menu picks it up automatically.

## Deploy

```bash
npx wrangler deploy
```

The route and custom domain are configured in [`wrangler.toml`](wrangler.toml).

## Endpoints

| Path | Response |
| --- | --- |
| `/` | Raw `nuke.ps1` interactive menu (terminal) or explainer page (browser) |
| `/<target>` | `nuke.ps1` with a direct target injected (`/mcafee`, `/s1`, `/all`, …) |
| `/<unknown>` | `404` plain text with the valid target list |
| `/health` | `200 OK` — health check |
| `/favicon.ico` | `204 No Content` |

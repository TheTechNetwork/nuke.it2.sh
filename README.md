# nuke.it2.sh

**Antivirus search & destroy.** An interactive PowerShell menu — in the spirit
of `get.activated.win` — that force-removes stubborn antivirus bloatware from
Windows. First target: **McAfee**, because it re-installs itself, self-protects
its services, and refuses to die quietly.

Part of the [it2.sh](https://it2.sh) family of one-line tools.

```powershell
# Windows — PowerShell (run as Administrator)
irm nuke.it2.sh | iex
```

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
   2) Norton / NortonLifeLock  (coming soon)
   3) Avast / AVG  (coming soon)

   Q) Quit
```

## How McAfee removal works

The proper way first, then by force:

1. **Official uninstallers** — runs every McAfee uninstaller registered in the
   registry (silently where possible). Doing this first keeps Windows Installer
   state clean and lets McAfee unhook its own drivers / WFP filters.
2. **Processes** — kills anything McAfee still running.
3. **Services & kernel drivers** — stops, disables and deletes them; self-protected
   ones are marked for deletion at reboot.
4. **Scheduled tasks** — unregisters McAfee tasks.
5. **AppX packages** — removes installed and provisioned Store packages.
6. **Known folders** — force-deletes McAfee folders under Program Files,
   ProgramData and every user profile, escalating through `takeown` / `icacls`
   and finally queueing locked files for deletion at next reboot.
7. **Registry & autoruns** — removes McAfee keys and Run entries.
8. **Deep scan (optional)** — sweeps the whole system drive for anything named
   `*mcafee*` that survived. Matches under program/system locations are deleted;
   matches anywhere else (e.g. your own documents) are **listed for review,
   never auto-deleted**.

A full transcript is written to `%TEMP%\AV-Removal-*.log` (path printed at the
end). If anything is genuinely locked, it's queued for deletion on the next
reboot. Whatever survives even that is listed at the end — finish it off with
McAfee's official [MCPR](https://www.mcafee.com/support) tool.

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

> Review [`public/nuke.ps1`](public/nuke.ps1) before running it. It is not
> affiliated with McAfee, Norton, Avast, or any vendor named here.

## How it works (hosting)

- A Cloudflare Worker is bound to the `nuke.it2.sh` custom domain.
- It does **content negotiation** on the request:
  - Terminals (`curl` / `wget` / PowerShell user-agents) → the raw `nuke.ps1`.
  - Browsers (`Accept: text/html`) → a self-contained explainer page.
- The script is served from the bound `./public` assets directory — single
  source of truth, no build step.

## Adding a vendor

Removal logic lives in `public/nuke.ps1`. To add an AV:

1. Write an `Invoke-<Vendor>Removal` function using the shared forced-removal
   primitives (`Remove-ItemForcefully`, the reparse-point helpers, etc.).
2. Add an entry to the `$script:Vendors` registry with `Ready = $true` and an
   `Action` scriptblock that calls it. The menu picks it up automatically.

## Deploy

```bash
npx wrangler deploy
```

The route and custom domain are configured in [`wrangler.toml`](wrangler.toml).

## Endpoints

| Path | Response |
| --- | --- |
| `/` | Raw `nuke.ps1` (terminal) or explainer page (browser) |
| `/health` | `200 OK` — health check |
| `/favicon.ico` | `204 No Content` |

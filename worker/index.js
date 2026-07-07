// Cloudflare Worker for nuke.it2.sh — the AV force-removal TUI.
//
// nuke.it2.sh serves an interactive PowerShell menu that rips stubborn
// antivirus bloatware off Windows (McAfee first). One line to run it:
//
//   irm nuke.it2.sh | iex
//
// Content negotiation, same as the rest of the it2.sh family:
//   • Terminals (curl / PowerShell / wget) → the raw nuke.ps1 script
//   • Browsers (Accept: text/html)         → a styled "what is this" page
//
// The script itself lives in ./public/nuke.ps1 and is served from the
// bound ASSETS directory, so there's a single source of truth.

const TITLE = "nuke.it2.sh";
const TAGLINE = "Antivirus search & destroy — force-remove stubborn AV bloatware, one line.";
const REPO = "https://github.com/TheTechNetwork/nuke.it2.sh";
const RUN_CMD = "irm nuke.it2.sh | iex";

// URL-path targets: nuke.it2.sh/<segment> runs that vendor straight away,
// skipping the interactive menu. Each alias maps to a canonical vendor Key in
// the script's $script:Vendors registry (or the literal 'all'). Because we only
// ever inject a value from THIS fixed allow-list, there is no script-injection
// surface (unlike a free-text path).
const TARGETS = {
  mcafee: "mcafee",
  norton: "norton", symantec: "norton",
  avast: "avast", avg: "avast",
  crowdstrike: "crowdstrike", cs: "crowdstrike", falcon: "crowdstrike",
  sentinelone: "sentinelone", s1: "sentinelone", sentinel: "sentinelone",
  all: "all",
};

function escapeHtml(str) {
  return str.replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

// Terminal clients (curl, wget, PowerShell) don't ask for HTML.
function wantsHtml(request) {
  const accept = (request.headers.get("Accept") || "").toLowerCase();
  const ua = (request.headers.get("User-Agent") || "").toLowerCase();
  if (/\bcurl\b|\bwget\b|powershell|libcurl/.test(ua)) return false;
  return accept.includes("text/html");
}

function renderHtml() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(TITLE)} — antivirus search &amp; destroy</title>
<meta name="description" content="${escapeHtml(TAGLINE)}">
<style>
  :root {
    --bg: #0d1117; --panel: #161b22; --border: #30363d;
    --fg: #e6edf3; --muted: #8b949e; --accent: #ff5c5c; --code: #0b0f14;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  .wrap { max-width: 720px; margin: 0 auto; padding: 3rem 1.25rem 4rem; }
  h1 { font-size: 2.4rem; margin: 0 0 .25rem; letter-spacing: -.02em; }
  h1 .dot { color: var(--accent); }
  .tagline { color: var(--muted); margin: 0 0 2rem; }
  .card {
    background: var(--panel); border: 1px solid var(--border);
    border-radius: 12px; padding: 1.25rem 1.4rem; margin-bottom: 1.1rem;
  }
  h2 { font-size: 1rem; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin: 0 0 .8rem; }
  .cmd-label { display: block; font-size: .75rem; color: var(--muted); margin-bottom: .2rem; }
  code {
    position: relative; display: block; background: var(--code); border: 1px solid var(--border);
    border-radius: 8px; padding: .6rem 2.4rem .6rem .8rem;
    font-family: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    font-size: .95rem; cursor: pointer; overflow-x: auto; transition: border-color .15s;
  }
  code:hover { border-color: var(--accent); }
  .copy-ic {
    position: absolute; top: 50%; right: .6rem; transform: translateY(-50%);
    display: inline-flex; color: var(--muted); transition: color .15s; pointer-events: none;
  }
  code:hover .copy-ic { color: var(--accent); }
  .copy-ic .ic-check { display: none; }
  code.copied { border-color: #3fb950; }
  code.copied .copy-ic { color: #3fb950; }
  code.copied .ic-copy { display: none; }
  code.copied .ic-check { display: inline; }
  code.failed { border-color: #f85149; }
  code.failed .copy-ic { color: #f85149; }
  ul { margin: .3rem 0 0; padding-left: 1.2rem; color: var(--fg); }
  li { margin: .25rem 0; }
  .muted { color: var(--muted); }
  .warn {
    border-left: 3px solid var(--accent); background: #1c1113;
    padding: .8rem 1rem; border-radius: 6px; margin: .4rem 0 0; color: var(--fg);
  }
  .repo { display: inline-block; margin-top: .5rem; color: var(--muted); text-decoration: none; font-size: .9rem; }
  .repo:hover { color: var(--accent); }
  footer { margin-top: 2.5rem; color: var(--muted); font-size: .85rem; text-align: center; }
  footer a { color: var(--accent); text-decoration: none; }
</style>
</head>
<body>
  <main class="wrap">
    <h1>nuke<span class="dot">.</span>it2<span class="dot">.</span>sh</h1>
    <p class="tagline">${escapeHtml(TAGLINE)}</p>

    <article class="card">
      <h2>Run it</h2>
      <span class="cmd-label">Windows — PowerShell (as Administrator) · interactive menu</span>
      <code data-copy="${escapeHtml(RUN_CMD)}">${escapeHtml(RUN_CMD)}<span class="copy-ic" aria-hidden="true"><svg class="ic-copy" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><svg class="ic-check" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg></span></code>
      <p class="muted" style="margin:.6rem 0 .3rem;font-size:.9rem">Or jump straight to a target — add it to the path:</p>
      <span class="cmd-label">Direct target (skips the menu)</span>
      <code data-copy="irm nuke.it2.sh/s1 | iex">irm nuke.it2.sh/s1 | iex<span class="copy-ic" aria-hidden="true"><svg class="ic-copy" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><svg class="ic-check" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg></span></code>
      <p class="muted" style="margin:.5rem 0 0;font-size:.88rem">
        <code style="display:inline;padding:.05rem .3rem">/mcafee</code>
        <code style="display:inline;padding:.05rem .3rem">/norton</code>
        <code style="display:inline;padding:.05rem .3rem">/avast</code>
        <code style="display:inline;padding:.05rem .3rem">/cs</code> (crowdstrike) ·
        <code style="display:inline;padding:.05rem .3rem">/s1</code> (sentinelone) ·
        <code style="display:inline;padding:.05rem .3rem">/all</code> (every consumer AV)
      </p>
      <p class="muted" style="margin:.6rem 0 0;font-size:.9rem">Not elevated? The tool offers to relaunch itself as Administrator — preserving the target.</p>
    </article>

    <article class="card">
      <h2>What it removes</h2>
      <p style="margin:0 0 .4rem">Pick a vendor from the menu:</p>
      <ul>
        <li><strong>McAfee</strong> — Total Protection, LiveSafe, Security Scan, WebAdvisor, enterprise agent.</li>
        <li><strong>Norton / Symantec</strong> — Norton 360 / Security, NortonLifeLock, Symantec Endpoint Protection.</li>
        <li><strong>Avast / AVG</strong> — Avast Antivirus / One and AVG (same engine).</li>
        <li><strong>CrowdStrike Falcon</strong> <span class="muted">(EDR)</span> — needs the maintenance token from your Falcon console.</li>
        <li><strong>SentinelOne</strong> <span class="muted">(EDR)</span> — needs the anti-tamper passphrase from your S1 console.</li>
      </ul>
      <p class="muted" style="margin:.8rem 0 0;font-size:.9rem">
        For consumer AV it runs the official uninstaller first, then force-removes
        processes, services, kernel drivers, scheduled tasks, AppX packages, folders,
        registry keys and autoruns — with an optional whole-drive leftover sweep.
        For tamper-protected EDRs it runs the supported token/passphrase uninstall and
        cleans up leftovers; it will <strong>not</strong> brute-force a still-protected
        agent (that risks an unbootable machine).
      </p>
      <p class="muted" style="margin:.6rem 0 0;font-size:.9rem">
        Where a vendor publishes a public cleaner (McAfee MCPR, avastclear) the tool
        offers to download and run it. Support-gated cleaners (Symantec CleanWipe,
        CrowdStrike / SentinelOne) you supply yourself.
      </p>
    </article>

    <article class="card">
      <div class="warn">
        <strong>Heads up.</strong> This is a deliberately aggressive, admin-only tool for
        cleaning up machines. It asks you to type <code style="display:inline;padding:.05rem .3rem">YES</code>
        before touching anything, writes a full transcript to <span class="muted">%TEMP%</span>,
        and may require a reboot to finish removing locked files. Read the
        <a class="repo" style="margin:0" href="${escapeHtml(REPO)}/blob/main/public/nuke.ps1" target="_blank" rel="noopener">script</a>
        before you run it.
      </div>
      <a class="repo" href="${escapeHtml(REPO)}" target="_blank" rel="noopener">source ↗</a>
    </article>

    <footer>
      Click the command to copy &middot; part of the
      <a href="https://it2.sh" target="_blank" rel="noopener">it2.sh</a> family
      <br><a href="${escapeHtml(REPO)}" target="_blank" rel="noopener">nuke.it2.sh source ↗</a>
    </footer>
  </main>
<script>
  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); return true; }
      catch (e) { /* fall through to legacy path */ }
    }
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      return ok;
    } catch (e) { return false; }
  }
  document.querySelectorAll("code[data-copy]").forEach((el) => {
    el.addEventListener("click", async () => {
      el.classList.remove("copied", "failed");
      const ok = await copyText(el.dataset.copy);
      el.classList.add(ok ? "copied" : "failed");
      setTimeout(() => el.classList.remove("copied", "failed"), 1400);
    });
  });
</script>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response("OK", { status: 200 });
    }

    // Ignore browser noise
    if (url.pathname === "/favicon.ico") {
      return new Response(null, { status: 204 });
    }

    // First path segment (if any) selects a direct target.
    const segment = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "").split("/")[0].toLowerCase();
    const target = segment ? TARGETS[segment] : null;

    // Browsers get the styled explainer page (path is ignored for HTML).
    if (wantsHtml(request)) {
      return new Response(renderHtml(), {
        status: 200,
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "public, max-age=300",
          "X-Source": "nuke.it2.sh",
        },
      });
    }

    // Unknown path segment → a helpful plain-text error for terminals.
    if (segment && !target) {
      const valid = Object.keys(TARGETS).join(", ");
      return new Response(
        `Unknown target: "${segment}".\nValid targets: ${valid}\nOr run the interactive menu: irm nuke.it2.sh | iex\n`,
        { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }

    // Terminals get the raw PowerShell TUI, served from the assets dir.
    const assetResponse = await env.ASSETS.fetch(
      new Request("https://assets.local/nuke.ps1")
    );
    if (!assetResponse.ok) {
      return new Response("Failed to load nuke.ps1", { status: 502 });
    }
    let body = await assetResponse.text();

    // Direct target: inject the canonical Key + a matching relaunch one-liner
    // (so self-elevation re-runs the same path) ahead of the script.
    if (target) {
      const header =
        `$script:NukeTarget = '${target}'\n` +
        `$script:LaunchCommand = 'irm nuke.it2.sh/${segment} | iex'\n`;
      body = header + body;
    }

    return new Response(body, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "public, max-age=3600",
        "X-Source": "nuke.it2.sh",
        "X-Script": "nuke.ps1",
        "X-Target": target || "(menu)",
      },
    });
  },
};

# Claude Codex Usage Tray

A lightweight Windows system tray widget that shows your **Claude Code** and **OpenAI Codex CLI** plan usage (session + weekly limits) in one combined icon, with a click-to-open popup showing progress bars and time-until-reset for each.

Pure PowerShell + WinForms. No install framework, no telemetry, no dependencies beyond what Windows already ships with (PowerShell 7 / `pwsh`).

## What it looks like

- **One tray icon**, split into two halves: left = Claude Code, right = Codex. Each half is colored green / orange / red based on how close you are to your weekly limit.
- **Click** the icon to open a small popup with progress bars for Session (5h) and Weekly (7 day) usage for both providers, plus a subtle "time until reset" next to each percentage.
- **Right-click** for a plain menu: Refresh / Quit.

## How it gets the data

**Claude Code** — reads `cachedUsageUtilization` from `~/.claude.json`. This is the same local cache Claude Code itself writes and keeps up to date while you use it. Purely local file read, no network call.

**Codex CLI** — this is the part you should know about before running this: Codex (when logged in via a ChatGPT plan, not an API key) does not expose usage/rate-limit data through any documented CLI command or local cache. This script reads the OAuth access token that `codex login` already stored in `~/.codex/auth.json`, and uses it to call:

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <your existing codex access token>
chatgpt-account-id: <your account id>
```

This is the **same endpoint and the same token the official `codex` CLI itself uses** to power its own status display — this script doesn't talk to anything Codex doesn't already talk to, and doesn't send your token anywhere except `chatgpt.com` (OpenAI's own domain). But it's worth being explicit: `chatgpt.com/backend-api/...` is OpenAI's internal web-app API, not a published/stable public API. It can change or break without notice. This approach is the same one used by other community tools such as [codexbar](https://github.com/mryll/codexbar) and [CodexBar](https://github.com/steipete/CodexBar) (macOS).

If your Codex token is expired, or you're not logged in, or the request fails, the Codex side just shows a neutral gray status with an explanation in the popup — it never crashes the Claude side.

**The script never writes to, modifies, or refreshes `~/.codex/auth.json`.** If your token expires, just use `codex` normally once (it refreshes its own token), and the tray will pick that up on the next refresh.

## Requirements

- Windows 10/11
- PowerShell 7 (`pwsh`) — falls back to `powershell.exe` if not found
- [Claude Code](https://claude.com/claude-code) and/or [Codex CLI](https://github.com/openai/codex) installed and logged in (either one alone is fine — the other side just shows "not available")

## Install

```powershell
git clone https://github.com/<your-username>/claude-codex-usage-tray.git
cd claude-codex-usage-tray
./install.ps1
```

This adds a Startup shortcut (so it launches automatically on login) and starts it immediately.

### Manual start (no autostart)

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\tray.ps1
```

### Uninstall

Right-click the tray icon → Quit, and delete the shortcut from:
`shell:startup` (Win+R → paste → Enter) → `Claude Codex Usage Tray.lnk`

## Notes / disclaimer

- Unofficial, community project. Not affiliated with or endorsed by Anthropic or OpenAI.
- The Codex integration relies on an undocumented endpoint (see above) and may stop working if OpenAI changes it.
- Refreshes every 5 minutes automatically, or on demand via the popup's "Refresh" button / right-click menu.
- MIT licensed — read the source, it's one file.

## License

MIT — see [LICENSE](LICENSE).

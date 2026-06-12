# Claude Usage Widget (no Python)

A tiny always-on-top desktop widget that shows your **Claude 5-hour rate-limit %**
(optionally the **7-day** limit too). Built for Windows 10/11 with **zero installs** —
it uses only what already ships with Windows:

- **.NET WinForms** — the floating window
- **curl.exe** — the HTTPS call (built into Win10/11 since 2018)

> Why curl and not PowerShell's `Invoke-RestMethod`? `claude.ai` is behind Cloudflare,
> which 403-challenges PowerShell's .NET TLS stack but lets `curl.exe` through. curl is
> the reliable path with no extra dependencies.

## Files

| File | What it does |
|------|--------------|
| `usage-widget.ps1` | The widget itself (UI + fetch). |
| `cuw.vbs` | Launches the widget **hidden** — no console window flash. |
| `cuw.bat` | Double-click / PATH entry point. Calls `cuw.vbs`. |

## Setup

1. **Credentials** — the widget reads the same `.env` as the rest of this set:
   put `SESSION_KEY`, `DEVICE_ID`, `ORG_ID` in `~/.claude/claude_usage.env`
   (copy from `claude_usage.env.example`). No keys = the widget shows `5h: -- (no .env)`.
2. **Run it** — double-click `cuw.bat` (or run `cuw.vbs`). The widget appears top-right.
3. **Optional — run at startup:** press <kbd>Win</kbd>+<kbd>R</kbd>, type `shell:startup`,
   and drop a shortcut to `cuw.bat` (or `cuw.vbs`) in that folder.

## Using it

- **Drag** with the left mouse button to reposition (remembered between launches).
- **Click** the widget to toggle the reset time between **remaining** `5h: 47% (1h58m)`
  and **exact clock** `5h: 47% @14:30`.
- **Right-click** for the menu:
  - **Refresh** — fetch now.
  - **Show 7d** — toggle the 7-day limit row on/off (see below).
  - **Lock position** — stop accidental dragging.
  - **Quit**.

The two lines show:
```
5h: 47% (1h58m)     ← limit % + when it resets (colored by load)
@ 14:02:13          ← when it was last checked
```

Position, the 7d toggle, and the time-format choice persist in `~/.claude/.usage_widget.cfg`.

## Failsafes (rate-limit & errors)

- **`(RL)` = rate-limited.** If the usage API returns **HTTP 403** (Cloudflare/rate-limit),
  the widget does **not** go blank — it keeps showing the **last good numbers** and appends
  `(RL)` to the clock line (`@ 14:02:13 (RL)`), then retries after 60s. This mirrors the
  original Python widget.
- **`401 refresh .env`** — your session expired; refresh the credentials in
  `~/.claude/claude_usage.env`.
- **`offline` / `http NNN`** — network or server issue; it keeps the last good value if it
  has one, otherwise shows the short error on the clock line.

## 5h vs 5h + 7d

The **7-day (weekly) limit row is off by default**, because some accounts don't return
weekly data (the field comes back null) — for those it would just show `7d: n/a`.

- Turn it on live with the **"Show 7d"** right-click item — no code edit.
- Or set `$ShowWeeklyDefault = $true` near the top of `usage-widget.ps1` to start with it on.
- If your account has no weekly limit, the row shows `7d: n/a` and the 5h row keeps working.

## "Running scripts is disabled on this system" — read this

Windows blocks `.ps1` files from running directly by default (ExecutionPolicy `Restricted`).
**You do not need to change any system setting** — the launchers handle it:

- `cuw.vbs` / `cuw.bat` call PowerShell with `-ExecutionPolicy Bypass`, which applies to that
  **one launch only**. It needs no admin rights and changes nothing permanently.

So always start the widget via **`cuw.bat` / `cuw.vbs`**, not by double-clicking the `.ps1`.

If you *want* to run `.ps1` files directly (optional, your choice):
```powershell
# per-user, no admin — allows local scripts + signed remote ones
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Colors

The 5h % is color-coded so you can read the load at a glance:

| Range | Color |
|-------|-------|
| < 50% | green |
| 50–70% | yellow |
| 70–90% | amber |
| ≥ 90% | red |

## Process name / closing it

The widget runs as **`powershell.exe`** (shown as "Windows PowerShell" in Task Manager) —
there is no separate `.exe`. Normally just **right-click → Quit**.

To find or force-kill *only this widget* (without touching your other PowerShell windows),
match on its command line:

```powershell
# find it
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' }

# stop it
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

**Single instance:** launching `cuw.bat` again while the widget is running does **nothing**
(a named mutex makes the second copy exit silently), so you won't accidentally stack two.

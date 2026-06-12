# Claude Usage Widget — no-Python desktop widget for Windows 10/11.
# Always-on-top, borderless, semi-transparent. Shows the 5-hour rate-limit %.
# Zero install: uses only things that ship with Windows 10/11 —
#   • .NET WinForms (the window/UI)
#   • curl.exe (the HTTPS call — built into Win10/11 since build 17063, 2018)
# curl.exe is used instead of Invoke-RestMethod on purpose: claude.ai sits behind
# Cloudflare, which 403-challenges PowerShell's .NET TLS stack but lets curl through.
#
# Reads credentials from a .env (SESSION_KEY / DEVICE_ID / ORG_ID), searched in:
#   1. $env:CLAUDE_LIMIT_ENV            (optional override)
#   2. ~/.claude/claude_usage.env       (standard location)
#   3. <this folder>/claude_usage.env   (self-contained fallback)
# No absolute paths are hardcoded.
#
# Launch via cuw.bat (which hides the console window). Right-click the widget
# for Refresh / Show 7d / Lock position / Quit. Drag with the left mouse button.
# Position + the 7d toggle are remembered in ~/.claude/.usage_widget.cfg.
#
# 5h vs 5h+7d: the 7-day (weekly) limit is OFF by default (some accounts don't
# return weekly data and would just show "7d: n/a"). Turn it on with the
# "Show 7d" right-click item (no code edit), or set $ShowWeeklyDefault = $true
# below. The choice persists between launches.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- single instance ----
# A named mutex (per-user) so launching cuw.bat twice doesn't stack a second
# widget. If one is already running, this copy exits quietly. Works the same on
# Win10 and Win11. The mutex is held for the life of the process.
$createdNew = $false
$script:singleMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageWidget', [ref]$createdNew)
if (-not $createdNew) { [Environment]::Exit(0) }   # another widget already owns it → exit silently

# ---- config ----
$UpdateIntervalSec = 30
$RetryLimitSec     = 60          # after a 403 (rate-limit), retry this soon (matches the Python widget)
$ShowWeeklyDefault = $false      # $true = start with 5h+7d; toggle live via right-click
$ClaudeDir  = Join-Path $HOME '.claude'
$CfgFile    = Join-Path $ClaudeDir '.usage_widget.cfg'   # remembers position + 7d toggle
$ApiTimeout = 15

# ---- persisted settings (position + showWeekly) ----
function Read-Cfg {
    $cfg = @{ x = $null; y = $null; showWeekly = $ShowWeeklyDefault; showExactTime = $false }
    if (Test-Path $CfgFile) {
        foreach ($line in Get-Content $CfgFile) {
            $t = $line.Trim(); if ($t -notmatch '=') { continue }
            $k, $v = $t -split '=', 2; $k = $k.Trim(); $v = $v.Trim()
            switch ($k) {
                'x' { $cfg.x = [int]$v }
                'y' { $cfg.y = [int]$v }
                'showWeekly' { $cfg.showWeekly = ($v -eq 'true') }
                'showExactTime' { $cfg.showExactTime = ($v -eq 'true') }
            }
        }
    }
    return $cfg
}
function Save-Cfg {
    try {
        @(
            "x=$($form.Location.X)"
            "y=$($form.Location.Y)"
            "showWeekly=$($script:showWeekly.ToString().ToLower())"
            "showExactTime=$($script:showExactTime.ToString().ToLower())"
        ) | Set-Content $CfgFile
    } catch {}
}
$cfg = Read-Cfg
$script:showWeekly = $cfg.showWeekly

# ---- locate .env (portable, no hardcoded path) ----
function Get-EnvPath {
    $candidates = @()
    if ($env:CLAUDE_LIMIT_ENV) { $candidates += $env:CLAUDE_LIMIT_ENV }
    $candidates += (Join-Path $ClaudeDir 'claude_usage.env')
    $candidates += (Join-Path $PSScriptRoot 'claude_usage.env')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Read-Creds {
    $path = Get-EnvPath
    if (-not $path) { return $null }
    $creds = @{}
    foreach ($line in Get-Content $path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or ($t -notmatch '=')) { continue }
        $k, $v = $t -split '=', 2
        $creds[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
    }
    return $creds
}

# ---- reset-time display: remaining ("1h58m") or exact local clock ("14:30") ----
# Toggled by clicking the widget (like the Python version). State persists.
$script:showExactTime = $cfg.showExactTime

function Format-Remaining($isoStr) {
    if (-not $isoStr) { return '' }
    try {
        $delta = [datetimeoffset]::Parse($isoStr) - [datetimeoffset]::UtcNow
        # Floor from total seconds (matches the Python widget). Do NOT use [int] on
        # TotalHours — [int] rounds (banker's rounding), which shows e.g. 2h1m for a
        # real 1h51m. [math]::Floor keeps it truncating like integer division.
        $total = [int][math]::Floor($delta.TotalSeconds)
        if ($total -le 0) { return 'now' }
        $h = [math]::Floor($total / 3600)
        $m = [math]::Floor(($total % 3600) / 60)
        if ($h -ge 1) { return "{0}h{1:D2}m" -f [int]$h, [int]$m }
        return "{0}m" -f [int]$m
    } catch { return '' }
}
function Format-ExactClock($isoStr) {
    if (-not $isoStr) { return '' }
    try { return ([datetimeoffset]::Parse($isoStr)).LocalDateTime.ToString('HH:mm') } catch { return '' }
}
# build the reset string per the current toggle: " (1h58m)"  or  " @14:30"
function Format-ResetDisplay($isoStr) {
    if (-not $isoStr) { return '' }
    if ($script:showExactTime) { return " @$(Format-ExactClock $isoStr)" }
    return " ($(Format-Remaining $isoStr))"
}

# ---- fetch 5h utilization from claude.ai (via curl.exe) ----
# The fetch runs OFF the UI thread so the widget never freezes, even on a slow network:
#   Start-UsageFetch  — launch curl windowless and return immediately (it runs as its own
#                       process, not on our thread). Returns a result only for instant cases.
#   Poll-UsageFetch   — non-blocking: if curl has finished, read+parse; else $null.
#   Parse-Usage       — pure: turn curl's stdout+status into the result hash.
# Same curl, same args, same 30s cadence, same 403/(RL) failsafe as before — just non-blocking.
$script:usageProc = $null   # in-flight curl process, or $null when idle

function Parse-Usage($out) {
    $lines = $out -split "`n"
    $status = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)] -join "`n")
    # 403 = rate-limited by Cloudflare; 401 = bad/expired session.
    if ($status -eq '403') { return @{ ok = $false; rateLimited = $true; msg = '403' } }
    if ($status -eq '401') { return @{ ok = $false; msg = '401 refresh .env' } }
    if ($status -ne '200') { return @{ ok = $false; msg = if ($status) { "http $status" } else { 'offline' } } }
    try { $resp = $body | ConvertFrom-Json } catch { return @{ ok = $false; msg = 'bad json' } }
    $five = $resp.five_hour
    if ($null -eq $five -or $null -eq $five.utilization) { return @{ ok = $false; msg = 'no data' } }
    # reset values stay RAW ISO so the time-format toggle re-renders without a refetch.
    $result = @{ ok = $true; pct = [double]$five.utilization; resetIso = $five.resets_at
                 hasWeekly = $false; wpct = $null; wresetIso = '' }
    $seven = $resp.seven_day
    if ($seven -and $null -ne $seven.utilization) {
        $result.hasWeekly = $true
        $result.wpct = [double]$seven.utilization
        $result.wresetIso = $seven.resets_at
    }
    return $result
}

function Start-UsageFetch {
    $creds = Read-Creds
    if (-not $creds -or -not $creds.SESSION_KEY -or -not $creds.ORG_ID) {
        return @{ ok = $false; msg = 'no .env' }   # nothing to fetch; immediate result
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }  # fall back to PATH
    $url = "https://claude.ai/api/organizations/$($creds.ORG_ID)/usage"
    $cookie = "sessionKey=$($creds.SESSION_KEY)"
    if ($creds.DEVICE_ID) { $cookie += "; anthropic-device-id=$($creds.DEVICE_ID)" }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $curl
        # -s silent, -m timeout, -w append HTTP status so we detect 403 without -f swallowing the body
        $psi.Arguments = "-s -m $ApiTimeout `"$url`" -H `"Cookie: $cookie`" -A `"claude-usage-widget/1.0`" -w `"\n%{http_code}`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $script:usageProc = [System.Diagnostics.Process]::Start($psi)
        return $null   # in flight; Poll-UsageFetch collects it
    } catch { return @{ ok = $false; msg = 'offline' } }
}

function Poll-UsageFetch {
    $p = $script:usageProc
    if (-not $p) { return $null }
    if (-not $p.HasExited) {
        if (((Get-Date) - $p.StartTime).TotalSeconds -gt ($ApiTimeout + 8)) {
            try { $p.Kill() } catch {}; $script:usageProc = $null
            return @{ ok = $false; msg = 'timeout' }
        }
        return $null   # still running — don't block
    }
    $out = $p.StandardOutput.ReadToEnd()
    $script:usageProc = $null
    try { return Parse-Usage $out } catch { return @{ ok = $false; msg = 'offline' } }
}

# ---- color by load ----
function Get-PctColor([double]$p) {
    if ($p -ge 90) { return [System.Drawing.Color]::FromArgb(255, 90, 90) }       # red
    elseif ($p -ge 70) { return [System.Drawing.Color]::FromArgb(255, 180, 70) }  # amber
    elseif ($p -ge 50) { return [System.Drawing.Color]::FromArgb(220, 230, 70) }  # yellow
    else { return [System.Drawing.Color]::FromArgb(0, 255, 136) }                 # green
}

# ---- build the window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Usage Widget'   # window title — lets you identify it even though the process is powershell.exe
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$form.Opacity = 0.85
$form.StartPosition = 'Manual'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None  # honor Width literally (Font mode inflates it ~1.4x)
$form.Width = 122        # literal px (AutoScaleMode None). Fits worst case "5h: 100% (1h58m)"
$HEIGHT_5H = 40
$HEIGHT_7D = 58           # taller when the 7d row is visible
$form.Height = if ($script:showWeekly) { $HEIGHT_7D } else { $HEIGHT_5H }
$form.Padding = New-Object System.Windows.Forms.Padding(2)

# restore saved position (or default top-right)
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 16), ($screen.Top + 16))
if ($null -ne $cfg.x -and $null -ne $cfg.y) {
    try { $form.Location = New-Object System.Drawing.Point([int]$cfg.x, [int]$cfg.y) } catch {}
}

$lblPct = New-Object System.Windows.Forms.Label
$lblPct.AutoSize = $false
$lblPct.Dock = 'Top'
$lblPct.Height = 20
$lblPct.TextAlign = 'MiddleLeft'
$lblPct.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblPct.ForeColor = [System.Drawing.Color]::FromArgb(0, 255, 136)
$lblPct.Text = '5h: --%'
$lblPct.Padding = New-Object System.Windows.Forms.Padding(6, 0, 4, 0)

# 7d (weekly) row — created always; visibility driven by $script:showWeekly
$lblWeekly = New-Object System.Windows.Forms.Label
$lblWeekly.AutoSize = $false
$lblWeekly.Dock = 'Top'
$lblWeekly.Height = 18
$lblWeekly.TextAlign = 'MiddleLeft'
$lblWeekly.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblWeekly.ForeColor = [System.Drawing.Color]::FromArgb(0, 204, 255)
$lblWeekly.Text = '7d: --%'
$lblWeekly.Visible = $script:showWeekly
$lblWeekly.Padding = New-Object System.Windows.Forms.Padding(6, 0, 4, 0)

$lblReset = New-Object System.Windows.Forms.Label
$lblReset.AutoSize = $false
$lblReset.Dock = 'Fill'
$lblReset.TextAlign = 'MiddleLeft'
$lblReset.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
$lblReset.ForeColor = [System.Drawing.Color]::FromArgb(136, 136, 136)
$lblReset.Text = 'starting...'
$lblReset.Padding = New-Object System.Windows.Forms.Padding(6, 0, 4, 0)

# add bottom-to-top so Dock stacking is: 5h (top) → 7d → reset (fill)
$form.Controls.Add($lblReset)
$form.Controls.Add($lblWeekly)
$form.Controls.Add($lblPct)

# ---- drag (borderless) ----
$script:dragging = $false
$script:dragMoved = $false        # true if the pointer actually moved during a press → suppress the click-toggle
$script:locked = $false
$script:offset = New-Object System.Drawing.Point(0, 0)
$onDown = {
    if ($_.Button -eq 'Left' -and -not $script:locked) {
        $script:dragging = $true
        $script:dragMoved = $false
        $script:offset = New-Object System.Drawing.Point($_.X, $_.Y)
    }
}
$onMove = {
    if ($script:dragging) {
        $script:dragMoved = $true
        $p = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(($p.X - $script:offset.X), ($p.Y - $script:offset.Y))
    }
}
$onUp = {
    if ($script:dragging) {
        $script:dragging = $false
        if ($script:dragMoved) { Save-Cfg }   # only persist if it was a real drag
    }
}
foreach ($c in @($form, $lblPct, $lblWeekly, $lblReset)) {
    $c.Add_MouseDown($onDown); $c.Add_MouseMove($onMove); $c.Add_MouseUp($onUp)
}

# ---- right-click menu ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh')
$miWeekly = $menu.Items.Add('Show 7d')
$miWeekly.CheckOnClick = $true
$miWeekly.Checked = $script:showWeekly
$miLock = $menu.Items.Add('Lock position')
$null = $menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$form.ContextMenuStrip = $menu
$lblPct.ContextMenuStrip = $menu
$lblWeekly.ContextMenuStrip = $menu
$lblReset.ContextMenuStrip = $menu

# ---- render + refresh ----
# $script:lastGood holds the most recent successful fetch so we can (a) re-render
# instantly when the time-format toggle flips, and (b) keep showing real numbers
# during a 403 rate-limit instead of going blank (the "(RL)" failsafe).
$script:lastGood = $null
$grey = [System.Drawing.Color]::FromArgb(136, 136, 136)
$red  = [System.Drawing.Color]::FromArgb(220, 120, 120)

# Render the two/three labels from a cached good result. $clockSuffix lets the
# 403 path append " (RL)" to the @clock line.
function Render-Usage($u, $clockTime, $clockSuffix) {
    $lblPct.Text = ('5h: {0:N0}%{1}' -f $u.pct, (Format-ResetDisplay $u.resetIso))
    $lblPct.ForeColor = Get-PctColor $u.pct
    $lblReset.Text = "@ $clockTime$clockSuffix"
    $lblReset.ForeColor = $grey
    if ($script:showWeekly) {
        if ($u.hasWeekly) {
            $lblWeekly.Text = ('7d: {0:N0}%{1}' -f $u.wpct, (Format-ResetDisplay $u.wresetIso))
            $lblWeekly.ForeColor = [System.Drawing.Color]::FromArgb(0, 204, 255)
        } else {
            $lblWeekly.Text = '7d: n/a'
            $lblWeekly.ForeColor = $grey
        }
    }
}

# Re-render the cached value without refetching (used by the time-format toggle).
$renderCached = {
    if ($script:lastGood) { Render-Usage $script:lastGood (Get-Date -Format 'HH:mm:ss') '' }
}

# Apply a finished fetch result: render + the 403/(RL) failsafe. (Unchanged logic; just split
# out so both the poll and the no-.env immediate case can call it.)
$applyUsage = {
    param($u)
    $now = Get-Date -Format 'HH:mm:ss'
    if ($u.ok) {
        $script:lastGood = $u
        Render-Usage $u $now ''
    }
    elseif ($u.rateLimited -and $script:lastGood) {
        # FAILSAFE: 403 rate-limited → keep the last good numbers, mark "(RL)",
        # and retry sooner (after $RetryLimitSec) instead of waiting a full cycle.
        Render-Usage $script:lastGood $now ' (RL)'
        $script:retryTimer.Stop(); $script:retryTimer.Start()
    }
    else {
        # No cached data to fall back on → show the error briefly on the clock line.
        $lblPct.Text = '5h: --%'; $lblPct.ForeColor = $grey
        $lblReset.Text = $u.msg; $lblReset.ForeColor = $red
        if ($script:showWeekly) { $lblWeekly.Text = '7d: --%'; $lblWeekly.ForeColor = $grey }
        if ($u.rateLimited) { $script:retryTimer.Stop(); $script:retryTimer.Start() }
    }
}

# 30s tick: START a fetch (non-blocking — curl runs off-thread). The 1s poll applies it.
$doRefresh = {
    if (-not $script:usageProc) {
        $immediate = Start-UsageFetch        # returns a result only for instant cases (no .env)
        if ($null -ne $immediate) { & $applyUsage $immediate }
    }
}

# 1s tick: collect a finished fetch (cheap HasExited check — never blocks) and render it.
$doPoll = {
    $u = Poll-UsageFetch
    if ($null -ne $u) { & $applyUsage $u }
}

# apply the 7d toggle: show/hide the row, resize the window, persist, re-render
$applyWeekly = {
    $lblWeekly.Visible = $script:showWeekly
    $form.Height = if ($script:showWeekly) { $HEIGHT_7D } else { $HEIGHT_5H }
    $miWeekly.Checked = $script:showWeekly
    Save-Cfg
    if ($script:lastGood) { & $renderCached } else { & $doRefresh }
}

# ---- click to toggle reset display: remaining-time  <->  exact clock ----
$onClick = {
    if ($_.Button -eq 'Left' -and -not $script:dragMoved) {
        $script:showExactTime = -not $script:showExactTime
        Save-Cfg
        & $renderCached
    }
}
foreach ($c in @($form, $lblPct, $lblWeekly, $lblReset)) { $c.Add_Click($onClick) }

$miRefresh.Add_Click($doRefresh)
$miWeekly.Add_Click({
    $script:showWeekly = $miWeekly.Checked
    & $applyWeekly
})
$miLock.Add_Click({
    $script:locked = -not $script:locked
    $miLock.Text = if ($script:locked) { 'Unlock position' } else { 'Lock position' }
})
$miQuit.Add_Click({ $form.Close() })

# ---- timers ----
# 30s tick: start a (non-blocking) fetch.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $UpdateIntervalSec * 1000
$timer.Add_Tick($doRefresh)

# 1s tick: collect a finished fetch and render it (cheap HasExited check — never blocks).
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 1000
$pollTimer.Add_Tick($doPoll)

# one-shot retry timer for the 403 (RL) failsafe — fires once, sooner than a full cycle
$script:retryTimer = New-Object System.Windows.Forms.Timer
$script:retryTimer.Interval = $RetryLimitSec * 1000
$script:retryTimer.Add_Tick({ $script:retryTimer.Stop(); & $doRefresh })

$form.Add_Shown({ & $doRefresh; $timer.Start(); $pollTimer.Start() })
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    $pollTimer.Stop(); $pollTimer.Dispose()
    if ($script:retryTimer) { $script:retryTimer.Stop(); $script:retryTimer.Dispose() }
    try { if ($script:usageProc -and -not $script:usageProc.HasExited) { $script:usageProc.Kill() } } catch {}
    try { $script:singleMutex.ReleaseMutex(); $script:singleMutex.Dispose() } catch {}
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[void]$form.ShowDialog()

# Claude Combined Widget — 5h rate-limit + per-session context, in one window.
# Always-on-top, borderless, semi-transparent. Combines the two proven engines:
#   • 5h section  — the exact off-thread curl fetch from usage-widget.ps1 (cuw). Same .env,
#     same 403/(RL) failsafe, same 30s cadence. Runs OFF the UI thread, so it never freezes.
#   • context section — the exact tail-read engine from context-widget.ps1 (ctw). Reads the
#     `usage` block Claude Code writes into each session's .jsonl. NEVER runs `claude`, never
#     forks, never spawns — so it can't touch the 5h pool and can't freeze. Titles load lazily
#     in a background runspace (ids show instantly, real titles fill in ~200ms).
#
# This is a convenience combo; the two standalone widgets (cuw.bat, ctw.bat) do the same jobs
# separately. Run ONE of the three — each has its own mutex, so they won't stack, but they'd
# overlap on screen. Launch via ccw.bat (hides the console).
#
# Controls: drag (left mouse) to move (persists). Left-click toggles the 5h reset display
# (remaining <-> exact clock). Right-click: Refresh / Show 7d / Lock / Legend / Quit.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- single instance (own mutex, separate from cuw and ctw) ----
$createdNew = $false
$script:singleMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeCombinedWidget', [ref]$createdNew)
if (-not $createdNew) { [Environment]::Exit(0) }

# ---- config ----
$UpdateIntervalSec  = 30      # 5h fetch cadence + context tail re-read
$RetryLimitSec      = 60      # after a 403 (RL), retry this soon
$ApiTimeout         = 15      # curl timeout (s)
$ShowWeeklyDefault  = $false
$ActiveSessionCount = 6       # how many recent sessions to show
$ActiveWindowMin    = 600     # only sessions touched within this many minutes
$TailBytes          = 65536   # how much of each transcript's end to read for the usage block
$ContextWindow      = 1000000 # 1M token window (for the context %)
$GateSoft = 30; $GateMid = 50; $GateHard = 60   # context color gates

$ClaudeDir    = Join-Path $HOME '.claude'
$ProjectsRoot = Join-Path $ClaudeDir 'projects'
$CfgFile      = Join-Path $ClaudeDir '.combined_widget.cfg'

# ---- persisted settings (position + 7d toggle + time-format toggle) ----
function Read-Cfg {
    $cfg = @{ x = $null; y = $null; showWeekly = $ShowWeeklyDefault; showExactTime = $false }
    if (Test-Path $CfgFile) {
        foreach ($line in Get-Content $CfgFile) {
            $t = $line.Trim(); if ($t -notmatch '=') { continue }
            $k, $v = $t -split '=', 2; $k = $k.Trim(); $v = $v.Trim()
            switch ($k) {
                'x' { try { $cfg.x = [int]$v } catch {} }
                'y' { try { $cfg.y = [int]$v } catch {} }
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
        ) | Set-Content $CfgFile -Encoding UTF8
    } catch {}
}
$cfg = Read-Cfg
$script:showWeekly    = $cfg.showWeekly
$script:showExactTime = $cfg.showExactTime

# ==========================================================================
#  5h ENGINE  (verbatim from cuw / usage-widget.ps1 — off-thread fetch)
# ==========================================================================
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

function Format-Remaining($isoStr) {
    if (-not $isoStr) { return '' }
    try {
        $delta = [datetimeoffset]::Parse($isoStr) - [datetimeoffset]::UtcNow
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
function Format-ResetDisplay($isoStr) {
    if (-not $isoStr) { return '' }
    if ($script:showExactTime) { return " @$(Format-ExactClock $isoStr)" }
    return " ($(Format-Remaining $isoStr))"
}

# Off-thread curl fetch (start / poll / parse) — identical pattern to cuw.
$script:usageProc = $null

function Parse-Usage($out) {
    $lines = $out -split "`n"
    $status = $lines[-1].Trim()
    $body = ($lines[0..($lines.Count - 2)] -join "`n")
    if ($status -eq '403') { return @{ ok = $false; rateLimited = $true; msg = '403' } }
    if ($status -eq '401') { return @{ ok = $false; msg = '401 refresh .env' } }
    if ($status -ne '200') { return @{ ok = $false; msg = if ($status) { "http $status" } else { 'offline' } } }
    try { $resp = $body | ConvertFrom-Json } catch { return @{ ok = $false; msg = 'bad json' } }
    $five = $resp.five_hour
    if ($null -eq $five -or $null -eq $five.utilization) { return @{ ok = $false; msg = 'no data' } }
    $result = @{ ok = $true; pct = [double]$five.utilization; resetIso = $five.resets_at
                 hasWeekly = $false; wpct = $null; wresetIso = '' }
    $seven = $resp.seven_day
    if ($seven -and $null -ne $seven.utilization) {
        $result.hasWeekly = $true; $result.wpct = [double]$seven.utilization; $result.wresetIso = $seven.resets_at
    }
    return $result
}
function Start-UsageFetch {
    $creds = Read-Creds
    if (-not $creds -or -not $creds.SESSION_KEY -or -not $creds.ORG_ID) {
        return @{ ok = $false; msg = 'no .env' }
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $url = "https://claude.ai/api/organizations/$($creds.ORG_ID)/usage"
    $cookie = "sessionKey=$($creds.SESSION_KEY)"
    if ($creds.DEVICE_ID) { $cookie += "; anthropic-device-id=$($creds.DEVICE_ID)" }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $curl
        $psi.Arguments = "-s -m $ApiTimeout `"$url`" -H `"Cookie: $cookie`" -A `"claude-combined-widget/1.0`" -w `"\n%{http_code}`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $script:usageProc = [System.Diagnostics.Process]::Start($psi)
        return $null
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
        return $null
    }
    $out = $p.StandardOutput.ReadToEnd()
    $script:usageProc = $null
    try { return Parse-Usage $out } catch { return @{ ok = $false; msg = 'offline' } }
}

function Get-PctColor([double]$p) {
    if ($p -ge 90) { return [System.Drawing.Color]::FromArgb(255, 90, 90) }
    elseif ($p -ge 70) { return [System.Drawing.Color]::FromArgb(255, 180, 70) }
    elseif ($p -ge 50) { return [System.Drawing.Color]::FromArgb(220, 230, 70) }
    else { return [System.Drawing.Color]::FromArgb(0, 255, 136) }
}

# ==========================================================================
#  CONTEXT ENGINE  (verbatim from ctw / context-widget.ps1 — tail-read only)
# ==========================================================================
function Get-ProjectLabel($encoded) {
    $s = $encoded -replace '^[a-zA-Z]--', ''
    $s = $s -replace '-', ' '
    if ([string]::IsNullOrWhiteSpace($s)) { return $encoded }
    return $s
}
function Get-ActiveSessionFiles {
    $cut = (Get-Date).AddMinutes(-$ActiveWindowMin)
    $files = @()
    if (Test-Path $ProjectsRoot) {
        foreach ($d in (Get-ChildItem $ProjectsRoot -Directory -ErrorAction SilentlyContinue)) {
            $label = Get-ProjectLabel $d.Name
            Get-ChildItem $d.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $cut } |
                ForEach-Object {
                    $_ | Add-Member -NotePropertyName Proj -NotePropertyValue $label -Force
                    $files += $_
                }
        }
    }
    $files | Sort-Object LastWriteTime -Descending | Select-Object -First $ActiveSessionCount
}
# FAST tail-read: seek the last $TailBytes, take the newest usage block. No claude, no fork.
function Get-TailContext($file) {
    try {
        $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $start = [Math]::Max(0, $fs.Length - $TailBytes)
            $fs.Seek($start, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd()
        } finally { $fs.Close() }
    } catch { return $null }
    $best = $null
    foreach ($l in ($text -split "`n")) {
        if ($l.IndexOf('cache_read_input_tokens') -lt 0) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        $u = if ($o.message -and $o.message.usage) { $o.message.usage } else { $o.usage }
        if ($u -and ($u.cache_read_input_tokens -or $u.cache_creation_input_tokens)) { $best = $u }
    }
    if (-not $best) { return $null }
    $tok = [double]$best.input_tokens + [double]$best.cache_creation_input_tokens + [double]$best.cache_read_input_tokens
    if ($tok -le 0) { return $null }
    return @{ tokens = [int]$tok; pct = [int][math]::Round(($tok / $ContextWindow) * 100) }
}

# Lazy title map (id -> real /resume picker title), loaded in a BACKGROUND runspace.
$script:titleMap = @{}
$script:titleRunspace = $null
$script:titlePowerShell = $null
$script:titleHandle = $null

function Start-TitleLoad {
    if ($script:titlePowerShell) { return }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($ProjectsRoot, $cut)
        $map = @{}
        if (Test-Path $ProjectsRoot) {
            foreach ($d in (Get-ChildItem $ProjectsRoot -Directory -ErrorAction SilentlyContinue)) {
                Get-ChildItem $d.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $cut } |
                    ForEach-Object {
                        Select-String -Path $_.FullName -Pattern '"type":"ai-title"' -ErrorAction SilentlyContinue |
                            ForEach-Object {
                                try {
                                    $o = $_.Line | ConvertFrom-Json
                                    if ($o.type -eq 'ai-title' -and $o.sessionId -and $o.aiTitle) { $map[$o.sessionId] = $o.aiTitle }
                                } catch {}
                            }
                    }
            }
        }
        return $map
    }).AddArgument($ProjectsRoot).AddArgument((Get-Date).AddMinutes(-$ActiveWindowMin))
    $script:titleRunspace = $rs
    $script:titlePowerShell = $ps
    $script:titleHandle = $ps.BeginInvoke()
}
function Poll-TitleLoad {
    if (-not $script:titleHandle) { return $false }
    if (-not $script:titleHandle.IsCompleted) { return $false }
    # EndInvoke returns a PSDataCollection wrapper, NOT the hashtable — unwrap the first element.
    try { $out = $script:titlePowerShell.EndInvoke($script:titleHandle) } catch { $out = $null }
    $map = $null
    if ($out) { foreach ($item in $out) { if ($item -is [hashtable]) { $map = $item; break } } }
    if ($map -and $map.Count) {
        $h = @{}; foreach ($k in $map.Keys) { $h[$k] = $map[$k] }
        $script:titleMap = $h
    }
    try { $script:titlePowerShell.Dispose() } catch {}
    try { $script:titleRunspace.Dispose() } catch {}
    $script:titlePowerShell = $null; $script:titleRunspace = $null; $script:titleHandle = $null
    return $true
}
function Get-RowTitle($id) {
    if ($script:titleMap.ContainsKey($id)) { return $script:titleMap[$id] }
    return $id.Substring(0, 8)
}
function Get-ContextRows {
    $files = Get-ActiveSessionFiles
    if (-not $files) { return @() }
    $rows = @()
    foreach ($f in $files) {
        $id = $f.BaseName
        $c = Get-TailContext $f
        $rows += @{
            id = $id; proj = $f.Proj
            title = (Get-RowTitle $id)
            tokens = if ($c) { $c.tokens } else { 0 }
            pct = if ($c) { $c.pct } else { 0 }
            hasReal = [bool]$c
            touchedSec = [int]((Get-Date) - $f.LastWriteTime).TotalSeconds
        }
    }
    return $rows
}
function Format-Tokens([int]$t) {
    if ($t -ge 1000) { return ('{0:N0}k' -f ($t / 1000)) }
    return "$t"
}
function Format-TouchedAgo([int]$sec) {
    if ($sec -lt 60) { return "${sec}s" }
    $m = [int][math]::Floor($sec / 60)
    if ($m -lt 60) { return "${m}m" }
    $h = [int][math]::Floor($m / 60); $mm = $m % 60
    return "${h}h${mm}m"
}
function Get-CtxColor([int]$p) {
    if ($p -ge $GateHard) { return [System.Drawing.Color]::FromArgb(255, 90, 90) }
    elseif ($p -ge $GateMid) { return [System.Drawing.Color]::FromArgb(255, 180, 70) }
    elseif ($p -ge $GateSoft) { return [System.Drawing.Color]::FromArgb(220, 230, 70) }
    else { return [System.Drawing.Color]::FromArgb(0, 255, 136) }
}

# ==========================================================================
#  WINDOW  (owner-drawn panel: 5h line(s) on top, context rows below)
# ==========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Combined Widget'
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$form.Opacity = 0.88
$form.StartPosition = 'Manual'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.Width = 365
$form.Padding = New-Object System.Windows.Forms.Padding(2)

$H_5H = 22; $H_7D = 20; $H_HDR = 18; $H_ROW = 16
function Compute-Height {
    $h = $H_5H
    if ($script:showWeekly) { $h += $H_7D }
    $h += $H_HDR
    $n = if ($script:ctxRows) { $script:ctxRows.Count } else { 1 }
    if ($n -lt 1) { $n = 1 }
    $h += $H_ROW * $n
    return $h + 8
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 16), ($screen.Top + 16))
if ($null -ne $cfg.x -and $null -ne $cfg.y) {
    try { $form.Location = New-Object System.Drawing.Point([int]$cfg.x, [int]$cfg.y) } catch {}
}

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Fill'
$panel.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$form.Controls.Add($panel)

$script:usage   = $null
$script:rlSuffix = ''
$script:ctxRows = @()
$script:locked  = $false

$fontBold  = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$fontRow   = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font('Consolas', 8, [System.Drawing.FontStyle]::Regular)
$fontPct   = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
$colDim    = [System.Drawing.Color]::FromArgb(110, 110, 110)
$colBlue   = [System.Drawing.Color]::FromArgb(0, 204, 255)

function Relayout {
    $form.Height = Compute-Height
    $panel.Invalidate()
}

$panel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $x = 6; $y = 4
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $fmt = [System.Drawing.StringFormat]::GenericTypographic

    # --- 5h line ---
    $u = $script:usage
    if ($u -and $u.ok) {
        $brush.Color = Get-PctColor $u.pct
        $txt = ('5h {0:0}%{1}{2}' -f $u.pct, (Format-ResetDisplay $u.resetIso), $script:rlSuffix)
        $g.DrawString($txt, $fontBold, $brush, $x, $y); $y += $H_5H
        if ($script:showWeekly) {
            if ($u.hasWeekly) {
                $brush.Color = $colBlue
                $txt = ('7d {0:0}%{1}' -f $u.wpct, (Format-ResetDisplay $u.wresetIso))
            } else { $brush.Color = $colDim; $txt = '7d n/a' }
            $g.DrawString($txt, $fontBold, $brush, $x, $y); $y += $H_7D
        }
    } else {
        $brush.Color = $colDim
        $txt = if ($u) { "5h --%  $($u.msg)" } else { '5h  starting...' }
        $g.DrawString($txt, $fontBold, $brush, $x, $y); $y += $H_5H
        if ($script:showWeekly) { $y += $H_7D }
    }

    # --- context header ---
    $brush.Color = $colDim
    $g.DrawString("context  (all projects)", $fontSmall, $brush, $x, $y); $y += $H_HDR

    # --- context rows ---
    if ($script:ctxRows.Count -eq 0) {
        $brush.Color = $colDim
        $g.DrawString('(no active sessions)', $fontRow, $brush, $x, $y)
    } else {
        foreach ($r in $script:ctxRows) {
            $dot  = if ($r.touchedSec -lt 60) { [char]0x25CF } else { [char]0x25CB }
            $proj = "$($r.proj):"
            $mark = if ($r.touchedSec -lt 60) { '*' } else { '~' }
            $title = $r.title
            if ($title.Length -gt 24) { $title = $title.Substring(0, 23) + [char]0x2026 }
            if (-not $r.hasReal) {
                $brush.Color = $colDim
                $line = ('{0} {1,-7} {2,5}  {3,-24} {4}' -f $dot, $proj, 'reading', $title, (Format-TouchedAgo $r.touchedSec))
                $g.DrawString($line, $fontRow, $brush, $x, $y)
            } else {
                $brush.Color = Get-CtxColor $r.pct
                # Layout: dot  proj:  [PCT%]  title…  tokens  mark age — % in the bigger font,
                # drawn in segments (MeasureString advances x) so columns stay aligned.
                $seg1 = ('{0} {1,-7} ' -f $dot, $proj)
                $pctS = ('{0,3}' -f $r.pct)
                $seg2 = ('%  {0,-24} {1,5} {2} {3}' -f $title, (Format-Tokens $r.tokens), $mark, (Format-TouchedAgo $r.touchedSec))
                $cx = $x
                $g.DrawString($seg1, $fontRow, $brush, $cx, $y, $fmt)
                $cx += $g.MeasureString($seg1, $fontRow, [int]0, $fmt).Width
                $g.DrawString($pctS, $fontPct, $brush, $cx, ($y - 3), $fmt)
                $cx += $g.MeasureString($pctS, $fontPct, [int]0, $fmt).Width
                $g.DrawString($seg2, $fontRow, $brush, $cx, $y, $fmt)
            }
            $y += $H_ROW
        }
    }
    $brush.Dispose()
})

# ---- drag + left-click (toggle 5h reset display) ----
$script:dragging = $false; $script:dragMoved = $false; $script:offset = $null
$onDown = {
    if ($_.Button -eq 'Left' -and -not $script:locked) {
        $script:dragging = $true; $script:dragMoved = $false
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
    if ($script:dragging) { $script:dragging = $false; if ($script:dragMoved) { Save-Cfg } }
}
$onClick = {
    if ($_.Button -eq 'Left' -and -not $script:dragMoved) {
        $script:showExactTime = -not $script:showExactTime; Save-Cfg; Relayout
    }
}
foreach ($c in @($form, $panel)) {
    $c.Add_MouseDown($onDown); $c.Add_MouseMove($onMove); $c.Add_MouseUp($onUp); $c.Add_Click($onClick)
}

# ---- right-click menu ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$null = $menu.Items.Add('-')
$miWeekly = $menu.Items.Add('Show 7d'); $miWeekly.CheckOnClick = $true; $miWeekly.Checked = $script:showWeekly
$miLock = $menu.Items.Add('Lock position')
$miLegend = $menu.Items.Add('Legend / Help')
$null = $menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$form.ContextMenuStrip = $menu
$panel.ContextMenuStrip = $menu

# ==========================================================================
#  REFRESH LOGIC
# ==========================================================================
# Apply a finished 5h fetch result (render state + 403/(RL) failsafe).
$applyUsage = {
    param($u)
    if ($null -eq $u) { return }
    if ($u.ok) { $script:usage = $u; $script:rlSuffix = '' }
    elseif ($u.rateLimited -and $script:usage) {
        $script:rlSuffix = ' (RL)'; $script:retryTimer.Stop(); $script:retryTimer.Start()
    } else { $script:usage = $u }
    Relayout
}

# 30s tick: start a (non-blocking) 5h fetch + tail-read context (free, instant).
$doRefresh = {
    if (-not $script:usageProc) {
        $immediate = Start-UsageFetch
        if ($null -ne $immediate) { & $applyUsage $immediate }
    }
    try { $script:ctxRows = @(Get-ContextRows) } catch {}
    Relayout
}

# 1s tick: collect a finished 5h fetch + the background title scan; repaint as each lands.
$doPoll = {
    $u = Poll-UsageFetch
    if ($null -ne $u) { & $applyUsage $u }
    if (Poll-TitleLoad) { try { $script:ctxRows = @(Get-ContextRows) } catch {}; Relayout }
}

$miRefresh.Add_Click($doRefresh)
$miWeekly.Add_Click({ $script:showWeekly = $miWeekly.Checked; Save-Cfg; Relayout })
$miLock.Add_Click({
    $script:locked = -not $script:locked
    $miLock.Text = if ($script:locked) { 'Unlock position' } else { 'Lock position' }
})
$miLegend.Add_Click({
    $nl = [Environment]::NewLine
    $msg = @(
        "TOP LINE  -  5h account rate-limit (the shared usage pool).",
        "  Left-click toggles 'resets in 1h52m' <-> '@ 14:30'.",
        "  Right-click 'Show 7d' adds the weekly limit line.",
        "",
        "CONTEXT ROWS  -  how full each recent session's 1M window is.",
        ([char]0x25CF + "  filled dot   = touched in the last 60s (active now)"),
        ([char]0x25CB + "  empty dot    = idle, but still recently touched"),
        "12k 4%       = real tokens used / percent of the 1M window",
        "*  star         = active session (live number)",
        "~  tilde        = idle session (last live-turn number)",
        "reading         = no usage block in the tail yet (brand-new session)",
        "2s 4m 21h    = how long since that session was last written",
        "",
        "COLOR (both lines): green low -> yellow -> amber -> red high.",
        ("Context gates: green <" + $GateSoft + "%  yellow <" + $GateMid + "%  amber <" + $GateHard + "%  red " + ([char]0x2265) + $GateHard + "%"),
        "",
        "Context numbers come straight from each session transcript JSON (the",
        "usage block Claude Code writes every turn). NOTHING is spawned for",
        "context: no claude run, no fork. The 5h fetch runs off-thread, so the",
        "widget never freezes. Titles load in the background; ids show first.",
        "Caveat: right after /compact a session tail shows the PRE-compact peak."
    ) -join $nl
    [System.Windows.Forms.MessageBox]::Show($msg, 'Claude Combined Widget - Legend',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
$miQuit.Add_Click({ $form.Close() })

# ==========================================================================
#  TIMERS
# ==========================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $UpdateIntervalSec * 1000
$timer.Add_Tick($doRefresh)

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 1000
$pollTimer.Add_Tick($doPoll)

$script:retryTimer = New-Object System.Windows.Forms.Timer
$script:retryTimer.Interval = $RetryLimitSec * 1000
$script:retryTimer.Add_Tick({ $script:retryTimer.Stop(); if (-not $script:usageProc) { Start-UsageFetch | Out-Null } })

$form.Add_Shown({
    & $doRefresh        # start first 5h fetch + tail-read context (instant)
    Start-TitleLoad     # background title scan (off-thread, no freeze)
    $timer.Start(); $pollTimer.Start()
})
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    $pollTimer.Stop(); $pollTimer.Dispose()
    if ($script:retryTimer) { $script:retryTimer.Stop(); $script:retryTimer.Dispose() }
    try { if ($script:usageProc -and -not $script:usageProc.HasExited) { $script:usageProc.Kill() } } catch {}
    try { if ($script:titlePowerShell) { $script:titlePowerShell.Dispose() } } catch {}
    try { if ($script:titleRunspace) { $script:titleRunspace.Dispose() } } catch {}
    try { $script:singleMutex.ReleaseMutex(); $script:singleMutex.Dispose() } catch {}
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[void]$form.ShowDialog()

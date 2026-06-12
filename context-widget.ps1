# Claude Context Widget — per-session context-window usage, from the transcript JSON only.
# Always-on-top, borderless, semi-transparent. Shows how full each recent session's 1M
# context window is. This widget does ONE thing: read the real token usage that Claude Code
# already writes into each session's .jsonl. It NEVER runs `claude`, never forks, never spawns
# anything — so it can't affect your 5h pool and can't freeze.
#
#   • Number source: each session's transcript records a `usage` block on every assistant
#     turn (input + cache_creation + cache_read = the real context that turn carried). We read
#     only the last ~64KB of the file (a byte seek, not a full read) and take the newest block.
#     Verified fast: ~70ms/session even on multi-MB transcripts.
#   • Titles: the real /resume picker title (the `ai-title` record) is loaded LAZILY in a
#     background runspace — the window paints instantly with short ids, then titles fill in.
#     No blocking scan of megabytes on the UI thread.
#
# Run the 5h-only usage-widget.ps1 (cuw.bat) separately for the rate-limit pool — that one is
# untouched. This widget has its OWN mutex, so the two coexist (they'll overlap on screen).
#
# Launch via ctw.bat (hides the console). Drag with left mouse to move (position persists).
# Right-click: Refresh now / Lock position / Legend / Quit.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- single instance (own mutex, separate from the 5h and combined widgets) ----
$createdNew = $false
$script:singleMutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeContextWidget', [ref]$createdNew)
if (-not $createdNew) { [Environment]::Exit(0) }

# ---- config ----
$ActiveSessionCount = 6       # how many recent sessions to show
$ActiveWindowMin    = 600     # only sessions touched within this many minutes
$UpdateIntervalSec  = 30      # how often to re-read the tails (free, instant)
$TailBytes          = 65536   # how much of each file's end to read for the usage block
$ContextWindow      = 1000000 # 1M token window (for the %)
$GateSoft = 30; $GateMid = 50; $GateHard = 60   # color gates (compaction thresholds)

$ClaudeDir    = Join-Path $HOME '.claude'
$ProjectsRoot = Join-Path $ClaudeDir 'projects'
$CfgFile      = Join-Path $ClaudeDir '.context_widget.cfg'

# ---- persisted position ----
function Read-Cfg {
    $cfg = @{ x = $null; y = $null }
    if (Test-Path $CfgFile) {
        foreach ($line in Get-Content $CfgFile) {
            $t = $line.Trim(); if ($t -notmatch '=') { continue }
            $k, $v = $t -split '=', 2; $k = $k.Trim(); $v = $v.Trim()
            switch ($k) { 'x' { try { $cfg.x = [int]$v } catch {} } 'y' { try { $cfg.y = [int]$v } catch {} } }
        }
    }
    return $cfg
}
function Save-Cfg {
    try { "x=$($form.Location.X)`r`ny=$($form.Location.Y)" | Set-Content $CfgFile -Encoding UTF8 } catch {}
}
$cfg = Read-Cfg

# ---- pretty project name from the encoded folder (d--Dev -> Dev) ----
function Get-ProjectLabel($encoded) {
    $s = $encoded -replace '^[a-zA-Z]--', ''   # strip drive prefix (d--)
    $s = $s -replace '-', ' '
    if ([string]::IsNullOrWhiteSpace($s)) { return $encoded }
    return $s
}

# ---- the N newest session files across all projects, tagged with their project ----
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

# ---- FAST tail-read: seek the last $TailBytes, take the newest usage block. No full read,
#      no claude, no fork. Returns @{tokens;pct} or $null. (Verified ~70ms on a 4.6MB file.)
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

# ---- lazy title map (id -> real /resume picker title), loaded in a BACKGROUND runspace ----
# The ai-title records can be anywhere in a project folder, and scanning every .jsonl is the
# slow part — so it runs off the UI thread. The window shows short ids until the map lands.
$script:titleMap = @{}                 # id -> title, filled by the background job
$script:titleRunspace = $null
$script:titlePowerShell = $null
$script:titleHandle = $null

function Start-TitleLoad {
    if ($script:titlePowerShell) { return }   # one at a time
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

# Non-blocking: if the background title scan finished, collect its map and clean up.
function Poll-TitleLoad {
    if (-not $script:titleHandle) { return $false }
    if (-not $script:titleHandle.IsCompleted) { return $false }
    # EndInvoke returns a PSDataCollection wrapper, NOT the hashtable directly — the actual
    # map is the first (and only) element. Unwrap it before reading its keys.
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

# Title for a row: real ai-title if the background map has it, else the short id.
function Get-RowTitle($id) {
    if ($script:titleMap.ContainsKey($id)) { return $script:titleMap[$id] }
    return $id.Substring(0, 8)
}

# ---- build the display rows (pure tail-read, instant) ----
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

# ---- formatting + color ----
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
#  WINDOW
# ==========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Context Widget'
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 26)
$form.Opacity = 0.88
$form.StartPosition = 'Manual'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.Width = 365
$form.Padding = New-Object System.Windows.Forms.Padding(2)

$H_HDR = 18; $H_ROW = 16
function Compute-Height {
    $n = if ($script:ctxRows) { $script:ctxRows.Count } else { 1 }
    if ($n -lt 1) { $n = 1 }
    return ($H_HDR + $H_ROW * $n) + 8
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

$script:ctxRows = @()
$script:clock   = ''
$script:locked  = $false

$fontRow   = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Regular)
$fontSmall = New-Object System.Drawing.Font('Consolas', 8, [System.Drawing.FontStyle]::Regular)
$fontPct   = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
$colDim    = [System.Drawing.Color]::FromArgb(110, 110, 110)

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

    # header
    $brush.Color = $colDim
    $g.DrawString("context  (all projects)", $fontSmall, $brush, $x, $y); $y += $H_HDR

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
                # dot  proj:   reading   title…   age
                $line = ('{0} {1,-7} {2,5}  {3,-24} {4}' -f $dot, $proj, 'reading', $title, (Format-TouchedAgo $r.touchedSec))
                $g.DrawString($line, $fontRow, $brush, $x, $y)
            } else {
                $brush.Color = Get-CtxColor $r.pct
                # Layout: dot  proj:  [PCT%]  title…   tokens  mark age
                # Percent sits right after the project, in the bigger font. Drawn in segments
                # (MeasureString advances x) so columns stay aligned despite the larger glyph.
                $seg1 = ('{0} {1,-7} ' -f $dot, $proj)                       # dot + project (padded)
                $pctS = ('{0,3}' -f $r.pct)                                  # the bigger number
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

# ---- drag to move ----
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
foreach ($c in @($form, $panel)) { $c.Add_MouseDown($onDown); $c.Add_MouseMove($onMove); $c.Add_MouseUp($onUp) }

# ---- right-click menu ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$null = $menu.Items.Add('-')
$miLock = $menu.Items.Add('Lock position')
$miLegend = $menu.Items.Add('Legend / Help')
$null = $menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$form.ContextMenuStrip = $menu
$panel.ContextMenuStrip = $menu

# ---- refresh: re-read the tails (instant) + rebuild rows. No spawn, never blocks. ----
$doRefresh = {
    $script:clock = Get-Date -Format 'HH:mm:ss'
    try { $script:ctxRows = @(Get-ContextRows) } catch {}
    Relayout
}

$miRefresh.Add_Click($doRefresh)
$miLock.Add_Click({
    $script:locked = -not $script:locked
    $miLock.Text = if ($script:locked) { 'Unlock position' } else { 'Lock position' }
})
$miLegend.Add_Click({
    $nl = [Environment]::NewLine
    $msg = @(
        "Each row = how full a recent session's 1M context window is.",
        "",
        ([char]0x25CF + "  filled dot   = touched in the last 60s (active now)"),
        ([char]0x25CB + "  empty dot    = idle, but still recently touched"),
        "12k 4%       = real tokens used / percent of the 1M window",
        "*  star         = active session (live number)",
        "~  tilde        = idle session (last live-turn number)",
        "reading         = no usage block in the tail yet (brand-new session)",
        "2s 4m 21h    = how long since that session was last written",
        "",
        "COLOR (context gates):",
        ("  green <" + $GateSoft + "%  yellow <" + $GateMid + "%  amber <" + $GateHard + "%  red " + ([char]0x2265) + $GateHard + "%"),
        "",
        "Numbers come straight from each session transcript JSON (the",
        "usage block Claude Code writes every turn). NOTHING is spawned:",
        "no claude run, no fork, so this cannot touch your 5h pool or freeze.",
        "Titles load in the background; ids show until they land.",
        "Caveat: right after /compact a session tail shows the PRE-compact",
        "peak until a few new turns land."
    ) -join $nl
    [System.Windows.Forms.MessageBox]::Show($msg, 'Claude Context Widget - Legend',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
$miQuit.Add_Click({ $form.Close() })

# ==========================================================================
#  TIMERS
# ==========================================================================
# 30s tick: re-read the tails (instant, no spawn).
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $UpdateIntervalSec * 1000
$timer.Add_Tick($doRefresh)

# 1s tick: collect the background title scan when it finishes, then repaint with real titles.
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 1000
$pollTimer.Add_Tick({ if (Poll-TitleLoad) { try { $script:ctxRows = @(Get-ContextRows) } catch {}; Relayout } })

$form.Add_Shown({
    & $doRefresh        # instant: paint rows with short ids
    Start-TitleLoad     # kick off the background title scan (off-thread, no freeze)
    $timer.Start(); $pollTimer.Start()
})
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    $pollTimer.Stop(); $pollTimer.Dispose()
    try { if ($script:titlePowerShell) { $script:titlePowerShell.Dispose() } } catch {}
    try { if ($script:titleRunspace) { $script:titleRunspace.Dispose() } } catch {}
    try { $script:singleMutex.ReleaseMutex(); $script:singleMutex.Dispose() } catch {}
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[void]$form.ShowDialog()

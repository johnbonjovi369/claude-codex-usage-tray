Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeIcon {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

$claudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"
$codexAuthPath  = Join-Path $env:USERPROFILE ".codex\auth.json"

$script:lastIconHandle = [IntPtr]::Zero
$script:claudeUsage = [PSCustomObject]@{ Status = "loading" }
$script:codexUsage  = [PSCustomObject]@{ Status = "loading" }
$script:currentPopup = $null

# ---------- data sources ----------

function Get-ClaudeUsage {
    if (-not (Test-Path $claudeJsonPath)) { return [PSCustomObject]@{ Status = "no-data" } }
    try {
        $json = Get-Content $claudeJsonPath -Raw | ConvertFrom-Json
        $u = $json.cachedUsageUtilization
        if (-not $u) { return [PSCustomObject]@{ Status = "no-data" } }
        [PSCustomObject]@{
            Status       = "ok"
            FetchedAtMs  = $u.fetchedAtMs
            SessionPct   = $u.utilization.five_hour.utilization
            SessionReset = $u.utilization.five_hour.resets_at
            WeeklyPct    = $u.utilization.seven_day.utilization
            WeeklyReset  = $u.utilization.seven_day.resets_at
        }
    } catch {
        return [PSCustomObject]@{ Status = "error"; Message = $_.Exception.Message }
    }
}

function Get-JwtExpiry([string]$jwt) {
    try {
        $parts = $jwt.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $bytes = [Convert]::FromBase64String($payload)
        $obj = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if ($obj.exp) { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$obj.exp) }
    } catch {}
    return $null
}

function Get-CodexUsage {
    if (-not (Test-Path $codexAuthPath)) { return [PSCustomObject]@{ Status = "no-auth" } }
    try {
        $auth = Get-Content $codexAuthPath -Raw | ConvertFrom-Json
        $accessToken = $auth.tokens.access_token
        $accountId   = $auth.tokens.account_id
        if (-not $accessToken) { return [PSCustomObject]@{ Status = "no-auth" } }

        $expiry = Get-JwtExpiry $accessToken
        if ($expiry -and $expiry -lt (Get-Date)) {
            return [PSCustomObject]@{ Status = "expired" }
        }

        $headers = @{ Authorization = "Bearer $accessToken" }
        if ($accountId) { $headers["chatgpt-account-id"] = $accountId }

        $response = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" -Headers $headers -Method Get -TimeoutSec 10

        [PSCustomObject]@{
            Status       = "ok"
            SessionPct   = [math]::Floor([double]$response.rate_limit.primary_window.used_percent)
            SessionReset = $response.rate_limit.primary_window.reset_at
            WeeklyPct    = [math]::Floor([double]$response.rate_limit.secondary_window.used_percent)
            WeeklyReset  = $response.rate_limit.secondary_window.reset_at
            FetchedAt    = Get-Date
        }
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        if ($statusCode -eq 401) { return [PSCustomObject]@{ Status = "expired" } }
        return [PSCustomObject]@{ Status = "error"; Message = $_.Exception.Message }
    }
}

function Get-PctColor([int]$pct) {
    if ($pct -ge 80) { [System.Drawing.Color]::FromArgb(220, 53, 69) }
    elseif ($pct -ge 50) { [System.Drawing.Color]::FromArgb(255, 153, 0) }
    else { [System.Drawing.Color]::FromArgb(40, 167, 69) }
}

$grayColor = [System.Drawing.Color]::FromArgb(120, 120, 120)

function Get-StatusColor($usage) {
    if ($usage.Status -eq "ok") { return Get-PctColor ([int][math]::Round($usage.WeeklyPct)) }
    return $grayColor
}

# ---------- combined tray icon (split circle: left = Claude, right = Codex) ----------

function New-SplitIcon([System.Drawing.Color]$leftColor, [System.Drawing.Color]$rightColor) {
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $half = [int]($size / 2)
    $leftBrush = New-Object System.Drawing.SolidBrush($leftColor)
    $g.SetClip((New-Object System.Drawing.Rectangle(0, 0, $half, $size)))
    $g.FillEllipse($leftBrush, 0, 0, $size, $size)
    $g.ResetClip()
    $leftBrush.Dispose()

    $rightWidth = $size - $half
    $rightBrush = New-Object System.Drawing.SolidBrush($rightColor)
    $g.SetClip((New-Object System.Drawing.Rectangle($half, 0, $rightWidth, $size)))
    $g.FillEllipse($rightBrush, 0, 0, $size, $size)
    $g.ResetClip()
    $rightBrush.Dispose()

    $lineBottom = $size - 3
    $pen = New-Object System.Drawing.Pen(([System.Drawing.Color]::FromArgb(200, 255, 255, 255)), 1)
    $g.DrawLine($pen, $half, 3, $half, $lineBottom)
    $pen.Dispose()
    $g.Dispose()

    $hicon = $bmp.GetHicon()
    $bmp.Dispose()
    @{ Icon = [System.Drawing.Icon]::FromHandle($hicon); Handle = $hicon }
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Aktualisieren")
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Beenden")
$contextMenu.Items.AddRange(@($refreshItem, (New-Object System.Windows.Forms.ToolStripSeparator), $exitItem))
$notifyIcon.ContextMenuStrip = $contextMenu

function Update-Icon {
    $result = New-SplitIcon (Get-StatusColor $script:claudeUsage) (Get-StatusColor $script:codexUsage)
    $oldHandle = $script:lastIconHandle
    $notifyIcon.Icon = $result.Icon
    $script:lastIconHandle = $result.Handle
    if ($oldHandle -ne [IntPtr]::Zero) { [NativeIcon]::DestroyIcon($oldHandle) | Out-Null }

    $claudeText = if ($script:claudeUsage.Status -eq "ok") { "$([int][math]::Round($script:claudeUsage.WeeklyPct))%" } else { "--" }
    $codexText  = if ($script:codexUsage.Status -eq "ok") { "$([int][math]::Round($script:codexUsage.WeeklyPct))%" } else { "--" }
    $notifyIcon.Text = "Claude $claudeText . Codex $codexText (Woche)"
}

function Update-All {
    $script:claudeUsage = Get-ClaudeUsage
    $script:codexUsage = Get-CodexUsage
    Update-Icon
}

# ---------- popup with bars ----------

function Add-HeaderRow($panel, [int]$y, [string]$text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point(16, $y)
    $lbl.AutoSize = $true
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $panel.Controls.Add($lbl)
    return $y + 26
}

function Add-TextRow($panel, [int]$y, [string]$text, [System.Drawing.Color]$color) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point(16, $y)
    $lbl.AutoSize = $true
    $lbl.ForeColor = $color
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $panel.Controls.Add($lbl)
    return $y + 24
}

function Get-CountdownText([DateTimeOffset]$resetTime) {
    $span = $resetTime - [DateTimeOffset]::Now
    if ($span.TotalSeconds -le 0) { return "faellig" }
    $totalMinutes = [int][math]::Ceiling($span.TotalMinutes)
    $h = [int]($totalMinutes / 60)
    $m = $totalMinutes % 60
    if ($h -gt 0) { return "noch ${h}h ${m}m" }
    else { return "noch ${m}m" }
}

function Add-BarRow($panel, [int]$y, [string]$labelText, [int]$pct, [System.Drawing.Color]$color, [string]$countdownText) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$labelText - $pct%"
    $lbl.Location = New-Object System.Drawing.Point(16, $y)
    $lbl.AutoSize = $true
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $panel.Controls.Add($lbl)

    if ($countdownText) {
        $cdLbl = New-Object System.Windows.Forms.Label
        $cdLbl.Text = $countdownText
        $cdLbl.AutoSize = $true
        $cdLbl.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
        $cdLbl.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        $cdX = 16 + $lbl.Width + 8
        $cdY = $y + 3
        $cdLbl.Location = New-Object System.Drawing.Point($cdX, $cdY)
        $panel.Controls.Add($cdLbl)
    }

    $trackWidth = 228
    $track = New-Object System.Windows.Forms.Panel
    $trackY = $y + 20
    $track.Location = New-Object System.Drawing.Point(16, $trackY)
    $track.Size = New-Object System.Drawing.Size($trackWidth, 8)
    $track.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 74)
    $panel.Controls.Add($track)

    $clamped = [Math]::Min([Math]::Max($pct, 0), 100)
    $fillWidth = [Math]::Max(2, [int]($trackWidth * $clamped / 100))
    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point(0, 0)
    $fill.Size = New-Object System.Drawing.Size($fillWidth, 8)
    $fill.BackColor = $color
    $track.Controls.Add($fill)

    return $trackY + 8 + 10
}

function New-UsagePopup {
    $popup = New-Object System.Windows.Forms.Form
    $popup.FormBorderStyle = 'None'
    $popup.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 34)
    $popup.StartPosition = 'Manual'
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.Width = 260

    $y = 14
    $y = Add-HeaderRow $popup $y "Claude Code"
    $cu = $script:claudeUsage
    if ($cu.Status -eq "ok") {
        $sessionCountdown = if ($cu.SessionReset) { Get-CountdownText ([DateTimeOffset]$cu.SessionReset) } else { "" }
        $weeklyCountdown  = if ($cu.WeeklyReset)  { Get-CountdownText ([DateTimeOffset]$cu.WeeklyReset) } else { "" }
        $sp = [int][math]::Round($cu.SessionPct); $wp = [int][math]::Round($cu.WeeklyPct)
        $y = Add-BarRow $popup $y "Session (5h)" $sp (Get-PctColor $sp) $sessionCountdown
        $y = Add-BarRow $popup $y "Woche (7 Tage)" $wp (Get-PctColor $wp) $weeklyCountdown
    } else {
        $y = Add-TextRow $popup $y "Keine Daten gefunden" ([System.Drawing.Color]::LightGray)
    }

    $y += 6
    $sep = New-Object System.Windows.Forms.Panel
    $sep.Location = New-Object System.Drawing.Point(16, $y)
    $sep.Size = New-Object System.Drawing.Size(228, 1)
    $sep.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 74)
    $popup.Controls.Add($sep)
    $y += 14

    $y = Add-HeaderRow $popup $y "Codex"
    $xu = $script:codexUsage
    switch ($xu.Status) {
        "ok" {
            $sessionCountdown = if ($xu.SessionReset) { Get-CountdownText ([DateTimeOffset]::FromUnixTimeSeconds([int64]$xu.SessionReset)) } else { "" }
            $weeklyCountdown  = if ($xu.WeeklyReset)  { Get-CountdownText ([DateTimeOffset]::FromUnixTimeSeconds([int64]$xu.WeeklyReset)) } else { "" }
            $sp = [int][math]::Round($xu.SessionPct); $wp = [int][math]::Round($xu.WeeklyPct)
            $y = Add-BarRow $popup $y "Session (5h)" $sp (Get-PctColor $sp) $sessionCountdown
            $y = Add-BarRow $popup $y "Woche (7 Tage)" $wp (Get-PctColor $wp) $weeklyCountdown
        }
        "no-auth" { $y = Add-TextRow $popup $y "Nicht angemeldet" ([System.Drawing.Color]::LightGray) }
        "expired" { $y = Add-TextRow $popup $y "Token abgelaufen - einmal 'codex' starten" ([System.Drawing.Color]::Orange) }
        "error"   { $y = Add-TextRow $popup $y "Fehler: $($xu.Message)" ([System.Drawing.Color]::OrangeRed) }
        default   { $y = Add-TextRow $popup $y "Lade..." ([System.Drawing.Color]::LightGray) }
    }

    $y += 8
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Aktualisieren"
    $btnRefresh.Location = New-Object System.Drawing.Point(16, $y)
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 26)
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 94)
    $btnRefresh.ForeColor = [System.Drawing.Color]::White
    $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 54)
    $btnRefresh.Add_Click({ Update-All; Show-Popup }.GetNewClosure())
    $popup.Controls.Add($btnRefresh)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Schliessen"
    $btnClose.Location = New-Object System.Drawing.Point(134, $y)
    $btnClose.Size = New-Object System.Drawing.Size(110, 26)
    $btnClose.FlatStyle = 'Flat'
    $btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 94)
    $btnClose.ForeColor = [System.Drawing.Color]::White
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 54)
    $btnClose.Add_Click({ $popup.Close() }.GetNewClosure())
    $popup.Controls.Add($btnClose)

    $y += 40
    $popup.Height = $y

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $popupX = $workArea.Right - $popup.Width - 10
    $popupY = $workArea.Bottom - $popup.Height - 10
    $popup.Location = New-Object System.Drawing.Point($popupX, $popupY)
    $popup.Add_Deactivate({ $popup.Close() }.GetNewClosure())

    return $popup
}

function Show-Popup {
    if ($script:currentPopup -and -not $script:currentPopup.IsDisposed) {
        $script:currentPopup.Close()
    }
    $script:currentPopup = New-UsagePopup
    $script:currentPopup.Show()
    $script:currentPopup.Activate()
}

# ---------- wiring ----------

function Stop-TrayApp {
    $timer.Stop()
    $notifyIcon.Visible = $false
    if ($script:lastIconHandle -ne [IntPtr]::Zero) { [NativeIcon]::DestroyIcon($script:lastIconHandle) | Out-Null }
    [System.Windows.Forms.Application]::Exit()
}

$notifyIcon.Add_MouseClick({
    param($src, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-Popup
    }
})

$refreshItem.Add_Click({ Update-All })
$exitItem.Add_Click({ Stop-TrayApp })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5 * 60 * 1000
$timer.Add_Tick({ Update-All })
$timer.Start()

Update-All

[System.Windows.Forms.Application]::Run()

$repoDir = $PSScriptRoot

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) { $pwshCmd = Get-Command powershell -ErrorAction SilentlyContinue }
if (-not $pwshCmd) { throw "Weder 'pwsh' noch 'powershell.exe' gefunden." }

$trayScript = Join-Path $repoDir "tray.ps1"
$argString = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "Claude Codex Usage Tray.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $pwshCmd.Source
$shortcut.Arguments = $argString
$shortcut.WorkingDirectory = $repoDir
$shortcut.Description = "Claude Code / Codex usage tray"
$shortcut.Save()

Write-Host "Autostart eingerichtet: $shortcutPath"

Start-Process -FilePath $pwshCmd.Source -ArgumentList @(
    "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $trayScript
) -WindowStyle Hidden

Write-Host "Tray gestartet. Schau unten rechts in der Taskleiste."

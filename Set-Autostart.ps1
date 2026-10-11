param([switch]$Disable)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'autostart.psm1') -Force
$shortcutPath = Get-PetStartupShortcut
$runtime = Join-Path $PSScriptRoot 'runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$stopPath = Join-Path $runtime 'autostart-stop'
if ($Disable) {
 if (Test-PetAutostart $PSScriptRoot) { Remove-Item -LiteralPath $shortcutPath -Force }
 [IO.File]::WriteAllText($stopPath, 'stop')
 Write-Output 'Codex pet automatic startup disabled. The running pet is left open.'
 return
}
if ((Test-Path -LiteralPath $shortcutPath) -and -not (Test-PetAutostart $PSScriptRoot)) {
 throw 'Another folder owns automatic startup. Disable it from that folder before enabling here.'
}
if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -Force }
$shell = New-Object -ComObject WScript.Shell
try {
 $shortcut = $shell.CreateShortcut($shortcutPath)
 try {
  $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
  $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'Watch-Codex.ps1') + '"'
  $shortcut.WorkingDirectory = $PSScriptRoot
  $shortcut.WindowStyle = 7
  $shortcut.Description = 'Start the desktop pet when the Codex desktop app starts.'
  $shortcut.Save()
 } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
} finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'Watch-Codex.ps1') + '"'
Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden | Out-Null
Write-Output 'Codex pet automatic startup enabled for the current Windows user.'

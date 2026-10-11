function Get-PetStartupShortcut {
 return Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex White Dragon Pet.lnk'
}

function Test-CodexDesktopPath([string]$Path) {
 # The Store package currently names its desktop executable ChatGPT.exe.
 return $Path -match '(?i)\\(?:OpenAI\.Codex_[^\\]+\\app|Programs\\Codex|Codex\\app)\\(?:ChatGPT|Codex)\.exe$'
}

function Test-CodexDesktopRunning {
 $session = (Get-Process -Id $PID).SessionId
 foreach ($process in @(Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue)) {
  try {
   if ($process.SessionId -eq $session -and (Test-CodexDesktopPath $process.Path)) { return $true }
  } catch { }
 }
 return $false
}

function Test-PetAutostart([string]$Root) {
 $path = Get-PetStartupShortcut
 if (-not (Test-Path -LiteralPath $path)) { return $false }
 $shell = New-Object -ComObject WScript.Shell
 try {
  $shortcut = $shell.CreateShortcut($path)
  try { return $shortcut.WorkingDirectory -eq $Root }
  finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
 } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
}

function Invoke-CodexWatch {
 param([string]$Root, [scriptblock]$IsRunning = { Test-CodexDesktopRunning },
  [scriptblock]$Launch = {
   param($Folder)
   $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Folder 'pet.ps1') + '"'
   Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden | Out-Null
  }, [scriptblock]$Pause = { Start-Sleep -Seconds 2 },
  [scriptblock]$ShouldStop = { param($Folder) (Test-Path -LiteralPath (Join-Path $Folder 'runtime/autostart-stop')) -or -not (Test-Path -LiteralPath (Join-Path $Folder 'pet.ps1')) })
 $wasRunning = $false
 $retryAt = [DateTimeOffset]::MinValue
 while (-not (& $ShouldStop $Root)) {
  $running = & $IsRunning
  if ($running -and -not $wasRunning -and [DateTimeOffset]::UtcNow -ge $retryAt) {
   try { & $Launch $Root; $wasRunning = $true }
   catch { $retryAt = [DateTimeOffset]::UtcNow.AddSeconds(60) }
  } elseif (-not $running) {
   $wasRunning = $false
   $retryAt = [DateTimeOffset]::MinValue
  }
  & $Pause
 }
}

Export-ModuleMember -Function Get-PetStartupShortcut,Test-CodexDesktopPath,Test-CodexDesktopRunning,Test-PetAutostart,Invoke-CodexWatch

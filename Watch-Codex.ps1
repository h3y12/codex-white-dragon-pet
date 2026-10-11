$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'autostart.psm1') -Force
$mutex = New-Object Threading.Mutex($false, 'Local\CodexWhiteDragonPetWatcher')
$owned = $false
try {
 try { $owned = $mutex.WaitOne(0) }
 catch [Threading.AbandonedMutexException] { $owned = $true }
 if ($owned) { Invoke-CodexWatch -Root $PSScriptRoot }
} finally {
 if ($owned) { $mutex.ReleaseMutex() }
 $mutex.Dispose()
}

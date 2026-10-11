$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'autostart.psm1') -Force
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert (Test-CodexDesktopPath 'C:\Program Files\WindowsApps\OpenAI.Codex_26.1007_x64__abc\app\ChatGPT.exe') 'Store desktop was not detected'
Assert (Test-CodexDesktopPath 'C:\Users\demo\AppData\Local\Programs\Codex\Codex.exe') 'Desktop installation was not detected'
Assert (-not (Test-CodexDesktopPath 'C:\Users\demo\AppData\Local\OpenAI\Codex\bin\version\codex.exe')) 'CLI must not trigger startup'
Assert (-not (Test-CodexDesktopPath 'C:\Program Files\WindowsApps\OpenAI.ChatGPT_1_x64__abc\app\ChatGPT.exe')) 'Other ChatGPT package must not trigger startup'

$script:states = @($false,$true,$true,$true,$false,$true,$true)
$script:index = 0; $script:launches = 0
Invoke-CodexWatch -Root $PSScriptRoot -IsRunning { $script:states[$script:index] } `
 -Launch { param($Folder) $script:launches++ } -Pause { $script:index++ } `
 -ShouldStop { param($Folder) $script:index -ge $script:states.Count }
Assert ($script:launches -eq 2) 'One launch per Codex run, including after manually closing the pet'

$script:index = 0; $script:launches = 0
Invoke-CodexWatch -Root $PSScriptRoot -IsRunning { $true } `
 -Launch { param($Folder) $script:launches++ } -Pause { $script:index++ } `
 -ShouldStop { param($Folder) $script:index -ge 3 }
Assert ($script:launches -eq 1) 'An already-running Codex must launch the pet once'

$script:index = 0; $script:launches = 0
Invoke-CodexWatch -Root $PSScriptRoot -IsRunning { $true } `
 -Launch { param($Folder) $script:launches++; throw 'launch failed' } -Pause { $script:index++ } `
 -ShouldStop { param($Folder) $script:index -ge 3 }
Assert ($script:launches -eq 1) 'Launch failures must not retry every two seconds'
'Autostart tests: 7 assertions passed. No startup entries or processes were created.'

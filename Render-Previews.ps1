$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$demoFolder = Join-Path $root 'runtime/preview-demo'
[IO.Directory]::CreateDirectory($demoFolder) | Out-Null
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$demo = '{"taskTitle":"\u68c0\u67e5\u5df2\u8bfb\u72b6\u6001\u4e0e\u52a8\u753b\u5faa\u73af","activeCount":1,"notificationCount":1,"notificationReadErrors":0,"localCoverage":12,"readErrors":0,"todayTokens":128640,"cachedTokens":96000,"outputTokens":8200,"accountConnected":true,"resetCreditCount":2}' | ConvertFrom-Json
$demo | Add-Member NoteProperty updatedAt $now
$demo | Add-Member NoteProperty rateUpdatedAt $now
$demo | Add-Member NoteProperty date ([DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd'))
$demo | Add-Member NoteProperty rateLimits @{ primary=@{usedPercent=25;resetsAt=$now+7200}; secondary=@{usedPercent=10;resetsAt=$now+259200} }
$demo | Add-Member NoteProperty status 'idle'
foreach ($entry in @(@('idle','preview-idle.png'),@('working','preview-busy.png'),@('notification','preview-notification.png'))) {
 $demo.status = $entry[0]
 $fixture = Join-Path $demoFolder ($entry[0] + '.json')
 [IO.File]::WriteAllText($fixture, ($demo | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
 & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'pet.ps1') -PreviewOnly -StatePath $fixture -RenderPath (Join-Path $root $entry[1]) -PreviewPetScale 0.6 -PreviewFontSize 12 -PreviewPanelOpacity 95 -PreviewPlanExpiry '2026-11-15'
 if ($LASTEXITCODE -ne 0) { throw ('Preview render failed: ' + $entry[0]) }
}
'Rendered three preview images using synthetic data; no account connection was started.'

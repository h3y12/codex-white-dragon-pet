$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$output = Join-Path $root 'runtime/audit'
[IO.Directory]::CreateDirectory($output) | Out-Null
$fixture = Join-Path $output 'state.json'
function Assert-UI($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Fixture([string]$Status) {
 $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $data = @{ status=$Status; taskTitle='Review startup, account connection, and completion notifications';
  activeCount=2; notificationCount=1; notificationReadErrors=0; localCoverage=2; readErrors=0;
  todayTokens=12345; cachedTokens=1000; outputTokens=200; updatedAt=$now; rateUpdatedAt=$now;
  date='2026-10-11'; accountConnected=$true; resetCreditCount=2;
  rateLimits=@{ primary=@{usedPercent=25;resetsAt=$now+3600}; secondary=@{usedPercent=10;resetsAt=$now+86400} } }
 [IO.File]::WriteAllText($fixture, ($data | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
}
Write-Fixture 'idle'
$source = [IO.File]::ReadAllText((Join-Path $root 'pet.ps1'))
$marker = 'Update-State' + "`n" + 'if ($RenderPath)'
$normalized = $source.Replace("`r`n", "`n")
$offset = $normalized.LastIndexOf($marker)
Assert-UI ($offset -ge 0) 'Could not locate the UI entry point'
$setup = $normalized.Substring(0, $offset).Replace('$PSScriptRoot', ("'" + $root.Replace("'", "''") + "'"))
. ([scriptblock]::Create($setup)) -PreviewOnly -StatePath $fixture
Initialize-PetTray
$script:phase = 0
$script:uiFailure = $null
$probe = New-Object Windows.Threading.DispatcherTimer
$probe.Interval = [TimeSpan]::FromMilliseconds(350)
$probe.Add_Tick({
 try {
  if ($script:phase -eq 0) {
   Assert-UI $window.IsVisible 'Window did not open'
   Hide-PetWindow
   Assert-UI (-not $window.IsVisible) 'Window did not hide'
  } elseif ($script:phase -eq 1) {
   Assert-UI (-not $window.IsVisible) 'Hidden window did not survive the dispatcher loop'
   Assert-UI $script:tray.Visible 'Tray disappeared while hidden'
   Show-PetWindow
   Assert-UI $window.IsVisible 'Tray restore failed'
  } elseif ($script:phase -le 5) {
   $status = @('idle','working','notification','needs_input')[$script:phase-2]
   Write-Fixture $status
   Set-PetFont $(if ($script:phase -eq 5) { 18 } else { 12 })
   $script:lastRaw = ''; Update-State; $window.UpdateLayout()
   Assert-UI ($parts.Heading.Text -eq $labels.$status) 'UI state update failed'
   Assert-UI ($parts.Dragon.Source.PixelWidth -gt 0) 'Pose asset is blank'
   Assert-UI ($parts.Card.ActualHeight -gt 0) 'Card failed to render'
   Assert-UI ($parts.TaskTitle.ActualWidth -le $parts.Card.ActualWidth) 'Title exceeds card width'
   Assert-UI ($parts.Quota.Text -eq '75%') 'Quota display is incorrect'
   if ($status -in @('notification','needs_input')) {
    Assert-UI ($parts.NotificationFrame.Visibility -eq 'Visible') 'Notification border is missing'
   }
   $image = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling($window.ActualWidth),[int][Math]::Ceiling($window.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32)
   $image.Render($parts.Root)
   $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
   $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
   $stream = [IO.File]::Create((Join-Path $output ($status + '.png')))
   try { $encoder.Save($stream) } finally { $stream.Dispose() }
  } elseif ($script:phase -eq 6) {
   Write-Fixture 'idle'
   $data = [IO.File]::ReadAllText($fixture) | ConvertFrom-Json
   $data.rateLimits.primary.usedPercent = $null
   [IO.File]::WriteAllText($fixture, ($data | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
   $script:lastRaw = ''; Update-State
   Assert-UI ($parts.Quota.Text -eq '--') 'Unknown quota must not display 100 percent'
   Assert-UI ($parts.Heading.Text -ne $labels.reading) 'Unknown quota broke the UI'
  } else { $probe.Stop(); $window.Close(); return }
  $script:phase++
 } catch { $script:uiFailure = $_; $probe.Stop(); $window.Close() }
})
$window.Show(); $probe.Start()
[Windows.Threading.Dispatcher]::Run()
if ($script:uiFailure) { throw $script:uiFailure }
Assert-UI (-not $script:tray) 'Tray resources were not disposed'
'UI tests passed: hide, restore, tray cleanup, four states, assets, unknown quota and font-size layout.'

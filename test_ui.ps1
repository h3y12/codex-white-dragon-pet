$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$output = Join-Path $root 'runtime/audit'
[IO.Directory]::CreateDirectory($output) | Out-Null
$fixture = Join-Path $output 'state.json'
function Assert-UI($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Fixture([string]$Status) {
 $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $data = @{ status=$Status; taskTitle='Review startup, account connection, and completion notifications';
  taskModel='gpt-6.1-sol'; taskEffort='high'; activeCount=2; notificationCount=1; notificationReadErrors=0; localCoverage=2; readErrors=0;
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
$savedExpiry = $defaults.PlanExpiry
$expiryPicker.SelectedDate = [DateTime]::new(2026,1,31)
Assert-UI (Extend-PlanExpiry) 'Renewal did not extend the configured date'
Assert-UI ($defaults.PlanExpiry -eq '2026-02-28') 'Month-end renewal is incorrect'
Assert-UI (-not (Extend-PlanExpiry)) 'Rapid duplicate renewal was not blocked'
Assert-UI (Undo-PlanRenewal) 'Renewal could not be undone'
Assert-UI ($defaults.PlanExpiry -eq '2026-01-31') 'Undo did not restore the original date'
$expiryPicker.SelectedDate = [DateTime]::new(2028,1,31)
Assert-UI (Extend-PlanExpiry) 'Leap-year renewal failed'
Assert-UI ($defaults.PlanExpiry -eq '2028-02-29') 'Leap-year renewal is incorrect'
$script:planRenewal.Started = (Get-PlanClock) - 31
Assert-UI (-not (Undo-PlanRenewal)) 'Expired undo should not change the date'
Assert-UI ($defaults.PlanExpiry -eq '2028-02-29') 'Expired undo changed the date'
Assert-UI (Extend-PlanExpiry) 'Renewal did not become available after undo expired'
$expiryPicker.SelectedDate = [DateTime]::new(2028,5,15)
Assert-UI (-not (Undo-PlanRenewal)) 'Undo overwrote a manually edited date'
$expiryPicker.SelectedDate = $null
Assert-UI (-not (Extend-PlanExpiry)) 'Unset expiry should require an initial date'
if ($savedExpiry) { $expiryPicker.SelectedDate = [DateTime]::ParseExact($savedExpiry,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) }
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
   if ($status -in @('working','needs_input')) {
    Assert-UI ($parts.TaskModel.Text -eq ($labels.modelFormat -f 'gpt-6.1-sol','high')) 'Conversation model or effort is incorrect'
    Assert-UI ($parts.TaskModel.Visibility -eq 'Visible') 'Conversation model is hidden'
   } else {
    Assert-UI ($parts.TaskModel.Visibility -eq 'Collapsed') 'Model should only appear for the current task'
   }
   if ($status -in @('notification','needs_input')) {
    Assert-UI ($parts.NotificationFrame.Visibility -eq 'Visible') 'Notification border is missing'
    Assert-UI ($parts.PoseSymbol.Text -eq [string][char]0x2665) 'Letter pose is missing its heart'
   } elseif ($status -eq 'working') {
    Assert-UI ($parts.PoseSymbol.Text -eq '?') 'Thinking pose is missing its question mark'
    Assert-UI ($parts.PoseSymbol.Visibility -eq 'Visible') 'Question mark is hidden'
   } else {
    Assert-UI ($parts.PoseSymbol.Visibility -eq 'Collapsed') 'Idle pose must not show a symbol'
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
   Assert-UI ($parts.NotificationFrame.Visibility -eq 'Collapsed') 'Gold effect did not clear after returning to idle'
   Assert-UI ($parts.PoseSymbol.Visibility -eq 'Collapsed') 'Heart did not clear after returning to idle'
  } elseif ($script:phase -eq 7) {
   Write-Fixture 'working'; $script:lastRaw = ''; Update-State
   $defaults.Animation = $true
   Update-SymbolMotion 0.25
   if ([Windows.SystemParameters]::ClientAreaAnimation) {
    Assert-UI ([Math]::Abs($parts.SymbolRotation.Angle) -gt 1) 'Question mark is not swaying'
   }
   Write-Fixture 'notification'; $script:lastRaw = ''; Update-State
   Update-SymbolMotion 0.256
   if ([Windows.SystemParameters]::ClientAreaAnimation) {
    Assert-UI ($parts.SymbolScale.ScaleX -gt 1.1) 'Heart is not pulsing'
   }
   $defaults.Animation = $false; Update-SymbolMotion 0.256
   Assert-UI ($parts.SymbolScale.ScaleX -eq 1 -and $parts.SymbolRotation.Angle -eq 0 -and $parts.SymbolFloat.Y -eq 0) 'Animation toggle did not reset symbol motion'
  } elseif ($script:phase -eq 8) {
   $oldAutoHide = $defaults.AutoHide; $oldDelay = $defaults.AutoHideMinutes
   $defaults.AutoHide = $true; $defaults.AutoHideMinutes = 30
   $script:autoHideActivity = $null; $script:autoHideLatestStart = $null
   $sample = [pscustomobject]@{latestTaskStarted=1;activeCount=0;pendingInputCount=0;updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
   Update-AutoHide $sample 100
   Update-AutoHide $sample 1899
   Assert-UI $window.IsVisible 'Auto-hide fired before the configured timeout'
   Update-AutoHide $sample 1900
   Assert-UI (-not $window.IsVisible) 'Auto-hide did not fire at the timeout'
   $sample.latestTaskStarted = 2; $sample.activeCount = 1
   Update-AutoHide $sample 1901
   Assert-UI $window.IsVisible 'A new task did not reveal the pet'
   Assert-UI (-not $window.ShowActivated) 'Automatic reveal should not take keyboard focus'
   Update-AutoHide $sample 20000
   Assert-UI $window.IsVisible 'A long running task was hidden'
   Hide-PetWindow
   $sample.latestTaskStarted = 3
   Update-AutoHide $sample 20001
   Assert-UI $window.IsVisible 'New task with unchanged active count was missed'
   $sample.activeCount = 0; $sample.pendingInputCount = 1
   Update-AutoHide $sample 24000
   Assert-UI $window.IsVisible 'A pending question was hidden'
   $sample.pendingInputCount = 0
   Update-AutoHide $sample 25799
   Assert-UI $window.IsVisible 'Idle countdown did not reset after pending input'
   Update-AutoHide $sample 25800
   Assert-UI (-not $window.IsVisible) 'Pet did not hide after input wait ended'
   $defaults.AutoHide = $false; $sample.latestTaskStarted = 4
   Update-AutoHide $sample 26000
   Assert-UI (-not $window.IsVisible) 'Disabled mode revealed the pet'
   Show-PetWindow
   Update-AutoHide $sample 30000
   Assert-UI $window.IsVisible 'Disabled mode hid the pet'
   $defaults.AutoHide = $oldAutoHide; $defaults.AutoHideMinutes = $oldDelay
  } elseif ($script:phase -eq 9) {
   Write-Fixture 'working'; $script:lastRaw = ''; Update-State
   $defaults.Animation = $true
   $script:personPhase = 0; $script:personSpeed = 2.6
   $script:lastMotionTime = $watch.Elapsed.TotalSeconds
   Update-PersonMotion $watch.Elapsed.TotalSeconds
   $window.UpdateLayout()
   $script:personBefore = $parts.Dragon.TransformToAncestor($parts.Root).Transform([Windows.Point]::new(0,0)).Y
   $script:breathBefore = $parts.Breath.ScaleY
  } elseif ($script:phase -eq 10) {
   $window.UpdateLayout()
   $personAfter = $parts.Dragon.TransformToAncestor($parts.Root).Transform([Windows.Point]::new(0,0)).Y
   Assert-UI ([Math]::Abs($personAfter - $script:personBefore) -gt 1) ("Live character: before=$script:personBefore after=$personAfter breath=$($parts.Breath.ScaleY) previous=$script:breathBefore phase=$script:personPhase time=$($watch.Elapsed.TotalSeconds) last=$script:lastMotionTime enabled=$($defaults.Animation) visible=$($window.IsVisible)")
   Assert-UI ($parts.Breath.ScaleY -eq 1) 'Character proportions changed during floating'
  } else { $probe.Stop(); $window.Close(); return }
  $script:phase++
 } catch { $script:uiFailure = $_; $probe.Stop(); $window.Close() }
})
$window.Show(); $probe.Start()
[Windows.Threading.Dispatcher]::Run()
if ($script:uiFailure) { throw $script:uiFailure }
Assert-UI (-not $script:tray) 'Tray resources were not disposed'
'UI tests passed: hide, restore, tray cleanup, four states, assets, unknown quota and font-size layout.'

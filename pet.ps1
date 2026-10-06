param([switch]$PreviewOnly, [string]$RenderPath, [string]$StatePath, [double]$PreviewDpiScale = 1.0, [double]$PreviewPetScale = 0, [double]$PreviewFontSize = 0, [double]$PreviewPanelOpacity = 0)
$ErrorActionPreference = 'Stop'
trap {
 $errorMessage = $_.Exception.Message
 $errorFolder = Join-Path $PSScriptRoot 'runtime'
 try {
  [IO.Directory]::CreateDirectory($errorFolder) | Out-Null
  [IO.File]::WriteAllText((Join-Path $errorFolder 'startup-error.txt'), $errorMessage, [Text.Encoding]::UTF8)
  if ($script:worker -and -not $script:worker.HasExited -and $stopPath) { [IO.File]::WriteAllText($stopPath, 'stop'); $script:worker.WaitForExit(7000) | Out-Null }
 } catch {}
 try { Add-Type -AssemblyName PresentationFramework; [Windows.MessageBox]::Show(('The desktop pet could not start.' + "`n`n" + $errorMessage + "`n`nSee runtime/startup-error.txt."), 'White Dragon Pet') | Out-Null } catch {}
 exit 1
}
# Opt this UI thread into per-monitor DPI before creating any WPF windows.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetDpi {
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
 [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }
 [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
 [DllImport("user32.dll", CharSet=CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
 [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
 public static double[] GetWorkArea(IntPtr hwnd) {
  var info = new MONITORINFO(); info.Size = Marshal.SizeOf(typeof(MONITORINFO));
  if (!GetMonitorInfo(MonitorFromWindow(hwnd, 2), ref info)) return null;
  double scale = GetDpiForWindow(hwnd) / 96.0; if (scale <= 0) scale = 1;
  return new double[] { info.Work.Left / scale, info.Work.Top / scale, info.Work.Right / scale, info.Work.Bottom / scale };
 }
}
'@
try {
 [PetDpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
 [PetDpi]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
} catch {}
[AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
[AppContext]::SetSwitch('Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater', $false)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$petRoot = $PSScriptRoot
$runtime = Join-Path $petRoot 'runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\CodexWhiteDragonPet')
if (-not $PreviewOnly -and -not $mutex.WaitOne(0)) { exit }
$stopPath = Join-Path $runtime ('stop-' + [Guid]::NewGuid().ToString('N'))
if (-not $StatePath) { $StatePath = Join-Path $runtime 'state.json' }
$settingsPath = Join-Path $runtime 'settings.json'
$defaults = @{ Left = $null; Top = $null; Scale = 0.6; Animation = $true; CardVisible = $true; FontSize = 12; PanelOpacity = 95 }
if (Test-Path -LiteralPath $settingsPath) {
 try { $saved = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json; foreach ($key in @($defaults.Keys)) { if ($null -ne $saved.$key) { $defaults[$key] = $saved.$key } } } catch {}
}
# Migrate the initial-release unset-position sentinel. Other negative coordinates are valid.
if ($defaults.Left -eq -1 -and $defaults.Top -eq -1) { $defaults.Left = $null; $defaults.Top = $null }
if ($PreviewOnly -and $PreviewPetScale -gt 0) { $defaults.Scale = $PreviewPetScale }
if ($PreviewOnly -and $PreviewFontSize -gt 0) { $defaults.FontSize = $PreviewFontSize }
if ($PreviewOnly -and $PreviewPanelOpacity -gt 0) { $defaults.PanelOpacity = $PreviewPanelOpacity }
$defaults.FontSize = [Math]::Max(10, [Math]::Min(18, [Math]::Round([double]$defaults.FontSize)))
$defaults.PanelOpacity = [Math]::Max(20, [Math]::Min(100, [double]$defaults.PanelOpacity))
$defaults.Scale = [Math]::Max(0.4, [Math]::Min(1.0, [double]$defaults.Scale))
[xml]$xaml = [IO.File]::ReadAllText((Join-Path $petRoot 'pet.xaml'), [Text.Encoding]::UTF8)
$reader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$parts = @{}
foreach ($name in @('Root','Card','Heading','StatusDot','IdlePanel','BusyPanel','Quota','QuotaLabel','QuotaBar','WeeklyLabel','WeeklyQuota','WeeklyBar','PrimaryReset','SecondaryReset','Tokens','Footnote','TaskTitle','Activity','TaskNote','Dragon','Breath','Float')) { $parts[$name] = $window.FindName($name) }
function Load-Pose([string]$filename) {
 $bitmap = New-Object Windows.Media.Imaging.BitmapImage
 $imageStream = [IO.File]::OpenRead((Join-Path $petRoot ('assets/' + $filename)))
 try { $bitmap.BeginInit(); $bitmap.CacheOption = 'OnLoad'; $bitmap.StreamSource = $imageStream; $bitmap.EndInit(); $bitmap.Freeze() } finally { $imageStream.Close() }
 return $bitmap
}
$idlePose = Load-Pose 'dragon-idle.png'
$thinkingPose = Load-Pose 'dragon-thinking.png'
$letterPose = Load-Pose 'dragon-letter.png'
$parts.Dragon.Source = $idlePose
$screen = [System.Windows.SystemParameters]::WorkArea
function Set-PetSize([double]$size) {
 $defaults.Scale = $size
 $parts.Dragon.Width = 212 * $size; $parts.Dragon.Height = 294 * $size
 $cardRow = 232 + 12 * ($defaults.FontSize - 14) + 3.4 * $defaults.FontSize
 $parts.Root.RowDefinitions[0].Height = [Windows.GridLength]::new($cardRow)
 $window.Width = 304 + 12 * ($defaults.FontSize - 14)
 $window.Height = $cardRow + 294 * $size + 10
}
Set-PetSize $defaults.Scale
$window.Left = if ($null -ne $defaults.Left) { $defaults.Left } else { $screen.Right - $window.Width - 26 }
$window.Top = if ($null -ne $defaults.Top) { $defaults.Top } else { $screen.Bottom - $window.Height - 18 }
function Keep-InWorkArea {
 $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
 if ($handle -eq [IntPtr]::Zero) { return }
 $area = [PetDpi]::GetWorkArea($handle)
 if ($area) {
  $window.Left = [Math]::Max($area[0], [Math]::Min($window.Left, $area[2] - $window.Width))
  $window.Top = [Math]::Max($area[1], [Math]::Min($window.Top, $area[3] - $window.Height))
 }
}
$window.Add_SourceInitialized({ Keep-InWorkArea })
$parts.Card.Visibility = if ($defaults.CardVisible) { 'Visible' } else { 'Hidden' }
$parts.Card.Background = '#232230'
$parts.Card.Opacity = $defaults.PanelOpacity / 100.0
$window.Add_MouseLeftButtonDown({ if ($_.ChangedButton -eq 'Left') { try { $window.DragMove() } catch {} } })
$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } })
$menu = New-Object Windows.Controls.ContextMenu
$menu.FontSize = $defaults.FontSize
function Add-MenuItem([string]$text, [scriptblock]$action) {
 $item = New-Object Windows.Controls.MenuItem; $item.Header = $text; $item.Add_Click($action); $menu.Items.Add($item) | Out-Null
}
# Labels live in UTF-8 JSON so this script also loads on Windows PowerShell 5.
$labels = [IO.File]::ReadAllText((Join-Path $petRoot 'labels.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
function Save-Settings {
 if ($PreviewOnly) { return }
 $defaults.Left = $window.Left; $defaults.Top = $window.Top
 [IO.File]::WriteAllText($settingsPath, ($defaults | ConvertTo-Json), [Text.Encoding]::UTF8)
}
function Set-VisualFont($visual, [double]$size) {
 if ($visual -is [Windows.Controls.TextBlock]) { $visual.FontSize = $size }
 for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($visual); $i++) {
  Set-VisualFont ([Windows.Media.VisualTreeHelper]::GetChild($visual, $i)) $size
 }
}
function Set-PetFont([double]$size) {
 $defaults.FontSize = [Math]::Max(10, [Math]::Min(18, [Math]::Round($size)))
 Set-VisualFont $parts.Root $defaults.FontSize
 $menu.FontSize = $defaults.FontSize
 if ($parts.Card.ToolTip -is [Windows.Controls.TextBlock]) { $parts.Card.ToolTip.FontSize = $defaults.FontSize }
 if ($script:fontLabel) { $script:fontLabel.Text = $labels.fontFormat -f $defaults.FontSize }
 Set-PetSize $defaults.Scale
 Keep-InWorkArea
}
Set-PetFont $defaults.FontSize
$fontItem = New-Object Windows.Controls.MenuItem
$fontItem.StaysOpenOnClick = $true
$fontPanel = New-Object Windows.Controls.StackPanel
$fontPanel.Margin = [Windows.Thickness]::new(0, 3, 0, 4)
$script:fontLabel = New-Object Windows.Controls.TextBlock
$script:fontLabel.Text = $labels.fontFormat -f $defaults.FontSize
$fontPanel.Children.Add($script:fontLabel) | Out-Null
$fontSlider = New-Object Windows.Controls.Slider
$fontSlider.Width = 180; $fontSlider.Minimum = 10; $fontSlider.Maximum = 18
$fontSlider.TickFrequency = 1; $fontSlider.IsSnapToTickEnabled = $true
$fontSlider.TickPlacement = 'BottomRight'; $fontSlider.Value = $defaults.FontSize
$fontSlider.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
$fontSlider.Add_ValueChanged({ Set-PetFont $fontSlider.Value; Save-Settings })
$fontPanel.Children.Add($fontSlider) | Out-Null
$fontItem.Header = $fontPanel
$menu.Items.Add($fontItem) | Out-Null
$opacityItem = New-Object Windows.Controls.MenuItem
$opacityItem.StaysOpenOnClick = $true
$opacityPanel = New-Object Windows.Controls.StackPanel
$opacityPanel.Margin = [Windows.Thickness]::new(0, 3, 0, 4)
$opacityLabel = New-Object Windows.Controls.TextBlock
$opacityLabel.Text = $labels.opacityFormat -f $defaults.PanelOpacity
$opacityPanel.Children.Add($opacityLabel) | Out-Null
$opacitySlider = New-Object Windows.Controls.Slider
$opacitySlider.Width = 180; $opacitySlider.Minimum = 20; $opacitySlider.Maximum = 100
$opacitySlider.TickFrequency = 5; $opacitySlider.IsSnapToTickEnabled = $true
$opacitySlider.TickPlacement = 'BottomRight'; $opacitySlider.Value = $defaults.PanelOpacity
$opacitySlider.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
$opacitySlider.Add_ValueChanged({
 $defaults.PanelOpacity = [Math]::Round($opacitySlider.Value)
 $parts.Card.Opacity = $defaults.PanelOpacity / 100.0
 $opacityLabel.Text = $labels.opacityFormat -f $defaults.PanelOpacity
 Save-Settings
})
$opacityPanel.Children.Add($opacitySlider) | Out-Null
$opacityItem.Header = $opacityPanel
$menu.Items.Add($opacityItem) | Out-Null
$sizeItem = New-Object Windows.Controls.MenuItem
$sizeItem.StaysOpenOnClick = $true
$sizePanel = New-Object Windows.Controls.StackPanel
$sizePanel.Margin = [Windows.Thickness]::new(0, 3, 0, 4)
$sizeLabel = New-Object Windows.Controls.TextBlock
$sizeLabel.Text = $labels.sizeFormat -f [Math]::Round($defaults.Scale * 100)
$sizePanel.Children.Add($sizeLabel) | Out-Null
$sizeSlider = New-Object Windows.Controls.Slider
$sizeSlider.Width = 180; $sizeSlider.Minimum = 40; $sizeSlider.Maximum = 100
$sizeSlider.TickFrequency = 5; $sizeSlider.IsSnapToTickEnabled = $true
$sizeSlider.TickPlacement = 'BottomRight'; $sizeSlider.Value = $defaults.Scale * 100
$sizeSlider.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
$sizeSlider.Add_ValueChanged({
 Set-PetSize ($sizeSlider.Value / 100.0)
 $sizeLabel.Text = $labels.sizeFormat -f [Math]::Round($sizeSlider.Value)
 Keep-InWorkArea
 Save-Settings
})
$sizePanel.Children.Add($sizeSlider) | Out-Null
$sizeItem.Header = $sizePanel
$menu.Items.Add($sizeItem) | Out-Null
$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
Add-MenuItem $labels.togglePanel { $defaults.CardVisible = -not $defaults.CardVisible; $parts.Card.Visibility = if ($defaults.CardVisible) { 'Visible' } else { 'Hidden' } }
Add-MenuItem $labels.toggleAnimation { $defaults.Animation = -not $defaults.Animation }
Add-MenuItem $labels.refresh { $script:lastRaw = ''; Update-State }
Add-MenuItem $labels.exit { $window.Close() }
$window.ContextMenu = $menu
$script:lastRaw = ''
$script:status = 'idle'
$script:lastUpdated = 0
$script:primaryBucket = $null
$script:secondaryBucket = $null
function Reset-Label($bucket, [bool]$weekly = $false, [long]$now = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) {
 $remainingLabel = if ($weekly) { $labels.weeklyRemaining } else { $labels.primaryRemaining }
 if ($bucket -and [double]$bucket.resetsAt -gt 0) {
  $resetAt = [long]$bucket.resetsAt
  $seconds = [Math]::Max(0, $resetAt - $now)
  $duration = [TimeSpan]::FromSeconds($seconds)
  $remaining = if ($weekly) { $labels.daysHours -f $duration.Days, $duration.Hours } else { $labels.hoursMinutes -f ([Math]::Floor($duration.TotalHours)), $duration.Minutes }
  return $labels.refreshTime + [DateTimeOffset]::FromUnixTimeSeconds($resetAt).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm') + "`n" + $remainingLabel + $remaining
 }
 return $labels.refreshTime + '--' + "`n" + $remainingLabel + '--'
}
function Update-ResetLabels {
 $parts.PrimaryReset.Text = Reset-Label $script:primaryBucket
 $parts.SecondaryReset.Text = Reset-Label $script:secondaryBucket $true
}
function Update-State {
 try {
  if (-not (Test-Path -LiteralPath $StatePath)) { return }
  $raw = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8)
  if ($raw -eq $script:lastRaw) {
   Update-ResetLabels
   if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:lastUpdated -gt 15) { $parts.Heading.Text = $labels.disconnected }
   return
  }; $script:lastRaw = $raw
  $state = $raw | ConvertFrom-Json
  $script:lastUpdated = [double]$state.updatedAt
  $script:status = $state.status
  $isIdle = $state.status -eq 'idle'
  $isNotification = $state.status -in @('notification', 'needs_input')
  $parts.Dragon.Source = if ($isNotification) { $letterPose } elseif ($isIdle) { $idlePose } else { $thinkingPose }
  # A pending message remains visible even when the normal card is collapsed.
  $parts.Card.Visibility = if ($isNotification -or $defaults.CardVisible) { 'Visible' } else { 'Hidden' }
  $parts.IdlePanel.Visibility = if ($isIdle) { 'Visible' } else { 'Collapsed' }
  $parts.BusyPanel.Visibility = if ($isIdle) { 'Collapsed' } else { 'Visible' }
  $parts.Heading.Text = $labels.($state.status)
  if (-not $parts.Heading.Text) { $parts.Heading.Text = $labels.working }
  $parts.StatusDot.Fill = if ($isNotification) { '#F3C36E' } elseif ($state.status -eq 'error') { '#F295AD' } else { '#B8A8E8' }
  $parts.Card.BorderBrush = if ($isNotification) { '#D2B177' } else { '#74688E' }
  $parts.Tokens.Text = ([long]$state.todayTokens).ToString('N0')
  $parts.Footnote.Text = $labels.localDate + ' ' + $state.date
  if ($state.readErrors -gt 0) { $parts.Footnote.Text += ' ' + $labels.partial }
  $parts.TaskTitle.Text = $state.taskTitle
  $parts.Activity.Text = if ($isNotification) { $labels.notificationCount -f [Math]::Max(1, [int]$state.notificationCount) } elseif ($state.activeCount -gt 1) { $labels.multi -f $state.activeCount } else { $labels.activity }
  $parts.TaskNote.Text = if ($isNotification) { $labels.messageAction } elseif ($state.statusStale) { $labels.staleStatus } else { $labels.finish }
  $limit = $state.rateLimits
  $p = $limit.primary; $s = $limit.secondary
  $rateAge = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [double]$state.rateUpdatedAt
  $expiredP = $null -ne $p -and [double]$p.resetsAt -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [double]$p.resetsAt
  $expiredS = $null -ne $s -and [double]$s.resetsAt -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [double]$s.resetsAt
  # Rollout fallback uses snake_case; live account endpoint uses camelCase.
  if ($p -and $null -eq $p.usedPercent) { $p | Add-Member NoteProperty usedPercent $p.used_percent; $p | Add-Member NoteProperty resetsAt $p.resets_at; $expiredP = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [double]$p.resetsAt }
  if ($s -and $null -eq $s.usedPercent) { $s | Add-Member NoteProperty usedPercent $s.used_percent; $s | Add-Member NoteProperty resetsAt $s.resets_at; $expiredS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [double]$s.resetsAt }
  $pr = if ($null -ne $p -and -not $expiredP) { [Math]::Max(0, [Math]::Min(100, 100 - [double]$p.usedPercent)) } else { $null }
  $sr = if ($null -ne $s -and -not $expiredS) { [Math]::Max(0, [Math]::Min(100, 100 - [double]$s.usedPercent)) } else { $null }
  $pt = if ($null -eq $pr) { '--' } else { '{0:0}%' -f $pr }
  $st = if ($null -eq $sr) { '--' } else { '{0:0}%' -f $sr }
  $parts.Quota.Text = $pt
  $parts.WeeklyQuota.Text = $st
  $parts.QuotaBar.Value = if ($null -eq $pr) { 0 } else { $pr }
  $parts.WeeklyBar.Value = if ($null -eq $sr) { 0 } else { $sr }
  $parts.QuotaLabel.Text = if ($rateAge -gt 180) { $labels.oldPrimary } else { $labels.primary }
  $parts.WeeklyLabel.Text = if ($rateAge -gt 180) { $labels.oldWeekly } else { $labels.weekly }
  $script:primaryBucket = $p; $script:secondaryBucket = $s
  Update-ResetLabels
  $tip = $labels.coverage -f $state.localCoverage, $state.cachedTokens, $state.outputTokens
  if ($null -ne $state.officialDayTokens) { $tip += "`n" + ($labels.official -f ([long]$state.officialDayTokens).ToString('N0')) }
  if ($isNotification) { $tip = $labels.messageAction + "`n" + $tip }
  if ($state.notificationReadErrors -gt 0) { $tip += "`n" + $labels.notificationPartial }
  if ($state.rateUpdatedAt -gt 0) { $tip += "`n" + $labels.updated + [DateTimeOffset]::FromUnixTimeSeconds([long]$state.rateUpdatedAt).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm:ss') }
  if ($p.resetsAt) { $tip += "`n" + $labels.reset + [DateTimeOffset]::FromUnixTimeSeconds([long]$p.resetsAt).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm') }
  if ($s.resetsAt) { $tip += "`n" + $labels.weekReset + [DateTimeOffset]::FromUnixTimeSeconds([long]$s.resetsAt).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm') }
  $tooltipText = New-Object Windows.Controls.TextBlock
  $tooltipText.Text = $tip; $tooltipText.FontSize = $defaults.FontSize; $tooltipText.MaxWidth = 440; $tooltipText.TextWrapping = 'Wrap'
  $parts.Card.ToolTip = $tooltipText
  if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [double]$state.updatedAt -gt 15) { $parts.Heading.Text = $labels.disconnected }
  if (-not $PreviewOnly) {
   $dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window)
   $uiState = @{ processId = $PID; scale = $defaults.Scale; status = $script:status; pose = $(if ($isNotification) { 'letter' } elseif ($isIdle) { 'idle' } else { 'thinking' }); notificationCount = $state.notificationCount; visible = $window.IsVisible; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); dpiScale = $dpi.DpiScaleX; perMonitorV2 = [PetDpi]::AreDpiAwarenessContextsEqual([PetDpi]::GetThreadDpiAwarenessContext(), [IntPtr]::new(-4)); fontSize = $defaults.FontSize; fontMin = 10; fontMax = 18; panelOpacity = $defaults.PanelOpacity; primaryReset = $parts.PrimaryReset.Text; secondaryReset = $parts.SecondaryReset.Text }
   [IO.File]::WriteAllText((Join-Path $runtime 'ui.json'), ($uiState | ConvertTo-Json), [Text.Encoding]::UTF8)
  }
 } catch { $parts.Heading.Text = $labels.reading }
}
$stateTimer = New-Object Windows.Threading.DispatcherTimer
$stateTimer.Interval = [TimeSpan]::FromSeconds(1)
$stateTimer.Add_Tick({
 $closeRequest = Join-Path $runtime 'close-request'
 if (-not $PreviewOnly -and (Test-Path -LiteralPath $closeRequest)) { Remove-Item -LiteralPath $closeRequest; $window.Close(); return }
 if ($script:worker -and $script:worker.HasExited) {
  $parts.Heading.Text = $labels.collectorStopped
  $parts.StatusDot.Fill = '#F295AD'
  $parts.Activity.Text = $labels.collectorHelp
  $parts.TaskNote.Text = $labels.collectorHelp
  $parts.Card.ToolTip = $labels.collectorHelp
  $workerError = $script:worker.StandardError.ReadToEnd()
  if ($workerError) { [IO.File]::WriteAllText((Join-Path $runtime 'collector-error.txt'), $workerError, [Text.Encoding]::UTF8) }
  return
 }
 Update-State
}); $stateTimer.Start()
$watch = [Diagnostics.Stopwatch]::StartNew()
$motionTimer = New-Object Windows.Threading.DispatcherTimer
$motionTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$motionTimer.Add_Tick({
 if ($defaults.Animation -and -not [Windows.SystemParameters]::ClientAreaAnimation) { $defaults.Animation = $false }
 if ($defaults.Animation) {
  $speed = if ($script:status -eq 'idle') { 1.6 } else { 2.6 }
  $wave = [Math]::Sin($watch.Elapsed.TotalSeconds * $speed)
  $parts.Float.Y = -2 - 2 * $wave; $parts.Breath.ScaleY = 1 + 0.004 * $wave
 } else { $parts.Float.Y = 0; $parts.Breath.ScaleY = 1 }
}); $motionTimer.Start()
$script:worker = $null
if (-not $PreviewOnly) {
 $closeRequest = Join-Path $runtime 'close-request'
 if (Test-Path -LiteralPath $closeRequest) { Remove-Item -LiteralPath $closeRequest }
 if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
 $python = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
 if (-not (Test-Path -LiteralPath $python)) { $python = (Get-Command python -ErrorAction Stop).Source }
 $workerInfo = New-Object Diagnostics.ProcessStartInfo
 $workerInfo.FileName = $python
 $workerInfo.Arguments = '"' + (Join-Path $petRoot 'collector.py') + '" --state "' + $StatePath + '" --stop "' + $stopPath + '"'
 $workerInfo.UseShellExecute = $false; $workerInfo.CreateNoWindow = $true; $workerInfo.WorkingDirectory = $petRoot
 $workerInfo.RedirectStandardError = $true
 $script:worker = [Diagnostics.Process]::Start($workerInfo)
}
$window.Add_Closed({
 $stateTimer.Stop(); $motionTimer.Stop()
 if (-not $PreviewOnly) {
  [IO.File]::WriteAllText($stopPath, 'stop')
  $defaults.Left = $window.Left; $defaults.Top = $window.Top
  [IO.File]::WriteAllText($settingsPath, ($defaults | ConvertTo-Json), [Text.Encoding]::UTF8)
  # Keep the singleton lock until the collector has closed its app-server child.
  if ($script:worker -and -not $script:worker.HasExited) {
   if (-not $script:worker.WaitForExit(7000)) {
    $killInfo = New-Object Diagnostics.ProcessStartInfo
    $killInfo.FileName = 'taskkill.exe'; $killInfo.Arguments = '/PID ' + $script:worker.Id + ' /T /F'
    $killInfo.UseShellExecute = $false; $killInfo.CreateNoWindow = $true
    [Diagnostics.Process]::Start($killInfo).WaitForExit(3000) | Out-Null
   }
  }
  try { $mutex.ReleaseMutex() } catch {}
 }
 $mutex.Dispose()
})
Update-State
if ($RenderPath) {
 $window.Show(); $window.UpdateLayout()
 $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
 # Let the WPF compositor finish the first transparent-window paint before capture.
 $frame = New-Object Windows.Threading.DispatcherFrame
 $paintTimer = New-Object Windows.Threading.DispatcherTimer
 $paintTimer.Interval = [TimeSpan]::FromMilliseconds(200)
 $paintTimer.Add_Tick({ $paintTimer.Stop(); $frame.Continue = $false })
 $paintTimer.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
 $render = New-Object Windows.Media.Imaging.RenderTargetBitmap([int][Math]::Ceiling($window.ActualWidth * $PreviewDpiScale), [int][Math]::Ceiling($window.ActualHeight * $PreviewDpiScale), (96 * $PreviewDpiScale), (96 * $PreviewDpiScale), [Windows.Media.PixelFormats]::Pbgra32)
 $render.Render($parts.Root)
 $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
 $outStream = [IO.File]::Create($RenderPath); $encoder.Save($outStream); $outStream.Close(); $window.Close()
} else { $window.ShowDialog() | Out-Null }

$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'pet.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'PowerShell syntax errors' }
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-MotionSample','Update-PersonMotion') }, $true)
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
function Assert-Near([double]$a, [double]$b, [double]$tolerance, [string]$message) {
 if ([Math]::Abs($a - $b) -gt $tolerance) { throw "$message : $a versus $b" }
}
$step = 0.00001
foreach ($pair in @(@('person',1),@('question',4),@('heart',1.6))) {
 $kind = $pair[0]; $period = [double]$pair[1]
 $start = Get-MotionSample $kind 0; $end = Get-MotionSample $kind $period
 $before = Get-MotionSample $kind ($period - $step)
 $after = Get-MotionSample $kind $step
 foreach ($key in $start.Keys) {
  Assert-Near $start[$key] $end[$key] 0.000000001 "$kind value at boundary ($key)"
  $left = ($end[$key] - $before[$key]) / $step
  $right = ($after[$key] - $start[$key]) / $step
  Assert-Near $left $right 0.005 "$kind velocity at boundary ($key)"
 }
 foreach ($time in @(0.13,0.71,1.23,27.4)) {
  $a = Get-MotionSample $kind $time; $b = Get-MotionSample $kind ($time + $period)
  foreach ($key in $a.Keys) { Assert-Near $a[$key] $b[$key] 0.000000001 "$kind repeats ($key)" }
 }
}
$parts = @{ Float = [pscustomobject]@{Y=0}; Breath = [pscustomobject]@{ScaleY=1} }
$defaults = @{Animation=$true}; $window = [pscustomobject]@{IsVisible=$true}
$script:lastMotionTime = $null; $script:status = 'idle'
Update-PersonMotion 123
$previous = $parts.Float.Y
$script:status = 'working'; Update-PersonMotion 123
Assert-Near $parts.Float.Y $previous 0.000000001 'State change must preserve position'
Assert-Near $script:personSpeed 1.6 0.000000001 'State change must preserve instantaneous speed'
Update-PersonMotion 123.00001
if ([Math]::Abs($parts.Float.Y - $previous) -gt 0.001) { throw 'State change caused a position jump' }
$defaults.Animation = $false; Update-PersonMotion 124
Assert-Near $parts.Float.Y 0 0 'Disabled position'
Assert-Near $parts.Breath.ScaleY 1 0 'Disabled scale'
'Motion tests passed: periodic positions, periodic velocities, repeated cycles and continuous state changes.'

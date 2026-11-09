param(
 [string]$Source = (Join-Path $PSScriptRoot 'assets/white-dragon-avatar.png'),
 [string]$Destination = (Join-Path $PSScriptRoot 'assets/white-dragon-avatar-color.ico')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$image = [Drawing.Image]::FromFile($Source)
$attributes = [Drawing.Imaging.ImageAttributes]::new()
$attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
$frames = @()
try {
 foreach ($size in @(16,24,32,48,64,128,256)) {
  $bitmap = [Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  $stream = [IO.MemoryStream]::new()
  try {
   $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
   $graphics.DrawImage($image,[Drawing.Rectangle]::new(0,0,$size,$size),0,0,$image.Width,$image.Height,[Drawing.GraphicsUnit]::Pixel,$attributes)
   $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
   $frames += [pscustomobject]@{Size=$size; Bytes=$stream.ToArray()}
  } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
 }
 $output = [IO.File]::Create($Destination)
 $writer = [IO.BinaryWriter]::new($output)
 try {
  $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
  $offset = 6 + 16 * $frames.Count
  foreach ($frame in $frames) {
   $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
   $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
   $writer.Write([byte]0); $writer.Write([byte]0)
   $writer.Write([uint16]1); $writer.Write([uint16]32)
   $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
   $offset += $frame.Bytes.Length
  }
  foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
 } finally { $writer.Dispose(); $output.Dispose() }
} finally { $attributes.Dispose(); $image.Dispose() }
Write-Output $Destination

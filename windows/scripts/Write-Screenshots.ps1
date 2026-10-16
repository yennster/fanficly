<#
.SYNOPSIS
  Prints every PNG under a folder to the log as a small base64 JPEG between
  BEGIN-SCREENSHOT/END-SCREENSHOT markers, so the pictures can be read back
  from a job log when artifact downloads aren't available.
#>
param([Parameter(Mandatory)] [string] $Dir, [int] $MaxWidth = 960, [long] $Quality = 65)
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $Dir)) { Write-Host "No screenshots in $Dir"; exit 0 }
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
$params = New-Object System.Drawing.Imaging.EncoderParameters 1
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), $Quality
$root = (Resolve-Path $Dir).Path
Get-ChildItem $Dir -Recurse -Filter *.png | Sort-Object FullName | ForEach-Object {
  $src = [System.Drawing.Image]::FromFile($_.FullName)
  $w = [Math]::Min($MaxWidth, $src.Width); $h = [int]($src.Height * $w / $src.Width)
  $small = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($small)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.DrawImage($src, 0, 0, $w, $h)
  $ms = New-Object System.IO.MemoryStream
  $small.Save($ms, $codec, $params)
  $b64 = [Convert]::ToBase64String($ms.ToArray())
  $name = $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '__').Replace('/', '__')
  Write-Host "BEGIN-SCREENSHOT $name ($($src.Width)x$($src.Height))"
  for ($i = 0; $i -lt $b64.Length; $i += 4000) { Write-Host ("B64:" + $b64.Substring($i, [Math]::Min(4000, $b64.Length - $i))) }
  Write-Host "END-SCREENSHOT"
  $g.Dispose(); $small.Dispose(); $src.Dispose(); $ms.Dispose()
}

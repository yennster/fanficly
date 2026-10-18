<#
.SYNOPSIS
  Launches a built Fanficly.exe in demo mode and saves a screenshot of the
  screen. CI uses it as a launch smoke test: the app must still be running
  after the wait, or the step fails.
#>
param(
  [Parameter(Mandatory)] [string] $Exe,
  [Parameter(Mandatory)] [string] $Out,
  [string[]] $AppArgs = @('-demoMode'),
  [int] $WaitSeconds = 12,
  # Also print a small JPEG of the capture to the log as base64 (between
  # BEGIN/END markers), so the picture can be read back from the job log
  # where artifact downloads aren't available.
  [switch] $EmitBase64
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

$proc = Start-Process -FilePath $Exe -ArgumentList $AppArgs -PassThru
Start-Sleep -Seconds $WaitSeconds
if ($proc.HasExited) {
  Write-Error "Fanficly exited during launch (exit code $($proc.ExitCode))."
}
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "Saved $Out"
if ($EmitBase64) {
  $src = [System.Drawing.Image]::FromFile((Resolve-Path $Out))
  $w = [Math]::Min(1280, $src.Width); $h = [int]($src.Height * $w / $src.Width)
  $small = New-Object System.Drawing.Bitmap $w, $h
  $sg = [System.Drawing.Graphics]::FromImage($small)
  $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $sg.DrawImage($src, 0, 0, $w, $h)
  $ms = New-Object System.IO.MemoryStream
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
  $params = New-Object System.Drawing.Imaging.EncoderParameters 1
  $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 72L
  $small.Save($ms, $codec, $params)
  $b64 = [Convert]::ToBase64String($ms.ToArray())
  Write-Host "BEGIN-SCREENSHOT $(Split-Path $Out -Leaf)"
  for ($i = 0; $i -lt $b64.Length; $i += 4000) { Write-Host ("B64:" + $b64.Substring($i, [Math]::Min(4000, $b64.Length - $i))) }
  Write-Host "END-SCREENSHOT"
  $sg.Dispose(); $small.Dispose(); $src.Dispose(); $ms.Dispose()
}
Stop-Process -Id $proc.Id -Force

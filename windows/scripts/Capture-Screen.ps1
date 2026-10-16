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
  [int] $WaitSeconds = 12
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
Stop-Process -Id $proc.Id -Force

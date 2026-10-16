<#
.SYNOPSIS
  Switches the primary display to the largest mode no bigger than the given
  size (CI runners start at 1024x768, too small for a desktop or upright
  tablet window). Best effort: prints what it got and never fails the job.
#>
param([int] $Width = 1920, [int] $Height = 1200)
$ErrorActionPreference = 'Continue'
# Windows Server has a cmdlet for this; use it when present.
if (Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue) {
  foreach ($size in @(@($Width, $Height), @(1920, 1080), @(1680, 1050), @(1600, 900), @(1440, 900), @(1366, 768))) {
    try { Set-DisplayResolution -Width $size[0] -Height $size[1] -Force -ErrorAction Stop; Write-Host "Set-DisplayResolution $($size[0])x$($size[1])"; break }
    catch { Write-Host "Set-DisplayResolution $($size[0])x$($size[1]) failed: $_" }
  }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Display {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
  public static DEVMODE Create() { var d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }
}
'@
$modes = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt 400; $i++) {
  $dm = [Display]::Create()
  try { if (-not [Display]::EnumDisplaySettings($null, $i, [ref]$dm)) { break } }
  catch { Write-Host "Couldn't list display modes: $_"; break }
  $modes.Add([pscustomobject]@{ W = $dm.dmPelsWidth; H = $dm.dmPelsHeight; Mode = $dm })
}
Write-Host "$($modes.Count) display modes"
$best = $modes | Where-Object { $_.W -le $Width -and $_.H -le $Height } |
  Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
if ($best) {
  $dm = $best.Mode
  $dm.dmFields = 0x80000 -bor 0x100000   # DM_PELSWIDTH | DM_PELSHEIGHT
  Write-Host "Switching to $($best.W)x$($best.H)"
  $result = [Display]::ChangeDisplaySettings([ref]$dm, 0)
  Write-Host "Display mode $($best.W)x$($best.H): result $result (0 = changed)"
} else {
  Write-Host "No display mode up to ${Width}x${Height}; modes: $(($modes | ForEach-Object { "$($_.W)x$($_.H)" } | Select-Object -Unique) -join ', ')"
}
Add-Type -AssemblyName System.Windows.Forms
Write-Host "Screen now: $([System.Windows.Forms.Screen]::PrimaryScreen.Bounds)"

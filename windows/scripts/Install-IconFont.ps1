<#
.SYNOPSIS
  Makes sure Segoe Fluent Icons (Windows 11's icon font, which the app draws
  its icons with) is installed. Windows Server images used by CI runners
  ship only the older Segoe MDL2 Assets, which lacks some glyphs, so
  screenshots taken there would show empty boxes. Downloads Microsoft's
  published copy of the font and installs it for the machine. Best effort.
#>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
$families = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
if ($families -contains 'Segoe Fluent Icons') { Write-Host 'Segoe Fluent Icons is installed.'; exit 0 }
Write-Host "Segoe Fluent Icons is missing (MDL2 present: $($families -contains 'Segoe MDL2 Assets')); installing it."
$zip = Join-Path $env:RUNNER_TEMP 'SegoeFluentIcons.zip'
$dir = Join-Path $env:RUNNER_TEMP 'SegoeFluentIcons'
Invoke-WebRequest 'https://aka.ms/SegoeFluentIcons' -OutFile $zip
Expand-Archive $zip -DestinationPath $dir -Force
$ttf = Get-ChildItem $dir -Recurse -Filter *.ttf | Select-Object -First 1
if (-not $ttf) { Write-Host 'No font file in the download.'; exit 0 }
$target = Join-Path $env:WINDIR "Fonts\$($ttf.Name)"
Copy-Item $ttf.FullName $target -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Name 'Segoe Fluent Icons (TrueType)' -Value $ttf.Name -PropertyType String -Force | Out-Null
Add-Type -Namespace Win32 -Name Fonts -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
'@
[void][Win32.Fonts]::AddFontResource($target)
$r = [IntPtr]::Zero
[void][Win32.Fonts]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$r)  # WM_FONTCHANGE
Write-Host "Installed $($ttf.Name)."

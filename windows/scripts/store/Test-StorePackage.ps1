<#
.SYNOPSIS
  Runs the Windows App Certification Kit (WACK) on the Store package.

.DESCRIPTION
  The Store runs the same kind of technical checks during certification;
  running WACK first catches most of what would fail there (the Windows
  counterpart of fastlane precheck).

  Steps:
    1. Takes a .msixupload (the Store upload file) or a .msixbundle / .msix.
       From a .msixupload it extracts the .msixbundle.
    2. WACK installs the package to test it, and Windows only installs
       signed packages, so an unsigned package is signed with a throwaway
       self-signed certificate whose subject is the package's own Publisher.
       The certificate is trusted for the run and removed afterwards. (The
       Store re-signs packages, so the upload itself stays unsigned.)
    3. Runs `appcert.exe test` and writes the XML report.

  Needs Windows, the Windows SDK's App Certification Kit and an elevated
  (administrator) PowerShell; GitHub's Windows runners have all three. If
  the kit isn't installed the script warns and exits without failing.

  Exit code: 0 when WACK passes (or the kit is missing), 1 when it fails.

.PARAMETER Package
  The .msixupload, .msixbundle or .msix to test, or a folder holding one.

.PARAMETER ReportPath
  Where to write the WACK XML report. Defaults to wack-report.xml in the
  current folder.

.EXAMPLE
  ./Test-StorePackage.ps1 -Package ../../../artifacts/AppPackages -ReportPath ../../../artifacts/wack/report.xml
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Package,
  [string] $ReportPath = (Join-Path (Get-Location) 'wack-report.xml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The Windows App Certification Kit only runs on Windows.' }

$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$appcert = Join-Path $kitRoot 'App Certification Kit\appcert.exe'
if (-not (Test-Path -LiteralPath $appcert)) {
  Write-Warning "The Windows App Certification Kit isn't installed ($appcert). Install the Windows SDK with it to run this check. Skipping."
  exit 0
}

# Find the package.
$item = Get-Item -LiteralPath $Package
if ($item.PSIsContainer) {
  $found = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
      Where-Object { $_.Extension -in '.msixupload', '.msixbundle', '.msix' } |
      Sort-Object { @('.msixupload', '.msixbundle', '.msix').IndexOf($_.Extension) })
  if ($found.Count -eq 0) { throw "No .msixupload, .msixbundle or .msix in $($item.FullName)." }
  $item = $found[0]
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "fanficly-wack-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Expand-ZipEntry([string] $ZipPath, [scriptblock] $Match, [string] $Destination) {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    $entry = $zip.Entries | Where-Object $Match | Select-Object -First 1
    if ($null -eq $entry) { return $null }
    $out = Join-Path $Destination $entry.Name
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
    return $out
  }
  finally { $zip.Dispose() }
}

function Get-ManifestPublisher([string] $PackageFile) {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($PackageFile)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -in 'AppxMetadata/AppxBundleManifest.xml', 'AppxManifest.xml' } | Select-Object -First 1
    if ($null -eq $entry) { throw "No manifest inside $PackageFile." }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
  }
  finally { $zip.Dispose() }
  $identity = $xml.SelectSingleNode("/*[local-name()='Bundle' or local-name()='Package']/*[local-name()='Identity']")
  if ($null -eq $identity) { throw "No Identity in the manifest of $PackageFile." }
  return $identity.GetAttribute('Publisher')
}

function Test-PackageSigned([string] $PackageFile) {
  # A signed MSIX or bundle carries AppxSignature.p7x at its root.
  $zip = [System.IO.Compression.ZipFile]::OpenRead($PackageFile)
  try { return [bool]($zip.Entries | Where-Object { $_.FullName -eq 'AppxSignature.p7x' }) }
  finally { $zip.Dispose() }
}

function Find-SignTool {
  $tool = Get-ChildItem -Path (Join-Path $kitRoot 'bin') -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' } |
    Sort-Object {
      $v = [version]'0.0'
      [void][version]::TryParse($_.Directory.Parent.Name, [ref] $v)
      $v
    } -Descending |
    Select-Object -First 1
  if ($null -eq $tool) { throw "signtool.exe not found under $kitRoot\bin." }
  return $tool.FullName
}

$cert = $null
$trusted = $null
$exitCode = 0
try {
  # 1. The package to test.
  if ($item.Extension -eq '.msixupload') {
    $target = Expand-ZipEntry $item.FullName { $_.Name -like '*.msixbundle' -or $_.Name -like '*.msix' } $work
    if ($null -eq $target) { throw "No .msixbundle or .msix inside $($item.FullName)." }
  }
  else {
    $target = Join-Path $work $item.Name
    Copy-Item -LiteralPath $item.FullName -Destination $target
  }
  Write-Host "Testing $(Split-Path -Leaf $target)"

  # 2. Sign it with a throwaway certificate if it isn't signed.
  if (-not (Test-PackageSigned $target)) {
    $publisher = Get-ManifestPublisher $target
    Write-Host "Signing with a temporary certificate for $publisher"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature `
      -FriendlyName 'Fanficly WACK test (temporary)' -CertStoreLocation 'Cert:\CurrentUser\My' `
      -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -NotAfter (Get-Date).AddDays(1)
    $cer = Join-Path $work 'wack-test.cer'
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    $trusted = Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
    $signtool = Find-SignTool
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $target
    if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
  }

  # 3. Run WACK.
  $reportFull = [System.IO.Path]::GetFullPath($ReportPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportFull) | Out-Null
  if (Test-Path -LiteralPath $reportFull) { Remove-Item -LiteralPath $reportFull -Force }
  & $appcert reset | Out-Null
  & $appcert test -appxpackagepath $target -reportoutputpath $reportFull
  $appcertExit = $LASTEXITCODE
  if (-not (Test-Path -LiteralPath $reportFull)) {
    throw "WACK wrote no report (exit code $appcertExit)."
  }

  [xml]$report = Get-Content -LiteralPath $reportFull -Raw
  $overall = $report.DocumentElement.GetAttribute('OVERALL_RESULT')
  Write-Host "WACK overall result: $overall"
  $failed = @($report.SelectNodes('//TEST') | Where-Object {
      $result = $_.SelectSingleNode('RESULT')
      $null -ne $result -and $result.InnerText.Trim() -eq 'FAIL'
    })
  foreach ($test in $failed) { Write-Host "  FAILED: $($test.GetAttribute('NAME'))" }

  if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @("### Windows App Certification Kit: $overall", '')
    if ($failed.Count -gt 0) { $lines += $failed | ForEach-Object { "- Failed: $($_.GetAttribute('NAME'))" } }
    else { $lines += 'No failed tests.' }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $lines -Encoding utf8
  }
  if ($overall -eq 'FAIL') { $exitCode = 1 }
}
finally {
  if ($trusted) { Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$($trusted.Thumbprint)" -ErrorAction SilentlyContinue }
  if ($cert) { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode

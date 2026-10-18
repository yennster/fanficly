<#
.SYNOPSIS
  Writes the package version into Package.appxmanifest.

.DESCRIPTION
  The Microsoft Store reads an app's version from Identity/@Version in the
  MSIX manifest. It must be four numbers, A.B.C.0: the Store reserves the
  last one (the revision) and requires it to be 0, and every new package
  must have a higher version than the last one published.

  Give the version one of two ways:

    -Version      An explicit version: 1.2.3, 1.2.3.0, v1.2.3 or a tag name
                  such as windows-v1.2.3. Becomes 1.2.3.0.
    -BuildNumber  Takes major.minor from windows/store/version.txt and uses
                  the build number as the third part: version.txt 1.0 and
                  build 57 become 1.0.57.0.

  Only the manifest is changed. The script prints the version, returns it
  as a string, and when run in GitHub Actions also sets the step output
  `version`.

.PARAMETER Version
  The version to write (see above).

.PARAMETER BuildNumber
  The build number used as the third part with version.txt. Defaults to 0.

.PARAMETER VersionFile
  The major.minor file. Defaults to windows/store/version.txt.

.PARAMETER Manifest
  The manifest to change. Defaults to windows/src/Fanficly.App/Package.appxmanifest.

.EXAMPLE
  ./Set-AppVersion.ps1 -Version windows-v1.2.3
  # Identity/@Version = 1.2.3.0

.EXAMPLE
  ./Set-AppVersion.ps1 -BuildNumber 57
  # With version.txt = 1.0: Identity/@Version = 1.0.57.0
#>
[CmdletBinding(DefaultParameterSetName = 'FromFile')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Explicit')]
  [string] $Version,

  [Parameter(ParameterSetName = 'FromFile')]
  [ValidateRange(0, 65535)]
  [int] $BuildNumber = 0,

  [Parameter(ParameterSetName = 'FromFile')]
  [string] $VersionFile = (Join-Path $PSScriptRoot '..' '..' 'store' 'version.txt'),

  [string] $Manifest = (Join-Path $PSScriptRoot '..' '..' 'src' 'Fanficly.App' 'Package.appxmanifest')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-VersionPart([string] $Part, [string] $Name, [string] $Source) {
  $n = 0
  if (-not [int]::TryParse($Part, [ref] $n) -or $n -lt 0 -or $n -gt 65535) {
    throw "The $Name part of '$Source' must be a whole number from 0 to 65535."
  }
  return $n
}

if ($PSCmdlet.ParameterSetName -eq 'Explicit') {
  # Accept tag names (windows-v1.2.3) and a leading v.
  $clean = $Version.Trim() -replace '^(?:windows-)?v', ''
  $parts = $clean.Split('.')
  if ($parts.Count -notin 3, 4) {
    throw "Version '$Version' must look like 1.2.3 or 1.2.3.0 (tags like windows-v1.2.3 work too)."
  }
  if ($parts.Count -eq 4 -and $parts[3] -ne '0') {
    throw "Version '$Version' ends in .$($parts[3]). The Microsoft Store reserves the fourth number; it must be 0."
  }
  $major = Assert-VersionPart $parts[0] 'major' $Version
  $minor = Assert-VersionPart $parts[1] 'minor' $Version
  $build = Assert-VersionPart $parts[2] 'third' $Version
}
else {
  if (-not (Test-Path -LiteralPath $VersionFile)) {
    throw "Version file not found: $VersionFile"
  }
  $base = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
  $parts = $base.Split('.')
  if ($parts.Count -ne 2) {
    throw "$VersionFile must hold major.minor, for example 1.0 (found '$base')."
  }
  $major = Assert-VersionPart $parts[0] 'major' $base
  $minor = Assert-VersionPart $parts[1] 'minor' $base
  $build = $BuildNumber
}

$packageVersion = "$major.$minor.$build.0"

if (-not (Test-Path -LiteralPath $Manifest)) {
  throw "Manifest not found: $Manifest"
}
$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path

$doc = [System.Xml.XmlDocument]::new()
$doc.PreserveWhitespace = $true
$doc.Load($manifestPath)
$ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
$ns.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')

$identity = $doc.SelectSingleNode('/f:Package/f:Identity', $ns)
if ($null -eq $identity) {
  throw "No Package/Identity element in $manifestPath."
}
$previous = $identity.GetAttribute('Version')
$identity.SetAttribute('Version', $packageVersion)

# Save as UTF-8 without a byte-order mark, keeping the file's own line endings.
$settings = [System.Xml.XmlWriterSettings]::new()
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
$writer = [System.Xml.XmlWriter]::Create($manifestPath, $settings)
try { $doc.Save($writer) } finally { $writer.Dispose() }

Write-Host "Package version: $previous -> $packageVersion"
if ($env:GITHUB_OUTPUT) {
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$packageVersion" -Encoding utf8
}
$packageVersion

<#
.SYNOPSIS
  Writes the Partner Center package identity into Package.appxmanifest.

.DESCRIPTION
  When you reserve an app name in Partner Center, the Store assigns the
  package identity the app must ship with. Partner Center shows it under
  Product management > Product identity:

    Package/Identity/Name                 -> -Name
    Package/Identity/Publisher            -> -Publisher
    Package/Properties/PublisherDisplayName -> -PublisherDisplayName

  The committed manifest carries placeholders; this script writes the real
  values (the Store workflow passes them from repository variables). A
  package whose identity doesn't match is rejected on upload.

.PARAMETER Name
  Package/Identity/Name, for example 12345Fanficly.Fanficly.

.PARAMETER Publisher
  Package/Identity/Publisher, for example CN=0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9.

.PARAMETER PublisherDisplayName
  Package/Properties/PublisherDisplayName, your publisher name in the Store.

.PARAMETER Manifest
  The manifest to change. Defaults to windows/src/Fanficly.App/Package.appxmanifest.

.EXAMPLE
  ./Set-StoreIdentity.ps1 -Name 12345Fanficly.Fanficly -Publisher 'CN=0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9' -PublisherDisplayName 'Jenny Speelman'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Name,
  [Parameter(Mandatory)] [string] $Publisher,
  [Parameter(Mandatory)] [string] $PublisherDisplayName,
  [string] $Manifest = (Join-Path $PSScriptRoot '..' '..' 'src' 'Fanficly.App' 'Package.appxmanifest')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Name = $Name.Trim()
$Publisher = $Publisher.Trim()
$PublisherDisplayName = $PublisherDisplayName.Trim()

# The MSIX schema: 3-50 characters of letters, digits, dots and dashes.
if ($Name -cnotmatch '^[A-Za-z0-9.\-]{3,50}$') {
  throw "Name '$Name' isn't a valid package name (3-50 letters, digits, dots or dashes). Copy Package/Identity/Name from Partner Center > Product identity."
}
if (-not $Publisher.StartsWith('CN=', [System.StringComparison]::Ordinal)) {
  throw "Publisher must start with 'CN=' (got '$Publisher'). Copy Package/Identity/Publisher from Partner Center > Product identity."
}
if ($PublisherDisplayName.Length -eq 0) {
  throw 'PublisherDisplayName is empty. Copy Package/Properties/PublisherDisplayName from Partner Center > Product identity.'
}

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
$displayName = $doc.SelectSingleNode('/f:Package/f:Properties/f:PublisherDisplayName', $ns)
if ($null -eq $identity) { throw "No Package/Identity element in $manifestPath." }
if ($null -eq $displayName) { throw "No Package/Properties/PublisherDisplayName element in $manifestPath." }

$identity.SetAttribute('Name', $Name)
$identity.SetAttribute('Publisher', $Publisher)
$displayName.InnerText = $PublisherDisplayName

$settings = [System.Xml.XmlWriterSettings]::new()
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)
$settings.NewLineHandling = [System.Xml.NewLineHandling]::None
$writer = [System.Xml.XmlWriter]::Create($manifestPath, $settings)
try { $doc.Save($writer) } finally { $writer.Dispose() }

Write-Host "Package identity: Name=$Name Publisher=$Publisher PublisherDisplayName=$PublisherDisplayName"

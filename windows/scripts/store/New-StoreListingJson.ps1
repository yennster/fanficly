<#
.SYNOPSIS
  Builds the Microsoft Store listing JSON from windows/store/listing/.

.DESCRIPTION
  The Store listing lives in the repository as plain text, one folder per
  language (windows/store/listing/en-us/ ...), like fastlane's metadata
  folder. This script reads every language folder, checks each field
  against the Store's limits, and writes the JSON that
  `msstore submission updateMetadata` takes.

  Files read in each language folder:

    title.txt              Listing title (must be one of the app's reserved names)
    short_description.txt  Short description, at most 1,000 characters
    description.txt        Description, required, at most 10,000 characters
    features.txt           Product features, one per line: at most 20, 200 characters each
    keywords.txt           Search terms, one per line: at most 7, 40 characters each,
                           21 words in all, and none naming AO3 / Archive of Our Own
    release_notes.txt      What's new in this version, at most 1,500 characters
    copyright.txt          Copyright and trademark info, at most 200 characters
    privacy_policy_url.txt, website.txt, support_contact.txt
                           Checked (must be https URLs) but not sent: see the note below.

  In features.txt and keywords.txt, blank lines and lines starting with #
  are ignored. A missing optional file leaves that field as it is in the
  Store.

  Without -BaseSubmission the output is just the listings:
    { "listings": { "en-us": { "baseListing": { "title": ..., ... } } } }

  With -BaseSubmission (the JSON from `msstore submission get <productId>`)
  the listing fields are merged into that whole submission. Use this form
  for `msstore submission updateMetadata`: for MSIX apps the CLI sends the
  JSON as the complete submission, so it must carry everything else
  (packages, pricing, images) unchanged.

  Note: the privacy policy URL, website and support contact are set once in
  Partner Center (the privacy policy on the app's Properties page). The
  msstore CLI's submission model has no fields for them, so they're not
  part of this JSON; the files keep the values to paste.

.PARAMETER ListingRoot
  The folder holding one subfolder per language. Defaults to windows/store/listing.

.PARAMETER BaseSubmission
  Path to a submission JSON file (from `msstore submission get`) to merge into.

.PARAMETER ReleaseNotesOnly
  Only send the release notes; leave every other listing field as it is in
  the Store. Every field is still checked.

.PARAMETER OutFile
  Write the JSON here instead of to the output.

.EXAMPLE
  ./New-StoreListingJson.ps1
  # Checks the listing and prints the listings JSON.

.EXAMPLE
  msstore submission get $productId > submission.json
  ./New-StoreListingJson.ps1 -BaseSubmission submission.json -OutFile submission-update.json
  msstore submission updateMetadata $productId submission-update.json
#>
[CmdletBinding()]
param(
  [string] $ListingRoot = (Join-Path $PSScriptRoot '..' '..' 'store' 'listing'),
  [string] $BaseSubmission,
  [switch] $ReleaseNotesOnly,
  [string] $OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Store limits (Partner Center > Store listing).
$MaxDescription = 10000
$MaxShortDescription = 1000
$MaxReleaseNotes = 1500
$MaxFeatures = 20
$MaxFeatureLength = 200
$MaxKeywords = 7
$MaxKeywordLength = 40
$MaxKeywordWords = 21
$MaxCopyright = 200
$MaxTitle = 256

# Notes go to stderr so the JSON on stdout stays clean.
function Write-Note([string] $Message) { [Console]::Error.WriteLine($Message) }

function Read-Text([string] $Dir, [string] $File) {
  $path = Join-Path $Dir $File
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
  if ($null -eq $text) { return '' }
  return ($text -replace "`r`n", "`n").Trim()
}

function Read-Lines([string] $Dir, [string] $File) {
  $text = Read-Text $Dir $File
  if ($null -eq $text) { return }
  foreach ($line in $text.Split("`n")) {
    $line = $line.Trim()
    if ($line.Length -gt 0 -and -not $line.StartsWith('#')) { $line }
  }
}

function Set-JsonProperty($Object, [string] $Name, $Value) {
  # PSObject property lookup ignores case, so this updates "BaseListing"
  # from `msstore submission get` as well as "baseListing".
  $property = $Object.PSObject.Properties[$Name]
  if ($null -ne $property) { $property.Value = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-JsonProperty($Object, [string] $Name) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

if (-not (Test-Path -LiteralPath $ListingRoot -PathType Container)) {
  throw "Listing folder not found: $ListingRoot"
}

$problems = [System.Collections.Generic.List[string]]::new()
$listings = [ordered]@{}

$localeDirs = @(Get-ChildItem -LiteralPath $ListingRoot -Directory | Sort-Object Name)
if ($localeDirs.Count -eq 0) {
  throw "No language folders in $ListingRoot (expected e.g. $ListingRoot/en-us)."
}

foreach ($dir in $localeDirs) {
  $locale = $dir.Name.ToLowerInvariant()
  $where = "listing/$($dir.Name)"
  if ($locale -notmatch '^[a-z]{2,3}(-[a-z0-9]+)*$') {
    $problems.Add("$where`: '$($dir.Name)' isn't a language tag like en-us.")
    continue
  }

  $title = Read-Text $dir.FullName 'title.txt'
  $short = Read-Text $dir.FullName 'short_description.txt'
  $description = Read-Text $dir.FullName 'description.txt'
  $releaseNotes = Read-Text $dir.FullName 'release_notes.txt'
  $copyright = Read-Text $dir.FullName 'copyright.txt'
  $features = [string[]] @(Read-Lines $dir.FullName 'features.txt')
  $keywords = [string[]] @(Read-Lines $dir.FullName 'keywords.txt')
  $hasFeatures = Test-Path -LiteralPath (Join-Path $dir.FullName 'features.txt')
  $hasKeywords = Test-Path -LiteralPath (Join-Path $dir.FullName 'keywords.txt')

  if ([string]::IsNullOrEmpty($title)) { $problems.Add("$where/title.txt is missing or empty.") }
  elseif ($title.Length -gt $MaxTitle) { $problems.Add("$where/title.txt is $($title.Length) characters; the limit is $MaxTitle.") }

  if ([string]::IsNullOrEmpty($description)) { $problems.Add("$where/description.txt is missing or empty; the Store requires a description.") }
  elseif ($description.Length -gt $MaxDescription) { $problems.Add("$where/description.txt is $($description.Length) characters; the limit is $MaxDescription.") }

  if ($null -ne $short -and $short.Length -gt $MaxShortDescription) {
    $problems.Add("$where/short_description.txt is $($short.Length) characters; the limit is $MaxShortDescription.")
  }
  if ($null -ne $releaseNotes -and $releaseNotes.Length -gt $MaxReleaseNotes) {
    $problems.Add("$where/release_notes.txt is $($releaseNotes.Length) characters; the limit is $MaxReleaseNotes.")
  }
  if ($null -ne $copyright -and $copyright.Length -gt $MaxCopyright) {
    $problems.Add("$where/copyright.txt is $($copyright.Length) characters; the limit is $MaxCopyright.")
  }

  if ($features.Count -gt $MaxFeatures) {
    $problems.Add("$where/features.txt has $($features.Count) features; the limit is $MaxFeatures.")
  }
  foreach ($feature in $features) {
    if ($feature.Length -gt $MaxFeatureLength) {
      $problems.Add("$where/features.txt: '$feature' is $($feature.Length) characters; the limit is $MaxFeatureLength.")
    }
  }

  if ($keywords.Count -gt $MaxKeywords) {
    $problems.Add("$where/keywords.txt has $($keywords.Count) keywords; the limit is $MaxKeywords.")
  }
  $wordCount = 0
  foreach ($keyword in $keywords) {
    if ($keyword.Length -gt $MaxKeywordLength) {
      $problems.Add("$where/keywords.txt: '$keyword' is $($keyword.Length) characters; the limit is $MaxKeywordLength.")
    }
    # Keep search terms trademark-clean: describe AO3 in the description only.
    if ($keyword -match 'ao3|archive\s*of\s*our\s*own|archiveofourown') {
      $problems.Add("$where/keywords.txt: '$keyword' names AO3. Keep keywords trademark-clean (mention Archive of Our Own only descriptively, in the description).")
    }
    $wordCount += @($keyword -split '\s+' | Where-Object { $_ }).Count
  }
  if ($wordCount -gt $MaxKeywordWords) {
    $problems.Add("$where/keywords.txt has $wordCount words in all; the Store allows $MaxKeywordWords.")
  }

  foreach ($urlFile in 'privacy_policy_url.txt', 'website.txt', 'support_contact.txt') {
    $url = Read-Text $dir.FullName $urlFile
    if ($null -ne $url -and $url -notmatch '^https://\S+$') {
      $problems.Add("$where/$urlFile must be a single https:// URL (got '$url').")
    }
  }

  $baseListing = [ordered]@{}
  if (-not $ReleaseNotesOnly) {
    if ($title) { $baseListing['title'] = $title }
    if ($null -ne $short) { $baseListing['shortDescription'] = $short }
    if ($description) { $baseListing['description'] = $description }
    if ($hasFeatures) { $baseListing['features'] = $features }
    if ($hasKeywords) { $baseListing['keywords'] = $keywords }
    if ($null -ne $copyright) { $baseListing['copyrightAndTrademarkInfo'] = $copyright }
  }
  if ($null -ne $releaseNotes) { $baseListing['releaseNotes'] = $releaseNotes }
  $listings[$locale] = $baseListing
}

if ($problems.Count -gt 0) {
  $list = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
  throw "The Store listing in $ListingRoot breaks the Microsoft Store's limits:$([Environment]::NewLine)$list"
}

if ($BaseSubmission) {
  if (-not (Test-Path -LiteralPath $BaseSubmission)) {
    throw "Base submission not found: $BaseSubmission"
  }
  # Tolerate anything printed around the JSON (older CLI versions logged to stdout).
  $raw = Get-Content -LiteralPath $BaseSubmission -Raw -Encoding utf8
  $start = if ($raw) { $raw.IndexOf('{') } else { -1 }
  $end = if ($raw) { $raw.LastIndexOf('}') } else { -1 }
  if ($start -lt 0 -or $end -le $start) {
    throw "$BaseSubmission holds no JSON object. Is there a draft submission? (msstore submission get <productId>)"
  }
  $submission = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json

  if ($null -eq (Get-JsonProperty $submission 'pricing')) {
    Write-Note "Warning: the base submission has no Pricing; msstore submission updateMetadata will refuse it."
  }
  $submissionListings = Get-JsonProperty $submission 'listings'
  if ($null -eq $submissionListings) {
    $submissionListings = [pscustomobject]@{}
    Set-JsonProperty $submission 'Listings' $submissionListings
  }

  foreach ($locale in $listings.Keys) {
    $entry = Get-JsonProperty $submissionListings $locale
    if ($null -eq $entry) {
      Write-Note "Warning: the submission has no '$locale' listing yet; adding one. Partner Center may also want screenshots for it."
      $entry = [pscustomobject]@{}
      Set-JsonProperty $submissionListings $locale $entry
    }
    $base = Get-JsonProperty $entry 'baseListing'
    if ($null -eq $base) {
      $base = [pscustomobject]@{}
      Set-JsonProperty $entry 'BaseListing' $base
    }
    foreach ($field in $listings[$locale].Keys) {
      Set-JsonProperty $base $field $listings[$locale][$field]
    }
  }
  $result = $submission
}
else {
  $listingObjects = [ordered]@{}
  foreach ($locale in $listings.Keys) {
    $listingObjects[$locale] = [ordered]@{ baseListing = $listings[$locale] }
  }
  $result = [ordered]@{ listings = $listingObjects }
}

$json = $result | ConvertTo-Json -Depth 64
$locales = @($listings.Keys) -join ', '
if ($OutFile) {
  Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8NoBOM
  Write-Note "Store listing ($locales$(if ($ReleaseNotesOnly) { ', release notes only' })) written to $OutFile"
}
else {
  Write-Note "Store listing ($locales$(if ($ReleaseNotesOnly) { ', release notes only' })) is within the Store's limits."
  $json
}

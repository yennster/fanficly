<#
.SYNOPSIS
  Copies the UI tests' screenshots into the repository: every size to
  docs/screenshots/windows/<size>/, and the desktop set, renamed in listing
  order, to windows/store/screenshots/en-us/ (only pictures at least
  1366 x 768, the Store's minimum).
#>
param([Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $Repo)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$docs = Join-Path $Repo 'docs/screenshots/windows'
foreach ($size in 'desktop', 'tablet', 'compact') {
  $src = Join-Path $From $size
  if (-not (Test-Path $src)) { Write-Host "No $size screenshots."; continue }
  $dst = Join-Path $docs $size
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $src '*.png') $dst -Force
  Write-Host "${size}: $((Get-ChildItem $dst -Filter *.png).Count) screenshots"
}

# The Store listing, best first (at most 10).
$order = '03-reader', '02-search-results', '04-library', '05-browse', '10-popular',
         '07-reader-settings', '12-bookmarks', '06-recently-viewed', '09-tts', '08-privacy'
$captions = @{
  '03-reader' = 'A calm, distraction-free reader with themes, fonts and page-by-page mode'
  '02-search-results' = 'Search AO3 with live tag suggestions and exact filters'
  '04-library' = 'Your library, with reading progress, folders and offline downloads'
  '05-browse' = 'Browse every fandom in all ten AO3 categories'
  '10-popular' = 'See the most popular fandoms, ships and characters'
  '07-reader-settings' = 'Make reading yours: themes, fonts, spacing and profiles'
  '12-bookmarks' = 'Your AO3 bookmarks, including private ones'
  '06-recently-viewed' = 'Pick up anything you opened recently'
  '09-tts' = 'Listen to any story, read aloud on your PC'
  '08-privacy' = 'No accounts, no tracking: everything stays on your PC'
}
$store = Join-Path $Repo 'windows/store/screenshots/en-us'
$picked = @()
foreach ($name in $order) {
  $file = Join-Path $From "desktop/$name.png"
  if (-not (Test-Path $file)) { continue }
  $img = [System.Drawing.Image]::FromFile((Resolve-Path $file))
  $big = $img.Width -ge 1366 -and $img.Height -ge 768 -or $img.Width -ge 768 -and $img.Height -ge 1366
  $img.Dispose()
  if ($big) { $picked += $file } else { Write-Host "$name is smaller than the Store minimum; not used for the listing." }
}
if ($picked.Count -gt 0) {
  New-Item -ItemType Directory -Force -Path $store | Out-Null
  Get-ChildItem $store -Filter *.png | Remove-Item
  $i = 1
  $lines = @()
  foreach ($file in $picked) {
    Copy-Item $file (Join-Path $store ('{0:D2}-{1}' -f $i, (Split-Path $file -Leaf).Substring(3)))
    $lines += $captions[[IO.Path]::GetFileNameWithoutExtension($file)]
    $i++
  }
  Set-Content -Path (Join-Path $store 'captions.txt') -Value $lines -Encoding utf8
  Write-Host "Store listing: $($picked.Count) screenshots"
}

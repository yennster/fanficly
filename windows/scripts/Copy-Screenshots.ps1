<#
.SYNOPSIS
  Copies the UI tests' screenshots into the repository: every size to
  docs/screenshots/windows/<size>/. The Store listing is built from the
  "store" and "store-tablet" captures by scripts/make_store_art.py instead.
#>
param([Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $Repo)
$ErrorActionPreference = 'Stop'
$docs = Join-Path $Repo 'docs/screenshots/windows'
foreach ($size in 'desktop', 'tablet', 'compact') {
  $src = Join-Path $From $size
  if (-not (Test-Path $src)) { Write-Host "No $size screenshots."; continue }
  $dst = Join-Path $docs $size
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $src '*.png') $dst -Force
  Write-Host "${size}: $((Get-ChildItem $dst -Filter *.png).Count) screenshots"
}

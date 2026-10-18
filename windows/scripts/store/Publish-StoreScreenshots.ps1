<#
.SYNOPSIS
  Replaces the Store listing screenshots and Store art in the app's draft submission.

.DESCRIPTION
  The Microsoft Store Developer CLI (msstore) uploads packages and listing
  text but not listing images, so this script does that one job directly
  with the documented Microsoft Store submission API
  (https://manage.devcenter.microsoft.com/v1.0/my/...):

    1. Gets an Entra ID token for the Partner Center app (client credentials).
    2. Finds the app's draft (pending) submission. Create one first, for
       example with `msstore publish <package> -id <productId> --noCommit`.
    3. For each language folder in windows/store/screenshots/ that has PNGs,
       marks that language's current screenshots PendingDelete and adds the
       new ones (in file-name order, with captions from captions.txt). Store
       art in windows/store/images/<language>/, one PNG per image type
       (StoreLogoSquare.png, the 1:1 box art; StoreLogo9x16.png, the 2:3
       poster art; PromotionalArt16x9.png, the 16:9 hero image), replaces
       that type's image the same way.
    4. Updates the submission, zips the PNGs and uploads the zip to the
       submission's upload URL.

  It doesn't commit the submission: `msstore submission publish <productId>`
  (or Partner Center) does that.

  The draft's upload URL holds a single zip. If the draft has a package that
  is uploaded but not yet committed (as after `msstore publish --noCommit`),
  this upload would replace it, so pass the same package with -PackagePath:
  the script puts it in the zip next to the screenshots.

  Screenshots must be PNG, at least 1366 x 768 (landscape or portrait),
  under 50 MB, at most 10 per language; captions at most 200 characters.

.PARAMETER ScreenshotRoot
  The folder with one subfolder per language. Defaults to windows/store/screenshots.

.PARAMETER ArtRoot
  The Store art folder, one subfolder per language. Defaults to windows/store/images.

.PARAMETER Locale
  Only these languages (folder names, e.g. en-us). Defaults to every folder with PNGs.

.PARAMETER PackagePath
  The .msixupload (or a folder holding it) that is waiting in the draft.

.PARAMETER ProductId
  The Store ID of the app. Defaults to $env:STORE_PRODUCT_ID.

.PARAMETER TenantId
  Defaults to $env:AZURE_AD_TENANT_ID.

.PARAMETER ClientId
  Defaults to $env:AZURE_AD_APPLICATION_CLIENT_ID.

.PARAMETER ClientSecret
  Defaults to $env:AZURE_AD_APPLICATION_SECRET. Prefer the environment
  variable to typing the secret on the command line.

.EXAMPLE
  ./Publish-StoreScreenshots.ps1 -WhatIf
  # Checks the screenshots and shows what would change, without changing anything.

.EXAMPLE
  ./Publish-StoreScreenshots.ps1 -PackagePath ../../../artifacts/AppPackages
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $ScreenshotRoot = (Join-Path $PSScriptRoot '..' '..' 'store' 'screenshots'),
  [string] $ArtRoot = (Join-Path $PSScriptRoot '..' '..' 'store' 'images'),
  [string[]] $Locale,
  [string] $PackagePath,
  [string] $ProductId = $env:STORE_PRODUCT_ID,
  [string] $TenantId = $env:AZURE_AD_TENANT_ID,
  [string] $ClientId = $env:AZURE_AD_APPLICATION_CLIENT_ID,
  [string] $ClientSecret = $env:AZURE_AD_APPLICATION_SECRET
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Api = 'https://manage.devcenter.microsoft.com/v1.0/my'
$MaxScreenshots = 10
$MaxCaption = 200
$MaxBytes = 50MB
$MinLongSide = 1366
$MinShortSide = 768
# Store art: the submission API's image type, and the sizes Partner Center takes.
$ArtTypes = [ordered]@{
  StoreLogoSquare    = @('1080x1080', '2160x2160')   # 1:1 box art
  StoreLogo9x16      = @('720x1080', '1440x2160')    # 2:3 poster art
  PromotionalArt16x9 = @('1920x1080', '3840x2160')   # 16:9 hero image
}

function Get-JsonProperty($Object, [string] $Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Set-JsonProperty($Object, [string] $Name, $Value) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -ne $property) { $property.Value = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-PngSize([string] $Path) {
  # PNG: 8-byte signature, then the IHDR chunk with big-endian width and height.
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $header = [byte[]]::new(24)
    $read = $stream.Read($header, 0, 24)
  }
  finally { $stream.Dispose() }
  $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
  if ($read -lt 24) { return $null }
  for ($i = 0; $i -lt 8; $i++) { if ($header[$i] -ne $signature[$i]) { return $null } }
  $width = ([int]$header[16] -shl 24) -bor ([int]$header[17] -shl 16) -bor ([int]$header[18] -shl 8) -bor [int]$header[19]
  $height = ([int]$header[20] -shl 24) -bor ([int]$header[21] -shl 16) -bor ([int]$header[22] -shl 8) -bor [int]$header[23]
  return [pscustomobject]@{ Width = $width; Height = $height }
}

function Mask([string] $Value) {
  if ($env:GITHUB_ACTIONS -eq 'true' -and $Value) { Write-Host "::add-mask::$Value" }
}

# 1. Collect and check the screenshots.
if (-not (Test-Path -LiteralPath $ScreenshotRoot -PathType Container)) {
  throw "Screenshot folder not found: $ScreenshotRoot"
}
$problems = [System.Collections.Generic.List[string]]::new()
$sets = [ordered]@{}
foreach ($dir in @(Get-ChildItem -LiteralPath $ScreenshotRoot -Directory | Sort-Object Name)) {
  $lang = $dir.Name.ToLowerInvariant()
  if ($Locale -and ($Locale | ForEach-Object { $_.ToLowerInvariant() }) -notcontains $lang) { continue }
  $pngs = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.png' |
      Sort-Object -Property @{ Expression = { $_.Name }; Ascending = $true })
  if ($pngs.Count -eq 0) { continue }

  $captions = @()
  $captionFile = Join-Path $dir.FullName 'captions.txt'
  if (Test-Path -LiteralPath $captionFile) {
    $text = Get-Content -LiteralPath $captionFile -Raw -Encoding utf8
    if ($text) { $captions = @(($text -replace "`r`n", "`n").TrimEnd("`n").Split("`n")) }
  }
  if ($captions.Count -gt $pngs.Count) {
    $problems.Add("screenshots/$($dir.Name)/captions.txt has $($captions.Count) lines for $($pngs.Count) screenshots.")
  }
  if ($pngs.Count -gt $MaxScreenshots) {
    $problems.Add("screenshots/$($dir.Name) has $($pngs.Count) screenshots; the Store takes at most $MaxScreenshots.")
  }

  $shots = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt $pngs.Count; $i++) {
    $png = $pngs[$i]
    $where = "screenshots/$($dir.Name)/$($png.Name)"
    $caption = if ($i -lt $captions.Count) { $captions[$i].Trim() } else { '' }
    if ($caption.Length -gt $MaxCaption) {
      $problems.Add("$where caption is $($caption.Length) characters; the limit is $MaxCaption.")
    }
    if ($png.Length -ge $MaxBytes) {
      $problems.Add("$where is $([math]::Round($png.Length / 1MB, 1)) MB; the limit is 50 MB.")
    }
    $size = Get-PngSize $png.FullName
    if ($null -eq $size) {
      $problems.Add("$where isn't a PNG file.")
    }
    elseif ([math]::Max($size.Width, $size.Height) -lt $MinLongSide -or [math]::Min($size.Width, $size.Height) -lt $MinShortSide) {
      $problems.Add("$where is $($size.Width) x $($size.Height); desktop screenshots must be at least $MinLongSide x $MinShortSide.")
    }
    $shots.Add([pscustomobject]@{
        Path      = $png.FullName
        EntryName = "screenshots/$lang/$($png.Name)"
        Caption   = $caption
      })
  }
  $sets[$lang] = $shots
}

$art = [ordered]@{}
if (Test-Path -LiteralPath $ArtRoot -PathType Container) {
  foreach ($dir in @(Get-ChildItem -LiteralPath $ArtRoot -Directory | Sort-Object Name)) {
    $lang = $dir.Name.ToLowerInvariant()
    if ($Locale -and ($Locale | ForEach-Object { $_.ToLowerInvariant() }) -notcontains $lang) { continue }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $ArtTypes.Keys) {
      $file = Join-Path $dir.FullName "$type.png"
      if (-not (Test-Path -LiteralPath $file)) { continue }
      $size = Get-PngSize $file
      $where = "images/$($dir.Name)/$type.png"
      if ($null -eq $size) { $problems.Add("$where isn't a PNG file."); continue }
      if ($ArtTypes[$type] -notcontains "$($size.Width)x$($size.Height)") {
        $problems.Add("$where is $($size.Width) x $($size.Height); $type must be $($ArtTypes[$type] -join ' or ').")
      }
      $items.Add([pscustomobject]@{ Path = $file; EntryName = "images/$lang/$type.png"; Type = $type })
    }
    if ($items.Count -gt 0) { $art[$lang] = $items }
  }
}

if ($problems.Count -gt 0) {
  $list = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
  throw "The screenshots aren't ready for the Store:$([Environment]::NewLine)$list"
}
if ($sets.Count -eq 0 -and $art.Count -eq 0) {
  throw "No screenshots found. Put PNGs in $ScreenshotRoot/<language>/ (for example en-us/01-library.png)."
}
foreach ($lang in $sets.Keys) {
  Write-Host "$lang`: $($sets[$lang].Count) screenshot(s)"
  foreach ($shot in $sets[$lang]) {
    $suffix = if ($shot.Caption) { " - $($shot.Caption)" } else { '' }
    Write-Host "  $(Split-Path -Leaf $shot.Path)$suffix"
  }
}

foreach ($lang in $art.Keys) {
  Write-Host "$lang`: Store art $(($art[$lang] | ForEach-Object { $_.Type }) -join ', ')"
}

$credentials = [ordered]@{
  'ProductId (STORE_PRODUCT_ID)'                 = $ProductId
  'TenantId (AZURE_AD_TENANT_ID)'                = $TenantId
  'ClientId (AZURE_AD_APPLICATION_CLIENT_ID)'    = $ClientId
  'ClientSecret (AZURE_AD_APPLICATION_SECRET)'   = $ClientSecret
}
$missing = @($credentials.Keys | Where-Object { [string]::IsNullOrWhiteSpace($credentials[$_]) })
if ($missing.Count -gt 0) {
  if ($WhatIfPreference) {
    Write-Host "What if: the screenshots above would replace the Store listing's screenshots. (Partner Center credentials not set, so the draft submission wasn't checked.)"
    return
  }
  throw "Missing Partner Center credentials: $($missing -join ', '). See windows/MICROSOFT_STORE.md."
}

# 2. Sign in and find the draft submission.
Mask $ClientSecret
$tokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" `
  -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type    = 'client_credentials'
    client_id     = $ClientId
    client_secret = $ClientSecret
    resource      = 'https://manage.devcenter.microsoft.com'
  }
$token = Get-JsonProperty $tokenResponse 'access_token'
if (-not $token) { throw 'Partner Center sign-in returned no access token.' }
Mask $token
$headers = @{ Authorization = "Bearer $token" }

$app = Invoke-RestMethod -Method Get -Uri "$Api/applications/$ProductId" -Headers $headers
$pending = Get-JsonProperty $app 'pendingApplicationSubmission'
$submissionId = Get-JsonProperty $pending 'id'
if (-not $submissionId) {
  throw "App $ProductId has no draft submission. Create one first, for example: msstore publish <package.msixupload> -id $ProductId --noCommit"
}
$submissionUri = "$Api/applications/$ProductId/submissions/$submissionId"
$submission = Invoke-RestMethod -Method Get -Uri $submissionUri -Headers $headers
$status = Get-JsonProperty $submission 'status'
if ($status -ne 'PendingCommit') {
  throw "Submission $submissionId is '$status', not a draft (PendingCommit); its screenshots can't be changed."
}
Write-Host "Draft submission: $submissionId"

# 3. Swap the screenshots and art in each language's listing.
$listings = Get-JsonProperty $submission 'listings'
$languages = @(@($sets.Keys) + @($art.Keys) | Select-Object -Unique)
foreach ($lang in $languages) {
  $listing = Get-JsonProperty $listings $lang
  $baseListing = Get-JsonProperty $listing 'baseListing'
  if ($null -eq $baseListing) {
    throw "The draft has no '$lang' listing. Add that language in Partner Center (and to the package) first."
  }
  $newShots = if ($sets.Contains($lang)) { $sets[$lang] } else { @() }
  $newArt = if ($art.Contains($lang)) { $art[$lang] } else { @() }
  # Image types this run replaces: screenshots when there are new ones, and each art type supplied.
  $replacing = @(@($newArt | ForEach-Object { $_.Type }) + @(if ($newShots.Count -gt 0) { 'Screenshot' }))
  $images = [System.Collections.Generic.List[object]]::new()
  $removed = 0
  foreach ($image in @(Get-JsonProperty $baseListing 'images' | Where-Object { $null -ne $_ })) {
    if ($replacing -contains (Get-JsonProperty $image 'imageType')) {
      $removed++
      # Not uploaded yet (a retry within the same draft): just drop it.
      if ((Get-JsonProperty $image 'fileStatus') -eq 'PendingUpload') { continue }
      Set-JsonProperty $image 'fileStatus' 'PendingDelete'
    }
    $images.Add($image)
  }
  foreach ($shot in $newShots) {
    $image = [ordered]@{
      fileName   = $shot.EntryName
      fileStatus = 'PendingUpload'
      imageType  = 'Screenshot'
    }
    if ($shot.Caption) { $image['description'] = $shot.Caption }
    $images.Add([pscustomobject]$image)
  }
  foreach ($item in $newArt) {
    $images.Add([pscustomobject][ordered]@{ fileName = $item.EntryName; fileStatus = 'PendingUpload'; imageType = $item.Type })
  }
  Set-JsonProperty $baseListing 'images' $images.ToArray()
  Write-Host "$lang`: replacing $removed image(s) with $($newShots.Count) screenshot(s) and $($newArt.Count) Store art image(s)"
}

# 4. A package waiting in the draft rides in the same zip.
$zipEntries = [System.Collections.Generic.List[object]]::new()
foreach ($set in @($sets.Values) + @($art.Values)) { foreach ($shot in $set) { $zipEntries.Add(@{ Path = $shot.Path; Name = $shot.EntryName }) } }
$pendingPackages = @(Get-JsonProperty $submission 'applicationPackages' |
    Where-Object { $null -ne $_ -and (Get-JsonProperty $_ 'fileStatus') -eq 'PendingUpload' })
foreach ($package in $pendingPackages) {
  $fileName = [string](Get-JsonProperty $package 'fileName')
  $leaf = Split-Path -Leaf ($fileName -replace '\\', '/')
  if (-not $PackagePath) {
    throw "The draft has a package waiting for upload ($fileName). Pass it with -PackagePath so it goes in the same upload; otherwise this upload would replace it."
  }
  $candidate = if (Test-Path -LiteralPath $PackagePath -PathType Container) {
    Get-ChildItem -LiteralPath $PackagePath -Recurse -File -Filter $leaf | Select-Object -First 1
  }
  elseif ((Split-Path -Leaf $PackagePath) -eq $leaf) { Get-Item -LiteralPath $PackagePath }
  else { $null }
  if ($null -eq $candidate) {
    throw "The draft's package '$fileName' wasn't found at $PackagePath."
  }
  $zipEntries.Add(@{ Path = $candidate.FullName; Name = ($fileName -replace '\\', '/') })
  Write-Host "Package in the same upload: $fileName"
}

$target = "draft submission $submissionId of $ProductId"
if (-not $PSCmdlet.ShouldProcess($target, "Replace the listing screenshots and Store art ($($languages -join ', '))")) {
  return
}

# 5. Update the submission, then upload the zip.
$body = $submission | ConvertTo-Json -Depth 64
$updated = Invoke-RestMethod -Method Put -Uri $submissionUri -Headers $headers `
  -ContentType 'application/json; charset=utf-8' -Body $body
$uploadUrl = Get-JsonProperty $updated 'fileUploadUrl'
if (-not $uploadUrl) { $uploadUrl = Get-JsonProperty $submission 'fileUploadUrl' }
if (-not $uploadUrl) { throw 'The submission has no fileUploadUrl.' }
Mask $uploadUrl

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "fanficly-store-$([guid]::NewGuid().ToString('N')).zip"
try {
  $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($entry in $zipEntries) {
      # PNGs and MSIX are already compressed; store them as they are.
      [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive, $entry.Path, $entry.Name, [System.IO.Compression.CompressionLevel]::NoCompression)
    }
  }
  finally { $archive.Dispose() }

  try {
    Invoke-WebRequest -Method Put -Uri $uploadUrl -InFile $zipPath -ContentType 'application/octet-stream' `
      -Headers @{ 'x-ms-blob-type' = 'BlockBlob'; 'x-ms-version' = '2020-04-08' } | Out-Null
  }
  catch {
    # The upload URL carries a signature; don't let it reach the log.
    $code = $null
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    throw "Uploading the screenshot zip failed$(if ($code) { " (HTTP $code)" }). The draft lists the new screenshots but they aren't uploaded; run this script again."
  }
}
finally {
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue -WhatIf:$false
}

Write-Host "Screenshots uploaded to $target. Commit with: msstore submission publish $ProductId"

<#
.SYNOPSIS
  Fails unless every app package in the Store upload carries the files the app
  needs at run time but the build can silently leave out.

.DESCRIPTION
  Opens each .msixupload (or .msixbundle) under -Package, then each .msix inside,
  and checks for every name in -Required at the package root. msquic.dll is the
  reason this exists: Native AOT drops it with the runtime pack's other native
  files, and without it .NET has no HTTP/3, so the app falls back to HTTP/2, where
  AO3's edge answers with 525s (Fanficly.App.csproj puts it back).
#>
param(
    [Parameter(Mandatory)] [string] $Package,
    [string[]] $Required = @('msquic.dll')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Open-Zip([System.IO.Stream] $stream) {
    $memory = [System.IO.MemoryStream]::new()
    $stream.CopyTo($memory)
    $memory.Position = 0
    [System.IO.Compression.ZipArchive]::new($memory, [System.IO.Compression.ZipArchiveMode]::Read)
}

function Get-AppPackages([System.IO.Compression.ZipArchive] $zip, [string] $where) {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName
        if ($name -match '\.(msixbundle|appxbundle)$') {
            $inner = $entry.Open()
            try { Get-AppPackages (Open-Zip $inner) "$where > $name" } finally { $inner.Dispose() }
        }
        elseif ($name -match '\.(msix|appx)$') {
            $inner = $entry.Open()
            try { [pscustomobject]@{ Name = "$where > $name"; Zip = (Open-Zip $inner) } } finally { $inner.Dispose() }
        }
    }
}

$containers = @(Get-ChildItem $Package -Recurse -Include *.msixupload, *.msixbundle)
if ($containers.Count -eq 0) { throw "No .msixupload or .msixbundle under $Package." }

$checked = 0
$missing = @()
foreach ($file in $containers) {
    $stream = [System.IO.File]::OpenRead($file.FullName)
    try {
        $outer = Open-Zip $stream
        foreach ($app in @(Get-AppPackages $outer $file.Name)) {
            $checked++
            $names = @($app.Zip.Entries | ForEach-Object FullName)
            foreach ($required in $Required) {
                if ($names -notcontains $required) { $missing += "$($app.Name) has no $required" }
                else { Write-Host "$($app.Name): $required present" }
            }
        }
    }
    finally { $stream.Dispose() }
}

if ($checked -eq 0) { throw "Found no .msix inside the packages under $Package." }
if ($missing.Count -gt 0) {
    foreach ($line in $missing) { Write-Host "::error::$line" }
    exit 1
}
Write-Host "Checked $checked app package(s): every one has $($Required -join ', ')."

# Builds the release zip: dist\FragCut-v<version>.zip  (contains the FragCut\ folder)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'FragCut\Core.ps1')

# syntax-check every script before packaging
foreach ($f in Get-ChildItem (Join-Path $root 'FragCut') -Filter *.ps1) {
    $null = [ScriptBlock]::Create((Get-Content -LiteralPath $f.FullName -Raw))
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "FragCut-v$FragCutVersion.zip"
Compress-Archive -Path (Join-Path $root 'FragCut') -DestinationPath $zip -Force
Write-Host ("built {0}  ({1:N0} bytes)" -f $zip, (Get-Item $zip).Length)

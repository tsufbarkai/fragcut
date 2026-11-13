# Builds the release zip: dist\FragCut-v<version>.zip  (contains the FragCut\ folder)
# and the release notes:  dist\release-notes.md  (this version's section of CHANGELOG.md).
# Fails if CHANGELOG.md has no "## <version>" section, so a release never ships without notes.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'FragCut\Core.ps1')

# syntax-check every script before packaging
foreach ($f in Get-ChildItem (Join-Path $root 'FragCut') -Filter *.ps1) {
    $null = [ScriptBlock]::Create((Get-Content -LiteralPath $f.FullName -Raw))
}

# release notes = the lines under "## <version>" up to the next "## " heading
$lines = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Encoding UTF8
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^##\s+v?$([regex]::Escape($FragCutVersion))(\s|$)") { $start = $i + 1; break }
}
if ($start -lt 0) { throw "CHANGELOG.md has no '## $FragCutVersion' section - add one before releasing." }
$end = $lines.Count
for ($i = $start; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s') { $end = $i; break } }
$notes = ($lines[$start..($end - 1)] -join "`n").Trim()
if (-not $notes) { throw "CHANGELOG.md section '## $FragCutVersion' is empty." }
$notes += "`n`n---`n**Install / update:** download ``FragCut-v$FragCutVersion.zip`` below, unzip it and double-click ``Install.bat`` (updating over an older version is fine - your clips and settings stay). See the [README](https://github.com/tsufbarkai/fragcut#install) for details."

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
[IO.File]::WriteAllText((Join-Path $dist 'release-notes.md'), $notes, (New-Object Text.UTF8Encoding $false))
$zip = Join-Path $dist "FragCut-v$FragCutVersion.zip"
Compress-Archive -Path (Join-Path $root 'FragCut') -DestinationPath $zip -Force
Write-Host ("built {0}  ({1:N0} bytes)" -f $zip, (Get-Item $zip).Length)
Write-Host "release notes: dist\release-notes.md"
# for GitHub Actions: expose the version to later steps
if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$FragCutVersion" }

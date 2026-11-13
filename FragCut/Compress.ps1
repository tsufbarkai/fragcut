# FragCut Compress - make a video about half the size with little visible quality loss (H.264, plays everywhere).
# Usage: select one or more videos > right-click > Send to > FragCut - Compress  (or run with no files to pick them).
# Saves "<name> - compressed.mp4" next to the original. The original is never changed.
# Test switches: -NoOpen  -NoPause

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files,
    [switch]$NoOpen,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

function Done { if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null } }

function Get-CompressedPath($video) {
    $dir  = Split-Path $video -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($video) -replace '\.DVR$', ''
    $n = 1; $try = "$base - compressed"
    while (Test-Path -LiteralPath (Join-Path $dir "$try.mp4")) { $n++; $try = "$base - compressed ($n)" }
    return (Join-Path $dir "$try.mp4")
}

function Run-Compress($ffmpeg, $video, $out, $enc, $audioCopy) {
    $a = @('-hide_banner','-loglevel','error','-stats','-y','-i',$video,'-map','0:v:0','-map','0:a?')
    $a += Get-CompressArgs $enc
    $a += @('-pix_fmt','yuv420p')
    if ($audioCopy) { $a += @('-c:a','copy') } else { $a += @('-c:a','aac','-b:a','192k','-ar','48000','-ac','2') }
    $a += @('-movflags','+faststart',$out)
    & $ffmpeg @a
    return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 4KB)
}

try {
    $ffmpeg  = Find-Tool 'ffmpeg'
    $ffprobe = Find-Tool 'ffprobe'

    $Files = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if (-not $Files.Count) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Pick videos to compress'
        $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov;*.avi;*.webm|All files|*.*'
        $dlg.Multiselect = $true
        $dlg.InitialDirectory = Get-StartFolder
        if ($dlg.ShowDialog() -ne 'OK') { exit }
        $Files = $dlg.FileNames
    }
    $Files = @($Files | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    Save-LastFolder $Files[0]

    Write-Host ""
    Write-Host "FragCut $FragCutVersion - Compress" -ForegroundColor DarkGray
    $enc = Get-Encoder $ffmpeg
    Write-Host "Encoding on: $(Get-EncoderName $enc)"

    $last = $null
    foreach ($video in $Files) {
        $out = Get-CompressedPath $video
        $before = (Get-Item -LiteralPath $video).Length
        $acodec = (& $ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$video" | Select-Object -First 1)
        $audioCopy = ("$acodec".Trim() -eq 'aac')
        Write-Host ""
        Write-Host ("{0}  ({1:N1} MB)" -f (Split-Path $video -Leaf), ($before / 1MB)) -ForegroundColor Cyan

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ok = Run-Compress $ffmpeg $video $out $enc $audioCopy
        if (-not $ok -and $enc -ne 'libx264') {
            Write-Host '  GPU encoder failed, using CPU encoder (slower)...' -ForegroundColor Yellow
            Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
            $enc = 'libx264'; Reset-Encoder
            $ok = Run-Compress $ffmpeg $video $out $enc $audioCopy
        }
        if (-not $ok) { Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue; Write-Host '  FAILED' -ForegroundColor Red; continue }

        $after = (Get-Item -LiteralPath $out).Length
        if ($after -ge $before) {
            Remove-Item -LiteralPath $out
            Write-Host '  already well compressed - a smaller copy would not save anything, skipped.' -ForegroundColor Yellow
            continue
        }
        Write-Host ("  saved: {0}  ({1:N1} MB, {2:N0}% of the original, {3:N0} s)" -f (Split-Path $out -Leaf), ($after / 1MB), (100 * $after / $before), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        $last = $out
    }

    if ($last -and -not $NoOpen) { Show-InFolder $last }
}
catch { Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red }
Done

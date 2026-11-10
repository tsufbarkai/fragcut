# FragCut TimeCut - cut a clip (video+audio MP4) and an MP3 of the same part, by typing the times.
# Usage: right-click a video > Send to > FragCut - Cut by time, or drag a video onto TimeCut.bat.
#        (To mark while watching, use FragCut itself.)
# Time formats: 98   1:38   01:38   1:01:38   1:38.5   (empty end = until the end)

param([string]$Video, [switch]$NoOpen)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

try {
    $ffmpeg  = Find-Tool 'ffmpeg'
    $ffprobe = Find-Tool 'ffprobe'

    if (-not $Video -or -not (Test-Path -LiteralPath $Video)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Pick a video to cut'
        $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov;*.avi;*.webm|All files|*.*'
        $dlg.InitialDirectory = Get-StartFolder
        if ($dlg.ShowDialog() -ne 'OK') { exit }
        $Video = $dlg.FileName
    }

    $Video = (Resolve-Path -LiteralPath $Video).Path
    Save-LastFolder $Video
    $dur = Get-Duration $ffprobe $Video

    Write-Host ""
    Write-Host "FragCut $FragCutVersion - Cut by time" -ForegroundColor DarkGray
    Write-Host "Video : $(Split-Path $Video -Leaf)" -ForegroundColor Cyan
    Write-Host "Length: $(Fmt $dur)"

    $enc = Get-Encoder $ffmpeg
    Write-Host "Encoding on: $(Get-EncoderName $enc)"
    $last = $null
    do {
        while ($true) {
            Write-Host ""
            try {
                $start = Parse-Time (Read-Host 'Start (e.g. 1:38)')
                if ($null -eq $start) { $start = 0 }
                $end = Parse-Time (Read-Host 'End   (e.g. 1:43, empty = until the end)')
                if ($null -eq $end -or $end -gt $dur) { $end = $dur }
                if ($start -ge $dur) { throw 'start is past the end of the video' }
                if ($end -le $start) { throw 'end must be after start' }
                break
            } catch { Write-Host "  $($_.Exception.Message) - try again" -ForegroundColor Yellow }
        }

        $len = $end - $start
        $out = Get-SlicePaths $Video $start $end
        Write-Host "Cutting $(Fmt $start) -> $(Fmt $end)  ($([math]::Round($len,1)) s)..."

        & $ffmpeg @(Get-CutArgs $Video $start $len $out.Mp4 $enc)
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok -and $enc -ne 'libx264') {
            Write-Host '  GPU encoder failed, using CPU encoder...' -ForegroundColor Yellow
            $enc = 'libx264'; Reset-Encoder
            & $ffmpeg @(Get-CutArgs $Video $start $len $out.Mp4 $enc)
            $ok = ($LASTEXITCODE -eq 0)
        }
        if ($ok) { $last = $out.Mp4 } else { Write-Host '  Video clip failed.' -ForegroundColor Red }

        & $ffmpeg @(Get-Mp3Args $Video $start $len $out.Mp3)
        if ($LASTEXITCODE -ne 0) { Write-Host '  MP3 failed.' -ForegroundColor Red }

        foreach ($f in $out.Mp4, $out.Mp3) {
            if (Test-Path -LiteralPath $f) { Write-Host ("  saved: {0}  ({1:N1} MB)" -f (Split-Path $f -Leaf), ((Get-Item -LiteralPath $f).Length / 1MB)) -ForegroundColor Green }
        }

        $again = Read-Host "`nAnother clip from the same video? (y/N)"
    } while ($again -match '^(y|yes)$')

    if ($last -and -not $NoOpen) { Show-InFolder $last }
}
catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to close'
}

# FragCut Join - join several clips into one video, in the order you choose.
# Usage: select clips in Explorer > right-click > Send to > FragCut - Join clips  (or run with no files to pick them).
# Slices made by FragCut share the same format, so they are joined instantly with no quality
# loss. Clips with a different format (resolution, fps, codec) are re-encoded on the GPU instead.
# Test switches: -Order "2 1 3"  -Mp3 / -NoMp3  -NoOpen  -NoPause

[CmdletBinding(PositionalBinding = $false)]   # every file name goes into $Files, never into -Order
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files,
    [string]$Order,
    [switch]$Mp3,
    [switch]$NoMp3,
    [switch]$NoOpen,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

function Done { if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null } }

function Probe($ffprobe, $file) {
    $j = (& $ffprobe -v error -show_entries 'stream=codec_type,codec_name,profile,width,height,r_frame_rate,pix_fmt,sample_rate,channels:format=duration' -of json "$file") -join "`n" | ConvertFrom-Json
    $v = $j.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
    $a = $j.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1
    if (-not $v) { throw "no video stream in $(Split-Path $file -Leaf)" }
    $fps = 60.0
    if ($v.r_frame_rate -match '^(\d+)/(\d+)$' -and [int]$matches[2] -ne 0) { $fps = [double]$matches[1] / [double]$matches[2] }
    [pscustomobject]@{
        File     = $file
        Duration = [double]::Parse($j.format.duration, [Globalization.CultureInfo]::InvariantCulture)
        Width    = [int]$v.width
        Height   = [int]$v.height
        Fps      = $fps
        HasAudio = [bool]$a
        Key      = "$($v.codec_name)|$($v.profile)|$($v.width)x$($v.height)|$($v.r_frame_rate)|$($v.pix_fmt)|$($a.codec_name)|$($a.sample_rate)|$($a.channels)"
    }
}

try {
    $ffmpeg  = Find-Tool 'ffmpeg'
    $ffprobe = Find-Tool 'ffprobe'

    $list = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    if ($list.Count -lt 2) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Pick the clips to join (Ctrl+click to pick several)'
        $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov;*.avi;*.webm|All files|*.*'
        $dlg.Multiselect = $true
        if ($list.Count -eq 1) { $dlg.InitialDirectory = Split-Path $list[0] -Parent }
        else { $dlg.InitialDirectory = Get-StartFolder }
        if ($dlg.ShowDialog() -ne 'OK') { exit }
        $list = @($list + $dlg.FileNames | Select-Object -Unique)
    }
    if ($list.Count -lt 2) { Write-Host 'Pick at least 2 clips.' -ForegroundColor Yellow; Done; exit }

    # default order = file name, which for NVIDIA recordings is the recording date/time
    $list = @($list | Sort-Object { Split-Path $_ -Leaf })

    Write-Host "`nFragCut $FragCutVersion - Join" -ForegroundColor DarkGray
    Write-Host 'Clips (in recording order):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), (Split-Path $list[$i] -Leaf)) }

    while ($true) {
        $ans = if ($PSBoundParameters.ContainsKey('Order')) { $Order } else { Read-Host "`nEnter = keep this order, or type a new order (e.g. 3 1 2; leave numbers out to skip clips)" }
        if ($ans.Trim() -eq '') { break }
        $nums = @($ans -split '[\s,]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
        $bad = @($nums | Where-Object { $_ -lt 1 -or $_ -gt $list.Count })
        if ($bad.Count -or $nums.Count -lt 2 -or (@($nums | Select-Object -Unique).Count -ne $nums.Count)) {
            Write-Host "  Use each number from 1 to $($list.Count) at most once, at least 2 clips." -ForegroundColor Yellow
            if ($PSBoundParameters.ContainsKey('Order')) { throw 'bad -Order' }
            continue
        }
        $list = @($nums | ForEach-Object { $list[$_ - 1] })
        break
    }

    Write-Host "`nJoining:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), (Split-Path $list[$i] -Leaf)) }

    $wantMp3 = $Mp3.IsPresent
    if (-not $Mp3 -and -not $NoMp3) { $wantMp3 = (Read-Host "`nAlso save an MP3 of the whole thing? (y/N)") -match '^(y|yes)$' }

    $info = @($list | ForEach-Object { Probe $ffprobe $_ })
    $same = (@($info.Key | Select-Object -Unique).Count -eq 1) -and -not (@($info | Where-Object { -not $_.HasAudio }).Count)

    # output name: first clip's recording name + " - montage"
    $dir  = Split-Path $list[0] -Parent
    $base = ([IO.Path]::GetFileNameWithoutExtension($list[0]) -replace '\.DVR$', '') -replace ' - clip .*$', ''
    $name = "$base - montage"; $n = 1; $try = $name
    while (Test-Path -LiteralPath (Join-Path $dir "$try.mp4")) { $n++; $try = "$name ($n)" }
    $out = Join-Path $dir "$try.mp4"

    $total = ($info | Measure-Object Duration -Sum).Sum
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ($same) {
        Write-Host "`nSame format - joining without re-encoding ($(Short $total) total)..."
        $txt = Join-Path $env:TEMP "fragcut-join-$PID.txt"
        $lines = $list | ForEach-Object { "file '" + ($_ -replace "'", "'\''") + "'" }
        [IO.File]::WriteAllLines($txt, $lines, (New-Object Text.UTF8Encoding($false)))
        & $ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $txt -c copy -movflags +faststart "$out"
        $ok = ($LASTEXITCODE -eq 0)
        Remove-Item $txt -ErrorAction SilentlyContinue
    } else {
        # different formats: scale everything to the biggest clip, same fps, and re-encode
        $big = $info | Sort-Object { $_.Width * $_.Height } -Descending | Select-Object -First 1
        $W = $big.Width; $H = $big.Height
        $F = [math]::Round(($info | Measure-Object Fps -Maximum).Maximum, 3).ToString([Globalization.CultureInfo]::InvariantCulture)
        Write-Host "`nClips have different formats - re-encoding to ${W}x${H} @ $F fps ($(Short $total) total)..."
        $in = @(); $fc = ''; $cat = ''
        for ($i = 0; $i -lt $info.Count; $i++) {
            $in += @('-i', $info[$i].File)
            $fc += "[${i}:v]scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$F,format=yuv420p[v$i];"
            if ($info[$i].HasAudio) { $fc += "[${i}:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$i];" }
            else { $d = $info[$i].Duration.ToString([Globalization.CultureInfo]::InvariantCulture); $fc += "anullsrc=r=48000:cl=stereo,atrim=duration=$d[a$i];" }
            $cat += "[v$i][a$i]"
        }
        $fc += "${cat}concat=n=$($info.Count):v=1:a=1[v][a]"
        $common = @('-hide_banner','-loglevel','error','-stats','-y') + $in + @('-filter_complex',$fc,'-map','[v]','-map','[a]')
        $enc = Get-Encoder $ffmpeg
        Write-Host "  encoding on: $(Get-EncoderName $enc)"
        & $ffmpeg @common @(Get-VideoEncArgs $enc) -c:a aac -b:a 192k -movflags +faststart "$out"
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok -and $enc -ne 'libx264') {
            Reset-Encoder
            Write-Host '  GPU encoder failed, using CPU encoder...' -ForegroundColor Yellow
            & $ffmpeg @common -c:v libx264 -preset medium -crf 18 -c:a aac -b:a 192k -movflags +faststart "$out"
            $ok = ($LASTEXITCODE -eq 0)
        }
    }

    if (-not $ok) { Write-Host '  Join failed.' -ForegroundColor Red; Done; exit 1 }
    Write-Host ("  saved: {0}  ({1:N1} MB, {2:N1} s)" -f (Split-Path $out -Leaf), ((Get-Item -LiteralPath $out).Length / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green

    if ($wantMp3) {
        $mp3File = [IO.Path]::ChangeExtension($out, '.mp3')
        & $ffmpeg -hide_banner -loglevel error -y -i "$out" -vn -c:a libmp3lame -b:a 320k "$mp3File"
        if ($LASTEXITCODE -eq 0) { Write-Host "  saved: $(Split-Path $mp3File -Leaf)" -ForegroundColor Green } else { Write-Host '  MP3 failed.' -ForegroundColor Red }
    }

    if (-not $NoOpen) { Show-InFolder $out }
    if (-not $NoPause) { Start-Sleep -Seconds 2 }
}
catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    Done
}

# FragCut - shared helpers (dot-sourced by FragCut.ps1, Join.ps1, TimeCut.ps1, Compress.ps1 and KillScan.ps1).
# https://github.com/tsufbarkai/fragcut

$FragCutVersion = '1.6.0'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:SettingsFile = Join-Path $env:LOCALAPPDATA 'FragCut\settings.json'

# ---------- tools ----------
function Find-Tool($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $f = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    throw "$name not found. Install it with:  winget install Gyan.FFmpeg.Essentials   (then reopen FragCut)"
}

# ---------- settings ----------
function Get-Settings {
    try { return (Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
}
function Set-Setting($name, $value) {
    $s = Get-Settings
    $s | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    try {
        New-Item -ItemType Directory -Force (Split-Path $script:SettingsFile) | Out-Null
        $s | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {}
}

# ---------- time helpers ----------
function Parse-Time([string]$s) {
    $s = $s.Trim()
    if ($s -eq '') { return $null }
    $parts = $s -split ':'
    if ($parts.Count -gt 3) { throw "bad time '$s'" }
    $sec = 0.0
    foreach ($p in $parts) {
        $v = 0.0
        if (-not [double]::TryParse($p, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { throw "bad time '$s'" }
        $sec = $sec * 60 + $v
    }
    return $sec
}

# 98.4 -> "01m38" (used in file names)
function Label([double]$sec) {
    $t = [TimeSpan]::FromSeconds([math]::Floor($sec))
    if ($t.Hours -gt 0) { return '{0}h{1:00}m{2:00}' -f $t.Hours, $t.Minutes, $t.Seconds }
    return '{0:00}m{1:00}' -f [math]::Floor($t.TotalMinutes), $t.Seconds
}

# 98.4 -> "00:01:38.400" (ffmpeg time)
function Fmt([double]$sec) { [TimeSpan]::FromSeconds($sec).ToString('hh\:mm\:ss\.fff') }

# 98.4 -> "1:38.4" (display)
function Short([double]$sec) {
    $t = [TimeSpan]::FromSeconds($sec)
    if ($t.Hours -gt 0) { return '{0}:{1:00}:{2:00}.{3}' -f $t.Hours, $t.Minutes, $t.Seconds, [math]::Floor($t.Milliseconds / 100) }
    return '{0}:{1:00}.{2}' -f [math]::Floor($t.TotalMinutes), $t.Seconds, [math]::Floor($t.Milliseconds / 100)
}

function Get-Duration($ffprobe, $file) {
    $s = & $ffprobe -v error -show_entries format=duration -of csv=p=0 "$file"
    return [double]::Parse(($s | Select-Object -First 1).Trim(), $script:Inv)
}

# ---------- folders ----------
# Where the "pick a video" dialog starts: last used folder, else the usual recording folders.
function Get-StartFolder {
    $last = (Get-Settings).LastFolder
    if ($last -and (Test-Path -LiteralPath $last)) { return $last }
    $vid = [Environment]::GetFolderPath('MyVideos')
    foreach ($c in "$vid\NVIDIA", "$vid\Captures", "$vid\Radeon ReLive", "$vid\Radeon", 'D:\Videos\NVIDIA', 'D:\Videos', $vid) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $vid
}
function Save-LastFolder($file) { try { Set-Setting 'LastFolder' (Split-Path $file -Parent) } catch {} }

# ---------- encoding ----------
# Pick the fastest working H.264 encoder once (NVIDIA > AMD > Intel > CPU) and remember it.
# Each one is tried with the exact settings clips use (mode 0). If a driver rejects those, a plain capped-bitrate
# version is tried (mode 1) before moving on to the next encoder.
function Get-Encoder($ffmpeg) {
    $s = Get-Settings
    if ($s.Encoder -and $s.EncoderVersion -eq $FragCutVersion) { return $s.Encoder }
    $pick = 'libx264'; $mode = 0
    :found foreach ($e in 'h264_nvenc', 'h264_amf', 'h264_qsv') {
        foreach ($m in 0, 1) {
            $a = @('-hide_banner','-loglevel','quiet','-f','lavfi','-i','testsrc2=s=1280x720:r=60','-frames:v','10') + (Get-VideoEncArgs $e -Cap 20e6 -Mode $m) + @('-pix_fmt','yuv420p','-f','null','-')
            & $ffmpeg @a 2>$null
            if ($LASTEXITCODE -eq 0) { $pick = $e; $mode = $m; break found }
        }
    }
    Set-Setting 'Encoder' $pick
    Set-Setting 'EncoderMode' $mode
    Set-Setting 'EncoderVersion' $FragCutVersion
    return $pick
}
function Reset-Encoder { Set-Setting 'Encoder' $null }
function Get-EncoderMode { $m = (Get-Settings).EncoderMode; if ($null -eq $m) { return 0 }; return [int]$m }

# Settings per encoder: quality-based where the encoder has it, never above $Cap bits/s (see Get-SourceCap).
# The H.264 level is fixed (5.2: up to 4K60), so clips with different caps still join without re-encoding.
function Get-VideoEncArgs([string]$enc, [switch]$Gentle, [double]$Cap = 40e6, [int]$Mode = -1) {
    if ($Mode -lt 0) { $Mode = Get-EncoderMode }
    $max = '{0}k' -f [int]($Cap / 1000); $avg = '{0}k' -f [int]($Cap * 0.75 / 1000); $buf = '{0}k' -f [int]($Cap * 2 / 1000)
    switch ($enc) {
        'h264_nvenc' {
            if ($Mode -eq 1) { return @('-c:v','h264_nvenc','-b:v',$avg,'-maxrate',$max,'-bufsize',$buf) }
            return @('-c:v','h264_nvenc','-preset',$(if ($Gentle) { 'p4' } else { 'p7' }),'-tune','hq','-rc','vbr','-cq','19','-b:v',$avg,'-maxrate',$max,'-bufsize',$buf,'-profile:v','high','-level','5.2')
        }
        'h264_amf' {
            if ($Mode -eq 1) { return @('-c:v','h264_amf','-b:v',$avg,'-maxrate',$max) }
            return @('-c:v','h264_amf','-quality','quality','-rc','vbr_peak','-b:v',$avg,'-maxrate',$max,'-bufsize',$buf,'-profile:v','high','-level','5.2')
        }
        'h264_qsv' {
            if ($Mode -eq 1) { return @('-c:v','h264_qsv','-b:v',$avg,'-maxrate',$max) }
            return @('-c:v','h264_qsv','-preset','slower','-b:v',$avg,'-maxrate',$max,'-bufsize',$buf,'-profile:v','high','-level','52')
        }
        default { return @('-c:v','libx264','-preset','medium','-crf','18','-maxrate',$max,'-bufsize',$max,'-profile:v','high','-level','5.2') }   # 1 s buffer: short clips stay under the cap too
    }
}

# How many bits/s a clip of this recording may use: up to 1.5x the recording's video bitrate for AV1/HEVC/VP9
# (H.264 needs more bits for the same picture) and 1.2x for H.264, always between 6 and 40 Mbit/s. Cached per file.
# Measured on a 1440p60 AV1 recording (22 Mbit/s) cut with NVENC: VMAF 95.1 at 1x, 97.9 at 1.5x, 98.8 at 1.8x.
$script:CapCache = @{}
function Get-SourceCap($video) {
    if ($script:CapCache.ContainsKey($video)) { return $script:CapCache[$video] }
    $cap = 40e6
    try {
        if (-not $script:Ffprobe) { $script:Ffprobe = Find-Tool 'ffprobe' }
        $v = (& $script:Ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,bit_rate -of csv=p=0 "$video" | Select-Object -First 1).Split(',')
        $codec = $v[0].Trim(); $br = 0.0
        if ($v.Count -gt 1 -and $v[1] -match '^\d+$') { $br = [double]$v[1] }
        if ($br -le 0) {                                                # MKV etc. don't store it per stream
            $fmt = (& $script:Ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$video" | Select-Object -First 1)
            if ("$fmt".Trim() -match '^\d+$') { $br = [double]$fmt - 200e3 }
        }
        if ($br -gt 0) {
            $factor = switch ($codec) { 'h264' { 1.2 } { $_ -in 'hevc','av1','vp9' } { 1.5 } default { 1.0 } }
            $cap = [math]::Max(6e6, [math]::Min(40e6, $br * $factor))
        }
    } catch {}
    $script:CapCache[$video] = $cap
    return $cap
}

# Smaller-file settings for Compress (H.264 so it plays everywhere). Tested on a 1440p60 BF6 montage
# with the NVIDIA encoder: about half the size, VMAF ~93 vs. the original (hard to tell apart when playing).
function Get-CompressArgs([string]$enc) {
    switch ($enc) {
        'h264_nvenc' { return @('-c:v','h264_nvenc','-preset','p7','-tune','hq','-rc','vbr','-cq','30','-b:v','0','-spatial-aq','1','-temporal-aq','1','-bf','3') }
        'h264_amf'   { return @('-c:v','h264_amf','-quality','quality','-rc','cqp','-qp_i','28','-qp_p','30','-qp_b','32') }
        'h264_qsv'   { return @('-c:v','h264_qsv','-preset','slower','-global_quality','29') }
        default      { return @('-c:v','libx264','-preset','medium','-crf','25') }
    }
}

function Get-EncoderName([string]$enc) {
    switch ($enc) { 'h264_nvenc' { 'NVIDIA GPU' } 'h264_amf' { 'AMD GPU' } 'h264_qsv' { 'Intel GPU' } default { 'CPU' } }
}

# Output paths for a slice: "<name> - clip 01m38-01m43.mp4" (+ .mp3). Adds " (2)" etc. if it already exists.
function Get-SlicePaths($video, [double]$start, [double]$end) {
    $dir  = Split-Path $video -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($video) -replace '\.DVR$', ''
    $name = "$base - clip $(Label $start)-$(Label $end)"
    $n = 1; $try = $name
    while (Test-Path -LiteralPath (Join-Path $dir "$try.mp4")) { $n++; $try = "$name ($n)" }
    return @{ Mp4 = (Join-Path $dir "$try.mp4"); Mp3 = (Join-Path $dir "$try.mp3") }
}

# OBS shares the graphics card's video encoder. While it runs, slices are cut "gently" so its recording doesn't drop frames.
function Test-ObsRunning { return [bool](Get-Process -Name 'obs64','obs32','obs' -ErrorAction SilentlyContinue) }

# -Gentle: lighter preset (NVIDIA p4: ~same size/quality, ~2x less encoder time) and paced to 1.5x real time,
# which leaves room on the video encoder for OBS. Slices still join losslessly with normal ones.
# -Cap: bits/s limit for the clip; 0 = from the recording (Get-SourceCap)
function Get-CutArgs($video, [double]$start, [double]$len, $mp4, [string]$enc, [switch]$Gentle, [double]$Cap = 0) {
    if ($Cap -le 0) { $Cap = Get-SourceCap $video }
    $a = @('-hide_banner','-loglevel','error','-y','-ss',(Fmt $start),'-i',$video,'-t',(Fmt $len))
    if ($Gentle) { $a += @('-vf','realtime=speed=1.5') }
    $a += Get-VideoEncArgs $enc -Gentle:$Gentle -Cap $Cap
    $a += @('-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-ac','2','-movflags','+faststart',$mp4)
    return $a
}

# ---------- fast cut: copy the video as it is, no re-encoding ----------
# A copied clip can only start on a keyframe (a full picture; recordings have one every 0.5-2 s, OBS up to 10 s),
# so FragCut moves the start back to the keyframe at or before the mark. The end can be anywhere.
# Keyframe times are read with ffprobe in 30-second chunks and remembered.
$script:KeyChunks = @{}
$script:KeyChunk = 30.0
function Get-KeyChunk($video, [int]$n) {
    $id = "$video|$n"
    if ($script:KeyChunks.ContainsKey($id)) { return $script:KeyChunks[$id] }
    if (-not $script:FfprobeExe) { $script:FfprobeExe = Find-Tool 'ffprobe' }
    $from = $n * $script:KeyChunk; $to = $from + $script:KeyChunk + 0.1
    $iv = '{0}%{1}' -f $from.ToString('0.###', $script:Inv), $to.ToString('0.###', $script:Inv)
    $keys = New-Object System.Collections.Generic.List[double]
    foreach ($l in (& $script:FfprobeExe -v quiet -select_streams v:0 -read_intervals $iv -show_entries packet=pts_time,flags -of csv=p=0 "$video")) {
        $p = "$l" -split ','
        $x = 0.0
        if ($p.Count -ge 2 -and $p[1].StartsWith('K') -and [double]::TryParse($p[0], [Globalization.NumberStyles]::Float, $script:Inv, [ref]$x)) { $keys.Add($x) }
    }
    $arr = @($keys | Sort-Object -Unique)
    $script:KeyChunks[$id] = $arr
    return $arr
}
# The keyframe at or before $t (0 if none found).
function Get-KeyframeBefore($video, [double]$t) {
    for ($n = [int][math]::Floor([math]::Max(0.0, $t) / $script:KeyChunk); $n -ge 0; $n--) {
        $k = @(Get-KeyChunk $video $n | Where-Object { $_ -le $t + 0.002 })
        if ($k.Count) { return [math]::Max(0.0, $k[-1]) }
    }
    return 0.0
}
# The first keyframe after $t, or $null if there is none before $limit.
function Get-KeyframeAfter($video, [double]$t, [double]$limit) {
    for ($n = [int][math]::Floor([math]::Max(0.0, $t) / $script:KeyChunk); $n * $script:KeyChunk -lt $limit; $n++) {
        $k = @(Get-KeyChunk $video $n | Where-Object { $_ -gt $t + 0.002 -and $_ -lt $limit })
        if ($k.Count) { return $k[0] }
        if ($n -gt 1000) { break }
    }
    return $null
}

$script:CodecCache = @{}
function Get-Codecs($video) {
    if ($script:CodecCache.ContainsKey($video)) { return $script:CodecCache[$video] }
    if (-not $script:FfprobeExe) { $script:FfprobeExe = Find-Tool 'ffprobe' }
    $v = "$(& $script:FfprobeExe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$video" | Select-Object -First 1)".Trim()
    $a = "$(& $script:FfprobeExe -v quiet -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$video" | Select-Object -First 1)".Trim()
    $c = @{ Video = $v; Audio = $a }
    $script:CodecCache[$video] = $c
    return $c
}

# $start should be a keyframe (Get-KeyframeBefore); ffmpeg starts the copy at the keyframe at or before it anyway.
# Seeking 1 ms past the keyframe makes sure ffmpeg lands on that keyframe and not the one before.
function Get-CopyCutArgs($video, [double]$start, [double]$len, $mp4) {
    $c = Get-Codecs $video
    $ss = $start + 0.001
    $a = @('-hide_banner','-loglevel','error','-y','-ss',$ss.ToString('0.######', $script:Inv),'-i',$video,'-t',[math]::Max(0.05, $len - 0.001).ToString('0.######', $script:Inv),
           '-map','0:v:0','-map','0:a:0?','-c:v','copy')
    if ($c.Video -eq 'hevc') { $a += @('-tag:v','hvc1') }
    if ($c.Audio -in 'aac','mp3','opus','ac3','eac3','flac','alac') { $a += @('-c:a','copy') }
    else { $a += @('-c:a','aac','-b:a','192k','-ar','48000','-ac','2') }
    $a += @('-avoid_negative_ts','make_zero','-movflags','+faststart',$mp4)
    return $a
}

# ---------- preview copy ----------
# FragCut's player is Windows' built-in one, which can't play some recordings (AV1, HEVC without its extension ...).
# Then FragCut plays an H.264 copy instead (at most 1080p, same frame rate). Cuts, kill search and joins still use the original.
$script:PreviewDir = Join-Path $env:LOCALAPPDATA 'FragCut\preview'
$script:PreviewKeep = 8          # previews kept (newest first)

function Get-PreviewPath($video) {
    $f = Get-Item -LiteralPath $video
    $key = '{0}|{1}|{2}' -f $f.FullName.ToLowerInvariant(), $f.Length, $f.LastWriteTimeUtc.Ticks
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') })
    return Join-Path $script:PreviewDir "$h.mp4"
}

# $info: codec, width, height (ffprobe). $mode: 0 = all on the NVIDIA GPU (decode, scale, encode), 1 = GPU decode via DirectX
# (any GPU), 2 = CPU only. Tried in that order. ffmpeg's default AV1 decoder (libaom) is very slow and can't use the GPU,
# so for AV1 its own decoder is named in modes 0 and 1.
function Get-PreviewArgs($video, $out, [string]$enc, $progress, $info, [int]$mode) {
    if ($mode -eq 2) { $enc = 'libx264' }
    $w = [int]$info.Width; $h = [int]$info.Height
    $scale = $h -gt 1080 -and $w -gt 0
    if ($scale) { $w = [int]([math]::Round($w * 1080.0 / $h / 2) * 2); $h = 1080 }
    $a = @('-hide_banner','-loglevel','error','-nostats','-y','-progress',$progress)
    if ($mode -eq 0) { $a += @('-hwaccel','cuda','-hwaccel_output_format','cuda') }
    if ($mode -eq 1) { $a += @('-hwaccel','d3d11va') }
    if ($mode -lt 2 -and $info.Codec -eq 'av1') { $a += @('-c:v','av1') }
    $a += @('-i',$video,'-map','0:v:0','-map','0:a:0?')
    if ($mode -eq 0) { if ($scale) { $a += @('-vf',"scale_cuda=${w}:${h}:interp_algo=bilinear") } }
    elseif ($scale)  { $a += @('-vf',"scale=${w}:${h}:flags=bilinear",'-pix_fmt','yuv420p') }
    else             { $a += @('-pix_fmt','yuv420p') }
    $v = switch ($enc) {
        'h264_nvenc' { @('-c:v','h264_nvenc','-preset','p1','-rc','vbr','-cq','28','-b:v','6M','-maxrate','10M','-bufsize','20M') }
        'h264_amf'   { @('-c:v','h264_amf','-quality','speed','-rc','vbr_peak','-b:v','6M','-maxrate','10M') }
        'h264_qsv'   { @('-c:v','h264_qsv','-preset','veryfast','-b:v','6M','-maxrate','10M') }
        default      { @('-c:v','libx264','-preset','veryfast','-crf','26','-maxrate','10M','-bufsize','20M') }
    }
    $a += $v
    $a += @('-g','30','-bf','0','-c:a','aac','-b:a','160k','-ar','48000','-ac','2','-movflags','+faststart','-f','mp4',$out)
    return $a
}

# keep only the newest previews
function Remove-OldPreviews {
    try {
        Get-ChildItem -LiteralPath $script:PreviewDir -Filter '*.mp4' -ErrorAction Stop | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $script:PreviewKeep | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Get-Mp3Args($video, [double]$start, [double]$len, $mp3) {
    return @('-hide_banner','-loglevel','error','-y','-ss',(Fmt $start),'-i',$video,'-t',(Fmt $len),'-vn','-c:a','libmp3lame','-b:a','320k',$mp3)
}

# Quote one argument for a Windows command line.
function Quote-Arg([string]$a) {
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Show a file in Explorer. If a window already shows that folder, select the file there instead of opening another.
function Show-InFolder($file) {
    if (-not (Test-Path -LiteralPath $file)) { return }
    $dir = Split-Path $file -Parent
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            try {
                $p = $w.Document.Folder.Self.Path
                if ($p -and ($p.TrimEnd('\') -ieq $dir.TrimEnd('\'))) {
                    $item = $w.Document.Folder.ParseName((Split-Path $file -Leaf))
                    if ($item) { $w.Document.SelectItem($item, 1 + 4 + 8 + 16) }
                    try {
                        Add-Type -Namespace FC -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);' -ErrorAction SilentlyContinue
                        [FC.W]::ShowWindow([IntPtr]$w.HWND, 9) | Out-Null
                        [FC.W]::SetForegroundWindow([IntPtr]$w.HWND) | Out-Null
                    } catch {}
                    return
                }
            } catch {}
        }
    } catch {}
    Start-Process explorer.exe "/select,`"$file`""
}

# FragCut - shared helpers (dot-sourced by FragCut.ps1, Join.ps1, TimeCut.ps1 and Compress.ps1).
# https://github.com/tsufbarkai/fragcut

$FragCutVersion = '1.2.0'
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
function Get-Encoder($ffmpeg) {
    $s = Get-Settings
    if ($s.Encoder -and $s.EncoderVersion -eq $FragCutVersion) { return $s.Encoder }
    $pick = 'libx264'
    foreach ($e in 'h264_nvenc', 'h264_amf', 'h264_qsv') {
        & $ffmpeg -hide_banner -loglevel quiet -f lavfi -i 'color=c=black:s=1280x720:r=30' -frames:v 5 -c:v $e -f null - 2>$null
        if ($LASTEXITCODE -eq 0) { $pick = $e; break }
    }
    Set-Setting 'Encoder' $pick
    Set-Setting 'EncoderVersion' $FragCutVersion
    return $pick
}
function Reset-Encoder { Set-Setting 'Encoder' $null }

# High-quality settings per encoder. All slices from one PC use the same encoder,
# so Join can stitch them without re-encoding.
function Get-VideoEncArgs([string]$enc) {
    switch ($enc) {
        'h264_nvenc' { return @('-c:v','h264_nvenc','-preset','p7','-tune','hq','-rc','vbr','-cq','19','-b:v','28M','-maxrate','40M','-bufsize','56M') }
        'h264_amf'   { return @('-c:v','h264_amf','-quality','quality','-rc','cqp','-qp_i','18','-qp_p','20','-qp_b','22') }
        'h264_qsv'   { return @('-c:v','h264_qsv','-preset','slower','-global_quality','20') }
        default      { return @('-c:v','libx264','-preset','medium','-crf','18') }
    }
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

function Get-CutArgs($video, [double]$start, [double]$len, $mp4, [string]$enc) {
    $a = @('-hide_banner','-loglevel','error','-y','-ss',(Fmt $start),'-i',$video,'-t',(Fmt $len))
    $a += Get-VideoEncArgs $enc
    $a += @('-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-ac','2','-movflags','+faststart',$mp4)
    return $a
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

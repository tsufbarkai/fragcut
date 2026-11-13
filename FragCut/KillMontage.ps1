# FragCut Kill montage - finds the kills in one or more recordings (Battlefield 6) and joins them into one video.
# Usage: select recordings in Explorer > right-click > Send to > FragCut - Kill montage  (or run with no files to pick them).
# Each kill becomes a clip from 5 s before it to 1 s after (kills close together share one clip).
# Test switches: -Before 5 -After 1 -NoOpen -NoPause -KeepClips

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files,
    [double]$Before = 5,
    [double]$After = 1,
    [switch]$NoOpen,
    [switch]$NoPause,
    [switch]$KeepClips
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Kills.ps1')

function Done { if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null } }
$inv = [Globalization.CultureInfo]::InvariantCulture

try {
    $ffmpeg = Find-Tool 'ffmpeg'; $ffprobe = Find-Tool 'ffprobe'

    $list = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    if ($list.Count -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Pick Battlefield 6 recordings (Ctrl+click to pick several)'
        $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov|All files|*.*'
        $dlg.Multiselect = $true
        $dlg.InitialDirectory = Get-StartFolder
        if ($dlg.ShowDialog() -ne 'OK') { exit }
        $list = @($dlg.FileNames)
    }
    $list = @($list | Sort-Object { Split-Path $_ -Leaf })      # recording order (NVIDIA names start with the date)

    Write-Host "`nFragCut $FragCutVersion - Kill montage  ($Before s before each kill, $After s after)" -ForegroundColor DarkGray

    # 1) find the kills in each recording
    $parts = New-Object System.Collections.ArrayList
    $sizes = @{}
    foreach ($v in $list) {
        $wh = (& $ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$v" | Select-Object -First 1).Split(',')
        $w = [int]$wh[0]; $h = [int]$wh[1]
        $dur = Get-Duration $ffprobe $v
        Write-Host ("`n{0}  ({1}x{2}, {3})" -f (Split-Path $v -Leaf), $w, $h, (Short $dur)) -ForegroundColor Cyan
        $kills = Get-CachedKills $v
        if ($null -ne $kills) {
            Write-Host '  kills already found earlier'
        } else {
            try { $sc = Start-KillScan $ffmpeg $v $dur $w $h }
            catch { Write-Host "  skipped: $($_.Exception.Message)" -ForegroundColor Yellow; continue }
            while (-not $sc.Done) { Start-Sleep -Milliseconds 300; Write-Host -NoNewline ("`r  looking for kills {0,3:N0}%" -f ($sc.Progress * 100)) }
            Write-Host -NoNewline "`r                              `r"
            if ($sc.Error) { Write-Host "  skipped: $($sc.Error)" -ForegroundColor Yellow; continue }
            $kills = Get-ScanKills $sc
            Save-CachedKills $v $kills
        }
        $nt = @($kills.Times).Count
        if ($nt -eq 0) { Write-Host '  no kills'; continue }
        # a burst (KILL -> KILL x2 ...) shows as first-last
        $desc = for ($i = 0; $i -lt $nt; $i++) {
            $t = $kills.Times[$i]; $l = if ($i -lt @($kills.Lasts).Count) { $kills.Lasts[$i] } else { $t }
            if ($l -gt $t + 0.3) { '{0}-{1}' -f (Short $t), (Short $l) } else { Short $t }
        }
        Write-Host ("  kills at: " + ($desc -join ', '))

        # 2) one clip per kill: from $Before s before the first kill to $After s after the last one; overlapping clips merge
        $cur = $null
        for ($i = 0; $i -lt $nt; $i++) {
            $t = $kills.Times[$i]; $l = if ($i -lt @($kills.Lasts).Count) { $kills.Lasts[$i] } else { $t }
            $a = [math]::Max(0.0, $t - $Before); $b = [math]::Min($dur, $l + $After)
            if ($cur -and $a -le $cur.End + 0.5) { $cur.End = [math]::Max($cur.End, $b); $cur.Kills++ }
            else { $cur = [pscustomobject]@{ Video = $v; Start = $a; End = $b; Kills = 1; W = $w; H = $h }; [void]$parts.Add($cur) }
        }
        $sizes["${w}x${h}"] = $true
    }

    if ($parts.Count -eq 0) { Write-Host "`nNo kills found - nothing to make." -ForegroundColor Yellow; Done; exit }

    # recordings with different sizes (e.g. 720p and 1440p): scale every clip to the biggest, so they join without re-encoding
    $big = $parts | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
    $W = $big.W; $H = $big.H
    $mixed = $sizes.Count -gt 1

    $total = ($parts | ForEach-Object { $_.End - $_.Start } | Measure-Object -Sum).Sum
    $nk = ($parts | Measure-Object Kills -Sum).Sum
    Write-Host ("`nMaking {0} clips ({1} kills, {2} total){3}" -f $parts.Count, $nk, (Short $total), $(if ($mixed) { ", all at ${W}x${H}" } else { '' })) -ForegroundColor Cyan

    # 3) cut the clips (same settings as FragCut slices)
    $enc = Get-Encoder $ffmpeg
    $gentle = Test-ObsRunning
    Write-Host "  encoding on: $(Get-EncoderName $enc)$(if ($gentle) { ' (gently - OBS is open)' })"
    $tmp = Join-Path $env:TEMP "fragcut-killmontage-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $clips = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        $mp4 = Join-Path $tmp ('{0:000}.mp4' -f $i)
        Write-Host -NoNewline ("`r  clip {0}/{1}" -f ($i + 1), $parts.Count)
        foreach ($e in @($enc, 'libx264') | Select-Object -Unique) {
            $a = Get-CutArgs $p.Video $p.Start ($p.End - $p.Start) $mp4 $e -Gentle:$gentle
            if ($mixed) {
                $scale = "scale=${W}:${H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,setsar=1"
                $ix = [array]::IndexOf($a, '-vf')
                if ($ix -ge 0) { $a[$ix + 1] = $a[$ix + 1] + ',' + $scale }       # gentle mode already has a -vf
                else { $o = [array]::IndexOf($a, '-c:v'); $a = $a[0..($o - 1)] + @('-vf', $scale) + $a[$o..($a.Count - 1)] }
            }
            & $ffmpeg @a
            if ($LASTEXITCODE -eq 0) { break }
            if ($e -ne 'libx264') { Reset-Encoder; $enc = 'libx264'; Write-Host "`n  GPU encoder failed, using the CPU..." -ForegroundColor Yellow }
        }
        if ($LASTEXITCODE -ne 0) { throw "could not cut clip $($i + 1) from $(Split-Path $p.Video -Leaf)" }
        $clips += $mp4
    }
    Write-Host ("`r  {0} clips cut in {1:N0} s          " -f $clips.Count, $sw.Elapsed.TotalSeconds)

    # 4) join them (no re-encoding: every clip has the same format)
    $dir  = Split-Path $list[0] -Parent
    $name = ([IO.Path]::GetFileNameWithoutExtension($list[0]) -replace '\.DVR$', '') + ' - kill montage'
    $n = 1; $try = $name
    while (Test-Path -LiteralPath (Join-Path $dir "$try.mp4")) { $n++; $try = "$name ($n)" }
    $out = Join-Path $dir "$try.mp4"
    $txt = Join-Path $tmp 'list.txt'
    [IO.File]::WriteAllLines($txt, @($clips | ForEach-Object { "file '" + ($_ -replace "'", "'\''") + "'" }), (New-Object Text.UTF8Encoding($false)))
    & $ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $txt -c copy -movflags +faststart "$out"
    if ($LASTEXITCODE -ne 0) { throw 'joining the clips failed' }
    if (-not $KeepClips) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "  clips kept in $tmp" }

    Write-Host ("`n  saved: {0}  ({1}, {2:N1} MB)" -f (Split-Path $out -Leaf), (Short (Get-Duration $ffprobe $out)), ((Get-Item -LiteralPath $out).Length / 1MB)) -ForegroundColor Green
    if (-not $NoOpen) { Show-InFolder $out }
    if (-not $NoPause) { Start-Sleep -Seconds 2 }
}
catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    Done
}

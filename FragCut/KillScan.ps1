# FragCut - list the kills in recordings from the command line (the player's "Find kills [K]" uses the same scanner).
# Usage:  powershell -File KillScan.ps1 <video> [<video> ...]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Kills.ps1')
$ffmpeg = Find-Tool 'ffmpeg'; $ffprobe = Find-Tool 'ffprobe'

foreach ($v in $Files) {
    $v = (Resolve-Path -LiteralPath $v).Path
    $wh = (& $ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$v" | Select-Object -First 1).Split(',')
    $dur = Get-Duration $ffprobe $v
    Write-Host "`n$(Split-Path $v -Leaf)  ($($wh[0])x$($wh[1]), $(Short $dur))"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sc = Start-KillScan $ffmpeg $v $dur ([int]$wh[0]) ([int]$wh[1])
    while (-not $sc.Done) { Start-Sleep -Milliseconds 500; Write-Host -NoNewline ("`r  scanning {0,3:N0}%" -f ($sc.Progress * 100)) }
    Write-Host ("`r  scanned {0} frames in {1:N0} s ({2:N1}x real time)" -f $sc.Frames, $sw.Elapsed.TotalSeconds, ($dur / [math]::Max(0.1, $sw.Elapsed.TotalSeconds)))
    if ($sc.Error) { Write-Host "  ERROR: $($sc.Error)" -ForegroundColor Red; continue }
    $k = $sc.Snapshot()
    if (-not $k.Count) { Write-Host '  no kills found' }
    foreach ($x in $k) {
        $last = Get-LastKill $x.Time $x.LastSeen
        $burst = if ($last -gt $x.Time + 0.3) { 'last kill ~' + (Short $last) } else { '' }
        Write-Host ("  {0,-8} {1,-15} score {2:N2}  on screen {3:N1} s  {4}" -f (Short $x.Time), $x.Tag, $x.Score, ($x.LastSeen - $x.Time + 0.2), $burst)
    }
}

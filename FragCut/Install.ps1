# FragCut installer - copies FragCut to your user folder and adds it to the right-click "Send to" menu.
# No admin rights needed. Run it with Install.bat.
param([string]$Dest = "$env:LOCALAPPDATA\FragCut", [switch]$NoShortcuts, [switch]$NoPause)

$ErrorActionPreference = 'Stop'
function Pause-End { if (-not $NoPause) { Read-Host "`nPress Enter to close" | Out-Null } }

try {
    . (Join-Path $PSScriptRoot 'Core.ps1')
    Write-Host "`nFragCut $FragCutVersion - install" -ForegroundColor Cyan
    Write-Host "Installing to: $Dest"

    # 1) copy the tools
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $files = 'Core.ps1','FragCut.ps1','Join.ps1','Join.bat','TimeCut.ps1','TimeCut.bat','Compress.ps1','Compress.bat','Uninstall.ps1','Uninstall.bat','Quick Guide.txt'
    foreach ($f in $files) {
        $src = Join-Path $PSScriptRoot $f
        if (-not (Test-Path -LiteralPath $src)) { throw "missing file in the package: $f (unzip the whole folder first)" }
        if ((Resolve-Path -LiteralPath $src).Path -ne (Join-Path (Resolve-Path -LiteralPath $Dest).Path $f)) { Copy-Item -LiteralPath $src -Destination $Dest -Force }
    }
    Get-ChildItem $Dest | Unblock-File -ErrorAction SilentlyContinue   # remove the "downloaded from the internet" flag
    Write-Host '  files copied' -ForegroundColor Green

    # 2) ffmpeg (the free video engine that does the actual cutting/joining)
    $ff = $null
    try { $ff = Find-Tool 'ffmpeg' } catch {}
    if ($ff) {
        Write-Host '  ffmpeg found' -ForegroundColor Green
    } else {
        Write-Host "`n  FragCut needs ffmpeg (free, open source video engine), and it is not installed." -ForegroundColor Yellow
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget -and ((Read-Host '  Install it now with winget? (Y/n)') -notmatch '^(n|no)$')) {
            & winget install --id Gyan.FFmpeg.Essentials -e --source winget
            if ($LASTEXITCODE -eq 0) { Write-Host '  ffmpeg installed' -ForegroundColor Green; try { $ff = Find-Tool 'ffmpeg' } catch {} }
            else { Write-Host '  winget could not install ffmpeg - see "Quick Guide.txt" for the manual way.' -ForegroundColor Red }
        } else {
            Write-Host '  Install it later with:  winget install Gyan.FFmpeg.Essentials' -ForegroundColor Yellow
        }
    }

    # 3) pick the fastest encoder for this PC (NVIDIA / AMD / Intel GPU, else CPU)
    if ($ff) {
        Reset-Encoder
        $enc = Get-Encoder $ff
        Write-Host "  encoding will run on: $(Get-EncoderName $enc)" -ForegroundColor Green
    }

    # 4) shortcuts: right-click > Send to, plus FragCut on the Desktop
    if (-not $NoShortcuts) {
        $ws    = New-Object -ComObject WScript.Shell
        $send  = Join-Path $env:APPDATA 'Microsoft\Windows\SendTo'
        $desk  = [Environment]::GetFolderPath('Desktop')
        $ps    = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

        function New-Lnk($path, $target, $arguments, $icon, $hidden) {
            $l = $ws.CreateShortcut($path)
            $l.TargetPath = $target; $l.Arguments = $arguments; $l.WorkingDirectory = $Dest
            $l.IconLocation = $icon
            if ($hidden) { $l.WindowStyle = 7 }
            $l.Save()
        }
        $main = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\FragCut.ps1`""
        New-Lnk "$send\FragCut.lnk"               $ps $main "$env:WINDIR\System32\imageres.dll,18" $true
        New-Lnk "$desk\FragCut.lnk"               $ps $main "$env:WINDIR\System32\imageres.dll,18" $true
        New-Lnk "$send\FragCut - Join clips.lnk"  "$Dest\Join.bat"    '' "$env:WINDIR\System32\imageres.dll,19" $false
        New-Lnk "$send\FragCut - Cut by time.lnk" "$Dest\TimeCut.bat" '' "$env:WINDIR\System32\imageres.dll,18" $false
        New-Lnk "$send\FragCut - Compress.lnk"    "$Dest\Compress.bat" '' "$env:WINDIR\System32\imageres.dll,174" $false
        Write-Host '  added to right-click > Send to:  FragCut, FragCut - Join clips, FragCut - Cut by time, FragCut - Compress' -ForegroundColor Green
        Write-Host '  added "FragCut" to the Desktop' -ForegroundColor Green
    }

    Write-Host "`nDone! Right-click a recording > Send to > FragCut.  Keys are in 'Quick Guide.txt'." -ForegroundColor Cyan
    Write-Host '(Windows 11: "Send to" is under "Show more options", or Shift + right-click.)'
}
catch { Write-Host "`nInstall failed: $($_.Exception.Message)" -ForegroundColor Red }
Pause-End

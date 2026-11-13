# FragCut uninstaller - removes the Send to / Desktop shortcuts, the installed files and settings.
# Your clips and ffmpeg are not touched (remove ffmpeg with: winget uninstall Gyan.FFmpeg.Essentials).
$send = Join-Path $env:APPDATA 'Microsoft\Windows\SendTo'
$desk = [Environment]::GetFolderPath('Desktop')
foreach ($l in "$send\FragCut.lnk", "$send\FragCut - Join clips.lnk", "$send\FragCut - Cut by time.lnk", "$send\FragCut - Compress.lnk", "$send\FragCut - Kill montage.lnk","$desk\FragCut.lnk") {
    if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; Write-Host "removed $l" }
}
$dir = "$env:LOCALAPPDATA\FragCut"
if (Test-Path -LiteralPath $dir) {
    # delete the folder after this script has exited (it may be running from inside it)
    Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden
    Write-Host "removed $dir"
}
Write-Host "`nFragCut uninstalled."
Read-Host 'Press Enter to close' | Out-Null

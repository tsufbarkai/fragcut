# FragCut uninstaller - removes the Send to / Desktop shortcuts, the installed files, settings and preview copies.
# The copy of mpv the installer downloaded lives in FragCut's folder and goes with it.
# Your clips are not touched, and neither is ffmpeg (remove it with: winget uninstall Gyan.FFmpeg.Essentials)
Add-Type -AssemblyName PresentationFramework
$dir = "$env:LOCALAPPDATA\FragCut"
$q = "Remove FragCut?`n`nThis removes FragCut, its Send to and Desktop shortcuts, its settings and the copy of mpv it downloaded, from $dir.`nYour clips are not deleted. ffmpeg stays installed (other programs may use it)."
if ([System.Windows.MessageBox]::Show($q, 'Uninstall FragCut', 'YesNo', 'Question') -ne 'Yes') { exit }

$send = Join-Path $env:APPDATA 'Microsoft\Windows\SendTo'
$desk = [Environment]::GetFolderPath('Desktop')
foreach ($l in "$send\FragCut.lnk", "$send\FragCut - Join clips.lnk", "$send\FragCut - Cut by time.lnk", "$send\FragCut - Compress.lnk", "$send\FragCut - Kill montage.lnk", "$desk\FragCut.lnk") {
    if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force }
}
if (Test-Path -LiteralPath $dir) {
    # delete the folder after this script has exited (it may be running from inside it)
    Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden
}
[System.Windows.MessageBox]::Show("FragCut is uninstalled.`n`nTo remove ffmpeg too, run in a terminal:`n  winget uninstall Gyan.FFmpeg.Essentials", 'Uninstall FragCut', 'OK', 'Information') | Out-Null

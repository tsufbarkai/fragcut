# FragCut installer - copies FragCut to your user folder, adds it to the right-click "Send to" menu,
# and offers to install the two free programs it uses (ffmpeg and mpv) with winget.
# No admin rights needed for FragCut itself. Run it with Install.bat.
# -NoGui: install without the window (copies files and shortcuts; doesn't install ffmpeg/mpv).
# -Snapshot <png>: test - saves a picture of the window, presses Install, saves another when done, closes.
param([string]$Dest = "$env:LOCALAPPDATA\FragCut", [switch]$NoShortcuts, [switch]$NoGui, [switch]$NoPause, [string]$Snapshot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Mpv.ps1')

$script:Files = 'Core.ps1','Mpv.ps1','FragCut.ps1','Join.ps1','Join.bat','TimeCut.ps1','TimeCut.bat','Compress.ps1','Compress.bat','Kills.ps1','KillScan.ps1','KillMontage.ps1','KillMontage.bat','Uninstall.ps1','Uninstall.bat','Quick Guide.txt'

function Copy-FragCut {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $destFull = (Resolve-Path -LiteralPath $Dest).Path
    foreach ($f in $script:Files) {
        $src = Join-Path $PSScriptRoot $f
        if (-not (Test-Path -LiteralPath $src)) { throw "missing file in the package: $f (unzip the whole folder first)" }
        if ((Resolve-Path -LiteralPath $src).Path -ne (Join-Path $destFull $f)) { Copy-Item -LiteralPath $src -Destination $Dest -Force }
    }
    # pictures of each game's kill tags (used by "Find kills")
    $kills = Join-Path $PSScriptRoot 'kills'
    if (-not (Test-Path -LiteralPath $kills)) { throw 'missing folder in the package: kills (unzip the whole folder first)' }
    if ((Resolve-Path -LiteralPath $kills).Path -ne (Join-Path $destFull 'kills')) { Copy-Item -LiteralPath $kills -Destination $Dest -Recurse -Force }
    Get-ChildItem $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue   # remove the "downloaded from the internet" flag
}

# right-click > Send to, plus FragCut on the Desktop
function Add-Shortcuts {
    $ws   = New-Object -ComObject WScript.Shell
    $send = Join-Path $env:APPDATA 'Microsoft\Windows\SendTo'
    $desk = [Environment]::GetFolderPath('Desktop')
    $ps   = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    function New-Lnk($path, $target, $arguments, $icon, $hidden) {
        $l = $ws.CreateShortcut($path)
        $l.TargetPath = $target; $l.Arguments = $arguments; $l.WorkingDirectory = $Dest
        $l.IconLocation = $icon
        if ($hidden) { $l.WindowStyle = 7 }
        $l.Save()
    }
    $main = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\FragCut.ps1`""
    New-Lnk "$send\FragCut.lnk"                $ps $main "$env:WINDIR\System32\imageres.dll,18" $true
    New-Lnk "$desk\FragCut.lnk"                $ps $main "$env:WINDIR\System32\imageres.dll,18" $true
    New-Lnk "$send\FragCut - Join clips.lnk"   "$Dest\Join.bat"        '' "$env:WINDIR\System32\imageres.dll,19" $false
    New-Lnk "$send\FragCut - Cut by time.lnk"  "$Dest\TimeCut.bat"     '' "$env:WINDIR\System32\imageres.dll,18" $false
    New-Lnk "$send\FragCut - Compress.lnk"     "$Dest\Compress.bat"    '' "$env:WINDIR\System32\imageres.dll,174" $false
    New-Lnk "$send\FragCut - Kill montage.lnk" "$Dest\KillMontage.bat" '' "$env:WINDIR\System32\imageres.dll,19" $false
}

function Find-FFmpeg { try { return Find-Tool 'ffmpeg' } catch { return $null } }
# mpv in FragCut's own folder (downloaded by this installer), else one installed some other way
$script:MpvDir = Join-Path $Dest 'mpv'
function Find-OurMpv { $e = Join-Path $script:MpvDir 'mpv.exe'; if (Test-Path -LiteralPath $e) { return $e }; return (Find-Mpv) }
# winget changes PATH for new programs; pick that up without restarting
function Update-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }

# ---------- without the window ----------
if ($NoGui) {
    try {
        Write-Host "FragCut $FragCutVersion - install to $Dest"
        Copy-FragCut; Write-Host '  files copied'
        $ff = Find-FFmpeg
        if ($ff) { Reset-Encoder; Write-Host "  ffmpeg found, encoding on: $(Get-EncoderName (Get-Encoder $ff))" } else { Write-Host '  ffmpeg NOT found:  winget install Gyan.FFmpeg.Essentials' }
        if (Find-OurMpv) { Write-Host '  mpv found' } else { Write-Host '  mpv not found (optional) - run Install.bat to download it' }
        if (-not $NoShortcuts) { Add-Shortcuts; Write-Host '  shortcuts added (Send to + Desktop)' }
        Write-Host 'Done.'
    } catch { Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 0
}

# ---------- the window ----------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Install FragCut" Width="620" SizeToContent="Height" ResizeMode="NoResize"
        Background="#1b1b1f" Foreground="#e8e8ea" WindowStartupLocation="CenterScreen" FontSize="14">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2d2d34"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="BorderBrush" Value="#44444c"/><Setter Property="Padding" Value="18,7"/><Setter Property="Margin" Value="8,0,0,0"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#e8e8ea"/><Setter Property="VerticalAlignment" Value="Top"/><Setter Property="Margin" Value="0,2,10,0"/></Style>
    <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
  </Window.Resources>
  <StackPanel Margin="22,18,22,18">
    <TextBlock x:Name="Head" FontSize="20" Foreground="#9aa0ff" Text="Install FragCut"/>
    <TextBlock x:Name="Intro" Margin="0,8,0,14" Foreground="#b8b8c0"/>

    <TextBlock Text="FragCut uses two free programs:" Margin="0,0,0,8"/>
    <Border Background="#141417" BorderBrush="#33333a" BorderThickness="1" Padding="12,10">
      <StackPanel>
        <DockPanel Margin="0,0,0,10">
          <CheckBox x:Name="ChkFf" DockPanel.Dock="Left"/>
          <TextBlock x:Name="StFf" DockPanel.Dock="Right" Margin="10,0,0,0" MinWidth="120" TextAlignment="Right"/>
          <TextBlock><Run FontWeight="SemiBold" Text="ffmpeg"/><Run Foreground="#8a8a92" Text="  (required)"/><LineBreak/><Run Foreground="#b8b8c0" Text="cuts, joins and compresses the videos"/></TextBlock>
        </DockPanel>
        <DockPanel>
          <CheckBox x:Name="ChkMpv" DockPanel.Dock="Left"/>
          <TextBlock x:Name="StMpv" DockPanel.Dock="Right" Margin="10,0,0,0" MinWidth="120" TextAlignment="Right"/>
          <TextBlock><Run FontWeight="SemiBold" Text="mpv"/><Run Foreground="#8a8a92" Text="  (recommended)"/><LineBreak/><Run Foreground="#b8b8c0" Text="plays the recordings in FragCut, including AV1 and HEVC. Without it, FragCut uses Windows' player, which can't play some recordings."/></TextBlock>
        </DockPanel>
      </StackPanel>
    </Border>
    <TextBlock x:Name="Note" Margin="0,8,0,0" FontSize="12" Foreground="#8a8a92"
               Text="ffmpeg is installed with winget, Windows' app installer. mpv is downloaded from its official releases (github.com/shinchiro/mpv-winbuild-cmake) into FragCut's folder."/>

    <TextBlock x:Name="Status" Margin="0,16,0,0" Foreground="#f0a020" MinHeight="20"/>
    <ProgressBar x:Name="Bar" Height="6" Margin="0,6,0,0" Minimum="0" Maximum="100" Visibility="Hidden" Background="#141417" Foreground="#3b5bdb" BorderThickness="0"/>
    <TextBlock x:Name="Detail" Margin="0,6,0,0" FontSize="12" Foreground="#8a8a92" FontFamily="Consolas" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="BtnGuide" Content="Open Quick Guide" Visibility="Collapsed"/>
      <Button x:Name="BtnInstall" Content="Install" Background="#3b5bdb" IsDefault="True"/>
      <Button x:Name="BtnClose" Content="Cancel" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Head','Intro','ChkFf','StFf','ChkMpv','StMpv','Note','Status','Bar','Detail','BtnGuide','BtnInstall','BtnClose') { $ui[$n] = $win.FindName($n) }
$green = '#51cf66'; $grey = '#8a8a92'; $red = '#ff6b6b'

$ui.Head.Text = "Install FragCut $FragCutVersion"
$ui.Intro.Text = "FragCut is copied to $Dest and added to the right-click Send to menu and the Desktop. It doesn't need administrator rights. Running this again updates it; your clips and settings are kept."
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

function Show-Found {
    foreach ($p in @(@{ Chk = $ui.ChkFf; St = $ui.StFf; Path = (Find-FFmpeg); Can = $hasWinget }, @{ Chk = $ui.ChkMpv; St = $ui.StMpv; Path = (Find-OurMpv); Can = $true })) {
        if ($p.Path) {
            $p.St.Text = 'installed'; $p.St.Foreground = $green
            $p.Chk.IsChecked = $false; $p.Chk.Visibility = 'Hidden'; $p.St.ToolTip = $p.Path
        } else {
            $p.St.Text = 'not installed'; $p.St.Foreground = $grey
            $p.Chk.IsChecked = $p.Can; $p.Chk.IsEnabled = $p.Can
        }
    }
}
Show-Found
if (-not $hasWinget) {
    $ui.Note.Text = "winget (Windows' app installer) isn't available on this PC, so ffmpeg can't be installed from here. Get ""App Installer"" from the Microsoft Store and run this again, or install ffmpeg yourself (see Quick Guide.txt). mpv is downloaded from its official releases into FragCut's folder."
    $ui.Note.Foreground = '#f0a020'
}

# ---------- install steps, run one per timer tick so the window stays responsive ----------
$st = @{ Steps = New-Object System.Collections.Queue; Proc = $null; Log = $null; Pkg = $null; Errors = New-Object System.Collections.ArrayList; Done = $false }

function Say($text, $color = '#f0a020') { $ui.Status.Text = $text; $ui.Status.Foreground = $color }

# run a program hidden; Run-Step calls $onTick while it runs and $onExit (with its exit code) when it ends
function Start-Bg([string]$exe, [string]$arguments, [scriptblock]$onTick, [scriptblock]$onExit) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $st.OnTick = $onTick; $st.OnExit = $onExit
    $st.Proc = [Diagnostics.Process]::Start($psi)
    $ui.Bar.Visibility = 'Visible'; $ui.Bar.IsIndeterminate = $true
}
function Stop-Bar { $ui.Bar.Visibility = 'Hidden'; $ui.Bar.IsIndeterminate = $false; $ui.Detail.Text = '' }

function Start-Winget($pkg) {
    $st.Pkg = $pkg
    $st.Log = Join-Path $env:TEMP "fragcut-winget-$($pkg.Name).log"
    $cmdLine = "/c winget install --id $($pkg.Id) -e --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity > `"$($st.Log)`" 2>&1"
    Say "Installing $($pkg.Name) with winget..."
    Start-Bg 'cmd.exe' $cmdLine { Show-WingetProgress } { param($code) Finish-Winget $code }
}

# ---------- mpv: the official build from shinchiro's GitHub releases (https://github.com/shinchiro/mpv-winbuild-cmake),
# unpacked into FragCut's folder. No admin rights, no file associations. Checked against the SHA-256 GitHub lists for it.
# If that doesn't work (no internet access to GitHub, or Windows' tar can't unpack .7z on older Windows 10), use winget.
function Start-MpvDownload($pkg) {
    $st.Pkg = $pkg
    Say 'Downloading mpv from its official releases (github.com/shinchiro)...'
    $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest' -Headers @{ 'User-Agent' = 'FragCut-installer' } -TimeoutSec 20
    $a = $r.assets | Where-Object { $_.name -match '^mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
    if (-not $a) { throw 'no Windows 64-bit mpv file in the latest release' }
    $tmp = Join-Path $env:TEMP 'fragcut-mpv'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $st.MpvAsset = $a
    $st.MpvFile = Join-Path $tmp $a.name
    Start-Bg 'curl.exe' "-sSL --fail -o `"$($st.MpvFile)`" `"$($a.browser_download_url)`"" {
        $size = 0; try { $size = (Get-Item -LiteralPath $st.MpvFile).Length } catch {}
        if ($st.MpvAsset.size -gt 0) { $ui.Bar.IsIndeterminate = $false; $ui.Bar.Value = 100 * $size / $st.MpvAsset.size }
        $ui.Detail.Text = '{0}  {1:N1} / {2:N1} MB' -f $st.MpvAsset.name, ($size / 1MB), ($st.MpvAsset.size / 1MB)
    } { param($code) Finish-MpvDownload $code }
}

function Finish-MpvDownload([int]$code) {
    Stop-Bar
    try {
        if ($code -ne 0) { throw "download failed (curl exit code $code)" }
        $want = ([string]$st.MpvAsset.digest) -replace '^sha256:', ''
        $got = (Get-FileHash -LiteralPath $st.MpvFile -Algorithm SHA256).Hash
        if ($want -and $got -ne $want) { throw 'the downloaded file does not match its published SHA-256 checksum' }
        Say 'Unpacking mpv...'
        $st.MpvNew = "$($script:MpvDir).new"
        if (Test-Path -LiteralPath $st.MpvNew) { [IO.Directory]::Delete($st.MpvNew, $true) }
        New-Item -ItemType Directory -Force $st.MpvNew | Out-Null
        Start-Bg 'tar.exe' "-xf `"$($st.MpvFile)`" -C `"$($st.MpvNew)`"" { } { param($c) Finish-MpvUnpack $c }
    } catch { Use-MpvWinget $_.Exception.Message }
}

function Finish-MpvUnpack([int]$code) {
    Stop-Bar
    try {
        if ($code -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $st.MpvNew 'mpv.exe'))) { throw "this Windows can't unpack .7z files (tar exit code $code)" }
        if (Test-Path -LiteralPath $script:MpvDir) { [IO.Directory]::Delete($script:MpvDir, $true) }
        [IO.Directory]::Move($st.MpvNew, $script:MpvDir)
        try { [IO.File]::Delete($st.MpvFile) } catch {}
        $st.Pkg.St.Text = 'installed'; $st.Pkg.St.Foreground = $green; $st.Pkg.Chk.Visibility = 'Hidden'
    } catch { Use-MpvWinget $_.Exception.Message }
}

# official download didn't work: try the winget package (made by a third party from shinchiro's build; asks for admin)
function Use-MpvWinget([string]$why) {
    try { if ($st.MpvNew -and (Test-Path -LiteralPath $st.MpvNew)) { [IO.Directory]::Delete($st.MpvNew, $true) } } catch {}
    if (-not $hasWinget) { [void]$st.Errors.Add("mpv wasn't installed ($why)."); $st.Pkg.St.Text = 'not installed'; $st.Pkg.St.Foreground = $red; return }
    $ui.Detail.Text = "official download: $why - trying winget"
    Start-Winget @{ Name = 'mpv'; Id = 'shinchiro.mpv'; Find = { Find-OurMpv }; St = $st.Pkg.St; Chk = $st.Pkg.Chk }
}

# winget's output: "Downloading ...", progress bars, "Successfully installed" - show the latest useful line
function Show-WingetProgress {
    try {
        $fs = [IO.File]::Open($st.Log, 'Open', 'Read', 'ReadWrite')
        $txt = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
        $parts = @($txt -split "[`r`n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '[A-Za-z0-9]' -and $_ -notmatch '^[-\\|/ ]+$' })
        if ($parts.Count) {
            $last = $parts[-1]
            $m = [regex]::Match($last, '([\d.]+)\s*[KMG]?B\s*/\s*([\d.]+)\s*[KMG]?B')
            if ($m.Success -and [double]$m.Groups[2].Value -gt 0) { $ui.Bar.IsIndeterminate = $false; $ui.Bar.Value = 100 * [double]$m.Groups[1].Value / [double]$m.Groups[2].Value }
            $ui.Detail.Text = ($last -replace '[^\x20-\x7E]', '').Trim()
        }
    } catch {}
}

function Finish-Winget([int]$code) {
    $pkg = $st.Pkg
    Stop-Bar
    Update-Path
    $found = & $pkg.Find
    if ($found) {
        $pkg.St.Text = 'installed'; $pkg.St.Foreground = $green; $pkg.Chk.Visibility = 'Hidden'
    } else {
        $why = "winget exit code $code - details in $($st.Log)"
        $pkg.St.Text = 'not installed'; $pkg.St.Foreground = $red
        [void]$st.Errors.Add("$($pkg.Name) wasn't installed ($why). Install it later with:  winget install $($pkg.Id)")
    }
}

function Run-Step {
    if ($st.Proc) {
        if (-not $st.Proc.HasExited) { try { & $st.OnTick } catch {}; return }
        $code = $st.Proc.ExitCode; $st.Proc = $null
        try { & $st.OnExit $code } catch { [void]$st.Errors.Add($_.Exception.Message) }
        return
    }
    if ($st.Steps.Count -eq 0) { Finish-Install; return }
    $step = $st.Steps.Dequeue()
    try {
        switch ($step.Kind) {
            'copy'      { Say 'Copying FragCut...'; Copy-FragCut }
            'winget'    { Start-Winget $step }
            'mpv'       { try { Start-MpvDownload $step } catch { $st.Pkg = $step; Use-MpvWinget $_.Exception.Message } }
            'encoder'   {
                $ff = Find-FFmpeg
                if ($ff) { Say 'Checking which graphics card can encode video...'; Reset-Encoder; $st.Enc = Get-EncoderName (Get-Encoder $ff) }
            }
            'shortcuts' { Say 'Adding the shortcuts...'; Add-Shortcuts }
        }
    } catch {
        [void]$st.Errors.Add("$($step.Kind): $($_.Exception.Message)")
        if ($step.Kind -eq 'copy') { $st.Steps.Clear() }        # nothing else makes sense without the files
    }
}

function Finish-Install {
    $timer.Stop(); $st.Done = $true
    $ui.Bar.Visibility = 'Collapsed'; $ui.Detail.Text = ''
    $ffOk = [bool](Find-FFmpeg)
    if ($st.Errors.Count -eq 0 -and $ffOk) {
        $msg = "FragCut is installed. Right-click a recording and choose Send to > FragCut. On Windows 11, Send to is under Show more options."
        if ($st.Enc) { $msg += " Videos will be encoded on: $($st.Enc)." }
        Say $msg $green
    } else {
        $lines = @($st.Errors)
        if (-not $ffOk) { $lines += 'FragCut can''t cut videos until ffmpeg is installed:  winget install Gyan.FFmpeg.Essentials' }
        Say ("Finished with problems:`n" + ($lines -join "`n")) $red
    }
    $ui.BtnInstall.Visibility = 'Collapsed'
    $ui.BtnGuide.Visibility = 'Visible'
    $ui.BtnClose.Content = 'Close'; $ui.BtnClose.IsEnabled = $true; $ui.BtnClose.IsDefault = $true
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({ Run-Step })

$ui.BtnInstall.Add_Click({
    $ui.BtnInstall.IsEnabled = $false; $ui.BtnClose.IsEnabled = $false
    $ui.ChkFf.IsEnabled = $false; $ui.ChkMpv.IsEnabled = $false
    $st.Steps.Enqueue(@{ Kind = 'copy' })
    if ($ui.ChkFf.IsChecked)  { $st.Steps.Enqueue(@{ Kind = 'winget'; Name = 'ffmpeg'; Id = 'Gyan.FFmpeg.Essentials'; Find = { Find-FFmpeg }; St = $ui.StFf;  Chk = $ui.ChkFf }) }
    if ($ui.ChkMpv.IsChecked) { $st.Steps.Enqueue(@{ Kind = 'mpv'; Name = 'mpv'; St = $ui.StMpv; Chk = $ui.ChkMpv }) }
    $st.Steps.Enqueue(@{ Kind = 'encoder' })
    if (-not $NoShortcuts) { $st.Steps.Enqueue(@{ Kind = 'shortcuts' }) }
    $timer.Start()
})
$ui.BtnGuide.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$Dest\Quick Guide.txt`"" })
$ui.BtnClose.Add_Click({ $win.Close() })
$win.Add_Closing({ param($s, $e) if ($st.Proc -and -not $st.Proc.HasExited) { $e.Cancel = $true } })   # don't leave winget half-way

if ($Snapshot) {
    function Save-Shot($path) {
        $win.UpdateLayout()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$win.ActualWidth, [int]$win.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($win.Content)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
    }
    $win.Add_ContentRendered({
        Save-Shot $Snapshot
        $ui.ChkFf.IsChecked = $false                                        # test: never run winget (mpv downloads into -Dest)
        $ui.BtnInstall.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        $t2 = New-Object Windows.Threading.DispatcherTimer; $t2.Interval = [TimeSpan]::FromMilliseconds(300)
        $t2.Add_Tick({ if ($st.Done) { $this.Stop(); Save-Shot ($Snapshot -replace '\.png$', '-done.png'); $win.Close() } })
        $t2.Start()
    })
}
[void]$win.ShowDialog()

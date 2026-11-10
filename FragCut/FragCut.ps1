# FragCut - watch a recording, mark start/end while it plays, and cut slices with one key.
# Usage: right-click one or more recordings > Send to > FragCut  (or run with no files to pick them).
#
# Keys:  Esc / Backspace  clear the marks
#        Space play/pause      Left/Right -/+ 0.5 s (Shift = 5 s, Ctrl = 30 s)
#        , / .  one frame back/forward (pauses)
#        I or [  mark start    O or ]  mark end     C or Enter  cut the slice
#        N  next video         J  join the slices cut in this window
#        Up/Down  volume
# Slices are saved next to the recording. All slices use the same encoder settings,
# so Join stitches them without re-encoding.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

function Fail($msg) { [System.Windows.MessageBox]::Show($msg, 'FragCut', 'OK', 'Error') | Out-Null; exit 1 }

try { $ffmpeg = Find-Tool 'ffmpeg'; $ffprobe = Find-Tool 'ffprobe' } catch { Fail $_.Exception.Message }

$queue = New-Object System.Collections.ArrayList
foreach ($f in $Files) { if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { [void]$queue.Add((Resolve-Path -LiteralPath $f).Path) } }
$queue = [System.Collections.ArrayList]@($queue | Sort-Object { Split-Path $_ -Leaf })

function Pick-Videos {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Pick recordings to mark (Ctrl+click for several)'
    $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov;*.avi;*.webm|All files|*.*'
    $dlg.Multiselect = $true
    $dlg.InitialDirectory = Get-StartFolder
    if ($dlg.ShowDialog() -eq 'OK') { Save-LastFolder $dlg.FileNames[0]; return @($dlg.FileNames | Sort-Object { Split-Path $_ -Leaf }) }
    return @()
}
if ($queue.Count -eq 0 -and $SelfTest) { Write-Host 'SELFTEST no video given'; exit 1 }
if ($queue.Count -eq 0) { foreach ($f in (Pick-Videos)) { [void]$queue.Add($f) } }
if ($queue.Count -eq 0) { exit }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FragCut" Width="1280" Height="860" MinWidth="800" MinHeight="560"
        Background="#1b1b1f" Foreground="#e8e8ea" WindowStartupLocation="CenterScreen" FontSize="14">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2d2d34"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="BorderBrush" Value="#44444c"/><Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Focusable" Value="False"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#e8e8ea"/><Setter Property="Focusable" Value="False"/></Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="110"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="15" Foreground="#9aa0ff" Margin="0,0,0,8" TextTrimming="CharacterEllipsis"/>
    <Border Grid.Row="1" Background="Black">
      <MediaElement x:Name="Player" LoadedBehavior="Manual" UnloadedBehavior="Stop" ScrubbingEnabled="True" Stretch="Uniform"/>
    </Border>
    <Grid Grid.Row="2" Margin="0,10,0,0">
      <Canvas x:Name="RangeCanvas" Height="8" VerticalAlignment="Top" Margin="5,0,5,0">
        <Rectangle x:Name="RangeRect" Height="8" Fill="#f0a020" Width="0"/>
      </Canvas>
    </Grid>
    <Slider x:Name="Seek" Grid.Row="3" Minimum="0" Maximum="1" IsMoveToPointEnabled="True" Focusable="False" Margin="0,2,0,0"/>
    <DockPanel Grid.Row="4" Margin="0,8,0,0" LastChildFill="False">
      <TextBlock x:Name="TimeText" DockPanel.Dock="Left" FontFamily="Consolas" FontSize="18" VerticalAlignment="Center" Width="230"/>
      <TextBlock x:Name="MarkText" DockPanel.Dock="Left" FontFamily="Consolas" FontSize="16" Foreground="#f0a020" VerticalAlignment="Center"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="Vol" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <Slider x:Name="Vol" Width="110" Minimum="0" Maximum="1" Value="0.6" Focusable="False" VerticalAlignment="Center"/>
      </StackPanel>
    </DockPanel>
    <WrapPanel Grid.Row="5" Margin="0,10,0,10">
      <Button x:Name="BtnPlay"  Content="Play/Pause [Space]"/>
      <Button x:Name="BtnStart" Content="Mark start [I]"/>
      <Button x:Name="BtnEnd"   Content="Mark end [O]"/>
      <Button x:Name="BtnClear" Content="Clear marks [Esc]"/>
      <Button x:Name="BtnCut"   Content="Cut slice [C]" Background="#3b5bdb"/>
      <Button x:Name="BtnNext"  Content="Next video [N]"/>
      <Button x:Name="BtnOpen"  Content="Open video..."/>
      <Button x:Name="BtnJoin"  Content="Join slices [J]" Background="#2f9e44"/>
      <CheckBox x:Name="ChkMp3" Content="Also save MP3" VerticalAlignment="Center" Margin="8,0,0,0"/>
    </WrapPanel>
    <ListBox x:Name="Slices" Grid.Row="6" Background="#141417" Foreground="#e8e8ea" BorderBrush="#33333a" Focusable="False" FontFamily="Consolas"/>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'TitleText','Player','RangeCanvas','RangeRect','Seek','TimeText','MarkText','Vol','BtnPlay','BtnStart','BtnEnd','BtnClear','BtnCut','BtnNext','BtnOpen','BtnJoin','ChkMp3','Slices') { $ui[$n] = $win.FindName($n) }

$st = @{
    Index = -1; Video = $null; Dur = 0.0; Playing = $false; Dragging = $false
    Start = $null; End = $null
    Jobs = New-Object System.Collections.ArrayList     # pending ffmpeg steps
    Running = $null                                    # current step
    Done = New-Object System.Collections.ArrayList     # finished slice mp4 files
    Enc = (Get-Encoder $ffmpeg)
}

function Set-Status($i, $text) { $ui.Slices.Items[$i] = $text }
function Set-Title { $win.Title = "FragCut $FragCutVersion   -   encoding on: $(Get-EncoderName $st.Enc)" }

function Load-Video([int]$i) {
    if ($i -ge $queue.Count) { return }
    $st.Index = $i; $st.Video = $queue[$i]; $st.Start = $null; $st.End = $null; $st.Dur = 0
    $ui.TitleText.Text = ('[{0}/{1}]  {2}' -f ($i + 1), $queue.Count, (Split-Path $st.Video -Leaf))
    Save-LastFolder $st.Video
    $ui.Player.Source = New-Object Uri($st.Video)
    $ui.Player.Volume = $ui.Vol.Value
    $ui.Player.Play(); $st.Playing = $true
}

function Pos { $ui.Player.Position.TotalSeconds }
function Seek-To([double]$s) {
    if ($st.Dur -gt 0) { $s = [math]::Max(0, [math]::Min($s, $st.Dur)) } else { $s = [math]::Max(0, $s) }
    $ui.Player.Position = [TimeSpan]::FromSeconds($s)
    $ui.Seek.Value = $s
}
function Toggle-Play { if ($st.Playing) { $ui.Player.Pause() } else { $ui.Player.Play() }; $st.Playing = -not $st.Playing }
function Step([double]$d) { if ($st.Playing) { $ui.Player.Pause(); $st.Playing = $false }; Seek-To ((Pos) + $d) }

function Update-Marks {
    $s = if ($null -ne $st.Start) { Short $st.Start } else { '--' }
    $e = if ($null -ne $st.End)   { Short $st.End }   else { '--' }
    $len = ''
    if ($null -ne $st.Start -and $null -ne $st.End -and $st.End -gt $st.Start) { $len = '  ({0:N1} s)' -f ($st.End - $st.Start) }
    $ui.MarkText.Text = "Start $s   End $e$len"
    $w = $ui.RangeCanvas.ActualWidth
    if ($st.Dur -gt 0 -and $w -gt 0 -and $null -ne $st.Start) {
        $a = $st.Start; $b = if ($null -ne $st.End -and $st.End -gt $a) { $st.End } else { [math]::Max((Pos), $a) }
        [Windows.Controls.Canvas]::SetLeft($ui.RangeRect, $w * $a / $st.Dur)
        $ui.RangeRect.Width = [math]::Max(2, $w * ($b - $a) / $st.Dur)
    } else { $ui.RangeRect.Width = 0 }
}

function Start-Next-Job {
    if ($st.Running -or $st.Jobs.Count -eq 0) { return }
    $job = $st.Jobs[0]; $st.Jobs.RemoveAt(0)
    $argv = if ($job.Kind -eq 'mp4') { Get-CutArgs $job.Video $job.Start $job.Len $job.Mp4 $st.Enc } else { Get-Mp3Args $job.Video $job.Start $job.Len $job.Mp3 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $job.Proc = [Diagnostics.Process]::Start($psi)
    $st.Running = $job
    if ($job.Kind -eq 'mp4') { Set-Status $job.Row ("{0}  saving..." -f $job.Label) } else { Set-Status $job.Row ($ui.Slices.Items[$job.Row] + '   + MP3...') }
}

function Check-Jobs {
    $job = $st.Running
    if (-not $job -or -not $job.Proc.HasExited) { return }
    $code = $job.Proc.ExitCode
    $st.Running = $null
    if ($job.Kind -eq 'mp4' -and $code -ne 0 -and $st.Enc -ne 'libx264') {
        $st.Enc = 'libx264'; Reset-Encoder; Set-Title; $st.Jobs.Insert(0, $job)   # GPU encoder failed: retry on the CPU (re-detect next start)
    } elseif ($job.Kind -eq 'mp4') {
        $size = 0; try { $size = (Get-Item -LiteralPath $job.Mp4).Length } catch {}
        if ($code -eq 0 -and $size -lt 4096) {
            try { Remove-Item -LiteralPath $job.Mp4 -Force } catch {}
            Set-Status $job.Row ("{0}  FAILED (empty - is the part inside the video?)" -f $job.Label)
        } elseif ($code -eq 0) {
            [void]$st.Done.Add($job.Mp4)
            $mb = (Get-Item -LiteralPath $job.Mp4).Length / 1MB
            Set-Status $job.Row ("{0}  saved  {1}  ({2:N1} MB)" -f $job.Label, (Split-Path $job.Mp4 -Leaf), $mb)
        } else { Set-Status $job.Row ("{0}  FAILED (ffmpeg exit {1})" -f $job.Label, $code) }
    } else {
        $txt = ([string]$ui.Slices.Items[$job.Row]) -replace '   \+ MP3\.\.\.$', ''
        if ($code -ne 0) { Set-Status $job.Row ($txt + '   (MP3 failed)') }
        else { Set-Status $job.Row ($txt + '   + MP3') }
    }
    Start-Next-Job
}

function Cut-Slice {
    if (-not $st.Video) { return }
    $a = $st.Start; $b = $st.End
    if ($null -eq $a) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'Mark a start first [I]'; return }
    if ($null -eq $b -or $b -le $a) { $b = Pos }                 # no end marked: cut up to where the video is now
    if ($st.Dur -gt 0) {
        if ($a -ge $st.Dur) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'Start is past the end of the video'; return }
        $b = [math]::Min($b, $st.Dur)
    }
    if ($b -le $a) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'End must be after start'; return }
    $paths = Get-SlicePaths $st.Video $a $b
    # reserve the name now so two quick cuts never get the same file name
    New-Item -ItemType File -Path $paths.Mp4 -Force | Out-Null
    $label = '{0,2}. {1} -> {2}' -f ($ui.Slices.Items.Count + 1), (Short $a), (Short $b)
    $row = $ui.Slices.Items.Add("$label  queued")
    $ui.Slices.ScrollIntoView($ui.Slices.Items[$row])
    $base = @{ Video = $st.Video; Start = $a; Len = ($b - $a); Mp4 = $paths.Mp4; Mp3 = $paths.Mp3; Row = $row; Label = $label; Proc = $null }
    $j1 = $base.Clone(); $j1.Kind = 'mp4'; [void]$st.Jobs.Add($j1)
    if ($ui.ChkMp3.IsChecked) { $j2 = $base.Clone(); $j2.Kind = 'mp3'; [void]$st.Jobs.Add($j2) }
    $st.Start = $null; $st.End = $null
    Update-Marks
    Start-Next-Job
}

function Join-Slices {
    if ($st.Done.Count -lt 2) { [System.Windows.MessageBox]::Show('Cut at least 2 slices first (and wait until they are saved).', 'FragCut') | Out-Null; return }
    $script = Join-Path $PSScriptRoot 'Join.ps1'
    $argline = (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) + @($st.Done) | ForEach-Object { Quote-Arg $_ }) -join ' '
    Start-Process powershell.exe -ArgumentList $argline
}

function Next-Video {
    if ($st.Index + 1 -lt $queue.Count) { Load-Video ($st.Index + 1) }
    else { $ui.MarkText.Text = 'That was the last video - use "Open video..." to add more' }
}

# --- events ---
$ui.Player.Add_MediaOpened({
    if ($ui.Player.NaturalDuration.HasTimeSpan) { $st.Dur = $ui.Player.NaturalDuration.TimeSpan.TotalSeconds }
    else { $st.Dur = Get-Duration $ffprobe $st.Video }
    $ui.Seek.Maximum = [math]::Max(0.1, $st.Dur)
    Update-Marks
})
$ui.Player.Add_MediaEnded({ $ui.Player.Pause(); $st.Playing = $false })
$ui.Player.Add_MediaFailed({ param($s, $e) $ui.MarkText.Text = "Can't play this file: $($e.ErrorException.Message)" })

$ui.Seek.Add_PreviewMouseDown({ $st.Dragging = $true })
$ui.Seek.Add_PreviewMouseUp({ Seek-To $ui.Seek.Value; $st.Dragging = $false })
$ui.Seek.Add_ValueChanged({ if ($st.Dragging) { $ui.Player.Position = [TimeSpan]::FromSeconds($ui.Seek.Value) } })
$ui.Vol.Add_ValueChanged({ $ui.Player.Volume = $ui.Vol.Value })

$ui.BtnPlay.Add_Click({ Toggle-Play })
$ui.BtnStart.Add_Click({ $st.Start = Pos; if ($null -ne $st.End -and $st.End -le $st.Start) { $st.End = $null }; Update-Marks })
$ui.BtnEnd.Add_Click({ $st.End = Pos; Update-Marks })
$ui.BtnCut.Add_Click({ Cut-Slice })
$ui.BtnClear.Add_Click({ $st.Start = $null; $st.End = $null; Update-Marks })
$ui.BtnNext.Add_Click({ Next-Video })
$ui.BtnJoin.Add_Click({ Join-Slices })
$ui.BtnOpen.Add_Click({
    $new = Pick-Videos
    if ($new.Count) { $first = $queue.Count; foreach ($f in $new) { [void]$queue.Add($f) }; Load-Video $first }
})

$win.Add_PreviewKeyDown({
    param($s, $e)
    $shift = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift
    $ctrl  = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control
    $jump  = if ($ctrl) { 30 } elseif ($shift) { 5 } else { 0.5 }
    $h = $true
    switch ($e.Key.ToString()) {
        'Space'      { Toggle-Play }
        'Left'       { Seek-To ((Pos) - $jump) }
        'Right'      { Seek-To ((Pos) + $jump) }
        'OemComma'   { Step (-1.0 / 60) }
        'OemPeriod'  { Step (1.0 / 60) }
        { $_ -in 'I','OemOpenBrackets','Oem4' }  { $ui.BtnStart.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        { $_ -in 'O','OemCloseBrackets','Oem6' }             { $ui.BtnEnd.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        { $_ -in 'C','Return' }           { Cut-Slice }
        'N'          { Next-Video }
        'J'          { Join-Slices }
        'Up'         { $ui.Vol.Value = [math]::Min(1, $ui.Vol.Value + 0.05) }
        'Down'       { $ui.Vol.Value = [math]::Max(0, $ui.Vol.Value - 0.05) }
        { $_ -in 'Escape','Back','Delete' } { $st.Start = $null; $st.End = $null; Update-Marks }
        default      { $h = $false }
    }
    $e.Handled = $h
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    try {
        $p = Pos
        if (-not $st.Dragging) { $ui.Seek.Value = $p }
        $ui.TimeText.Text = '{0} / {1}' -f (Short $p), (Short $st.Dur)
        if ($null -ne $st.Start -and $null -eq $st.End) { Update-Marks }
        Check-Jobs
    } catch {}
})

$win.Add_SizeChanged({ Update-Marks })
$win.Add_Closing({
    param($s, $e)
    if ($st.Running -or $st.Jobs.Count) {
        $r = [System.Windows.MessageBox]::Show('Slices are still being saved. Close anyway? (unfinished ones will be lost)', 'FragCut', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        try { if ($st.Running) { $st.Running.Proc.Kill() } } catch {}
    }
    $timer.Stop(); $ui.Player.Stop(); $ui.Player.Close()
})

if ($SelfTest) {
    # automated check: mark 1.0-3.5 s, cut it (with MP3), wait for it to save, then close
    $script:tstep = 0
    $tt = New-Object Windows.Threading.DispatcherTimer
    $tt.Interval = [TimeSpan]::FromMilliseconds(500)
    $tt.Add_Tick({
        $script:tstep++
        if ($script:tstep -eq 4) { $ui.ChkMp3.IsChecked = $true; Seek-To 1.0; $st.Start = 1.0; $st.End = 3.5; Update-Marks; Cut-Slice }
        if ($script:tstep -gt 4 -and -not $st.Running -and $st.Jobs.Count -eq 0) {
            Write-Host "SELFTEST dur=$($st.Dur) pos=$(Pos) done=$($st.Done -join '|') rows=$($ui.Slices.Items -join ' || ')"
            $tt.Stop(); $win.Close()
        }
        if ($script:tstep -gt 120) { Write-Host 'SELFTEST timeout'; $tt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $tt.Start() })
}

$win.Add_Loaded({ Set-Title; Load-Video 0; $timer.Start() })
[void]$win.ShowDialog()

# remove placeholders of slices that never finished
foreach ($j in @($st.Jobs) + @($st.Running)) { if ($j -and $j.Kind -eq 'mp4') { try { $f = Get-Item -LiteralPath $j.Mp4 -EA Stop; if ($f.Length -eq 0) { Remove-Item -LiteralPath $j.Mp4 } } catch {} } }
if ($st.Done.Count -and -not $SelfTest) { Show-InFolder $st.Done[$st.Done.Count - 1] }

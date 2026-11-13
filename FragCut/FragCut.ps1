# FragCut - watch a recording, mark start/end while it plays, and cut slices with one key.
# Usage: right-click one or more recordings > Send to > FragCut  (or run with no files to pick them).
#
# Keys:  Space  play/pause          Left/Right  -/+ 0.5 s  (Shift = 5 s, Ctrl = 30 s)
#        , / .  one frame back/forward (pauses)
#        I  mark start   O  mark end   -> once both are marked, the marked part loops
#        Q / W  start earlier / later   E / R  end earlier / later   (0.2 s, Shift = 1 s)
#        Enter or C  cut the slice and keep watching     Esc  clear the marks
#        P / N  previous / next recording   J  join the slices cut in this window
#        Up/Down  playback speed (0.25x 0.5x 1x 2x 4x)     + / -  volume
#        K  find kills (Battlefield 6), then jump to the next kill and mark it   Shift+K  previous kill
# Slices are saved next to the recording. All slices use the same encoder settings,
# so Join stitches them without re-encoding.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [switch]$SelfTest, [switch]$KillTest)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Kills.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

function Fail($msg) { [System.Windows.MessageBox]::Show($msg, 'FragCut', 'OK', 'Error') | Out-Null; exit 1 }

try { $ffmpeg = Find-Tool 'ffmpeg'; $ffprobe = Find-Tool 'ffprobe' } catch { Fail $_.Exception.Message }

$queue = New-Object System.Collections.ArrayList
foreach ($f in $Files) { if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { [void]$queue.Add((Resolve-Path -LiteralPath $f).Path) } }
$queue = [System.Collections.ArrayList]@($queue | Sort-Object { Split-Path $_ -Leaf })

function Pick-Videos {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Pick recordings (Ctrl+click for several)'
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
        Title="FragCut" Width="1360" Height="880" MinWidth="900" MinHeight="580"
        Background="#1b1b1f" Foreground="#e8e8ea" WindowStartupLocation="CenterScreen" FontSize="14">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2d2d34"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="BorderBrush" Value="#44444c"/><Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="0,0,6,6"/><Setter Property="Focusable" Value="False"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#e8e8ea"/><Setter Property="Focusable" Value="False"/></Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="270"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="110"/>
    </Grid.RowDefinitions>

    <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="15" Foreground="#9aa0ff" Margin="0,0,0,8" TextTrimming="CharacterEllipsis"/>
    <Border Grid.Row="1" Background="Black">
      <MediaElement x:Name="Player" LoadedBehavior="Manual" UnloadedBehavior="Stop" ScrubbingEnabled="True" Stretch="Uniform"/>
    </Border>
    <Canvas x:Name="RangeCanvas" Grid.Row="2" Height="8" Margin="5,10,5,0">
      <Rectangle x:Name="RangeRect" Height="8" Fill="#f0a020" Width="0"/>
    </Canvas>
    <Canvas x:Name="KillCanvas" Grid.Row="2" Height="8" Margin="5,10,5,0" IsHitTestVisible="False"/>
    <Slider x:Name="Seek" Grid.Row="3" Minimum="0" Maximum="1" Focusable="False" Margin="0,2,0,0" Cursor="Hand"/>
    <DockPanel Grid.Row="4" Margin="0,8,0,0" LastChildFill="True">
      <TextBlock x:Name="TimeText" DockPanel.Dock="Left" FontFamily="Consolas" FontSize="18" VerticalAlignment="Center" Width="290"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="Vol" VerticalAlignment="Center" Margin="12,0,6,0"/>
        <Slider x:Name="Vol" Width="110" Minimum="0" Maximum="1" Value="0.6" Focusable="False" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock x:Name="MarkText" FontFamily="Consolas" FontSize="15" Foreground="#f0a020" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <WrapPanel Grid.Row="5" Margin="0,10,0,4">
      <Button x:Name="BtnPlay"  Content="Play/Pause [Space]"/>
      <Button x:Name="BtnStart" Content="Mark start [I]"/>
      <Button x:Name="BtnEnd"   Content="Mark end [O]"/>
      <Button x:Name="BtnClear" Content="Clear [Esc]"/>
      <Button x:Name="BtnCut"   Content="Cut slice [Enter]" Background="#3b5bdb"/>
      <Button x:Name="BtnJoin"  Content="Join slices [J]" Background="#2f9e44"/>
      <Button x:Name="BtnKills" Content="Find kills [K]" Background="#a61e4d" ToolTip="Battlefield 6: finds the kills in this recording. Then K = next kill, Shift+K = previous."/>
      <CheckBox x:Name="ChkMp3" Content="Also save MP3" VerticalAlignment="Center" Margin="6,0,0,6"/>
    </WrapPanel>
    <ListBox x:Name="Slices" Grid.Row="6" Background="#141417" Foreground="#e8e8ea" BorderBrush="#33333a" Focusable="False" FontFamily="Consolas"/>

    <DockPanel Grid.Column="2" Grid.Row="0" Grid.RowSpan="7">
      <TextBlock DockPanel.Dock="Top" Text="Recordings" FontSize="15" Foreground="#9aa0ff" Margin="0,0,0,8"/>
      <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
        <Button x:Name="BtnPrev" Content="Prev [P]"/>
        <Button x:Name="BtnNext" Content="Next [N]"/>
        <Button x:Name="BtnOpen" Content="Add..."/>
      </StackPanel>
      <TextBlock DockPanel.Dock="Bottom" TextWrapping="Wrap" Foreground="#8a8a92" FontSize="12" Margin="0,10,0,0"
                 Text="Marked part loops. Q/W = start earlier/later, E/R = end earlier/later (Shift = 1 s). Enter = cut and keep watching."/>
      <ListBox x:Name="Videos" Background="#141417" Foreground="#e8e8ea" BorderBrush="#33333a" Focusable="False"/>
    </DockPanel>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'TitleText','Player','RangeCanvas','RangeRect','KillCanvas','Seek','TimeText','MarkText','Vol','BtnPlay','BtnStart','BtnEnd','BtnClear','BtnCut','BtnJoin','BtnKills','ChkMp3','Slices','Videos','BtnPrev','BtnNext','BtnOpen') { $ui[$n] = $win.FindName($n) }

$st = @{
    Index = -1; Video = $null; Dur = 0.0; Playing = $false
    Dragging = $false; DragWasPlaying = $false
    Start = $null; End = $null
    LastSeek = 0.0; LastSeekAt = [datetime]::MinValue
    Jobs = New-Object System.Collections.ArrayList     # pending ffmpeg steps
    Running = $null                                    # current step
    Done = New-Object System.Collections.ArrayList     # finished slice mp4 files
    Enc = (Get-Encoder $ffmpeg)
    SyncingList = $false
    Speeds = @(0.25, 0.5, 1.0, 2.0, 4.0); SpeedIx = 2
    Scans = @{}                                        # video path -> running/finished kill scan
    Kills = $null                                      # kill times (s) of the current video, once known
    KillIx = -1; KillClip = $null                      # last kill jumped to, and the part marked for it
}

function Set-Status($i, $text) { $ui.Slices.Items[$i] = $text }
function Set-Title { $win.Title = "FragCut $FragCutVersion   -   encoding on: $(Get-EncoderName $st.Enc)" }
function Looping { ($null -ne $st.Start) -and ($null -ne $st.End) -and ($st.End -gt $st.Start) }

# ---------- recordings list ----------
function Refresh-Videos {
    $st.SyncingList = $true
    $ui.Videos.Items.Clear()
    foreach ($v in $queue) { [void]$ui.Videos.Items.Add(([IO.Path]::GetFileNameWithoutExtension($v) -replace '\.DVR$', '')) }
    if ($st.Index -ge 0) { $ui.Videos.SelectedIndex = $st.Index; $ui.Videos.ScrollIntoView($ui.Videos.SelectedItem) }
    $st.SyncingList = $false
}

function Load-Video([int]$i) {
    if ($i -lt 0 -or $i -ge $queue.Count) { return }
    $st.Index = $i; $st.Video = $queue[$i]; $st.Start = $null; $st.End = $null; $st.Dur = 0
    # kills already found for this recording (this session or an earlier one)?
    $st.KillIx = -1; $st.KillClip = $null
    $sc = $st.Scans[$st.Video]
    if ($sc) { $st.Kills = @($sc.Snapshot() | ForEach-Object { $_.Time }) } else { $st.Kills = Get-CachedKills $st.Video }
    $ui.KillCanvas.Children.Clear(); Set-KillButton
    Save-LastFolder $st.Video
    $ui.TitleText.Text = ('[{0}/{1}]  {2}' -f ($i + 1), $queue.Count, (Split-Path $st.Video -Leaf))
    $ui.Player.Source = New-Object Uri($st.Video)
    $ui.Player.Volume = $ui.Vol.Value
    Start-Playing; $st.Playing = $true
    $st.LastSeekAt = [datetime]::MinValue
    Refresh-Videos
    Update-Marks
}

# ---------- playback ----------
function Pos { $ui.Player.Position.TotalSeconds }

# Position to step from: right after a seek the player may still report the old position,
# so repeated key presses build on the last target instead.
function Base-Pos {
    if (([datetime]::Now - $st.LastSeekAt).TotalMilliseconds -lt 450) { return $st.LastSeek }
    return (Pos)
}

# Exact seek: while playing, the player snaps to keyframes, so pause, seek, then resume.
function Seek-To([double]$s) {
    if ($st.Dur -gt 0) { $s = [math]::Max(0.0, [math]::Min($s, $st.Dur - 0.02)) } else { $s = [math]::Max(0.0, $s) }
    if ($st.Playing) { $ui.Player.Pause() }
    $ui.Player.Position = [TimeSpan]::FromSeconds($s)
    if ($st.Playing) { Start-Playing }
    $ui.Seek.Value = $s
    $st.LastSeek = $s; $st.LastSeekAt = [datetime]::Now
}
# Play at the chosen speed (the player can forget the speed after a pause/seek, so set it every time)
function Start-Playing { $ui.Player.SpeedRatio = $st.Speeds[$st.SpeedIx]; $ui.Player.Play(); $ui.Player.SpeedRatio = $st.Speeds[$st.SpeedIx] }
function Play { Start-Playing; $st.Playing = $true }
function Change-Speed([int]$d) {
    $st.SpeedIx = [math]::Max(0, [math]::Min($st.Speeds.Count - 1, $st.SpeedIx + $d))
    $ui.Player.SpeedRatio = $st.Speeds[$st.SpeedIx]   # applies live while playing
}
function Speed-Text {
    $x = [double]$st.Speeds[$st.SpeedIx]
    if ($x -eq 1.0) { return '' }
    return ('   {0}x' -f $x.ToString([Globalization.CultureInfo]::InvariantCulture))
}
function Pause-Video { $ui.Player.Pause(); $st.Playing = $false }
function Toggle-Play { if ($st.Playing) { Pause-Video } else { Play } }
function Step([double]$d) { if ($st.Playing) { Pause-Video }; Seek-To ((Base-Pos) + $d) }

# ---------- marks ----------
function Update-Marks {
    if (Looping) {
        $ui.MarkText.Text = ('LOOP {0} -> {1}  ({2:N1} s)   Enter = cut   Q/W start  E/R end   Esc = cancel' -f (Short $st.Start), (Short $st.End), ($st.End - $st.Start))
    } else {
        $s = if ($null -ne $st.Start) { Short $st.Start } else { '--' }
        $e = if ($null -ne $st.End)   { Short $st.End }   else { '--' }
        $ui.MarkText.Text = "Start $s   End $e"
    }
    $w = $ui.RangeCanvas.ActualWidth
    if ($st.Dur -gt 0 -and $w -gt 0 -and $null -ne $st.Start) {
        $a = $st.Start; $b = if ($null -ne $st.End -and $st.End -gt $a) { $st.End } else { [math]::Max((Pos), $a) }
        [Windows.Controls.Canvas]::SetLeft($ui.RangeRect, $w * $a / $st.Dur)
        $ui.RangeRect.Width = [math]::Max(2.0, $w * ($b - $a) / $st.Dur)
    } else { $ui.RangeRect.Width = 0 }
}

function Start-Loop { Seek-To $st.Start; Play; Update-Marks }

function Mark-Start {
    $st.Start = Base-Pos
    if ($null -ne $st.End -and $st.End -le $st.Start + 0.05) { $st.End = $null }
    if (Looping) { Start-Loop } else { Update-Marks }
}
function Mark-End {
    $p = Base-Pos
    if ($null -ne $st.Start -and $p -le $st.Start + 0.05) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'End must be after start'; return }
    $st.End = $p
    if (Looping) { Start-Loop } else { Update-Marks }
}
function Clear-Marks { $st.Start = $null; $st.End = $null; Update-Marks }

# Q/W/E/R: move the start or end of the marked part, then replay that edge.
function Nudge([string]$which, [double]$d) {
    if (-not (Looping)) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'Mark a start [I] and an end [O] first'; return }
    if ($which -eq 'start') {
        $st.Start = [math]::Max(0.0, [math]::Min($st.Start + $d, $st.End - 0.1))
        Seek-To $st.Start
    } else {
        $max = if ($st.Dur -gt 0) { $st.Dur } else { $st.End + 3600 }
        $st.End = [math]::Min($max, [math]::Max($st.End + $d, $st.Start + 0.1))
        Seek-To ([math]::Max($st.Start, $st.End - 1.5))      # hear the last 1.5 s
    }
    Play; Update-Marks
}

# ---------- cutting ----------
function Start-Next-Job {
    if ($st.Running -or $st.Jobs.Count -eq 0) { return }
    $job = $st.Jobs[0]; $st.Jobs.RemoveAt(0)
    # OBS open (e.g. recording this window)? Share the GPU encoder: lighter preset, paced, low priority.
    $gentle = ($job.Kind -eq 'mp4') -and (Test-ObsRunning)
    $argv = if ($job.Kind -eq 'mp4') { Get-CutArgs $job.Video $job.Start $job.Len $job.Mp4 $st.Enc -Gentle:$gentle } else { Get-Mp3Args $job.Video $job.Start $job.Len $job.Mp3 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $job.Proc = [Diagnostics.Process]::Start($psi)
    if ($gentle) { try { $job.Proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
    $st.Running = $job
    if ($job.Kind -eq 'mp4') { Set-Status $job.Row ("{0}  saving{1}..." -f $job.Label, $(if ($gentle) { ' (gently - OBS is open)' } else { '' })) } else { Set-Status $job.Row ($ui.Slices.Items[$job.Row] + '   + MP3...') }
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
            Set-Status $job.Row ("{0}  saved  {1}  ({2:N1} MB)" -f $job.Label, (Split-Path $job.Mp4 -Leaf), ($size / 1MB))
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
    $looping = Looping
    if (-not $looping) { $b = Base-Pos }                        # no end marked: cut up to where the video is now
    if ($st.Dur -gt 0) {
        if ($a -ge $st.Dur) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'Start is past the end of the video'; return }
        $b = [math]::Min($b, $st.Dur)
    }
    if ($b -le $a) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'End must be after start'; return }
    $paths = Get-SlicePaths $st.Video $a $b
    New-Item -ItemType File -Path $paths.Mp4 -Force | Out-Null   # reserve the name so quick cuts never collide
    $label = '{0,2}. {1} -> {2}' -f ($ui.Slices.Items.Count + 1), (Short $a), (Short $b)
    $row = $ui.Slices.Items.Add("$label  queued")
    $ui.Slices.ScrollIntoView($ui.Slices.Items[$row])
    $base = @{ Video = $st.Video; Start = $a; Len = ($b - $a); Mp4 = $paths.Mp4; Mp3 = $paths.Mp3; Row = $row; Label = $label; Proc = $null }
    $j1 = $base.Clone(); $j1.Kind = 'mp4'; [void]$st.Jobs.Add($j1)
    if ($ui.ChkMp3.IsChecked) { $j2 = $base.Clone(); $j2.Kind = 'mp3'; [void]$st.Jobs.Add($j2) }
    $st.Start = $null; $st.End = $null
    if ($looping) { Seek-To $b; Play }                          # keep watching from the end of the slice
    Update-Marks
    Start-Next-Job
}

function Join-Slices {
    if ($st.Done.Count -lt 2) { [System.Windows.MessageBox]::Show('Cut at least 2 slices first (and wait until they are saved).', 'FragCut') | Out-Null; return }
    $script = Join-Path $PSScriptRoot 'Join.ps1'
    $argline = (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) + @($st.Done) | ForEach-Object { Quote-Arg $_ }) -join ' '
    Start-Process powershell.exe -ArgumentList $argline
}

function Next-Video { if ($st.Index + 1 -lt $queue.Count) { Load-Video ($st.Index + 1) } else { $ui.MarkText.Text = 'That was the last recording - use "Add..." for more' } }
function Prev-Video { if ($st.Index -gt 0) { Load-Video ($st.Index - 1) } else { $ui.MarkText.Text = 'This is the first recording' } }

# ---------- kills (Battlefield 6): find them, mark them on the timeline, jump between them ----------
$KillBefore = 8.0; $KillAfter = 2.0          # clip around a kill: 8 s before its tag appears, 2 s after
$st.ScanDone = @{}                            # video path -> results handled
$killBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(255, 77, 77))

function On-KillClip { ($st.KillIx -ge 0) -and $st.KillClip -and ($st.Start -eq $st.KillClip[0]) -and ($st.End -eq $st.KillClip[1]) }

function Draw-KillTicks {
    $ui.KillCanvas.Children.Clear()
    $w = $ui.KillCanvas.ActualWidth
    if (-not $st.Kills -or $st.Dur -le 0 -or $w -le 0) { return }
    foreach ($t in $st.Kills) {
        $r = New-Object Windows.Shapes.Rectangle
        $r.Width = 3; $r.Height = 8; $r.Fill = $killBrush
        [Windows.Controls.Canvas]::SetLeft($r, [math]::Max(0.0, $w * $t / $st.Dur - 1.5))
        [void]$ui.KillCanvas.Children.Add($r)
    }
}

function Set-KillButton {
    $sc = $st.Scans[$st.Video]
    $n = if ($null -eq $st.Kills) { 0 } else { @($st.Kills).Count }
    if ($sc -and -not $sc.Done) {
        $txt = 'Finding kills {0:N0}%' -f ($sc.Progress * 100)
        if ($n) { $txt += "  ($n so far)" }
    }
    elseif ($null -eq $st.Kills) { $txt = 'Find kills [K]' }
    elseif ($n -eq 0)            { $txt = 'No kills found' }
    elseif (On-KillClip)         { $txt = 'Kill {0} of {1}  [K next, Shift+K back]' -f ($st.KillIx + 1), $n }
    else                         { $txt = "$n kills - next [K]" }
    if ([string]$ui.BtnKills.Content -ne $txt) { $ui.BtnKills.Content = $txt }
}

function Find-Kills {
    $v = $st.Video
    try {
        $wh = (& $ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$v" | Select-Object -First 1).Split(',')
        $dur = if ($st.Dur -gt 0) { $st.Dur } else { Get-Duration $ffprobe $v }
        $st.Scans[$v] = Start-KillScan $ffmpeg $v $dur ([int]$wh[0]) ([int]$wh[1])
        $st.Kills = @()
        $ui.MarkText.Text = 'Looking for kills - keep watching. Red marks appear on the timeline as they are found.'
    } catch {
        [System.Media.SystemSounds]::Beep.Play()
        $ui.MarkText.Text = "Find kills: $($_.Exception.Message)"
    }
    Set-KillButton
}

# K: find the kills first; after that, jump to the next one (Shift+K: previous) and mark its clip, looping.
function Kill-Key([int]$dir) {
    if (-not $st.Video) { return }
    if ($null -eq $st.Kills) { Find-Kills; return }
    $k = @($st.Kills)
    $sc = $st.Scans[$st.Video]; $running = $sc -and -not $sc.Done
    if ($k.Count -eq 0) {
        [System.Media.SystemSounds]::Beep.Play()
        $ui.MarkText.Text = if ($running) { 'Still looking for kills...' } else { 'No kills found in this recording' }
        return
    }
    if (On-KillClip) { $i = $st.KillIx + $dir }
    else {
        $p = Base-Pos
        if ($dir -gt 0) { $i = 0; while ($i -lt $k.Count -and $k[$i] + $KillAfter -le $p + 0.05) { $i++ } }
        else { $i = $k.Count - 1; while ($i -ge 0 -and $k[$i] + $KillAfter -ge $p - 0.05) { $i-- } }
    }
    if ($i -lt 0) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'No earlier kill'; return }
    if ($i -ge $k.Count) {
        [System.Media.SystemSounds]::Beep.Play()
        $ui.MarkText.Text = if ($running) { 'No later kill found yet - still looking...' } else { 'That was the last kill' }
        return
    }
    $t = $k[$i]
    $a = [math]::Max(0.0, $t - $KillBefore); $b = $t + $KillAfter
    if ($st.Dur -gt 0) { $b = [math]::Min($b, $st.Dur) }
    $st.Start = $a; $st.End = $b; $st.KillIx = $i; $st.KillClip = @($a, $b)
    Start-Loop
    Set-KillButton
}

# timer: pick up new results, save finished ones
function Check-Scans {
    foreach ($v in @($st.Scans.Keys)) {
        if ($st.ScanDone[$v]) { continue }
        $sc = $st.Scans[$v]
        $done = $sc.Done
        $times = @($sc.Snapshot() | ForEach-Object { $_.Time })
        $known = if ($null -eq $st.Kills) { -1 } else { @($st.Kills).Count }
        if ($v -eq $st.Video -and $times.Count -ne $known) { $st.Kills = $times; Draw-KillTicks }
        if ($done) {
            $st.ScanDone[$v] = $true
            if ($sc.Error) {
                $st.Scans.Remove($v)
                if ($v -eq $st.Video) { $st.Kills = $null; Draw-KillTicks; $ui.MarkText.Text = "Find kills failed: $($sc.Error)" }
            } else {
                Save-CachedKills $v $times
                if ($v -eq $st.Video) {
                    $st.Kills = $times; Draw-KillTicks
                    $ui.MarkText.Text = if ($times.Count) { "Found $($times.Count) kill moments - press K to jump to them" } else { 'No kills found in this recording' }
                }
            }
        }
    }
    if ($st.Video) { Set-KillButton }
}

# ---------- timeline: click to jump, drag to scrub (paused + muted while dragging) ----------
function Value-At([double]$x) {
    # x = position on the timeline track; the thumb's centre covers [half thumb .. width - half thumb]
    $track = $ui.Seek.Template.FindName('PART_Track', $ui.Seek)
    $w = $ui.Seek.ActualWidth; $tw = 0.0
    if ($track) { $w = $track.ActualWidth; if ($track.Thumb) { $tw = $track.Thumb.ActualWidth } }
    $frac = ($x - $tw / 2) / [math]::Max(1.0, $w - $tw)
    return $ui.Seek.Maximum * [math]::Max(0.0, [math]::Min(1.0, $frac))
}
function Track-Value($e) {
    $track = $ui.Seek.Template.FindName('PART_Track', $ui.Seek)
    $rel = if ($track) { $track } else { $ui.Seek }
    return (Value-At ($e.GetPosition($rel).X))
}
$ui.Seek.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $st.Dragging = $true; $st.DragWasPlaying = $st.Playing
    if ($st.Playing) { Pause-Video }
    $ui.Player.IsMuted = $true
    [void]$ui.Seek.CaptureMouse()
    Seek-To (Track-Value $e)
})
$ui.Seek.Add_PreviewMouseMove({
    param($s, $e)
    if (-not $st.Dragging) { return }
    $e.Handled = $true
    $v = Track-Value $e
    $ui.Seek.Value = $v
    $ui.Player.Position = [TimeSpan]::FromSeconds($v)
    $st.LastSeek = $v; $st.LastSeekAt = [datetime]::Now
})
function End-Drag {
    if (-not $st.Dragging) { return }
    $st.Dragging = $false
    $ui.Player.IsMuted = $false
    if ($st.DragWasPlaying) { Play }
}
$ui.Seek.Add_PreviewMouseLeftButtonUp({ param($s, $e) $e.Handled = $true; if ($st.Dragging) { Seek-To (Track-Value $e) }; $ui.Seek.ReleaseMouseCapture(); End-Drag })
$ui.Seek.Add_LostMouseCapture({ End-Drag })

# ---------- events ----------
$ui.Player.Add_MediaOpened({
    # the player rounds the length down to whole seconds; ffprobe gives the exact length
    $d = 0.0; try { $d = Get-Duration $ffprobe $st.Video } catch {}
    if ($ui.Player.NaturalDuration.HasTimeSpan) { $d = [math]::Max($d, $ui.Player.NaturalDuration.TimeSpan.TotalSeconds) }
    $st.Dur = $d
    $ui.Seek.Maximum = [math]::Max(0.1, $st.Dur)
    Update-Marks
    Draw-KillTicks
})
$ui.Player.Add_MediaEnded({ if (Looping) { Seek-To $st.Start; Play } else { Pause-Video } })
$ui.Player.Add_MediaFailed({ param($s, $e) $ui.MarkText.Text = "Can't play this file: $($e.ErrorException.Message)" })
$ui.Vol.Add_ValueChanged({ $ui.Player.Volume = $ui.Vol.Value })

$ui.BtnPlay.Add_Click({ Toggle-Play })
$ui.BtnStart.Add_Click({ Mark-Start })
$ui.BtnEnd.Add_Click({ Mark-End })
$ui.BtnClear.Add_Click({ Clear-Marks })
$ui.BtnCut.Add_Click({ Cut-Slice })
$ui.BtnJoin.Add_Click({ Join-Slices })
$ui.BtnKills.Add_Click({ Kill-Key 1 })
$ui.BtnNext.Add_Click({ Next-Video })
$ui.BtnPrev.Add_Click({ Prev-Video })
$ui.BtnOpen.Add_Click({
    $new = Pick-Videos
    if ($new.Count) { $first = $queue.Count; foreach ($f in $new) { [void]$queue.Add($f) }; Load-Video $first }
})
$ui.Videos.Add_SelectionChanged({
    if ($st.SyncingList) { return }
    $i = $ui.Videos.SelectedIndex
    if ($i -ge 0 -and $i -ne $st.Index) { Load-Video $i }
})

$win.Add_PreviewKeyDown({
    param($s, $e)
    $shift = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)
    $ctrl  = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
    $jump  = if ($ctrl) { 30 } elseif ($shift) { 5 } else { 0.5 }
    $nudge = if ($shift) { 1.0 } else { 0.2 }
    $h = $true
    switch ($e.Key.ToString()) {
        'Space'      { Toggle-Play }
        'Left'       { Seek-To ((Base-Pos) - $jump) }
        'Right'      { Seek-To ((Base-Pos) + $jump) }
        'OemComma'   { Step (-1.0 / 60) }
        'OemPeriod'  { Step (1.0 / 60) }
        { $_ -in 'I','OemOpenBrackets','Oem4' }  { Mark-Start }
        { $_ -in 'O','OemCloseBrackets','Oem6' } { Mark-End }
        'Q'          { Nudge 'start' (-$nudge) }
        'W'          { Nudge 'start' $nudge }
        'E'          { Nudge 'end' (-$nudge) }
        'R'          { Nudge 'end' $nudge }
        { $_ -in 'C','Return' } { Cut-Slice }
        'N'          { Next-Video }
        'P'          { Prev-Video }
        'J'          { Join-Slices }
        'K'          { Kill-Key $(if ($shift) { -1 } else { 1 }) }
        'Up'         { Change-Speed 1 }
        'Down'       { Change-Speed -1 }
        { $_ -in 'OemPlus','Add' }       { $ui.Vol.Value = [math]::Min(1.0, $ui.Vol.Value + 0.05) }
        { $_ -in 'OemMinus','Subtract' } { $ui.Vol.Value = [math]::Max(0.0, $ui.Vol.Value - 0.05) }
        { $_ -in 'Escape','Back','Delete' } { Clear-Marks }
        default      { $h = $false }
    }
    $e.Handled = $h
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({
    try {
        $p = Pos
        # loop the marked part
        if ((Looping) -and $st.Playing -and -not $st.Dragging -and $p -ge $st.End -and ([datetime]::Now - $st.LastSeekAt).TotalMilliseconds -gt 150) { Seek-To $st.Start; $p = $st.Start }
        if (-not $st.Dragging) { $ui.Seek.Value = $p }
        $ui.TimeText.Text = '{0} / {1}{2}' -f (Short $p), (Short $st.Dur), (Speed-Text)
        if ($null -ne $st.Start -and $null -eq $st.End) { Update-Marks }
        Check-Jobs
        Check-Scans
    } catch {}
})

$win.Add_SizeChanged({ Update-Marks; Draw-KillTicks })
$win.Add_Closing({
    param($s, $e)
    if ($st.Running -or $st.Jobs.Count) {
        $r = [System.Windows.MessageBox]::Show('Slices are still being saved. Close anyway? (unfinished ones will be lost)', 'FragCut', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        try { if ($st.Running) { $st.Running.Proc.Kill() } } catch {}
    }
    foreach ($sc in @($st.Scans.Values)) { if (-not $sc.Done) { $sc.Cancel() } }    # unfinished kill scans
    $timer.Stop(); $ui.Player.Stop(); $ui.Player.Close()
})

if ($SelfTest) {
    # automated check: seeking, marks, loop, nudge, cut (with MP3); prints results, then closes
    $script:tstep = 0
    $script:tlog = New-Object System.Collections.ArrayList
    $tt = New-Object Windows.Threading.DispatcherTimer
    $tt.Interval = [TimeSpan]::FromMilliseconds(250)
    $tt.Add_Tick({
        $script:tstep++
        $k = $script:tstep
        function L($m) { [void]$script:tlog.Add($m) }
        if ($k -ge 6 -and $k -le 30) { L ("t{0} pos={1:N2} playing={2}" -f $k, (Pos), $st.Playing) }
        switch ($k) {
            6  { Seek-To 4.0; L "  >> seek 4.0"; $tr = $ui.Seek.Template.FindName('PART_Track', $ui.Seek); L ("  >> timeline: left={0:N2} middle={1:N2} right={2:N2} (length {3:N2})" -f (Value-At 0), (Value-At ($tr.ActualWidth / 2)), (Value-At $tr.ActualWidth), $st.Dur) }
            10 { $bp = Base-Pos; $pp = Pos; $age = ([datetime]::Now - $st.LastSeekAt).TotalMilliseconds; Seek-To ($bp - 0.5); L ("  >> back 0.5: base={0:N2} -> target {1:N2}  (dur={2:N2})" -f $bp, $st.LastSeek, $st.Dur) }
            14 { Seek-To ((Base-Pos) - 0.5); Seek-To ((Base-Pos) - 0.5); L ("  >> back 0.5 twice fast -> target {0:N2}" -f $st.LastSeek) }
            18 { Seek-To 1.0; Mark-Start; Seek-To 2.5; Mark-End; L ("  >> marked 1.0-2.5 looping={0}" -f (Looping)) }
            28 { Nudge 'end' 0.2; Nudge 'start' (-0.2); L ("  >> nudged: {0:N1}-{1:N1}" -f $st.Start, $st.End) }
            31 { $ui.ChkMp3.IsChecked = $true; Cut-Slice; L ("  >> cut, target after cut={0:N2}" -f $st.LastSeek) }
            33 { L ("t33 pos={0:N2} playing={1}" -f (Pos), $st.Playing) }
            34 { Seek-To 6.0; Change-Speed 1; $script:sp = Pos; L ("  >> speed now {0}" -f (Speed-Text)) }
            38 { L ("  2x: moved {0:N2} s in 1 s" -f ((Pos) - $script:sp)); Change-Speed 1; Change-Speed 1; $script:sp = Pos; L ("  >> speed now {0} (Up pressed past the top)" -f (Speed-Text)) }
            42 { L ("  4x: moved {0:N2} s in 1 s" -f ((Pos) - $script:sp)); Change-Speed -1; Change-Speed -1; Change-Speed -1; $script:sp = Pos; L ("  >> speed now {0}" -f (Speed-Text)) }
            44 { L ("  0.5x: moved {0:N2} s in 0.5 s" -f ((Pos) - $script:sp)); Change-Speed -1; $script:sp = Pos; L ("  >> speed now {0}" -f (Speed-Text)) }
            46 { L ("  0.25x: moved {0:N2} s in 1 s" -f ((Pos) - $script:sp)); Seek-To 2.0; $script:sp = Pos }
            50 { L ("  0.25x after a seek: moved {0:N2} s in 1 s (speed must stick)" -f ((Pos) - $script:sp)) }
        }
        if ($k -gt 50 -and -not $st.Running -and $st.Jobs.Count -eq 0) {
            Write-Host ("SELFTEST`n  " + ($script:tlog -join "`n  ") + "`n  slices: " + ($ui.Slices.Items -join ' || '))
            $tt.Stop(); $win.Close()
        }
        if ($k -gt 160) { Write-Host 'SELFTEST timeout'; $tt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $tt.Start() })
}

if ($KillTest) {
    # automated check of Find kills: K (scan), then K, K, Shift+K; prints what happened, then closes
    $script:kstep = 0; $script:klog = New-Object System.Collections.ArrayList; $script:kphase = 0
    $kt = New-Object Windows.Threading.DispatcherTimer
    $kt.Interval = [TimeSpan]::FromMilliseconds(250)
    $kt.Add_Tick({
        $script:kstep++
        function L($m) { [void]$script:klog.Add($m) }
        function Marks { '{0}-{1} ix={2} button="{3}"' -f $(if ($null -ne $st.Start) { Short $st.Start } else { '--' }), $(if ($null -ne $st.End) { Short $st.End } else { '--' }), $st.KillIx, $ui.BtnKills.Content }
        if ($script:kstep -eq 4) {
            L ("at start: kills known = {0}, button=""{1}""" -f $(if ($null -eq $st.Kills) { 'no' } else { "yes ($(@($st.Kills).Count), from cache)" }), $ui.BtnKills.Content)
            Kill-Key 1; L ("K -> button=""{0}""  text=""{1}""" -f $ui.BtnKills.Content, $ui.MarkText.Text)
            $script:kphase = 1; $script:kt0 = [datetime]::Now
        }
        if ($script:kphase -eq 1 -and ($st.ScanDone[$st.Video] -or -not $st.Scans.ContainsKey($st.Video))) {
            $sc = $st.Scans[$st.Video]
            if ($sc) { L ("scan finished in {0:N0} s, {1} frames" -f ([datetime]::Now - $script:kt0).TotalSeconds, $sc.Frames) }
            L ("kills: " + (@($st.Kills | ForEach-Object { Short $_ }) -join ', '))
            L ("timeline marks drawn: {0}" -f $ui.KillCanvas.Children.Count)
            Kill-Key 1;  L ("K       -> " + (Marks))
            Kill-Key 1;  L ("K       -> " + (Marks))
            Kill-Key -1; L ("Shift+K -> " + (Marks))
            $script:kphase = 2; $script:kpos = $script:kstep
        }
        if ($script:kphase -eq 2 -and $script:kstep -eq $script:kpos + 8) {
            L ("looping: pos={0} within {1}-{2}: {3}" -f (Short (Pos)), (Short $st.Start), (Short $st.End), ((Pos) -ge $st.Start - 0.1 -and (Pos) -le $st.End + 0.1))
            Write-Host ("KILLTEST`n  " + ($script:klog -join "`n  ")); $kt.Stop(); $win.Close()
        }
        if ($script:kstep -gt 480) { Write-Host ("KILLTEST timeout`n  " + ($script:klog -join "`n  ")); $kt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $kt.Start() })
}

$win.Add_Loaded({ Set-Title; Load-Video 0; $timer.Start() })
[void]$win.ShowDialog()

# remove placeholders of slices that never finished
foreach ($j in @($st.Jobs) + @($st.Running)) { if ($j -and $j.Kind -eq 'mp4') { try { $f = Get-Item -LiteralPath $j.Mp4 -EA Stop; if ($f.Length -eq 0) { Remove-Item -LiteralPath $j.Mp4 } } catch {} } }
if ($st.Done.Count -and -not $SelfTest) { Show-InFolder $st.Done[$st.Done.Count - 1] }

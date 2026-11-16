# FragCut - watch a recording, mark start/end while it plays, and cut slices with one key.
# Usage: run it (opens the folder set with "Set folder..."), or right-click recordings or a folder > Send to > FragCut.
#
# Keys:  Space  play/pause          Left/Right  -/+ 0.5 s  (Shift = 5 s, Ctrl = 30 s)
#        , / .  one frame back/forward (pauses)
#        I  mark start   O  mark end   -> once both are marked, the marked part loops
#        Q / W  start earlier / later   E / R  end earlier / later   (0.2 s, Shift = 1 s)
#        Enter or C  cut the slice and keep watching     Esc  clear the marks
#        P / N  previous / next recording   J  join the slices cut in this window
#        Up/Down  playback speed (0.25x 0.5x 1x 2x 4x)     + / -  volume
#        K  find kills (Battlefield 6), then jump to the next kill and mark it   Shift+K  previous kill
# Slices are saved in a "clips" folder next to the recording. All slices use the same encoder settings,
# so Join stitches them without re-encoding.

[CmdletBinding(PositionalBinding = $false)]   # file names always go into $Files
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [switch]$SelfTest, [switch]$KillTest, [switch]$PreviewTest, [switch]$FastTest, [switch]$RoundTest, [switch]$GripTest, [switch]$LibTest, [string]$ShotTest, [string]$Shots)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Kills.ps1')
. (Join-Path $PSScriptRoot 'Mpv.ps1')
. (Join-Path $PSScriptRoot 'Rounds.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, WindowsFormsIntegration

function Fail($msg) { [System.Windows.MessageBox]::Show($msg, 'FragCut', 'OK', 'Error') | Out-Null; exit 1 }

try { $ffmpeg = Find-Tool 'ffmpeg'; $ffprobe = Find-Tool 'ffprobe' } catch { Fail $_.Exception.Message }

$queue = New-Object System.Collections.ArrayList     # every recording in the list, in list order (P / N)
$sentFiles = New-Object System.Collections.ArrayList
$sentDir = $null
foreach ($f in $Files) {
    if (-not $f) { continue }
    if (Test-Path -LiteralPath $f -PathType Container) { if (-not $sentDir) { $sentDir = (Resolve-Path -LiteralPath $f).Path } }
    elseif (Test-Path -LiteralPath $f -PathType Leaf) { [void]$sentFiles.Add((Resolve-Path -LiteralPath $f).Path) }
}
$sentFiles = [System.Collections.ArrayList]@($sentFiles | Sort-Object { Get-NaturalKey (Split-Path $_ -Leaf) })
# The folder the list shows: a folder sent to FragCut, else the game folder of the first file sent, else the one set with "Set folder..."
$script:Root = if ($sentDir) { $sentDir } elseif ($sentFiles.Count) { Get-GameDir $sentFiles[0] } else { (Get-Settings).WorkFolder }
if (-not $script:Root -and -not $sentFiles.Count) {
    # no folder set yet: the folder used last (its game folder, if that was a round folder)
    $last = (Get-Settings).LastFolder
    if ($last -and (Test-Path -LiteralPath $last -PathType Container)) { $script:Root = if ((Split-Path $last -Leaf) -match '^[A-Za-z0-9_]+-\d+( |$)') { Split-Path $last -Parent } else { $last } }
}
if ($script:Root -and -not (Test-Path -LiteralPath $script:Root -PathType Container)) { $script:Root = $null }
$script:Extra = New-Object System.Collections.ArrayList   # files opened from somewhere else than that folder

function Pick-Videos {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Pick recordings (Ctrl+click for several)'
    $dlg.Filter = 'Videos|*.mp4;*.mkv;*.mov;*.avi;*.webm|All files|*.*'
    $dlg.Multiselect = $true
    $dlg.InitialDirectory = Get-StartFolder
    if ($dlg.ShowDialog() -eq 'OK') { Save-LastFolder $dlg.FileNames[0]; return @($dlg.FileNames | Sort-Object { Get-NaturalKey (Split-Path $_ -Leaf) }) }
    return @()
}
if ($sentFiles.Count -eq 0 -and $SelfTest) { Write-Host 'SELFTEST no video given'; exit 1 }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FragCut" Width="1400" Height="900" MinWidth="980" MinHeight="620"
        Background="#141417" Foreground="#e8e8ea" WindowStartupLocation="CenterScreen" FontSize="14" FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel" Color="#1d1d22"/>
    <SolidColorBrush x:Key="Line" Color="#2e2e36"/>
    <SolidColorBrush x:Key="Muted" Color="#8d8d97"/>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2a2a31"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="BorderBrush" Value="#3a3a43"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="11,5"/><Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Focusable" Value="False"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3b5bdb"/><Setter Property="BorderBrush" Value="#4c6ef5"/><Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="Success" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2b8a3e"/><Setter Property="BorderBrush" Value="#37b24d"/><Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="Round" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2e2650"/><Setter Property="BorderBrush" Value="#5f3dc4"/><Setter Property="Foreground" Value="#d0bfff"/>
    </Style>
    <Style x:Key="Kills" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#3a1d2a"/><Setter Property="BorderBrush" Value="#a61e4d"/><Setter Property="Foreground" Value="#faa2c1"/>
    </Style>
    <Style x:Key="Icon" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="9,6"/>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#c9c9d1"/><Setter Property="Focusable" Value="False"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="Focusable" Value="False"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="6,2"/><Setter Property="Foreground" Value="#e8e8ea"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="B" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="0,0,0,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#26262e"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="#2c3354"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel Margin="12">
    <!-- top bar: the folder FragCut works in -->
    <Border DockPanel.Dock="Top" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="10,8" Margin="0,0,0,12">
      <DockPanel>
        <TextBlock DockPanel.Dock="Left" Text="FragCut" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center" Margin="2,0,14,0"/>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnOpen" Content="Add files..." Style="{StaticResource Ghost}" Foreground="#a8a8b3" ToolTip="Add recordings from another folder to the list"/>
          <TextBlock x:Name="InfoText" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center" Margin="8,0,2,0"/>
        </StackPanel>
        <Border x:Name="FolderBar" Background="#1f2742" BorderBrush="#3b5bdb" BorderThickness="1" CornerRadius="6" Padding="10,5" Cursor="Hand" ToolTip="The folder with your recordings. Click to change it.">
          <DockPanel>
            <TextBlock DockPanel.Dock="Left" Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#91a7ff" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <Button x:Name="BtnFolder" DockPanel.Dock="Right" Content="Change folder" Style="{StaticResource Primary}" Margin="10,0,0,0" Padding="12,4"/>
            <TextBlock x:Name="FolderName" FontWeight="SemiBold" FontSize="15" Foreground="#dbe4ff" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock x:Name="FolderPath" Foreground="#91a7ff" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
        </Border>
      </DockPanel>
    </Border>

    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="330"/></Grid.ColumnDefinitions>

      <!-- left: player, controls, clip list -->
      <Grid Grid.Column="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="170"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="14" Foreground="#c9c9d1" Margin="2,0,0,8" TextTrimming="CharacterEllipsis"/>
        <Border x:Name="VideoBox" Grid.Row="1" Background="Black" CornerRadius="6">
          <MediaElement x:Name="Player" LoadedBehavior="Manual" UnloadedBehavior="Stop" ScrubbingEnabled="True" Stretch="Uniform"/>
        </Border>
        <Canvas x:Name="RangeCanvas" Grid.Row="2" Height="14" Margin="5,7,5,-3" Background="Transparent">
          <Rectangle x:Name="RangeRect" Canvas.Top="3" Height="8" Fill="#f0a020" Width="0" RadiusX="2" RadiusY="2"/>
          <Rectangle x:Name="StartGrip" Width="4" Height="14" Fill="#ffe2a8" Visibility="Collapsed"/>
          <Rectangle x:Name="EndGrip" Width="4" Height="14" Fill="#ffe2a8" Visibility="Collapsed"/>
        </Canvas>
        <Canvas x:Name="KillCanvas" Grid.Row="2" Height="8" Margin="5,10,5,0" IsHitTestVisible="False"/>
        <Slider x:Name="Seek" Grid.Row="3" Minimum="0" Maximum="1" Focusable="False" Margin="0,2,0,0" Cursor="Hand"/>
        <DockPanel Grid.Row="4" Margin="0,6,0,0" LastChildFill="True">
          <TextBlock x:Name="TimeText" DockPanel.Dock="Left" FontFamily="Consolas" FontSize="17" VerticalAlignment="Center" Width="270"/>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="&#xE767;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="12,0,8,0"/>
            <Slider x:Name="Vol" Width="110" Minimum="0" Maximum="1" Value="0.6" Focusable="False" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="MarkText" FontFamily="Consolas" FontSize="14" Foreground="#f0a020" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <!-- controls: playback | marking and cutting | kills | options -->
        <DockPanel Grid.Row="5" Margin="0,10,0,10">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <CheckBox x:Name="ChkFast" Content="Fast cut" Margin="0,0,14,0"
                      ToolTip="Fast cut (no re-encode): copies the video as it is - instant, original quality and size per second, same format as the recording. The clip starts on the nearest full picture (keyframe) before your mark, usually up to 0.5-2 s earlier. Clips stay in the recording's format (AV1 / HEVC clips may not play everywhere)."/>
            <CheckBox x:Name="ChkMp3" Content="Also MP3" ToolTip="Also save the sound of each clip (and montage) as an MP3"/>
          </StackPanel>
          <WrapPanel>
            <Button x:Name="BtnPrev" Content="&#xE892;" Style="{StaticResource Icon}" ToolTip="Previous recording [P]" Margin="0,0,4,0"/>
            <Button x:Name="BtnPlay" Content="&#xE768;" Style="{StaticResource Icon}" ToolTip="Play / pause [Space]" Margin="0,0,4,0"/>
            <Button x:Name="BtnNext" Content="&#xE893;" Style="{StaticResource Icon}" ToolTip="Next recording [N]" Margin="0,0,16,0"/>
            <Button x:Name="BtnStart" Content="Start  I" ToolTip="Mark the start [I]"/>
            <Button x:Name="BtnEnd" Content="End  O" ToolTip="Mark the end [O] - the marked part loops"/>
            <Button x:Name="BtnClear" Content="&#xE711;" Style="{StaticResource Icon}" ToolTip="Clear the marks [Esc]"/>
            <Button x:Name="BtnCut" Content="Cut clip  Enter" Style="{StaticResource Primary}" Margin="0,0,16,0" ToolTip="Save the marked part as a clip [Enter or C]"/>
            <Button x:Name="BtnKills" Content="Find kills  K" Style="{StaticResource Kills}" ToolTip="Battlefield 6: finds the kills in this recording. Then K = next kill, Shift+K = previous."/>
          </WrapPanel>
        </DockPanel>
        <!-- the clip list: what Join joins -->
        <Border Grid.Row="6" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="10,8">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
              <Button x:Name="BtnJoin" DockPanel.Dock="Right" Content="Join  J" Style="{StaticResource Success}" Margin="8,0,0,0" ToolTip="Join the saved clips of this list, top to bottom, then empty the list [J]"/>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="BtnClipPlay" Content="&#xE768;" Style="{StaticResource Icon}" ToolTip="Play the selected clip (or double-click it)" Margin="0,0,4,0"/>
                <Button x:Name="BtnClipUp" Content="&#xE74A;" Style="{StaticResource Icon}" ToolTip="Move up" Margin="0,0,4,0"/>
                <Button x:Name="BtnClipDown" Content="&#xE74B;" Style="{StaticResource Icon}" ToolTip="Move down" Margin="0,0,4,0"/>
                <Button x:Name="BtnClipRemove" Content="&#xE711;" Style="{StaticResource Icon}" ToolTip="Take the clip off this list (the file stays)" Margin="0,0,4,0"/>
                <Button x:Name="BtnClipClear" Content="Clear" ToolTip="Empty this list (the files stay)" Margin="0"/>
              </StackPanel>
              <TextBlock Text="Clip list" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="ClipInfo" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center" Margin="10,0,0,0" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <ListBox x:Name="Slices" FontFamily="Consolas" FontSize="13"/>
          </DockPanel>
        </Border>
      </Grid>

      <!-- right: the library (folder, rounds, recordings, clips) -->
      <Border Grid.Column="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="10,8">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <CheckBox x:Name="ChkClips" DockPanel.Dock="Right" Content="Clips" ToolTip="Show the clips under the recordings they were cut from"/>
            <TextBlock Text="Library" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
          </DockPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <Button x:Name="BtnRound" Content="Make round..." Style="{StaticResource Round}" ToolTip="Put the selected recordings in a folder of their own, renamed and numbered (e.g. BF6-12-1, BF6-12-2)"/>
            <Button x:Name="BtnUndo" Content="Undo round" ToolTip="Move the files of the last round back to their old names"/>
            <Button x:Name="BtnDelete" Content="&#xE74D;" Style="{StaticResource Icon}" ToolTip="Move the selected recordings or clips to the Recycle Bin"/>
          </WrapPanel>
          <Border x:Name="LooseBar" DockPanel.Dock="Top" Background="#3a3218" BorderBrush="#8a6d1c" BorderThickness="1" CornerRadius="6" Padding="9,5" Margin="0,0,0,8" Cursor="Hand"
                  Visibility="Collapsed" ToolTip="Click to select them, then Make round">
            <TextBlock x:Name="LooseText" Foreground="#ffd866" FontSize="13"/>
          </Border>
          <TextBlock DockPanel.Dock="Bottom" TextWrapping="Wrap" Foreground="{StaticResource Muted}" FontSize="12" Margin="2,8,0,0"
                     Text="Click a round to open or close it. Ctrl+click or Shift+click selects several. Right-click for more."/>
          <Grid>
            <ListBox x:Name="Videos" SelectionMode="Extended" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            <StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed" Margin="10">
              <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="#5c7cfa" HorizontalAlignment="Center" Margin="0,0,0,10"/>
              <TextBlock x:Name="EmptyText" Text="Pick the folder your recordings are saved in" TextWrapping="Wrap" TextAlignment="Center" Foreground="#c9c9d1" Margin="0,0,0,12"/>
              <Button x:Name="BtnChooseFolder" Content="Choose your recordings folder" Style="{StaticResource Primary}" HorizontalAlignment="Center" Padding="16,8"/>
            </StackPanel>
          </Grid>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'TitleText','Player','VideoBox','RangeCanvas','RangeRect','StartGrip','EndGrip','KillCanvas','Seek','TimeText','MarkText','Vol','BtnPlay','BtnStart','BtnEnd','BtnClear','BtnCut','BtnJoin','BtnKills','ChkMp3','ChkFast','Slices','Videos','BtnPrev','BtnNext','BtnOpen','BtnFolder','BtnRound','BtnUndo','BtnDelete','ChkClips','BtnClipPlay','BtnClipUp','BtnClipDown','BtnClipRemove','BtnClipClear','InfoText','FolderBar','FolderName','FolderPath','ClipInfo','LooseBar','LooseText','EmptyState','EmptyText','BtnChooseFolder') { $ui[$n] = $win.FindName($n) }

$st = @{
    Index = -1; Video = $null; Dur = 0.0; Playing = $false
    Dragging = $false; DragWasPlaying = $false
    Start = $null; End = $null
    LastSeek = 0.0; LastSeekAt = [datetime]::MinValue
    Jobs = New-Object System.Collections.ArrayList     # pending ffmpeg steps
    Running = $null                                    # current step
    Clips = New-Object System.Collections.ArrayList    # the clip list at the bottom: @{ Mp4; Mp3; Label; Status; Saved } - what Join joins
    Join = $null                                       # a join running in the background
    Lib = (New-Object System.Collections.ArrayList)    # what the recordings list shows (Get-Library)
    Expanded = @{}                                     # round folders shown open
    Enc = (Get-Encoder $ffmpeg)
    SyncingList = $false
    Speeds = @(0.25, 0.5, 1.0, 2.0, 4.0); SpeedIx = 2
    Scans = @{}                                        # video path -> running/finished kill scan
    Kills = $null                                      # kill times (s) of the current video, once known
    KillLasts = $null                                  # per kill moment: time of its last kill (KILL x2 ...)
    KillIx = -1; KillClip = $null                      # last kill jumped to, and the part marked for it
    PendingSeek = $null; PendingPlay = $true           # after files were moved: where to continue
    Grip = $null; GripWasPlaying = $false; GripFrom = 0.0              # dragging the start or end of the marked part
}

# ---------- the clip list at the bottom ----------
function Render-Slices {
    $sel = $ui.Slices.SelectedIndex
    $ui.Slices.Items.Clear()
    for ($i = 0; $i -lt $st.Clips.Count; $i++) {
        $c = $st.Clips[$i]
        [void]$ui.Slices.Items.Add(('{0,2}. {1}  {2}{3}' -f ($i + 1), $c.Label, $c.Status, $c.Mp3Note))
    }
    if ($sel -ge 0 -and $sel -lt $ui.Slices.Items.Count) { $ui.Slices.SelectedIndex = $sel }
    $saved = @($st.Clips | Where-Object { $_.Saved })
    $secs = 0.0; foreach ($c in $saved) { if ($c.Len) { $secs += $c.Len } }
    $ui.ClipInfo.Text = if (-not $st.Clips.Count) { 'clips you cut show up here' } else { '{0} clip{1}{2}' -f $st.Clips.Count, $(if ($st.Clips.Count -ne 1) { 's' } else { '' }), $(if ($secs -gt 0) { '  {0}  {1:N1} s' -f [char]0x00B7, $secs } else { '' }) }
    $ui.BtnJoin.Content = if ($saved.Count -ge 2) { "Join $($saved.Count) clips  J" } else { 'Join  J' }
}
function Set-ClipStatus($c, [string]$status) { $c.Status = $status; Render-Slices }
function Set-Title {
    $win.Title = "FragCut $FragCutVersion"
    $ui.InfoText.Text = "player: $(if ($st.Mpv) { 'mpv' } else { 'Windows' })   " + [char]0x00B7 + "   encoding: $(Get-EncoderName $st.Enc)"
}
function Looping { ($null -ne $st.Start) -and ($null -ne $st.End) -and ($st.End -gt $st.Start) }

# ---------- player: mpv inside the window if it's installed, else Windows' built-in player ----------
$st.MpvExe = Find-Mpv
$st.Mpv = $null
if ($st.MpvExe) {
    $wfh = New-Object System.Windows.Forms.Integration.WindowsFormsHost
    $panel = New-Object System.Windows.Forms.Panel
    $panel.BackColor = [Drawing.Color]::Black
    $panel.Enabled = $false                      # clicks and keys stay with FragCut, not mpv
    $wfh.Child = $panel
    $ui.VideoBox.Child = $wfh
    $st.MpvPanel = $panel
}
function Start-Mpv {
    if (-not $st.MpvExe) { return }
    try { $m = New-Object FragCutMpv.Player; $m.Start($st.MpvExe, $st.MpvPanel.Handle); $st.Mpv = $m }
    catch {
        # mpv didn't start: use the built-in player
        $st.Mpv = $null; $st.MpvExe = $null
        $ui.VideoBox.Child = $ui.Player
        $ui.MarkText.Text = "mpv didn't start ($($_.Exception.Message)) - using Windows' player"
    }
}
function P-Open($path) { if ($st.Mpv) { $st.Mpv.Load($path) } else { $ui.Player.Source = New-Object Uri($path) } }
function P-Play  { if ($st.Mpv) { $st.Mpv.SetPause($false) } else { $ui.Player.Play() } }
function P-Pause { if ($st.Mpv) { $st.Mpv.SetPause($true) }  else { $ui.Player.Pause() } }
function P-Pos   { if ($st.Mpv) { $st.Mpv.TimePos } else { $ui.Player.Position.TotalSeconds } }
function P-SetPos([double]$s, [switch]$Fast) { if ($st.Mpv) { $st.Mpv.Seek($s, -not $Fast) } else { $ui.Player.Position = [TimeSpan]::FromSeconds($s) } }
function P-Speed([double]$x) { if ($st.Mpv) { $st.Mpv.SetSpeed($x) } else { $ui.Player.SpeedRatio = $x } }
function P-Volume([double]$v) { if ($st.Mpv) { $st.Mpv.SetVolume($v) } else { $ui.Player.Volume = $v } }
function P-Mute([bool]$m) { if ($st.Mpv) { $st.Mpv.SetMute($m) } else { $ui.Player.IsMuted = $m } }
function P-Duration {
    if ($st.Mpv) { return $st.Mpv.Duration }
    if ($ui.Player.NaturalDuration.HasTimeSpan) { return $ui.Player.NaturalDuration.TimeSpan.TotalSeconds }
    return 0.0
}
function P-Close { if ($st.Mpv) { $st.Mpv.Quit(); $st.Mpv = $null } else { $ui.Player.Stop(); $ui.Player.Close() } }
# timer: mpv's events (the built-in player raises its own)
function Check-Mpv {
    $m = $st.Mpv
    if (-not $m) { return }
    if ($m.TakeLoaded()) { On-MediaOpened }
    if ($m.TakeFailed()) { $ui.MarkText.Text = "Can't play this file: $($m.LastError)" }
    if ($m.TakeEnded())  { On-MediaEnded }
    if ($m.Exited) { $st.Mpv = $null; $st.MpvExe = $null; $ui.VideoBox.Child = $ui.Player; $ui.MarkText.Text = 'mpv closed - switched to Windows'' player'; if ($st.Video) { Load-Path $st.Video } }
}

# ---------- recordings list: rounds > recordings > clips (Get-Library in Rounds.ps1) ----------
$script:Brush = @{
    Round = '#b197fc'; Rec = '#e8e8ea'; Loose = '#f0c040'; Clip = '#a6a6ae'; LooseClip = '#c9a640'; Muted = '#8d8d97'
}
foreach ($k in @($script:Brush.Keys)) { $script:Brush[$k] = [Windows.Media.BrushConverter]::new().ConvertFromString($script:Brush[$k]) }

# Scans the folder again, then redraws the list
function Refresh-Library {
    $lib = Get-Library $script:Root
    $known = @{}
    foreach ($n in $lib) { foreach ($x in @($n) + @($n.Children)) { $known[$x.Path.ToLowerInvariant()] = $true; foreach ($y in $x.Children) { $known[$y.Path.ToLowerInvariant()] = $true } } }
    $extra = @($script:Extra | Where-Object { (Test-Path -LiteralPath $_) -and -not $known[$_.ToLowerInvariant()] })
    if ($extra.Count) {
        $g = New-LibNode 'round' '::extra' 'Opened from other folders' $null
        foreach ($f in $extra) { $r = New-LibNode 'rec' $f (([IO.Path]::GetFileNameWithoutExtension($f)) -replace '\.DVR$', '') '::extra'; [void]$g.Children.Add($r) }
        $lib.Insert(0, $g)
        $st.Expanded['::extra'] = $true
    }
    $st.Lib = $lib
    $queue.Clear()
    foreach ($n in $lib) {
        if ($n.Kind -eq 'rec') { [void]$queue.Add($n.Path) }
        elseif ($n.Kind -eq 'round') { foreach ($c in $n.Children) { if ($c.Kind -eq 'rec') { [void]$queue.Add($c.Path) } } }
    }
    $st.Index = if ($st.Video) { Index-Of $st.Video } else { -1 }
    if ($script:Root) { $ui.FolderName.Text = Split-Path $script:Root -Leaf; $ui.FolderPath.Text = $script:Root; $ui.BtnFolder.Content = 'Change folder' }
    else { $ui.FolderName.Text = 'No folder chosen'; $ui.FolderPath.Text = 'pick the folder your recordings are saved in'; $ui.BtnFolder.Content = 'Choose folder' }
    # recordings that aren't in a round yet
    $loose = @($lib | Where-Object { $_.Kind -eq 'rec' }).Count
    if ($loose) {
        $ui.LooseText.Text = if ($loose -eq 1) { '1 recording not in a round yet' } else { "$loose recordings not in a round yet" }
        $ui.LooseBar.Visibility = 'Visible'
    } else { $ui.LooseBar.Visibility = 'Collapsed' }
    Render-Library
}
function Index-Of([string]$path) {
    for ($i = 0; $i -lt $queue.Count; $i++) { if ($queue[$i] -ieq $path) { return $i } }
    return -1
}

# Runs a script block right after the current event is handled
function Later([scriptblock]$sb) { [void]$win.Dispatcher.BeginInvoke([Action]$sb, [Windows.Threading.DispatcherPriority]::Background) }

# Redraws the list from $st.Lib (no disk access)
function Render-Library {
    $st.SyncingList = $true
    $script:CurItem = $null
    $ui.Videos.Items.Clear()
    foreach ($n in $st.Lib) { Add-LibRow $n 0 }
    if ($script:CurItem) { $ui.Videos.SelectedItem = $script:CurItem; $ui.Videos.ScrollIntoView($script:CurItem) }
    if ($st.Lib.Count) { $ui.EmptyState.Visibility = 'Collapsed' }
    else {
        $ui.EmptyText.Text = if ($script:Root) { "No recordings in $(Split-Path $script:Root -Leaf) yet. Pick another folder?" } else { 'Pick the folder your recordings are saved in. FragCut opens it from then on.' }
        $ui.BtnChooseFolder.Content = if ($script:Root) { 'Choose another folder' } else { 'Choose your recordings folder' }
        $ui.EmptyState.Visibility = 'Visible'
    }
    $st.SyncingList = $false
}
# Short names for the list (the full path is in the tooltip)
$script:Months = 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
function Round-Label([string]$name) {
    if ($name -match '^(?<r>[A-Za-z0-9_]+-\d+) (?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})') { return '{0} {1} {2} {3}' -f $Matches.r, [char]0x00B7, [int]$Matches.d, $script:Months[[int]$Matches.m - 1] }
    return $name
}
function Rec-Label($n) {
    $name = $n.Name
    $k = ''
    if ($name -match '^[A-Za-z0-9_]+-\d+-(?<k>\d+) (?<rest>.+)$') { $k = $Matches.k; $name = $Matches.rest }
    $game = if ($script:Root) { Split-Path $script:Root -Leaf } else { '' }
    if ($game -and $name.StartsWith("$game ", [StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring($game.Length + 1) }
    $name = $name -replace '(\d{2}\.\d{2}\.\d{2})\.\d{1,3}$', '$1'                       # NVIDIA: drop the hundredths
    if ($k) {
        # in a round the date is on the round line: show the time of day
        if ($name -match '(?<t>\d{2})[.\-:](?<u>\d{2})[.\-:](?<v>\d{2})(\.\d+)?$') { $name = '{0}:{1}:{2}' -f $Matches.t, $Matches.u, $Matches.v }
        return "#$k   $name"
    }
    return $name
}
function Clip-Label($n) {
    $name = $n.Name
    if ($name -match '(^| - |^[A-Za-z0-9_]+-\d+-\d+ )(?<c>clip \d+m\d+-\d+m\d+.*)$') { return $Matches.c }
    $game = if ($script:Root) { Split-Path $script:Root -Leaf } else { '' }
    if ($game -and $name.StartsWith("$game ", [StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring($game.Length + 1) }
    return $name
}
function Count-Clips($n) { $c = 0; foreach ($x in $n.Children) { if ($x.Kind -eq 'clip') { $c++ }; $c += Count-Clips $x }; return $c }

function Add-LibRow($n, [int]$depth) {
    if ($n.Kind -eq 'clip' -and -not $ui.ChkClips.IsChecked) { return }
    $it = New-Object Windows.Controls.ListBoxItem
    $it.Tag = $n; $it.ToolTip = $n.Path
    $it.Padding = New-Object Windows.Thickness((4 + 16 * $depth), 1, 4, 1)
    $tb = New-Object Windows.Controls.TextBlock
    $tb.TextTrimming = 'CharacterEllipsis'
    switch ($n.Kind) {
        'round' {
            $open = [bool]$st.Expanded[$n.Path]
            $recs = @($n.Children | Where-Object { $_.Kind -eq 'rec' }).Count
            $clips = Count-Clips $n
            [void]$tb.Inlines.Add((New-Object Windows.Documents.Run(('{0}  {1}' -f $(if ($open) { [char]0x25BE } else { [char]0x25B8 }), (Round-Label $n.Name)))))
            $more = New-Object Windows.Documents.Run(('    {0} rec{1}{2}' -f $recs, $(if ($recs -ne 1) { 's' } else { '' }), $(if ($clips) { ' {0} {1} clip{2}' -f [char]0x00B7, $clips, $(if ($clips -ne 1) { 's' } else { '' }) } else { '' })))
            $more.Foreground = $script:Brush.Muted; $more.FontWeight = 'Normal'; $more.FontSize = 12
            [void]$tb.Inlines.Add($more)
            $tb.Foreground = $script:Brush.Round; $tb.FontWeight = 'SemiBold'
            $it.ToolTip = if ($n.Path -eq '::extra') { 'Recordings opened from other folders' } else { "$($n.Path)`nClick to open or close" }
            # a plain click opens / closes the round instead of selecting it (Ctrl / Shift + click still selects it)
            $it.Add_PreviewMouseLeftButtonDown({
                param($s, $e)
                if ([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None) { return }
                $p = $s.Tag.Path; $st.Expanded[$p] = -not [bool]$st.Expanded[$p]
                $e.Handled = $true
                Later { Render-Library }          # not while WPF is still handling the click on a row it would remove
            })
        }
        'rec' {
            $tb.Text = Rec-Label $n
            $tb.Foreground = if ($n.Round) { $script:Brush.Rec } else { $script:Brush.Loose }
        }
        'clip' {
            $tb.Text = Clip-Label $n; $tb.FontStyle = 'Italic'
            $tb.Foreground = if ($n.Round) { $script:Brush.Clip } else { $script:Brush.LooseClip }
        }
    }
    if ($n.Kind -ne 'round' -and $st.Video -and $n.Path -ieq $st.Video) { $tb.FontWeight = 'Bold'; $script:CurItem = $it }
    $it.Content = $tb
    [void]$ui.Videos.Items.Add($it)
    if ($n.Kind -eq 'round' -and -not $st.Expanded[$n.Path]) { return }
    foreach ($c in $n.Children) { Add-LibRow $c ($depth + 1) }
}

# Selected list rows: 'rec', 'clip' or 'round' nodes
function Selected-Nodes { return @($ui.Videos.SelectedItems | ForEach-Object { $_.Tag } | Where-Object { $_ -is [hashtable] }) }

function Load-Video([int]$i) { if ($i -ge 0 -and $i -lt $queue.Count) { Load-Path $queue[$i] } }

function Load-Path([string]$path, [switch]$Paused) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $st.Video = $path; $st.Index = Index-Of $path; $st.Start = $null; $st.End = $null; $st.Dur = 0
    $i = $st.Index
    # kills already found for this recording (this session or an earlier one)?
    $st.KillIx = -1; $st.KillClip = $null
    $sc = $st.Scans[$st.Video]
    $info = if ($sc) { Get-ScanKills $sc } else { Get-CachedKills $st.Video }
    if ($null -eq $info) { $st.Kills = $null; $st.KillLasts = $null } else { $st.Kills = $info.Times; $st.KillLasts = $info.Lasts }
    $ui.KillCanvas.Children.Clear(); Set-KillButton
    Save-LastFolder $st.Video
    $ui.TitleText.Text = if ($i -ge 0) { '[{0}/{1}]  {2}' -f ($i + 1), $queue.Count, (Split-Path $st.Video -Leaf) } else { Split-Path $st.Video -Leaf }
    if ($st.Preview -and $st.Preview.Video -ne $st.Video) { Stop-Preview }
    $st.UsingPreview = $false
    if ($st.Mpv) { P-Open $st.Video }
    else {
        # Windows' player: a preview copy exists only if it couldn't play this recording before - play that right away
        $pv = $null; try { $pv = Get-PreviewPath $st.Video } catch {}
        $st.UsingPreview = [bool]($pv -and (Test-Path -LiteralPath $pv))
        if ($st.UsingPreview) {
            try { (Get-Item -LiteralPath $pv).LastWriteTime = Get-Date } catch {}
            P-Open $pv
            $ui.TitleText.Text += $script:PreviewNote
        } else { P-Open $st.Video }
    }
    P-Volume $ui.Vol.Value
    if ($Paused) { P-Pause; $st.Playing = $false } else { Start-Playing; $st.Playing = $true }
    $st.LastSeekAt = [datetime]::MinValue
    # open the round it's in, and show it in the list
    foreach ($n in $st.Lib) { if ($n.Kind -eq 'round') { foreach ($c in $n.Children) { if ($c.Path -ieq $path -or @($c.Children | Where-Object { $_.Path -ieq $path }).Count) { $st.Expanded[$n.Path] = $true } } } }
    Render-Library
    Update-Marks
}

# ---------- folders and rounds (Rounds.ps1) ----------
function Ask-YesNo([string]$q, [string]$title = 'FragCut') {
    if ($script:AutoYes) { [void]$script:AskLog.Add($q); return $true }
    return ([System.Windows.MessageBox]::Show($q, $title, 'YesNo', 'Warning') -eq 'Yes')
}

# "Set folder...": the folder FragCut opens from now on
function Set-Folder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the folder with your recordings (for example Videos\NVIDIA\Battlefield 6). FragCut opens it from now on.'
    $dlg.SelectedPath = if ($script:Root) { $script:Root } elseif ($st.Video) { Get-GameDir $st.Video } else { Get-StartFolder }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    Set-Setting 'WorkFolder' $dlg.SelectedPath
    $script:Root = $dlg.SelectedPath
    $script:Extra.Clear()
    Refresh-Library
    if ($queue.Count -and (Index-Of $st.Video) -lt 0) { Load-Path $queue[$queue.Count - 1] -Paused }   # the newest
}

# Recordings for a round: the selected ones (a selected round = all of its recordings), else the one playing
function Selected-Videos {
    $v = New-Object System.Collections.ArrayList
    foreach ($n in (Selected-Nodes)) {
        if ($n.Kind -eq 'rec') { [void]$v.Add($n.Path) }
        elseif ($n.Kind -eq 'round' -and $n.Path -ne '::extra') { foreach ($c in $n.Children) { if ($c.Kind -eq 'rec') { [void]$v.Add($c.Path) } } }
    }
    $v = @($v | Select-Object -Unique)
    if (-not $v.Count -and $st.Video -and (Index-Of $st.Video) -ge 0) { $v = @($st.Video) }
    return $v
}

# Moves the selected recordings / clips to the Recycle Bin
function Delete-Selected {
    $files = @(Selected-Nodes | Where-Object { $_.Kind -ne 'round' } | ForEach-Object { $_.Path } | Select-Object -Unique)
    if (-not $files.Count) { [System.Windows.MessageBox]::Show('Select the recordings or clips to delete first (a round can''t be deleted as a whole).', 'FragCut') | Out-Null; return }
    $busy = @(@($st.Jobs) + @($st.Running) | Where-Object { $_ -and ($files -contains $_.Video -or $files -contains $_.Mp4) })
    if ($busy.Count -or ($st.Join -and @($st.Join.Files | Where-Object { $files -contains $_ }).Count)) { [System.Windows.MessageBox]::Show('One of these files is being used (saving a clip or joining). Try again when it''s done.', 'FragCut') | Out-Null; return }
    foreach ($k in @($st.Scans.Keys)) { if ($files -contains $k -and -not $st.Scans[$k].Done) { [System.Windows.MessageBox]::Show('Find kills is still reading one of these recordings.', 'FragCut') | Out-Null; return } }
    $recs = @($files | Where-Object { -not (Test-MadeByFragCut (Split-Path $_ -Leaf)) }).Count
    $names = @($files | Select-Object -First 12 | ForEach-Object { '  ' + (Split-Path $_ -Leaf) })
    if ($files.Count -gt 12) { $names += "  ... and $($files.Count - 12) more" }
    $what = if ($recs -and $recs -eq $files.Count) { "$recs recording(s)" } elseif ($recs) { "$($files.Count) files ($recs of them recordings)" } else { "$($files.Count) clip(s)" }
    $q = "Move $what to the Recycle Bin?`n`n$($names -join "`n")`n`nA clip's MP3 goes with it. You can restore them from the Recycle Bin."
    if (-not (Ask-YesNo $q 'FragCut - delete')) { return }
    $cur = $st.Video; $curGone = $cur -and ($files -contains $cur)
    if ($curGone) { Pause-Video; Stop-Preview; if ($st.Mpv) { $st.Mpv.Stop() } else { $ui.Player.Close() } }
    $next = $null
    if ($curGone) { $i = Index-Of $cur; if ($i -ge 0) { for ($j = $i + 1; $j -lt $queue.Count; $j++) { if ($files -notcontains $queue[$j]) { $next = $queue[$j]; break } } } }
    $done = @()
    try { $done = Remove-ToRecycleBin $files } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'FragCut', 'OK', 'Warning') | Out-Null }
    foreach ($c in @($st.Clips)) { if ($files -contains $c.Mp4) { $st.Clips.Remove($c) } }
    Render-Slices
    if ($curGone) { $st.Video = $null }
    Refresh-Library
    if ($curGone) {
        if (-not $next -and $queue.Count) { $next = $queue[$queue.Count - 1] }
        if ($next) { Load-Path $next -Paused } else { $ui.TitleText.Text = ''; $st.Dur = 0 }
    }
    $ui.MarkText.Text = "$(@($done).Count) file(s) moved to the Recycle Bin"
}

# Runs file moves (a round or its undo): lets go of the open recording first, then updates the list, the cut clips
# and kill searches to the new names, and reopens the recording where it was.
function Apply-Moves([scriptblock]$do) {
    if ($st.Running -or $st.Jobs.Count) { [System.Windows.MessageBox]::Show('Wait until the clips are saved.', 'FragCut') | Out-Null; return }
    foreach ($k in @($st.Scans.Keys)) { if (-not $st.Scans[$k].Done) { [System.Windows.MessageBox]::Show('Wait until Find kills is done.', 'FragCut') | Out-Null; return } }
    $pos = Pos; $wasPlaying = $st.Playing
    Pause-Video
    Stop-Preview
    if ($st.Mpv) { $st.Mpv.Stop() } else { $ui.Player.Close() }
    $done = @()
    try { $done = @(& $do) } catch { [System.Windows.MessageBox]::Show("Nothing was moved.`n`n$($_.Exception.Message)", 'FragCut', 'OK', 'Warning') | Out-Null }
    $map = @{}; foreach ($m in $done) { $map[$m.From.ToLowerInvariant()] = $m.To }
    foreach ($c in $st.Clips) { $t = $map[$c.Mp4.ToLowerInvariant()]; if ($t) { $c.Mp4 = $t }; if ($c.Mp3) { $t = $map[$c.Mp3.ToLowerInvariant()]; if ($t) { $c.Mp3 = $t } } }
    for ($i = 0; $i -lt $script:Extra.Count; $i++) { $t = $map[$script:Extra[$i].ToLowerInvariant()]; if ($t) { $script:Extra[$i] = $t } }
    $scans = @{}; foreach ($k in @($st.Scans.Keys)) { $t = $map[$k.ToLowerInvariant()]; if ($t) { $scans[$t] = $st.Scans[$k] } else { $scans[$k] = $st.Scans[$k] } }
    $st.Scans = $scans
    $cur = $st.Video; if ($cur) { $t = $map[$cur.ToLowerInvariant()]; if ($t) { $cur = $t } }
    $st.Video = $cur
    Refresh-Library
    $st.PendingSeek = $pos; $st.PendingPlay = $wasPlaying
    Load-Path $cur | Out-Null
    $script:LastMoved = $done
}

function Make-Round {
    $vids = @(Selected-Videos)
    if (-not $vids.Count) { return }
    $plan = Show-RoundDialog $win $vids
    if (-not $plan) { return }
    $script:LastMoved = @(); Apply-Moves { Invoke-RoundPlan $plan } | Out-Null; $done = $script:LastMoved
    if ($done.Count) { $ui.MarkText.Text = "Round $(Split-Path $plan.Dir -Leaf): $(@($done).Count) files moved" }
}

function Undo-Round {
    $e = Get-LastRound
    if (-not $e) { [System.Windows.MessageBox]::Show('There is no round to undo.', 'FragCut') | Out-Null; return }
    $n = @($e.Moves).Count
    $q = "Undo round $($e.Name)?`n`nIts $n files go back to their old names and folders."
    if ([System.Windows.MessageBox]::Show($q, 'FragCut', 'YesNo', 'Question') -ne 'Yes') { return }
    $script:LastMoved = @(); Apply-Moves { Undo-LastRound } | Out-Null; $done = $script:LastMoved
    if ($done.Count) { $ui.MarkText.Text = "Round $($e.Name) undone: $(@($done).Count) files moved back" }
}

# ---------- playback ----------
function Pos { P-Pos }

# Position to step from: right after a seek the player may still report the old position,
# so repeated key presses build on the last target instead.
function Base-Pos {
    if (([datetime]::Now - $st.LastSeekAt).TotalMilliseconds -lt 450) { return $st.LastSeek }
    return (Pos)
}

# Exact seek: while playing, the player snaps to keyframes, so pause, seek, then resume.
function Seek-To([double]$s) {
    if ($st.Dur -gt 0) { $s = [math]::Max(0.0, [math]::Min($s, $st.Dur - 0.02)) } else { $s = [math]::Max(0.0, $s) }
    if ($st.Mpv) { P-SetPos $s }        # mpv seeks exactly while playing
    else {
        if ($st.Playing) { P-Pause }
        P-SetPos $s
        if ($st.Playing) { Start-Playing }
    }
    $ui.Seek.Value = $s
    $st.LastSeek = $s; $st.LastSeekAt = [datetime]::Now
}
# Play at the chosen speed (the player can forget the speed after a pause/seek, so set it every time)
function Start-Playing { P-Speed $st.Speeds[$st.SpeedIx]; P-Play; P-Speed $st.Speeds[$st.SpeedIx] }
function Play { Start-Playing; $st.Playing = $true }
function Change-Speed([int]$d) {
    $st.SpeedIx = [math]::Max(0, [math]::Min($st.Speeds.Count - 1, $st.SpeedIx + $d))
    P-Speed $st.Speeds[$st.SpeedIx]   # applies live while playing
}
function Speed-Text {
    $x = [double]$st.Speeds[$st.SpeedIx]
    if ($x -eq 1.0) { return '' }
    return ('   {0}x' -f $x.ToString([Globalization.CultureInfo]::InvariantCulture))
}
function Pause-Video { P-Pause; $st.Playing = $false }
function Toggle-Play { if ($st.Playing) { Pause-Video } else { Play } }
function Step([double]$d) { if ($st.Playing) { Pause-Video }; Seek-To ((Base-Pos) + $d) }

# ---------- marks ----------
function Fast { [bool]$ui.ChkFast.IsChecked }
# Fast cut: a copied clip starts on a keyframe, so the start mark moves to the keyframe at or before it.
function Snap-Start([double]$t) { if ((Fast) -and $st.Video) { return (Get-KeyframeBefore $st.Video $t) } else { return $t } }

function Update-Marks {
    if (Looping) {
        $ui.MarkText.Text = ('{3}LOOP {0} -> {1}  ({2:N1} s)   Enter = cut   Q/W start  E/R end   Esc = cancel' -f (Short $st.Start), (Short $st.End), ($st.End - $st.Start), $(if (Fast) { 'FAST ' } else { '' }))
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
        # grips on the edges: drag them to move the start / end
        [Windows.Controls.Canvas]::SetLeft($ui.StartGrip, $w * $a / $st.Dur - 2)
        $ui.StartGrip.Visibility = 'Visible'
        [Windows.Controls.Canvas]::SetLeft($ui.EndGrip, $w * $b / $st.Dur - 2)
        $ui.EndGrip.Visibility = if (Looping) { 'Visible' } else { 'Collapsed' }
    } else { $ui.RangeRect.Width = 0; $ui.StartGrip.Visibility = 'Collapsed'; $ui.EndGrip.Visibility = 'Collapsed' }
}

function Start-Loop { Seek-To $st.Start; Play; Update-Marks }

function Mark-Start {
    $st.Start = Snap-Start (Base-Pos)
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
    if ($which -eq 'start' -and (Fast)) {
        # fast cut: the start can only be on a keyframe, so Q/W move it to the previous / next one
        $k = if ($d -lt 0) { if ($st.Start -gt 0.01) { Get-KeyframeBefore $st.Video ($st.Start - 0.01) } else { $null } } else { Get-KeyframeAfter $st.Video $st.Start ($st.End - 0.1) }
        if ($null -eq $k) { [System.Media.SystemSounds]::Beep.Play() } else { $st.Start = $k }
        Seek-To $st.Start
    } elseif ($which -eq 'start') {
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
    $gentle = ($job.Kind -eq 'mp4') -and -not $job.Copy -and (Test-ObsRunning)
    $argv = if ($job.Kind -eq 'mp4' -and $job.Copy) { Get-CopyCutArgs $job.Video $job.Start $job.Len $job.Mp4 } elseif ($job.Kind -eq 'mp4') { Get-CutArgs $job.Video $job.Start $job.Len $job.Mp4 $st.Enc -Gentle:$gentle } else { Get-Mp3Args $job.Video $job.Start $job.Len $job.Mp3 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $job.Proc = [Diagnostics.Process]::Start($psi)
    if ($gentle) { try { $job.Proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
    $st.Running = $job
    if ($job.Kind -eq 'mp4') { Set-ClipStatus $job.Clip ("saving{0}..." -f $(if ($gentle) { ' (gently - OBS is open)' } else { '' })) } else { $job.Clip.Mp3Note = '   + MP3...'; Render-Slices }
}

function Check-Jobs {
    $job = $st.Running
    if (-not $job -or -not $job.Proc.HasExited) { return }
    $code = $job.Proc.ExitCode
    $st.Running = $null
    if ($job.Kind -eq 'mp4' -and $code -ne 0 -and $job.Copy) {
        $job.Copy = $false; $job.Clip.Label += ' (fast cut failed, re-encoding)'; $st.Jobs.Insert(0, $job)   # copying failed: encode it the normal way
    } elseif ($job.Kind -eq 'mp4' -and $code -ne 0 -and $st.Enc -ne 'libx264') {
        $st.Enc = 'libx264'; Reset-Encoder; Set-Title; $st.Jobs.Insert(0, $job)   # GPU encoder failed: retry on the CPU (re-detect next start)
    } elseif ($job.Kind -eq 'mp4') {
        $size = 0; try { $size = (Get-Item -LiteralPath $job.Mp4).Length } catch {}
        if ($code -eq 0 -and $size -lt 4096) {
            try { Remove-Item -LiteralPath $job.Mp4 -Force } catch {}
            Set-ClipStatus $job.Clip 'FAILED (empty - is the part inside the video?)'
        } elseif ($code -eq 0) {
            $job.Clip.Saved = $true
            Set-ClipStatus $job.Clip ("saved  {0}  ({1:N1} MB)" -f (Split-Path $job.Mp4 -Leaf), ($size / 1MB))
            if ($ui.ChkClips.IsChecked) { Refresh-Library }
        } else { Set-ClipStatus $job.Clip ("FAILED (ffmpeg exit {0})" -f $code) }
    } else {
        $job.Clip.Mp3Note = if ($code -ne 0) { '   (MP3 failed)' } else { '   + MP3' }
        Render-Slices
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
    $fast = Fast
    if ($fast) { $a = Snap-Start $a }                            # fast cut starts on a keyframe
    if ($b -le $a) { [System.Media.SystemSounds]::Beep.Play(); $ui.MarkText.Text = 'End must be after start'; return }
    $paths = Get-SlicePaths $st.Video $a $b
    New-Item -ItemType File -Path $paths.Mp4 -Force | Out-Null   # reserve the name so quick cuts never collide
    $label = '{0} -> {1}{2}' -f (Short $a), (Short $b), $(if ($fast) { ' fast' } else { '' })
    $clip = @{ Mp4 = $paths.Mp4; Mp3 = $paths.Mp3; Label = $label; Status = 'queued'; Mp3Note = ''; Saved = $false; Len = ($b - $a) }
    [void]$st.Clips.Add($clip)
    Render-Slices
    $ui.Slices.ScrollIntoView($ui.Slices.Items[$ui.Slices.Items.Count - 1])
    $base = @{ Video = $st.Video; Start = $a; Len = ($b - $a); Mp4 = $paths.Mp4; Mp3 = $paths.Mp3; Clip = $clip; Proc = $null; Copy = $fast }
    $j1 = $base.Clone(); $j1.Kind = 'mp4'; [void]$st.Jobs.Add($j1)
    if ($ui.ChkMp3.IsChecked) { $j2 = $base.Clone(); $j2.Kind = 'mp3'; [void]$st.Jobs.Add($j2) }
    $st.Start = $null; $st.End = $null
    if ($looping) { Seek-To $b; Play }                          # keep watching from the end of the slice
    Update-Marks
    Start-Next-Job
}

# Joins the saved clips of the list, top to bottom, in the background (Join.ps1 without its window); then empties the list.
function Join-Slices {
    if ($st.Join) { $ui.MarkText.Text = 'Already joining...'; return }
    $files = @($st.Clips | Where-Object { $_.Saved -and (Test-Path -LiteralPath $_.Mp4) } | ForEach-Object { $_.Mp4 })
    if ($files.Count -lt 2) { [System.Windows.MessageBox]::Show('The clip list needs at least 2 saved clips. Cut some, or right-click clips in the recordings list > Add to clip list.', 'FragCut') | Out-Null; return }
    $result = Join-Path $env:TEMP "fragcut-join-$PID-$([Environment]::TickCount).txt"
    $script = Join-Path $PSScriptRoot 'Join.ps1'
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-KeepOrder','-NoPause','-NoOpen','-ResultFile',$result, $(if ($ui.ChkMp3.IsChecked) { '-Mp3' } else { '-NoMp3' })) + $files
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($a | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $st.Join = @{ Proc = [Diagnostics.Process]::Start($psi); Result = $result; Files = $files; Count = $files.Count; T0 = [datetime]::Now }
    $ui.BtnJoin.IsEnabled = $false
    $ui.MarkText.Text = "Joining $($files.Count) clips..."
}
function Check-Join {
    $j = $st.Join
    if (-not $j) { return }
    if (-not $j.Proc.HasExited) { $ui.MarkText.Text = 'Joining {0} clips... {1:N0} s' -f $j.Count, ([datetime]::Now - $j.T0).TotalSeconds; return }
    $st.Join = $null; $ui.BtnJoin.IsEnabled = $true
    $r = ''; try { $r = [IO.File]::ReadAllText($j.Result).Trim(); [IO.File]::Delete($j.Result) } catch {}
    if ($r -like 'OK|*') {
        $out = $r.Substring(3)
        $st.Clips.Clear(); Render-Slices
        Refresh-Library
        $ui.MarkText.Text = 'Saved {0}  ({1:N1} MB)' -f (Split-Path $out -Leaf), ((Get-Item -LiteralPath $out).Length / 1MB)
        $st.LastMontage = $out
    } else {
        $msg = if ($r -like 'ERR|*') { $r.Substring(4) } else { "Join stopped (exit $($j.Proc.ExitCode))" }
        $ui.MarkText.Text = "Join failed: $msg"
    }
}

# list buttons
function Selected-Clip { $i = $ui.Slices.SelectedIndex; if ($i -ge 0 -and $i -lt $st.Clips.Count) { return $st.Clips[$i] }; return $null }
function Play-Clip { $c = Selected-Clip; if (-not $c) { return }; if (-not $c.Saved) { $ui.MarkText.Text = 'That clip isn''t saved yet'; return }; Load-Path $c.Mp4 }
function Move-Clip([int]$d) {
    $i = $ui.Slices.SelectedIndex; $j = $i + $d
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $st.Clips.Count) { return }
    $c = $st.Clips[$i]; $st.Clips.RemoveAt($i); $st.Clips.Insert($j, $c)
    Render-Slices; $ui.Slices.SelectedIndex = $j
}
function Remove-Clip {
    $c = Selected-Clip; if (-not $c) { return }
    if (-not $c.Saved -and $c.Status -notlike 'FAILED*') { $ui.MarkText.Text = 'Wait until that clip is saved'; return }
    $i = $ui.Slices.SelectedIndex; $st.Clips.Remove($c); Render-Slices
    if ($st.Clips.Count) { $ui.Slices.SelectedIndex = [math]::Min($i, $st.Clips.Count - 1) }
}
function Clear-Clips {
    $busy = @($st.Clips | Where-Object { -not $_.Saved -and $_.Status -notlike 'FAILED*' })
    $st.Clips.Clear(); foreach ($c in $busy) { [void]$st.Clips.Add($c) }   # clips still being saved stay
    Render-Slices
}
# from the recordings list: right-click clips > Add to clip list
function Add-ToClipList {
    foreach ($n in (Selected-Nodes)) {
        if ($n.Kind -ne 'clip' -and -not ($n.Kind -eq 'rec' -and (Test-MadeByFragCut (Split-Path $n.Path -Leaf)))) { continue }
        if (@($st.Clips | Where-Object { $_.Mp4 -ieq $n.Path }).Count) { continue }
        [void]$st.Clips.Add(@{ Mp4 = $n.Path; Mp3 = [IO.Path]::ChangeExtension($n.Path, '.mp3'); Label = $n.Name; Status = ''; Mp3Note = ''; Saved = $true; Len = $(try { Get-Duration $ffprobe $n.Path } catch { 0.0 }) })
    }
    Render-Slices
}

# ---------- preview copy: for recordings Windows' player can't open (AV1, HEVC without its extension ...) ----------
$script:PreviewNote = '   (preview copy - cuts use the original)'
$st.Preview = $null; $st.UsingPreview = $false

# mode 0: all on the NVIDIA GPU, 1: GPU decoding via DirectX (any GPU), 2: CPU only - see Get-PreviewArgs
function Start-Preview([int]$mode = -1, $info = $null) {
    $v = $st.Video
    if ($mode -lt 0) { $mode = if ($st.Enc -eq 'h264_nvenc') { 0 } else { 1 } }
    $out = Get-PreviewPath $v
    New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
    Remove-OldPreviews
    if (-not $info) {
        $info = @{ Codec = ''; Width = 0; Height = 0 }
        try {
            $c = (& $ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$v" | Select-Object -First 1).Split(',')
            $info = @{ Codec = $c[0].Trim(); Width = [int]$c[1]; Height = [int]$c[2] }
        } catch {}
    }
    $dur = if ($st.Dur -gt 0) { $st.Dur } else { try { Get-Duration $ffprobe $v } catch { 0.0 } }
    $p = @{ Video = $v; Out = $out; Tmp = "$out.part"; Prog = "$out.progress"; Mode = $mode; Info = $info; Dur = $dur; Codec = $info.Codec.ToUpper(); Pct = 0 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ffmpeg
    $psi.Arguments = (Get-PreviewArgs $v $p.Tmp $st.Enc $p.Prog $info $mode | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p.Proc = [Diagnostics.Process]::Start($psi)
    if (Test-ObsRunning) { try { $p.Proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch {} }
    $st.Preview = $p
    Show-PreviewProgress
}

function Show-PreviewProgress {
    $p = $st.Preview
    $what = if ($p.Codec) { "this $($p.Codec) recording" } else { 'this recording' }
    $ui.MarkText.Text = "Windows can't play $what - making a preview copy {0:N0}%  (cuts use the original)" -f $p.Pct
}

function Stop-Preview {
    $p = $st.Preview; $st.Preview = $null
    if (-not $p) { return }
    try { if (-not $p.Proc.HasExited) { $p.Proc.Kill(); $p.Proc.WaitForExit(2000) | Out-Null } } catch {}
    foreach ($f in $p.Tmp, $p.Prog) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch {} }
}

# timer: progress, then switch the player over to the finished copy
function Check-Preview {
    $p = $st.Preview
    if (-not $p) { return }
    if (-not $p.Proc.HasExited) {
        try {
            $fs = [IO.File]::Open($p.Prog, 'Open', 'Read', 'ReadWrite, Delete')
            $txt = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
            $m = [regex]::Matches($txt, 'out_time_us=(\d+)')
            if ($m.Count -and $p.Dur -gt 0) { $p.Pct = [math]::Min(99, [double]$m[$m.Count - 1].Groups[1].Value / 1e6 / $p.Dur * 100) }
        } catch {}
        Show-PreviewProgress
        return
    }
    $code = $p.Proc.ExitCode
    $ok = ($code -eq 0) -and (Test-Path -LiteralPath $p.Tmp) -and ((Get-Item -LiteralPath $p.Tmp).Length -gt 4096)
    if ($ok) { try { Move-Item -LiteralPath $p.Tmp $p.Out -Force -ErrorAction Stop } catch { $ok = $false } }
    Stop-Preview
    if (-not $ok) {
        if ($p.Mode -lt 2 -and $p.Video -eq $st.Video) { Start-Preview ($p.Mode + 1) $p.Info; return }    # next way down: DirectX, then CPU
        $ui.MarkText.Text = "Can't play this file, and making a preview copy failed (ffmpeg exit $code)"
        return
    }
    if ($p.Video -ne $st.Video) { return }
    $st.UsingPreview = $true
    P-Open $p.Out
    $ui.TitleText.Text += $script:PreviewNote
    Play
    Update-Marks
}

function Next-Video { if ($st.Index + 1 -lt $queue.Count) { Load-Video ($st.Index + 1) } else { $ui.MarkText.Text = 'That was the last recording' } }
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
    elseif ($null -eq $st.Kills) { $txt = 'Find kills  K' }
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
        $st.Kills = @(); $st.KillLasts = @()
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
    $last = if ($st.KillLasts -and $i -lt @($st.KillLasts).Count) { [math]::Max($t, $st.KillLasts[$i]) } else { $t }   # KILL x2 ...: up to the last kill
    $a = Snap-Start ([math]::Max(0.0, $t - $KillBefore)); $b = $last + $KillAfter
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
        $info = Get-ScanKills $sc
        $times = $info.Times
        $known = if ($null -eq $st.Kills) { -1 } else { @($st.Kills).Count }
        if ($v -eq $st.Video) {
            $st.KillLasts = $info.Lasts
            if ($times.Count -ne $known) { $st.Kills = $times; Draw-KillTicks }
        }
        if ($done) {
            $st.ScanDone[$v] = $true
            if ($sc.Error) {
                $st.Scans.Remove($v)
                if ($v -eq $st.Video) { $st.Kills = $null; Draw-KillTicks; $ui.MarkText.Text = "Find kills failed: $($sc.Error)" }
            } else {
                Save-CachedKills $v $info
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
    P-Mute $true
    [void]$ui.Seek.CaptureMouse()
    Seek-To (Track-Value $e)
})
$ui.Seek.Add_PreviewMouseMove({
    param($s, $e)
    if (-not $st.Dragging) { return }
    $e.Handled = $true
    $v = Track-Value $e
    $ui.Seek.Value = $v
    P-SetPos $v -Fast
    $st.LastSeek = $v; $st.LastSeekAt = [datetime]::Now
})
function End-Drag {
    if (-not $st.Dragging) { return }
    $st.Dragging = $false
    P-Mute $false
    if ($st.DragWasPlaying) { Play }
}
$ui.Seek.Add_PreviewMouseLeftButtonUp({ param($s, $e) $e.Handled = $true; if ($st.Dragging) { Seek-To (Track-Value $e) }; $ui.Seek.ReleaseMouseCapture(); End-Drag })
$ui.Seek.Add_LostMouseCapture({ End-Drag })

# ---------- dragging the start / end of the marked part (the orange bar's edges) ----------
# Which edge is under the mouse (within 7 px): 'start', 'end' (only once an end is marked) or $null
function Grip-At([double]$x) {
    $w = $ui.RangeCanvas.ActualWidth
    if ($st.Dur -le 0 -or $w -le 0 -or $null -eq $st.Start) { return $null }
    $da = [math]::Abs($x - $w * $st.Start / $st.Dur)
    $de = if (Looping) { [math]::Abs($x - $w * $st.End / $st.Dur) } else { 1e9 }
    if ([math]::Min($da, $de) -gt 7) { return $null }
    if ($de -lt $da) { return 'end' } else { return 'start' }
}
function Grip-Time($e) {
    $w = [math]::Max(1.0, $ui.RangeCanvas.ActualWidth)
    return $st.Dur * [math]::Max(0.0, [math]::Min(1.0, $e.GetPosition($ui.RangeCanvas).X / $w))
}
# Moves the edge being dragged to $t and shows that frame
function Move-Grip([double]$t) {
    if ($st.Grip -eq 'start') {
        $max = if (Looping) { $st.End - 0.1 } else { [math]::Max(0.0, $st.Dur - 0.1) }
        $st.Start = Snap-Start ([math]::Max(0.0, [math]::Min($t, $max)))
        $show = $st.Start
    } else {
        $st.End = [math]::Min($st.Dur, [math]::Max($t, $st.Start + 0.1))
        $show = $st.End
    }
    P-SetPos $show -Fast
    $ui.Seek.Value = $show; $st.LastSeek = $show; $st.LastSeekAt = [datetime]::Now
    Update-Marks
}
function End-Grip {
    if (-not $st.Grip) { return }
    $g = $st.Grip; $st.Grip = $null
    P-Mute $false
    if (Looping) {
        if ($g -eq 'start') { Seek-To $st.Start } else { Seek-To ([math]::Max($st.Start, $st.End - 1.5)) }   # replay that edge
        Play
    } else { Seek-To ([math]::Max($st.Start, $st.GripFrom)); if ($st.GripWasPlaying) { Play } }   # only a start: back to where the end was
    Update-Marks
}
$ui.RangeCanvas.Add_MouseLeftButtonDown({
    param($s, $e)
    $g = Grip-At ($e.GetPosition($ui.RangeCanvas).X)
    if (-not $g) { return }
    $e.Handled = $true
    $st.Grip = $g; $st.GripWasPlaying = $st.Playing; $st.GripFrom = Base-Pos
    if ($st.Playing) { Pause-Video }
    P-Mute $true
    [void]$ui.RangeCanvas.CaptureMouse()
})
$ui.RangeCanvas.Add_MouseMove({
    param($s, $e)
    if ($st.Grip) { $e.Handled = $true; Move-Grip (Grip-Time $e); return }
    $ui.RangeCanvas.Cursor = if (Grip-At ($e.GetPosition($ui.RangeCanvas).X)) { [Windows.Input.Cursors]::SizeWE } else { $null }
})
$ui.RangeCanvas.Add_MouseLeftButtonUp({ param($s, $e) if ($st.Grip) { $e.Handled = $true; Move-Grip (Grip-Time $e); $ui.RangeCanvas.ReleaseMouseCapture(); End-Grip } })
$ui.RangeCanvas.Add_LostMouseCapture({ End-Grip })

# ---------- events ----------
function On-MediaOpened {
    # Windows' player rounds the length down to whole seconds; ffprobe gives the exact length
    $d = 0.0; try { $d = Get-Duration $ffprobe $st.Video } catch {}
    $d = [math]::Max($d, (P-Duration))
    $st.Dur = $d
    $ui.Seek.Maximum = [math]::Max(0.1, $st.Dur)
    Update-Marks
    Draw-KillTicks
    if ($null -ne $st.PendingSeek) { $p = $st.PendingSeek; $st.PendingSeek = $null; Seek-To $p; if (-not $st.PendingPlay) { Pause-Video } }
}
function On-MediaEnded { if (Looping) { Seek-To $st.Start; Play } else { Pause-Video } }
$ui.Player.Add_MediaOpened({ On-MediaOpened })
$ui.Player.Add_MediaEnded({ On-MediaEnded })
$ui.Player.Add_MediaFailed({
    param($s, $e)
    if (-not $st.UsingPreview -and -not $st.Preview) {
        try { Start-Preview; return } catch {}
    }
    if ($st.Preview) { return }
    $ui.MarkText.Text = "Can't play this file: $($e.ErrorException.Message)"
})
$ui.Vol.Add_ValueChanged({ P-Volume $ui.Vol.Value })

$ui.BtnPlay.Add_Click({ Toggle-Play })
$ui.BtnStart.Add_Click({ Mark-Start })
$ui.BtnEnd.Add_Click({ Mark-End })
$ui.BtnClear.Add_Click({ Clear-Marks })
$ui.BtnCut.Add_Click({ Cut-Slice })
$ui.BtnJoin.Add_Click({ Join-Slices })
$ui.ChkFast.IsChecked = [bool](Get-Settings).FastCut
$ui.ChkFast.Add_Click({
    Set-Setting 'FastCut' (Fast)
    if ((Fast) -and $null -ne $st.Start) { $st.Start = Snap-Start $st.Start; if (Looping) { Start-Loop } }
    Update-Marks
})
$ui.BtnKills.Add_Click({ Kill-Key 1 })
$ui.BtnNext.Add_Click({ Next-Video })
$ui.BtnPrev.Add_Click({ Prev-Video })
$ui.BtnOpen.Add_Click({
    $new = @(Pick-Videos)
    if ($new.Count) { foreach ($f in $new) { if ($script:Extra -notcontains $f) { [void]$script:Extra.Add($f) } }; Refresh-Library; Load-Path $new[0] }
})
$ui.Videos.Add_SelectionChanged({
    if ($st.SyncingList) { return }
    if ($ui.Videos.SelectedItems.Count -ne 1) { return }          # several selected (Ctrl/Shift+click): for a round, don't switch
    $n = $ui.Videos.SelectedItem.Tag
    if ($n -is [hashtable] -and $n.Kind -ne 'round' -and $n.Path -ine $st.Video) { $script:LoadNext = $n.Path; Later { Load-Path $script:LoadNext } }   # the list is rebuilt: not inside its own event
})
$ui.BtnFolder.Add_Click({ Set-Folder })
$ui.BtnChooseFolder.Add_Click({ Set-Folder })
$ui.FolderBar.Add_MouseLeftButtonUp({ Set-Folder })
$ui.LooseBar.Add_MouseLeftButtonUp({
    # select the recordings that aren't in a round, ready for Make round
    $st.SyncingList = $true
    $ui.Videos.SelectedItems.Clear()
    foreach ($it in $ui.Videos.Items) { if ($it.Tag -is [hashtable] -and $it.Tag.Kind -eq 'rec' -and -not $it.Tag.Round) { [void]$ui.Videos.SelectedItems.Add($it) } }
    $st.SyncingList = $false
    $ui.MarkText.Text = "$($ui.Videos.SelectedItems.Count) selected - Ctrl+click to change the selection, then Make round"
})
$ui.BtnRound.Add_Click({ Make-Round })
$ui.BtnUndo.Add_Click({ Undo-Round })
$ui.BtnDelete.Add_Click({ Delete-Selected })
$ui.ChkClips.IsChecked = -not ((Get-Settings).ShowClips -eq $false)
$ui.ChkClips.Add_Click({ Set-Setting 'ShowClips' ([bool]$ui.ChkClips.IsChecked); Render-Library })
# right-click menu on the recordings list
$libMenu = New-Object Windows.Controls.ContextMenu
foreach ($m in @(@('Play', { $n = @(Selected-Nodes | Where-Object { $_.Kind -ne 'round' })[0]; if ($n) { Load-Path $n.Path } }),
                 @('Add to clip list (for Join)', { Add-ToClipList }),
                 @('Make round...', { Make-Round }),
                 @('Show in folder', { $n = @(Selected-Nodes)[0]; if ($n -and $n.Path -ne '::extra') { if ($n.Kind -eq 'round') { Start-Process explorer.exe (Quote-Arg $n.Path) } else { Show-InFolder $n.Path } } }),
                 @('Delete (to Recycle Bin)...', { Delete-Selected }))) {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $m[0]; $mi.Add_Click($m[1]); [void]$libMenu.Items.Add($mi)
}
$ui.Videos.ContextMenu = $libMenu
# clip list
$ui.BtnClipPlay.Add_Click({ Play-Clip })
$ui.BtnClipUp.Add_Click({ Move-Clip -1 })
$ui.BtnClipDown.Add_Click({ Move-Clip 1 })
$ui.BtnClipRemove.Add_Click({ Remove-Clip })
$ui.BtnClipClear.Add_Click({ Clear-Clips })
$ui.Slices.Add_MouseDoubleClick({ Play-Clip })

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
        $g = [string][char]$(if ($st.Playing) { 0xE769 } else { 0xE768 }); if ([string]$ui.BtnPlay.Content -ne $g) { $ui.BtnPlay.Content = $g }
        $ui.TimeText.Text = '{0} / {1}{2}' -f (Short $p), (Short $st.Dur), (Speed-Text)
        if ($null -ne $st.Start -and $null -eq $st.End) { Update-Marks }
        Check-Jobs
        Check-Join
        Check-Scans
        Check-Preview
        Check-Mpv
    } catch {}
})

$win.Add_SizeChanged({ Update-Marks; Draw-KillTicks })
$win.Add_Closing({
    param($s, $e)
    if ($st.Join) { [void][System.Windows.MessageBox]::Show('Wait a moment - the clips are being joined.', 'FragCut'); $e.Cancel = $true; return }
    if ($st.Running -or $st.Jobs.Count) {
        $r = [System.Windows.MessageBox]::Show('Slices are still being saved. Close anyway? (unfinished ones will be lost)', 'FragCut', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        try { if ($st.Running) { $st.Running.Proc.Kill() } } catch {}
    }
    foreach ($sc in @($st.Scans.Values)) { if (-not $sc.Done) { $sc.Cancel() } }    # unfinished kill scans
    Stop-Preview
    $timer.Stop(); P-Close
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

if ($RoundTest) {
    # automated check of rounds: select the first two recordings, make a round (dialog answered by a timer), cut a clip,
    # then undo the round; prints what happened, then closes. Give it a folder.
    $script:rstep = 0; $script:rlog = New-Object System.Collections.ArrayList
    function Show-Tree { $root = Get-GameDir $queue[0]; foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) { [void]$script:rlog.Add('     ' + $f.FullName.Substring($root.Length + 1)) } }
    $rt = New-Object Windows.Threading.DispatcherTimer
    $rt.Interval = [TimeSpan]::FromMilliseconds(250)
    $rt.Add_Tick({
        $script:rstep++; $k = $script:rstep
        function L($m) { [void]$script:rlog.Add($m) }
        switch ($k) {
            6  { Load-Video 0; L ("  list: " + (($ui.Videos.Items | ForEach-Object { $_.Content.Text }) -join ' | ')) }
            10 { Seek-To 3.0 }
            12 {
                [void]$ui.Videos.SelectedItems.Add(@($ui.Videos.Items | Where-Object { $_.Tag -is [hashtable] -and $_.Tag.Path -eq $queue[1] })[0])
                L ("  selected {0}, playing index {1}" -f $ui.Videos.SelectedItems.Count, $st.Index)
                $script:dt = New-Object Windows.Threading.DispatcherTimer
                $script:dt.Interval = [TimeSpan]::FromMilliseconds(600)
                $script:dt.Add_Tick({
                    $script:dt.Stop()
                    $script:RD.Tag.Text = 'TEST'
                    L ("  dialog: tag TEST, round {0}, ok enabled {1}`n" -f $script:RD.Num.Text, $script:RD.Ok.IsEnabled + $script:RD.Preview.Text)
                    $script:RD.Win.DialogResult = $true
                })
                $script:dt.Start()
                Make-Round
                L ("  after round: {0}  now playing [{1}] {2} at {3:N1} s" -f $ui.MarkText.Text, $st.Index, (Split-Path $st.Video -Leaf), (Pos))
            }
            20 { L ("  position after reopen: {0:N1} s" -f (Pos)); $st.Start = 4.0; $st.End = 5.0; Cut-Slice }
            30 { if (-not $st.Running) { L ("  slice: " + ($ui.Slices.Items -join ' || ')); L '  files:'; Show-Tree } else { $script:rstep-- } }
            32 {
                $script:mb = $null
                Apply-Moves { Undo-LastRound } | Out-Null
                L ("  undo: {0} files moved back, playing {1}" -f @($script:LastMoved).Count, (Split-Path $st.Video -Leaf)); L '  files:'; Show-Tree
            }
        }
        if ($k -gt 36) { Write-Host ("ROUNDTEST`n" + ($script:rlog -join "`n")); $rt.Stop(); $win.Close() }
        if ($k -gt 200) { Write-Host 'ROUNDTEST timeout'; $rt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $rt.Start() })
}

if ($GripTest) {
    # automated check of dragging the marked part's edges (the mouse handlers call these same functions)
    $script:gstep = 0; $script:glog = New-Object System.Collections.ArrayList
    $gt = New-Object Windows.Threading.DispatcherTimer
    $gt.Interval = [TimeSpan]::FromMilliseconds(250)
    $gt.Add_Tick({
        $script:gstep++; $k = $script:gstep
        function L($m) { [void]$script:glog.Add($m) }
        function Px([double]$t) { $ui.RangeCanvas.ActualWidth * $t / $st.Dur }
        switch ($k) {
            6  { Seek-To 2.0; Mark-Start; Seek-To 6.0; Mark-End; L ("  marked {0:N2}-{1:N2}, grips visible: start {2} end {3}" -f $st.Start, $st.End, $ui.StartGrip.Visibility, $ui.EndGrip.Visibility) }
            8  { L ("  hit test: at start {0}, 5 px right of start {1}, at end {2}, middle {3}" -f (Grip-At (Px 2.0)), (Grip-At ((Px 2.0) + 5)), (Grip-At (Px 6.0)), (Grip-At (Px 4.0)))
                 $st.Grip = 'start'; $st.GripWasPlaying = $st.Playing; $st.GripFrom = Base-Pos; Pause-Video; Move-Grip 3.3; Move-Grip 1.25; End-Grip
                 L ("  dragged start to 1.25: {0:N2}-{1:N2}, playing {2}, pos {3:N2}" -f $st.Start, $st.End, $st.Playing, $st.LastSeek) }
            12 { $st.Grip = 'end'; $st.GripWasPlaying = $st.Playing; $st.GripFrom = Base-Pos; Pause-Video; Move-Grip 0.5; End-Grip
                 L ("  dragged end before the start: {0:N2}-{1:N2} (end stays 0.1 s after start)" -f $st.Start, $st.End) }
            16 { $st.Grip = 'end'; Pause-Video; Move-Grip 8.4; End-Grip; L ("  dragged end to 8.4: {0:N2}-{1:N2}, replay from {2:N2}" -f $st.Start, $st.End, $st.LastSeek) }
            20 { Clear-Marks; Seek-To 3.0; Mark-Start; Seek-To 7.0; L ("  only a start at {0:N2}: end grip {1}, hit at 7.0 = {2}" -f $st.Start, $ui.EndGrip.Visibility, (Grip-At (Px 7.0)))
                 $st.Grip = 'start'; $st.GripWasPlaying = $st.Playing; $st.GripFrom = Base-Pos; Pause-Video; Move-Grip 1.5; End-Grip
                 L ("  dragged start to 1.5: start {0:N2}, back at {1:N2}" -f $st.Start, $st.LastSeek) }
            22 { $ui.ChkFast.IsChecked = $true; Seek-To 6.0; Mark-End; $st.Grip = 'start'; Pause-Video; Move-Grip 2.6; End-Grip
                 L ("  fast cut on, dragged start to 2.6: start {0:N2} (keyframe)" -f $st.Start); $ui.ChkFast.IsChecked = $false }
        }
        if ($k -gt 24) { Write-Host ("GRIPTEST`n" + ($script:glog -join "`n")); $gt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $gt.Start() })
}

if ($LibTest) {
    # automated check of the recordings list, the clip list and the background join. Run it with no files:
    # it opens the folder set as WorkFolder. Prints what happened, then closes.
    $script:AutoYes = $true; $script:AskLog = New-Object System.Collections.ArrayList
    $script:lstep = 0; $script:llog = New-Object System.Collections.ArrayList
    function Rows { @($ui.Videos.Items | ForEach-Object { $t = $_.Content; if ($t -is [Windows.Controls.TextBlock]) { '{0}{1}{2}{3}' -f (' ' * [int](($_.Padding.Left - 4) / 8)), $t.Text, $(if ($t.FontStyle -eq 'Italic') { ' /i' } else { '' }), $(if ($t.Foreground.ToString() -eq $script:Brush.Loose.ToString() -or $t.Foreground.ToString() -eq $script:Brush.LooseClip.ToString()) { ' /yellow' } else { '' }) } else { "($t)" } }) }
    function Pick([string]$like) { $ui.Videos.SelectedItems.Clear(); foreach ($it in $ui.Videos.Items) { if ($it.Tag -is [hashtable] -and $it.Tag.Name -like $like) { [void]$ui.Videos.SelectedItems.Add($it) } } }
    $lt = New-Object Windows.Threading.DispatcherTimer
    $lt.Interval = [TimeSpan]::FromMilliseconds(250)
    $lt.Add_Tick({
        $script:lstep++; $k = $script:lstep
        function L($m) { [void]$script:llog.Add($m) }
        switch ($k) {
            4  { L "root: $script:Root   playing: $(Split-Path $st.Video -Leaf)  paused: $(-not $st.Playing)"; L '  list:'; Rows | ForEach-Object { L "    $_" } }
            6  {
                Pick 'Test Game*18.19*'; $ui.Videos.SelectedItems.Add(@($ui.Videos.Items | Where-Object { $_.Tag -is [hashtable] -and $_.Tag.Name -like 'Test Game*18.26*' })[0]) | Out-Null
                $script:dt = New-Object Windows.Threading.DispatcherTimer; $script:dt.Interval = [TimeSpan]::FromMilliseconds(500)
                $script:dt.Add_Tick({ $script:dt.Stop(); $script:RD.Tag.Text = 'TEST'; $script:RD.Win.DialogResult = $true }); $script:dt.Start()
                Make-Round
                L "made round: $($ui.MarkText.Text)"; L '  list:'; Rows | ForEach-Object { L "    $_" }
            }
            8  { Load-Path $queue[0]; L "playing $(Split-Path $st.Video -Leaf)" }
            10 { $st.Start = 1.0; $st.End = 2.0; Cut-Slice; $st.Start = 3.0; $st.End = 4.5; Cut-Slice; $st.Start = 0.5; $st.End = 1.5; Cut-Slice }
            20 { if ($st.Running -or $st.Jobs.Count) { $script:lstep-- } else { L '  clip list:'; $ui.Slices.Items | ForEach-Object { L "    $_" }; L '  list:'; Rows | ForEach-Object { L "    $_" } } }
            21 { $ui.Slices.SelectedIndex = 2; Move-Clip -1; Move-Clip -1; $ui.Slices.SelectedIndex = 1; Remove-Clip; L '  clip list after: 3rd up twice, then remove the 2nd:'; $ui.Slices.Items | ForEach-Object { L "    $_" } }
            22 { Pick '*clip 00m03-00m04*'; Add-ToClipList; $ui.Slices.SelectedIndex = 0; Play-Clip; L "  added a clip from the list; playing $(Split-Path $st.Video -Leaf), index $($st.Index)" }
            24 { Join-Slices; L "  join started: $($ui.MarkText.Text)" }
            25 { if ($st.Join) { $script:lstep-- } else { L "  join done: $($ui.MarkText.Text); clip list now $($st.Clips.Count) rows"; L '  list:'; Rows | ForEach-Object { L "    $_" } } }
            27 { Load-Path $queue[0]; Pick '*montage*'; Delete-Selected; L "  delete montage: $($ui.MarkText.Text)" }
            29 { Pick 'TEST-1-1 *'; Delete-Selected; L "  delete the recording that plays: $($ui.MarkText.Text); now playing $(Split-Path $st.Video -Leaf)"; L '  list:'; Rows | ForEach-Object { L "    $_" }; L ("  asked: " + (($script:AskLog | ForEach-Object { ($_ -split "`n")[0] }) -join ' / ')) }
            31 { $r = @($st.Lib | Where-Object { $_.Kind -eq 'round' })[0]; $st.Expanded[$r.Path] = $false; $ui.ChkClips.IsChecked = $false; Render-Library; L '  round closed, clips hidden:'; Rows | ForEach-Object { L "    $_" } }
        }
        if ($k -gt 32) { Write-Host ("LIBTEST`n" + ($script:llog -join "`n")); $lt.Stop(); $win.Close() }
        if ($k -gt 400) { Write-Host 'LIBTEST timeout'; $lt.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $lt.Start() })
}

if ($ShotTest) {
    # screenshot of the window (for checking the layout): opens a round, puts its clips on the clip list, saves a PNG to $ShotTest
    $script:sstep = 0
    $sh = New-Object Windows.Threading.DispatcherTimer
    $sh.Interval = [TimeSpan]::FromMilliseconds(250)
    $sh.Add_Tick({
        $script:sstep++
        if ($script:sstep -eq 4) {
            $r = @($st.Lib | Where-Object { $_.Kind -eq 'round' -and (Count-Clips $_) -ge 2 })[0]
            if ($r) {
                $st.Expanded[$r.Path] = $true; Render-Library
                $ui.Videos.SelectedItems.Clear(); foreach ($it in $ui.Videos.Items) { if ($it.Tag -is [hashtable] -and $it.Tag.Kind -eq 'clip' -and $it.Tag.Round -eq $r.Path) { [void]$ui.Videos.SelectedItems.Add($it) } }
                Add-ToClipList
                $rec = @($r.Children | Where-Object { $_.Kind -eq 'rec' })[0]; if ($rec) { Load-Path $rec.Path -Paused }
            }
        }
        if ($script:sstep -eq 16) {
            Add-Type -AssemblyName System.Drawing
            $src = [Windows.PresentationSource]::FromVisual($win); $m = $src.CompositionTarget.TransformToDevice
            $x = [int]($win.Left * $m.M11); $y = [int]($win.Top * $m.M22); $w = [int]($win.ActualWidth * $m.M11); $h = [int]($win.ActualHeight * $m.M22)
            $bmp = New-Object Drawing.Bitmap $w, $h
            $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size); $g.Dispose()
            $bmp.Save($ShotTest, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
            Write-Host "SHOT $ShotTest"
            $sh.Stop(); $win.Close()
        }
    })
    $win.Add_ContentRendered({ $win.Activate(); $win.Topmost = $true; $sh.Start() })
}

if ($Shots) {
    # README screenshots: run on a demo folder (passed as the file argument); saves numbered PNGs into the $Shots folder
    $script:shk = 0; $script:shWait = $null
    function Grab($w) {
        Add-Type -AssemblyName System.Drawing
        if (-not ('ShotWin' -as [type])) { Add-Type -Name ShotWin -Namespace '' -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, int[] r, int s);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, int[] r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
'@ }
        # PrintWindow draws the window itself, even if another window is on top of it
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $w).Handle
        $wr = New-Object int[] 4; [void][ShotWin]::GetWindowRect($hwnd, $wr)
        $fr = New-Object int[] 4; [void][ShotWin]::DwmGetWindowAttribute($hwnd, 9, $fr, 16)   # the visible frame, without the invisible resize border
        $full = New-Object Drawing.Bitmap ($wr[2] - $wr[0]), ($wr[3] - $wr[1])
        $g = [Drawing.Graphics]::FromImage($full); $dc = $g.GetHdc(); [void][ShotWin]::PrintWindow($hwnd, $dc, 2); $g.ReleaseHdc($dc); $g.Dispose()
        $bmp = $full.Clone((New-Object Drawing.Rectangle ($fr[0] - $wr[0]), ($fr[1] - $wr[1]), ($fr[2] - $fr[0]), ($fr[3] - $fr[1])), $full.PixelFormat); $full.Dispose()
        return @{ Bmp = $bmp; X = $fr[0]; Y = $fr[1] }
    }
    function Shot([string]$name, $over) {
        $m = Grab $win; $bmp = $m.Bmp
        if ($over) { $o = Grab $over; $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($o.Bmp, $o.X - $m.X, $o.Y - $m.Y, $o.Bmp.Width, $o.Bmp.Height); $g.Dispose(); $o.Bmp.Dispose() }
        $out = Join-Path $Shots "$name.png"; $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Write-Host "SHOT $out"
    }
    function Mark([double]$a, [double]$b) { $st.Start = $a; $st.End = $b; Start-Loop }
    function Only-New { foreach ($n in $st.Lib) { if ($n.Kind -eq 'round') { $st.Expanded[$n.Path] = $n.Name -like 'BF6-14 *' } }; Render-Library }
    $sx = New-Object Windows.Threading.DispatcherTimer
    $sx.Interval = [TimeSpan]::FromMilliseconds(250)
    $sx.Add_Tick({
        $script:shk++; $k = $script:shk
        if ($script:shWait) { if (& $script:shWait) { $script:shWait = $null; $script:shk = 1000 * ([math]::Floor($k / 1000) + 1) - 1 } else { return } }
        switch ($k) {
            # 1: the Library - a round open with its clips, three recordings not in a round yet
            4 {
                $ui.ChkClips.IsChecked = $true
                $r = @($st.Lib | Where-Object { $_.Kind -eq 'round' -and $_.Name -like 'BF6-9 *' })[0]
                $rec = @($r.Children | Where-Object { $_.Kind -eq 'rec' })[0]
                Load-Path $rec.Path -Paused
            }
            10 { Seek-To 36.0 }
            16 { Shot '1-library' }
            # 2: select the loose recordings, Make round
            18 {
                foreach ($n in $st.Lib) { if ($n.Kind -eq 'round') { $st.Expanded[$n.Path] = $false } }
                Render-Library
                $st.SyncingList = $true; $ui.Videos.SelectedItems.Clear()
                foreach ($it in $ui.Videos.Items) { if ($it.Tag -is [hashtable] -and $it.Tag.Kind -eq 'rec' -and -not $it.Tag.Round) { [void]$ui.Videos.SelectedItems.Add($it) } }
                $st.SyncingList = $false
                Later { Make-Round }
            }
            26 { Shot '2-make-round' $script:RD.Win; $script:RD.Win.DialogResult = $true }
            # 3: the new round's first recording, a part marked and looping
            32 {
                $r = @($st.Lib | Where-Object { $_.Kind -eq 'round' -and $_.Name -like 'BF6-14 *' })[0]
                $rec = @($r.Children | Where-Object { $_.Kind -eq 'rec' })[0]
                Load-Path $rec.Path -Paused
            }
            40 { Only-New; Mark 99.0 104.5 }
            48 { Cut-Slice; $script:shWait = { -not $st.Jobs.Count } }
            1000 { Only-New; Mark 105.6 110.2 }
            1012 { Shot '3-marked' }
            1013 { Cut-Slice }
            1016 { Shot '4-cut-keeps-playing'; $script:shWait = { -not $st.Jobs.Count } }
            2000 { Mark 112.0 117.5 }
            2006 { Cut-Slice; $script:shWait = { -not $st.Jobs.Count } }
            # 5: the clip list, ready to join
            3000 { Only-New; Pause-Video; Seek-To 110.9; $ui.Slices.SelectedIndex = 1 }
            3008 { Shot '5-clip-list' }
            3010 { Join-Slices; $script:shWait = { -not $st.Join } }
            4002 { Only-New }
            4006 { Shot '6-joined' }
            4008 { $sx.Stop(); $win.Close() }
        }
        if ($k -gt 900 -and $k -lt 1000 -or $k -gt 9000) { Write-Host 'SHOTS timeout'; $sx.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $win.Activate(); $win.Topmost = $true; $sx.Start() })
}

if ($FastTest) {
    # automated check of fast cut: start snaps to a keyframe, Q/W step by keyframes, the clip is copied; prints results, then closes
    $script:fstep = 0; $script:flog = New-Object System.Collections.ArrayList
    $ft = New-Object Windows.Threading.DispatcherTimer
    $ft.Interval = [TimeSpan]::FromMilliseconds(250)
    $ft.Add_Tick({
        $script:fstep++; $k = $script:fstep
        function L($m) { [void]$script:flog.Add($m) }
        switch ($k) {
            6  { $ui.ChkFast.IsChecked = $true; Seek-To 2.4; L "  >> fast on, seek 2.4" }
            9  { Mark-Start; Seek-To 5.3 }
            11 { Mark-End; L ("  >> marked: {0:N3}-{1:N3}  text: {2}" -f $st.Start, $st.End, $ui.MarkText.Text) }
            14 { Nudge 'start' 0.2; L ("  >> W: start {0:N3}" -f $st.Start) }
            16 { Nudge 'start' (-0.2); L ("  >> Q: start {0:N3}" -f $st.Start) }
            18 { Nudge 'start' (-0.2); L ("  >> Q: start {0:N3}" -f $st.Start) }
            20 { Nudge 'start' 0.2; Nudge 'start' 0.2; Nudge 'start' 0.2; L ("  >> W x3: start {0:N3} (end {1:N3})" -f $st.Start, $st.End) }
            22 { Nudge 'start' (-0.2); Nudge 'start' (-0.2); Cut-Slice; L "  >> cut" }
        }
        if ($k -gt 24 -and -not $st.Running -and $st.Jobs.Count -eq 0) {
            Write-Host ("FASTTEST`n  " + ($script:flog -join "`n  ") + "`n  slices: " + ($ui.Slices.Items -join ' || ') + "`n  files: " + (@($st.Clips | Where-Object { $_.Saved } | ForEach-Object { $_.Mp4 }) -join ' | '))
            $ft.Stop(); $win.Close()
        }
        if ($k -gt 160) { Write-Host 'FASTTEST timeout'; $ft.Stop(); $win.Close() }
    })
    $win.Add_ContentRendered({ $ft.Start() })
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

if ($PreviewTest) {
    # automated check of the preview copy: waits until the video plays (directly or from a preview), prints what happened
    $script:pt0 = [datetime]::Now; $script:plog = New-Object System.Collections.ArrayList
    $pt = New-Object Windows.Threading.DispatcherTimer
    $pt.Interval = [TimeSpan]::FromMilliseconds(500)
    $pt.Add_Tick({
        $s = ([datetime]::Now - $script:pt0).TotalSeconds
        [void]$script:plog.Add(('{0,5:N1}s  preview={1} using={2} pos={3:N2} dur={4:N2}  "{5}"' -f $s, [bool]$st.Preview, $st.UsingPreview, (Pos), $st.Dur, $ui.MarkText.Text))
        if ((Pos) -gt 1.5 -and $st.Index + 1 -lt $queue.Count) { [void]$script:plog.Add('  >> next recording'); Next-Video; return }   # several files: play each
        if ((Pos) -gt 1.5 -or $s -gt 180) {
            Write-Host ("PREVIEWTEST`n  " + ($script:plog -join "`n  ") + "`n  title: " + $ui.TitleText.Text); $pt.Stop(); $win.Close()
        }
    })
    $win.Add_ContentRendered({ $pt.Start() })
}

$win.Add_Loaded({
    Start-Mpv; Set-Title; Render-Slices
    foreach ($f in $sentFiles) { [void]$script:Extra.Add($f) }   # shown in their own group if they're not in the folder
    Refresh-Library
    if ($sentFiles.Count) { Load-Path $sentFiles[0] }
    elseif ($queue.Count) { Load-Path $queue[$queue.Count - 1] -Paused }                    # the newest recording, paused
    else { $ui.MarkText.Text = 'Choose the folder with your recordings (top bar)' }
    $timer.Start()
})
[void]$win.ShowDialog()

# remove placeholders of slices that never finished
foreach ($j in @($st.Jobs) + @($st.Running)) { if ($j -and $j.Kind -eq 'mp4') { try { $f = Get-Item -LiteralPath $j.Mp4 -EA Stop; if ($f.Length -eq 0) { Remove-Item -LiteralPath $j.Mp4 } } catch {} } }
$saved = @($st.Clips | Where-Object { $_.Saved } | ForEach-Object { $_.Mp4 })
if ($saved.Count -and -not $SelfTest -and -not $FastTest -and -not $RoundTest -and -not $GripTest -and -not $LibTest -and -not $ShotTest -and -not $Shots) { Show-InFolder $saved[$saved.Count - 1] }

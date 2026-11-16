# FragCut - rounds: group recordings of one game round into a folder, renamed and numbered.
# Dot-sourced by FragCut.ps1 (after Core.ps1 and Kills.ps1).
#
#   Battlefield 6\
#     BF6-12 2026-11-13\                                     <- round folder: <tag>-<number> <date of the first recording>
#       BF6-12-1 Battlefield 6 2026.11.13 - 18.19.09.77.DVR.mp4   <- <tag>-<number>-<order by recording time> <original name>
#       BF6-12-2 Battlefield 6 2026.11.13 - 18.26.22.78.DVR.mp4
#       clips\                                               <- clips cut from them
#
# Every grouping is written to rounds-log.json so it can be undone.

$script:RoundLog = Join-Path $env:LOCALAPPDATA 'FragCut\rounds-log.json'
$script:VideoExt = '.mp4', '.mkv', '.mov', '.avi', '.webm'

# When a recording was made: the earlier of created / last written (a copied file gets a new creation time)
function Get-RecordTime($file) {
    $f = Get-Item -LiteralPath $file
    if ($f.CreationTime -lt $f.LastWriteTime) { return $f.CreationTime } else { return $f.LastWriteTime }
}

# Clips, montages and compressed copies made by FragCut (not recordings)
function Test-MadeByFragCut([string]$leaf) {
    $b = [IO.Path]::GetFileNameWithoutExtension($leaf)
    return ($b -match ' - clip \d+m\d+-\d+m\d+' -or $b -match '^[A-Za-z0-9_]+-\d+-\d+ clip \d+m\d+-\d+m\d+' -or $b -match '(^| - |^[A-Za-z0-9_]+-\d+ )(kill )?montage( \(\d+\))?$' -or $b -match ' - compressed( \(\d+\))?$')
}

# Recordings in a folder and in its round folders (not in "clips"), oldest first
function Get-FolderVideos($dir) {
    $files = New-Object System.Collections.ArrayList
    $dirs = @($dir) + @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Za-z0-9_]+-\d+( |$)' } | ForEach-Object { $_.FullName })
    foreach ($d in $dirs) {
        foreach ($f in (Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
            if ($script:VideoExt -contains $f.Extension.ToLowerInvariant() -and -not (Test-MadeByFragCut $f.Name)) { [void]$files.Add($f.FullName) }
        }
    }
    return @($files | Sort-Object { Get-RecordTime $_ })
}

# ---------- tag and number ----------
$script:KnownGames = [ordered]@{
    'battlefield' = 'BF'; 'apex' = 'APEX'; 'call of duty' = 'COD'; 'counter-strike' = 'CS'; 'valorant' = 'VAL'
    'fortnite' = 'FN'; 'overwatch' = 'OW'; 'rainbow six' = 'R6'; 'pubg' = 'PUBG'; 'rocket league' = 'RL'; 'league of legends' = 'LOL'
}
function Get-SettingMap($name) {
    $m = @{}
    $v = (Get-Settings).$name
    if ($v) { foreach ($p in $v.PSObject.Properties) { $m[$p.Name] = $p.Value } }
    return $m
}
function Set-SettingMap($name, $key, $value) {
    $m = Get-SettingMap $name
    $m[$key] = $value
    Set-Setting $name ([pscustomobject]$m)
}

# Suggested tag: the one used for this game folder before, else a short name for a known game, else the last one used
function Get-SuggestedTag($gameDir, $videos) {
    $leaf = Split-Path $gameDir -Leaf
    $known = Get-SettingMap 'RoundTags'
    if ($known.ContainsKey($leaf)) { return $known[$leaf] }
    foreach ($v in $videos) { $p = Get-RoundParts $v; if ($p) { return $p.Tag } }
    $names = @($leaf) + @($videos | ForEach-Object { Split-Path $_ -Leaf })
    foreach ($n in $names) {
        $low = "$n".ToLowerInvariant()
        foreach ($g in $script:KnownGames.Keys) {
            if ($low.StartsWith($g)) {
                $num = if ($low.Substring($g.Length) -match '^\s*(\d{1,2})\b') { $Matches[1] } else { '' }
                return $script:KnownGames[$g] + $num
            }
        }
    }
    $last = (Get-Settings).LastRoundTag
    if ($last) { return $last }
    return 'GAME'
}

# Next round number for a tag: one more than the highest used (round folders in the game folder, or remembered)
function Get-NextRoundNumber($gameDir, [string]$tag) {
    $max = 0
    $counters = Get-SettingMap 'RoundCounters'
    if ($counters.ContainsKey($tag)) { $max = [int]$counters[$tag] }
    $rx = "^$([regex]::Escape($tag))-(\d+)( |$)"
    foreach ($d in (Get-ChildItem -LiteralPath $gameDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match $rx) { $max = [math]::Max($max, [int]$Matches[1]) }
    }
    return $max + 1
}

# ---------- plan, move, undo ----------
# Returns @{ Dir = round folder; Moves = list of @{ From; To } } - recordings ordered by recording time, plus their clips.
function Get-RoundPlan($videos, [string]$tag, [int]$n) {
    $videos = @($videos | Sort-Object { Get-RecordTime $_ })
    $gameDir = Get-GameDir $videos[0]
    $date = (Get-RecordTime $videos[0]).ToString('yyyy-MM-dd')
    $dir = Join-Path $gameDir "$tag-$n $date"
    $clipDir = Join-Path $dir 'clips'
    $moves = New-Object System.Collections.ArrayList
    $k = 0
    foreach ($v in $videos) {
        $k++
        $p = Get-RoundParts $v
        $rest = if ($p) { $p.Rest } else { Split-Path $v -Leaf }
        [void]$moves.Add(@{ From = $v; To = (Join-Path $dir "$tag-$n-$k $rest") })
        # its clips (next to it, or in its clips folder)
        $oldBase = Get-ClipBase $v
        foreach ($cd in @((Split-Path $v -Parent), (Get-ClipDir $v))) {
            foreach ($c in (Get-ChildItem -LiteralPath $cd -File -ErrorAction SilentlyContinue)) {
                if ($c.Name.StartsWith("$oldBase ", [StringComparison]::OrdinalIgnoreCase) -and $c.FullName -ne $v) {
                    [void]$moves.Add(@{ From = $c.FullName; To = (Join-Path $clipDir ("$tag-$n-$k clip " + $c.Name.Substring($oldBase.Length + 1))) })
                }
            }
        }
    }
    return @{ Dir = $dir; Moves = $moves; Tag = $tag; N = $n; GameDir = $gameDir }
}

# Moves files (retrying briefly while a player lets go of them). On failure, moves back what was moved and throws.
function Move-Files($moves) {
    $done = New-Object System.Collections.ArrayList
    try {
        foreach ($m in $moves) {
            if ($m.From -eq $m.To) { continue }
            if (Test-Path -LiteralPath $m.To) { throw "There's already a file named $(Split-Path $m.To -Leaf) there." }
            [IO.Directory]::CreateDirectory((Split-Path $m.To -Parent)) | Out-Null
            $tries = 0
            while ($true) {
                try { [IO.File]::Move($m.From, $m.To); break }
                catch [IO.IOException] { if (++$tries -ge 20) { throw "Couldn't move $(Split-Path $m.From -Leaf): $($_.Exception.InnerException.Message)$($_.Exception.Message)" }; Start-Sleep -Milliseconds 150 }
            }
            [void]$done.Add($m)
        }
    } catch {
        for ($i = $done.Count - 1; $i -ge 0; $i--) { try { [IO.File]::Move($done[$i].To, $done[$i].From) } catch {} }
        throw
    }
    Move-KillCache $done
    return $done
}

# Kill search results are remembered by file path: carry them over to the new names
function Move-KillCache($moves) {
    try {
        $c = Read-KillCache
        if (-not $c.Count) { return }
        $changed = $false
        foreach ($e in $c) {
            foreach ($m in $moves) {
                $old = $m.From.ToLowerInvariant() + '|'
                if ($e.Key.StartsWith($old)) { $e.Key = $m.To.ToLowerInvariant() + '|' + $e.Key.Substring($old.Length); $changed = $true }
            }
        }
        if ($changed) { ConvertTo-Json -InputObject $c.ToArray() -Depth 4 | Set-Content -LiteralPath $script:KillCacheFile -Encoding UTF8 }
    } catch {}
}

# Removes folders left empty (a round's clips folder, then the round folder)
function Remove-EmptyDirs($dirs) {
    foreach ($d in ($dirs | Sort-Object Length -Descending -Unique)) {
        try { if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) { [IO.Directory]::Delete($d) } } catch {}
    }
}

function Read-RoundLog {
    $out = New-Object System.Collections.ArrayList
    try { foreach ($e in (ConvertFrom-Json (Get-Content -LiteralPath $script:RoundLog -Raw -ErrorAction Stop))) { [void]$out.Add($e) } } catch {}
    return ,$out
}
function Save-RoundLog($log) {
    while ($log.Count -gt 50) { $log.RemoveAt(0) }
    New-Item -ItemType Directory -Force (Split-Path $script:RoundLog) | Out-Null
    ConvertTo-Json -InputObject @($log.ToArray()) -Depth 5 | Set-Content -LiteralPath $script:RoundLog -Encoding UTF8
}

# Does the plan; returns the moves done
function Invoke-RoundPlan($plan) {
    $oldDirs = @($plan.Moves | ForEach-Object { Split-Path $_.From -Parent } | Sort-Object -Unique)
    $done = Move-Files $plan.Moves
    Remove-EmptyDirs ($oldDirs | Where-Object { $_ -ne $plan.GameDir })
    $log = Read-RoundLog
    [void]$log.Add([pscustomobject]@{ Name = (Split-Path $plan.Dir -Leaf); Dir = $plan.Dir; Time = (Get-Date).ToString('s'); Tag = $plan.Tag; N = $plan.N; Moves = @($done | ForEach-Object { [pscustomobject]@{ From = $_.From; To = $_.To } }) })
    Save-RoundLog $log
    Set-SettingMap 'RoundTags' (Split-Path $plan.GameDir -Leaf) $plan.Tag
    Set-SettingMap 'RoundCounters' $plan.Tag ([math]::Max($plan.N, [int](Get-SettingMap 'RoundCounters')[$plan.Tag]))
    Set-Setting 'LastRoundTag' $plan.Tag
    return $done
}

function Get-LastRound { $log = Read-RoundLog; if ($log.Count) { return $log[$log.Count - 1] }; return $null }

# Undoes the last grouping: moves the files back to their old names; returns the moves done (old -> back)
function Undo-LastRound {
    $log = Read-RoundLog
    if (-not $log.Count) { throw 'Nothing to undo.' }
    $e = $log[$log.Count - 1]
    $back = New-Object System.Collections.ArrayList
    foreach ($m in @($e.Moves)) { if (Test-Path -LiteralPath $m.To) { [void]$back.Add(@{ From = $m.To; To = $m.From }) } }
    $back.Reverse()
    # files added to the round folder since (clips, montages): clips go back with their recording, the rest to the game's clips folder
    $dir = $e.Dir
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        $recs = @{}; $logged = @{}
        foreach ($m in @($e.Moves)) {
            $logged[$m.To.ToLowerInvariant()] = $true
            if ((Split-Path $m.To -Parent) -eq $dir -and (Split-Path $m.To -Leaf) -match "^$([regex]::Escape($e.Tag))-$($e.N)-(\d+) ") { $recs[[int]$Matches[1]] = $m.From }
        }
        $taken = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File)) {
            if ($logged[$f.FullName.ToLowerInvariant()]) { continue }
            $rx = "^$([regex]::Escape($e.Tag))-$($e.N)-(\d+) clip (.+)$"
            if ($f.Name -match $rx -and $recs[[int]$Matches[1]]) { $rec = $recs[[int]$Matches[1]]; $to = Join-Path (Get-ClipDir $rec) ((Get-ClipBase $rec) + ' ' + $Matches[2]) }
            else { $to = Join-Path (Join-Path (Split-Path $dir -Parent) 'clips') $f.Name }
            $b = [IO.Path]::Combine((Split-Path $to -Parent), [IO.Path]::GetFileNameWithoutExtension($to)); $x = [IO.Path]::GetExtension($to); $n = 1
            while ((Test-Path -LiteralPath $to) -or $taken[$to.ToLowerInvariant()]) { $n++; $to = "$b ($n)$x" }
            $taken[$to.ToLowerInvariant()] = $true
            [void]$back.Add(@{ From = $f.FullName; To = $to })
        }
    }
    $newDirs = @($back | ForEach-Object { Split-Path $_.From -Parent } | Sort-Object -Unique) + @($dir | Where-Object { $_ })
    $done = Move-Files $back
    Remove-EmptyDirs $newDirs
    $log.RemoveAt($log.Count - 1); Save-RoundLog $log
    $c = Get-SettingMap 'RoundCounters'
    if ($e.Tag -and $c.ContainsKey($e.Tag) -and [int]$c[$e.Tag] -eq [int]$e.N) { Set-SettingMap 'RoundCounters' $e.Tag ([int]$e.N - 1) }
    return $done
}

# ---------- dialog ----------
# Asks for the tag and number, shows the new names. Returns the plan, or $null if cancelled.
function Show-RoundDialog($owner, $videos) {
    $gameDir = Get-GameDir (@($videos | Sort-Object { Get-RecordTime $_ })[0])
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FragCut - make a round" Width="720" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#1e1e22" Foreground="#e8e8ea" FontFamily="Segoe UI" FontSize="13">
  <StackPanel Margin="16">
    <TextBlock TextWrapping="Wrap" Foreground="#b8b8c0" Margin="0,0,0,12"
               Text="The recordings get a folder of their own and are renamed and numbered by when they were recorded. Clips already cut from them move along, into its clips folder."/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
      <TextBlock Text="Game tag" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="Tag" Width="110" Padding="4,3" Background="#2d2d34" Foreground="#e8e8ea" BorderBrush="#44444c" CaretBrush="White"/>
      <TextBlock Text="Round" VerticalAlignment="Center" Margin="18,0,8,0"/>
      <TextBox x:Name="Num" Width="60" Padding="4,3" Background="#2d2d34" Foreground="#e8e8ea" BorderBrush="#44444c" CaretBrush="White"/>
      <TextBlock Text="(letters, digits and _ only)" VerticalAlignment="Center" Margin="12,0,0,0" Foreground="#8a8a92"/>
    </StackPanel>
    <TextBox x:Name="Preview" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Height="190" Background="#141417" Foreground="#e8e8ea"
             BorderBrush="#33333a" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="6"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="Ok" Content="Move and rename" Padding="14,6" Margin="0,0,8,0" Background="#3b5bdb" Foreground="White" BorderBrush="#44444c" IsDefault="True"/>
      <Button x:Name="Cancel" Content="Cancel" Padding="14,6" Background="#2d2d34" Foreground="#e8e8ea" BorderBrush="#44444c" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    if ($owner) { $w.Owner = $owner }
    # event handlers see script variables, not this function's: keep the dialog's state in $script:RD
    $script:RD = @{ Win = $w; Videos = $videos; GameDir = $gameDir; Plan = $null; NumTouched = $false }
    foreach ($n in 'Tag','Num','Preview','Ok') { $script:RD[$n] = $w.FindName($n) }
    $script:RD.Tag.Text = Get-SuggestedTag $gameDir $videos
    $script:RD.Num.Text = [string](Get-NextRoundNumber $gameDir $script:RD.Tag.Text)
    $script:RD.Tag.Add_TextChanged({
        $t = $script:RD.Tag.Text.Trim()
        if (-not $script:RD.NumTouched -and $t -match '^[A-Za-z0-9_]{1,16}$') { $script:RD.Num.Text = [string](Get-NextRoundNumber $script:RD.GameDir $t) }
        Update-RoundDialog
    })
    $script:RD.Num.Add_TextChanged({ if ($script:RD.Num.IsKeyboardFocused) { $script:RD.NumTouched = $true }; Update-RoundDialog })
    $script:RD.Ok.Add_Click({ $script:RD.Win.DialogResult = $true })
    $w.Add_ContentRendered({ [void]$script:RD.Tag.Focus(); $script:RD.Tag.SelectAll() })
    Update-RoundDialog
    if ($w.ShowDialog()) { return $script:RD.Plan }
    return $null
}

function Update-RoundDialog {
    $d = $script:RD
    $t = $d.Tag.Text.Trim(); $n = 0
    if ($t -notmatch '^[A-Za-z0-9_]{1,16}$' -or -not [int]::TryParse($d.Num.Text.Trim(), [ref]$n) -or $n -lt 1) {
        $d.Preview.Text = 'Type a tag (like BF6) and a round number.'; $d.Ok.IsEnabled = $false; $d.Plan = $null; return
    }
    $p = Get-RoundPlan $d.Videos $t $n
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("$(Split-Path $p.GameDir -Leaf)\$(Split-Path $p.Dir -Leaf)\")
    $exists = $false
    foreach ($m in $p.Moves) {
        $rel = $m.To.Substring($p.Dir.Length + 1)
        if ($m.To -ne $m.From -and (Test-Path -LiteralPath $m.To)) { $exists = $true; $rel += '   <- already exists' }
        [void]$lines.Add("  $rel")
        [void]$lines.Add("      was: $(Split-Path $m.From -Leaf)")
    }
    $d.Preview.Text = $lines -join "`r`n"
    $d.Ok.IsEnabled = -not $exists
    $d.Plan = $p
}

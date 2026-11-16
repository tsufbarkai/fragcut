# Changelog

## 1.7.0

- **Clips go into a `clips` folder** next to the recording, instead of next to the recording itself.
  Kill montages too. Join saves the montage next to the clips, as before.
- **Open folder**: lists every recording in a folder (and in its round folders), oldest first. You can also choose
  *Send to > FragCut* on a folder.
- **Rounds**: select recordings in the list (Ctrl+click or Shift+click) and click **Make round**. FragCut asks for a
  short game tag (like `BF6`) and suggests the next round number. It moves the recordings into a folder of their own,
  `BF6-12 2026-11-13`, renamed `BF6-12-1 <original name>`, `BF6-12-2 ...` in the order they were recorded.
  Clips already cut from them move into the round's `clips` folder and are renamed `BF6-12-1 clip 01m38-01m43.mp4`.
  New clips of a round's recordings are named the same way, and joining them gives `BF6-12 montage.mp4`.
  FragCut remembers the tag for each game folder and counts the rounds up.
- **Undo round** moves the files of the last round back to their old names and folders. Clips cut since then go
  back with their recording.
- Kill search results carry over when a recording is renamed.

## 1.6.0

- **Fast cut (no re-encode)**: a checkbox in FragCut. When it's on, clips are copied from the recording instead of
  encoded: saving takes well under a second, the quality is the original's, and the size per second is the recording's.
  A copied clip can only start on a keyframe, so the start mark moves back to the keyframe at or before it
  (recordings usually have one every 0.5 to 2 seconds) and `Q` / `W` move the start to the previous / next keyframe.
  The end can be anywhere. The clip keeps the recording's format, so an AV1 or HEVC recording gives an AV1 or HEVC clip,
  which some apps and Windows' own player can't play. Copied clips from the same recording settings join without
  re-encoding. The setting is remembered.

## 1.5.1

- **Clips are no longer much bigger than the recording**: a clip's bitrate is now limited by the recording's:
  up to 1.5x for AV1, HEVC and VP9 recordings (H.264 needs more bits for the same picture) and 1.2x for H.264
  recordings, between 6 and 40 Mbit/s. Before, clips used fixed settings, and on AMD graphics cards had no limit
  at all: a 25 s clip of an AV1 recording could be about as big as the 2-minute recording.
  On a 1440p60 AV1 recording the clips measure VMAF 97.9 against the original.
- AMD and Intel encoders use a capped variable bitrate instead of a fixed quantizer.
- When FragCut picks the encoder, it now tests the exact clip settings, and falls back to simpler capped settings
  if a driver doesn't accept them.
- Clips always use H.264 High profile, level 5.2, so clips with different bitrates still join without re-encoding.
  Join also checks the level, so older clips are re-encoded instead of being joined wrongly.
- Compress skips AV1, HEVC and VP9 videos: they're already more compact than the H.264 copy it would make.

## 1.5.0

- **mpv as the player**: if [mpv](https://mpv.io) is installed, FragCut plays recordings with it, inside its window.
  It plays H.264, HEVC, AV1 and VP9 directly and decodes on the graphics card, so AV1 recordings open
  right away instead of waiting for a preview copy. Without mpv, FragCut uses Windows' player as before.
  The window title shows which player is used.
- **Installer window**: `Install.bat` opens a window instead of a console. It shows whether ffmpeg (required) and
  mpv (recommended) are installed, and installs the missing ones when you click Install: ffmpeg with winget,
  mpv by downloading its official Windows build (shinchiro) into FragCut's folder, checked against its SHA-256.
  No administrator rights needed. If that download can't be unpacked (older Windows 10), it falls back to winget.
- Uninstall asks in a dialog instead of a console window.

## 1.4.1

- **Plays recordings Windows can't**: some recordings (for example AV1 from newer NVIDIA or AMD cards) failed with
  "Can't play this file: Exception from HRESULT: 0xC00D11B1", even with Microsoft's AV1 extension installed.
  FragCut now makes a playable copy (H.264, up to 1080p) and plays that. It takes a few seconds for a short clip
  and is made once per recording (the 8 newest are kept). Cuts, Find kills and joins still use the original file.

## 1.4.0

- **Kill montage (Battlefield 6)**: select recordings > *Send to > FragCut - Kill montage*. It finds the kills in each one,
  cuts 5 seconds before each kill to 1 second after, and joins them into `<first recording> - kill montage.mp4`.
  Kills close together share one clip. Recordings of different sizes (720p and 1440p) are scaled to the biggest.
- **Double kills stay whole**: when KILL turns into KILL x2 (or x3 ...), the clip now runs until after the *last* kill,
  in the montage and with `K` in FragCut. Before, it ended 1-2 s after the first kill and cut the second one off.
- Fixed: Find kills searched a recording again when results for several recordings were saved.

## 1.3.0

- **Find kills (Battlefield 6)**: press `K` in FragCut. It looks through the recording for the game's kill tags
  (KILL, HEADSHOT, KILL CONFIRMED) and marks each kill on the timeline. Then `K` jumps to the next kill and marks
  8 seconds before it to 2 seconds after, ready to save with `Enter`; `Shift+K` goes back. It runs in the background
  while you watch (a 2-minute 1440p recording takes about 11 s) and remembers the results.
  Works with 16:9 recordings at any resolution.

## 1.2.1

- **Plays nice with OBS**: while OBS is open, slices are cut gently (lighter GPU preset, paced to 1.5x real time,
  low priority) so an OBS recording of FragCut doesn't drop frames. Same size and quality; slices still join losslessly.

## 1.2.0

- **Compress**: *Send to → FragCut - Compress* makes a copy about half the size that looks nearly the same
  (H.264 on the GPU; a 1440p60 montage went from 227 MB to about half, VMAF ~93). Works on several files at once.

## 1.1.0

- **Loop the marked part**: once start and end are marked, playback loops just that part.
  `Q`/`W` move the start, `E`/`R` move the end (0.2 s, `Shift` = 1 s); `Enter` cuts and keeps watching from the end of the slice.
- **Playback speed** on `↑`/`↓`: 0.25x, 0.5x, 1x, 2x, 4x (shown next to the time). Volume moved to `+`/`-`.
- **Recordings list** on the right: click to switch; `P` / `N` for previous / next.
- **Timeline**: click anywhere to jump there; dragging pauses and mutes instead of scrambling the audio.
- Fixed: seeking (arrow keys, frame step, timeline) was rounded down to whole seconds, so ← 0.5 s could get stuck.
- Fixed: volume keys jumped straight to 0 or full.
- Fixed: exact video length (the last fraction of a second could not be reached).

## 1.0.0 — first release

- **FragCut** player: watch a recording, mark start/end with `I`/`O`, cut with `C`. Slices save in the background.
- **Join clips**: stitch slices in any order; lossless when the formats match, automatic re-encode when they don't.
- **Cut by time**: type start/end times, get an MP4 + MP3.
- Encodes on NVIDIA, AMD or Intel GPUs (auto-detected), CPU fallback.
- Remembers the last folder you opened.
- Installer adds *Send to* + Desktop shortcuts; no admin rights needed.

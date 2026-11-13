# Changelog

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

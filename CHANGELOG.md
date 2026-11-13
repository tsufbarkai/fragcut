# Changelog

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

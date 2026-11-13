# FragCut

**Cut the best moments out of your game recordings and stitch them into one video — right from the right-click menu.**

Right-click a recording → **Send to → FragCut**. Watch it, press **I** at the start of the play and **O** at the end — the marked part loops so you can fine-tune it — then **Enter** to cut and keep watching. Do it for a few clips, press **J**, and you've got a montage. No timeline, no effects, no account, nothing running in the background.

- **Mark while watching** — a small player with keyboard controls. Slices save in the background while you keep watching.
- **One-key join** — stitch slices together in the order you choose. Slices from FragCut join **instantly with no quality loss**.
- **Fast** — encodes on your graphics card (NVIDIA, AMD or Intel), falls back to the CPU.
- **Tiny** — a few PowerShell scripts plus [ffmpeg](https://ffmpeg.org). Nothing to keep running, no tray icon, no telemetry.
- Works with NVIDIA ShadowPlay / NVIDIA App, Xbox Game Bar, AMD ReLive, OBS and Steam recordings (any MP4/MKV ffmpeg can read).

> Windows 10 / 11.

## Install

1. Download `FragCut-vX.Y.Z.zip` from [Releases](https://github.com/tsufbarkai/fragcut/releases/latest) and unzip it.
2. Double-click **`Install.bat`**.
   - *"Windows protected your PC"*: click **More info → Run anyway**. FragCut isn't code-signed (certificates cost money); the scripts are plain text — read them if you like.
   - If [ffmpeg](https://ffmpeg.org) isn't installed, the installer offers to install it with `winget` (`Gyan.FFmpeg.Essentials`).
3. Right-click a recording → **Send to → FragCut**.
   On Windows 11, *Send to* is under **Show more options** (or **Shift + right-click**).

No admin rights needed. Installs to `%LOCALAPPDATA%\FragCut`.

## Use

### FragCut — watch, mark, cut

| Key | Action |
|---|---|
| `Space` | play / pause |
| `←` / `→` | back / forward 0.5 s (`Shift` = 5 s, `Ctrl` = 30 s) |
| `,` / `.` | one frame back / forward |
| `I` | mark start |
| `O` | mark end — the marked part now **loops** |
| `Q` / `W` | move the start earlier / later (0.2 s, `Shift` = 1 s) |
| `E` / `R` | move the end earlier / later (0.2 s, `Shift` = 1 s) |
| `Enter` or `C` | cut the slice and keep watching (only a start marked = cut up to the current position) |
| `Esc` | clear the marks |
| `P` / `N` | previous / next recording |
| `J` | join the slices you cut |
| `↑` / `↓` | playback speed: 0.25x · 0.5x · 1x · 2x · 4x |
| `+` / `-` | volume |

The flow: **I → O** (it loops) → tweak with **Q W E R** → **Enter**. Marking again with I/O just replaces the marks.

Click anywhere on the timeline to jump there, or drag it (the video pauses and goes silent while you drag). Opened several recordings? They're listed on the right — click one to switch.

Slices are saved next to the recording as `<recording> - clip 01m38-01m43.mp4`. Tick **Also save MP3** to get the audio too.

### Join clips

Press `J` in FragCut, or select clips → **Send to → FragCut - Join clips**. It lists them in recording order; press Enter or type a new order (`3 1 2`, leave numbers out to skip). Clips in the same format are joined losslessly in a second; mixed resolutions/frame rates are re-encoded automatically. Output: `<first recording> - montage.mp4`.

### Cut by time

Know the timestamps already? **Send to → FragCut - Cut by time**, type `1:38` and `1:43`. Saves an MP4 and an MP3.

### Compress

Montage too big to send? Select videos → **Send to → FragCut - Compress**. You get `<name> - compressed.mp4`, about half the size and hard to tell apart from the original (H.264, so it plays everywhere). The original is left alone.

## FAQ

**The video is black / won't play.** It's probably HEVC (H.265) or AV1. Install *HEVC Video Extensions* or *AV1 Video Extension* from the Microsoft Store, or record in H.264. (Cutting still works — only the preview needs the codec.)

**Which encoder is used?** The first one that works on your PC: NVIDIA NVENC → AMD AMF → Intel Quick Sync → CPU (x264). The FragCut window title shows it.

**Recording FragCut with OBS?** FragCut notices OBS is open and cuts slices gently (paced, lighter GPU preset), because both share the graphics card's video encoder. Slices take a moment longer to save; your OBS recording doesn't drop frames.

**Does it upload anything?** No. Everything runs locally with ffmpeg.

**Uninstall?** Run `Uninstall.bat` (in the zip or in `%LOCALAPPDATA%\FragCut`). Your clips stay.

## How it works

PowerShell + WPF for the player (Windows' built-in media engine), ffmpeg for cutting and joining. Slices are encoded with fixed settings (H.264 + AAC 48 kHz stereo), which is what lets the joiner use ffmpeg's concat demuxer with stream copy instead of re-encoding.

| File | What it is |
|---|---|
| `FragCut.ps1` | the player: mark & cut |
| `Join.ps1` | join clips |
| `TimeCut.ps1` | cut by typed times |
| `Compress.ps1` | smaller copy of a video (H.264, GPU-encoded) |
| `Core.ps1` | shared helpers (encoder detection, naming, ffmpeg args) |
| `Install.ps1` / `Uninstall.ps1` | add / remove the Send to + Desktop shortcuts |

## License

[MIT](LICENSE). ffmpeg is not included; it's installed separately and is licensed under the LGPL/GPL.

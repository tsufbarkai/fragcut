# FragCut - find kills in a recording by spotting the game's kill tags (KILL, HEADSHOT, ...).
# Dot-sourced by FragCut.ps1 and KillScan.ps1 (after Core.ps1).
#
# How it works: ffmpeg decodes the recording and hands over only the area where the tags appear,
# 5 times per second, shrunk to 720p size and in grayscale. Bright pixels (the white tag text) are
# compared with small pictures of the tag words in kills\<game>\*.pgm. A match = a kill on screen.

# Per game: where the tags appear (x, y, width, height in a 1280x720 frame), the brightness that
# counts as "text", and the match score (0..1) that counts as a kill.
$script:KillProfiles = @{
    bf6 = @{ Name = 'Battlefield 6'; Folder = 'bf6'; Region = @(150, 380, 550, 200); Bright = 150; MinScore = 0.70; Fps = 5 }
}
$script:KillCacheFile = Join-Path $env:LOCALAPPDATA 'FragCut\kills-cache.json'
$script:KillCacheVersion = 1      # bump when templates/settings change, so old results are not reused

# The matcher is C# (compiled on first use, ~1 s) so it is fast enough without extra software.
function Initialize-KillScanner {
if ('FragCutKills.Scanner' -as [type]) { return }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace FragCutKills {
    public class Template {
        public string Name;
        public int W, H, N;            // size, number of "text" pixels
        public ulong[] M0, M1;         // per row: bits for columns 0-63 and 64-127

        // Load a binary PGM (P5) and keep pixels >= bright as text.
        public static Template Load(string path, int bright) {
            byte[] d = File.ReadAllBytes(path);
            int pos = 0;
            string magic = Token(d, ref pos);
            if (magic != "P5") throw new Exception("not a P5 PGM: " + path);
            int w = int.Parse(Token(d, ref pos)), h = int.Parse(Token(d, ref pos)); Token(d, ref pos);
            pos++;                                          // single whitespace after maxval
            if (w > 128) throw new Exception("template wider than 128 px: " + path);
            Template t = new Template();
            t.Name = Path.GetFileNameWithoutExtension(path); t.W = w; t.H = h;
            t.M0 = new ulong[h]; t.M1 = new ulong[h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (d[pos + y * w + x] >= bright) {
                        t.N++;
                        if (x < 64) t.M0[y] |= 1UL << x; else t.M1[y] |= 1UL << (x - 64);
                    }
            return t;
        }
        static string Token(byte[] d, ref int pos) {
            while (pos < d.Length && (d[pos] == ' ' || d[pos] == '\n' || d[pos] == '\r' || d[pos] == '\t')) pos++;
            int s = pos;
            while (pos < d.Length && !(d[pos] == ' ' || d[pos] == '\n' || d[pos] == '\r' || d[pos] == '\t')) pos++;
            return Encoding.ASCII.GetString(d, s, pos - s);
        }
    }

    public class Kill {
        public double Time;            // first moment the tag was seen (s)
        public double LastSeen;
        public double Score;
        public string Tag;
    }

    public class Scanner {
        public volatile bool Done;
        public volatile string Error;
        public double Duration;        // s, for progress
        public int Frames;
        public double Seconds { get { return Frames / fps; } }
        public double Progress { get { return Duration > 0 ? Math.Min(1.0, Seconds / Duration) : 0; } }
        public List<Kill> Kills = new List<Kill>();
        public List<double> Scores;    // best score per frame (only when KeepScores is set)
        public bool KeepScores;

        readonly List<Template> tmpl;
        readonly int W, H, bright;
        readonly double fps, minScore;
        const double Gap = 1.0;        // tags seen again within 1 s belong to the same kill moment
        Process proc;
        StringBuilder err = new StringBuilder();

        // work buffers (one frame at a time)
        byte[] bin; int[] integ; ulong[] words, win0, win1; int wordsPerRow;

        public Scanner(List<Template> templates, int width, int height, int brightness, double framesPerSecond, double minimumScore) {
            tmpl = templates; W = width; H = height; bright = brightness; fps = framesPerSecond; minScore = minimumScore;
            bin = new byte[W * H]; integ = new int[(W + 1) * (H + 1)];
            wordsPerRow = W / 64 + 3; words = new ulong[wordsPerRow * H];
            win0 = new ulong[W * H]; win1 = new ulong[W * H];
        }

        public void Start(string ffmpeg, string args) {
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg, args);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            proc = Process.Start(psi);
            try { proc.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            proc.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (err) { if (err.Length < 4000) err.AppendLine(e.Data); } };
            proc.BeginErrorReadLine();
            Thread th = new Thread(Run); th.IsBackground = true; th.Start();
        }

        public void Cancel() { try { if (proc != null && !proc.HasExited) proc.Kill(); } catch { } }

        void Run() {
            try {
                Stream s = proc.StandardOutput.BaseStream;
                byte[] frame = new byte[W * H];
                while (true) {
                    int got = 0;
                    while (got < frame.Length) { int n = s.Read(frame, got, frame.Length - got); if (n <= 0) break; got += n; }
                    if (got < frame.Length) break;
                    string tag; double best = Score(frame, out tag);
                    double t = Frames / fps;
                    if (KeepScores) { if (Scores == null) Scores = new List<double>(); Scores.Add(best); }
                    if (best >= minScore) {
                        lock (Kills) {
                            Kill last = Kills.Count > 0 ? Kills[Kills.Count - 1] : null;
                            if (last == null || t - last.LastSeen > Gap) { last = new Kill(); last.Time = t; last.Tag = tag; Kills.Add(last); }
                            last.LastSeen = t;
                            if (best > last.Score) { last.Score = best; }
                        }
                    }
                    Frames++;
                }
                proc.WaitForExit();
                if (proc.ExitCode != 0 && Frames == 0) { lock (err) { Error = "ffmpeg failed: " + err.ToString().Trim(); } }
            } catch (Exception e) { Error = e.Message; }
            Done = true;
        }

        public Kill[] Snapshot() { lock (Kills) { return Kills.ToArray(); } }

        static int Pop(ulong x) {
            x = x - ((x >> 1) & 0x5555555555555555UL);
            x = (x & 0x3333333333333333UL) + ((x >> 2) & 0x3333333333333333UL);
            x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0FUL;
            return (int)((x * 0x0101010101010101UL) >> 56);
        }

        // Best match score (normalized correlation of the text pixels, 0..1) of any template anywhere in the frame.
        public double Score(byte[] frame, out string tag) {
            tag = null;
            int W1 = W + 1;
            Array.Clear(words, 0, words.Length);
            for (int y = 0; y < H; y++) {
                int rowSum = 0;
                for (int x = 0; x < W; x++) {
                    byte b = (byte)(frame[y * W + x] >= bright ? 1 : 0);
                    bin[y * W + x] = b; rowSum += b;
                    integ[(y + 1) * W1 + x + 1] = integ[y * W1 + x + 1] + rowSum;
                    if (b != 0) words[y * wordsPerRow + (x >> 6)] |= 1UL << (x & 63);
                }
            }
            // for every pixel: the 128 bits that start there (two words), so a template row is matched with 1-2 popcounts
            for (int y = 0; y < H; y++) {
                int r = y * wordsPerRow;
                for (int x = 0; x < W; x++) {
                    int k = x >> 6, sh = x & 63;
                    ulong a = words[r + k], b = words[r + k + 1], c = words[r + k + 2];
                    win0[y * W + x] = sh == 0 ? a : (a >> sh) | (b << (64 - sh));
                    win1[y * W + x] = sh == 0 ? b : (b >> sh) | (c << (64 - sh));
                }
            }
            double best = 0;
            foreach (Template t in tmpl) {
                int n = t.W * t.H;
                double varT = t.N - (double)t.N * t.N / n;
                if (varT <= 0) continue;
                bool wide = t.W > 64;
                for (int y = 0; y + t.H <= H; y++) {
                    for (int x = 0; x + t.W <= W; x++) {
                        int sumI = integ[(y + t.H) * W1 + x + t.W] - integ[y * W1 + x + t.W] - integ[(y + t.H) * W1 + x] + integ[y * W1 + x];
                        if (sumI < t.N / 2) continue;             // too few bright pixels to be this word
                        int dot = 0;
                        for (int r = 0; r < t.H; r++) {
                            int i = (y + r) * W + x;
                            dot += Pop(win0[i] & t.M0[r]);
                            if (wide) dot += Pop(win1[i] & t.M1[r]);
                        }
                        double varI = sumI - (double)sumI * sumI / n;
                        if (varI <= 0) continue;
                        double ncc = (dot - (double)sumI * t.N / n) / Math.Sqrt(varI * varT);
                        if (ncc > best) { best = ncc; tag = t.Name; }
                    }
                }
            }
            return best;
        }
    }
}
"@
}

# Start scanning a recording in the background. Returns the scanner; poll .Done / .Progress / .Snapshot().
function Start-KillScan($ffmpeg, $video, [double]$duration, [int]$width, [int]$height, [string]$game = 'bf6', [switch]$KeepScores) {
    Initialize-KillScanner
    $p = $script:KillProfiles[$game]
    if (-not $p) { throw "no kill profile for '$game'" }
    if ($width -le 0 -or $height -le 0) { throw "unknown video size" }
    if ([math]::Abs($width / $height - 16 / 9) -gt 0.02) { throw "Find kills only works with 16:9 recordings (this one is ${width}x${height})." }
    $dir = Join-Path $PSScriptRoot "kills\$($p.Folder)"
    $list = New-Object 'System.Collections.Generic.List[FragCutKills.Template]'
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter *.pgm) { $list.Add([FragCutKills.Template]::Load($f.FullName, $p.Bright)) }
    if ($list.Count -eq 0) { throw "no tag pictures found in $dir" }
    $x, $y, $w, $h = $p.Region
    # crop the same area at any 16:9 resolution, then shrink it to its 720p size
    $vf = "fps=$($p.Fps),crop=iw*$w/1280:ih*$h/720:iw*$x/1280:ih*$y/720,scale=${w}:${h}:flags=area,format=gray"
    $argv = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-i', $video, '-an', '-sn', '-dn', '-vf', $vf, '-f', 'rawvideo', '-pix_fmt', 'gray', '-')
    $sc = New-Object FragCutKills.Scanner($list, $w, $h, $p.Bright, [double]$p.Fps, [double]$p.MinScore)
    $sc.Duration = $duration
    $sc.KeepScores = [bool]$KeepScores
    $sc.Start($ffmpeg, (($argv | ForEach-Object { Quote-Arg $_ }) -join ' '))
    return $sc
}

# Remember results per recording (path + size + date), so reopening a recording doesn't scan it again.
function Get-KillCacheKey($video) {
    $f = Get-Item -LiteralPath $video
    return '{0}|{1}|{2}|v{3}' -f $f.FullName.ToLowerInvariant(), $f.Length, $f.LastWriteTimeUtc.Ticks, $script:KillCacheVersion
}
function Get-CachedKills($video) {
    try {
        $key = Get-KillCacheKey $video
        $c = Get-Content -LiteralPath $script:KillCacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $hit = $c | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($hit) { return ,@($hit.Kills | ForEach-Object { [double]$_ }) }
    } catch {}
    return $null
}
function Save-CachedKills($video, [double[]]$times) {
    try {
        $key = Get-KillCacheKey $video
        $c = @()
        try { $c = @(Get-Content -LiteralPath $script:KillCacheFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {}
        $c = @($c | Where-Object { $_.Key -ne $key -and $_.Key -like "*|v$($script:KillCacheVersion)" } | Select-Object -Last 199)
        $c += [pscustomobject]@{ Key = $key; Kills = @($times) }
        New-Item -ItemType Directory -Force (Split-Path $script:KillCacheFile) | Out-Null
        ConvertTo-Json -InputObject @($c) -Depth 4 | Set-Content -LiteralPath $script:KillCacheFile -Encoding UTF8
    } catch {}
}

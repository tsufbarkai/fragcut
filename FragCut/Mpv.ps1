# FragCut - mpv as the video player (dot-sourced by FragCut.ps1).
# mpv plays almost any recording (H.264, HEVC, AV1, VP9 ...) and decodes on the graphics card. FragCut starts mpv.exe
# inside its own window (--wid) and controls it through mpv's JSON pipe (--input-ipc-server).
# Without mpv, FragCut falls back to Windows' built-in player (and a preview copy for files it can't play).

# mpv.exe: FragCut's own copy (Install.bat downloads the official build into FragCut\mpv), else one installed
# another way: on PATH, Program Files\MPV Player (winget shinchiro.mpv), scoop, or winget's package folder
# Settings "Player": "windows" (or env FRAGCUT_PLAYER=windows) uses Windows' player even when mpv is installed.
function Find-Mpv {
    $s = Get-Settings
    if ($env:FRAGCUT_PLAYER -eq 'windows' -or $s.Player -eq 'windows') { return $null }
    if ($s.MpvPath -and (Test-Path -LiteralPath $s.MpvPath)) { return $s.MpvPath }
    # the copy the installer downloaded into FragCut's folder
    foreach ($p in (Join-Path $PSScriptRoot 'mpv\mpv.exe'), "$env:LOCALAPPDATA\FragCut\mpv\mpv.exe") { if (Test-Path -LiteralPath $p) { return $p } }
    $c = Get-Command 'mpv.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in "$env:ProgramFiles\MPV Player\mpv.exe", "$env:ProgramFiles\mpv\mpv.exe", "$env:LOCALAPPDATA\Programs\mpv\mpv.exe", "$env:USERPROFILE\scoop\apps\mpv\current\mpv.exe") {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $f = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'mpv.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

if (-not ('FragCutMpv.Player' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace FragCutMpv {
public class Player {
    Process proc; NamedPipeClientStream pipe; StreamWriter writer; Thread reader;
    readonly object wlock = new object();
    IntPtr job = IntPtr.Zero;

    // state from mpv (written by the reader thread)
    public volatile bool Ready;
    double timePos, duration;
    public double TimePos { get { return Volatile.Read(ref timePos); } }
    public double Duration { get { return Volatile.Read(ref duration); } }
    int loaded, ended, failed;          // events since the last Take...()
    public string LastError = "";
    public bool TakeLoaded() { return Interlocked.Exchange(ref loaded, 0) != 0; }
    public bool TakeEnded()  { return Interlocked.Exchange(ref ended, 0) != 0; }
    public bool TakeFailed() { return Interlocked.Exchange(ref failed, 0) != 0; }
    public bool Exited { get { try { return proc == null || proc.HasExited; } catch { return true; } } }

    public void Start(string exe, IntPtr wid) {
        string pipeName = "fragcut-mpv-" + Process.GetCurrentProcess().Id + "-" + Environment.TickCount;
        string[] opts = {
            "--wid=" + wid.ToInt64(), "--input-ipc-server=\\\\.\\pipe\\" + pipeName,
            "--no-config", "--idle=yes", "--keep-open=always", "--force-window=yes", "--pause",
            "--hwdec=auto-safe", "--hr-seek=yes", "--hr-seek-framedrop=no",
            "--osc=no", "--osd-level=0", "--input-default-bindings=no", "--input-vo-keyboard=no", "--input-cursor=no",
            "--cursor-autohide=no", "--background-color=#000000", "--audio-display=no", "--sub-auto=no",
            "--no-terminal", "--msg-level=all=no"
        };
        var psi = new ProcessStartInfo(exe, string.Join(" ", opts));
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        proc = Process.Start(psi);
        KillWithUs(proc);
        pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        var until = DateTime.Now.AddSeconds(10);
        while (true) {
            try { pipe.Connect(200); break; }
            catch (TimeoutException) { }
            catch (IOException) { Thread.Sleep(50); }
            if (proc.HasExited) throw new Exception("mpv closed right after starting (exit code " + proc.ExitCode + ")");
            if (DateTime.Now > until) throw new Exception("mpv did not answer");
        }
        writer = new StreamWriter(pipe, new UTF8Encoding(false)); writer.AutoFlush = true;
        reader = new Thread(Read); reader.IsBackground = true; reader.Start();
        Send("{\"command\":[\"observe_property\",1,\"time-pos\"]}");
        Send("{\"command\":[\"observe_property\",2,\"duration\"]}");
        Send("{\"command\":[\"observe_property\",3,\"eof-reached\"]}");
        Ready = true;
    }

    static readonly Regex evRx = new Regex("\"event\":\"([a-z-]+)\"");
    static readonly Regex propRx = new Regex("\"name\":\"([a-z-]+)\",\"data\":([^,}]+)");
    static readonly Regex errRx = new Regex("\"file_error\":\"([^\"]*)\"");
    void Read() {
        try {
            var sr = new StreamReader(pipe, new UTF8Encoding(false));
            string line;
            while ((line = sr.ReadLine()) != null) {
                var e = evRx.Match(line);
                if (!e.Success) continue;
                switch (e.Groups[1].Value) {
                    case "property-change":
                        var p = propRx.Match(line);
                        if (!p.Success) break;
                        string name = p.Groups[1].Value, data = p.Groups[2].Value;
                        double d;
                        if (name == "time-pos" && double.TryParse(data, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) Volatile.Write(ref timePos, d);
                        else if (name == "duration" && double.TryParse(data, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) Volatile.Write(ref duration, d);
                        else if (name == "eof-reached" && data == "true") Interlocked.Exchange(ref ended, 1);
                        break;
                    case "file-loaded": Interlocked.Exchange(ref loaded, 1); break;
                    case "end-file":
                        if (line.Contains("\"reason\":\"error\"")) {
                            var m = errRx.Match(line); LastError = m.Success ? m.Groups[1].Value : "unknown error";
                            Interlocked.Exchange(ref failed, 1);
                        }
                        break;
                }
            }
        } catch { }
    }

    void Send(string json) {
        lock (wlock) { try { writer.WriteLine(json); } catch { } }
    }
    static string Q(string s) {
        var b = new StringBuilder("\"");
        foreach (char c in s) {
            if (c == '\\' || c == '"') b.Append('\\').Append(c);
            else if (c < 32) b.AppendFormat("\\u{0:x4}", (int)c);
            else b.Append(c);
        }
        return b.Append('"').ToString();
    }
    static string N(double x) { return x.ToString("0.######", CultureInfo.InvariantCulture); }

    public void Load(string path) {
        Volatile.Write(ref timePos, 0); Volatile.Write(ref duration, 0);
        Interlocked.Exchange(ref loaded, 0); Interlocked.Exchange(ref ended, 0); Interlocked.Exchange(ref failed, 0);
        Send("{\"command\":[\"loadfile\"," + Q(path) + "]}");
    }
    public void SetPause(bool p) { Send("{\"command\":[\"set_property\",\"pause\"," + (p ? "true" : "false") + "]}"); }
    // exact = the very frame (slower); otherwise the nearest keyframe (for dragging the timeline)
    public void Seek(double s, bool exact) {
        Volatile.Write(ref timePos, s);
        Send("{\"command\":[\"seek\"," + N(s) + ",\"absolute+" + (exact ? "exact" : "keyframes") + "\"]}");
    }
    public void SetSpeed(double x) { Send("{\"command\":[\"set_property\",\"speed\"," + N(x) + "]}"); }
    public void SetVolume(double v01) { Send("{\"command\":[\"set_property\",\"volume\"," + N(v01 * 100) + "]}"); }
    public void SetMute(bool m) { Send("{\"command\":[\"set_property\",\"mute\"," + (m ? "true" : "false") + "]}"); }
    public void Stop() { Send("{\"command\":[\"stop\"]}"); }
    public void Quit() {
        Send("{\"command\":[\"quit\"]}");
        try { if (!proc.WaitForExit(1500)) proc.Kill(); } catch { }
        try { pipe.Dispose(); } catch { }
    }

    // mpv closes with FragCut even if FragCut crashes (job object with "kill on close")
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    void KillWithUs(Process p) {
        try {
            job = CreateJobObject(IntPtr.Zero, null);
            int size = IntPtr.Size == 8 ? 144 : 112;              // JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            IntPtr info = Marshal.AllocHGlobal(size);
            for (int i = 0; i < size; i++) Marshal.WriteByte(info, i, 0);
            Marshal.WriteInt32(info, 16, 0x2000);                   // LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            SetInformationJobObject(job, 9, info, (uint)size);
            Marshal.FreeHGlobal(info);
            AssignProcessToJobObject(job, p.Handle);
        } catch { }
    }
}
}
'@
}

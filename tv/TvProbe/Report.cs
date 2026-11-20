using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace TvProbe
{
    static class Report
    {
        // Libraries whose loadability tells us which capture paths this TV exposes.
        static readonly string[] Libraries =
        {
            "libvideoenhance.so",
            "libcapi-video-capture.so", "libcapi-video-capture.so.0", "libcapi-video-capture.so.1",
            "libcapi-screen.so.0", "libcapi-screen.so",
            "libcapi-mde-framework-tv.so",
            "libcapi-media-camera.so.0",
        };

        // Symbols to look up in every library that loads (names seen in Hue Sync / ambilight
        // and plausible capture entry points).
        static readonly string[] Symbols =
        {
            "ppi_ve_get_rgb_measure_condition", "ve_get_rgb_measure_condition", "cs_ve_get_rgb_measure_condition",
            "video_capture_create", "video_capture_destroy", "video_capture_start", "video_capture_get_frame",
            "video_capture_capture", "video_capture_get_image", "capture_video", "screen_capture",
            "screen_capture_get_image", "screen_get_image",
        };

        public static string Build()
        {
            var sb = new StringBuilder();
            sb.AppendLine("== TV Probe report " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            Try(sb, "model", () => Info("http://tizen.org/system/model_name"));
            Try(sb, "platform version", () => Info("http://tizen.org/feature/platform.version"));
            Try(sb, "build string", () => Info("http://tizen.org/system/build.string"));
            Try(sb, "tizen id", () => Info("http://tizen.org/system/tizenid"));
            Try(sb, "dotnet", () => Environment.Version + " " + RuntimeInformation.FrameworkDescription);
            Try(sb, "arch", () => RuntimeInformation.ProcessArchitecture + " / os " + RuntimeInformation.OSArchitecture);
            Try(sb, "pid", () => Process.GetCurrentProcess().Id.ToString());
            Try(sb, "uid/gid", () => Grep("/proc/self/status", "Uid:") + " | " + Grep("/proc/self/status", "Gid:") + " | " + Grep("/proc/self/status", "Groups:"));
            Try(sb, "smack label", () => File.ReadAllText("/proc/self/attr/current").Trim('\0', '\n'));
            Try(sb, "kernel", () => File.ReadAllText("/proc/version").Trim());
            Try(sb, "os-release", () => File.Exists("/etc/os-release") ? File.ReadAllText("/etc/os-release").Replace('\n', ' ') : "-");
            Try(sb, "tizen-release", () => File.Exists("/etc/tizen-release") ? File.ReadAllText("/etc/tizen-release").Replace('\n', ' ') : "-");
            Try(sb, "cpu", () => Grep("/proc/cpuinfo", "Hardware") + " " + Grep("/proc/cpuinfo", "model name"));

            sb.AppendLine();
            sb.AppendLine("== Native libraries (dlopen RTLD_NOW)");
            foreach (var lib in Libraries)
            {
                IntPtr h = Native.DlOpen(lib, out string err);
                if (h == IntPtr.Zero) { sb.AppendLine($"  {lib}: FAIL {err}"); continue; }
                sb.AppendLine($"  {lib}: OK");
                foreach (var s in Symbols)
                    if (Native.TryGetExport(h, s, out IntPtr p)) sb.AppendLine($"      {s} @0x{p.ToInt64():x}");
            }

            sb.AppendLine();
            sb.AppendLine("== Managed TV assemblies");
            try
            {
                foreach (var f in Directory.GetFiles("/usr/share/dotnet.tizen/framework", "*.dll"))
                {
                    var n = Path.GetFileName(f);
                    if (n.StartsWith("Tizen.TV", StringComparison.OrdinalIgnoreCase) || n.IndexOf("Samsung", StringComparison.OrdinalIgnoreCase) >= 0)
                        sb.AppendLine($"  {n} {new FileInfo(f).Length}");
                }
            }
            catch (Exception ex) { sb.AppendLine("  error: " + ex.Message); }

            sb.AppendLine();
            sb.AppendLine("== Candidate files");
            foreach (var f in Routes.Candidates())
            {
                string readable;
                try { using (File.OpenRead(f)) { } readable = "readable"; }
                catch (Exception ex) { readable = "NOT readable: " + ex.GetType().Name; }
                long len = -1;
                try { len = new FileInfo(f).Length; } catch { }
                sb.AppendLine($"  {f} {len} {readable}");
            }

            sb.AppendLine();
            sb.AppendLine("== /dev/video*");
            try
            {
                foreach (var d in Directory.GetFiles("/dev", "video*"))
                {
                    string acc;
                    try { using (new FileStream(d, FileMode.Open, FileAccess.Read)) { } acc = "openable"; }
                    catch (Exception ex) { acc = ex.GetType().Name; }
                    sb.AppendLine($"  {d} {acc}");
                }
            }
            catch (Exception ex) { sb.AppendLine("  error: " + ex.Message); }

            sb.AppendLine();
            sb.AppendLine("== Log");
            sb.AppendLine(Log.Text());
            return sb.ToString();
        }

        static string Info(string key)
        {
            return Tizen.System.Information.TryGetValue(key, out string v) ? v : "(n/a)";
        }

        static string Grep(string file, string prefix)
        {
            foreach (var line in File.ReadAllLines(file))
                if (line.StartsWith(prefix)) return line.Trim();
            return "";
        }

        static void Try(StringBuilder sb, string label, Func<string> f)
        {
            try { sb.AppendLine($"{label}: {f()}"); }
            catch (Exception ex) { sb.AppendLine($"{label}: error {ex.GetType().Name} {ex.Message}"); }
        }
    }
}

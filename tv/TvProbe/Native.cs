using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace TvProbe
{
    // Minimal native REPL: dlopen/dlsym, call a function with up to 8 integer/pointer
    // arguments, allocate/read/write memory, and hand out a logging callback pointer.
    // On ARM (AAPCS) and AArch64 every int/pointer argument is one register/stack slot and
    // the caller cleans the stack, so one 8-argument signature can call any function that
    // takes up to 8 int/pointer arguments.
    static class Native
    {
        [DllImport("libdl.so.2")] static extern IntPtr dlopen(string filename, int flags);
        [DllImport("libdl.so.2")] static extern IntPtr dlerror();
        [DllImport("libdl.so.2")] static extern IntPtr dlsym(IntPtr handle, string symbol);

        public static bool TryGetExport(IntPtr lib, string name, out IntPtr address)
        {
            address = dlsym(lib, name);
            return address != IntPtr.Zero;
        }
        const int RTLD_NOW = 2, RTLD_LAZY = 1;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        delegate IntPtr Fn8(IntPtr a, IntPtr b, IntPtr c, IntPtr d, IntPtr e, IntPtr f, IntPtr g, IntPtr h);

        static readonly Dictionary<int, IntPtr> _libs = new Dictionary<int, IntPtr>();
        static int _nextLib = 1;

        public static IntPtr DlOpen(string lib, out string error)
        {
            error = null;
            dlerror();
            IntPtr h = dlopen(lib, RTLD_NOW);
            if (h != IntPtr.Zero) return h;
            string e1 = Marshal.PtrToStringAnsi(dlerror());
            dlerror();
            IntPtr lazy = dlopen(lib, RTLD_LAZY);
            if (lazy != IntPtr.Zero)
            {
                error = $"RTLD_NOW failed ({e1}) but RTLD_LAZY loaded it";
                return IntPtr.Zero;
            }
            error = e1 ?? "unknown";
            return IntPtr.Zero;
        }

        public static string Open(string lib)
        {
            dlerror();
            IntPtr h = dlopen(lib, RTLD_NOW);
            string mode = "now";
            if (h == IntPtr.Zero) { h = dlopen(lib, RTLD_LAZY); mode = "lazy"; }
            if (h == IntPtr.Zero) return "FAIL " + Marshal.PtrToStringAnsi(dlerror());
            lock (_libs) { _libs[_nextLib] = h; return $"lib {_nextLib++} = 0x{h.ToInt64():x} ({mode})"; }
        }

        public static string Sym(string lib, string name)
        {
            IntPtr h;
            lock (_libs) h = _libs[int.Parse(lib)];
            return TryGetExport(h, name, out IntPtr p) ? $"0x{p.ToInt64():x}" : "not found";
        }

        // Arguments: decimal, 0x hex, "s:text" (allocated C string), "cb" (the logging callback).
        public static string Call(string fn, List<string> args)
        {
            if (args.Count > 8) return "at most 8 arguments";
            var a = new IntPtr[8];
            var temp = new List<IntPtr>();
            for (int i = 0; i < args.Count; i++) a[i] = ParseArg(args[i], temp);
            var f = Marshal.GetDelegateForFunctionPointer<Fn8>(ParsePtr(fn));
            Log.Add($"ncall {fn}({string.Join(",", args)})");
            IntPtr r = f(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
            return $"ret = {r.ToInt64()} (0x{r.ToInt64():x})";
        }

        static IntPtr ParseArg(string s, List<IntPtr> temp)
        {
            if (s.StartsWith("s:"))
            {
                var p = Marshal.StringToHGlobalAnsi(s.Substring(2));
                temp.Add(p);   // leaked on purpose: the callee may keep the pointer
                return p;
            }
            if (s == "cb") return CallbackPtr;
            return ParsePtr(s);
        }

        public static IntPtr ParsePtr(string s)
        {
            s = s.Trim();
            bool neg = s.StartsWith("-");
            if (neg) s = s.Substring(1);
            long v = s.StartsWith("0x") ? long.Parse(s.Substring(2), NumberStyles.HexNumber) : long.Parse(s);
            if (neg) v = -v;
            return IntPtr.Size == 4 ? new IntPtr(unchecked((int)v)) : new IntPtr(v);
        }

        public static string Alloc(int size)
        {
            IntPtr p = Marshal.AllocHGlobal(size);
            var zero = new byte[size];
            Marshal.Copy(zero, 0, p, size);
            return $"0x{p.ToInt64():x}";
        }

        public static Response Read(string addr, int len, string fmt)
        {
            var buf = new byte[len];
            Marshal.Copy(ParsePtr(addr), buf, 0, len);
            if (fmt == "raw") return Response.Bytes(buf, "mem.bin");
            if (fmt == "str") return Response.Text(Encoding.UTF8.GetString(buf).Split('\0')[0]);
            return Response.Text(HexDump(buf, ParsePtr(addr).ToInt64()));
        }

        public static string Write(string addr, string hex)
        {
            hex = hex.Replace(" ", "");
            var b = new byte[hex.Length / 2];
            for (int i = 0; i < b.Length; i++) b[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber);
            Marshal.Copy(b, 0, ParsePtr(addr), b.Length);
            return $"wrote {b.Length} bytes";
        }

        public static string HexDump(byte[] buf, long baseAddr)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < buf.Length; i += 16)
            {
                sb.Append((baseAddr + i).ToString("x8")).Append("  ");
                for (int j = 0; j < 16; j++) sb.Append(i + j < buf.Length ? buf[i + j].ToString("x2") + " " : "   ");
                sb.Append(" ");
                for (int j = 0; j < 16 && i + j < buf.Length; j++)
                {
                    byte c = buf[i + j];
                    sb.Append(c >= 32 && c < 127 ? (char)c : '.');
                }
                sb.AppendLine();
            }
            return sb.ToString();
        }

        #region Logging callback

        // One callback pointer that logs its first 8 arguments; "snap" specs ("argIndex:len")
        // copy that many bytes from the pointer in that argument at call time.
        static readonly Fn8 _callback = OnCallback;
        static readonly IntPtr CallbackPtr = Marshal.GetFunctionPointerForDelegate(_callback);
        static List<(int arg, int len)> _snaps = new List<(int, int)>();
        static readonly List<string> _cbLog = new List<string>();
        static int _cbCount;

        public static string Callback(List<string> snaps)
        {
            var list = new List<(int, int)>();
            foreach (var s in snaps)
            {
                var p = s.Split(':');
                list.Add((int.Parse(p[0]), int.Parse(p[1])));
            }
            _snaps = list;
            return $"callback = 0x{CallbackPtr.ToInt64():x} (pass \"cb\" as an argument); snaps={snaps.Count}";
        }

        static IntPtr OnCallback(IntPtr a, IntPtr b, IntPtr c, IntPtr d, IntPtr e, IntPtr f, IntPtr g, IntPtr h)
        {
            try
            {
                var args = new[] { a, b, c, d, e, f, g, h };
                var sb = new StringBuilder();
                int n = System.Threading.Interlocked.Increment(ref _cbCount);
                sb.Append($"#{n} {DateTime.Now:HH:mm:ss.fff} args:");
                foreach (var x in args) sb.Append($" 0x{x.ToInt64():x}");
                foreach (var (arg, len) in _snaps)
                {
                    if (args[arg] == IntPtr.Zero) continue;
                    var buf = new byte[len];
                    Marshal.Copy(args[arg], buf, 0, len);
                    sb.AppendLine().Append($"  snap arg{arg}:").AppendLine().Append(HexDump(buf, args[arg].ToInt64()));
                }
                lock (_cbLog)
                {
                    _cbLog.Add(sb.ToString());
                    if (_cbLog.Count > 50) _cbLog.RemoveAt(0);
                }
            }
            catch (Exception ex) { Log.Add("callback: " + ex.Message); }
            return IntPtr.Zero;
        }

        public static string CallbackLog()
        {
            lock (_cbLog) return $"calls: {_cbCount}\n" + string.Join("\n", _cbLog);
        }

        #endregion
    }
}

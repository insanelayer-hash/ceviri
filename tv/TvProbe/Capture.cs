using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace TvProbe
{
    // Full-frame video capture through libcapi-video-capture.so (the same call Samsung's
    // ContentAnalysis SW_CAPTURE path makes). The frame comes back as YUV420 (NV12: Y plane +
    // interleaved UV plane) at the requested size.
    static class Capture
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Param
        {
            public uint uYSize;
            public uint uCSize;
            public int ret_width;
            public int ret_height;
            public IntPtr pYAddr;
            public IntPtr pCAddr;
            public int no_lock_no_copy;
            public int color_format;
            public uint protected_on;
            public int capt_3dmod;
            public uint ret_interlaced;
            public uint ret_y_pitch;
            public uint ret_c_pitch;
            public uint pad0;
            public ulong timestamp_nsec;
            public uint do_auto_correct_flip;
            public int flip_type;
            public int ret_rotation;
            public int no_cache_requst_capture;
            public uint is_cache;
            public uint pad1, pad2, pad3, pad4, pad5;   // the native struct is larger than ContentAnalysis' 88 bytes
        }

        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_video_main(int w, int h, ref Param p);
        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_screen(int w, int h, ref Param p);
        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_screen_video_only(int w, int h, ref Param p);
        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_is_protect(out int isProtect);
        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_lock(int lockType, int rsc);
        [DllImport("libcapi-video-capture.so")] static extern int secvideo_api_capture_unlock(int lockType, int rsc);

        static readonly object _lock = new object();
        static byte[] _lastY, _lastC;
        static int _lastW, _lastH;
        static IntPtr _y, _c;
        static int _cap;

        public static string Grab(string mode, int w, int h, bool useLock)
        {
            lock (_lock)
            {
                var sb = new StringBuilder();
                int need = w * h;
                if (_cap < need)
                {
                    if (_y != IntPtr.Zero) { Marshal.FreeHGlobal(_y); Marshal.FreeHGlobal(_c); }
                    _y = Marshal.AllocHGlobal(need);
                    _c = Marshal.AllocHGlobal(need);
                    _cap = need;
                }
                try
                {
                    int r0 = secvideo_api_capture_is_protect(out int prot);
                    sb.AppendLine($"is_protect ret={r0} value={prot}");
                }
                catch (Exception ex) { sb.AppendLine("is_protect: " + ex.Message); }

                var p = new Param { uYSize = (uint)need, uCSize = (uint)(need / 2), pYAddr = _y, pCAddr = _c };
                if (useLock) sb.AppendLine("lock ret=" + secvideo_api_capture_lock(0, 0));
                var sw = System.Diagnostics.Stopwatch.StartNew();
                int ret;
                switch (mode)
                {
                    case "screen": ret = secvideo_api_capture_screen(w, h, ref p); break;
                    case "video_only": ret = secvideo_api_capture_screen_video_only(w, h, ref p); break;
                    default: ret = secvideo_api_capture_video_main(w, h, ref p); break;
                }
                sw.Stop();
                if (useLock) sb.AppendLine("unlock ret=" + secvideo_api_capture_unlock(0, 0));
                sb.AppendLine($"{mode} ret={ret} time={sw.ElapsedMilliseconds}ms");
                sb.AppendLine($"ret_size={p.ret_width}x{p.ret_height} protected={p.protected_on} format={p.color_format} interlaced={p.ret_interlaced} pitch={p.ret_y_pitch}/{p.ret_c_pitch} rot={p.ret_rotation} cache={p.is_cache} ts={p.timestamp_nsec}");
                if (ret == 0)
                {
                    int ow = p.ret_width > 0 ? p.ret_width : w, oh = p.ret_height > 0 ? p.ret_height : h;
                    int pitch = p.ret_y_pitch > 0 ? (int)p.ret_y_pitch : ow;
                    var y = new byte[ow * oh];
                    var c = new byte[ow * oh / 2];
                    for (int row = 0; row < oh; row++) Marshal.Copy(_y + row * pitch, y, row * ow, ow);
                    int cpitch = p.ret_c_pitch > 0 ? (int)p.ret_c_pitch : ow;
                    for (int row = 0; row < oh / 2; row++) Marshal.Copy(_c + row * cpitch, c, row * ow, ow);
                    _lastY = y; _lastC = c; _lastW = ow; _lastH = oh;
                    long sum = 0; foreach (var b in y) sum += b;
                    sb.AppendLine($"Y mean={(double)sum / y.Length:F1} -> /frame.bmp");
                }
                Log.Add(sb.ToString().Replace('\n', ' '));
                return sb.ToString();
            }
        }

        // Main video frame, luma only. Returns the API's result code (0 ok, -4 copy
        // protection, -3 no source...).
        public static int GrabLuma(int w, int h, out byte[] luma, out int ow, out int oh)
        {
            luma = null;
            return GrabLumaInto(w, h, ref luma, out ow, out oh);
        }

        // Same, into a buffer the caller keeps between frames (the subtitle loop runs many
        // times a second; a fresh half-megabyte array per frame would keep the GC busy).
        public static int GrabLumaInto(int w, int h, ref byte[] luma, out int ow, out int oh)
        {
            byte[] none = null;
            return GrabFrameInto(w, h, ref luma, ref none, false, out ow, out oh);
        }

        // Luma and, when wanted, the colour plane too (NV12: one interleaved U,V pair per
        // 2x2 pixels, so `chroma` is ow bytes wide and oh/2 rows high).
        public static int GrabFrameInto(int w, int h, ref byte[] luma, ref byte[] chroma, bool wantChroma, out int ow, out int oh)
        {
            lock (_lock)
            {
                ow = oh = 0;
                int need = w * h;
                if (_cap < need)
                {
                    if (_y != IntPtr.Zero) { Marshal.FreeHGlobal(_y); Marshal.FreeHGlobal(_c); }
                    _y = Marshal.AllocHGlobal(need);
                    _c = Marshal.AllocHGlobal(need);
                    _cap = need;
                }
                var p = new Param { uYSize = (uint)need, uCSize = (uint)(need / 2), pYAddr = _y, pCAddr = _c };
                int ret = secvideo_api_capture_video_main(w, h, ref p);
                if (ret != 0) return ret;
                ow = p.ret_width > 0 ? p.ret_width : w;
                oh = p.ret_height > 0 ? p.ret_height : h;
                if (ow > w) ow = w;
                if (oh > h) oh = h;
                int pitch = p.ret_y_pitch > 0 ? (int)p.ret_y_pitch : ow;
                if (luma == null || luma.Length != ow * oh) luma = new byte[ow * oh];
                if (pitch == ow) Marshal.Copy(_y, luma, 0, ow * oh);
                else for (int row = 0; row < oh; row++) Marshal.Copy(_y + row * pitch, luma, row * ow, ow);
                if (wantChroma)
                {
                    int cp = p.ret_c_pitch > 0 ? (int)p.ret_c_pitch : pitch, ch = oh / 2;
                    if (chroma == null || chroma.Length != ow * ch) chroma = new byte[ow * ch];
                    for (int row = 0; row < ch; row++) Marshal.Copy(_c + row * cp, chroma, row * ow, ow);
                }
                return 0;
            }
        }

        // Last frame as a 24-bit BMP (NV12 -> RGB), viewable in any browser.
        public static Response Bmp()
        {
            byte[] Y, C; int W, H;
            lock (_lock) { Y = _lastY; C = _lastC; W = _lastW; H = _lastH; }
            if (Y == null) return Response.Text("no frame yet: call /capture first", 404);
            int rowBytes = (W * 3 + 3) & ~3;
            int size = 54 + rowBytes * H;
            var bmp = new byte[size];
            void I32(int o, int v) { bmp[o] = (byte)v; bmp[o + 1] = (byte)(v >> 8); bmp[o + 2] = (byte)(v >> 16); bmp[o + 3] = (byte)(v >> 24); }
            bmp[0] = (byte)'B'; bmp[1] = (byte)'M'; I32(2, size); I32(10, 54); I32(14, 40); I32(18, W); I32(22, H);
            bmp[26] = 1; bmp[28] = 24; I32(34, rowBytes * H);
            for (int j = 0; j < H; j++)
            {
                int dst = 54 + (H - 1 - j) * rowBytes;
                for (int i = 0; i < W; i++)
                {
                    int yy = Y[j * W + i];
                    int ci = (j >> 1) * W + (i & ~1);
                    int u = C[ci] - 128, v = C[ci + 1] - 128;
                    int r = yy + (1436 * v >> 10), g = yy - ((352 * u + 731 * v) >> 10), b = yy + (1815 * u >> 10);
                    bmp[dst++] = Clamp(b); bmp[dst++] = Clamp(g); bmp[dst++] = Clamp(r);
                }
            }
            return new Response { ContentType = "image/bmp", Body = bmp };
        }

        static byte Clamp(int v) => (byte)(v < 0 ? 0 : v > 255 ? 255 : v);
    }
}

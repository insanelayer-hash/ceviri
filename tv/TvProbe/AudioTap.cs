using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TvProbe
{
    // The TV's own audio capture (libaudio-capture, the sound sibling of the video capture we
    // use for subtitles). start(device) then getPCM() hands back blocks of the sound the TV is
    // playing. Experiment: measure what arrives.
    static class AudioTap
    {
        const string LIB = "libaudio-capture.so.0";
        [DllImport(LIB)] static extern int ppi_audio_capture_start(int dev);
        [DllImport(LIB)] static extern int ppi_audio_capture_stop();
        [DllImport(LIB)] static extern int ppi_audio_capture_getPCM(IntPtr data);

        static readonly object _lock = new object();

        // ---- A running copy of the last seconds of sound, for the phone ----------------------
        // The phone asks for the sound around the moment a subtitle line appeared, to hear how
        // the character said it (loud or soft, fast or slow). Kept as 16 kHz mono (left+right),
        // which keeps centre-panned dialogue and is small enough to send quickly.
        public const int RingRate = 16000;
        // Split: the overlay plays our Turkish voice on the right channel only and the copy for the
        // phone keeps the left channel only, so the phone never hears our own voice: it can go on
        // listening to the game (and to who is speaking) while a Turkish line is playing.
        // Centre-panned game dialogue is in both channels, so nothing of it is lost.
        public static volatile bool Split = true;
        static readonly short[] _ring = new short[RingRate * 12];
        static long _ringWritten;          // samples written so far
        static long _ringEndTicks;         // clock time of the newest sample
        static long _ringWantedTicks;      // last time somebody asked for sound
        static long _ringEpoch;            // when this copy was started (tells callers about restarts)
        static Thread _ringThread;
        static readonly object _ringLock = new object();

        static void RingLoop()
        {
            IntPtr p = Marshal.AllocHGlobal(64);
            Marshal.Copy(new byte[64], 0, p, 64);
            bool started = false;
            try
            {
                lock (_lock)
                {
                    started = ppi_audio_capture_start(0) == 0;
                    if (!started) { Log.Add("sound copy: capture did not start"); return; }
                    var block = new byte[1 << 16];
                    // Runs while the phone keeps asking (20 s after the last request it stops).
                    while (DateTime.UtcNow.Ticks - Interlocked.Read(ref _ringWantedTicks) < 120 * TimeSpan.TicksPerSecond)
                    {
                        if (ppi_audio_capture_getPCM(p) != 0) { Thread.Sleep(10); continue; }
                        IntPtr buf = Marshal.ReadIntPtr(p, 16);
                        int size = Marshal.ReadInt32(p, 20);
                        if (buf == IntPtr.Zero || size <= 0 || size > block.Length) continue;
                        Marshal.Copy(buf, block, 0, size);
                        long now = DateTime.UtcNow.Ticks;
                        int frames = size / 4;      // 48 kHz, 16 bit, two channels
                        lock (_ringLock)
                        {
                            for (int i = 0; i + 2 < frames; i += 3)
                            {
                                int sum = 0;
                                bool split = Split;
                                for (int k = 0; k < 3; k++)
                                {
                                    int o = (i + k) * 4;
                                    int left = (short)(block[o] | block[o + 1] << 8), right = (short)(block[o + 2] | block[o + 3] << 8);
                                    sum += split ? 2 * left : left + right;
                                }
                                _ring[_ringWritten % _ring.Length] = (short)(sum / 6);
                                _ringWritten++;
                            }
                            _ringEndTicks = now;
                            Monitor.PulseAll(_ringLock);
                        }
                    }
                }
            }
            catch (Exception ex) { Log.Add("sound copy: " + ex.Message); }
            finally
            {
                if (started) ppi_audio_capture_stop();
                Marshal.FreeHGlobal(p);
                lock (_ringLock) { _ringThread = null; _ringEndTicks = 0; Monitor.PulseAll(_ringLock); }
            }
        }

        // Continuous listening: the sound after sample number `from` (of the copy started at
        // `epoch`), at most two seconds of it, waiting until at least 0.2 s is there. When the
        // caller is out of step (first call, or the copy was restarted) it starts half a second
        // back. first/next are the sample numbers of the returned span; times are its clock times.
        public static byte[] Since(long epoch, long from, int waitMs, out long nowEpoch, out long first, out long next,
                                   out long fromTicks, out long toTicks)
        {
            Interlocked.Exchange(ref _ringWantedTicks, DateTime.UtcNow.Ticks);
            nowEpoch = 0; first = next = 0; fromTicks = toTicks = 0;
            lock (_ringLock)
            {
                if (_ringThread == null)
                {
                    _ringWritten = 0;
                    _ringEpoch = DateTime.UtcNow.Ticks;
                    _ringThread = new Thread(RingLoop) { IsBackground = true, Name = "sound-copy" };
                    _ringThread.Start();
                }
                nowEpoch = _ringEpoch;
                if (epoch != _ringEpoch || from > _ringWritten || _ringWritten - from > _ring.Length - RingRate)
                    from = Math.Max(0, _ringWritten - RingRate / 2);
                long deadline = DateTime.UtcNow.Ticks + waitMs * TimeSpan.TicksPerMillisecond;
                while (_ringThread != null && _ringWritten - from < RingRate / 5 && DateTime.UtcNow.Ticks < deadline)
                    Monitor.Wait(_ringLock, 50);
                int count = (int)Math.Min(_ringWritten - from, RingRate * 2);
                first = from; next = from + count;
                if (count <= 0) return new byte[0];
                var bytes = new byte[count * 2];
                for (int i = 0; i < count; i++)
                {
                    short v = _ring[(from + i) % _ring.Length];
                    bytes[i * 2] = (byte)v; bytes[i * 2 + 1] = (byte)(v >> 8);
                }
                toTicks = _ringEndTicks - (_ringWritten - next) * TimeSpan.TicksPerSecond / RingRate;
                fromTicks = toTicks - (long)count * TimeSpan.TicksPerSecond / RingRate;
                return bytes;
            }
        }

        // The sound from `beforeMs` before to `afterMs` after a moment (clock ticks), as 16-bit
        // mono samples at RingRate. Waits for the end of the span to arrive. Null when the copy
        // was not running at that moment (the first request only starts it).
        // Keeps the copy running while subtitle lines keep coming, once the phone has asked for
        // sound at all: the copy must already be running when a line appears, or the start of
        // what the character says is missing and the phone cannot tell whose voice it is.
        static long _askedTicks;
        public static void Touch()
        {
            long now = DateTime.UtcNow.Ticks;
            if (now - Interlocked.Read(ref _askedTicks) > 30 * TimeSpan.TicksPerMinute) return;
            Interlocked.Exchange(ref _ringWantedTicks, now);
            lock (_ringLock) StartRing();
        }

        // The computer that speaks the lines is connected: keep the copy running for it.
        public static void Wanted()
        {
            long now = DateTime.UtcNow.Ticks;
            Interlocked.Exchange(ref _ringWantedTicks, now);
            Interlocked.Exchange(ref _askedTicks, now);
            lock (_ringLock) StartRing();
        }

        static void StartRing()
        {
            if (_ringThread != null) return;
            _ringWritten = 0;
            _ringEpoch = DateTime.UtcNow.Ticks;
            _ringThread = new Thread(RingLoop) { IsBackground = true, Name = "sound-copy" };
            _ringThread.Start();
        }

        public static byte[] Around(long ticks, int beforeMs, int afterMs, int waitMs)
        {
            Interlocked.Exchange(ref _ringWantedTicks, DateTime.UtcNow.Ticks);
            Interlocked.Exchange(ref _askedTicks, DateTime.UtcNow.Ticks);
            lock (_ringLock)
            {
                StartRing();
                long endWanted = ticks + afterMs * TimeSpan.TicksPerMillisecond;
                long deadline = DateTime.UtcNow.Ticks + waitMs * TimeSpan.TicksPerMillisecond;
                while (_ringThread != null && _ringEndTicks < endWanted && DateTime.UtcNow.Ticks < deadline)
                    Monitor.Wait(_ringLock, 50);
                if (_ringEndTicks < endWanted) return null;
                // Sample index of a clock time, counted back from the newest sample.
                long last = _ringWritten - (_ringEndTicks - endWanted) * RingRate / TimeSpan.TicksPerSecond;
                int count = (beforeMs + afterMs) * RingRate / 1000;
                long first = last - count;
                // The copy started only a moment ago: what there is, if it is at least half a second.
                if (first < 0) { count += (int)first; first = 0; }
                if (count < RingRate / 2 || _ringWritten - first > _ring.Length) return null;
                var bytes = new byte[count * 2];
                for (int i = 0; i < count; i++)
                {
                    short v = _ring[(first + i) % _ring.Length];
                    bytes[i * 2] = (byte)v; bytes[i * 2 + 1] = (byte)(v >> 8);
                }
                return bytes;
            }
        }

        public static string Measure(int dev, int ms, double toneHz)
        {
            var sb = new StringBuilder();
            lock (_ringLock) if (_ringThread != null) return "  busy: the sound copy for the phone is running\n";
            lock (_lock)
            {
                IntPtr p = Marshal.AllocHGlobal(64);
                Marshal.Copy(new byte[64], 0, p, 64);
                var chunks = new List<byte[]>();
                var stamps = new List<long>();
                var gaps = new List<long>();
                int fails = 0;
                string head = "";
                try
                {
                    int ret = ppi_audio_capture_start(dev);
                    sb.AppendLine($"  start(device {dev}) = {ret}");
                    if (ret != 0) return sb.ToString();
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    long last = 0;
                    while (sw.ElapsedMilliseconds < ms)
                    {
                        ret = ppi_audio_capture_getPCM(p);
                        if (ret != 0) { fails++; Thread.Sleep(10); continue; }
                        IntPtr buf = Marshal.ReadIntPtr(p, 16);
                        int size = Marshal.ReadInt32(p, 20);
                        if (buf == IntPtr.Zero || size <= 0 || size > (1 << 20)) { fails++; continue; }
                        var b = new byte[size];
                        Marshal.Copy(buf, b, 0, size);
                        chunks.Add(b);
                        stamps.Add(Marshal.ReadInt64(p, 24));
                        gaps.Add(sw.ElapsedMilliseconds - last);
                        last = sw.ElapsedMilliseconds;
                        if (head.Length == 0)
                        {
                            var h = new byte[32];
                            Marshal.Copy(p, h, 0, 32);
                            foreach (var x in h) head += x.ToString("x2");
                        }
                    }
                    sb.AppendLine($"  stop = {ppi_audio_capture_stop()}");
                }
                finally { Marshal.FreeHGlobal(p); }

                int total = 0;
                foreach (var c in chunks) total += c.Length;
                sb.AppendLine($"  {chunks.Count} blocks, {total} bytes in {ms} ms ({(ms > 0 ? total * 1000L / ms : 0)} bytes/s), {fails} empty reads");
                if (chunks.Count == 0) return sb.ToString();
                sb.AppendLine($"  first header {head}");
                sb.AppendLine($"  block sizes {chunks[0].Length}.., wait between blocks ms: {string.Join(",", gaps.GetRange(0, Math.Min(12, gaps.Count)))}");
                if (stamps.Count > 2) sb.AppendLine($"  time stamps step: {stamps[1] - stamps[0]}, {stamps[2] - stamps[1]}");

                var all = new byte[total];
                int o = 0;
                foreach (var c in chunks) { Buffer.BlockCopy(c, 0, all, o, c.Length); o += c.Length; }
                int n = total / 4;   // assumed: 16 bit, two channels
                var L = new double[n]; var R = new double[n];
                for (int i = 0; i < n; i++)
                {
                    L[i] = (short)(all[i * 4] | all[i * 4 + 1] << 8);
                    R[i] = (short)(all[i * 4 + 2] | all[i * 4 + 3] << 8);
                }
                sb.AppendLine($"  left: {Stats(L)}");
                sb.AppendLine($"  right: {Stats(R)}");
                // If the layout guess is right, neighbouring samples of one channel are close.
                double dSame = 0, dCross = 0, lr = 0, ll = 0, rr = 0;
                for (int i = 1; i < n; i++) { dSame += Math.Abs(L[i] - L[i - 1]); dCross += Math.Abs(L[i] - R[i]); }
                for (int i = 0; i < n; i++) { lr += L[i] * R[i]; ll += L[i] * L[i]; rr += R[i] * R[i]; }
                sb.AppendLine($"  step within a channel {dSame / n:0.0}, left-right difference {dCross / n:0.0}, left-right correlation {(ll > 0 && rr > 0 ? lr / Math.Sqrt(ll * rr) : 0):0.00}");
                sb.AppendLine($"  loudness over time (per 100 ms, 48 kHz assumed): {Envelope(L, 4800)}");
                foreach (int rate in new[] { 48000, 44100, 32000 })
                    sb.AppendLine($"  bands if {rate} Hz: {Bands(L, rate)}");
                if (toneHz > 0)
                    foreach (int rate in new[] { 48000, 44100 })
                        sb.AppendLine($"  share of a {toneHz} Hz tone if {rate} Hz: {Tone(L, rate, toneHz):0.000} (left), {Tone(R, rate, toneHz):0.000} (right)");
            }
            return sb.ToString();
        }

        static string Stats(double[] x)
        {
            double sum = 0, peak = 0; int zero = 0;
            foreach (var v in x) { double a = Math.Abs(v); sum += a; if (a > peak) peak = a; if (v == 0) zero++; }
            return $"mean level {sum / x.Length:0}, peak {peak:0}, silent samples {100.0 * zero / x.Length:0}%";
        }

        static string Envelope(double[] x, int win)
        {
            var parts = new List<string>();
            for (int i = 0; i + win <= x.Length && parts.Count < 40; i += win)
            {
                double s = 0;
                for (int j = 0; j < win; j++) s += Math.Abs(x[i + j]);
                parts.Add(((int)(s / win)).ToString());
            }
            return string.Join(" ", parts);
        }

        // Share of the signal's energy sitting at one frequency (Goertzel), 0..1.
        static double Tone(double[] x, int rate, double hz)
        {
            const int N = 4096;
            double best = 0;
            for (int s = 0; s + N <= x.Length; s += N)
            {
                double w = 2 * Math.PI * hz / rate, c = 2 * Math.Cos(w), s1 = 0, s2 = 0, e = 0;
                for (int i = 0; i < N; i++) { double v = x[s + i]; double s0 = v + c * s1 - s2; s2 = s1; s1 = s0; e += v * v; }
                double power = s1 * s1 + s2 * s2 - c * s1 * s2;
                if (e > 0) best = Math.Max(best, 2 * power / (N * e));
            }
            return best;
        }

        // Energy share below 300 Hz, 300-3400 Hz (speech), 3.4-8 kHz and above.
        static string Bands(double[] x, int rate)
        {
            const int N = 2048;
            var acc = new double[N / 2];
            var re = new double[N]; var im = new double[N];
            int frames = 0;
            for (int s = 0; s + N <= x.Length && frames < 60; s += N, frames++)
            {
                for (int i = 0; i < N; i++) { re[i] = x[s + i] * (0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (N - 1))); im[i] = 0; }
                Fft(re, im);
                for (int i = 0; i < N / 2; i++) acc[i] += re[i] * re[i] + im[i] * im[i];
            }
            double[] edge = { 300, 3400, 8000, 1e9 };
            var band = new double[4]; double tot = 0; int peakBin = 1;
            for (int i = 1; i < N / 2; i++)
            {
                double f = (double)i * rate / N;
                int b = 0; while (f >= edge[b]) b++;
                band[b] += acc[i]; tot += acc[i];
                if (acc[i] > acc[peakBin]) peakBin = i;
            }
            if (tot <= 0) return "silence";
            return $"low {100 * band[0] / tot:0}% | speech band {100 * band[1] / tot:0}% | high {100 * band[2] / tot:0}% | top {100 * band[3] / tot:0}% | strongest at {peakBin * rate / N} Hz";
        }

        static void Fft(double[] re, double[] im)
        {
            int n = re.Length;
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1) j ^= bit;
                j ^= bit;
                if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
            }
            for (int len = 2; len <= n; len <<= 1)
            {
                double ang = -2 * Math.PI / len;
                for (int i = 0; i < n; i += len)
                    for (int k = 0; k < len / 2; k++)
                    {
                        double wr = Math.Cos(ang * k), wi = Math.Sin(ang * k);
                        int a = i + k, b = i + k + len / 2;
                        double xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                        re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
                    }
            }
        }
    }
}

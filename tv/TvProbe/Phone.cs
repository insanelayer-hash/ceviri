using System;
using System.Collections.Generic;
using System.Threading;

namespace TvProbe
{
    // The iPhone app as the reading/translation engine. It long-polls /job; when a new
    // subtitle line shows up the service hands it the crop right away, the phone reads it
    // (Vision) and translates it on-device and calls /result. Several jobs can be in flight
    // at once; Subtitles decides which answers still belong to the line on screen.
    static class Phone
    {
        public class Job
        {
            public int Id, Chain, X, Y, W, H;
            public int[] Rects;         // one x,y,w,h per text line
            public byte[] Crop;         // raw 8-bit gray, W x H
            public long Created;
            public bool Voted;
        }

        static readonly object _lock = new object();
        static Job _pending;
        static readonly List<Job> _recent = new List<Job>();
        // Job ids must keep rising across restarts of this service: the phone app stays running
        // and ignores ids lower than the newest one it has seen. So start from the clock
        // (four ids per second since late 2026 is far more than are ever issued).
        static int _nextId = (int)Math.Max(1000, Math.Min(2000000000L, (DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 1795000000L) * 4));
        static readonly int _firstId = _nextId;
        static int _waiting;
        static long _lastSeenTicks;
        static string _device = "";
        static int _done, _replaced;
        static long _lastOcrMs, _lastTlMs, _lastRoundMs;
        static Job _last;

        public static int Submitted => Volatile.Read(ref _nextId) - _firstId;
        public static Job Last { get { lock (_lock) return _last; } }

        // Phone counts as connected while it is waiting on /job or polled in the last 4 s.
        public static bool Active =>
            Volatile.Read(ref _waiting) > 0 || DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastSeenTicks) < TimeSpan.FromSeconds(4).Ticks;

        public static Job Submit(int chain, byte[] crop, int x, int y, int w, int h, int[] rects = null)
        {
            AudioTap.Touch();
            lock (_lock)
            {
                var j = new Job { Id = ++_nextId, Chain = chain, Crop = crop, X = x, Y = y, W = w, H = h, Rects = rects, Created = DateTime.UtcNow.Ticks };
                if (_pending != null) _replaced++;      // never picked up: the newer line wins
                _pending = j; _last = j;
                _recent.Add(j);
                if (_recent.Count > 24) _recent.RemoveAt(0);
                Monitor.PulseAll(_lock);
                return j;
            }
        }

        // Blocks up to waitMs for a job; null when none arrived.
        public static Job WaitJob(int waitMs, string device)
        {
            Interlocked.Exchange(ref _lastSeenTicks, DateTime.UtcNow.Ticks);
            if (!string.IsNullOrEmpty(device)) _device = device;
            Interlocked.Increment(ref _waiting);
            try
            {
                lock (_lock)
                {
                    if (_pending == null) Monitor.Wait(_lock, Math.Max(100, Math.Min(waitMs, 20000)));
                    var j = _pending;
                    _pending = null;
                    return j;
                }
            }
            finally
            {
                Interlocked.Decrement(ref _waiting);
                Interlocked.Exchange(ref _lastSeenTicks, DateTime.UtcNow.Ticks);
            }
        }

        // The waiting job, if any, without blocking (used by the offline simulator).
        public static Job WaitJobNow()
        {
            lock (_lock) { var j = _pending; _pending = null; return j; }
        }

        public static Job Find(int id)
        {
            lock (_lock)
            {
                foreach (var r in _recent) if (r.Id == id) return r;
            }
            return null;
        }

        public static string Result(int id, string tr, string en, long ocrMs, long tlMs, bool final)
        {
            Job j = null;
            lock (_lock)
            {
                foreach (var r in _recent) if (r.Id == id) { j = r; break; }
            }
            if (j == null) return "unknown or stale job";
            long round = (DateTime.UtcNow.Ticks - j.Created) / TimeSpan.TicksPerMillisecond;
            _lastOcrMs = ocrMs; _lastTlMs = tlMs; _lastRoundMs = round;
            Interlocked.Increment(ref _done);
            string verdict = Subtitles.FromPhone(j, tr ?? "", en ?? "", round, final);
            Log.Add($"phone #{id} {(final ? "final" : "quick")} {round}ms (ocr {ocrMs} tl {tlMs}) [{verdict}]: {en} => {tr}");
            return "ok";
        }

        public static string Status()
        {
            return $"active={Active} device={_device} jobs={Submitted} answered={_done} replaced={_replaced} " +
                   $"last: ocr {_lastOcrMs} ms, translate {_lastTlMs} ms, round trip {_lastRoundMs} ms\n" + Subtitles.Stats();
        }
    }
    // HDMI inputs. The overlay app (which owns the TV picture) reports which inputs have a
    // device and which one it is showing; the phone app reads that and sets the "hdmi"
    // setting (0 = automatic), which the overlay follows.
    static class Inputs
    {
        static readonly object _lock = new object();
        static string _list = "";
        static int _current;

        public static void Report(string list, int current)
        {
            var sb = new System.Text.StringBuilder();
            foreach (var part in (list ?? "").Split(','))
                if (int.TryParse(part, out int n) && n > 0 && n < 100) sb.Append(sb.Length > 0 ? "," : "").Append(n);
            lock (_lock) { _list = sb.ToString(); _current = current; }
        }

        public static string Json()
        {
            lock (_lock)
                return "{" + $"\"hdmi\":{(int)Settings.Num("hdmi", 0)},\"cur\":{_current},\"list\":[{_list}]" + "}";
        }
    }
}

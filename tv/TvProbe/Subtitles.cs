using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;

namespace TvProbe
{
    // Subtitle loop. About 25 times a second it captures the frame and looks for subtitle
    // lines (centred, dense thin bright strokes). A new line goes to the iPhone app at once,
    // which reads and translates it on-device; the overlay app waits on /subtitle and draws
    // the Turkish text over the game.
    //
    // What keeps the picture calm:
    //  - a line is recognised as "still the same line" by its stroke shape (LineSig), so it is
    //    sent once, not on every frame the background moves;
    //  - answers only count for the line that is on screen (its "chain"); late answers for
    //    an older line are dropped instead of flashing up;
    //  - if the same line is read more than once, the reading seen most often is shown and
    //    the text does not flip between near-identical readings;
    //  - the text is only cleared after the line has really been gone for a moment.
    static class Subtitles
    {
        const int W = 960, H = 540;
        const double SameD = 0.30;      // LineSig distance: same line
        const double MaybeD = 0.60;     // probably the same line, changed (fading in, noise)

        public struct Det { public bool Found; public int Total, X, Y, Wd, Ht; public int[] Rects; public LineSig Sig; }

        class Line
        {
            public LineSig Sig;
            public int X, Y, Wd, Ht, Chain, Tries;
            public int[] Rects;
            public long FirstSeen, LastSeen, LastSubmit;
            public bool Answered, Ended, EmptyResult, FromCache;
            public bool Unconfirmed;    // a short line sent on first sight, not yet seen twice
        }

        class Vote { public int Count, Job; public string Tr, En; public bool Final; }

        public static Func<long> Clock = () => DateTime.UtcNow.Ticks;

        static readonly object _state = new object();

        // What the overlay shows (read by /subtitle).
        static int _seq;
        static string _tr = "", _en = "", _shownEn = "", _status = "başlıyor";
        static int _rx, _ry, _rw, _rh;            // rectangle around all of the English text
        static int[] _rects = new int[0];         // and one x,y,w,h per text line inside it
        static long _latencyMs, _shownTicks;
        static int _shownChain = -1, _shownJob;
        static bool _shownFinal;
        static readonly Dictionary<string, Vote> _votes = new Dictionary<string, Vote>();

        // The line on screen. A chain is one line as the viewer sees it, even if its capture
        // changed a little and it was sent to the phone again.
        static Line _cur;
        static int _chain;

        static int _skipped, _lastStrokes, _lines, _dropped;

        // Experiment ("style" setting): 0 = black box, 1 = let the browser blur what is behind
        // the text, 2 = a background patch made here from the captured frame. For 2 the
        // patch is two rows of colours (just above and just below the text) across the
        // line; stretched over the text it gives a soft fill with no English letters in it.
        static string _patch = "";
        static int _patchSeq, _patchCols, _patchRows = 2, _patchX, _patchW;
        static long _demoUntil;

        // Cover: the English line is hidden (blurred or boxed) from the moment it is seen,
        // before its translation is back, so the viewer does not read English first.
        static bool _cover;
        static int _coverChain;
        static long _coverTicks;
        static byte[] _chroma;
        static long _lastPollTicks;
        // Last time the phone said (with its job request) that it speaks the lines.
        public static long VoiceWantedTicks;
        static int _stepMs, _capMs;

        // Buffers reused every frame (the loop runs ~25 times a second).
        static byte[] _luma;
        static int _lumaW, _lumaH;
        static bool[] _stroke, _keepRow;
        static int[] _rowCount, _col, _sorted;
        static readonly int[] _acc = new int[32];

        public static void Start()
        {
            var t = new Thread(Loop) { IsBackground = true, Name = "subtitles" };
            t.Start();
        }

        // seq/waitMs: long poll. Returns at once when the caller's seq (or, for the patch
        // experiment, pseq) is out of date, otherwise waits until something changes or
        // waitMs passes.
        public static string Poll(int seq, int pseq, int waitMs)
        {
            Interlocked.Exchange(ref _lastPollTicks, DateTime.UtcNow.Ticks);
            string json;
            lock (_state)
            {
                bool current = seq == _seq && ((int)Settings.Num("style", 0) != 2 || (_tr.Length == 0 && !_cover) || pseq == _patchSeq);
                if (waitMs > 0 && current) Monitor.Wait(_state, Math.Min(waitMs, 5000));
                int style = (int)Settings.Num("style", 0);   // read after the wait: it may have changed
                json = "{" +
                    $"\"seq\":{_seq},\"line\":{_shownChain},\"tr\":{Json.Esc(_tr)},\"en\":{Json.Esc(_en)}," +
                    $"\"x\":{_rx},\"y\":{_ry},\"w\":{_rw},\"h\":{_rh},\"n\":{Math.Max(1, _rects.Length / 4)},\"r\":[{string.Join(",", _rects)}],\"fw\":{W},\"fh\":{H}," +
                    $"\"status\":{Json.Esc(_status)},\"lat\":{_latencyMs},\"calls\":{Phone.Submitted},\"skipped\":{_skipped}," +
                    $"\"errors\":0,\"strokes\":{_lastStrokes},\"step\":{_stepMs},\"cov\":{(_cover ? 1 : 0)},\"style\":{style},\"hdmi\":{(int)Settings.Num("hdmi", 0)},\"snd\":{_snd},\"sndp\":{Json.Esc(_sndp)},\"aseq\":{Speech.Seq},\"pan\":{(AudioTap.Split ? 1 : 0)}" +
                    (style == 2 ? $",\"pseq\":{_patchSeq},\"pr\":{_patchRows},\"pc\":{_patchCols},\"px\":{_patchX},\"pw\":{_patchW},\"patch\":\"{_patch}\"" : "") +
                    "}";
            }
            Interlocked.Exchange(ref _lastPollTicks, DateTime.UtcNow.Ticks);
            return json;
        }

        // ---- lines for the computer that speaks them (/lines) -------------------------
        // Every line on screen, once it has Turkish text: the computer's program waits here,
        // makes the voice and hands it back with /say. A line whose text changes while it is
        // up is given again under a new number (the computer says a line once).
        class Fed { public int N, Chain; public string Tr; public long First; public bool Final; }
        static readonly List<Fed> _feed = new List<Fed>();
        static int _feedN;
        public static long PcSeenTicks;
        public static bool PcActive => DateTime.UtcNow.Ticks - Interlocked.Read(ref PcSeenTicks) < 15 * TimeSpan.TicksPerSecond;

        // Call with _state held.
        // final: the phone will not replace this text with a better translation.
        static void Feed(int chain, string tr, long first, bool final)
        {
            if (chain < 0 || tr.Length == 0) return;
            foreach (var f in _feed)
                if (f.Chain == chain)
                {
                    if (f.Tr == tr && f.Final == final) return;
                    f.Tr = tr; f.Final = final; f.N = ++_feedN;
                    Monitor.PulseAll(_state);
                    return;
                }
            _feed.Add(new Fed { N = ++_feedN, Chain = chain, Tr = tr, First = first, Final = final });
            if (_feed.Count > 24) _feed.RemoveAt(0);
            Monitor.PulseAll(_state);
        }

        // after < 0 (or ahead of us, after a restart here): just the current number, no old lines.
        public static string Lines(int after, int waitMs)
        {
            Interlocked.Exchange(ref PcSeenTicks, DateTime.UtcNow.Ticks);
            AudioTap.Wanted();
            var sb = new System.Text.StringBuilder();
            lock (_state)
            {
                if (after < 0 || after > _feedN) return "{" + $"\"n\":{_feedN},\"lines\":[]" + "}";
                long deadline = DateTime.UtcNow.Ticks + Math.Max(0, Math.Min(waitMs, 10000)) * TimeSpan.TicksPerMillisecond;
                while (_feedN <= after)
                {
                    long left = (deadline - DateTime.UtcNow.Ticks) / TimeSpan.TicksPerMillisecond;
                    if (left <= 0) break;
                    Monitor.Wait(_state, (int)Math.Min(left, 1000));
                }
                long now = DateTime.UtcNow.Ticks;
                sb.Append("{").Append($"\"n\":{_feedN},\"lines\":[");
                bool any = false;
                foreach (var f in _feed)
                {
                    if (f.N <= after) continue;
                    sb.Append(any ? "," : "").Append("{").Append($"\"n\":{f.N},\"line\":{f.Chain},\"t\":\"{f.First}\",\"age\":{(now - f.First) / TimeSpan.TicksPerMillisecond},\"final\":{(f.Final ? 1 : 0)},\"tr\":{Json.Esc(f.Tr)}").Append("}");
                    any = true;
                }
                sb.Append("]}");
            }
            Interlocked.Exchange(ref PcSeenTicks, DateTime.UtcNow.Ticks);
            return sb.ToString();
        }

        // Wakes the overlay's waiting request (a spoken line is ready for it).
        public static void Nudge()
        {
            lock (_state) { _seq++; Monitor.PulseAll(_state); }
        }

        // A line is spoken once: true the first time a spoken version arrives for it.
        static int _spokenChain = -1;
        public static bool ClaimSpeech(int chain)
        {
            lock (_state)
            {
                if (chain == _spokenChain) return false;
                _spokenChain = chain;
                return true;
            }
        }

        // Sound experiment: asks the overlay to play a test sound ("kind,frequency,ms,volume").
        static int _snd; static string _sndp = "";
        public static string Sound(string p)
        {
            lock (_state) { _snd++; _sndp = p; _seq++; Monitor.PulseAll(_state); }
            return "ok " + _snd;
        }

        // Shows a test line at a given place for a while (no game dialogue needed).
        public static string Demo(string tr, int x, int y, int w, int h, int ms)
        {
            long now = Clock();
            lock (_state)
            {
                _demoUntil = now + TimeSpan.FromMilliseconds(ms).Ticks;
                _votes.Clear();
                _tr = "";   // so the rectangle is taken as given, not grown from the last line
                Show(CleanTr(tr), "", "", x, y, w, h, new[] { x, y, w, h }, -2, 0, true, 0, now);
            }
            return "ok";
        }

        public static string Stats()
        {
            return $"loop: step {_stepMs} ms (capture {_capMs} ms), target every {(int)Settings.Num("interval", 40)} ms, " +
                   $"lines {_lines}, late answers dropped {_dropped}, remembered {LineCache.Count}";
        }

        static void SetStatus(string s)
        {
            lock (_state) _status = s;
        }

        static void Loop()
        {
            var sw = new Stopwatch();
            while (true)
            {
                int period = (int)Settings.Num("interval", 40);
                sw.Restart();
                try
                {
                    bool overlayActive = DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastPollTicks) < TimeSpan.FromSeconds(5).Ticks;
                    if (!overlayActive) { Thread.Sleep(300); continue; }
                    if (!Phone.Active)
                    {
                        lock (_state)
                        {
                            _status = "iPhone bağlı değil: TR Altyazı uygulamasını aç";
                            if (_tr.Length > 0 && Clock() - _shownTicks >= Ms("hold", 3500)) Clear();
                            if (_cover) Uncover(_coverChain);
                        }
                        Thread.Sleep(300);
                        continue;
                    }
                    Step();
                }
                catch (Exception ex) { SetStatus("hata: " + ex.Message); Log.Add("subtitles: " + ex); }
                int elapsed = (int)sw.ElapsedMilliseconds;
                _stepMs = _stepMs == 0 ? elapsed : (_stepMs * 7 + elapsed + 4) / 8;
                Thread.Sleep(Math.Max(4, period - elapsed));
            }
        }

        static long Ms(string key, double def) => TimeSpan.FromMilliseconds(Settings.Num(key, def)).Ticks;

        static void Step()
        {
            var sw = Stopwatch.StartNew();
            bool patch = (int)Settings.Num("style", 0) == 2;
            int ret = Capture.GrabFrameInto(W, H, ref _luma, ref _chroma, patch, out int fw, out int fh);
            int cap = (int)sw.ElapsedMilliseconds;
            _capMs = _capMs == 0 ? cap : (_capMs * 7 + cap + 4) / 8;
            if (ret == -4) { SetStatus("HDCP koruması açık (PS5: Ayarlar > Sistem > HDMI)"); return; }
            if (ret != 0) { SetStatus("yakalama hatası " + ret); return; }
            _lumaW = fw; _lumaH = fh;
            Process(_luma, fw, fh);
            if (patch) UpdatePatch(_luma, _chroma, fw, fh);
        }

        // Captured video level -> level on the TV's composed screen, measured on this TV by
        // capturing the same still frame both ways (the HDMI picture is HDR-coded, so it
        // looks grey and flat until mapped). Colour differences needed a gain of about 2.4.
        static readonly int[] LutIn = { 32, 48, 58, 66, 74, 82, 90, 98, 106, 114, 122, 130, 138, 146, 154, 170, 190 };
        static readonly int[] LutOut = { 0, 22, 35, 45, 54, 64, 74, 85, 95, 104, 119, 132, 159, 181, 190, 225, 255 };

        static double MapLevel(double v)
        {
            if (v <= LutIn[0]) return LutOut[0];
            for (int i = 1; i < LutIn.Length; i++)
                if (v <= LutIn[i])
                    return LutOut[i - 1] + (v - LutIn[i - 1]) * (LutOut[i] - LutOut[i - 1]) / (LutIn[i] - LutIn[i - 1]);
            return 255;
        }

        static void UpdatePatch(byte[] y, byte[] c, int fw, int fh)
        {
            int rx, rw; bool shown; int[] rects;
            lock (_state) { shown = _tr.Length > 0 || _cover; rx = _rx; rw = _rw; rects = _rects; }
            int n = rects.Length / 4;
            if (!shown || rw <= 0 || c == null || n == 0) return;

            // A strip wider than the English line, since the Turkish one may be longer.
            int half = Math.Max(rw / 2 + 32, 320), mid = rx + rw / 2;
            int x0 = Math.Max(0, mid - half) & ~7, x1 = Math.Min(fw, mid + half) & ~7;
            int cols = (x1 - x0) / 8;
            if (cols < 2) return;
            double chromaGain = Settings.Num("pchroma", 2.4), gain = Settings.Num("pgain", 1.33);   // the TV shows overlay graphics ~25% dimmer than video (measured)

            // Colour bands: just above the first text line, in the gap between each pair of
            // lines, and just below the last. Line i is then filled between band i and i+1.
            var sb = new StringBuilder(cols * 6 * (n + 1));
            for (int band = 0; band <= n; band++)
            {
                int ya, yb;
                if (band == 0) { ya = rects[1] - 6; yb = rects[1] - 1; }
                else if (band == n) { int end = rects[(n - 1) * 4 + 1] + rects[(n - 1) * 4 + 3]; ya = end + 1; yb = end + 6; }
                else { int m = (rects[(band - 1) * 4 + 1] + rects[(band - 1) * 4 + 3] + rects[band * 4 + 1]) / 2; ya = m - 1; yb = m + 1; }
                ya = Math.Max(0, Math.Min(fh - 1, ya)); yb = Math.Max(ya + 1, Math.Min(fh, yb));
                for (int col = 0; col < cols; col++)
                {
                    int xa = x0 + col * 8;
                    long sy = 0, su = 0, sv = 0; int ny = 0, nc = 0;
                    for (int yy = ya; yy < yb; yy++)
                    {
                        int row = yy * fw + xa;
                        for (int xx = 0; xx < 8; xx++) sy += y[row + xx];
                        ny += 8;
                        int crow = (yy / 2) * fw + (xa & ~1);
                        for (int xx = 0; xx < 8; xx += 2) { su += c[crow + xx]; sv += c[crow + xx + 1]; nc++; }
                    }
                    double Y = MapLevel(sy / (double)ny) * gain;
                    double U = (su / (double)nc - 128) * chromaGain, V = (sv / (double)nc - 128) * chromaGain;
                    Hex(sb, Y + 1.5748 * V); Hex(sb, Y - 0.1873 * U - 0.4681 * V); Hex(sb, Y + 1.8556 * U);
                }
            }
            lock (_state)
            {
                _patch = sb.ToString(); _patchCols = cols; _patchRows = n + 1; _patchX = x0; _patchW = x1 - x0;
                _patchSeq++;
                Monitor.PulseAll(_state);
            }
        }

        static void Hex(StringBuilder sb, double v)
        {
            int b = v < 0 ? 0 : v > 255 ? 255 : (int)(v + 0.5);
            const string digits = "0123456789abcdef";
            sb.Append(digits[b >> 4]).Append(digits[b & 15]);
        }

        // One captured frame: find the line, decide whether it is new, and send it.
        public static void Process(byte[] y, int fw, int fh)
        {
            long now = Clock();
            Detect(y, fw, fh, out var det);
            _lastStrokes = det.Total;

            long gap = Ms("gap", 350), hold = Ms("hold", 3500);
            lock (_state)
            {
                // Short lines ("No.", "Okay.") have few strokes, like some scene details. They
                // are sent on first sight, to lose no time, and must still be there on the
                // next frame; if not, it was noise and whatever comes back for it is dropped.
                if (_cur != null && _cur.Unconfirmed && !_cur.Ended)
                {
                    if (det.Found && LineSig.Distance(det.Sig, _cur.Sig) <= MaybeD) _cur.Unconfirmed = false;
                    else
                    {
                        Uncover(_cur.Chain);
                        if (!_cur.Answered) _chain++;
                        _cur.Ended = true;
                    }
                }
                // The cover goes when its line has left the screen, or after a while with no
                // answer (phone gone, nothing readable there).
                if (_cover && (_cur == null || _cur.Ended || _cur.Chain != _coverChain || now - _coverTicks > Ms("covermax", 1500)))
                    Uncover(_coverChain);

                if (!det.Found)
                {
                    if (_cur != null && !_cur.Ended && now - _cur.LastSeen >= gap) EndLine();
                    Expire(now, hold);
                    if (_tr.Length == 0) _status = "altyazı yok";
                    return;
                }

                double d = _cur != null && !_cur.Ended ? LineSig.Distance(det.Sig, _cur.Sig) : 1;
                if (d <= SameD)
                {
                    // Still the same line. Ask again only if the phone has not answered.
                    _cur.LastSeen = now; _skipped++;
                    if (!_cur.Answered && _cur.Tries < 4 && (_cur.EmptyResult || now - _cur.LastSubmit >= Ms("retry", 500)))
                    {
                        // Read twice and nothing there: stop hiding it.
                        if (_cur.EmptyResult && _cur.Tries >= 2) Uncover(_cur.Chain);
                        Send(_cur, det, y, fw, now);
                    }
                    Expire(now, hold);
                    return;
                }

                bool maybe = d <= MaybeD;
                // The line looks a bit different (background, fade) but already has its
                // translation: re-read it at most a few times a second.
                if (maybe && _cur.Answered && now - _cur.LastSubmit < Ms("recheck", 400)) { _cur.LastSeen = now; _skipped++; return; }

                long first = now; bool answered = false, unconfirmed = false;
                if (maybe) { first = _cur.FirstSeen; answered = _cur.Answered; }
                else
                {
                    if (_cur != null && !_cur.Ended) EndLine();
                    _chain++; _lines++;
                    unconfirmed = det.Total < 150;
                }
                var line = new Line
                {
                    Sig = det.Sig, X = det.X, Y = det.Y, Wd = det.Wd, Ht = det.Ht, Rects = det.Rects, Chain = _chain,
                    FirstSeen = first, LastSeen = now, Answered = answered, Unconfirmed = unconfirmed,
                };
                _cur = line;

                if (!maybe)
                {
                    // Seen this exact line before: show it at once, no phone round trip.
                    string cached = LineCache.Lookup(det.Sig);
                    if (cached != null)
                    {
                        line.Answered = true; line.FromCache = true;
                        _votes.Clear();
                        Show(cached, "", "", line.X, line.Y, line.Wd, line.Ht, line.Rects, _chain, 0, true, 0, now);
                        _status = "ok (hafızadan)";
                        // The text is there at once, but the voice is made on the phone: with the
                        // voice on, the line goes to the phone as well, or it would stay silent.
                        if (DateTime.UtcNow.Ticks - Interlocked.Read(ref VoiceWantedTicks) < 30 * TimeSpan.TicksPerSecond)
                            Send(line, det, y, fw, now);
                        return;
                    }
                }
                Send(line, det, y, fw, now);
                if (!maybe && now >= _demoUntil && Settings.Num("cover", 1) != 0) Cover(line, now);
            }
        }

        // Hide the English of a line that has just appeared: the overlay draws its cover
        // (blur patch or box) over the line's rectangles with no text yet. The previous
        // line's text goes at the same moment; its English is no longer on screen.
        static void Cover(Line line, long now)
        {
            _tr = ""; _en = ""; _shownEn = "";
            _votes.Clear();
            _rx = line.X; _ry = line.Y; _rw = line.Wd; _rh = line.Ht;
            _rects = line.Rects ?? new[] { line.X, line.Y, line.Wd, line.Ht };
            _cover = true; _coverChain = line.Chain; _coverTicks = now;
            _seq++;
            Monitor.PulseAll(_state);
        }

        static void Uncover(int chain)
        {
            if (!_cover || _coverChain != chain) return;
            _cover = false;
            _seq++;
            Monitor.PulseAll(_state);
        }

        static void Send(Line line, Det det, byte[] y, int fw, long now)
        {
            var crop = new byte[det.Wd * det.Ht];
            for (int r = 0; r < det.Ht; r++) Buffer.BlockCopy(y, (det.Y + r) * fw + det.X, crop, r * det.Wd, det.Wd);
            Phone.Submit(line.Chain, crop, det.X, det.Y, det.Wd, det.Ht, det.Rects);
            line.LastSubmit = now; line.Tries++; line.EmptyResult = false;
            if (!line.Answered) _status = "telefonda çevriliyor…";
        }

        // The line left the screen: remember its translation for next time.
        static void EndLine()
        {
            if (_cur.Answered && !_cur.FromCache && _shownChain == _cur.Chain && _shownFinal && _tr.Length > 0)
                LineCache.Add(_cur.Sig, _tr);
            _cur.Ended = true;
        }

        // Clears text that belongs to a line no longer on screen, once it has been readable
        // for `hold`. While a new line is being translated the old text stays a moment
        // longer, so the box does not blink between two lines.
        static void Expire(long now, long hold)
        {
            if (_tr.Length == 0 || now < _demoUntil) return;
            bool live = _cur != null && !_cur.Ended;
            if (live && _shownChain == _cur.Chain) return;
            if (now - _shownTicks < hold) return;
            if (live && now - _cur.FirstSeen < TimeSpan.FromMilliseconds(1200).Ticks) return;
            Clear();
        }

        static void Clear()
        {
            _tr = ""; _en = ""; _shownEn = "";
            _votes.Clear();
            _cover = false;
            _seq++;
            Monitor.PulseAll(_state);
        }

        static void Show(string tr, string key, string en, int x, int y, int w, int h, int[] rects, int chain, int job, bool final, long ms, long now)
        {
            bool sameLine = _shownChain == chain && _tr.Length > 0;
            bool wasCovered = _cover;
            _cover = false;
            if (sameLine)
            {
                // Keep the box steady: it only grows while the same line is up.
                int x1 = Math.Max(_rx + _rw, x + w), y1 = Math.Max(_ry + _rh, y + h);
                x = Math.Min(_rx, x); y = Math.Min(_ry, y); w = x1 - x; h = y1 - y;
                if (rects == null || rects.Length < _rects.Length) rects = _rects;
            }
            if (rects == null || rects.Length < 4) rects = new[] { x, y, w, h };
            bool changed = wasCovered || tr != _tr || x != _rx || y != _ry || w != _rw || h != _rh || !SameRects(rects, _rects);
            _tr = tr; _en = en; _shownEn = key;
            _rx = x; _ry = y; _rw = w; _rh = h; _rects = rects;
            _shownJob = sameLine ? Math.Max(_shownJob, job) : job;
            _shownChain = chain; _shownFinal = final;
            _latencyMs = ms;
            if (!sameLine) _shownTicks = now;
            _status = "ok";
            if (changed) { _seq++; Monitor.PulseAll(_state); }
            Feed(chain, tr, _cur != null && _cur.Chain == chain ? _cur.FirstSeen : now, final);
        }

        static bool SameRects(int[] a, int[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        // Answer from the iPhone app (Phone.Result). The same job may answer twice: a quick
        // translation first (final = false), then a more natural one that replaces it.
        public static string FromPhone(Phone.Job job, string tr, string en, long ms, bool final)
        {
            tr = CleanTr(tr); en = en.Trim();
            long now = Clock();
            lock (_state)
            {
                if (job.Chain != _chain) { _dropped++; return "eski satır, gösterilmedi"; }
                if (tr.Length == 0)
                {
                    if (final && _cur != null && _cur.Chain == _chain) _cur.EmptyResult = true;
                    if (_tr.Length == 0) _status = "telefon: metin okunamadı";
                    return "boş";
                }
                string key = Norm(en);
                bool sameLine = _shownChain == _chain && _tr.Length > 0;
                bool similar = sameLine && _shownEn.Length > 0 && key.Length > 0 && Similar(key, _shownEn);
                // A different reading from an older capture of this line: the newer one stays.
                if (sameLine && !similar && job.Id < _shownJob) { _dropped++; return "eski okuma"; }
                if (!similar) _votes.Clear();
                if (!_votes.TryGetValue(key, out var v)) _votes[key] = v = new Vote();
                if (!job.Voted) { v.Count++; job.Voted = true; }
                if (final || !v.Final) { v.Tr = tr; v.En = en; v.Final |= final; }
                v.Job = Math.Max(v.Job, job.Id);

                // Keep the reading on screen unless another one has been seen more often.
                string best = similar && _votes.ContainsKey(_shownEn) ? _shownEn : key;
                foreach (var kv in _votes) if (kv.Value.Count > _votes[best].Count) best = kv.Key;
                var b = _votes[best];
                Show(b.Tr, best, b.En, job.X, job.Y, job.W, job.H, job.Rects, _chain, job.Id, b.Final, ms, now);
                if (_cur != null && _cur.Chain == _chain) _cur.Answered = true;
                return best == key ? "gösterildi" : "oy: önceki okuma kaldı";
            }
        }

        // ---- detection -------------------------------------------------------------

        // Finds subtitle lines in the frame. The PS5 sends HDR, so subtitle white is only
        // ~160 luma here and a plain brightness threshold also catches sand and sky.
        // Instead mark "stroke" pixels: brighter by `delta` than a pixel within 3 px on both
        // the left and the right (thin bright glyph strokes).
        public static void Detect(byte[] y, int fw, int fh, out Det det)
        {
            det = default;
            int y0 = (int)(fh * Settings.Num("y0", 0.78)), y1 = (int)(fh * Settings.Num("y1", 0.98));
            // Strokes are marked over almost the full width, so long lines keep their first
            // and last words.
            int wx0 = Math.Max(3, (int)(fw * 0.03)), wx1 = Math.Min(fw - 3, (int)(fw * 0.97));
            if (y1 <= y0 + 8 || wx1 <= wx0 + 200) return;
            int delta = (int)Settings.Num("delta", 30);
            int minStrokes = (int)Settings.Num("minstrokes", 45);
            double minDensity = Settings.Num("density", 1.2);
            double centreTol = Settings.Num("centre", 0.10) * fw;

            // Subtitles are centred, so every line crosses the middle of the screen: rows are
            // judged in a narrow window there, clear of the minimap, the phone widget and
            // most of the scenery.
            int ww = wx1 - wx0, bh = y1 - y0, mid = fw / 2 - wx0, half = Math.Max(40, (int)(fw * 0.0625));
            int c0 = mid - half, c1 = mid + half;
            if (_stroke == null || _stroke.Length != ww * bh)
            {
                _stroke = new bool[ww * bh]; _rowCount = new int[bh]; _keepRow = new bool[bh]; _col = new int[ww]; _sorted = new int[bh];
            }
            else { Array.Clear(_stroke, 0, _stroke.Length); Array.Clear(_rowCount, 0, bh); Array.Clear(_keepRow, 0, bh); }
            var stroke = _stroke; var rowCount = _rowCount; var keepRow = _keepRow; var col = _col;

            for (int yy = 0; yy < bh; yy++)
            {
                int row = (y0 + yy) * fw + wx0, srow = yy * ww;
                for (int xx = 3; xx < ww - 3; xx++)
                {
                    int i = row + xx;
                    int v = y[i] - delta;
                    if (v < 60) continue;
                    if (!(y[i - 1] <= v || y[i - 2] <= v || y[i - 3] <= v)) continue;
                    if (!(y[i + 1] <= v || y[i + 2] <= v || y[i + 3] <= v)) continue;
                    stroke[srow + xx] = true;
                    if (xx >= c0 && xx < c1) rowCount[yy]++;
                }
            }

            // A busy background (leaves, fences, sand) has strokes on every row. Text rows
            // stand well above that level, so the row threshold follows the band's median.
            Array.Copy(rowCount, _sorted, bh);
            Array.Sort(_sorted);
            int rowMin = Math.Max(4, _sorted[bh / 2] * 2 + 2);

            // Group rows into text lines and keep the lines centred on screen. This drops
            // scene text such as car badges and signs.
            int gapMax = Math.Max(16, (int)(fw * 0.03));
            int total = 0, lines = 0, minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
            int yy0 = 0;
            while (yy0 < bh)
            {
                if (rowCount[yy0] < rowMin) { yy0++; continue; }
                int yy1 = yy0, gap = 0;
                while (yy1 + 1 < bh && (rowCount[yy1 + 1] >= rowMin || (gap < 1 && yy1 + 2 < bh && rowCount[yy1 + 2] >= rowMin)))
                {
                    gap = rowCount[yy1 + 1] >= rowMin ? 0 : gap + 1;
                    yy1++;
                }
                int hgt = yy1 - yy0 + 1, n = 0;
                for (int r = yy0; r <= yy1; r++) n += rowCount[r];
                if (hgt >= 5 && hgt <= 24 && n >= 30)
                {
                    Array.Clear(col, 0, ww);
                    for (int r = yy0; r <= yy1; r++)
                    {
                        int srow = r * ww;
                        for (int xx = 0; xx < ww; xx++) if (stroke[srow + xx]) col[xx]++;
                    }
                    // From the middle, grow to the real ends of the text, word by word. What
                    // counts as "text" is set by how dense the line is in the middle.
                    int need = Math.Max(6, (int)(n / (double)(2 * half) * 12 * 0.45));
                    int left = Grow(col, ww, mid, -1, gapMax, need), right = Grow(col, ww, mid, 1, gapMax, need);
                    int width = right - left + 1, nSeg = 0;
                    for (int xx = left; xx <= right; xx++) nSeg += col[xx];
                    double centre = wx0 + (left + right) / 2.0;
                    double tol = nSeg < 150 ? Math.Max(20, fw * 0.025) : centreTol;
                    // Real subtitle lines: ~2.5-3.7 strokes per pixel of width; background rows 0.1-0.5.
                    if (width >= 18 && nSeg >= 45 && nSeg / (double)width >= minDensity && Math.Abs(centre - fw / 2.0) <= tol)
                    {
                        for (int r = yy0; r <= yy1; r++) keepRow[r] = true;
                        total += nSeg;
                        if (lines < 8) { _acc[lines * 4] = left; _acc[lines * 4 + 1] = right; _acc[lines * 4 + 2] = yy0; _acc[lines * 4 + 3] = yy1; lines++; }
                        minX = Math.Min(minX, left); maxX = Math.Max(maxX, right);
                        minY = Math.Min(minY, yy0); maxY = Math.Max(maxY, yy1);
                    }
                }
                yy0 = yy1 + 1;
            }

            det.Total = total;
            if (total < minStrokes || maxX < 0) return;

            det.Sig = LineSig.Build(stroke, ww, keepRow, minX, minY, maxX - minX + 1, maxY - minY + 1, wx0, y0);
            // Rectangle sent to the phone and covered by the overlay: the text plus a margin.
            int cx0 = Math.Max(0, wx0 + minX - 10), cx1 = Math.Min(fw, wx0 + maxX + 11);
            int cy0 = Math.Max(0, y0 + minY - 5), cy1 = Math.Min(fh, y0 + maxY + 6);
            det.X = cx0; det.Y = cy0; det.Wd = cx1 - cx0; det.Ht = cy1 - cy0;
            // One rectangle per text line (same margins, but never reaching into the next
            // line), so the overlay can cover just the letters and leave the gap between
            // two lines alone.
            var rects = new int[lines * 4];
            for (int i = 0; i < lines; i++)
            {
                int l = _acc[i * 4], r = _acc[i * 4 + 1], t = _acc[i * 4 + 2], b = _acc[i * 4 + 3];
                int top = 5, bot = 5;
                if (i > 0) { int gap = Math.Max(0, t - _acc[(i - 1) * 4 + 3] - 1); top = Math.Min(5, gap - Math.Min(5, gap / 2)); }
                if (i < lines - 1) { int gap = Math.Max(0, _acc[(i + 1) * 4 + 2] - b - 1); bot = Math.Min(5, gap / 2); }
                int ax0 = Math.Max(0, wx0 + l - 10), ax1 = Math.Min(fw, wx0 + r + 11);
                int ay0 = Math.Max(0, y0 + t - top), ay1 = Math.Min(fh, y0 + b + 1 + bot);
                rects[i * 4] = ax0; rects[i * 4 + 1] = ay0; rects[i * 4 + 2] = ax1 - ax0; rects[i * 4 + 3] = ay1 - ay0;
            }
            det.Rects = rects;
            det.Found = true;
        }

        // From `from`, walk outwards (dir = -1 or 1) over the rest of the text: jump gaps up
        // to `gapMax` px as long as what follows is as dense as text.
        static int Grow(int[] col, int n, int from, int dir, int gapMax, int need)
        {
            int edge = from;
            while (true)
            {
                // Finish the run we are in (letters are at most a few px apart).
                int g = 0;
                for (int x = edge + dir; x >= 0 && x < n; x += dir)
                {
                    if (col[x] > 0) { edge = x; g = 0; }
                    else if (++g > 3) break;
                }
                // Look for the next word within the gap.
                int next = -1;
                for (int x = edge + dir, k = 0; k < gapMax && x >= 0 && x < n; x += dir, k++)
                {
                    if (col[x] < 2) continue;
                    int s = 0;
                    for (int j = 0; j < 12; j++)
                    {
                        int xx = x + dir * j;
                        if (xx < 0 || xx >= n) break;
                        s += col[xx];
                    }
                    if (s >= need) { next = x; break; }
                }
                if (next < 0) return edge;
                edge = next;
            }
        }

        // ---- text helpers ----------------------------------------------------------

        static string CleanTr(string s)
        {
            var sb = new StringBuilder();
            foreach (var part in s.Replace("\r", "").Split('\n'))
            {
                var t = part.Trim();
                if (t.Length == 0) continue;
                if (sb.Length > 0) sb.Append('\n');
                sb.Append(t);
            }
            return sb.ToString();
        }

        static string Norm(string s)
        {
            var sb = new StringBuilder(s.Length);
            bool space = false;
            foreach (char c in s.ToLowerInvariant())
            {
                if (char.IsWhiteSpace(c)) { space = sb.Length > 0; continue; }
                if (space) { sb.Append(' '); space = false; }
                sb.Append(c);
            }
            return sb.ToString();
        }

        // Two readings of the same line differ by a few characters at most.
        static bool Similar(string a, string b)
        {
            if (a == b) return true;
            int la = a.Length, lb = b.Length, limit = Math.Max(2, Math.Max(la, lb) / 4);
            if (Math.Abs(la - lb) > limit) return false;
            var prev = new int[lb + 1]; var cur = new int[lb + 1];
            for (int j = 0; j <= lb; j++) prev[j] = j;
            for (int i = 1; i <= la; i++)
            {
                cur[0] = i;
                for (int j = 1; j <= lb; j++)
                    cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
                var t = prev; prev = cur; cur = t;
            }
            return prev[lb] <= limit;
        }

        // ---- debugging and the old phone app ----------------------------------------

        // 2x bilinear upscale with a contrast stretch, as PNG. Only for /crop.png and for
        // phone app versions that still ask for PNG; the current app takes the raw crop.
        public static byte[] JobPng(Phone.Job j)
        {
            if (j == null) return null;
            const int S = 2;
            var src = j.Crop; int w = j.W, h = j.H, ow = w * S, oh = h * S;
            int lo = 255, hi = 0;
            foreach (var b in src) { if (b < lo) lo = b; if (b > hi) hi = b; }
            if (hi <= lo) hi = lo + 1;
            var dst = new byte[ow * oh];
            for (int yy = 0; yy < oh; yy++)
            {
                double fy = (yy + 0.5) / S - 0.5; int ya = Math.Max(0, (int)Math.Floor(fy)); int yb = Math.Min(h - 1, ya + 1); double ty = Math.Max(0, fy - ya);
                for (int xx = 0; xx < ow; xx++)
                {
                    double fx = (xx + 0.5) / S - 0.5; int xa = Math.Max(0, (int)Math.Floor(fx)); int xb = Math.Min(w - 1, xa + 1); double tx = Math.Max(0, fx - xa);
                    double v = (src[ya * w + xa] * (1 - tx) + src[ya * w + xb] * tx) * (1 - ty) + (src[yb * w + xa] * (1 - tx) + src[yb * w + xb] * tx) * ty;
                    int o = (int)((v - lo) * 255 / (hi - lo));
                    dst[yy * ow + xx] = (byte)(o < 0 ? 0 : o > 255 ? 255 : o);
                }
            }
            return Png.Gray(dst, ow, oh);
        }

        // The subtitle band of the latest frame as PNG (for tuning).
        public static byte[] BandPng()
        {
            byte[] y = _luma; int fw = _lumaW, fh = _lumaH;
            if ((y == null || fw == 0) && Capture.GrabLuma(W, H, out y, out fw, out fh) != 0) return null;
            int y0 = (int)(fh * Settings.Num("y0", 0.78)), y1 = (int)(fh * Settings.Num("y1", 0.98));
            var band = new byte[fw * (y1 - y0)];
            Buffer.BlockCopy(y, y0 * fw, band, 0, band.Length);
            return Png.Gray(band, fw, y1 - y0);
        }
    }
}

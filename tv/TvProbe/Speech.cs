using System;
using System.IO;
using System.Text;

namespace TvProbe
{
    // Spoken translation: the phone turns a Turkish line into sound and uploads the samples;
    // the overlay fetches them as a WAV and plays them over the game sound.
    static class Speech
    {
        static readonly object _lock = new object();
        static int _seq;
        // The last clips, by number: several can be announced before the overlay has fetched the first.
        static readonly System.Collections.Generic.Dictionary<int, byte[]> _wavs = new System.Collections.Generic.Dictionary<int, byte[]>();
        // A line may arrive in pieces (same sid): the first piece decides whether the line is said.
        static long _okSid, _noSid;
        public static int Seq { get { lock (_lock) return _seq; } }
        public static int Accepted, Dropped;

        public static string FromPhone(int id, int rate, byte[] pcm)
        {
            if (pcm == null || pcm.Length < 400 || rate < 8000 || rate > 48000) return "empty";
            var job = Phone.Find(id);
            if (job == null) { Dropped++; return "unknown job"; }
            long ms = (DateTime.UtcNow.Ticks - job.Created) / TimeSpan.TicksPerMillisecond;
            // Too late to be worth saying, or this line already has its voice.
            if (ms > 5000) { Dropped++; Log.Add($"speech #{id} dropped: {ms} ms late"); return "late"; }
            if (!Subtitles.ClaimSpeech(job.Chain)) { Dropped++; return "already spoken"; }
            Put(pcm, rate);
            Accepted++;
            Log.Add($"speech #{id}: {pcm.Length / 2 * 1000L / rate} ms of sound, {ms} ms after the line appeared");
            return "ok";
        }

        // A line spoken by the computer (see Subtitles.Lines). `first`: when the line appeared.
        // Answers "ok <ms>": how long until it starts (the clips before it are still playing).
        public static string FromPc(int chain, long first, int rate, byte[] pcm)
        {
            if (pcm == null || pcm.Length < 400 || rate < 8000 || rate > 48000) return "empty";
            long now = DateTime.UtcNow.Ticks, ms = (now - first) / TimeSpan.TicksPerMillisecond, wait;
            lock (_lock) wait = Math.Max(0, (_ownTo - now) / TimeSpan.TicksPerMillisecond);
            if (ms < -2000 || ms + wait > 6000) { Dropped++; Log.Add($"pc speech line {chain} dropped: {ms} ms after the line, {wait} ms waiting"); return "late"; }
            if (!Subtitles.ClaimSpeech(chain)) { Dropped++; return "already spoken"; }
            Put(pcm, rate);
            Accepted++;
            Log.Add($"pc speech line {chain}: {pcm.Length / 2 * 1000L / rate} ms of sound, {ms} ms after the line appeared" + (wait > 0 ? $", starts in {wait} ms" : ""));
            return "ok " + wait;
        }

        // One piece of a line. id 0 = a line the phone heard (no subtitle job). sid 0 = the whole
        // line at once. Otherwise piece 0 goes through the usual checks and the later pieces of
        // the same sid simply follow it (or are refused with it).
        public static string Say(int id, int rate, long sid, int part, byte[] pcm)
        {
            if (sid != 0 && part > 0)
            {
                lock (_lock) if (sid != _okSid) return "refused";
                if (pcm == null || pcm.Length < 400 || rate < 8000 || rate > 48000) return "empty";
                Put(pcm, rate);
                return "ok";
            }
            string answer = id == 0 ? Free(rate, pcm) : FromPhone(id, rate, pcm);
            if (sid != 0) lock (_lock) { if (answer == "ok") _okSid = sid; else _noSid = sid; }
            return answer;
        }

        // A line that belongs to no subtitle: speech the phone heard in the game's sound and
        // translated. Not said when the clips already waiting would make it more than 4 s late.
        public static string Free(int rate, byte[] pcm)
        {
            if (pcm == null || pcm.Length < 400 || rate < 8000 || rate > 48000) return "empty";
            long wait;
            lock (_lock) wait = (_ownTo - DateTime.UtcNow.Ticks) / TimeSpan.TicksPerMillisecond;
            if (wait > 4000) { Dropped++; Log.Add($"heard speech dropped: {wait} ms of speech already waiting"); return "busy"; }
            Put(pcm, rate);
            Accepted++;
            Log.Add($"heard speech: {pcm.Length / 2 * 1000L / rate} ms of sound" + (wait > 0 ? $", after {wait} ms" : ""));
            return "ok";
        }

        // A short test tone through the same path (no phone needed).
        public static string Test(double hz, int ms)
        {
            const int rate = 22050;
            int n = rate * Math.Max(100, Math.Min(ms, 3000)) / 1000;
            var pcm = new byte[n * 2];
            for (int i = 0; i < n; i++)
            {
                double fade = Math.Min(1, Math.Min(i, n - i) / 400.0);
                short v = (short)(Math.Sin(2 * Math.PI * hz * i / rate) * 9000 * fade);
                pcm[i * 2] = (byte)v; pcm[i * 2 + 1] = (byte)(v >> 8);
            }
            Put(pcm, rate);
            return "ok " + Seq;
        }

        // When our own spoken line is coming out of the TV: the copy of the TV's sound contains it
        // too, so a reading of the character's voice taken then would hear us instead.
        static long _ownFrom, _ownTo;
        public static bool OwnVoiceDuring(long from, long to)
        {
            lock (_lock) return from < _ownTo && to > _ownFrom;
        }

        static void Put(byte[] pcm, int rate)
        {
            long now = DateTime.UtcNow.Ticks;
            lock (_lock)
            {
                // Lines queue behind each other on the TV; the overlay starts ~0.1 s after this.
                long start = Math.Max(now + TimeSpan.TicksPerMillisecond * 100, _ownTo);
                if (_ownTo < now) _ownFrom = start;
                _ownTo = start + (long)(pcm.Length / 2) * TimeSpan.TicksPerSecond / rate;
            }
            var ms = new MemoryStream(44 + pcm.Length);
            var w = new BinaryWriter(ms);
            w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + pcm.Length); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
            w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2);
            w.Write((short)2); w.Write((short)16); w.Write(Encoding.ASCII.GetBytes("data")); w.Write(pcm.Length); w.Write(pcm);
            lock (_lock) { _seq++; _wavs[_seq] = ms.ToArray(); _wavs.Remove(_seq - 16); }
            Subtitles.Nudge();
        }

        public static byte[] Wav(int n)
        {
            lock (_lock) return _wavs.TryGetValue(n, out var wav) ? wav : null;
        }
    }
}

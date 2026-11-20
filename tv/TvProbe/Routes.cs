using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Text;

namespace TvProbe
{
    class Routes : IRoutes
    {
        // Folders searched for capture-related system files.
        static readonly string[] SearchDirs =
        {
            "/usr/lib", "/usr/lib64", "/lib", "/usr/share/dotnet.tizen/framework",
            "/usr/share/dotnet.tizen/lib", "/usr/lib/mde-framework",
        };

        // Name fragments (lower case) that make a file interesting.
        static readonly string[] Interesting =
        {
            "video-capture", "videocapture", "video_capture", "videoenhance", "contentanalysis",
            "content-analysis", "capi-screen", "screen-capture", "screencapture", "mde-framework",
            "mde-service", "tizen.tv.", "capture", "subtitle", "screen-analysis", "tdm", "avoc", "vdo",
        };

        public Response Handle(Request r)
        {
            switch (r.Path)
            {
                case "/": return Response.Html(Index());
                case "/report": return Response.Text(Report.Build());
                case "/log": return Response.Text(Log.Text());
                case "/subtitle":
                    // ?seq=N&wait=ms: long poll, answers as soon as the subtitle changes.
                    return new Response
                    {
                        ContentType = "application/json; charset=utf-8",
                        Body = System.Text.Encoding.UTF8.GetBytes(Subtitles.Poll(int.Parse(r.Get("seq", "-1")), int.Parse(r.Get("pseq", "-1")), int.Parse(r.Get("wait", "0")))),
                    };
            }

            if (r.Path == "/speech.wav")
            {
                var wav = Speech.Wav(int.Parse(r.Get("n", "0")));
                return wav == null ? Response.Text("gone", 404) : new Response { ContentType = "audio/wav", Body = wav };
            }

            if (r.Path == "/sndr")
            {
                Log.Add("overlay sound: " + r.Get("msg", ""));
                return Response.Text("ok");
            }

            if (r.Path == "/sources")
            {
                Inputs.Report(r.Get("list", ""), int.TryParse(r.Get("cur", "0"), out int cur) ? cur : 0);
                return Response.Text("ok");
            }

            // Everything below can read files or run code: needs the key.
            if (r.Get("k") != App.Key) return Response.Text("missing or wrong key (?k=...)", 403);

            switch (r.Path)
            {
                case "/config":
                    foreach (var kv in r.Query) if (kv.Key != "k") Settings.Set(kv.Key, kv.Value[0]);
                    return Response.Text(Settings.Describe());
                case "/job":
                    if (r.Get("voice") == "1") System.Threading.Interlocked.Exchange(ref Subtitles.VoiceWantedTicks, DateTime.UtcNow.Ticks);
                    var job = Phone.WaitJob(int.Parse(r.Get("wait", "10000")), r.Get("dev", ""));
                    if (job == null) return new Response { Status = 204, Body = new byte[0] };
                    // fmt=raw: the crop as plain 8-bit gray bytes (small and no work for the TV);
                    // the phone enlarges it itself. Older app versions get an enlarged PNG in JSON.
                    if (r.Get("fmt") == "raw")
                        return new Response { ContentType = "application/octet-stream", Body = job.Crop }
                            .Header("X-Job", job.Id + "," + job.W + "," + job.H);
                    return new Response
                    {
                        ContentType = "application/json",
                        Body = System.Text.Encoding.UTF8.GetBytes("{" + $"\"id\":{job.Id},\"x\":{job.X},\"y\":{job.Y},\"w\":{job.W},\"h\":{job.H}," +
                            "\"png\":\"" + Convert.ToBase64String(Subtitles.JobPng(job)) + "\"}"),
                    };
                case "/result":
                    return Response.Text(Phone.Result(int.Parse(r.Get("id", "0")), r.Get("tr", ""), r.Get("en", ""),
                        long.Parse(r.Get("ocr", "0")), long.Parse(r.Get("tl", "0")), r.Get("final", "1") != "0"));
                case "/phone": return Response.Text(Phone.Status());
                case "/inputs": return new Response { ContentType = "application/json", Body = System.Text.Encoding.UTF8.GetBytes(Inputs.Json()) };
                case "/demo":
                    return Response.Text(Subtitles.Demo(r.Get("tr", "Deneme satırı"), int.Parse(r.Get("x", "330")), int.Parse(r.Get("y", "476")),
                        int.Parse(r.Get("w", "300")), int.Parse(r.Get("h", "22")), int.Parse(r.Get("ms", "8000"))));
                case "/crop.png":
                    var cp = Subtitles.JobPng(Phone.Last);
                    return cp == null ? Response.Text("no crop yet", 404) : new Response { ContentType = "image/png", Body = cp };
                case "/band.png":
                    var png = Subtitles.BandPng();
                    return png == null ? Response.Text("no frame", 500) : new Response { ContentType = "image/png", Body = png };
                case "/capture": return Response.Text(Capture.Grab(r.Get("mode", "main"), int.Parse(r.Get("w", "960")), int.Parse(r.Get("h", "540")), r.Get("lock") == "1"));
                case "/frame.bmp": return Capture.Bmp();
                case "/sound": return Response.Text(Subtitles.Sound(r.Get("p", "osc,440,1500,0.3")));
                case "/audiotap":
                    return Response.Text(AudioTap.Measure(int.Parse(r.Get("dev", "0")), Math.Min(int.Parse(r.Get("ms", "3000")), 8000),
                        double.Parse(r.Get("tone", "0"), System.Globalization.CultureInfo.InvariantCulture)));
                case "/lines":
                    // The computer that speaks the lines waits here for the next one.
                    return new Response
                    {
                        ContentType = "application/json; charset=utf-8",
                        Body = System.Text.Encoding.UTF8.GetBytes(Subtitles.Lines(int.Parse(r.Get("after", "-1")), int.Parse(r.Get("wait", "8000")))),
                    };
                case "/say":
                    {
                        // line=N&t=ticks: from the computer (a line of /lines).
                        if (r.Get("line") != null)
                            return Response.Text(Speech.FromPc(int.Parse(r.Get("line")), long.Parse(r.Get("t", "0")), int.Parse(r.Get("rate", "44100")), r.Body));
                        // id=0: a line the phone heard rather than read (no subtitle job behind it).
                        int sayId = int.Parse(r.Get("id", "0")), sayRate = int.Parse(r.Get("rate", "22050"));
                        return Response.Text(Speech.Say(sayId, sayRate, long.Parse(r.Get("sid", "0")), int.Parse(r.Get("part", "0")), r.Body));
                    }
                case "/split":
                    // on=1: our voice on the right channel, listening on the left (see AudioTap.Split).
                    if (r.Get("on") != null) AudioTap.Split = r.Get("on") == "1";
                    Subtitles.Nudge();
                    return Response.Text("split " + (AudioTap.Split ? 1 : 0));
                case "/voice":
                    {
                        // The sound around the moment a line appeared (see AudioTap.Around).
                        var vj = Phone.Find(int.Parse(r.Get("id", "0")));
                        // t=ticks: the moment itself (the computer knows it from /lines).
                        long given = long.Parse(r.Get("t", "0"));
                        if (given != 0 && Math.Abs(DateTime.UtcNow.Ticks - given) > 20 * TimeSpan.TicksPerSecond) return new Response { Status = 204, Body = new byte[0] };
                        // test=1: no line needed, the moment is "0.6 s ago" (to check the copy works).
                        if (vj == null && given == 0 && r.Get("test") != "1") return new Response { Status = 204, Body = new byte[0] };
                        long moment = given != 0 ? given : vj != null ? vj.Created : DateTime.UtcNow.Ticks - 600 * TimeSpan.TicksPerMillisecond;
                        int before = Math.Min(int.Parse(r.Get("before", "200")), 1000), after = Math.Min(int.Parse(r.Get("after", "350")), 2000);
                        var pcm = AudioTap.Around(moment, before, after, after + 1200);
                        if (pcm == null) return new Response { Status = 204, Body = new byte[0] };
                        bool own = !AudioTap.Split && Speech.OwnVoiceDuring(moment - before * TimeSpan.TicksPerMillisecond, moment + after * TimeSpan.TicksPerMillisecond);
                        return new Response { ContentType = "application/octet-stream", Body = pcm }
                            .Header("X-Voice", AudioTap.RingRate + "," + (own ? 1 : 0));
                    }
                case "/listen":
                    {
                        // The game sound as a running stream for the phone (16 kHz mono).
                        var chunk = AudioTap.Since(long.Parse(r.Get("epoch", "0")), long.Parse(r.Get("from", "0")),
                            Math.Min(int.Parse(r.Get("wait", "1500")), 5000), out long ep, out long first, out long next, out long t0, out long t1);
                        bool ours = !AudioTap.Split && chunk.Length > 0 && Speech.OwnVoiceDuring(t0, t1);
                        return new Response { ContentType = "application/octet-stream", Body = chunk }
                            .Header("X-Audio", AudioTap.RingRate + "," + ep + "," + first + "," + next + "," + (ours ? 1 : 0));
                    }
                case "/note":
                    Log.Add("phone: " + r.Get("msg", ""));
                    return Response.Text("ok");
                case "/saytest":
                    return Response.Text(Speech.Test(double.Parse(r.Get("hz", "880"), System.Globalization.CultureInfo.InvariantCulture), int.Parse(r.Get("ms", "700"))));
            }
            return Response.Text("not found", 404);
        }

        static string Index()
        {
            string k = WebUtility.UrlEncode(App.Key);
            var sb = new StringBuilder();
            sb.Append("<html><body style='font-family:sans-serif'><h2>TV Probe</h2><ul>");
            sb.Append("<li><a href='/report'>report</a> (no key needed)</li>");
            sb.Append("<li><a href='/log'>log</a></li>");
            sb.Append("<li>with key: /phone, /capture, /frame.bmp, /band.png, /crop.png, /config</li>");
            sb.Append("</ul></body></html>");
            return sb.ToString();
        }

        public static List<string> Candidates()
        {
            var found = new SortedSet<string>();
            foreach (var dir in SearchDirs)
            {
                if (!Directory.Exists(dir)) continue;
                IEnumerable<string> files;
                try { files = Directory.EnumerateFiles(dir); } catch { continue; }
                foreach (var f in files)
                {
                    var n = Path.GetFileName(f).ToLowerInvariant();
                    if (Interesting.Any(i => n.Contains(i))) found.Add(f);
                }
            }
            return found.ToList();
        }

    }
}

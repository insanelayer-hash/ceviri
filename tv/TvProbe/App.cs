using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using Tizen.Applications;

namespace TvProbe
{
    // Background service (starts on TV boot). Everything happens over HTTP on port 8090:
    //   http://<tv-ip>:8090/            report + links
    //   /bundle?k=KEY                   zip of the capture-related system files
    //   /fs/ls, /fs/get, /m/*, /n/*     file, reflection and native exploration (see Http.cs)
    class App : ServiceApplication
    {
        public static int Port = 8090;
        public static string Key = "";
        public static string ResDir = "";
        public static string DataDir = "";
        private HttpServer _server;

        protected override void OnCreate()
        {
            base.OnCreate();
            try
            {
                ResDir = DirectoryInfo.Resource;
                DataDir = DirectoryInfo.Data;
                var cfg = File.ReadAllText(Path.Combine(ResDir, "probe.json"));
                var m = Regex.Match(cfg, "\"port\"\\s*:\\s*(\\d+)");
                if (m.Success) Port = int.Parse(m.Groups[1].Value);
                m = Regex.Match(cfg, "\"key\"\\s*:\\s*\"([^\"]*)\"");
                if (m.Success) Key = m.Groups[1].Value;
            }
            catch (Exception ex) { Log.Add("config: " + ex.Message); }

            Settings.Load();
            Subtitles.Start();
            _server = new HttpServer(Port, new Routes());
            var t = new Thread(_server.Run) { IsBackground = true, Name = "http" };
            t.Start();
            Log.Add($"listening on {Port}");
        }

        protected override void OnTerminate()
        {
            _server?.Stop();
            base.OnTerminate();
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }

    static class Log
    {
        static readonly System.Collections.Generic.List<string> _lines = new System.Collections.Generic.List<string>();
        public static void Add(string s)
        {
            lock (_lines)
            {
                _lines.Add(DateTime.Now.ToString("HH:mm:ss.fff") + " " + s);
                if (_lines.Count > 500) _lines.RemoveAt(0);
            }
        }
        public static string Text()
        {
            lock (_lines) return string.Join("\n", _lines);
        }
    }
}

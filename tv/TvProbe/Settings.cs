using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace TvProbe
{
    // Persistent key=value settings in the app's data folder, changed over HTTP (/config) so
    // the API key and tuning values never need a rebuild.
    static class Settings
    {
        static readonly Dictionary<string, string> _v = new Dictionary<string, string>
        {
            ["y0"] = "0.78",     // subtitle band, fractions of the frame
            ["y1"] = "0.98",
            ["delta"] = "30",    // a text stroke is this much brighter than pixels on both sides
            ["minstrokes"] = "45",
            ["interval"] = "40",  // ms between captures
        };

        static string FilePath => Path.Combine(App.DataDir, "settings.txt");

        public static void Load()
        {
            try
            {
                if (!File.Exists(FilePath)) return;
                foreach (var line in File.ReadAllLines(FilePath))
                {
                    int e = line.IndexOf('=');
                    if (e > 0) lock (_v) _v[line.Substring(0, e)] = line.Substring(e + 1);
                }
            }
            catch (Exception ex) { Log.Add("settings load: " + ex.Message); }

            // Cloud translation was removed: drop any API keys stored by older versions.
            bool removed = false;
            lock (_v)
                foreach (var old in new[] { "gemini", "groq", "groqmodel", "model", "provider", "res", "thr" })
                    removed |= _v.Remove(old);
            if (removed) Set("interval", Get("interval"));   // rewrites the file without them

            // 1.2: faster capture loop and short lines ("No.", "Okay."); replace the values
            // stored by older versions once.
            if (Num("rev", 0) < 2)
            {
                lock (_v) { _v["interval"] = "40"; _v["minstrokes"] = "45"; }
                Set("rev", "2");
            }
        }

        public static void Set(string key, string value)
        {
            lock (_v)
            {
                _v[key] = value;
                try
                {
                    var lines = new List<string>();
                    foreach (var kv in _v) lines.Add(kv.Key + "=" + kv.Value);
                    File.WriteAllLines(FilePath, lines);
                }
                catch (Exception ex) { Log.Add("settings save: " + ex.Message); }
            }
        }

        public static string Get(string key)
        {
            lock (_v) return _v.TryGetValue(key, out var v) ? v : "";
        }

        public static double Num(string key, double def)
        {
            return double.TryParse(Get(key), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : def;
        }

        public static string Describe()
        {
            lock (_v)
            {
                var parts = new List<string>();
                foreach (var kv in _v)
                {
                    string v = kv.Value;
                    parts.Add(kv.Key + "=" + v);
                }
                return string.Join("\n", parts);
            }
        }
    }
}

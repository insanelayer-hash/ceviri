using System;
using System.Globalization;
using System.Text;

namespace TvProbe
{
    // Just enough JSON for the HTTP endpoints (netstandard2.1 has no System.Text.Json).
    static class Json
    {
        public static string Esc(string s)
        {
            if (s == null) return "null";
            var sb = new StringBuilder("\"");
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        // Value of the first string property named `key` at or after `from`, or null.
        public static string Str(string json, string key, int from = 0)
        {
            if (json == null) return null;
            string pat = "\"" + key + "\"";
            int i = json.IndexOf(pat, from, StringComparison.Ordinal);
            while (i >= 0)
            {
                int j = i + pat.Length;
                while (j < json.Length && char.IsWhiteSpace(json[j])) j++;
                if (j < json.Length && json[j] == ':')
                {
                    j++;
                    while (j < json.Length && char.IsWhiteSpace(json[j])) j++;
                    if (j < json.Length && json[j] == '"') return ReadString(json, j, out _);
                }
                i = json.IndexOf(pat, i + 1, StringComparison.Ordinal);
            }
            return null;
        }

        public static string ReadString(string s, int quote, out int end)
        {
            var sb = new StringBuilder();
            int i = quote + 1;
            while (i < s.Length && s[i] != '"')
            {
                char c = s[i];
                if (c == '\\' && i + 1 < s.Length)
                {
                    char n = s[++i];
                    switch (n)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            if (i + 4 < s.Length) { sb.Append((char)int.Parse(s.Substring(i + 1, 4), NumberStyles.HexNumber)); i += 4; }
                            break;
                        default: sb.Append(n); break;
                    }
                }
                else sb.Append(c);
                i++;
            }
            end = i;
            return sb.ToString();
        }
    }
}

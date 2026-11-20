using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace TvProbe
{
    class Request
    {
        public string Path = "/";
        public byte[] Body = new byte[0];   // POST body, if any
        public Dictionary<string, List<string>> Query = new Dictionary<string, List<string>>();

        public string Get(string name, string def = null)
        {
            return Query.TryGetValue(name, out var v) && v.Count > 0 ? v[0] : def;
        }

        public List<string> All(string name)
        {
            return Query.TryGetValue(name, out var v) ? v : new List<string>();
        }
    }

    class Response
    {
        public int Status = 200;
        public string ContentType = "text/plain; charset=utf-8";
        public byte[] Body;
        public string FilePath;      // streamed instead of Body when set
        public string DownloadName;  // Content-Disposition attachment
        public List<KeyValuePair<string, string>> Headers;   // extra response headers

        public Response Header(string name, string value)
        {
            (Headers ??= new List<KeyValuePair<string, string>>()).Add(new KeyValuePair<string, string>(name, value));
            return this;
        }

        public static Response Text(string s, int status = 200)
        {
            return new Response { Status = status, Body = Encoding.UTF8.GetBytes(s ?? "") };
        }

        public static Response Html(string s)
        {
            return new Response { ContentType = "text/html; charset=utf-8", Body = Encoding.UTF8.GetBytes(s) };
        }

        public static Response Bytes(byte[] b, string name)
        {
            return new Response { ContentType = "application/octet-stream", Body = b, DownloadName = name };
        }
    }

    interface IRoutes
    {
        Response Handle(Request req);
    }

    class HttpServer
    {
        readonly int _port;
        readonly IRoutes _routes;
        TcpListener _listener;
        volatile bool _stop;

        public HttpServer(int port, IRoutes routes)
        {
            _port = port;
            _routes = routes;
        }

        public void Stop()
        {
            _stop = true;
            try { _listener?.Stop(); } catch { }
        }

        // The phone sends a one-byte datagram here many times a second while translating.
        // Nothing is done with it: sending keeps the phone's Wi-Fi radio awake, so a new
        // line reaches it without waiting for the radio's next wake-up.
        void Sink()
        {
            try
            {
                using var udp = new UdpClient(_port);
                var from = new IPEndPoint(IPAddress.Any, 0);
                while (!_stop) udp.Receive(ref from);
            }
            catch (Exception ex) { Log.Add("udp: " + ex.Message); }
        }

        public void Run()
        {
            new Thread(Sink) { IsBackground = true, Name = "udp-sink" }.Start();
            while (!_stop)
            {
                try
                {
                    _listener = new TcpListener(IPAddress.Any, _port);
                    _listener.Start();
                    while (!_stop)
                    {
                        var client = _listener.AcceptTcpClient();
                        // One thread per connection: long polls (/job, /subtitle) park here for
                        // seconds, which would starve the shared thread pool and stall
                        // every other request.
                        new Thread(() => Serve(client), 256 * 1024) { IsBackground = true, Name = "http-conn" }.Start();
                    }
                }
                catch (Exception ex)
                {
                    Log.Add("listener: " + ex.Message);
                    try { _listener?.Stop(); } catch { }
                    Thread.Sleep(3000);
                }
            }
        }

        // One connection can carry many requests (HTTP keep-alive): the phone and the overlay
        // talk to this server several times a second, and opening a new connection for each
        // message costs a round trip every time.
        void Serve(TcpClient client)
        {
            using (client)
            {
                try
                {
                    client.ReceiveTimeout = 60000;
                    client.SendTimeout = 10000;
                    client.NoDelay = true;
                    var stream = client.GetStream();
                    var input = new BufferedStream(stream, 8192);
                    while (!_stop)
                    {
                        var req = Parse(input, out bool ended, out bool keep);
                        if (ended) return;      // the other side closed the connection
                        Response res;
                        if (req == null) { res = Response.Text("bad request", 400); keep = false; }
                        else
                        {
                            try { res = _routes.Handle(req); }
                            catch (Exception ex) { res = Response.Text("error: " + ex, 500); }
                        }
                        Write(stream, res, keep);
                        if (!keep) return;
                    }
                }
                catch (IOException) { }         // idle too long, or the other side went away
                catch (Exception ex) { Log.Add("serve: " + ex.Message); }
            }
        }

        static Request Parse(Stream stream, out bool ended, out bool keep)
        {
            // Read the header block byte by byte.
            ended = false; keep = false;
            var sb = new StringBuilder();
            int b;
            while ((b = stream.ReadByte()) != -1)
            {
                sb.Append((char)b);
                if (sb.Length >= 4 && sb.ToString(sb.Length - 4, 4) == "\r\n\r\n") break;
                if (sb.Length > 600000) return null;
            }
            if (sb.Length == 0) { ended = true; return null; }
            var lines = sb.ToString().Split(new[] { "\r\n" }, StringSplitOptions.None);
            var parts = lines[0].Split(' ');
            if (parts.Length < 2) return null;
            keep = parts.Length >= 3 && parts[2].Trim() == "HTTP/1.1";
            for (int i = 1; i < lines.Length; i++)
                if (lines[i].StartsWith("Connection:", StringComparison.OrdinalIgnoreCase) &&
                    lines[i].IndexOf("close", StringComparison.OrdinalIgnoreCase) >= 0) keep = false;
            var target = parts[1];
            var req = new Request();
            // A body (the phone uploads spoken lines): read exactly Content-Length bytes.
            for (int i = 1; i < lines.Length; i++)
                if (lines[i].StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase) &&
                    int.TryParse(lines[i].Substring(15).Trim(), out int len) && len > 0)
                {
                    if (len > 4 * 1024 * 1024) return null;
                    var body = new byte[len];
                    int got = 0, n;
                    while (got < len && (n = stream.Read(body, got, len - got)) > 0) got += n;
                    if (got < len) { ended = true; return null; }
                    req.Body = body;
                }
            int q = target.IndexOf('?');
            req.Path = Uri.UnescapeDataString(q >= 0 ? target.Substring(0, q) : target);
            if (q >= 0)
            {
                foreach (var pair in target.Substring(q + 1).Split('&'))
                {
                    if (pair.Length == 0) continue;
                    int e = pair.IndexOf('=');
                    string k = Uri.UnescapeDataString((e >= 0 ? pair.Substring(0, e) : pair).Replace('+', ' '));
                    string v = e >= 0 ? Uri.UnescapeDataString(pair.Substring(e + 1).Replace('+', ' ')) : "";
                    if (!req.Query.TryGetValue(k, out var list)) req.Query[k] = list = new List<string>();
                    list.Add(v);
                }
            }
            return req;
        }

        static void Write(NetworkStream stream, Response res, bool keep)
        {
            long length = res.FilePath != null ? new FileInfo(res.FilePath).Length : (res.Body?.Length ?? 0);
            var head = new StringBuilder();
            head.Append("HTTP/1.1 ").Append(res.Status).Append(res.Status == 200 ? " OK" : res.Status == 204 ? " No Content" : " ERR").Append("\r\n");
            head.Append("Content-Type: ").Append(res.ContentType).Append("\r\n");
            head.Append("Content-Length: ").Append(length).Append("\r\n");
            head.Append("Access-Control-Allow-Origin: *\r\n");
            if (res.DownloadName != null)
                head.Append("Content-Disposition: attachment; filename=\"").Append(res.DownloadName).Append("\"\r\n");
            if (res.Headers != null)
                foreach (var h in res.Headers) head.Append(h.Key).Append(": ").Append(h.Value).Append("\r\n");
            head.Append(keep ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n");
            var hb = Encoding.ASCII.GetBytes(head.ToString());
            if (res.FilePath != null)
            {
                stream.Write(hb, 0, hb.Length);
                using var fs = File.OpenRead(res.FilePath);
                fs.CopyTo(stream);
            }
            else
            {
                // Header and body in one write, so the body never waits behind the header
                // for the other side's delayed ACK.
                int bl = res.Body?.Length ?? 0;
                var all = new byte[hb.Length + bl];
                Buffer.BlockCopy(hb, 0, all, 0, hb.Length);
                if (bl > 0) Buffer.BlockCopy(res.Body, 0, all, hb.Length, bl);
                stream.Write(all, 0, all.Length);
            }
            stream.Flush();
        }
    }
}

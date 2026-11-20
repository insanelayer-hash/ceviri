"""A stand-in for the TV, to try the computer's speaking program (zb_pc_voice.cpp) without a TV or a game.

usage: mock_tv.py <port> <speech.wav> <gap seconds> <result file> [folder for the received sound]

Announces four Turkish lines `gap` seconds apart (/lines), answers /voice with a piece of <speech.wav>
(lines 1 and 3 as it is, lines 2 and 4 raised in pitch: "two characters") and notes what arrives at /say.
Ends when all four lines have been spoken or after a time limit; the result file says how it went.
"""
import json, struct, sys, threading, time, wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

port, wav_path, gap, result_path = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), sys.argv[4]
dump = sys.argv[5] if len(sys.argv) > 5 else ""   # a folder for the sound that arrives (16-bit, 44.1 kHz)
with wave.open(wav_path) as w:
    rate = w.getframerate()
    src = struct.unpack("<%dh" % w.getnframes(), w.readframes(w.getnframes()))

def voice(step, seconds):
    """16 kHz samples: every `step`-th source sample (a bigger step = a higher voice)."""
    out, pos = [], rate * 0.5
    for _ in range(int(16000 * seconds)):
        out.append(src[int(pos) % len(src)])
        pos += step
    return struct.pack("<%dh" % len(out), *out)

def ticks(t): return int(t * 1e7) + 621355968000000000
# (text when the line appears, final?, the final text that replaces it after 0.3 s or None)
SCRIPT = [("Merhaba. Joey burada.", True, None),
          ("Hey Joey bekle biraz", False, "Hey, Joey, bekle biraz."),        # a quick translation, then the natural one
          ("JASON: Evet. İki dakika.", True, None),                           # a speaker's label is not read out
          ("Bunu daha önce de konuşmuştuk, değil mi?", False, None)]          # the natural one never comes
# The lines start two seconds after the program first asks for them (it loads its models before that).
lines = [{"line": 100 + i, "at": float("inf"), "script": SCRIPT[i]} for i in range(4)]
begun = time.time()
said, notes, lock = [], [], threading.Lock()

def feed(now):
    """What the TV would hold now: per line its newest text, numbered in the order the texts appeared."""
    events = []
    for l in lines:
        text, final, later = l["script"]
        if l["at"] <= now: events.append((l["at"], l, text, final))
        if later is not None and l["at"] + 0.3 <= now: events.append((l["at"] + 0.3, l, later, True))
    events.sort(key=lambda e: e[0])
    state = {}
    for n, (at, l, text, final) in enumerate(events, 1): state[l["line"]] = {"n": n, "line": l["line"], "t": str(ticks(l["at"])), "age": int((now - l["at"]) * 1000), "final": 1 if final else 0, "tr": text}
    return len(events), sorted(state.values(), key=lambda e: e["n"])

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, body, ctype="text/plain", extra=None, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if q.get("k") != "test": return self.reply(b"missing or wrong key", status=403)
        if u.path == "/lines":
            with lock:
                if lines[0]["at"] == float("inf"):
                    for i, l in enumerate(lines): l["at"] = time.time() + 2 + i * gap
            after, wait = int(q.get("after", -1)), int(q.get("wait", 8000)) / 1000
            deadline = time.time() + wait
            while True:
                now = time.time()
                n, state = feed(now)
                if after < 0 or after > n: return self.reply(json.dumps({"n": n, "lines": []}).encode(), "application/json")
                new = [e for e in state if e["n"] > after]
                if new or now >= deadline: return self.reply(json.dumps({"n": n, "lines": new}).encode(), "application/json")
                time.sleep(0.02)
        if u.path == "/voice":
            t = int(q["t"]); l = next((l for l in lines if ticks(l["at"]) == t), None)
            if l is None: return self.reply(b"", status=204)
            before, after = int(q.get("before", 200)), int(q.get("after", 350))
            end = l["at"] + after / 1000
            while time.time() < end: time.sleep(0.01)
            pcm = voice(rate / 16000 * (1.3 if l["line"] % 2 else 1.0), (before + after) / 1000)
            return self.reply(pcm, "application/octet-stream", {"X-Voice": "16000,0"})
        self.reply(b"not found", status=404)
    def do_POST(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if u.path == "/say" and q.get("k") == "test":
            l = next((l for l in lines if l["line"] == int(q.get("line", 0))), None)
            with lock: said.append((int(q.get("line", 0)), len(body) / 2 / int(q.get("rate", 44100)), (time.time() - l["at"]) if l else -1))
            if dump: open("%s/said-%s.pcm" % (dump, q.get("line", "0")), "wb").write(body)
            return self.reply(b"ok 0")
        self.reply(b"not found", status=404)

srv = ThreadingHTTPServer(("127.0.0.1", port), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
while len(said) < 4:
    first = lines[0]["at"]
    if (first == float("inf") and time.time() > begun + 300) or time.time() > first + 4 * gap + 60: break
    time.sleep(0.2)
time.sleep(4)   # let the last lesson be learned
with open(result_path, "w") as f:
    for line, seconds, late in said: f.write("line %d: %.2f s of sound, %.2f s after it appeared\n" % (line, seconds, late))
    f.write("OK\n" if len(said) == 4 and all(s > 0.3 for _, s, _ in said) else "FAILED: %d of 4 lines spoken\n" % len(said))
print(open(result_path).read())
sys.exit(0 if len(said) == 4 else 1)

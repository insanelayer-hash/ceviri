"""Speaks the Turkish test lines through ZONOS3-Mini's own server (the path Zyphra's playground uses)
and saves one WAV per line and setting, so they can be compared by ear with the app's present path.

usage: server_check.py <base url> <voice .npy> <lines file> <out dir> [<work dir of voice_match.py>]
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
import wave

base, voice_path, lines_path, out = sys.argv[1:5]
voice = base64.b64encode(open(voice_path, "rb").read()).decode()
lines = [l.strip() for l in open(lines_path, encoding="utf-8") if l.strip()]


def call(path, body=None, timeout=600):
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


for attempt in range(180):
    try:
        call("/v2/health", timeout=5).read()
        break
    except Exception:
        time.sleep(1)
else:
    sys.exit("the server did not start")

caps = json.load(call("/v2/capabilities"))
print("alignment heads for:", caps.get("laci_languages"))
print("Turkish text preparation:", "tr" in (caps.get("text_norm_languages") or []))
print("decoders:", caps.get("decoders"))
print("pause tokens:", caps.get("pause_tokens"), "| start token:", caps.get("start_token"))
print("voice modes:", caps.get("speaker_modes"), "| silence before speech:", caps.get("silence_prefill"))


def request(text, **extra):
    body = {"text": text, "language": "tr", "seed": 7, "speaker_mode": "embedding", "speaker_embedding_base64": voice,
            "condition_values": {"loudness": -17.0, "fmax": 20000.0, "speaking_rate": 20.0}}
    body.update(extra)
    return body


settings = [
    ("2-sunucu", {}),                 # the server as it comes: text preparation, short lines guarded
    ("3-hizalama", {"laci": True}),   # plus the alignment guard on every line
]
for i, text in enumerate(lines, 1):
    for tag, extra in settings:
        name = f"cumle{i}-{tag}"
        t0 = time.time()
        try:
            data = call("/v2/generate", request(text, stream=False, format="wav", **extra)).read()
        except urllib.error.HTTPError as e:
            print(f"{name}: FAILED {e.code} {e.read()[:300]!r}")
            continue
        took = time.time() - t0
        path = f"{out}/{name}.wav"
        open(path, "wb").write(data)
        with wave.open(path) as w:
            seconds = w.getnframes() / w.getframerate()
        print(f"{name}: {seconds:.2f} s of sound in {took:.2f} s ({took / seconds:.2f}x real time)  | {text}")

# How soon the first sound arrives when the server sends the audio piece by piece.
pieces = settings + [("hizalama, sessizlik olmadan", {"laci": True, "start_immediately": True})]
if not caps.get("start_token"):
    pieces = settings
for tag, extra in pieces:
    text = lines[3]
    t0 = time.time()
    try:
        r = call("/v2/generate", request(text, stream=True, format="pcm", **extra))
        first = None
        total = 0
        while True:
            chunk = r.read(4096)
            if not chunk:
                break
            if first is None:
                first = time.time() - t0
            total += len(chunk)
        took = time.time() - t0
        seconds = total / 4 / 44100
        print(f"piece by piece, {tag}: first sound after {first * 1000:.0f} ms, {seconds:.2f} s of sound in {took:.2f} s")
    except urllib.error.HTTPError as e:
        print(f"piece by piece, {tag}: FAILED {e.code} {e.read()[:300]!r}")

# A Turkish line in voices the speaker encoder heard for two seconds (voice_match.py), clean and with noise under it.
work = sys.argv[5] if len(sys.argv) > 5 else ""
if work and os.path.exists(work + "/picked.txt"):
    for name in open(work + "/picked.txt").read().split():
        for tag, file in (("1-turkce", f"heard-{name}.npy"), ("2-turkce-gurultulu-kayittan", f"heard-noisy-{name}.npy")):
            body = request(lines[3], stream=False, format="wav", laci=True)
            body["speaker_embedding_base64"] = base64.b64encode(open(f"{work}/{file}", "rb").read()).decode()
            try:
                data = call("/v2/generate", body).read()
            except urllib.error.HTTPError as e:
                print(f"ses-{name}-{tag}: FAILED {e.code} {e.read()[:300]!r}")
                continue
            open(f"{out}/ses-{name}-{tag}.wav", "wb").write(data)
            print(f"ses-{name}-{tag}: written")

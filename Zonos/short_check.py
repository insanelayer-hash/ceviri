"""Short lines (three or four words) come out too short and gabbled when produced like long ones.
Tries the settings that might help and prints how long each comes out (about 17-20 characters a
second is what full sentences get).

usage: short_check.py <base url> <voice .npy>
"""
import base64, io, json, sys, urllib.request, wave

base, voice_path = sys.argv[1:3]
voice = base64.b64encode(open(voice_path, "rb").read()).decode()
lines = ["Elbette, iki saniye.", "Merhaba. Joey burada.", "Sarı. Bu Joey.", "Evet. İki dakika.", "Hey, Joey, bekle biraz.",
         "Hey, Joey, arabamı getirmesi için birini gönderir misin?"]
variants = [("hiz20", {"speaking_rate": 20.0}, {}), ("hiz20+koruma", {"speaking_rate": 20.0}, {"laci": True}),
            ("hiz14", {"speaking_rate": 14.0}, {}), ("hiz14+koruma", {"speaking_rate": 14.0}, {"laci": True}),
            ("hiz10+koruma", {"speaking_rate": 10.0}, {"laci": True})]
for text in lines:
    print(f"\n{text}  ({len(text)} characters)")
    for tag, cond, extra in variants:
        out = []
        for seed in (3, 7, 11):
            body = {"text": text, "language": "tr", "seed": seed, "stream": False, "format": "wav", "speaker_mode": "embedding",
                    "speaker_embedding_base64": voice, "condition_values": {"loudness": -17.0, "fmax": 20000.0, **cond}}
            body.update(extra)
            req = urllib.request.Request(base + "/v2/generate", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
            try:
                data = urllib.request.urlopen(req, timeout=300).read()
                with wave.open(io.BytesIO(data)) as w:
                    out.append(w.getnframes() / w.getframerate())
            except Exception as e:
                out.append(-1)
        print(f"  {tag:14s} " + "  ".join(f"{s:.2f} s ({len(text) / s:.0f}/s)" if s > 0 else "failed" for s in out))

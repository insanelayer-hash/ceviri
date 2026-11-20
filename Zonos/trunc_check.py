"""Does the model's alignment guard (laci) stop lines from losing their end?

usage: trunc_check.py <base url> <built-in voices dir>

The sentences that came out cut short on the user's computer, spoken with the voices used there, each with ten
seeds, once without and once with the guard. Prints how long each comes out; a full reading of the first
sentence takes about three seconds, one that stops after "…getirmesi için" about two.
"""
import base64, io, json, sys, urllib.request, wave

base, voices = sys.argv[1:3]
LINES = [("Hey, Joey, arabamı getirmesi için birini gönderir misin?", 20.0),
         ("Çoğu akşam Thorpe Adventures yakınlarındaki Pelican Vadisi'nde olacağım.", 20.0),
         ("Lütfen görüşün tarihini, saatini ve yerini içeren bir mesaj bırakın,", 20.0),
         ("Acil kokarca maymun bilginiz varsa,", 17.0)]
for name in ("Wyatt", "Gaspard", "Imogen", "Minjun"):
    voice = base64.b64encode(open("%s/%s.npy" % (voices, name), "rb").read()).decode()
    for text, rate in LINES:
        for guard in (False, True):
            out = []
            for seed in range(3, 13):
                body = {"text": text, "language": "tr", "seed": seed, "stream": False, "format": "wav", "speaker_mode": "embedding",
                        "speaker_embedding_base64": voice, "laci": guard,
                        "condition_values": {"loudness": -17.0, "fmax": 20000.0, "speaking_rate": rate}}
                req = urllib.request.Request(base + "/v2/generate", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
                try:
                    data = urllib.request.urlopen(req, timeout=600).read()
                    with wave.open(io.BytesIO(data)) as w: out.append(w.getnframes() / w.getframerate())
                except Exception as e:
                    out.append(-1)
            full = max(out)
            short = sum(1 for s in out if s < 0.8 * full)
            print("%-8s %-5s short %2d/10 | %s | %s" % (name, "guard" if guard else "plain", short, " ".join("%.1f" % s for s in out), text[:40]), flush=True)

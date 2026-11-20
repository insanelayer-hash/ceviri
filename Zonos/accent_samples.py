"""How much of a game character's own voice can go into the Turkish voice before the Turkish suffers?

usage: accent_samples.py <base url> <characters file> <built-in voices dir> <out dir>

For each character of <characters file> (as the computer's program saves them) the same Turkish sentence is
spoken with the character's own voice at 100, 60, 35 and 0 per cent, the rest being the built-in voice nearest
to the character (the mix of zb_pc_voice.cpp). The WAV files are compared by ear.
"""
import base64, glob, io, json, os, sys, urllib.request
import numpy as np

base, cast_path, voices_dir, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
builtin = {os.path.basename(p)[:-4]: np.load(p).astype(np.float32) for p in sorted(glob.glob(voices_dir + "/*.npy"))}
rows = open(cast_path).read().split("\n")[1:]
cast = []
for row in rows:
    f = row.split()
    if len(f) < 196: continue
    total = np.array(f[4:196], dtype=np.float32)
    cast.append((int(f[0]), total * (float(f[1]) / float(f[2])) / max(np.linalg.norm(total), 1e-9)))

def npy(v):
    buf = io.BytesIO(); np.save(buf, v.astype(np.float32)); return base64.b64encode(buf.getvalue()).decode()

TEXT = "Hey, Joey, arabayı getirebilecek birinin var mı? Bir saniye bekle, hemen orada olacak."
for number, heard in cast:
    name = max(builtin, key=lambda n: float(np.dot(builtin[n], heard) / (np.linalg.norm(builtin[n]) * np.linalg.norm(heard))))
    b = builtin[name]
    hn, bn = np.linalg.norm(heard), np.linalg.norm(b)
    for share in (100, 60, 35, 0):
        a = share / 100
        mix = a * heard / hn + (1 - a) * b / bn
        mix = mix * (a * hn + (1 - a) * bn) / np.linalg.norm(mix)
        body = {"text": TEXT, "language": "tr", "seed": 7, "stream": False, "format": "wav", "speaker_mode": "embedding",
                "speaker_embedding_base64": npy(mix), "condition_values": {"loudness": -17.0, "fmax": 20000.0, "speaking_rate": 17.0}}
        req = urllib.request.Request(base + "/v2/generate", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        data = urllib.request.urlopen(req, timeout=600).read()
        path = "%s/karakter%d-kendi-sesi-%03d.wav" % (out, number, share)
        open(path, "wb").write(data)
        print(path, len(data), "nearest built-in voice:", name, flush=True)

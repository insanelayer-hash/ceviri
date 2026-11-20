"""How well does ZONOS3-Mini's speaker encoder recognise a voice from a short clip like the ones the
TV hands to the phone (16 kHz mono, a second or two, sometimes with other sound under it)?

Takes the recordings of the model's default voices, cuts short windows out of them, asks the
speaker encoder (through our bridge, `zb-test embed`) for the speaker vector of each, and prints
how similar windows of the same voice are compared with windows of different voices. Also
writes speaker vectors made from 2-second windows, for a listening test of the Turkish voice.

usage: voice_match.py <zb-test> <spk-encoder.gguf> <default_voices dir> <work dir> <out dir>
"""
import glob
import os
import subprocess
import sys

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

zb_test, encoder, voices_dir, work, out = sys.argv[1:6]
os.makedirs(work, exist_ok=True)
RATE = 16000
rng = np.random.default_rng(1)

voices = {}
for path in sorted(glob.glob(voices_dir + "/**/*.wav", recursive=True)):
    stem = path[:-4]
    if not os.path.exists(stem + ".embedding.npy"):
        continue
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    mono = resample_poly(mono, RATE, rate).astype(np.float32)
    voices[os.path.basename(stem)] = (mono, np.load(stem + ".embedding.npy").astype(np.float32).ravel())
print(f"{len(voices)} voices:", ", ".join(f"{n} ({len(a) / RATE:.1f} s)" for n, (a, _) in voices.items()))


def noisy(x, snr_db):
    """Adds low-passed noise (a stand-in for music and street sound under the speech)."""
    noise = rng.standard_normal(len(x)).astype(np.float32)
    noise = np.convolve(noise, np.ones(24, dtype=np.float32) / 24, mode="same")
    gain = np.sqrt(np.mean(x ** 2) / (np.mean(noise ** 2) * 10 ** (snr_db / 10) + 1e-12))
    return (x + gain * noise).astype(np.float32)


clips = []  # (voice, kind, samples)
for name, (audio, _) in voices.items():
    clips.append((name, "full", audio))
    for seconds in (1.0, 1.5, 2.0, 3.0):
        n = int(seconds * RATE)
        for k, start in enumerate((int(0.3 * RATE), int(0.3 * RATE) + n)):
            if start + n <= len(audio):
                clips.append((name, f"{seconds}s#{k}", audio[start:start + n]))
    n = int(2.0 * RATE)
    if int(0.3 * RATE) + n <= len(audio):
        window = audio[int(0.3 * RATE):int(0.3 * RATE) + n]
        clips.append((name, "2.0s+noise10dB", noisy(window, 10)))
        clips.append((name, "2.0s+noise3dB", noisy(window, 3)))

paths = []
for i, (_, _, samples) in enumerate(clips):
    path = f"{work}/clip{i}.f32"
    samples.astype("<f4").tofile(path)
    paths.append(path)
vectors_path = f"{work}/vectors.f32"
for begin in range(0, len(paths), 200):
    part = f"{vectors_path}.{begin}"
    subprocess.run([zb_test, "embed", encoder, str(RATE), part] + paths[begin:begin + 200], check=True,
                   stderr=subprocess.DEVNULL)
vectors = np.concatenate([np.fromfile(f"{vectors_path}.{b}", dtype="<f4") for b in range(0, len(paths), 200)])
vectors = vectors.reshape(len(clips), 192)


def unit(v):
    return v / (np.linalg.norm(v) + 1e-9)


def cos(a, b):
    return float(np.dot(unit(a), unit(b)))


index = {(name, kind): i for i, (name, kind, _) in enumerate(clips)}
print("\nOur 16 kHz path against the vector shipped with the voice (1.0 = identical):")
print("  " + ", ".join(f"{n} {cos(vectors[index[(n, 'full')]], voices[n][1]):.2f}" for n in voices))


def report(kind_a, kind_b, label):
    same, different = [], []
    for a in voices:
        if (a, kind_a) not in index:
            continue
        for b in voices:
            if (b, kind_b) not in index:
                continue
            value = cos(vectors[index[(a, kind_a)]], vectors[index[(b, kind_b)]])
            (same if a == b else different).append(value)
    if not same or not different:
        return
    same, different = np.array(same), np.array(different)
    best = max(np.linspace(0.05, 0.95, 91),
               key=lambda t: np.mean(same >= t) + np.mean(different < t))
    print(f"  {label:34s} same voice: min {same.min():.2f} median {np.median(same):.2f} | "
          f"other voice: median {np.median(different):.2f} max {different.max():.2f} | "
          f"best line {best:.2f}: misses {np.mean(same < best) * 100:.0f}% of same, "
          f"confuses {np.mean(different >= best) * 100:.1f}% of others")


print("\nSimilarity of two clips (cosine):")
for seconds in (1.0, 1.5, 2.0, 3.0):
    report(f"{seconds}s#0", f"{seconds}s#1", f"{seconds} s window vs another {seconds} s")
    report(f"{seconds}s#0", "full", f"{seconds} s window vs the whole clip")
report("2.0s+noise10dB", "full", "2 s with noise (10 dB) vs whole")
report("2.0s+noise3dB", "full", "2 s with loud noise (3 dB) vs whole")
report("2.0s+noise10dB", "2.0s#1", "2 s with noise (10 dB) vs clean 2 s")

# For the listening test: the voice as heard in two seconds, and the original two seconds themselves.
os.makedirs(out, exist_ok=True)
picked = [n for n in voices if (n, "2.0s#0") in index][:4]
for name in picked:
    np.save(f"{work}/heard-{name}.npy", vectors[index[(name, '2.0s#0')]].astype(np.float32))
    np.save(f"{work}/heard-noisy-{name}.npy", vectors[index[(name, '2.0s+noise10dB')]].astype(np.float32))
    start = int(0.3 * RATE)
    sf.write(f"{out}/ses-{name}-0-asil-2sn.wav", voices[name][0][start:start + 2 * RATE], RATE, subtype="PCM_16")
print("\nvoices for the listening test:", ", ".join(picked))
open(f"{work}/picked.txt", "w").write("\n".join(picked) + "\n")

# Prints simple measurements of speech recordings (WAV, mono): pitch level and how much it
# moves, how much of the time is speech, and how far up the spectrum the sound reaches.
# Used to compare voices by numbers when nobody can listen.
import sys, wave
import numpy as np

def load(path):
    with wave.open(path, "rb") as w:
        rate, n, ch, width = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, rate

def pitch_track(x, rate, fmin=60.0, fmax=400.0):
    hop, win = int(rate * 0.010), int(rate * 0.040)
    lo, hi = int(rate / fmax), int(rate / fmin)
    level = np.sqrt(np.mean(x ** 2)) + 1e-9
    f0, voiced_frames, frames = [], 0, 0
    for s in range(0, len(x) - win, hop):
        seg = x[s:s + win]
        frames += 1
        if np.sqrt(np.mean(seg ** 2)) < 0.25 * level:
            continue
        seg = seg - seg.mean()
        ac = np.correlate(seg, seg, "full")[win - 1:]
        if ac[0] <= 0:
            continue
        ac = ac / ac[0]
        lag = lo + int(np.argmax(ac[lo:hi]))
        if ac[lag] > 0.45:
            f0.append(rate / lag)
            voiced_frames += 1
    return np.array(f0), voiced_frames / max(frames, 1)

def describe(path):
    x, rate = load(path)
    f0, voiced = pitch_track(x, rate)
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freqs = np.fft.rfftfreq(len(x), 1.0 / rate)
    cum = np.cumsum(spec) / (spec.sum() + 1e-12)
    roll95 = freqs[np.searchsorted(cum, 0.95)]
    centroid = float((freqs * spec).sum() / (spec.sum() + 1e-12))
    if len(f0) > 10:
        st = 12 * np.log2(f0 / np.median(f0))
        pitch = f"pitch median {np.median(f0):.0f} Hz, spread {np.std(st):.1f} semitones, range {np.percentile(st, 95) - np.percentile(st, 5):.1f}"
    else:
        pitch = "pitch: too little voiced sound"
    print(f"{path.split('/')[-1]}: {len(x) / rate:.2f} s, {pitch}, voiced {voiced * 100:.0f}% of the time, "
          f"95% of energy below {roll95:.0f} Hz, centre {centroid:.0f} Hz")

for p in sys.argv[1:]:
    try:
        describe(p)
    except Exception as e:
        print(f"{p}: {e}")

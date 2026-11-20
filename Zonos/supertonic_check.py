# Speaks the same game-like Turkish lines with Supertonic 3's built-in voices, for comparison.
import os, sys, time
from supertonic import TTS

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
lines = [
    "Hadi ama, bunu ciddi ciddi mi söylüyorsun?",
    "Çabuk arabaya bin, polisler geliyor!",
    "Bak, seni son gördüğümde bana borcun vardı. Unuttun mu?",
]
tts = TTS(auto_download=True)
for voice in ["M1", "M2", "M4", "F1", "F3"]:
    style = tts.get_voice_style(voice_name=voice)
    for i, text in enumerate(lines):
        if voice not in ("M1", "F1") and i != 2:
            continue
        t0 = time.time()
        wav, duration = tts.synthesize(text, voice_style=style, lang="tr")
        took = time.time() - t0
        try:
            seconds = float(duration[0]) if hasattr(duration, "__len__") else float(duration)
        except Exception:
            seconds = 0.0
        path = os.path.join(out, f"supertonic-{voice}-cumle{i + 1}.wav")
        tts.save_audio(wav, path)
        print(f"{path}: {seconds:.2f} s of sound in {took * 1000:.0f} ms")

"""XTTS-v2 (Coqui; non-commercial licence, accepted by the user for private use): the character's clip as the voice."""
import sys, time
from lines import LINES, clip
from TTS.api import TTS
out = sys.argv[1]
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to("cpu")
for n, text in LINES:
    t = time.time()
    tts.tts_to_file(text=text, speaker_wav=clip(n), language="tr", file_path="%s/xtts-karakter%d.wav" % (out, n))
    print("xtts karakter%d %.1f s" % (n, time.time() - t), flush=True)

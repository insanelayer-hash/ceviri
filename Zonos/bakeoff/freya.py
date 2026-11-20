"""FreyaTTS (Turkish only, one voice of its own, no cloning): how the lines sound in native Turkish. These files
are also what the voice conversion in chatterbox_run.py turns into the characters' voices."""
import sys, time
from lines import LINES
from freyatts import FreyaTTS
out = sys.argv[1]
tts = FreyaTTS.from_pretrained("freyavoice/freya-tts", device="cpu")
for n, text in LINES:
    t = time.time()
    wav = tts.synthesize(text)
    tts.save_wav(wav, "%s/freya-satir%d.wav" % (out, n))
    print("freya satir%d %.1f s" % (n, time.time() - t), flush=True)

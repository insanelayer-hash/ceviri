"""OmniVoice (k2-fsa): the character's clip as the voice; the clip's words are found by the model's own recogniser."""
import sys, time
import soundfile as sf, torch
from lines import LINES, clip
from omnivoice import OmniVoice
out = sys.argv[1]
model = OmniVoice.from_pretrained("k2-fsa/OmniVoice", device_map="cpu", dtype=torch.float32)
for n, text in LINES:
    t = time.time()
    audio = model.generate(text=text, ref_audio=clip(n))
    sf.write("%s/omnivoice-karakter%d.wav" % (out, n), audio[0], 24000)
    print("omnivoice karakter%d %.1f s" % (n, time.time() - t), flush=True)

"""Chatterbox Multilingual (Resemble AI, MIT): the character's clip as the voice, plain and with the setting its
authors give against a foreign accent (cfg_weight 0). Then voice conversion: the native Turkish reading of
FreyaTTS (freya-satirN.wav, if that job produced it) turned into the character's voice.

usage: chatterbox_run.py <out dir> [dir with freya-satirN.wav]
"""
import os, sys, time, traceback
import torchaudio as ta
from lines import LINES, clip
out = sys.argv[1]
freya = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    from chatterbox.mtl_tts import ChatterboxMultilingualTTS
    try: m = ChatterboxMultilingualTTS.from_pretrained(device="cpu", t3_model="v3")
    except TypeError: m = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
    for n, text in LINES:
        for tag, extra in (("", {}), ("-aksansiz", {"cfg_weight": 0.0})):
            t = time.time()
            wav = m.generate(text, language_id="tr", audio_prompt_path=clip(n), **extra)
            ta.save("%s/chatterbox%s-karakter%d.wav" % (out, tag, n), wav, m.sr)
            print("chatterbox%s karakter%d %.1f s" % (tag, n, time.time() - t), flush=True)
    del m
except Exception:
    traceback.print_exc()
try:
    from chatterbox.vc import ChatterboxVC
    vc = ChatterboxVC.from_pretrained(device="cpu")
    for n, text in LINES:
        src = "%s/freya-satir%d.wav" % (freya, n)
        if not freya or not os.path.exists(src): print("no", src); continue
        t = time.time()
        wav = vc.generate(audio=src, target_voice_path=clip(n))
        ta.save("%s/freya+donusturme-karakter%d.wav" % (out, n), wav, vc.sr)
        print("freya+vc karakter%d %.1f s" % (n, time.time() - t), flush=True)
except Exception:
    traceback.print_exc()

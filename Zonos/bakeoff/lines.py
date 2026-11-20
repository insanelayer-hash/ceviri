"""The same Turkish lines for every voice model tried: one per character clip of the user's game
(klipler/karakterN.wav, 16 kHz mono, as the computer's program saves them)."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
LINES = [
    (1, "Evet, tabii. Bir saniye bekle, arabayı hemen gönderiyorum."),
    (3, "Hey Joey, arabayı getirecek birini gönderebilir misin?"),
    (6, "Selam, Lucia'nın telefonuna ulaştınız. Şu an açamıyorum, mesaj bırakın."),
]
def clip(n): return os.path.join(HERE, "klipler", "karakter%d.wav" % n)

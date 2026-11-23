# TR Altyazı (iPhone)

TV'deki TR Altyazı servisinden altyazı resimlerini alır, iPhone'da okur (Vision) ve
cihaz üzerinde Türkçeye çevirir (Apple Translation), sonucu TV'ye geri yollar.

Derleme: her push'ta GitHub Actions imzasız `TRAltyazi.ipa` üretir (Actions > son çalışma > Artifacts).
Kurulum: Sideloadly ile Apple ID kullanarak iPhone'a yüklenir.

## Hazır çeviri tablosu (isteğe bağlı)

Bir oyunun altyazılarını önceden çevirdiyseniz, uygulama satırı çevirmek yerine tablodan bulup hemen gösterir;
tabloda olmayan satır her zamanki gibi çevrilir. Tablo tek bir dosyadır (`tablo.trat`): İngilizce satırın 64 bitlik
özeti → Türkçe satır (biçimi `TRAltyazi/SubtitleTable.swift` başında yazılı). Uygulamadaki "Hazır çeviri tablosu"
bölümüne dosyanın ev ağınızdaki adresi yazılıp bir kez indirilir. Bu depoda tablo yoktur; kendi tablonuzu siz
üretirsiniz.

## Sesli çeviri: deneysel, kurmayın

Bu depodaki sesli çeviri (Türkçe seslendirme) kısmı **deneyseldir** ve **kurulmamalıdır**. Kullanılacak olan
özellik yalnızca Türkçe altyazıdır. Ayrıntı: [SESLI-CEVIRI-DENEYSEL.md](SESLI-CEVIRI-DENEYSEL.md).

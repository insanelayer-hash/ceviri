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

## Hazır dublaj (isteğe bağlı)

Bir oyunun repliklerini önceden Türkçe seslendirdiyseniz, uygulama satırı ekranda görür görmez o satırın hazır sesini
telefonun deposundan okuyup TV'ye yollar; ses üretilmez, bilgisayar gerekmez. Paket bir dizin (`ses.trsx`: İngilizce
satırın özeti → ses, sahne bilgisiyle) ve 64 MB'lik ses dosyalarından (`ses-000.trsd`…, MP3) oluşur; biçimi
`TRAltyazi/DubPack.swift` başında yazılı. Uygulamadaki "Hazır dublaj" bölümüne paketin bulunduğu klasörün ev
ağınızdaki adresi yazılıp bir kez indirilir; yarıda kesilen indirme kaldığı yerden sürer. Aynı cümleyi birkaç
kişi söylüyorsa uygulama TV'den oyunun o anki sesini (yarım saniye) alır ve özgün konuşanı o sese en yakın
kalınlıkta/incelikte olan sesi seçer; ses duyulamazsa sahneye bakar, o da yoksa satırı sessiz bırakır. Hazır satırlar TV'de sıraya girmez: yeni satır, önceki bitmeden
başlar (TV arayüzü 0.12.0 ve sonrası). Bu depoda ses paketi yoktur; kendi paketinizi siz üretirsiniz.

## Sesli çeviri: deneysel, kurmayın

Bu depodaki sesli çeviri (Türkçe seslendirme) kısmı **deneyseldir** ve **kurulmamalıdır**. Kullanılacak olan
özellik yalnızca Türkçe altyazıdır. Ayrıntı: [SESLI-CEVIRI-DENEYSEL.md](SESLI-CEVIRI-DENEYSEL.md).

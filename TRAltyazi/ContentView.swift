import SwiftUI
import UIKit
import AVFoundation
import Translation

struct ContentView: View {
    @StateObject private var worker = Worker()
    @StateObject private var listener = Listener()
    @AppStorage("tvHost") private var host = ""
    @AppStorage("tvKey") private var key = ""
    @AppStorage("quality") private var qualityRaw = Quality.both.rawValue
    @State private var configuration: TranslationSession.Configuration?
    @State private var aiState = Refiner.availability()
    @AppStorage("look") private var look = 2
    @AppStorage("fastReading") private var fastReading = false
    @AppStorage("voice") private var voice = false
    @AppStorage("voiceEngine") private var voiceEngine = 0
    @AppStorage("zonosVoice") private var zonosVoice = "Gaspard"
    @AppStorage("zonosGPU") private var zonosGPU = false
    @AppStorage("zonosRate") private var zonosRate = 20.0
    @AppStorage("zonosGuard") private var zonosGuard = true
    @AppStorage("zonosOwnVoice") private var zonosOwnVoice = true
    @AppStorage("voiceSource") private var voiceSource = 0
    @AppStorage("zonosPieces") private var zonosPieces = true
    @AppStorage("zonosQuickStart") private var zonosQuickStart = true
    @State private var knownVoices = 0
    @State private var elevenKey = Keychain.get("elevenKey")
    @AppStorage("elevenVoice") private var elevenVoice = "JBFqnCBsd6RMkjVDRZzb"
    @AppStorage("elevenModel") private var elevenModel = "eleven_v4_turbo"
    @AppStorage("toneFollow") private var toneFollow = false
    @AppStorage("voiceByCharacter") private var voiceByCharacter = false
    @State private var castNote = ElevenVoice.shared.voices.isEmpty ? "" : "\(ElevenVoice.shared.voices.count) ses hazır"
    @State private var zonosReady = ZonosVoice.shared.isDownloaded
    @State private var zonosProgress: Double?
    @State private var zonosNote = ""
    @State private var zonosBusy = false
    @State private var player: AVAudioPlayer?
    @AppStorage("tableURL") private var tableURL = ""
    @State private var tableLines = SubtitleTable.shared.lines
    @State private var tableNote = ""
    @State private var tableBusy = false
    @State private var dark = false
    @State private var savedBrightness: CGFloat = 0.5
    @Environment(\.scenePhase) private var scenePhase

    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .both }

    // The screen, with each group of settings passed on to the worker as it changes. Split into
    // steps because one long chain of modifiers is more than the compiler can check at once.
    private var page: some View {
        ZStack {
            settings
            if dark { darkScreen }
        }
        .statusBarHidden(dark)
        .persistentSystemOverlays(dark ? .hidden : .automatic)
        .translationTask(configuration) { session in
            await worker.run(session: session)
        }
        .onChange(of: qualityRaw) { _, _ in worker.quality = quality }
        .onChange(of: fastReading) { _, value in worker.fastReading = value }
        .onChange(of: voice) { _, value in
            worker.voiceOn = value
            listenIfNeeded()
        }
        .onChange(of: voiceEngine) { _, value in
            worker.voiceEngine = value
            listenIfNeeded()
        }
    }

    private var pageWithZonos: some View {
        page
            .onChange(of: zonosVoice) { _, value in worker.zonosVoice = value }
            .onChange(of: zonosGPU) { _, value in worker.zonosGPU = value }
            .onChange(of: zonosRate) { _, value in worker.zonosRate = value }
            .onChange(of: zonosGuard) { _, value in worker.zonosGuard = value }
            .onChange(of: zonosOwnVoice) { _, value in worker.zonosOwnVoice = value }
            .onChange(of: zonosPieces) { _, value in worker.zonosPieces = value }
            .onChange(of: voiceSource) { _, value in
                worker.voiceSource = value
                listenIfNeeded()
            }
    }

    private var pageWithVoices: some View {
        pageWithZonos
            .onChange(of: elevenKey) { _, value in Keychain.set("elevenKey", value); worker.elevenKey = value }
            .onChange(of: elevenVoice) { _, value in worker.elevenVoice = value }
            .onChange(of: elevenModel) { _, value in worker.elevenModel = value }
            .onChange(of: toneFollow) { _, value in worker.toneFollow = value }
            .onChange(of: voiceByCharacter) { _, value in worker.voiceByCharacter = value }
    }

    var body: some View {
        pageWithVoices
        .onChange(of: look) { _, value in
            worker.host = host.trimmingCharacters(in: .whitespaces)
            worker.key = key.trimmingCharacters(in: .whitespaces)
            worker.look = value
            Task { await worker.applyLook() }
        }
        // While translating, the screen switches itself off when the phone lies face down
        // (or is covered), like during a call; the app keeps running.
        .onChange(of: worker.running) { _, running in
            UIDevice.current.isProximityMonitoringEnabled = running
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && dark { setDark(false) }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            aiState = Refiner.availability()
            worker.quality = quality
            // The spoken translation is made on the computer now: the phone only does subtitles.
            voice = false
            voiceSource = 0
            if !key.isEmpty { start() }
        }
    }

    /// A black screen at minimum brightness: on an OLED iPhone that is almost the same as
    /// the screen being off, but the app stays in front and keeps translating.
    private var darkScreen: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Çıkmak için iki kez dokun")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.22))
                    .padding(.bottom, 48)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { setDark(false) }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private func setDark(_ on: Bool) {
        if on {
            savedBrightness = screen?.brightness ?? 0.5
            screen?.brightness = 0
        } else {
            screen?.brightness = savedBrightness
        }
        dark = on
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Televizyon") {
                    LabeledContent("TV IP adresi") {
                        TextField("ör. 192.168.1.50", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Anahtar") {
                        TextField("TV servis anahtarı", text: $key)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button(worker.running ? "Durdur" : "Başlat") {
                        if worker.running {
                            worker.stop()
                            configuration?.invalidate()
                            configuration = nil
                        } else {
                            start()
                        }
                    }
                    .disabled(key.isEmpty)
                }

                Section {
                    Picker("Çeviri", selection: $qualityRaw) {
                        ForEach(Quality.allCases) { q in Text(q.title).tag(q.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Apple Intelligence", value: aiState.text)
                } header: {
                    Text("Kalite")
                } footer: {
                    Text("Hızlı: Apple Çeviri, anında. Doğal: Apple Intelligence, günlük konuşma Türkçesi, biraz daha yavaş. Hızlı + doğal: önce hızlı çeviri görünür, doğal olanı gelince onunla değişir.")
                }

                tableSection

                // Only when there is a choice to make: more than one device on the TV's HDMI inputs.
                if worker.inputs.count > 1 {
                    Section {
                        Picker("TV girişi", selection: Binding(
                            get: { worker.input },
                            set: { number in Task { await worker.chooseInput(number) } })) {
                            Text("Otomatik").tag(0)
                            ForEach(worker.inputs, id: \.self) { number in
                                Text("HDMI \(number)").tag(number)
                            }
                        }
                    } footer: {
                        Text("Oyun konsolunun takılı olduğu girişi seç. TV şu an HDMI \(worker.currentInput) girişini gösteriyor.")
                    }
                }

                Section {
                    Picker("Görünüm", selection: $look) {
                        Text("Siyah kutu").tag(0)
                        Text("Bulanık").tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("TV'deki görünüm")
                } footer: {
                    Text("Siyah kutu: İngilizcenin üstünü kapatan kutu, her sahnede net okunur. Bulanık: kutu yok, yazının arkası sahnenin renkleriyle doldurulur. Bir sonraki altyazıda geçerli olur.")
                }

                Section {
                    Text("Sesli çeviri bilgisayarda yapılır. Bilgisayarda “TR Altyazı – sesli çeviri” programı açıkken, buradaki Türkçe altyazılar konuşan karakterin sesiyle televizyondan seslendirilir. Telefon yalnızca altyazıyı çevirir.")
                        .font(.footnote)
                    if zonosReady {
                        Button("Telefondaki ses modelini sil (1,1 GB yer açar)") {
                            ZonosVoice.shared.stop()
                            ZonosVoice.shared.deleteFiles()
                            zonosReady = ZonosVoice.shared.isDownloaded
                        }
                    }
                } header: {
                    Text("Sesli çeviri")
                }

                Section {
                    Picker("Okuma", selection: $fastReading) {
                        Text("Dikkatli").tag(false)
                        Text("Hızlı").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Yazıyı okuma")
                } footer: {
                    Text("Dikkatli: en doğru okuma. Hızlı: satır başına biraz daha çabuk, ama küçük harflerde daha sık yanlış okuyabilir. Durum bölümündeki Okuma süresinden farkı görebilirsin.")
                }

                Section("Durum") {
                    Text(worker.status)
                    LabeledContent("Okuma", value: "\(worker.lastOcrMs) ms")
                    LabeledContent("Hızlı çeviri", value: "\(worker.lastTranslateMs) ms")
                    LabeledContent("Doğal çeviri", value: "\(worker.lastNaturalMs) ms")
                    LabeledContent("Satır", value: "\(worker.done)")
                    LabeledContent("Hafızadan", value: "\(worker.cacheHits)")
                    LabeledContent("Tablodan", value: "\(worker.tableHits)")
                }

                if !worker.lastEN.isEmpty {
                    Section("Son satır") {
                        Text(worker.lastEN).foregroundStyle(.secondary)
                        Text(worker.lastTR).font(.headline)
                    }
                }

                Section {
                    Button("Ekranı karart") { setDark(true) }
                } footer: {
                    Text("Oynarken uygulama önde kalmalı; kilit tuşuna basarsan iOS uygulamayı durdurur. Bunun yerine ekranı karart ya da telefonu ekranı aşağı bakacak şekilde bırak: ekran kapanır, çeviri sürer. Uzun oyunda şarja tak.")
                }
            }
            .navigationTitle("TR Altyazı")
        }
    }

    /// Translating from the game's sound needs the listener: it runs while that source is chosen.
    private func listenIfNeeded() {
        listener.onLine = { number, text, pcm in worker.heard(number, english: text, pcm: pcm, rate: 16000) }
        listener.onVoice = { number, pcm in worker.heardVoiceSample(number, pcm: pcm, rate: 16000) }
        listener.onDraft = { number, text, pcm in worker.heardDraft(number, english: text, pcm: pcm, rate: 16000) }
        listener.onWithdraw = { number in worker.heardWithdrawn(number) }
        let wanted = voice && voiceSource == 1 && !key.isEmpty
        if wanted, !listener.running {
            listener.start(host: host.trimmingCharacters(in: .whitespaces), key: key.trimmingCharacters(in: .whitespaces))
        } else if !wanted, listener.running, voiceSource != 1 {
            listener.stop()
        }
        knownVoices = worker.knownVoices
        // The voice model takes seconds to load: do it now rather than on the first line.
        if voice, voiceEngine == 1, !key.isEmpty {
            let gpu = zonosGPU
            Task { await ZonosVoice.shared.warmUp(gpu: gpu) }
        }
    }

    private func start() {
        aiState = Refiner.availability()
        worker.host = host.trimmingCharacters(in: .whitespaces)
        worker.key = key.trimmingCharacters(in: .whitespaces)
        worker.quality = quality
        worker.look = look
        worker.fastReading = fastReading
        worker.voiceOn = voice
        worker.voiceEngine = voiceEngine
        worker.zonosVoice = zonosVoice
        worker.zonosGPU = zonosGPU
        worker.zonosRate = zonosRate
        worker.zonosGuard = zonosGuard
        worker.zonosOwnVoice = zonosOwnVoice
        worker.voiceSource = voiceSource
        worker.zonosPieces = zonosPieces
        worker.zonosQuickStart = zonosQuickStart
        listenIfNeeded()
        worker.elevenKey = elevenKey
        worker.elevenVoice = elevenVoice
        worker.elevenModel = elevenModel
        worker.toneFollow = toneFollow
        worker.voiceByCharacter = voiceByCharacter
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "tr"))
    }

    /// The ready-made translation table: one file, downloaded once from an address on the home
    /// network (for example a computer that serves it for a minute).
    private var tableSection: some View {
        Section {
            LabeledContent("Tablo", value: tableLines > 0 ? "\(tableLines) satır yüklü" : "Yüklü değil")
            TextField("http://bilgisayarın-adresi:8123/tablo.trat", text: $tableURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(tableBusy ? "İndiriliyor…" : "Tabloyu indir") { downloadTable() }
                .disabled(tableBusy || tableURL.trimmingCharacters(in: .whitespaces).isEmpty)
            if tableLines > 0 {
                Button("Tabloyu sil", role: .destructive) {
                    SubtitleTable.shared.delete()
                    tableLines = SubtitleTable.shared.lines
                    tableNote = ""
                }
            }
            if !tableNote.isEmpty {
                Text(tableNote).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hazır çeviri tablosu")
        } footer: {
            Text("Oyunun altyazıları önceden çevrilmişse, tablodaki satır hiç çeviri beklemeden gösterilir; tabloda olmayan satır yukarıdaki yolla çevrilir. Tablo dosyası bir kez indirilir ve telefonda kalır.")
        }
    }

    private func downloadTable() {
        guard let url = URL(string: tableURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            tableNote = "Adres geçersiz."
            return
        }
        tableBusy = true
        tableNote = ""
        Task {
            do {
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let target = SubtitleTable.fileURL
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temp, to: target)
                if SubtitleTable.shared.load() {
                    tableNote = "Tablo yüklendi."
                } else {
                    try? FileManager.default.removeItem(at: target)
                    tableNote = "İnen dosya tablo biçiminde değil."
                }
            } catch {
                tableNote = "İndirilemedi: \(error.localizedDescription)"
            }
            tableLines = SubtitleTable.shared.lines
            tableBusy = false
        }
    }

    private func downloadZonos() {
        zonosProgress = 0
        zonosNote = ""
        Task {
            do {
                try await ZonosVoice.shared.download { value in
                    Task { @MainActor in zonosProgress = value }
                }
                zonosReady = ZonosVoice.shared.isDownloaded
                zonosNote = zonosReady ? "Model hazır." : "İndirme tamamlanamadı."
            } catch {
                zonosNote = "İndirilemedi: \(error.localizedDescription)"
            }
            zonosProgress = nil
        }
    }

    private func tryEleven() {
        zonosBusy = true
        zonosNote = "Bekleniyor…"
        let key = elevenKey, voiceName = elevenVoice, model = elevenModel
        Task {
            let clip = await ElevenVoice.shared.speak("Hadi ama, bunu ciddi ciddi mi söylüyorsun? Çabuk arabaya bin, polisler geliyor!",
                                                      apiKey: key, voiceID: voiceName, model: model)
            if let clip {
                zonosNote = String(format: "%.1f sn ses · %d ms'de geldi", Double(clip.pcm.count / 2) / Double(max(clip.rate, 1)), ElevenVoice.shared.lastMs)
                play(clip)
            } else {
                zonosNote = "Olmadı: " + ElevenVoice.shared.lastError
            }
            zonosBusy = false
        }
    }

    /// Says a test sentence on the phone's own speaker and shows how long it took.
    private func tryZonos() {
        zonosBusy = true
        zonosNote = "Hazırlanıyor…"
        let voiceName = zonosVoice, gpu = zonosGPU
        Task {
            let clip = await ZonosVoice.shared.speak("Merhaba, bu yeni sesin denemesi. Arabayı arka sokağa çek, iki dakikaya dönerim.",
                                                     voice: voiceName, gpu: gpu, rate: zonosRate, guarded: zonosGuard)
            if let clip, let t = ZonosVoice.shared.lastTiming {
                zonosNote = String(format: "%.1f sn ses · üretim %d ms", t.seconds, t.totalMs - t.startMs)
                    + (t.startMs > 0 ? String(format: " (model ilk açılışta %d ms'de yüklendi)", t.startMs) : "")
                play(clip)
            } else {
                zonosNote = "Ses üretilemedi: " + ZonosVoice.shared.lastError
            }
            zonosBusy = false
        }
    }

    private func play(_ clip: Speaker.Clip) {
        var wav = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + clip.pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(clip.rate)); append32(UInt32(clip.rate * 2)); append16(2); append16(16)
        wav.append(contentsOf: Array("data".utf8)); append32(UInt32(clip.pcm.count))
        wav.append(clip.pcm)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: wav)
        player?.play()
    }
}

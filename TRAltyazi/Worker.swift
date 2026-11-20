import Foundation
import Vision
import CoreGraphics
import Translation
import Network

/// One subtitle crop handed out by the TV service (`GET /job?fmt=raw`): the raw 8-bit gray
/// pixels in the body, "id,width,height" in the `X-Job` header.
struct Job {
    let id: Int
    let image: CGImage

    init?(data: Data, header: String?) {
        let parts = (header ?? "").split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3,
              let image = Worker.makeImage(gray: data, width: parts[1], height: parts[2], scale: 3) else { return nil }
        self.id = parts[0]
        self.image = image
    }
}

/// Translation quality setting.
enum Quality: String, CaseIterable, Identifiable {
    case fast       // Apple Translation only (~instant)
    case both       // Apple Translation first, then Apple Intelligence replaces it
    case natural    // Apple Intelligence only (waits for the natural version)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Hızlı"
        case .both: return "Hızlı + doğal"
        case .natural: return "Doğal"
        }
    }
}

/// Waits on the TV for new subtitle lines, reads them with Vision, translates them on the
/// device and posts the Turkish text back (`GET /result`).
///
/// Built for speed and for not losing lines:
/// - two long polls are always open, so a stuck connection cannot hold a line back;
/// - every line is handled in its own task, so a slow one never blocks the next;
/// - when a newer line has arrived, work on an older one that is not translated yet stops;
/// - Vision and the translator are warmed up before the first real line.
@MainActor
final class Worker: ObservableObject {
    @Published var status = "Başlatılıyor…"
    @Published var lastEN = ""
    @Published var lastTR = ""
    @Published var lastNatural = ""
    @Published var lastOcrMs = 0
    @Published var lastTranslateMs = 0
    @Published var lastNaturalMs = 0
    @Published var done = 0
    @Published var cacheHits = 0
    @Published var running = false
    /// HDMI inputs with a device on them, as the TV reports them, the input it is showing,
    /// and the chosen one (0 = let the TV decide).
    @Published var inputs: [Int] = []
    @Published var currentInput = 0
    @Published var input = 0

    var host = ""
    var key = ""
    var quality: Quality = .both
    /// How the TV draws the line: 0 = black box, 2 = no box, soft patch of the scene behind.
    var look = 2
    /// Quick reading: Vision's fast text recogniser instead of the accurate one. Saves a few
    /// hundredths of a second per line; may misread small letters more often.
    var fastReading = false
    /// Spoken translation: each Turkish line is also turned into sound and sent to the TV.
    var voiceOn = false
    /// Which voice says the lines: 0 = the phone's own, 1 = ZONOS3-Mini (when downloaded),
    /// 2 = ElevenLabs (over the internet, with the user's own key).
    var voiceEngine = 0
    var elevenKey = ""
    var elevenVoice = ""
    var elevenModel = "eleven_v4_turbo"
    /// Follow how the character says the line (ElevenLabs v4 Turbo only): the TV's sound around
    /// the line decides directions such as "[shouting]" or "[softly]" for the voice.
    var toneFollow = false
    /// A voice of their own for each character (ElevenLabs): chosen by how high the character
    /// speaks, from the voices prepared in the settings.
    var voiceByCharacter = false
    private let tone = ToneTracker()
    private let cast = CharacterVoices()
    private struct Heard {
        var directions = ""
        var voice: String?
    }
    private var toneTasks: [Int: Task<Heard, Never>] = [:]
    /// The best reading of the line that is on screen now: the TV sends a line several times
    /// and a blurred frame reads worse, so a clearer earlier reading is kept.
    private var steady: (text: String, confidence: Float, at: Date)?
    var zonosVoice = "Gaspard"
    var zonosGPU = false
    var zonosRate = 20.0
    var zonosGuard = true
    /// Hand a line to the TV in pieces while it is still being produced, so it starts sooner.
    var zonosPieces = true
    /// ZONOS: speak each line in the voice of the character who says it. The TV hands over the
    /// game's sound around the line, the model's speaker encoder turns it into a voice, and the
    /// characters heard so far are kept apart in `heardCast`.
    var zonosOwnVoice = true
    private let heardCast = VoiceCast()
    private struct HeardVoice {
        let vector: [Float]         // empty: one of the built-in voices (`builtIn`)
        let who: String
        var builtIn: String? = nil
        var number: Int? = nil      // the character, when known
        /// Names the voice for remembering a spoken line.
        var key: String? { number.map { "c\($0)" } ?? builtIn }
    }
    // Lines already spoken, by voice and text: said again (a scene replayed, a phrase people
    // repeat), they go out at once without being produced a second time.
    private var spokenLines: [String: Speaker.Clip] = [:]
    private var spokenOrder: [String] = []
    private func rememberSpoken(_ key: String, _ clip: Speaker.Clip) {
        guard clip.pcm.count < 44100 * 2 * 12 else { return }
        if spokenLines[key] == nil { spokenOrder.append(key) }
        spokenLines[key] = clip
        while spokenOrder.count > 80 { spokenLines[spokenOrder.removeFirst()] = nil }
    }
    private var voiceTasks: [Int: Task<HeardVoice?, Never>] = [:]
    private var guessTasks: [Int: Task<HeardVoice?, Never>] = [:]
    /// Start a subtitle line at once with a guessed speaker instead of listening first.
    var zonosQuickStart = true
    // Until when the TV is busy playing what we already sent (our estimate), to leave out a
    // line that could only start long after it was said.
    private var playingUntil = Date.distantPast
    // When each distinct line appeared: a clip for learning a voice must stop where the next
    // line starts, or it holds two people and teaches a voice that is neither.
    private var lineStarts: [Int: Date] = [:]
    private var lineStartText = ""
    private var lineFirstJob = 0
    private var sureLines: Set<Int> = []
    private var guessRunning = 0
    private var newestLine = 0
    /// Where the spoken lines come from: 0 = the subtitles on screen, 1 = the game's sound
    /// (speech is listened to, written down by the phone and translated; no subtitle needed).
    var voiceSource = 0
    var knownVoices: Int { heardCast.count }
    func forgetVoices() { heardCast.reset() }
    // How alike two clips of one voice must be (cosine of their speaker vectors). A known
    // character is accepted from the first second only when the match is clear; with a longer
    // listen a looser match is enough, and below that the speaker counts as someone new.
    // Measured on the model's default voices cut to 16 kHz clips (Zonos/voice_match.py): one
    // second against a known voice gives 0.53-0.8 for the same person and at most 0.50 for
    // someone else; two seconds, also with noise under them, 0.55 and up against 0.49 at most.
    private static let quickMatch: Float = 0.55
    private static let slowMatch: Float = 0.50
    private static let heardMatch: Float = 0.38
    @Published var voiceNote = ""

    private let speaker = Speaker()
    private var speakQueue: Task<Void, Never>?
    private var lastSpokenJob = 0
    private var lastSpoken = ""
    private var lastSpokenAt = Date.distantPast

    private var session: TranslationSession?
    private var quickCache: [String: String] = [:]
    private var naturalCache: [String: String] = [:]
    private var recent: [(en: String, tr: String)] = []
    private var refineTask: Task<Void, Never>?
    private var pollers: [Task<Void, Never>] = []
    private var stopRequested = false
    private var newestJob = 0
    private var aiReady = false
    private var beat: NWConnection?

    // Apple's translator is asked for one line at a time; later lines wait here.
    private var translating = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let idle = "Bağlı · altyazı bekleniyor"

    // Everything about the voice (clips of the game's sound, spoken lines, notes) has its own
    // connections: these requests wait on the TV for up to two seconds each, and several at
    // once used to take all the connections, so fetching and answering subtitle lines stalled.
    private let voiceNet: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.httpMaximumConnectionsPerHost = 6
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private let net: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.httpMaximumConnectionsPerHost = 8
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func stop() {
        stopRequested = true
        pollers.forEach { $0.cancel() }
    }

    /// Runs until stopped or the surrounding translation task is cancelled.
    func run(session: TranslationSession) async {
        stopRequested = false
        running = true
        newestJob = 0
        self.session = session
        defer {
            running = false
            self.session = nil
            pollers = []
            beat?.cancel()
            beat = nil
        }

        status = "Türkçe dil paketi hazırlanıyor…"
        do {
            try await session.prepareTranslation()
        } catch {
            status = "Dil paketi indirilemedi: \(error.localizedDescription)"
        }
        aiReady = Refiner.availability().ok
        await warmUp()
        if Task.isCancelled || stopRequested { return }
        await applyLook()
        status = Self.idle

        let first = Task { await self.pollLoop() }
        let second = Task { await self.pollLoop() }
        // Keeps the list of TV inputs fresh (a console may be switched on later).
        // A one-byte datagram to the TV twenty times a second. The TV ignores it; sending
        // keeps this phone's Wi-Fi radio awake, so a new line from the TV is not held back
        // until the radio's next wake-up.
        let pulse = startBeat()
        let refresher = Task {
            while !Task.isCancelled && !self.stopRequested {
                await self.loadInputs()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        pollers = [first, second, refresher, pulse]
        await withTaskCancellationHandler {
            await first.value
            await second.value
            refresher.cancel()
            pulse.cancel()
        } onCancel: {
            first.cancel()
            second.cancel()
            refresher.cancel()
            pulse.cancel()
        }
    }

    /// Tells the TV which look to use (its `style` setting). The TV remembers it.
    func applyLook() async {
        guard !key.isEmpty, let url = URL(string: "http://\(host):8090/config?k=\(key)&style=\(look)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        _ = try? await net.data(for: request)
    }

    private struct InputsReply: Decodable {
        let hdmi: Int
        let cur: Int
        let list: [Int]
    }

    /// Asks the TV which HDMI inputs have a device and which one is chosen.
    func loadInputs() async {
        guard !key.isEmpty, let url = URL(string: "http://\(host):8090/inputs?k=\(key)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await net.data(for: request),
              let reply = try? JSONDecoder().decode(InputsReply.self, from: data) else { return }
        if inputs != reply.list { inputs = reply.list }
        if currentInput != reply.cur { currentInput = reply.cur }
        if input != reply.hdmi { input = reply.hdmi }
    }

    /// Switches the TV to the chosen input (the TV remembers it).
    func chooseInput(_ number: Int) async {
        input = number
        guard !key.isEmpty, let url = URL(string: "http://\(host):8090/config?k=\(key)&hdmi=\(number)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        _ = try? await net.data(for: request)
        try? await Task.sleep(for: .seconds(2))
        await loadInputs()
    }

    private func startBeat() -> Task<Void, Never> {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 8090, using: .udp)
        connection.start(queue: .global(qos: .utility))
        beat = connection
        return Task {
            let byte = Data([1])
            while !Task.isCancelled && !self.stopRequested {
                connection.send(content: byte, completion: .idempotent)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The first Vision request and the first translation each take about a second while
    /// their models load. Do that now rather than on the first subtitle.
    private func warmUp() async {
        var pixels = [UInt8](repeating: 30, count: 200 * 40)
        for i in stride(from: 0, to: pixels.count, by: 7) { pixels[i] = 220 }
        if let image = Self.makeImage(gray: Data(pixels), width: 200, height: 40, scale: 3) {
            _ = await Self.recognize(image, fast: fastReading)
        }
        if let session {
            _ = try? await session.translate("Hello, how are you?")
        }
    }

    private func pollLoop() async {
        let device = UIDeviceName.current
        while !Task.isCancelled && !stopRequested {
            guard let url = URL(string: "http://\(host):8090/job?k=\(key)&wait=8000&fmt=raw&dev=\(device)&voice=\(voiceOn ? 1 : 0)") else {
                status = "TV adresi geçersiz"
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            do {
                let (data, response) = try await net.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                switch http.statusCode {
                case 204:
                    if status != Self.idle { status = Self.idle }
                case 200:
                    guard let job = Job(data: data, header: http.value(forHTTPHeaderField: "X-Job")) else {
                        // A TV service older than 1.2 answers with JSON here.
                        status = "TV servisi eski: 1.2 sürümünü kur"
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    // Ids normally only rise. A much lower one means the TV service started
                    // over, so start counting from it instead of treating every line as old.
                    newestJob = job.id + 100 < newestJob ? job.id : max(newestJob, job.id)
                    Task { await self.handle(job) }
                case 403:
                    status = "Anahtar yanlış"
                    try? await Task.sleep(for: .seconds(2))
                default:
                    status = "TV hatası \(http.statusCode)"
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                if Task.isCancelled || stopRequested { return }
                status = "TV'ye ulaşılamıyor: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handle(_ job: Job) async {
        if voiceOn, voiceEngine == 2, voiceByCharacter || (toneFollow && elevenModel == "eleven_v4_turbo") {
            let id = job.id
            toneTasks[id] = Task { await self.readTone(id: id) }
            if toneTasks.count > 40 { toneTasks = toneTasks.filter { $0.key > id - 20 } }
        }
        if voiceOn, voiceEngine == 1, zonosOwnVoice {
            let id = job.id
            // The TV sends a line again while it waits for the answer, and sends frames with
            // nothing in them: only one guess runs at a time, the repeats share it (below).
            if zonosQuickStart, guessRunning < 2 {
                guessRunning += 1
                guessTasks[id] = Task {
                    let voice = await self.guessVoice(id: id)
                    self.guessRunning -= 1
                    return voice
                }
            }
            if guessTasks.count > 40 { guessTasks = guessTasks.filter { $0.key > id - 20 } }
        }
        let t0 = Date()
        let read = await Self.recognize(job.image, fast: fastReading)
        var en = read.text
        // Same line read again: keep whichever reading Vision was surer of.
        if let kept = steady, Date().timeIntervalSince(kept.at) < 8, Self.alike(kept.text, en) {
            if read.confidence > kept.confidence + 0.02 {
                steady = (en, read.confidence, kept.at)
            } else {
                en = kept.text
            }
        } else if Self.looksLikeText(en) {
            steady = (en, read.confidence, Date())
        }
        let ocrMs = Int(Date().timeIntervalSince(t0) * 1000)
        lastOcrMs = ocrMs
        done += 1
        guard Self.looksLikeText(en) else {
            guessTasks[job.id] = nil
            await post(id: job.id, tr: "", en: "", ocrMs: ocrMs, tlMs: 0, final: true)
            return
        }
        lastEN = en
        // The proper listen (two seconds and the speaker encoder) only for a frame that really
        // has a line in it: menus and empty frames must not become "characters".
        if voiceOn, voiceEngine == 1 { ZonosVoice.shared.keepEncoderBack(for: 1.5) }
        if !Self.alike(lineStartText, en) {
            lineStartText = en
            lineStarts[job.id] = t0
            lineFirstJob = job.id
            if lineStarts.count > 40 { lineStarts = lineStarts.filter { $0.key > job.id - 20 } }
        } else if lineFirstJob != job.id {
            // The same line again: it shares what the first job of the line found out.
            if let first = guessTasks[lineFirstJob] { guessTasks[job.id] = first }
            if let first = voiceTasks[lineFirstJob] { voiceTasks[job.id] = first }
        }
        if voiceOn, voiceEngine == 1, zonosOwnVoice, voiceTasks[job.id] == nil {
            let id = job.id
            voiceTasks[id] = Task { await self.heardVoice(id: id) }
            if voiceTasks.count > 40 { voiceTasks = voiceTasks.filter { $0.key > id - 20 } }
        }

        let useNatural = quality != .fast && aiReady

        // Already have the natural version of this exact line: show it right away.
        if useNatural, let hit = naturalCache[en] {
            cacheHits += 1
            lastTR = hit; lastNatural = hit
            remember(en, hit)
            await post(id: job.id, tr: hit, en: en, ocrMs: ocrMs, tlMs: 0, final: true)
            return
        }

        // Quick Apple Translation (skipped in "natural" mode when Apple Intelligence works).
        var quick = ""
        if quality != .natural || !useNatural {
            let t1 = Date()
            if let hit = quickCache[en] {
                quick = hit
                cacheHits += 1
            } else if let out = await translateLine(en, id: job.id) {
                quick = out
                quickCache[en] = out
            } else {
                return      // a newer line took over, or the translator failed
            }
            let tlMs = Int(Date().timeIntervalSince(t1) * 1000)
            lastTranslateMs = tlMs
            lastTR = quick
            await post(id: job.id, tr: quick, en: en, ocrMs: ocrMs, tlMs: tlMs, final: !useNatural)
            if !useNatural { remember(en, quick); return }
        }

        // Natural version from the on-device language model, in the background; a newer
        // line cancels an older one that is still being written.
        guard job.id >= newestJob else { return }
        let context = recent
        let id = job.id
        refineTask?.cancel()
        refineTask = Task { await self.refine(id: id, en: en, quick: quick, ocrMs: ocrMs, context: context) }
    }

    private func refine(id: Int, en: String, quick: String, ocrMs: Int, context: [(en: String, tr: String)]) async {
        let t0 = Date()
        do {
            let natural = try await Refiner.translate(en, context: context)
            guard !Task.isCancelled, !natural.isEmpty else { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            naturalCache[en] = natural
            lastNatural = natural
            lastNaturalMs = ms
            lastTR = natural
            remember(en, natural)
            await post(id: id, tr: natural, en: en, ocrMs: ocrMs, tlMs: ms, final: true)
        } catch {
            // Guardrails or model busy: keep the quick translation (or make one now).
            if Task.isCancelled { return }
            if !quick.isEmpty {
                remember(en, quick)
            } else if let fallback = await translateQuick(en, id: id) {
                lastTR = fallback
                await post(id: id, tr: fallback, en: en, ocrMs: ocrMs, tlMs: 0, final: true)
            }
        }
    }

    /// Apple Translation, one request at a time. Returns nil when a newer line has arrived
    /// in the meantime (this one is no longer on screen) or the translator failed.
    private var names = EnglishPrep.seed

    /// A subtitle line into Turkish: first into plain English (slang, contractions, idioms),
    /// names kept away from the translator, then the on-device translator.
    private func translateLine(_ en: String, id: Int) async -> String? {
        let plain = EnglishPrep.plain(en)
        for name in EnglishPrep.learn(from: plain) where names.count < 300 { names.insert(name) }
        let parts = EnglishPrep.withoutNameEnds(plain, names: names)
        guard !parts.core.isEmpty else { return parts.lead }             // nothing but a name
        guard var turkish = await translateQuick(parts.core, id: id) else { return nil }
        // A name inside the line that came out as a word ("Jay" as the bird): once more with a
        // name the translator leaves alone, put back afterwards.
        if let lost = names.first(where: { EnglishPrep.has($0, in: parts.core) && turkish.range(of: $0, options: .caseInsensitive) == nil }) {
            let standIn = "Tomas"
            let swapped = parts.core.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: lost) + "\\b",
                                                          with: standIn, options: .regularExpression)
            if !EnglishPrep.has(standIn, in: parts.core), let again = await translateQuick(swapped, id: id), again.contains(standIn) {
                turkish = again.replacingOccurrences(of: standIn, with: lost)
            }
        }
        return parts.lead + turkish + parts.trail
    }

    /// For a line heard in the game's sound: the same translator, and the same rule that only
    /// one translation runs at a time (two at once fail, and the subtitle line then stays
    /// untranslated).
    private func translateHeard(_ en: String) async -> String? {
        while translating {
            await withCheckedContinuation { waiters.append($0) }
        }
        if let hit = quickCache[en] { return hit }
        guard let session else { return nil }
        translating = true
        defer {
            translating = false
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
        return try? await session.translate(en).targetText
    }

    private func translateQuick(_ en: String, id: Int) async -> String? {
        while translating {
            await withCheckedContinuation { waiters.append($0) }
        }
        if let hit = quickCache[en] { return hit }
        guard id >= newestJob, let session else { return nil }
        translating = true
        defer {
            translating = false
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
        do {
            let out = try await session.translate(en).targetText
            if quickCache.count > 3000 { quickCache.removeAll() }
            quickCache[en] = out
            return out
        } catch {
            status = "Çeviri hatası: \(error.localizedDescription)"
            return nil
        }
    }

    private func remember(_ en: String, _ tr: String) {
        recent.append((en, tr))
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
    }

    /// Says a line once. The same job is not said twice (quick version, then the natural
    /// one), and neither is a line that was just said: the TV sends a line again while it
    /// stays on screen.
    private func speak(id: Int, text: String) {
        guard voiceOn, id != lastSpokenJob else { return }
        let norm = text.lowercased().filter { $0.isLetter }
        guard !norm.isEmpty else { return }
        if Date().timeIntervalSince(lastSpokenAt) < 8, !lastSpoken.isEmpty,
           norm == lastSpoken || norm.hasPrefix(lastSpoken) || lastSpoken.hasPrefix(norm) { return }
        lastSpokenJob = id
        lastSpoken = norm
        lastSpokenAt = Date()
        let appeared = Date()
        newestLine = id
        let previous = speakQueue
        speakQueue = Task {
            await previous?.value
            if self.voiceEngine == 1, ZonosVoice.shared.isDownloaded {
                // The order of a conversation: a line that is playing is never cut, and when
                // several came while it played, only the newest is said next (older ones that
                // have not started stay text). So the voice follows the scene instead of
                // reading out a backlog.
                guard self.newestLine == id else {
                    self.note("voice \(id): left as text (a newer line came)")
                    return
                }
                var heard = await self.guessTasks[id]?.value ?? nil
                self.guessTasks[id] = nil
                if heard == nil { heard = await self.voiceTasks[id]?.value ?? nil }
                self.voiceTasks[id] = nil       // the proper listen goes on by itself and teaches the cast
                if self.playingUntil.timeIntervalSinceNow > 1.5 {
                    // The TV will be saying the line before for a while yet. This one is produced
                    // now, a little faster since it starts late, and kept back until that one is
                    // nearly over. (With less left to play, the line goes out piece by piece at
                    // once and the TV plays it straight after: producing it whole would take
                    // longer than the wait and leave a silence.)
                    let clip = await self.wholeClip(text, heard: heard, faster: true)
                    while self.playingUntil.timeIntervalSinceNow > 0.25, self.newestLine == id {
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    guard self.newestLine == id, let clip else {
                        self.note("voice \(id): left as text (a newer line came while it waited)")
                        return
                    }
                    let late = Date().timeIntervalSince(appeared)
                    self.note(String(format: "voice %d: said after the line before it, %.1f s after it appeared", id, late))
                    // The TV refuses a subtitle line five seconds late; one that waited its turn
                    // that long is still the newest thing said, so it goes as a free line.
                    _ = await self.send(clip, id: late > 4 ? 0 : id)
                    return
                }
                await self.say(text, id: id, heard: heard)
                return
            }
            var clip: Speaker.Clip?
            if self.voiceEngine == 2 {
                let heard = await self.toneTasks[id]?.value ?? Heard()
                self.toneTasks[id] = nil
                let line = heard.directions.isEmpty ? text : heard.directions + " " + text
                let voiceID = heard.voice ?? self.elevenVoice
                clip = await ElevenVoice.shared.speak(line, apiKey: self.elevenKey, voiceID: voiceID, model: self.elevenModel)
                let who = heard.voice == nil ? "" : " · " + ElevenVoice.shared.name(of: voiceID)
                self.voiceNote = clip != nil ? "ElevenLabs: \(ElevenVoice.shared.lastMs) ms\(who) \(heard.directions)" : ElevenVoice.shared.lastError
            }
            if clip == nil { clip = await self.speaker.render(text) }
            guard let clip else { return }
            _ = await self.send(clip, id: id)
        }
    }

    /// Asks the TV for the sound around the moment the line appeared and turns it into
    /// directions for the voice. Empty when there is nothing to go on (no sound yet, or our
    /// own previous line was playing then).
    private func readTone(id: Int) async -> Heard {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = 8090
        c.path = "/voice"
        c.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "before", value: "200"),
            URLQueryItem(name: "after", value: "350"),
        ]
        var heard = Heard()
        guard let url = c.url else { return heard }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        let pool = ElevenVoice.shared.voices
        guard let (data, response) = try? await net.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if voiceByCharacter { heard.voice = cast.voice(pitch: 0, pool: pool) }
            return heard
        }
        let parts = (http.value(forHTTPHeaderField: "X-Voice") ?? "").split(separator: ",").compactMap { Int($0) }
        // Our own previous line was playing then: nothing can be learned from that sound.
        guard parts.count == 2, parts[1] == 0, let reading = ToneTracker.measure(data, rate: parts[0]) else {
            if voiceByCharacter { heard.voice = cast.voice(pitch: 0, pool: pool) }
            return heard
        }
        if toneFollow, elevenModel == "eleven_v4_turbo" { heard.directions = tone.tags(for: reading) }
        if voiceByCharacter { heard.voice = cast.voice(pitch: reading.pitchHz, pool: pool) }
        return heard
    }

    // MARK: - Lines heard in the game's sound

    /// A heard line on its way to being spoken. It may start as a draft (the speaker paused,
    /// but might go on): then everything is prepared and only the playing waits for the word.
    private final class HeardLine {
        let english: String
        var confirmed: Bool
        var withdrawn = false
        init(english: String, confirmed: Bool) { self.english = english; self.confirmed = confirmed }
    }
    private var heardLines: [Int: HeardLine] = [:]
    // The subtitle lines of the last moments: a heard line that is the same speech as a subtitle
    // is left to the subtitle, which has the exact words.
    private var subtitleSeen: [(words: Set<String>, at: Date)] = []

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })
    }

    /// Is this heard line what a subtitle on screen says? True while a subtitle has just
    /// appeared (the speech being heard is then that line), or when half its words were in a
    /// subtitle of the last quarter minute.
    private func coveredBySubtitle(_ english: String) -> Bool {
        let now = Date()
        if subtitleSeen.contains(where: { now.timeIntervalSince($0.at) < 5 }) { return true }
        let heard = Self.words(english)
        guard !heard.isEmpty else { return false }
        let shown = subtitleSeen.filter { now.timeIntervalSince($0.at) < 15 }.reduce(into: Set<String>()) { $0.formUnion($1.words) }
        return heard.intersection(shown).count * 2 >= heard.count
    }
    private var earlyVoices: [Int: Task<[Float]?, Never>] = [:]

    /// The start of a line that is still being said: its voice is worked out meanwhile.
    func heardVoiceSample(_ number: Int, pcm: Data, rate: Int) {
        guard voiceOn, voiceSource == 1, voiceEngine == 1, zonosOwnVoice else { return }
        earlyVoices[number] = Task { await self.vectorIfWanted(pcm, rate: rate) }
        if earlyVoices.count > 20 { earlyVoices = earlyVoices.filter { $0.key > number - 10 } }
    }

    /// The speaker paused: prepare the line, but play nothing until it is confirmed.
    func heardDraft(_ number: Int, english: String, pcm: Data, rate: Int) {
        guard voiceOn, voiceSource == 1, heardLines[number] == nil else { return }
        begin(number, HeardLine(english: english, confirmed: false), pcm: pcm, rate: rate)
    }

    func heardWithdrawn(_ number: Int) {
        heardLines[number]?.withdrawn = true
        heardLines[number] = nil
    }

    /// A line heard in the game's sound (from `Listener`): translated and spoken in the voice of
    /// whoever said it. `pcm` is the stretch of sound the words were said in.
    func heard(_ number: Int, english: String, pcm: Data, rate: Int) {
        guard voiceOn, voiceSource == 1 else { return }
        if let line = heardLines[number], line.english == english, !line.withdrawn {
            line.confirmed = true           // already on its way as a draft
            return
        }
        heardWithdrawn(number)
        begin(number, HeardLine(english: english, confirmed: true), pcm: pcm, rate: rate)
    }

    private func begin(_ number: Int, _ line: HeardLine, pcm: Data, rate: Int) {
        heardLines[number] = line
        if heardLines.count > 30 { heardLines = heardLines.filter { $0.key > number - 15 } }
        let at = Date()
        let english = line.english
        let previous = speakQueue
        speakQueue = Task {
            await previous?.value
            // Lines pile up when people talk faster than we can speak: an old one is let go.
            guard !line.withdrawn, Date().timeIntervalSince(at) < 6 else { return }
            guard !self.coveredBySubtitle(english) else { self.note("heard line left to its subtitle: " + english); return }
            guard self.playingUntil.timeIntervalSinceNow < 3 else { self.note("heard line let go (still busy speaking): " + english); return }
            // Whose voice: from the start of the line if that is already being worked out,
            // otherwise from the first two seconds of what was heard; translated meanwhile.
            let early = self.earlyVoices[number]
            self.earlyVoices[number] = nil
            let sample = Data(pcm.prefix(rate * 2 * 2))
            async let voice = self.voiceOfLine(early: early, sample: sample, rate: rate)
            guard let turkish = await self.translateHeard(EnglishPrep.plain(english)), !turkish.isEmpty else { _ = await voice; return }
            var who: HeardVoice?
            if let vector = await voice {
                // Background talk is quieter and noisier than a subtitled line: the same voice
                // scored about 0.40 there, so that is where the line is drawn for heard lines.
                let match = self.heardCast.learn(vector, threshold: Self.heardMatch, pitch: Self.pitch(sample, rate: rate))
                who = HeardVoice(vector: match.vector, who: "karakter \(match.number)" + (match.isNew ? " (yeni)" : ""))
                self.note(String(format: "heard: character %d (%.2f)%@ | %@ => %@", match.number, match.similarity,
                                 match.isNew ? " NEW" : "", english, turkish))
            } else {
                self.note("heard: no voice | \(english) => \(turkish)")
            }
            // Nothing is played before the line is confirmed (at most about a second's wait).
            let go: () async -> Bool = {
                if await self.coveredBySubtitle(english) { return false }
                var waited = 0
                while !line.confirmed, !line.withdrawn, waited < 3000 {
                    try? await Task.sleep(for: .milliseconds(25))
                    waited += 25
                }
                return line.confirmed && !line.withdrawn
            }
            await self.say(turkish, id: 0, heard: who, go: go)
            self.note(String(format: "heard line %d: finished %d ms after it was heard%@", number,
                             Int(Date().timeIntervalSince(at) * 1000), line.withdrawn ? " (withdrawn)" : ""))
        }
    }

    /// How fast a line is read: the shorter, the calmer (a short reply at the top speed is over
    /// before it can be followed); `faster` for a line that starts late and has to catch up.
    private func readingRate(_ text: String, faster: Bool) -> Double {
        let base: Double = text.count <= 30 ? 14 : text.count <= 55 ? 17 : 20
        return min(zonosRate, faster ? base + 3 : base)
    }

    /// A whole line as one clip (from memory when it was said before in this voice).
    private func wholeClip(_ text: String, heard: HeardVoice?, faster: Bool) async -> Speaker.Clip? {
        let cacheKey = heard?.key.map { $0 + "|" + text }
        if let cacheKey, let clip = spokenLines[cacheKey] { return clip }
        for _ in 0..<2 {
            let clip = await ZonosVoice.shared.speak(text, voice: heard?.builtIn ?? zonosVoice, heard: heard?.vector, gpu: zonosGPU,
                                                     rate: readingRate(text, faster: faster), guarded: zonosGuard && !zonosPieces)
            guard let t = ZonosVoice.shared.lastTiming, let clip else {
                voiceNote = "ZONOS: " + ZonosVoice.shared.lastError
                return nil
            }
            // Now and then the model stops after a few hundredths of a second: one more try.
            if t.seconds < Double(text.count) / 45, text.count >= 4 { continue }
            voiceNote = String(format: "%.1f sn ses · %d ms'de hazır", t.seconds, t.totalMs) + " · " + (heard?.who ?? "yedek ses")
            if let cacheKey { rememberSpoken(cacheKey, clip) }
            return clip
        }
        return nil
    }

    /// Turns a Turkish line into sound and hands it to the TV. With ZONOS and "pieces" on, the
    /// first piece goes out while the rest is still being produced. `go` is asked once, before
    /// anything is sent.
    private func say(_ text: String, id: Int, heard: HeardVoice?, go: @escaping () async -> Bool = { true }) async {
        let cacheKey = heard?.key.map { $0 + "|" + text }
        if voiceEngine == 1, let cacheKey, let clip = spokenLines[cacheKey] {
            guard await go() else { return }
            voiceNote = "hazır ses (daha önce söylenmiş) · " + (heard?.who ?? "")
            note("line sent from memory: " + String(text.prefix(40)))
            _ = await send(clip, id: id)
            return
        }
        if voiceEngine == 1, ZonosVoice.shared.isDownloaded {
            let voice = heard?.builtIn ?? zonosVoice
            let rate = readingRate(text, faster: false)
            // One- and two-word lines go through the model's special handling for short texts,
            // which only comes out right when the line is produced whole.
            var pieces = zonosPieces && text.split(whereSeparator: { $0 == " " }).count > 2
            if pieces {
                let sid = Int.random(in: 1...Int(Int32.max))
                var cleared = false
                var whole = Data()
                let done = await ZonosVoice.shared.speakInPieces(text, voice: voice, heard: heard?.vector, gpu: zonosGPU, rate: rate) { clip, part in
                    if !cleared {
                        guard await go() else { return false }
                        cleared = true
                    }
                    whole.append(clip.pcm)
                    return await self.send(clip, id: id, sid: sid, part: part)
                }
                if done, let cacheKey, !whole.isEmpty { rememberSpoken(cacheKey, Speaker.Clip(pcm: whole, rate: 44100)) }
                if let t = ZonosVoice.shared.lastTiming, done {
                    voiceNote = String(format: "%.1f sn ses · ilk parça %d ms · %d parça", t.seconds, t.firstMs, t.parts) + " · " + (heard?.who ?? "yedek ses")
                    return
                }
                if cleared { return }               // something was already sent, or the line was withdrawn
                // Now and then the model stops after a few hundredths of a second: once more, whole.
                if ZonosVoice.shared.lastError == ZonosVoice.tooShort { pieces = false } else {
                    if !ZonosVoice.shared.lastError.isEmpty { voiceNote = "ZONOS: " + ZonosVoice.shared.lastError }
                    guard await go() else { return }
                }
            }
            if !pieces, let clip = await wholeClip(text, heard: heard, faster: false) {
                if await go() { _ = await send(clip, id: id) }
                return
            }
        }
        guard await go(), let clip = await speaker.render(text) else { return }
        _ = await send(clip, id: id)
    }

    private func voiceOfLine(early: Task<[Float]?, Never>?, sample: Data, rate: Int) async -> [Float]? {
        if let early, let vector = await early.value { return vector }
        return await vectorIfWanted(sample, rate: rate)
    }

    private func vectorIfWanted(_ sample: Data, rate: Int) async -> [Float]? {
        guard voiceEngine == 1, zonosOwnVoice, Self.audible(sample) else { return nil }
        return await ZonosVoice.shared.voiceVector(pcm: sample, rate: rate)
    }

    /// The game's sound around the moment a line appeared (16-bit mono), from the TV.
    /// `own`: our own previous line was playing then, so the clip is not the character alone.
    private func voiceClip(id: Int, before: Int, after: Int) async -> (pcm: Data, rate: Int, own: Bool)? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = 8090
        c.path = "/voice"
        c.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "before", value: String(before)),
            URLQueryItem(name: "after", value: String(after)),
        ]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Double(after) / 1000 + 2.5
        guard let (data, response) = try? await voiceNet.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let parts = (http.value(forHTTPHeaderField: "X-Voice") ?? "").split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0 else { return nil }
        return (data, parts[0], parts[1] != 0)
    }

    /// The part of a line's clip (which starts 0.2 s before the line appeared) that lies before
    /// the next line appeared; nil when that leaves less than a second.
    private func untilNextLine(_ pcm: Data, rate: Int, id: Int) -> Data? {
        guard let mine = lineStarts[id] ?? lineStarts.filter({ $0.key < id }).max(by: { $0.key < $1.key })?.value,
              let next = lineStarts.filter({ $0.key > id }).values.min() else { return pcm }
        let seconds = 0.2 + next.timeIntervalSince(mine) - 0.1
        let whole = Double(pcm.count / 2) / Double(rate)
        if seconds >= whole { return pcm }
        guard seconds >= 1.0 else { return nil }
        return Data(pcm.prefix(Int(seconds * Double(rate)) * 2))
    }

    private static func pitch(_ pcm: Data, rate: Int) -> Float {
        Float(ToneTracker.measure(pcm, rate: rate)?.pitchHz ?? 0)
    }

    /// Whose voice, at once, so that a line never waits: the first half second of the line
    /// gives the pitch, and the character who speaks at that pitch is taken, first among those
    /// heard in the last minute, then among everyone known. If nobody fits (a character not
    /// heard before), this one line is spoken in a built-in voice of the same kind (a man's
    /// or a woman's, by the pitch); the proper listen runs meanwhile, so from the character's
    /// next line on it is their own voice.
    private func guessVoice(id: Int) async -> HeardVoice? {
        var hz: Float = 0
        // A third of a second is enough for the pitch; every tenth waited here is a tenth later
        // that the line starts.
        if let clip = await voiceClip(id: id, before: 100, after: 200), !clip.own { hz = Self.pitch(clip.pcm, rate: clip.rate) }
        // No voice yet: the character may start a moment after the subtitle appears.
        if hz == 0, let clip = await voiceClip(id: id, before: 0, after: 550), !clip.own { hz = Self.pitch(clip.pcm, rate: clip.rate) }
        // First the people talking in this scene (confirmed in the last 40 s), then anyone known
        // who speaks at just this pitch (a character returning from an earlier scene).
        if let found = heardCast.guessInScene(pitch: hz, seconds: 40) {
            // Close to the pitch of someone talking right now: sure enough to skip the check with
            // the encoder, which is heavy. (Every fifth such line is still checked.)
            if found.distance <= 1.5, id % 5 != 0 {
                sureLines.insert(id)
                if sureLines.count > 60 { sureLines = sureLines.filter { $0 > id - 30 } }
                heardCast.touch(found.match.number)
            }
            note(String(format: "voice %d: guessed character %d of the %d talking (%.0f Hz, %.1f semitones off)", id, found.match.number, found.among, hz, found.distance))
            return HeardVoice(vector: found.match.vector, who: "karakter \(found.match.number) (tahmin)", number: found.match.number)
        }
        if let found = heardCast.guess(pitch: hz, seconds: .infinity, semitones: 2.0) {
            note(String(format: "voice %d: guessed known character %d by pitch (%.0f Hz, %.1f semitones off)", id, found.match.number, hz, found.distance))
            return HeardVoice(vector: found.match.vector, who: "karakter \(found.match.number) (tahmin)", number: found.match.number)
        }
        let men = ["Minjun", "Gaspard", "Wyatt", "Rupert"], women = ["Ximena", "Seoyeon", "Imogen"]
        var name = zonosVoice
        if hz >= 165, !women.contains(name) { name = women[0] }
        if hz > 0, hz < 165, !men.contains(name) { name = men[0] }
        note(String(format: "voice %d: nobody known at %.0f Hz, built-in voice %@ for this line", id, hz, name))
        return HeardVoice(vector: [], who: "yedek ses (\(name))", builtIn: name)
    }

    /// Is there enough sound in the clip for a voice to be in it? (Level above about -45 dB.)
    private static func audible(_ pcm: Data) -> Bool {
        let count = pcm.count / 2
        guard count > 0 else { return false }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(Int16(littleEndian: samples[i])) / 32768
                sum += v * v
            }
        }
        return (sum / Double(count)).squareRoot() > 0.0056
    }

    /// Whose voice says this line. A character heard before is recognised from the first
    /// second of the line; otherwise two seconds are listened to, and the speaker either
    /// turns out to be a known character after all or joins as a new one. When the line's own
    /// sound cannot be used (our previous Turkish line was still playing, or there was no
    /// sound), the character who spoke last keeps the floor.
    private func heardVoice(id: Int) async -> HeardVoice? {
        // This no longer decides the voice of the line itself (see guessVoice): it teaches the
        // cast for the lines to come. One clip of two seconds, fetched now because the TV only
        // keeps the last seconds; the encoder then runs when no line is being produced.
        var reason = "klip alınamadı"
        if sureLines.contains(id) { return nil }
        if let long = await voiceClip(id: id, before: 200, after: 1800) {
            if sureLines.contains(id) { return nil }
            if long.own {
                reason = "kendi sesimiz çalıyordu"
            } else if !Self.audible(long.pcm) {
                reason = "sessiz"
            } else if let pcm = untilNextLine(long.pcm, rate: long.rate, id: id) {
                guard let vector = await ZonosVoice.shared.voiceVector(pcm: pcm, rate: long.rate) else {
                    note("voice \(id): could not be worked out")
                    return nil
                }
                let match = heardCast.learn(vector, threshold: Self.slowMatch, pitch: Self.pitch(pcm, rate: long.rate))
                note(String(format: "voice %d: character %d from %.1f s (%.2f)%@, %d known", id, match.number,
                            Double(pcm.count / 2) / Double(long.rate), match.similarity, match.isNew ? " NEW" : "", heardCast.count))
                return HeardVoice(vector: match.vector, who: "karakter \(match.number)" + (match.isNew ? " (yeni)" : ""))
            } else {
                note("voice \(id): the next line came too soon to learn this voice")
                return nil
            }
        }
        guard let last = heardCast.latest else {
            note("voice \(id): no character yet (\(reason))")
            return nil
        }
        note("voice \(id): kept character \(last.number) (\(reason))")
        return HeardVoice(vector: last.vector, who: "karakter \(last.number) (son konuşan)")
    }

    /// Leaves a line in the TV's log, so what happened can be read from there afterwards.
    private func note(_ message: String) {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = 8090; c.path = "/note"
        c.queryItems = [URLQueryItem(name: "k", value: key), URLQueryItem(name: "msg", value: message)]
        guard let url = c.url else { return }
        Task { _ = try? await self.voiceNet.data(from: url) }
    }

    /// Hands the spoken line to the TV (`POST /say`, 16-bit mono samples in the body).
    /// `sid`/`part`: a line sent in pieces (same sid, parts 0, 1, 2…). False when the TV did not
    /// take it (too late, or the line already has its voice): the rest need not be sent.
    @discardableResult
    private func send(_ clip: Speaker.Clip, id: Int, sid: Int = 0, part: Int = 0) async -> Bool {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = 8090
        c.path = "/say"
        c.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "rate", value: String(clip.rate)),
            URLQueryItem(name: "sid", value: String(sid)),
            URLQueryItem(name: "part", value: String(part)),
        ]
        guard let url = c.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        guard let (data, _) = try? await voiceNet.upload(for: request, from: clip.pcm) else { return false }
        guard String(data: data, encoding: .utf8) == "ok" else { return false }
        playingUntil = max(playingUntil, Date()).addingTimeInterval(Double(clip.pcm.count / 2) / Double(max(clip.rate, 1)))
        return true
    }

    private func post(id: Int, tr: String, en: String, ocrMs: Int, tlMs: Int, final: Bool) async {
        if !tr.isEmpty {
            subtitleSeen.append((Self.words(en), Date()))
            if subtitleSeen.count > 12 { subtitleSeen.removeFirst(subtitleSeen.count - 12) }
            speak(id: id, text: tr)
        }
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = 8090
        c.path = "/result"
        c.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "tr", value: tr),
            URLQueryItem(name: "en", value: en),
            URLQueryItem(name: "ocr", value: String(ocrMs)),
            URLQueryItem(name: "tl", value: String(tlMs)),
            URLQueryItem(name: "final", value: final ? "1" : "0"),
        ]
        // URLComponents leaves "+" unescaped, which servers read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        _ = try? await net.data(for: request)
    }

    // MARK: - Image and reading

    /// The TV sends the crop at its capture size (subtitle letters are only ~10 px tall).
    /// Stretch the contrast and enlarge it with smooth interpolation so Vision reads it well.
    nonisolated static func makeImage(gray: Data, width: Int, height: Int, scale: Int) -> CGImage? {
        let count = width * height
        guard width > 0, height > 0, gray.count >= count else { return nil }
        var lo: UInt8 = 255, hi: UInt8 = 0
        var pixels = [UInt8](repeating: 0, count: count)
        gray.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = raw[i]
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            let range = max(1, Int(hi) - Int(lo))
            for i in 0..<count {
                pixels[i] = UInt8((Int(raw[i]) - Int(lo)) * 255 / range)
            }
        }
        let space = CGColorSpaceCreateDeviceGray()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let small = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width * scale, height: height * scale,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        return context.makeImage()
    }

    /// Reads the English text in the crop, off the main thread.
    /// Whether two readings are the same line (letters only, shared letter pairs).
    nonisolated static func alike(_ a: String, _ b: String) -> Bool {
        func pairs(_ text: String) -> [String: Int] {
            let letters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
            var out: [String: Int] = [:]
            guard letters.count >= 2 else { return out }
            for i in 0..<(letters.count - 1) { out[String(letters[i...(i + 1)]), default: 0] += 1 }
            return out
        }
        let x = pairs(a), y = pairs(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total >= 8 else { return false }
        var shared = 0
        for (pair, count) in x { shared += min(count, y[pair] ?? 0) }
        return Double(2 * shared) / Double(total) >= 0.6
    }

    nonisolated static func recognize(_ image: CGImage, fast: Bool) async -> (text: String, confidence: Float) {
        await Task.detached(priority: .userInitiated) { () -> (text: String, confidence: Float) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return ("", 0)
            }
            var sure: Float = 0
            var count: Float = 0
            let pieces: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { observation in
                guard let best = observation.topCandidates(1).first else { return nil }
                sure += best.confidence
                count += 1
                return (observation.boundingBox, best.string)
            }
            return (joinRows(pieces), count > 0 ? sure / count : 0)
        }.value
    }

    /// Vision returns pieces of text with their boxes (origin bottom-left). Put pieces that
    /// share a row in left-to-right order, rows top to bottom, and join a wrapped sentence
    /// into one line so it is translated as a whole. A row that starts a new speaker
    /// ("- ...", "NAME: ...") keeps its line break.
    nonisolated static func joinRows(_ pieces: [(box: CGRect, text: String)]) -> String {
        var rows: [[(box: CGRect, text: String)]] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - piece.box.midY) < max(anchor.box.height, piece.box.height) * 0.5 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        var text = ""
        for row in rows {
            let line = row.sorted { $0.box.minX < $1.box.minX }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            if line.isEmpty { continue }
            if text.isEmpty {
                text = line
            } else if startsNewSpeaker(line) {
                text += "\n" + line
            } else {
                text += " " + line
            }
        }
        return text
    }

    nonisolated static func startsNewSpeaker(_ line: String) -> Bool {
        if line.hasPrefix("-") || line.hasPrefix("–") || line.hasPrefix("—") { return true }
        // "LUCIA: ..." style label: a short all-caps word group before a colon.
        if let colon = line.firstIndex(of: ":") {
            let label = line[line.startIndex..<colon]
            if label.count >= 2, label.count <= 24, label == label.uppercased(),
               label.contains(where: { $0.isLetter }) { return true }
        }
        return false
    }

    /// At least two letters: guards against specks and scene details read as "." or "|".
    nonisolated static func looksLikeText(_ text: String) -> Bool {
        text.filter { $0.isLetter }.count >= 2
    }
}

/// A short, URL-safe device label for the TV's status page.
enum UIDeviceName {
    static var current: String {
        let raw = ProcessInfo.processInfo.hostName
        return raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "iphone"
    }
}

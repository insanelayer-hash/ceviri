import Foundation

/// ZONOS3-Mini on the phone (experiment): a far more natural Turkish voice than the system
/// one. The two model files (about 1.1 GB together) are downloaded once from Hugging Face and
/// kept in the app's own folder; after that everything runs on the phone.
///
/// The model's own server (the code behind Zyphra's playground) runs inside the app and is
/// asked over 127.0.0.1, so a line gets everything the playground does: Turkish text
/// preparation (numbers, dates), the handling of one- and two-word lines, and the alignment
/// guard that stops skipped or repeated words.
final class ZonosVoice: @unchecked Sendable {
    struct Timing {
        let seconds: Double     // length of the sound
        let totalMs: Int        // from the request to the finished sound
        let startMs: Int        // of that, starting the model (0 when it was already running)
        var firstMs = 0         // until the first piece was handed over (pieces only)
        var parts = 1
    }

    static let shared = ZonosVoice()
    static let voiceNames = ["Minjun", "Gaspard", "Wyatt", "Rupert", "Seoyeon", "Ximena", "Imogen"]

    // `exact`: the size is known to the byte and checked; otherwise it is only what to expect.
    // backbone-ptq-edit.gguf is the model with the extra text rows (pause and start tokens) that
    // the handling of one- and two-word lines needs; otherwise the same as backbone-ptq.gguf.
    private static let files: [(name: String, size: Int64, exact: Bool)] = [
        ("backbone-ptq-edit.gguf", 663_491_840, true),
        ("zac-keep2.gguf", 452_325_440, true),
        (encoderFile, 45_385_728, true),
    ]
    static let encoderFile = "spk-encoder.gguf"
    static let tooShort = "çok kısa çıktı"
    /// Files of earlier versions of the app that are no longer used.
    private static let retired = ["backbone-ptq.gguf"]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    private static func present(_ file: (name: String, size: Int64, exact: Bool)) -> Bool {
        let have = size(of: folder.appendingPathComponent(file.name))
        return file.exact ? have == file.size : have > file.size * 9 / 10
    }

    /// What is still to be downloaded, in bytes.
    var missingBytes: Int64 { Self.files.filter { !Self.present($0) }.reduce(0) { $0 + $1.size } }

    // Starting and stopping the server happens on one queue; it speaks one line at a time.
    private let queue = DispatchQueue(label: "zonos", qos: .userInitiated)
    // The speaker encoder works on its own: a line must not wait for it before it can be spoken.
    private let encoderQueue = DispatchQueue(label: "zonos-voice", qos: .utility)
    private var port: Int32 = 0
    // Lines being produced right now. The speaker encoder waits while this is above zero:
    // the two together overload the phone and a line then takes seconds instead of tenths.
    private var speaking = 0
    private func speakingChanged(_ by: Int) { lock.lock(); speaking += by; lock.unlock() }
    private var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return speaking > 0 }
    // The speaker encoder is heavy enough to slow everything else on the phone (a translation
    // that takes 0.1 s took 3.5 s beside it). It is background learning, so it also keeps out
    // of the way while subtitle lines are coming in, and runs in the pauses of a conversation.
    private var encoderBackUntil = Date.distantPast
    func keepEncoderBack(for seconds: TimeInterval) {
        lock.lock(); encoderBackUntil = max(encoderBackUntil, Date().addingTimeInterval(seconds)); lock.unlock()
    }
    private var encoderMustWait: Bool {
        lock.lock(); defer { lock.unlock() }
        return speaking > 0 || encoderBackUntil > Date()
    }

    /// Loads the model ahead of the first line (it takes several seconds), so that line is
    /// not late. Does nothing when it is already running.
    func warmUp(gpu: Bool) async {
        guard isDownloaded else { return }
        _ = await server(gpu: gpu, restart: false)
        encoderQueue.async {
            if self.encoder == nil {
                let path = Self.folder.appendingPathComponent(Self.encoderFile).path
                if FileManager.default.fileExists(atPath: path) { self.encoder = zb_voice_open(path, 0) }
            }
        }
    }
    private var encoder: UnsafeMutableRawPointer?
    private var loadedWithGPU = false
    private var voices: [String: String] = [:]      // name -> the .npy file, base64
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
    private let lock = NSLock()
    private var timing: Timing?
    private var failure = ""

    var lastTiming: Timing? { lock.lock(); defer { lock.unlock() }; return timing }
    var lastError: String { lock.lock(); defer { lock.unlock() }; return failure }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zonos", isDirectory: true)
    }

    private static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    var isDownloaded: Bool {
        Self.files.allSatisfy { Self.present($0) }
    }

    // MARK: - Download

    /// Fetches the files that are not there yet. `progress` gets 0...1 about twice a second.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var folder = Self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // 1 GB that can be downloaded again
        try? folder.setResourceValues(values)

        var done: Int64 = 0
        for file in Self.files {
            let destination = Self.folder.appendingPathComponent(file.name)
            if !Self.present(file) {
                let base = done
                let url = URL(string: "https://huggingface.co/Zyphra/ZONOS3-Mini/resolve/main/gguf/" + file.name)!
                try await fetch(url, to: destination) { received in
                    progress(Double(base + received) / Double(Self.totalBytes))
                }
                if !Self.present(file) {
                    try? FileManager.default.removeItem(at: destination)
                    throw URLError(.cannotDecodeContentData)
                }
            }
            done += file.size
            progress(Double(done) / Double(Self.totalBytes))
        }
        for name in Self.retired {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name))
        }
    }

    private func fetch(_ url: URL, to destination: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                do {
                    // The temporary file disappears when this handler returns.
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak task] in
                guard let task, task.state == .running else { timer.cancel(); return }
                received(task.countOfBytesReceived)
            }
            timer.resume()
            task.resume()
        }
    }

    func deleteFiles() {
        queue.sync {
            zb_server_stop()
            port = 0
        }
        encoderQueue.sync {
            if let encoder { zb_voice_close(encoder) }
            encoder = nil
        }
        try? FileManager.default.removeItem(at: Self.folder)
    }

    /// Frees the model's memory (about 1.1 GB); the next line starts it again.
    func stop() {
        queue.async {
            zb_server_stop()
            self.port = 0
        }
    }

    // MARK: - Speaking

    /// Turns a line into sound in one of the built-in voices. Returns nil when the model is
    /// not downloaded or something failed (`lastError` says what).
    /// `rate`: speaking rate in characters per second (the model's studio goes up to about 20).
    /// `guarded`: the alignment guard on every line (one- and two-word lines always get it).
    /// `heard`: the speaker vector of the character who is talking (`voiceVector`); when given,
    /// the line is spoken in that voice instead of the built-in one.
    func speak(_ text: String, voice: String, heard: [Float]? = nil, gpu: Bool, rate: Double = 20, guarded: Bool = true) async -> Speaker.Clip? {
        speakingChanged(1)
        defer { speakingChanged(-1) }
        let began = Date()
        guard isDownloaded else { return fail("model indirilmemiş") }
        let speaker: String
        if let heard, !heard.isEmpty {
            speaker = Self.npy(heard).base64EncodedString()
        } else {
            guard let builtIn = await embedding(for: voice) else { return fail("ses dosyası bulunamadı: " + voice) }
            speaker = builtIn
        }
        var startMs = 0
        // A second try covers the server having been closed while the app was in the background.
        for attempt in 0..<2 {
            let starting = Date()
            let (port, fresh) = await server(gpu: gpu, restart: attempt > 0)
            guard port > 0 else { return fail("model başlatılamadı") }
            if fresh { startMs += Int(Date().timeIntervalSince(starting) * 1000) }

            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/generate")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The delivery settings are the ones the model's own studio uses for a clean, lively
            // line: full bandwidth, a firm loudness and the chosen speaking rate.
            var body: [String: Any] = [
                "text": text,
                "language": "tr",
                "stream": false,
                "format": "wav",
                "seed": Int.random(in: 1...1_000_000),
                "speaker_mode": "embedding",
                "speaker_embedding_base64": speaker,
                "condition_values": ["loudness": -17.0, "fmax": 20000.0, "speaking_rate": rate],
            ]
            if guarded { body["laci"] = true }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    return fail("sunucu \(status): " + (String(data: data.prefix(300), encoding: .utf8) ?? ""))
                }
                guard let whole = Self.clip(fromWav: data) else { return fail("ses çözülemedi") }
                let clip = Self.tightened(whole)
                lock.lock()
                timing = Timing(seconds: Double(clip.pcm.count / 2) / Double(max(clip.rate, 1)),
                                totalMs: Int(Date().timeIntervalSince(began) * 1000), startMs: startMs)
                failure = ""
                lock.unlock()
                return clip
            } catch {
                if attempt == 1 { return fail("sunucuya ulaşılamadı: " + error.localizedDescription) }
            }
        }
        return nil
    }

    /// Like `speak`, but hands the sound over in pieces while the model is still producing the
    /// rest, so the line can start playing early: a first piece of about 0.7 s, then the rest
    /// in one or two more. Pieces are cut at a quiet spot so the joins cannot be heard. A short
    /// line, or a phone running too slowly to stay ahead of the playback, comes as one piece.
    /// `piece` returns false to stop (the line was withdrawn). Returns true when a line was
    /// produced. The alignment guard is left out here: it holds the sound back until the end.
    func speakInPieces(_ text: String, voice: String, heard: [Float]? = nil, gpu: Bool, rate: Double = 20,
                       piece: @escaping (Speaker.Clip, Int) async -> Bool) async -> Bool {
        speakingChanged(1)
        defer { speakingChanged(-1) }
        let began = Date()
        guard isDownloaded else { _ = fail("model indirilmemiş"); return false }
        let speaker: String
        if let heard, !heard.isEmpty {
            speaker = Self.npy(heard).base64EncodedString()
        } else {
            guard let builtIn = await embedding(for: voice) else { _ = fail("ses dosyası bulunamadı: " + voice); return false }
            speaker = builtIn
        }
        var startMs = 0
        for attempt in 0..<2 {
            let starting = Date()
            let (port, fresh) = await server(gpu: gpu, restart: attempt > 0)
            guard port > 0 else { _ = fail("model başlatılamadı"); return false }
            if fresh { startMs += Int(Date().timeIntervalSince(starting) * 1000) }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/generate")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "text": text, "language": "tr", "stream": true, "format": "pcm",
                "seed": Int.random(in: 1...1_000_000),
                "speaker_mode": "embedding", "speaker_embedding_base64": speaker,
                "condition_values": ["loudness": -17.0, "fmax": 20000.0, "speaking_rate": rate],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let asked = Date()
                let (bytes, response) = try await session.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { _ = fail("sunucu \(status)"); return false }
                let sampleRate = 44100
                var samples: [Int16] = []           // everything received so far
                samples.reserveCapacity(sampleRate * 8)
                var four: [UInt8] = []
                four.reserveCapacity(4)
                var sent = 0, parts = 0, quietRun = 0
                var oneGo = false                   // too slow to stay ahead: send it whole at the end
                var firstMs = 0
                // Up to `end`, cut at the quietest 10 ms of the last 200 ms.
                func quietCut(_ end: Int) -> Int {
                    let window = sampleRate / 100
                    var best = end, bestEnergy = Double.infinity
                    var at = max(sent + window, end - sampleRate / 5)
                    while at + window <= end {
                        var e = 0.0
                        for i in at..<(at + window) { let v = Double(samples[i]); e += v * v }
                        if e < bestEnergy { bestEnergy = e; best = at + window / 2 }
                        at += window / 2
                    }
                    return best
                }
                func hand(_ to: Int) async -> Bool {
                    guard to > sent else { return true }
                    let slice = samples[sent..<to]
                    sent = to
                    let data = slice.withUnsafeBufferPointer { Data(buffer: $0) }
                    if parts == 0 { firstMs = Int(Date().timeIntervalSince(began) * 1000) }
                    parts += 1
                    return await piece(Speaker.Clip(pcm: data, rate: sampleRate), parts - 1)
                }
                var firstSound: Date?
                for try await byte in bytes {
                    if firstSound == nil { firstSound = Date() }
                    four.append(byte)
                    guard four.count == 4 else { continue }
                    let bits = UInt32(four[0]) | UInt32(four[1]) << 8 | UInt32(four[2]) << 16 | UInt32(four[3]) << 24
                    four.removeAll(keepingCapacity: true)
                    let v = Float(bitPattern: bits)
                    let sample = Int16(max(-1, min(1, v.isFinite ? v : 0)) * 32767)
                    // The model pauses 0.2-0.4 s after a comma and longer between sentences. In a
                    // dubbed conversation that time is needed: a silence is kept to 0.16 s.
                    if abs(Int(sample)) < Self.quietLevel {
                        quietRun += 1
                        if quietRun > sampleRate * 16 / 100 { continue }
                    } else {
                        quietRun = 0
                    }
                    samples.append(sample)
                    guard samples.count % 2048 == 0, !oneGo else { continue }
                    if parts == 0 {
                        // The silence the model opens with is not worth sending.
                        if sent == 0, let loud = samples.firstIndex(where: { abs(Int($0)) > 130 }) {
                            sent = max(0, loud - sampleRate * 15 / 1000)
                        }
                        // The first piece is small so the line starts at once; the next ones grow
                        // (0.35, 0.6, 1.0, then 1.5 s), each ready well before the one before it ends.
                        guard samples.count - sent >= sampleRate * 35 / 100 else { continue }
                        // Is the model comfortably faster than the playback? Otherwise there would be gaps.
                        // Measured from the first sound that arrived: the wait before it (reading
                        // the text, the voice) is paid once and says nothing about the pace after.
                        let speed = Double(samples.count) / Double(sampleRate) / max(Date().timeIntervalSince(firstSound ?? asked), 0.05)
                        if speed < 1.5 { oneGo = true; continue }
                        if !(await hand(quietCut(samples.count))) { return false }
                    } else if samples.count - sent >= sampleRate * (parts == 1 ? 60 : parts == 2 ? 100 : 150) / 100 {
                        if !(await hand(quietCut(samples.count))) { return false }
                    }
                }
                guard !samples.isEmpty else { _ = fail("ses gelmedi"); return false }
                if parts == 0, let loud = samples.firstIndex(where: { abs(Int($0)) > 130 }) {
                    sent = max(0, loud - sampleRate * 15 / 1000)
                }
                // The whole line in a few hundredths of a second: the model stopped at once (it
                // happens now and then). Nothing is sent; the caller tries again.
                if parts == 0, Double(samples.count - sent) / Double(sampleRate) < Double(text.count) / 45, text.count >= 4 {
                    _ = fail(Self.tooShort)
                    return false
                }
                if samples.count - sent > sampleRate / 50 { _ = await hand(samples.count) }
                lock.lock()
                timing = Timing(seconds: Double(samples.count) / Double(sampleRate),
                                totalMs: Int(Date().timeIntervalSince(began) * 1000), startMs: startMs, firstMs: firstMs, parts: parts)
                failure = ""
                lock.unlock()
                return true
            } catch {
                if attempt == 1 { _ = fail("sunucuya ulaşılamadı: " + error.localizedDescription); return false }
            }
        }
        return false
    }

    private func fail(_ message: String) -> Speaker.Clip? {
        lock.lock(); failure = message; lock.unlock()
        return nil
    }

    /// The port of the running server, starting it when needed (loading the files takes a few
    /// seconds). `fresh` tells whether this call had to start it.
    private func server(gpu: Bool, restart: Bool) async -> (port: Int32, fresh: Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(port: Int32, fresh: Bool), Never>) in
            queue.async {
                if self.port > 0, self.loadedWithGPU == gpu, !restart {
                    continuation.resume(returning: (self.port, false)); return
                }
                zb_server_stop()
                let backbone = Self.folder.appendingPathComponent(Self.files[0].name).path
                let decoder = Self.folder.appendingPathComponent(Self.files[1].name).path
                let heads = Bundle.main.path(forResource: "zonos3_mini_heads_tr", ofType: "json") ?? ""
                self.port = zb_server_start(backbone, decoder, "tr", heads, gpu ? 1 : 0)
                self.loadedWithGPU = gpu
                continuation.resume(returning: (self.port, true))
            }
        }
    }

    private func embedding(for voice: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                if let known = self.voices[voice] { continuation.resume(returning: known); return }
                guard let path = Bundle.main.path(forResource: voice, ofType: "npy"),
                      let file = FileManager.default.contents(atPath: path) else {
                    continuation.resume(returning: nil); return
                }
                let encoded = file.base64EncodedString()
                self.voices[voice] = encoded
                continuation.resume(returning: encoded)
            }
        }
    }

    // MARK: - The voice of whoever is talking

    /// The speaker vector (192 numbers) of a clip of someone speaking: 16-bit mono samples at
    /// 16000 per second, as the TV hands them over. Nil when the encoder is missing or failed.
    func voiceVector(pcm: Data, rate: Int) async -> [Float]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float]?, Never>) in
            encoderQueue.async {
                if self.encoder == nil {
                    let path = Self.folder.appendingPathComponent(Self.encoderFile).path
                    guard FileManager.default.fileExists(atPath: path) else { continuation.resume(returning: nil); return }
                    self.encoder = zb_voice_open(path, 0)
                }
                guard let encoder = self.encoder else { continuation.resume(returning: nil); return }
                // Speaking comes first: wait for a quiet moment (the TV is then playing the line).
                var waited = 0
                while self.encoderMustWait, waited < 8_000 {
                    Thread.sleep(forTimeInterval: 0.05)
                    waited += 50
                }
                // No pause in eight seconds: this clip is let go rather than run in the way.
                guard !self.encoderMustWait else { continuation.resume(returning: nil); return }
                let count = pcm.count / 2
                guard count > rate / 2 else { continuation.resume(returning: nil); return }
                var samples = [Float](repeating: 0, count: count)
                pcm.withUnsafeBytes { raw in
                    let input = raw.bindMemory(to: Int16.self)
                    for i in 0..<count { samples[i] = Float(Int16(littleEndian: input[i])) / 32768 }
                }
                var out = [Float](repeating: 0, count: 192)
                let n = zb_voice_embed(encoder, samples, Int32(count), Int32(rate), &out, 192)
                continuation.resume(returning: n == 192 ? out : nil)
            }
        }
    }

    /// A list of numbers as a NumPy .npy file (the form the server takes a speaker vector in).
    private static func npy(_ values: [Float]) -> Data {
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(values.count),), }"
        while (10 + header.utf8.count + 1) % 64 != 0 { header += " " }
        header += "\n"
        var data = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let length = UInt16(header.utf8.count)
        data.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
        data.append(Data(header.utf8))
        values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    static let quietLevel = 200          // of 32768: about -44 dB

    /// A spoken line without its dead air: at most 0.16 s of silence inside it, 15 ms before
    /// the first sound and 60 ms after the last. Cuts fall inside silence, so nothing clicks.
    static func tightened(_ clip: Speaker.Clip) -> Speaker.Clip {
        let count = clip.pcm.count / 2
        guard count > clip.rate / 10 else { return clip }
        var input = [Int16](repeating: 0, count: count)
        _ = input.withUnsafeMutableBytes { clip.pcm.copyBytes(to: $0) }
        guard let firstLoud = input.firstIndex(where: { abs(Int($0)) >= quietLevel }),
              let lastLoud = input.lastIndex(where: { abs(Int($0)) >= quietLevel }) else { return clip }
        let from = max(0, firstLoud - clip.rate * 15 / 1000)
        let to = min(count, lastLoud + clip.rate * 60 / 1000)
        var out: [Int16] = []
        out.reserveCapacity(to - from)
        var quietRun = 0
        for i in from..<to {
            if abs(Int(input[i])) < quietLevel {
                quietRun += 1
                if quietRun > clip.rate * 16 / 100 { continue }
            } else {
                quietRun = 0
            }
            out.append(input[i])
        }
        return Speaker.Clip(pcm: out.withUnsafeBufferPointer { Data(buffer: $0) }, rate: clip.rate)
    }

    /// The samples of a 16-bit mono WAV file.
    private static func clip(fromWav data: Data) -> Speaker.Clip? {
        let bytes = [UInt8](data)
        guard bytes.count > 44, bytes[0...3].elementsEqual("RIFF".utf8), bytes[8...11].elementsEqual("WAVE".utf8) else { return nil }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        var rate = 44100, channels = 1, bits = 16
        var position = 12
        while position + 8 <= bytes.count {
            let size = u32(position + 4)
            let start = position + 8
            if bytes[position...position + 3].elementsEqual("fmt ".utf8), start + 16 <= bytes.count {
                channels = Int(bytes[start + 2]) | Int(bytes[start + 3]) << 8
                rate = u32(start + 4)
                bits = Int(bytes[start + 14]) | Int(bytes[start + 15]) << 8
            } else if bytes[position...position + 3].elementsEqual("data".utf8) {
                guard channels == 1, bits == 16 else { return nil }
                let end = min(bytes.count, start + size)
                let length = (end - start) / 2 * 2
                guard length > 0 else { return nil }
                return Speaker.Clip(pcm: data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length)), rate: rate)
            }
            position = start + size + (size & 1)
        }
        return nil
    }
}

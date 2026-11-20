import Foundation
import Speech
import AVFoundation

/// A rough "voice print" of a stretch of speech: the shape of its spectrum and how high the
/// voice is. Enough to tell clearly different voices apart; similar voices may be confused.
struct VoicePrint {
    let bands: [Double]     // log energy in 18 bands, gain removed
    let pitch: Double       // Hz, 0 = unknown

    func distance(to other: VoicePrint) -> Double {
        var sum = 0.0
        for i in 0..<min(bands.count, other.bands.count) {
            let d = bands[i] - other.bands[i]
            sum += d * d
        }
        // In a game's mix the spectrum shape moves with the background, so how high the voice
        // is counts for more: three semitones apart weigh as much as a clearly different shape.
        var d = 0.5 * sqrt(sum / Double(max(bands.count, 1)))
        if pitch > 0, other.pitch > 0 { d += abs(12 * log2(pitch / other.pitch)) / 3 } else { d += 0.3 }
        return d
    }

    /// This print moved a step towards another reading of the same speaker.
    func blended(with other: VoicePrint, weight: Double) -> VoicePrint {
        var mixed = bands
        for i in 0..<min(bands.count, other.bands.count) { mixed[i] = bands[i] * (1 - weight) + other.bands[i] * weight }
        let height = pitch > 0 && other.pitch > 0 ? pitch * (1 - weight) + other.pitch * weight : max(pitch, other.pitch)
        return VoicePrint(bands: mixed, pitch: height)
    }

    static func make(_ samples: [Int16], rate: Int) -> VoicePrint? {
        let size = 512, hop = 160
        guard samples.count >= rate / 2 else { return nil }
        var frames: [(energy: Double, spectrum: [Double])] = []
        var re = [Double](repeating: 0, count: size), im = [Double](repeating: 0, count: size)
        var start = 0
        while start + size <= samples.count {
            var energy = 0.0
            for i in 0..<size {
                let v = Double(samples[start + i]) / 32768
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(size - 1))
                re[i] = v * w
                im[i] = 0
                energy += v * v
            }
            fft(&re, &im)
            var mags = [Double](repeating: 0, count: size / 2)
            for i in 0..<(size / 2) { mags[i] = re[i] * re[i] + im[i] * im[i] }
            frames.append((energy, mags))
            start += hop
        }
        guard frames.count >= 20 else { return nil }
        // Only the louder frames: the speech rather than the gaps.
        let threshold = frames.map { $0.energy }.sorted()[frames.count * 2 / 5]
        let loud = frames.filter { $0.energy >= threshold && $0.energy > 1e-7 }
        guard loud.count >= 10 else { return nil }

        // 18 bands evenly spaced on a mel-like scale between 150 and 5000 Hz.
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hertz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let count = 18
        let low = mel(150), high = mel(5000)
        var bands = [Double](repeating: 0, count: count)
        for b in 0..<count {
            let f0 = hertz(low + (high - low) * Double(b) / Double(count))
            let f1 = hertz(low + (high - low) * Double(b + 1) / Double(count))
            let i0 = max(1, Int(f0 * Double(size) / Double(rate)))
            let i1 = min(size / 2 - 1, max(i0, Int(f1 * Double(size) / Double(rate))))
            var sum = 0.0
            for frame in loud { for i in i0...i1 { sum += frame.spectrum[i] } }
            bands[b] = log10(sum / Double(loud.count * (i1 - i0 + 1)) + 1e-12)
        }
        let mean = bands.reduce(0, +) / Double(count)
        bands = bands.map { $0 - mean }

        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count { out[i] = samples[i].littleEndian }
        }
        let pitch = ToneTracker.measure(data, rate: rate)?.pitchHz ?? 0
        return VoicePrint(bands: bands, pitch: pitch)
    }

    private static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            var i = 0
            while i < n {
                for k in 0..<(length / 2) {
                    let wr = cos(angle * Double(k)), wi = sin(angle * Double(k))
                    let a = i + k, b = i + k + length / 2
                    let xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                }
                i += length
            }
            length <<= 1
        }
    }
}

/// Listening experiment: takes the game sound from the TV as a running stream, lets the
/// phone's speech recognition write down the English it hears, and gives each stretch of
/// speech a speaker number. Nothing is translated or spoken yet; the lines are only shown.
@MainActor
final class Listener: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let speaker: Int
        let pitch: Int
        let text: String
    }

    @Published var lines: [Line] = []
    @Published var status = ""
    @Published var running = false
    @Published var partial = ""
    /// Called for each line heard: the English words and the stretch of sound they were said
    /// in (16-bit mono at 16000 per second), for translating and speaking it.
    /// The Int is the line's number: the calls below about the same line carry the same one.
    var onLine: ((Int, String, Data) -> Void)?
    /// The first second and a half of a line that is still being said: enough to work out whose
    /// voice it is before the line ends.
    var onVoice: ((Int, Data) -> Void)?
    /// The line probably ended (a short pause): translating and speaking can begin, but nothing
    /// may be played until `onLine` confirms it. `onWithdraw`: the speaker went on after all.
    var onDraft: ((Int, String, Data) -> Void)?
    var onWithdraw: ((Int) -> Void)?
    private var lineNumber = 1
    private var voiceSent = false
    private var draft: String?

    private var loop: Task<Void, Never>?
    private var host = "", key = ""
    private let rate = 16000

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var generation = 0
    private var requestStarted = Date()

    // The last half minute of sound, to cut a speaker's stretch out of it.
    private var store: [Int16] = []
    private var storeBase = 0           // absolute sample number of store[0]
    private var fed = 0                 // absolute sample number after the last one fed
    private var requestBase = 0         // absolute sample number where this request began
    private var emittedUntil = 0.0      // seconds into this request already shown
    private var latest: [SFTranscriptionSegment] = []
    private var voices: [(print: VoicePrint, count: Int)] = []

    private let net: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    func start(host: String, key: String) {
        guard !running else { return }
        self.host = host
        self.key = key
        running = true
        lines = []
        voices = []
        status = "Konuşma tanıma izni isteniyor…"
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        endRequest()
        running = false
        status = "Durduruldu"
    }

    private func run() async {
        let allowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard allowed else { status = "Konuşma tanıma izni verilmedi (Ayarlar > TR Altyazı)"; running = false; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            status = "İngilizce konuşma tanıma bu telefonda kullanılamıyor"; running = false; return
        }
        self.recognizer = recognizer
        let local = recognizer.supportsOnDeviceRecognition
        status = local ? "Dinleniyor (telefonun içinde)" : "Dinleniyor (Apple sunucusu üzerinden)"
        beginRequest()

        var epoch = 0, next = 0
        while !Task.isCancelled {
            var c = URLComponents()
            c.scheme = "http"; c.host = host; c.port = 8090; c.path = "/listen"
            c.queryItems = [
                URLQueryItem(name: "k", value: key),
                URLQueryItem(name: "epoch", value: String(epoch)),
                URLQueryItem(name: "from", value: String(next)),
                URLQueryItem(name: "wait", value: "1500"),
            ]
            guard let url = c.url, let (data, response) = try? await net.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = "TV'ye ulaşılamıyor"
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let parts = (http.value(forHTTPHeaderField: "X-Audio") ?? "").split(separator: ",").compactMap { Int($0) }
            guard parts.count == 5 else { try? await Task.sleep(for: .milliseconds(300)); continue }
            epoch = parts[1]
            next = parts[3]
            if data.count >= 2 { feed(data, ours: parts[4] == 1) }
            checkPause()
            // A fresh request now and then, at a quiet moment, keeps recognition from stalling.
            if Date().timeIntervalSince(requestStarted) > 45, latest.isEmpty || pauseSeconds() > 1.2 {
                endRequest()
                beginRequest()
            }
        }
    }

    private func beginRequest() {
        guard let recognizer else { return }
        generation += 1
        let mine = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        self.request = request
        requestBase = fed
        emittedUntil = 0
        latest = []
        requestStarted = Date()
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let segments = result?.bestTranscription.segments ?? []
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                if !segments.isEmpty { self.latest = segments }
                if final || failed {
                    self.emit(force: true)
                    if self.running { self.endRequest(); self.beginRequest() }
                } else {
                    self.checkPause()
                }
            }
        }
    }

    private func endRequest() {
        generation += 1
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        partial = ""
    }

    /// Gives a chunk of the TV's sound to the recognizer. While our own spoken line is coming
    /// out of the TV the chunk is replaced by silence, so we never write down our own voice.
    private func feed(_ data: Data, ours: Bool) {
        let n = data.count / 2
        var samples = [Int16](repeating: 0, count: n)
        if !ours {
            data.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<n { samples[i] = Int16(littleEndian: s[i]) }
            }
        }
        store.append(contentsOf: samples)
        let keep = rate * 30
        if store.count > keep {
            let drop = store.count - keep
            store.removeFirst(drop)
            storeBase += drop
        }
        fed += n
        guard let request,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { channel[0][i] = Float(samples[i]) / 32768 }
        request.append(buffer)
    }

    /// Seconds since the last heard word ended.
    private func pauseSeconds() -> Double {
        guard let last = latest.last else { return 99 }
        return Double(fed - requestBase) / Double(rate) - (last.timestamp + last.duration)
    }

    /// The stretch of stored sound between two moments of this request (seconds), if still kept.
    private func stretch(from: Double, to: Double) -> Data? {
        let a = requestBase + Int(from * Double(rate)) - storeBase
        let b = min(requestBase + Int(to * Double(rate)) - storeBase, store.count)
        guard a >= 0, b > a else { return nil }
        return Array(store[a..<b]).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func checkPause() {
        let pending = latest.filter { $0.timestamp >= emittedUntil }
        let text = pending.map { $0.substring }.joined(separator: " ")
        partial = text
        guard let first = pending.first, let last = pending.last else { return }
        // Whose voice: as soon as a second and a half of the line has been heard.
        if !voiceSent, Double(fed - requestBase) / Double(rate) - first.timestamp >= 1.5,
           let sound = stretch(from: first.timestamp, to: first.timestamp + 1.5) {
            voiceSent = true
            onVoice?(lineNumber, sound)
        }
        // More words after a draft went out: that draft is not the line.
        if let d = draft, d != text {
            draft = nil
            onWithdraw?(lineNumber)
        }
        let pause = pauseSeconds()
        // A single word waits longer: it is often the start of a sentence still being heard.
        if draft == nil, text.count >= 2, pause >= (pending.count >= 2 ? 0.45 : 1.0),
           let sound = stretch(from: first.timestamp, to: last.timestamp + last.duration) {
            draft = text
            onDraft?(lineNumber, text, sound)
        }
        if pause >= (pending.count >= 2 ? 0.8 : 1.6) { emit(force: false) }
    }

    /// Shows the words heard since the last shown stretch as one line with a speaker number.
    private func emit(force: Bool) {
        let pending = latest.filter { $0.timestamp >= emittedUntil }
        guard let first = pending.first, let last = pending.last else { return }
        let text = pending.map { $0.substring }.joined(separator: " ")
        let from = requestBase + Int(first.timestamp * Double(rate)) - storeBase
        let to = requestBase + Int((last.timestamp + last.duration) * Double(rate)) - storeBase
        emittedUntil = last.timestamp + last.duration + 0.01
        partial = ""
        // This line is over, whatever becomes of it: the next words belong to a new one.
        let number = lineNumber
        let drafted = draft
        lineNumber += 1
        voiceSent = false
        draft = nil
        guard text.count >= 2 else {
            if drafted != nil { onWithdraw?(number) }
            return
        }

        // The same words again (the recognizer finishing a line it already gave): not a new line.
        if let previous = lines.first {
            let a = previous.text.lowercased(), b = text.lowercased()
            if a == b || a.hasSuffix(b) {
                if drafted != nil { onWithdraw?(number) }
                return
            }
        }

        if let onLine, from >= 0, to <= store.count, to > from {
            let stretch = Array(store[from..<to])
            onLine(number, text, stretch.withUnsafeBufferPointer { Data(buffer: $0) })
        } else if drafted != nil {
            onWithdraw?(number)
        }

        var speaker = 0, pitch = 0
        var distances = ""
        if from >= 0, to <= store.count, to - from >= rate / 2,
           let voice = VoicePrint.make(Array(store[from..<to]), rate: rate) {
            pitch = Int(voice.pitch)
            let all = voices.map { $0.print.distance(to: voice) }
            distances = all.map { String(format: "%.2f", $0) }.joined(separator: " ")
            if let index = all.indices.min(by: { all[$0] < all[$1] }), all[index] < 0.8 {
                speaker = index + 1
                voices[index].count += 1
                voices[index].print = voices[index].print.blended(with: voice, weight: max(0.2, 1 / Double(voices[index].count)))
            } else if voices.count < 12 {
                voices.append((voice, 1))
                speaker = voices.count
            }
        }
        // A line that only completes the previous one replaces it.
        if let previous = lines.first, text.lowercased().hasPrefix(previous.text.lowercased()) { lines.removeFirst() }
        lines.insert(Line(speaker: speaker, pitch: pitch, text: text), at: 0)
        if lines.count > 12 { lines.removeLast() }
        note("heard [\(speaker == 0 ? "?" : String(speaker)), \(pitch) Hz, d \(distances)] \(text)")
    }

    /// Leaves the line in the TV's log as well, so the experiment can be read from there.
    private func note(_ message: String) {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = 8090; c.path = "/note"
        c.queryItems = [URLQueryItem(name: "k", value: key), URLQueryItem(name: "msg", value: message)]
        guard let url = c.url else { return }
        Task { _ = try? await self.net.data(from: url) }
    }
}

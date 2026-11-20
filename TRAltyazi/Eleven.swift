import Foundation
import AVFoundation
import Security

/// The user's secrets (the ElevenLabs API key) live in the phone's keychain, not in settings.
enum Keychain {
    static func get(_ name: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ name: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// ElevenLabs text to speech (experiment): the Turkish line goes to ElevenLabs over the
/// internet and comes back as sound, which is then sent to the TV like any other voice.
final class ElevenVoice: @unchecked Sendable {
    static let shared = ElevenVoice()

    /// A voice of the user's ElevenLabs account, with how high it speaks (measured once from
    /// its preview recording; 0 = unknown).
    struct Voice: Codable {
        let id: String
        let name: String
        let gender: String
        var pitch: Double
    }

    private var known: [Voice] = {
        guard let data = UserDefaults.standard.data(forKey: "elevenVoices"),
              let list = try? JSONDecoder().decode([Voice].self, from: data) else { return [] }
        return list
    }()

    var voices: [Voice] { lock.lock(); defer { lock.unlock() }; return known }

    func name(of id: String) -> String {
        voices.first { $0.id == id }?.name ?? ""
    }

    /// Reads the account's voices (up to ten men and ten women), measures each one's pitch
    /// from its preview and remembers the list. Returns a line for the screen.
    func prepareVoices(apiKey: String) async -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100") else { return "API anahtarı girilmemiş" }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, response) = try? await session.data(for: request) else { return "ElevenLabs'e ulaşılamadı" }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["voices"] as? [[String: Any]] else { return "Ses listesi alınamadı (\(status))" }

        var found: [Voice] = []
        var men = 0, women = 0
        for item in items {
            guard let id = item["voice_id"] as? String else { continue }
            let labels = item["labels"] as? [String: Any] ?? [:]
            let gender = ((labels["gender"] as? String) ?? "").lowercased()
            if gender == "male" { if men >= 10 { continue }; men += 1 }
            else if gender == "female" { if women >= 10 { continue }; women += 1 }
            else { continue }
            var pitch = 0.0
            if let preview = item["preview_url"] as? String, let previewURL = URL(string: preview),
               let (sound, _) = try? await session.data(from: previewURL), let clip = Self.decode(mp3: sound) {
                pitch = Self.pitch(of: clip)
            }
            found.append(Voice(id: id, name: (item["name"] as? String) ?? id, gender: gender, pitch: pitch))
        }
        guard !found.isEmpty else { return "Hesapta erkek/kadın etiketli ses bulunamadı" }
        lock.lock(); known = found; lock.unlock()
        if let encoded = try? JSONEncoder().encode(found) { UserDefaults.standard.set(encoded, forKey: "elevenVoices") }
        return "\(men) erkek, \(women) kadın ses hazır"
    }

    /// How high a recording speaks: its first seconds, thinned to about 11 kHz to keep the
    /// measurement quick.
    private static func pitch(of clip: Speaker.Clip) -> Double {
        let step = max(clip.rate / 11025, 1)
        let total = clip.pcm.count / 2
        let count = min(total / step, 11025 * 4)
        guard count > 2000 else { return 0 }
        var thin = Data(count: count * 2)
        clip.pcm.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            thin.withUnsafeMutableBytes { out in
                let target = out.bindMemory(to: Int16.self)
                for i in 0..<count {
                    var sum = 0
                    for j in 0..<step { sum += Int(Int16(littleEndian: source[i * step + j])) }
                    target[i] = Int16(sum / step).littleEndian
                }
            }
        }
        return ToneTracker.measure(thin, rate: clip.rate / step)?.pitchHz ?? 0
    }

    private let lock = NSLock()
    private var failure = ""
    private var millis = 0

    var lastError: String { lock.lock(); defer { lock.unlock() }; return failure }
    var lastMs: Int { lock.lock(); defer { lock.unlock() }; return millis }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func fail(_ message: String) -> Speaker.Clip? {
        lock.lock(); failure = message; lock.unlock()
        return nil
    }

    func speak(_ text: String, apiKey: String, voiceID: String, model: String) async -> Speaker.Clip? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return fail("API anahtarı girilmemiş") }
        guard !voice.isEmpty, voice.allSatisfy({ $0.isLetter || $0.isNumber }),
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_128")
        else { return fail("ses kimliği geçersiz") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "model_id": model, "language_code": "tr"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let detail = String(data: data.prefix(240), encoding: .utf8) ?? ""
                return fail("ElevenLabs \(status): \(detail)")
            }
            guard let clip = Self.decode(mp3: data) else { return fail("gelen ses çözülemedi") }
            lock.lock()
            millis = Int(Date().timeIntervalSince(started) * 1000)
            failure = ""
            lock.unlock()
            return clip
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// MP3 bytes -> 16-bit mono samples.
    private static func decode(mp3 data: Data) -> Speaker.Clip? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        do {
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
            else { return nil }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return nil }
            let n = Int(buffer.frameLength)
            var out = Data(count: n * 2)
            out.withUnsafeMutableBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let v = max(-1, min(1, channels[0][i]))
                    samples[i] = Int16(v * 32767).littleEndian
                }
            }
            return Speaker.Clip(pcm: out, rate: Int(format.sampleRate))
        } catch {
            return nil
        }
    }
}

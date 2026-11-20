import AVFoundation

/// Turns a Turkish line into sound with the phone's own voice, without playing it: the
/// samples go to the TV, which plays them over the game.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    struct Clip {
        let pcm: Data       // 16-bit mono samples, little endian
        let rate: Int       // samples per second
    }

    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let lock = NSLock()
    private var pending: Pending?

    /// One render in flight: collects the samples and answers exactly once.
    private final class Pending {
        var data = Data()
        var rate = 22050
        var continuation: CheckedContinuation<Clip?, Never>?
    }

    override init() {
        // The best Turkish voice installed on the phone (enhanced or premium if the user
        // has downloaded one in Settings, the standard one otherwise).
        let turkish = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("tr") }
        voice = turkish.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "tr-TR")
        super.init()
        synth.delegate = self
    }

    var voiceName: String { voice?.name ?? "yok" }

    /// Renders one line. Call it for one line at a time. Returns nil when the phone has no
    /// Turkish voice or nothing came out within a few seconds.
    func render(_ text: String) async -> Clip? {
        guard let voice else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // A little faster than normal: Turkish lines are longer than the English ones and the
        // voice starts later than the character does.
        utterance.rate = 0.56
        let job = Pending()
        lock.lock(); pending = job; lock.unlock()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Clip?, Never>) in
            lock.lock(); job.continuation = continuation; lock.unlock()
            synth.write(utterance) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.finish(job); return }
                let samples = Self.int16(pcm)
                self.lock.lock()
                job.rate = Int(pcm.format.sampleRate)
                job.data.append(samples)
                self.lock.unlock()
            }
            // Safety net: never leave the caller waiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish(job) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock(); let job = pending; lock.unlock()
        if let job { finish(job) }
    }

    private func finish(_ job: Pending) {
        lock.lock()
        let continuation = job.continuation
        job.continuation = nil
        let clip = job.data.isEmpty ? nil : Clip(pcm: job.data, rate: job.rate)
        if pending === job { pending = nil }
        lock.unlock()
        continuation?.resume(returning: clip)
    }

    /// The first channel of a buffer as 16-bit samples, whatever format the voice produced.
    private static func int16(_ buffer: AVAudioPCMBuffer) -> Data {
        let n = Int(buffer.frameLength)
        var out = Data(count: n * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            if let src = buffer.int16ChannelData {
                for i in 0..<n { dst[i] = src[0][i].littleEndian }
            } else if let src = buffer.floatChannelData {
                for i in 0..<n {
                    let v = max(-1, min(1, src[0][i]))
                    dst[i] = Int16(v * 32767).littleEndian
                }
            } else if let src = buffer.int32ChannelData {
                for i in 0..<n { dst[i] = Int16(truncatingIfNeeded: src[0][i] >> 16).littleEndian }
            }
        }
        return out
    }
}

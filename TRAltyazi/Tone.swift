import Foundation

/// How a line was said, measured from the TV's sound around the moment the line appeared.
struct ToneReading {
    let levelDb: Double         // loudness of the spoken part
    let peaks: Int              // syllable-like bursts in the span
    let seconds: Double
    let pitchSpread: Double     // how much the pitch moves, in semitones (0 = unknown)
    let pitchHz: Double         // how high the voice is (0 = unknown)
}

/// Turns readings into delivery directions for the voice ("[shouting]", "[softly]", ...), by
/// comparing each line with how the recent lines were said.
final class ToneTracker {
    private var levels: [Double] = []

    /// `data`: 16-bit mono samples.
    static func measure(_ data: Data, rate: Int) -> ToneReading? {
        let n = data.count / 2
        guard rate > 0, n > rate / 4 else { return nil }
        var x = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { x[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        // Drop bass and rumble (engines, music beats): keep what carries speech.
        var y = [Float](repeating: 0, count: n)
        for i in 1..<n { y[i] = x[i] - 0.95 * x[i - 1] }

        // Energy per 20 ms.
        let frame = max(rate / 50, 1)
        var energies: [Double] = []
        var start = 0
        while start + frame <= n {
            var e = 0.0
            for j in 0..<frame { let v = Double(y[start + j]); e += v * v }
            energies.append(e / Double(frame))
            start += frame
        }
        guard energies.count >= 8 else { return nil }

        // Loudness of the louder half of the span: the speech rather than the gaps.
        let sorted = energies.sorted()
        let upper = sorted[(sorted.count / 2)...]
        let level = 10 * log10(upper.reduce(0, +) / Double(upper.count) + 1e-12)

        // Syllable-like bursts: peaks of the smoothed energy, at least 100 ms apart.
        var smooth = energies
        for i in 1..<(energies.count - 1) { smooth[i] = (energies[i - 1] + energies[i] + energies[i + 1]) / 3 }
        let top = smooth.max() ?? 0
        var peaks = 0, lastPeak = -10
        if top > 0 {
            for i in 1..<(smooth.count - 1) where smooth[i] > 0.3 * top && smooth[i] >= smooth[i - 1] && smooth[i] > smooth[i + 1] && i - lastPeak >= 5 {
                peaks += 1
                lastPeak = i
            }
        }

        // Pitch per 40 ms by autocorrelation, where the sound is voiced.
        let window = rate / 25, hop = rate / 50
        let low = rate / 350, high = min(rate / 70, window - 1)
        var pitches: [Double] = []
        var at = 0
        while at + window <= n, high > low {
            var zero: Float = 0
            for j in 0..<window { zero += x[at + j] * x[at + j] }
            if zero > 1e-5 {
                var best: Float = 0
                var bestLag = 0
                for lag in low...high {
                    var sum: Float = 0
                    for j in 0..<(window - lag) { sum += x[at + j] * x[at + j + lag] }
                    if sum > best { best = sum; bestLag = lag }
                }
                if bestLag > 0, best / zero > 0.5 { pitches.append(Double(rate) / Double(bestLag)) }
            }
            at += hop
        }
        var spread = 0.0
        var height = 0.0
        if pitches.count >= 6 {
            let median = pitches.sorted()[pitches.count / 2]
            height = median
            let semitones = pitches.map { 12 * log2($0 / median) }
            let mean = semitones.reduce(0, +) / Double(semitones.count)
            spread = sqrt(semitones.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(semitones.count))
        }
        return ToneReading(levelDb: level, peaks: peaks, seconds: Double(n) / Double(rate), pitchSpread: spread, pitchHz: height)
    }

    /// Delivery directions for a line. Louder or softer is judged against the middle of the
    /// last lines, so the first few lines get none.
    func tags(for reading: ToneReading) -> String {
        defer {
            levels.append(reading.levelDb)
            if levels.count > 30 { levels.removeFirst() }
        }
        var tags = ""
        if levels.count >= 4 {
            let base = levels.sorted()[levels.count / 2]
            let delta = reading.levelDb - base
            if delta >= 9 { tags += "[shouting]" }
            else if delta >= 5 { tags += "[raised voice]" }
            else if delta <= -11 { tags += "[whispers]" }
            else if delta <= -6 { tags += "[softly]" }
        }
        if reading.seconds > 0, Double(reading.peaks) / reading.seconds >= 6.5 { tags += "[speaking quickly]" }
        if tags.isEmpty, reading.pitchSpread >= 3.5 { tags = "[animated]" }
        return tags
    }
}

/// Gives each character a voice of their own. A character is recognised by how high their
/// voice is; a new one gets the unused voice of the same sex whose own pitch is closest.
final class CharacterVoices {
    private struct Character {
        var pitch: Double
        let voice: String
        var seen: Date
    }
    private var characters: [Character] = []
    private var lastVoice: String?
    private var lastAt = Date.distantPast

    func reset() {
        characters = []
        lastVoice = nil
    }

    /// The voice for a line. `pitch` 0 means the character could not be heard (too short, too
    /// noisy, or our own line was playing): the previous speaker's voice is kept for a while.
    func voice(pitch: Double, pool: [ElevenVoice.Voice]) -> String? {
        guard !pool.isEmpty else { return nil }
        let now = Date()
        guard pitch > 0 else {
            return now.timeIntervalSince(lastAt) < 6 ? lastVoice : nil
        }
        func distance(_ a: Double, _ b: Double) -> Double { abs(12 * log2(a / b)) }
        var chosen: String
        if let index = characters.indices.min(by: { distance(characters[$0].pitch, pitch) < distance(characters[$1].pitch, pitch) }),
           distance(characters[index].pitch, pitch) <= 2.0 {
            characters[index].pitch = characters[index].pitch * 0.8 + pitch * 0.2
            characters[index].seen = now
            chosen = characters[index].voice
        } else {
            let wanted = pitch < 165 ? "male" : "female"
            var candidates = pool.filter { $0.gender == wanted }
            if candidates.isEmpty { candidates = pool }
            let used = Set(characters.map { $0.voice })
            let free = candidates.filter { !used.contains($0.id) }
            let from = free.isEmpty ? candidates : free
            let best = from.min { a, b in
                let da = a.pitch > 0 ? distance(a.pitch, pitch) : 99
                let db = b.pitch > 0 ? distance(b.pitch, pitch) : 99
                return da < db
            }
            chosen = best?.id ?? from[0].id
            characters.append(Character(pitch: pitch, voice: chosen, seen: now))
            if characters.count > 14, let oldest = characters.indices.min(by: { characters[$0].seen < characters[$1].seen }) {
                characters.remove(at: oldest)
            }
        }
        lastVoice = chosen
        lastAt = now
        return chosen
    }
}

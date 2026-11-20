import Foundation

/// The characters heard so far in the game, each kept as the average of the speaker vectors
/// of their lines (from ZONOS3-Mini's speaker encoder). A new clip is compared with everyone
/// already known: close enough and it is that character again, otherwise a new one joins.
/// The Turkish line is then spoken with the character's average vector, so a character keeps
/// one steady voice that is derived from their own.
final class VoiceCast: @unchecked Sendable {
    struct Match {
        let number: Int          // 1, 2, 3… in the order the characters were first heard
        let vector: [Float]      // the character's voice for the model
        let similarity: Float    // to the best known character before this clip was added
        let isNew: Bool
    }

    private struct Member: Codable {
        let number: Int
        var sum: [Float]         // of unit vectors
        var lengths: Float       // of the vectors' lengths
        var count: Float
        var used: Date
        var pitch: Float?        // how high the character speaks, Hz
    }

    private var members: [Member] = []
    private var next = 1
    private let lock = NSLock()

    // The cast is kept on the phone, so a character heard once keeps the same voice the next
    // time the game is played.
    private struct Saved: Codable {
        var next: Int
        var members: [Member]
    }
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("karakter-sesleri.json")
    }
    private let disk = DispatchQueue(label: "cast-save", qos: .utility)

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            members = saved.members.filter { $0.sum.count == 192 }
            next = max(saved.next, (members.map { $0.number }.max() ?? 0) + 1)
        }
    }

    /// Call with the lock held.
    private func save() {
        let saved = Saved(next: next, members: members)
        disk.async {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.file, options: .atomic) }
        }
    }

    private static func length(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
        return dot / max(length(a) * length(b), 1e-9)
    }

    private func voice(of m: Member) -> [Float] {
        let n = Self.length(m.sum)
        let scale = (m.lengths / m.count) / max(n, 1e-9)
        return m.sum.map { $0 * scale }
    }

    /// The known character this clip most resembles, if it reaches `threshold`. Does not learn.
    private func notePitch(_ index: Int, _ pitch: Float) {
        guard pitch > 50, pitch < 500 else { return }
        if let old = members[index].pitch { members[index].pitch = old * 0.7 + pitch * 0.3 } else { members[index].pitch = pitch }
    }

    /// A quick guess from the pitch alone, among the characters heard in the last `seconds`:
    /// the one whose usual pitch is nearest, if within `semitones`. Used to start speaking at
    /// once; the speaker vector (which takes a second or two of listening) confirms it later.
    func guess(pitch: Float, seconds: TimeInterval, semitones: Float) -> (match: Match, distance: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard pitch > 50 else { return nil }
        let now = Date()
        var best = -1
        var bestDistance = Float.infinity
        for i in members.indices {
            guard let own = members[i].pitch, now.timeIntervalSince(members[i].used) < seconds else { continue }
            let d = abs(12 * log2(pitch / own))
            if d < bestDistance { bestDistance = d; best = i }
        }
        guard best >= 0, bestDistance <= semitones else { return nil }
        return (Match(number: members[best].number, vector: voice(of: members[best]), similarity: 0, isNew: false), bestDistance)
    }

    /// The quick guess within a scene: among the characters whose voice was confirmed in the
    /// last `seconds` (the people talking right now), the one nearest in pitch. With two or
    /// more of them the nearest is taken generously (a voice moves a lot within a sentence);
    /// with only one, a clearly different pitch means somebody else has started talking.
    func guessInScene(pitch: Float, seconds: TimeInterval) -> (match: Match, distance: Float, among: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard pitch > 50 else { return nil }
        let now = Date()
        var best = -1, among = 0
        var bestDistance = Float.infinity
        for i in members.indices {
            guard let own = members[i].pitch, now.timeIntervalSince(members[i].used) < seconds else { continue }
            among += 1
            let d = abs(12 * log2(pitch / own))
            if d < bestDistance { bestDistance = d; best = i }
        }
        guard best >= 0, bestDistance <= (among >= 2 ? 6 : 3.5) else { return nil }
        return (Match(number: members[best].number, vector: voice(of: members[best]), similarity: 0, isNew: false), bestDistance, among)
    }

    /// The character is talking now (a sure guess, not checked with the encoder).
    func touch(_ number: Int) {
        lock.lock(); defer { lock.unlock() }
        if let i = members.firstIndex(where: { $0.number == number }) { members[i].used = Date() }
    }

    func recognise(_ vector: [Float], threshold: Float, pitch: Float = 0) -> Match? {
        lock.lock(); defer { lock.unlock() }
        guard let best = members.indices.max(by: { Self.cosine(members[$0].sum, vector) < Self.cosine(members[$1].sum, vector) }) else { return nil }
        let similarity = Self.cosine(members[best].sum, vector)
        guard similarity >= threshold else { return nil }
        members[best].used = Date()
        notePitch(best, pitch)
        return Match(number: members[best].number, vector: voice(of: members[best]), similarity: similarity, isNew: false)
    }

    /// Like `recognise`, but the clip also teaches: it is added to the character it matches,
    /// or becomes a new character.
    func learn(_ vector: [Float], threshold: Float, pitch: Float = 0) -> Match {
        lock.lock(); defer { lock.unlock() }
        let norm = Self.length(vector)
        let unit = vector.map { $0 / max(norm, 1e-9) }
        var bestIndex = -1
        var bestSimilarity: Float = -1
        for i in members.indices {
            let s = Self.cosine(members[i].sum, vector)
            if s > bestSimilarity { bestSimilarity = s; bestIndex = i }
        }
        if bestIndex >= 0, bestSimilarity >= threshold {
            // Later clips count, but the voice must not drift: at most 12 clips' worth of weight.
            if members[bestIndex].count >= 12 {
                let keep: Float = 11.0 / 12.0
                members[bestIndex].sum = members[bestIndex].sum.map { $0 * keep }
                members[bestIndex].lengths *= keep
                members[bestIndex].count *= keep
            }
            for i in unit.indices { members[bestIndex].sum[i] += unit[i] }
            members[bestIndex].lengths += norm
            members[bestIndex].count += 1
            members[bestIndex].used = Date()
            notePitch(bestIndex, pitch)
            save()
            return Match(number: members[bestIndex].number, vector: voice(of: members[bestIndex]), similarity: bestSimilarity, isNew: false)
        }
        if members.count >= 60, let oldest = members.indices.min(by: { members[$0].used < members[$1].used }) {
            members.remove(at: oldest)
        }
        let member = Member(number: next, sum: unit, lengths: norm, count: 1, used: Date(),
                            pitch: pitch > 50 && pitch < 500 ? pitch : nil)
        next += 1
        members.append(member)
        save()
        return Match(number: member.number, vector: vector, similarity: max(bestSimilarity, 0), isNew: true)
    }

    /// The character used most recently (for a line whose own sound could not be used).
    var latest: Match? {
        lock.lock(); defer { lock.unlock() }
        guard let m = members.max(by: { $0.used < $1.used }) else { return nil }
        return Match(number: m.number, vector: voice(of: m), similarity: 0, isNew: false)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return members.count }

    func reset() {
        lock.lock(); members = []; next = 1; save(); lock.unlock()
    }
}

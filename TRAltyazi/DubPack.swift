import Foundation
import AVFoundation

/// Ready-made spoken lines: a pack the user loads once into the app's Documents folder
/// (`ses/ses.trsx` and the sound files `ses/ses-000.trsd`, `ses-001.trsd`, …). It maps the digest
/// of an English subtitle line to the sound of that line in Turkish, so a line that is in the
/// pack is spoken without anything being produced: the sound is read from the phone's storage
/// and handed to the TV. The pack holds no English text.
///
/// Index layout (little-endian): "TRSS0001" | u32 keys K | u32 entries E | u32 text size |
/// u32 sound files P | K x u64 digests, sorted | (K+1) x u32 first entry of a key |
/// E x 24-byte entry | P x u32 size of each sound file | UTF-8 text.
/// Entry: u32 place in its sound file | u32 length | u32 order of the line in its table |
/// u32 text start | u16 text length | u16 length of the sound in 1/100 s | u16 table |
/// u8 sound file | u8 flags. Flags: bit 0 = a later piece of a line the game shows in pieces
/// (the sound is the one that began with the line's first piece); bits 1-7 = where in the sound
/// this piece begins, in 127ths. The sounds are MP3. Digest and normalising are those of
/// `SubtitleTable`.
///
/// One English line can have several sounds (the same words said in another scene by someone
/// else). Each entry says which table (scene) it is from and where in it; the sound from the
/// scene of the lines seen a moment ago is taken.
final class DubPack: @unchecked Sendable {
    static let shared = DubPack()

    /// Samples per second of the sounds as they go to the TV.
    static let rate = 24000
    /// The first samples of a ready-made line (far too quiet to hear). The TV's overlay knows a
    /// ready-made line by them and starts it at once, over a line that is still being said,
    /// instead of after it: two people may talk at the same time.
    static let mark: [Int16] = [1, -1, 2, -2, 3, -3, 5, -5]

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ses", isDirectory: true)
    }
    static var indexURL: URL { folder.appendingPathComponent("ses.trsx") }
    static func partName(_ n: Int) -> String { String(format: "ses-%03d.trsd", n) }
    static func partURL(_ n: Int) -> URL { folder.appendingPathComponent(partName(n)) }

    struct Entry {
        let part: Int
        let offset: Int
        let length: Int
        let order: Int
        let table: Int
        let seconds: Double
        /// A later piece of a line the game shows in pieces: the sound began with the first piece.
        let continuation: Bool
        /// Where in the sound this piece begins (0...1); 0 for a whole line and a first piece.
        let begins: Double
        let text: String
        /// Chosen without doubt (the only sound for these words, or the scene decided).
        var sure = false
        /// Names the sound itself: entries of the pieces of one line share it.
        var sound: UInt64 { UInt64(part) << 32 | UInt64(offset) }
    }

    struct Match {
        let entries: [Entry]
        /// The Turkish text of exactly these sounds; nil when a piece has no text of its own.
        var text: String? {
            let texts = entries.map { $0.text }
            return texts.contains("") ? nil : texts.joined(separator: " ")
        }
    }

    enum PackError: LocalizedError {
        case notAPack
        case noSpace(Int)
        var errorDescription: String? {
            switch self {
            case .notAPack: return "Adresteki dosya ses paketi biçiminde değil."
            case .noSpace(let bytes): return String(format: "Telefonda yer yok: %.1f GB boş yer gerekli.", Double(bytes) / 1_073_741_824)
            }
        }
    }

    private let lock = NSLock()
    private var data: Data?
    private var keys = 0
    private var entryCount = 0
    private var partCount = 0
    private var textSize = 0
    private var digestsAt = 0
    private var startsAt = 0
    private var entriesAt = 0
    private var partsAt = 0
    private var textAt = 0
    private var complete = false
    // The scenes of the last lines, newest last, and the sounds started lately.
    private var scene: [(table: Int, order: Int, at: Date)] = []
    private var started: [UInt64: Date] = [:]

    private init() { load() }

    /// True when the index and every sound file are here and whole.
    var ready: Bool {
        lock.lock(); defer { lock.unlock() }
        return complete
    }

    /// How many lines the index knows (0: no index).
    var lines: Int {
        lock.lock(); defer { lock.unlock() }
        return keys
    }

    /// The size of all sound files together, as the index says.
    var bytes: Int {
        lock.lock(); defer { lock.unlock() }
        guard let d = data else { return 0 }
        return (0..<partCount).reduce(0) { $0 + Int(Self.u32(d, partsAt + $1 * 4)) }
    }

    /// Reads the index again (after a download or a delete). True when the pack is whole.
    @discardableResult
    func load() -> Bool {
        lock.lock(); defer { lock.unlock() }
        data = nil
        keys = 0; entryCount = 0; partCount = 0; textSize = 0
        complete = false
        scene = []
        started = [:]
        guard let d = try? Data(contentsOf: Self.indexURL, options: .alwaysMapped),
              let layout = Self.layout(d) else { return false }
        data = d
        keys = layout.keys; entryCount = layout.entries; partCount = layout.parts; textSize = layout.text
        digestsAt = 24
        startsAt = digestsAt + keys * 8
        entriesAt = startsAt + (keys + 1) * 4
        partsAt = entriesAt + entryCount * 24
        textAt = partsAt + partCount * 4
        var whole = true
        for n in 0..<partCount where Self.fileSize(Self.partURL(n)) != Int(Self.u32(d, partsAt + n * 4)) { whole = false }
        complete = whole
        return whole
    }

    func delete() {
        try? FileManager.default.removeItem(at: Self.folder)
        load()
    }

    private static func layout(_ d: Data) -> (keys: Int, entries: Int, text: Int, parts: Int)? {
        guard d.count >= 24, d.prefix(8) == Data("TRSS0001".utf8) else { return nil }
        let k = Int(u32(d, 8)), e = Int(u32(d, 12)), t = Int(u32(d, 16)), p = Int(u32(d, 20))
        guard k > 0, e > 0, p > 0, p <= 255, d.count >= 24 + k * 8 + (k + 1) * 4 + e * 24 + p * 4 + t else { return nil }
        return (k, e, t, p)
    }

    /// The sizes of the sound files an index asks for; nil when the data is not an index.
    private static func partSizes(_ d: Data) -> [Int]? {
        guard let shape = Self.layout(d) else { return nil }
        let at = 24 + shape.keys * 8 + (shape.keys + 1) * 4 + shape.entries * 24
        return (0..<shape.parts).map { Int(u32(d, at + $0 * 4)) }
    }

    private static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? -1
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        d.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self)) }
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
    }

    // MARK: - Finding the sound of a line

    private func entry(_ d: Data, _ n: Int) -> Entry? {
        let at = entriesAt + n * 24
        let textStart = Int(Self.u32(d, at + 12)), textLength = Int(Self.u16(d, at + 16))
        let part = Int(Self.u16(d, at + 22) & 0xFF), flags = Int(Self.u16(d, at + 22) >> 8)
        guard part < partCount, textStart + textLength <= textSize else { return nil }
        let from = textAt + textStart
        let text = String(data: d.subdata(in: from..<(from + textLength)), encoding: .utf8) ?? ""
        return Entry(part: part, offset: Int(Self.u32(d, at)), length: Int(Self.u32(d, at + 4)),
                     order: Int(Self.u32(d, at + 8)), table: Int(Self.u16(d, at + 20)),
                     seconds: Double(Self.u16(d, at + 18)) / 100, continuation: flags & 1 != 0,
                     begins: Double(flags >> 1) / 127, text: text)
    }

    /// Every sound the pack has for these words. (Call with the lock held.)
    private func candidates(_ text: String) -> [Entry] {
        let key = SubtitleTable.normalize(text)
        guard key.count >= 2, let d = data, complete else { return [] }
        let wanted = SubtitleTable.digest(key)
        var low = 0, high = keys - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = Self.u64(d, digestsAt + mid * 8)
            if value == wanted {
                let from = Int(Self.u32(d, startsAt + mid * 4)), to = Int(Self.u32(d, startsAt + (mid + 1) * 4))
                guard from <= to, to <= entryCount else { return [] }
                return (from..<to).compactMap { entry(d, $0) }
            }
            if value < wanted { low = mid + 1 } else { high = mid - 1 }
        }
        return []
    }

    /// The one sound for these words. (Call with the lock held.)
    private func pick(_ text: String, now: Date) -> Entry? {
        let all = candidates(text)
        guard !all.isEmpty else { return nil }
        // The line goes on: the game shows it in pieces, and the sound that began with its first
        // piece is saying this piece too. Nothing new is to be played.
        if var going = all.first(where: { e in
            guard e.continuation, let at = started[e.sound] else { return false }
            return now.timeIntervalSince(at) < e.seconds + 10
        }) {
            going.sure = true
            return going
        }
        // Only later pieces of lines, and none of them going (the first piece was missed, or not
        // read well enough to be found): the sound is played from where this piece begins.
        let starters = all.filter { !$0.continuation }
        let pool = starters.isEmpty ? all : starters
        var best = pool[0]
        if pool.count == 1 {
            best.sure = true
            return best
        }
        // The same words in several scenes: the scene of the lines seen lately decides, and
        // within it the line nearest to them. With nothing to go on, the first one is taken.
        var bestScore = 0.0
        for e in pool {
            var score = 0.0
            for s in scene where s.table == e.table {
                let weight = 1 / (1 + now.timeIntervalSince(s.at) / 60)
                score += weight * (abs(s.order - e.order) <= 30 ? 2 : 1)
            }
            if score > bestScore {
                best = e
                bestScore = score
            }
        }
        best.sure = bestScore > 0
        return best
    }

    /// The sounds for an English subtitle as read from the screen, or nil. The same three steps
    /// as `SubtitleTable.lookup`: the whole line; sentence by sentence; with a short tail left
    /// out (the mission note the TV reads as part of the line).
    func find(_ english: String) -> Match? {
        lock.lock(); defer { lock.unlock() }
        guard complete else { return nil }
        let now = Date()
        if let e = pick(english, now: now) { return Match(entries: [e]) }
        let pieces = SubtitleTable.sentences(english)
        guard pieces.count >= 2 else { return nil }
        let single = pieces.map { pick($0, now: now) }
        if single.allSatisfy({ $0 != nil }) { return Match(entries: single.compactMap { $0 }) }
        var k = pieces.count - 1
        while k >= 1 {
            let tailWords = pieces[k...].joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
            if tailWords > 6 { break }
            if let e = pick(pieces[..<k].joined(separator: " "), now: now) { return Match(entries: [e]) }
            if single[..<k].allSatisfy({ $0 != nil }) { return Match(entries: single[..<k].compactMap { $0 }) }
            k -= 1
        }
        return nil
    }

    /// The sounds of a match that are to start now, and remembers them. Left out: a sound that
    /// started a moment ago (the TV sends a line again while it stays on screen; a later piece
    /// of a line whose sound is already going).
    func claim(_ match: Match) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var out: [Entry] = []
        for e in match.entries {
            if e.sure, scene.last.map({ $0.table != e.table || $0.order != e.order }) ?? true {
                scene.append((e.table, e.order, now))
                if scene.count > 12 { scene.removeFirst(scene.count - 12) }
            }
            let quiet = e.continuation ? e.seconds + 10 : max(8, e.seconds + 5)
            if let at = started[e.sound], now.timeIntervalSince(at) < quiet { continue }
            started[e.sound] = now
            out.append(e)
        }
        if started.count > 200 { started = started.filter { now.timeIntervalSince($0.value) < 120 } }
        return out
    }

    // MARK: - Reading the sound

    /// The sounds as one clip for the TV: 16-bit mono samples with the mark in front. Reads the
    /// phone's storage and unpacks MP3 (some hundredths of a second): call it off the main thread.
    func clip(_ sounds: [Entry]) -> Speaker.Clip? {
        var pcm = Data()
        for v in Self.mark { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        var rate = 0
        for e in sounds {
            guard let sound = Self.unpack(e), rate == 0 || sound.rate == rate else { continue }
            if rate != 0 { pcm.append(Data(count: sound.rate / 8 * 2)) }       // an eighth of a second between two sounds
            pcm.append(sound.pcm)
            rate = sound.rate
        }
        return rate == 0 ? nil : Speaker.Clip(pcm: pcm, rate: rate)
    }

    private static func unpack(_ e: Entry) -> (pcm: Data, rate: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: partURL(e.part)) else { return nil }
        defer { try? handle.close() }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dub-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try handle.seek(toOffset: UInt64(e.offset))
            guard let packed = try handle.read(upToCount: e.length), packed.count == e.length else { return nil }
            try packed.write(to: temp)
            let file = try AVAudioFile(forReading: temp)
            let format = file.processingFormat
            let rate = Int(format.sampleRate)
            guard rate >= 8000, rate <= 48000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { return nil }
            var samples: [Int16] = []
            samples.reserveCapacity(Int(max(0, file.length)) + 2048)
            // Read until nothing more comes: the length an MP3 states is an estimate, and running
            // into the end is not a failure. (The count only guards against a file that never ends.)
            var rounds = 0
            while rounds < 600 {
                rounds += 1
                do { try file.read(into: buffer) } catch { break }
                let n = Int(buffer.frameLength)
                guard n > 0, let source = buffer.floatChannelData else { break }
                for i in 0..<n { samples.append(Int16(max(-1, min(1, source[0][i])) * 32767)) }
            }
            guard samples.count > rate / 20 else { return nil }
            // Packing leaves a little silence in front of the sound: it would only make the
            // line start later.
            var first = 0
            let window = min(samples.count, rate / 5)
            if let loud = samples[..<window].firstIndex(where: { $0 > 100 || $0 < -100 }) { first = max(0, loud - rate / 200) }
            // A later piece of a line whose beginning was missed: from about where the piece
            // begins (a little earlier, the place is an estimate), faded in so it does not click.
            if e.continuation, e.begins > 0 {
                first = min(samples.count - rate / 20, max(first, first + Int(Double(samples.count - first) * e.begins) - rate / 5))
                let fade = min(rate / 50, samples.count - first)
                for i in 0..<fade { samples[first + i] = Int16(Int(samples[first + i]) * i / fade) }
            }
            let pcm = samples[first...].withUnsafeBufferPointer { Data(buffer: $0) }
            return (pcm, rate)
        } catch {
            return nil
        }
    }

    // MARK: - Getting the pack

    /// Fetches the pack from a folder address on the home network (for example a computer that
    /// serves the folder for a while). Sound files that are already here and whole are kept, so
    /// a download that stopped half way goes on where it was.
    static func download(from base: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Gigabytes that can be fetched again: not for the phone's backup.
        var home = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? home.setResourceValues(values)

        let (tempIndex, answer) = try await URLSession.shared.download(from: base.appendingPathComponent("ses.trsx"))
        guard (answer as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let fresh = try Data(contentsOf: tempIndex)
        guard let sizes = partSizes(fresh) else {
            try? fm.removeItem(at: tempIndex)
            throw PackError.notAPack
        }
        // Another pack than the one here: its sounds lie elsewhere in the files, so the old files go.
        if let old = try? Data(contentsOf: indexURL), old != fresh {
            for n in 0..<256 { try? fm.removeItem(at: partURL(n)) }
        }
        try? fm.removeItem(at: indexURL)
        try fm.moveItem(at: tempIndex, to: indexURL)

        let total = sizes.reduce(0, +)
        var missing = 0
        for (n, size) in sizes.enumerated() where fileSize(partURL(n)) != size { missing += size }
        let space = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = space?.volumeAvailableCapacityForImportantUsage, free < Int64(missing) + 300_000_000 {
            throw PackError.noSpace(missing + 300_000_000)
        }
        var have = total - missing
        progress(Double(have) / Double(max(total, 1)))
        for (n, size) in sizes.enumerated() where fileSize(partURL(n)) != size {
            var tries = 0
            while true {
                do {
                    let (temp, reply) = try await URLSession.shared.download(from: base.appendingPathComponent(partName(n)))
                    guard (reply as? HTTPURLResponse)?.statusCode == 200, fileSize(temp) == size else {
                        try? fm.removeItem(at: temp)
                        throw URLError(.badServerResponse)
                    }
                    try? fm.removeItem(at: partURL(n))
                    try fm.moveItem(at: temp, to: partURL(n))
                    break
                } catch {
                    tries += 1
                    if tries >= 3 { throw error }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            have += size
            progress(Double(have) / Double(max(total, 1)))
        }
        shared.load()
    }
}

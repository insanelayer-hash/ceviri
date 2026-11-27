import Foundation

/// Ready-made Turkish lines: a file the user loads once (`tablo.trat` in the app's Documents
/// folder). It maps a 64-bit digest of an English subtitle line to its Turkish line, so a line
/// that is in the table needs no translating at all. The file holds no English text.
///
/// Layout (little-endian): "TRAT0001" | u32 line count N | u32 text size | N x u64 digests,
/// sorted | (N+1) x u32 text starts | UTF-8 text. `normalize` and `digest` must stay the same
/// as in the tool that writes the file.
final class SubtitleTable: @unchecked Sendable {
    static let shared = SubtitleTable()

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tablo.trat")
    }

    private let lock = NSLock()
    private var data: Data?
    private var count = 0
    private var digestsAt = 0
    private var startsAt = 0
    private var textAt = 0

    /// How many lines the loaded table has (0: no table).
    var lines: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    private init() { load() }

    /// Reads the file again (after a download or a delete). False when there is no usable file.
    @discardableResult
    func load() -> Bool {
        lock.lock(); defer { lock.unlock() }
        data = nil
        count = 0
        guard let d = try? Data(contentsOf: Self.fileURL, options: .alwaysMapped), d.count >= 16,
              d.prefix(8) == Data("TRAT0001".utf8) else { return false }
        let n = Int(Self.u32(d, 8)), text = Int(Self.u32(d, 12))
        guard n > 0, d.count >= 16 + n * 8 + (n + 1) * 4 + text else { return false }
        data = d
        count = n
        digestsAt = 16
        startsAt = 16 + n * 8
        textAt = startsAt + (n + 1) * 4
        return true
    }

    func delete() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        load()
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
    }

    /// Letters and digits only, lower case, apostrophes dropped, everything else one space.
    static func normalize(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var space = true
        for scalar in text.unicodeScalars {
            var v = scalar.value
            if v >= 65 && v <= 90 { v += 32 }
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
                out.append(UInt8(v))
                space = false
            } else if v == 0x27 || v == 0x2019 || v == 0x2018 {
                continue
            } else if !space {
                out.append(32)
                space = true
            }
        }
        if out.last == 32 { out.removeLast() }
        return out
    }

    /// FNV-1a, 64 bit.
    static func digest(_ key: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// Split after . ! ? … when white space follows.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var ended = false
        for ch in text {
            if ended, ch.isWhitespace {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { out.append(piece) }
                current = ""
                ended = false
                continue
            }
            current.append(ch)
            ended = ch == "." || ch == "!" || ch == "?" || ch == "…"
        }
        let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { out.append(piece) }
        return out
    }

    /// The speaker's name the game shows in front of a line ("Lucia: Well, …") and the line
    /// without it; nil when the line does not begin with such a name. The table and the sound
    /// pack hold the lines without names.
    static func speakerLabel(_ text: String) -> (name: String, rest: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, name.count <= 28, let first = name.first, first.isLetter, first.isUppercase else { return nil }
        guard name.split(separator: " ").count <= 4 else { return nil }
        let allowed: Set<Character> = [" ", ".", "'", "’", "-", "&"]
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || allowed.contains($0) }) else { return nil }
        guard rest.filter({ $0.isLetter }).count >= 2 else { return nil }
        return (name, rest)
    }

    private func exact(_ text: String) -> String? {
        let key = Self.normalize(text)
        guard key.count >= 2 else { return nil }
        let wanted = Self.digest(key)
        lock.lock(); defer { lock.unlock() }
        guard let d = data, count > 0 else { return nil }
        var low = 0, high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = Self.u64(d, digestsAt + mid * 8)
            if value == wanted {
                let from = textAt + Int(Self.u32(d, startsAt + mid * 4))
                let to = textAt + Int(Self.u32(d, startsAt + (mid + 1) * 4))
                guard from <= to, to <= d.count else { return nil }
                return String(data: d.subdata(in: from..<to), encoding: .utf8)
            }
            if value < wanted { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// The Turkish line for an English subtitle as read from the screen, or nil.
    /// 1) the whole line; 2) sentence by sentence; 3) with a short tail left out: the TV often
    /// reads the mission note under the subtitle ("Find Cal") as part of the line.
    func lookup(_ english: String) -> String? {
        if lines == 0 { return nil }
        if let hit = exact(english) { return hit }
        let parts = Self.sentences(english)
        guard parts.count >= 2 else { return nil }
        let single = parts.map { exact($0) }
        if single.allSatisfy({ $0 != nil }) { return single.compactMap { $0 }.joined(separator: " ") }
        var k = parts.count - 1
        while k >= 1 {
            let tailWords = parts[k...].joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
            if tailWords > 6 { break }
            if let hit = exact(parts[..<k].joined(separator: " ")) { return hit }
            if single[..<k].allSatisfy({ $0 != nil }) { return single[..<k].compactMap { $0 }.joined(separator: " ") }
            k -= 1
        }
        return nil
    }
}

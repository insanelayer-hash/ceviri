import Foundation

/// Game subtitles are spoken English: slang, contractions, swearing used as punctuation, and
/// names that are also ordinary words. The on-device translator renders these word for word
/// ("Yello" became "Sarı", "Fuck it" became "Siktir git", "Jay" became "Alakarga"). Before a
/// line is translated it is put into plain English that translates the way it was meant.
enum EnglishPrep {
    // Pattern (case does not matter) and what replaces it; $1 is the first group.
    private static let table: [(String, String)] = [
        ("[¿¡]", ""),
        ("\\bl'm\\b", "I'm"),
        ("\\by'?ello\\b", "hello"),
        ("\\bi'?m+a\\b", "I am going to"),
        ("\\bgonna\\b", "going to"),
        ("\\bwanna\\b", "want to"),
        ("\\bgotta\\b", "have to"),
        ("\\bgimme\\b", "give me"),
        ("\\blemme\\b", "let me"),
        ("\\bkinda\\b", "kind of"),
        ("\\bsorta\\b", "sort of"),
        ("\\boutta\\b", "out of"),
        ("\\bdunno\\b", "do not know"),
        ("\\bain'?t\\b", "is not"),
        ("\\by'?all\\b", "you all"),
        ("(?<![A-Za-z])'em\\b", "them"),
        ("(?<![A-Za-z])'?cause\\b", "because"),
        ("\\bcuz\\b", "because"),
        ("\\bya\\b", "you"),
        ("\\bnah\\b", "no"),
        ("\\by(up|ep)\\b", "yes"),
        ("\\buh-huh\\b", "yes"),
        ("\\bmm+-?hm+\\b", "yes"),
        ("\\bnope\\b", "no"),
        ("\\bc'?mon\\b", "come on"),
        ("\\bwhatcha\\b", "what are you"),
        ("\\b(oh,? )?fuck yeah\\b", "yes, great"),
        ("\\bhell yeah\\b", "yes, great"),
        ("\\bfuck it\\b", "forget it"),
        ("\\bscrap that\\b", "forget that"),
        ("\\bthat was a trip\\b", "that was crazy"),
        ("\\bhit me (back|up)\\b", "call me back"),
        ("\\bsee about\\b", "ask about"),
        ("\\bchecking in about\\b", "asking about"),
        ("\\byou(?:'ve)? got ([A-Z][a-z]+)'s phone\\b", "you have reached $1's phone"),
        ("\\b(?:just )?a sec\\b", "a second"),
        ("\\btwo secs\\b", "two seconds"),
        ("\\bwhat'?s up\\b", "how are you"),
        ("\\bwhatup\\b", "how are you"),
        ("\\bwassup\\b", "how are you"),
        ("\\bmy bad\\b", "my mistake"),
        ("\\bfor real\\b", "really"),
        ("\\b,? and shit\\b", " and so on"),
        ("\\bholy shit\\b", "wow"),
        ("\\boh,? shit\\b", "oh no"),
        ("\\bgoddamn(?:ed)?\\b", "damn"),
        ("^well (find|see|get|be|go|talk|figure|have|need|make|do|take|meet)\\b", "we'll $1")
    ]
    private static let rules: [(NSRegularExpression, String)] = table.compactMap { pattern, replacement in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, replacement) }
    }
    private static let sentenceStart = try! NSRegularExpression(pattern: "(^|[.!?]\\s+)([a-z])")

    static func plain(_ text: String) -> String {
        var out = text
        for (rule, replacement) in rules {
            out = rule.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        out = out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        // A replacement may have put a small letter where a sentence starts.
        var result = out
        for match in sentenceStart.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let r = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(r, with: result[r].uppercased())
        }
        return result
    }

    // MARK: - Names

    /// Characters whose names the translator must not touch. Seeded with the game the app is
    /// being built on; more are learned while playing (see `learn`).
    static let seed: Set<String> = ["Jason", "Jay", "Lucia", "Lu", "Kat", "Joey", "Brian", "Cal", "Raul", "Boobie", "Dre", "Roxy"]

    // Capitalised words inside a sentence that are not names.
    private static let notNames: Set<String> = [
        "I", "I'm", "I'll", "I've", "I'd", "God", "Jesus", "Christ", "OK", "Okay", "TV", "Mr", "Mrs", "Ms", "Dr", "Sir", "Ma'am",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February", "March", "April",
        "May", "June", "July", "August", "September", "October", "November", "December", "English", "American", "Spanish",
        "Christmas", "Internet", "Hell", "Lord", "Mom", "Dad", "Daddy", "Mama", "Papa", "Bro", "Sis", "Yeah", "Yes", "No",
    ]
    private static let addressed = try! NSRegularExpression(pattern: ",\\s+([A-Z][a-z]{1,14})(?=[,.!?])")

    /// Names in a line: someone being addressed ("Hey, Joey, ...", "It'll be okay, Lu."). Only
    /// this sure sign is used; a capitalised word elsewhere is as often a title or a menu entry.
    static func learn(from text: String) -> [String] {
        addressed.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let word = String(text[r])
            return notNames.contains(word) ? nil : word
        }
    }

    /// A name standing alone as the first or last sentence of a line ("Sorry. Jay.") is taken
    /// out before translating and put back after: alone, a name that is also a word gets
    /// translated as the word.
    static func withoutNameEnds(_ text: String, names: Set<String>) -> (lead: String, core: String, trail: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        var lead = "", trail = ""
        func bare(_ s: Substring) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,…")) }
        // The whole line is a name.
        if names.contains(bare(Substring(core))) { return (core, "", "") }
        if let cut = core.dropLast().lastIndex(where: { ".!?".contains($0) }) {
            let last = core[core.index(after: cut)...]
            if names.contains(bare(last)) {
                trail = " " + last.trimmingCharacters(in: .whitespaces)
                core = String(core[...cut])
            }
        }
        if let cut = core.firstIndex(where: { ".!?".contains($0) }), cut != core.index(before: core.endIndex) {
            let first = core[...cut]
            if names.contains(bare(first)) {
                lead = String(first) + " "
                core = core[core.index(after: cut)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return (lead, core, trail)
    }

    /// Does the line contain this name as a word of its own?
    static func has(_ name: String, in text: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b", options: .regularExpression) != nil
    }
}

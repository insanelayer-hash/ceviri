import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Natural, context-aware translation with Apple Intelligence's on-device language model
/// (Foundation Models framework, iOS 26+). Free and offline, like Apple Translation, but it
/// follows instructions: casual spoken Turkish, keeps names, uses the previous lines.
enum Refiner {
    static let instructions = """
    You translate English video game subtitles into natural, casual, spoken Turkish, the way \
    a native Turkish speaker would actually say it. Translate only the given line: one line in, \
    one line out. Never add a speaker's name, a label or anything that is not in the English \
    line; if the English line itself starts with a name and a colon (like "LUCIA:"), keep that \
    name unchanged. Write complete, grammatical Turkish sentences with normal punctuation. \
    Translate slang, jokes and swearing with natural Turkish equivalents instead of word for word. \
    Output only the Turkish translation, nothing else.
    """

    /// The model's answer made safe to show: a speaker's name it put in front on its own
    /// ("JASON: …" when the English has none) is removed. Nil when the answer is no good
    /// (a string of words with no punctuation where the English has some), so the caller
    /// falls back to the quick translation.
    static func tidy(_ answer: String, english: String) -> String? {
        var out = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        func labelEnd(_ text: String) -> String.Index? {
            guard let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 28 else { return nil }
            let head = String(text[..<colon])
            guard head.contains(where: { $0.isLetter }), head == head.uppercased(with: Locale(identifier: "tr")) || head == head.uppercased() else { return nil }
            return colon
        }
        if let colon = labelEnd(out), labelEnd(english) == nil {
            out = String(out[out.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let marks = CharacterSet(charactersIn: ".,!?…")
        if english.rangeOfCharacter(from: marks) != nil, out.rangeOfCharacter(from: marks) == nil, out.split(separator: " ").count >= 5 { return nil }
        return out.isEmpty ? nil : out
    }

    /// Whether the on-device model can be used, and a short Turkish explanation for the UI.
    static func availability() -> (ok: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Hazır")
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return (false, "Bu iPhone Apple Intelligence desteklemiyor")
                case .appleIntelligenceNotEnabled:
                    return (false, "Ayarlar > Apple Intelligence ve Siri'den aç")
                case .modelNotReady:
                    return (false, "Model indiriliyor, biraz sonra hazır olur")
                @unknown default:
                    return (false, "Şu an kullanılamıyor")
                }
            }
        }
        #endif
        return (false, "iOS 26 gerekli")
    }

    /// Translates `en`, giving the model the last few lines (English and Turkish) as context.
    static func translate(_ en: String, context: [(en: String, tr: String)]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            var prompt = ""
            if !context.isEmpty {
                prompt += "Previous lines, for context only:\n"
                for line in context {
                    prompt += "EN: \(line.en)\nTR: \(line.tr)\n"
                }
                prompt += "\n"
            }
            prompt += "Translate this subtitle into Turkish:\n\(en)"
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.15))
            let answer = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            guard let clean = tidy(answer, english: en) else { throw RefinerError.unavailable }
            return clean
        }
        #endif
        throw RefinerError.unavailable
    }

    enum RefinerError: Error { case unavailable }
}

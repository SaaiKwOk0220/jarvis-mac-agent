import Foundation

/// Converts common Markdown presentation into plain text for speech synthesis.
enum SpeechTextFormatter {
    static func prepare(_ input: String) -> String {
        var inFence = false
        let lines = input.components(separatedBy: .newlines).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return nil
            }
            if inFence { return raw }
            let line = cleanInlineCode(in: raw)
            let result = line.trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? nil : result
        }
        return lines.joined(separator: "\n")
    }

    /// Clean prose spans independently so Markdown-like code remains literal.
    private static func cleanInlineCode(in text: String) -> String {
        var remainder = text[...]
        var result = ""
        var firstProse = true
        while let open = remainder.firstIndex(of: "`") {
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "`") else { break }
            result += cleanProse(String(remainder[..<open]), stripPrefix: firstProse)
            result += String(remainder[afterOpen..<close])
            remainder = remainder[remainder.index(after: close)...]
            firstProse = false
        }
        result += cleanProse(String(remainder), stripPrefix: firstProse)
        return result
    }

    private static func cleanProse(_ text: String, stripPrefix: Bool) -> String {
        var line = text
        if stripPrefix {
            line = replacing(line, pattern: #"^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#, with: "")
        }
        line = replacing(line, pattern: #"!?\[([^\]]+)\]\(https?://[^\s)]+\)"#, with: "$1")
        line = replacing(line, pattern: #"(?<![\p{L}\p{N}_])\*\*(\S(?:.*?\S)?)\*\*(?![\p{L}\p{N}_])"#, with: "$1")
        line = replacing(line, pattern: #"(?<![\p{L}\p{N}_])__(\S(?:.*?\S)?)__(?![\p{L}\p{N}_])"#, with: "$1")
        line = replacing(line, pattern: #"(?<!\S)[*_]([^*_\n]+)[*_](?!\S)"#, with: "$1")
        return replacing(line, pattern: #"[\t ]{2,}"#, with: " ")
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

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
            var line = raw
            if !inFence {
                line = replacing(line, pattern: #"^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#, with: "")
                line = replacing(line, pattern: #"!?\[([^\]]+)\]\(https?://[^\s)]+\)"#, with: "$1")
                line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "~~", with: "")
                line = replacing(line, pattern: #"(?<!\S)[*_]([^*_\n]+)[*_](?!\S)"#, with: "$1")
            }
            line = line.replacingOccurrences(of: "`", with: "")
            line = replacing(line, pattern: #"https?://[^\s]+"#, with: "")
            line = replacing(line, pattern: #"[\t ]{2,}"#, with: " ")
            let result = line.trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? nil : result
        }
        return lines.joined(separator: "\n")
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

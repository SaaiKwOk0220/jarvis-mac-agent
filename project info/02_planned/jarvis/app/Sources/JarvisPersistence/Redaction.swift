import Foundation

public func redactSecrets(_ input: String) -> String {
    let patterns: [(String, String)] = [
        (#"(?i)([\"'](?:api[_-]?key|apikey|access[_-]?token|token|secret|password|passwd|pwd|cookie|set-cookie)[\"']\s*:\s*[\"'])[^\"']*([\"'])"#, "$1[REDACTED]$2"),
        (#"(?i)\b(cookie|set-cookie)\s*:\s*[^\r\n]+"#, "$1: [REDACTED]"),
        (#"(?i)\bcookie\s*=\s*([A-Za-z0-9_-]+)=([^\s,;]+)"#, "cookie=$1=[REDACTED]"),
        (#"(?i)\b(api[_-]?key|apikey|access[_-]?token|token|secret)\b(\s*[:=]\s*)([\"']?)[^\s,;\"'&]+"#, "$1$2$3[REDACTED]$3"),
        (#"(?i)\bBearer\s+[^\s,;]+"#, "Bearer [REDACTED]"),
        (#"(?i)\b(password|passwd|pwd)\b(\s*[:=]\s*)([\"']?)[^\s,;\"'&]+"#, "$1$2$3[REDACTED]$3"),
    ]

    return patterns.reduce(input) { value, pattern in
        guard let expression = try? NSRegularExpression(pattern: pattern.0) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: pattern.1
        )
    }
}

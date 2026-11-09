import Foundation

/// Validates a conservative browser destination without credentials, query or fragment.
public enum BrowserOpenURL {
    public static func validated(_ value: String) -> URL? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty, host.contains("."),
              !host.lowercased().hasSuffix(".local"), !host.lowercased().hasSuffix(".localhost"),
              host.lowercased() != "localhost", !host.hasSuffix("."),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").contains($0) }),
              host.contains(where: { $0.isLetter }),
              let url = parts.url, url.absoluteString == value else { return nil }
        return url
    }
}

import Foundation
import JarvisDomain

/// Explicit, user-controlled allowlists used by the local policy gate.
public struct PolicyConfig: Codable, Equatable, Sendable {
    public var approvedDirectories: [String]
    public var commandNames: [String]
    public var browserProfiles: [String]
    public var sites: [String]
    public var applicationBundleIDs: [String]

    public init(
        approvedDirectories: [String] = [],
        commandNames: [String] = [],
        browserProfiles: [String] = [],
        sites: [String] = [],
        applicationBundleIDs: [String] = []
    ) {
        self.approvedDirectories = approvedDirectories
        self.commandNames = commandNames
        self.browserProfiles = browserProfiles
        self.sites = sites
        self.applicationBundleIDs = applicationBundleIDs
    }

    /// Compatibility spelling for callers that describe these as approved commands.
    public var approvedCommands: [String] {
        get { commandNames }
        set { commandNames = newValue }
    }
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    case requireApproval(reason: String)
    case deny(reason: String)
}

public protocol PolicyEvaluator: Sendable {
    func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision
}

/// Deterministic policy: model-provided text cannot expand any configured allowlist.
public struct Policy: PolicyEvaluator, Sendable {
    public init() {}

    public func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        switch request.sideEffect {
        case .money:
            return .deny(reason: "money actions are unsupported")
        case .localExecute:
            guard config.commandNames.contains(request.name) else {
                return .deny(reason: "command is not allowlisted")
            }
            if !isWithinApprovedDirectory(request.target, config: config) {
                return .deny(reason: "target is outside approved directories")
            }
            return .allow
        case .read:
            return evaluateRead(request, config: config)
        case .localWrite:
            guard isWithinApprovedDirectory(request.target, config: config) else {
                return .deny(reason: "target is outside approved directories")
            }
            return .requireApproval(reason: "local write changes local state")
        case .externalSend:
            guard isAllowlistedExternalTarget(request.target, config: config) else {
                return .deny(reason: "site or application is not allowlisted")
            }
            return .requireApproval(reason: "external send has an external side effect")
        case .upload:
            return .requireApproval(reason: "upload transfers data externally")
        case .delete:
            if looksLikePath(request.target) && !isWithinApprovedDirectory(request.target, config: config) {
                return .deny(reason: "target is outside approved directories")
            }
            return .requireApproval(reason: "delete removes data")
        case .credential:
            return .requireApproval(reason: "credential or privilege change requires approval")
        }
    }

    private func evaluateRead(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        if let host = URL(string: request.target)?.host, !host.isEmpty {
            guard config.sites.contains(where: { siteMatches(host: host, configured: $0) }) else {
                return .deny(reason: "site is not allowlisted")
            }
            if let profile = browserProfile(in: request), !config.browserProfiles.contains(profile) {
                return .deny(reason: "browser profile is not allowlisted")
            }
            return .allow
        }
        if request.target.hasPrefix("com.") {
            return config.applicationBundleIDs.contains(request.target)
                ? .allow : .deny(reason: "application is not allowlisted")
        }
        guard isWithinApprovedDirectory(request.target, config: config) else {
            return .deny(reason: "target is outside approved directories")
        }
        return .allow
    }

    private func isAllowlistedExternalTarget(_ target: String, config: PolicyConfig) -> Bool {
        if let host = URL(string: target)?.host { return config.sites.contains(where: { siteMatches(host: host, configured: $0) }) }
        if target.hasPrefix("com.") { return config.applicationBundleIDs.contains(target) }
        return true
    }

    private func siteMatches(host: String, configured: String) -> Bool {
        let normalized = configured.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let candidate = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return candidate == normalized
    }

    private func browserProfile(in request: ToolRequest) -> String? {
        for part in request.payload.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            let token = String(part)
            if token.hasPrefix("profile=") { return String(token.dropFirst("profile=".count)) }
            if token.hasPrefix("profile:") { return String(token.dropFirst("profile:".count)) }
        }
        return nil
    }

    private func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~")
    }

    private func isWithinApprovedDirectory(_ target: String, config: PolicyConfig) -> Bool {
        guard !config.approvedDirectories.isEmpty else { return false }
        let resolvedTarget = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath()
        return config.approvedDirectories.contains { directory in
            let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return resolvedTarget.path == root.path || resolvedTarget.path.hasPrefix(rootPath)
        }
    }
}

public typealias DeterministicPolicyEvaluator = Policy
public typealias DefaultPolicyEvaluator = Policy

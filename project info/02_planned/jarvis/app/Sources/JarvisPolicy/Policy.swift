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
            guard isWithinApprovedDirectory(request.target, config: config) else {
                return .deny(reason: "target is outside approved directories")
            }
            guard isAllowedTestInvocation(request) else {
                return .deny(reason: "command invocation is not allowlisted")
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
            guard isAllowlistedSendTarget(request.target, config: config) else {
                return .deny(reason: "site or application is not allowlisted")
            }
            return .requireApproval(reason: "external send has an external side effect")
        case .upload:
            return .requireApproval(reason: "upload transfers data externally")
        case .delete:
            guard let target = resolvedDeleteTarget(request, config: config), isWithinApprovedDirectory(target, config: config) else {
                return .deny(reason: "delete target is not an approved local path")
            }
            return .requireApproval(reason: "delete removes data")
        case .credential:
            return .requireApproval(reason: "credential or privilege change requires approval")
        }
    }

    private func evaluateRead(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        if URLComponents(string: request.target)?.scheme != nil {
            guard let host = exactHTTPSHost(request.target), config.sites.contains(host) else {
                return .deny(reason: "site is not allowlisted")
            }
            guard let profile = request.scope?.browserProfile else {
                return .deny(reason: "browser profile is required")
            }
            guard config.browserProfiles.contains(profile) else {
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

    private func isAllowedTestInvocation(_ request: ToolRequest) -> Bool {
        request.payload == "test" && ["swift", "xcodebuild"].contains(request.name)
    }

    private func isAllowlistedSendTarget(_ target: String, config: PolicyConfig) -> Bool {
        if config.applicationBundleIDs.contains(target) { return true }
        guard let host = exactHTTPSHost(target) else { return false }
        return config.sites.contains(host)
    }

    private func exactHTTPSHost(_ target: String) -> String? {
        guard let components = URLComponents(string: target),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }
        return host
    }

    private func resolvedDeleteTarget(_ request: ToolRequest, config: PolicyConfig) -> URL? {
        let target = request.target
        if target.hasPrefix("file:") {
            guard let components = URLComponents(string: target),
                  components.scheme?.lowercased() == "file",
                  components.host == nil || components.host == "",
                  let url = components.url,
                  url.isFileURL,
                  !url.path.isEmpty
            else { return nil }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        if URLComponents(string: target)?.scheme != nil || target.hasPrefix("~") || target.isEmpty {
            return nil
        }
        if target.hasPrefix("/") {
            return URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard let workingDirectory = request.scope?.workingDirectory,
              isWithinApprovedDirectory(workingDirectory, config: config)
        else { return nil }
        return URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(target)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func isWithinApprovedDirectory(_ target: URL, config: PolicyConfig) -> Bool {
        guard !config.approvedDirectories.isEmpty else { return false }
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        return config.approvedDirectories.contains { directory in
            let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            return resolvedTarget.path == root.path || resolvedTarget.path.hasPrefix(rootPath)
        }
    }

    private func isWithinApprovedDirectory(_ target: String, config: PolicyConfig) -> Bool {
        isWithinApprovedDirectory(URL(fileURLWithPath: target), config: config)
    }
}

public typealias DeterministicPolicyEvaluator = Policy
public typealias DefaultPolicyEvaluator = Policy

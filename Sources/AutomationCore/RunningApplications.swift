import AppKit
import Foundation

public enum ApplicationActivationPolicy: String, Codable, Sendable {
    case regular
    case accessory
    case prohibited
    case unknown

    init(_ policy: NSApplication.ActivationPolicy) {
        switch policy {
        case .regular:
            self = .regular
        case .accessory:
            self = .accessory
        case .prohibited:
            self = .prohibited
        @unknown default:
            self = .unknown
        }
    }
}

public struct RunningApplicationInfo: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let activationPolicy: ApplicationActivationPolicy
    public let isActive: Bool
    public let isHidden: Bool
    public let isTerminated: Bool

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        localizedName: String?,
        activationPolicy: ApplicationActivationPolicy,
        isActive: Bool,
        isHidden: Bool,
        isTerminated: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.isHidden = isHidden
        self.isTerminated = isTerminated
    }
}

@MainActor
public struct RunningApplicationCatalog {
    public init() {}

    public func applications() -> [RunningApplicationInfo] {
        NSWorkspace.shared.runningApplications
            .map {
                RunningApplicationInfo(
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    localizedName: $0.localizedName,
                    activationPolicy: ApplicationActivationPolicy($0.activationPolicy),
                    isActive: $0.isActive,
                    isHidden: $0.isHidden,
                    isTerminated: $0.isTerminated
                )
            }
            .sorted {
                let left = $0.localizedName ?? $0.bundleIdentifier ?? ""
                let right = $1.localizedName ?? $1.bundleIdentifier ?? ""
                if left.caseInsensitiveCompare(right) == .orderedSame {
                    return $0.processIdentifier < $1.processIdentifier
                }
                return left.caseInsensitiveCompare(right) == .orderedAscending
            }
    }
}

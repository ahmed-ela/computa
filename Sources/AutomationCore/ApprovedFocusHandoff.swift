import Foundation

/// Bounded preparation for an already-approved action, not an input retry.
/// Only our own approval host may be reclaimed from, and only once. A third
/// application taking focus aborts the handoff instead of fighting the user.
public struct ApprovedFocusHandoff: Sendable {
    public enum Foreground: Equatable, Sendable { case target, approvalHost, other, unknown }
    public enum Decision: Equatable, Sendable { case wait, ready, restoreOnce, stop }

    private var consecutiveFocused = 0
    private var samples = 0
    private var restored = false
    private var stopped = false

    public init() {}

    public mutating func observe(
        _ focus: AccessibilitySnapshotFocusState, foreground: Foreground
    ) -> Decision {
        guard !stopped else { return .stop }
        samples += 1
        guard samples <= 80, foreground != .other, foreground != .unknown else {
            stopped = true
            return .stop
        }
        if focus == .notWindow { return .ready }
        if focus == .focused, foreground == .target {
            consecutiveFocused += 1
            return consecutiveFocused >= 12 ? .ready : .wait
        }
        consecutiveFocused = 0
        if foreground == .approvalHost, !restored {
            restored = true
            return .restoreOnce
        }
        return .wait
    }
}

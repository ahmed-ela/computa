import Foundation

/// A changing image cannot certify a synchronized Accessibility tree. One
/// ordinary screenshot-only retry may still provide a valid observation,
/// under the exact same permissions, focus, window and freshness checks.
enum NativeCombinedCapture {
    static let omissionMarker = "ACCESSIBILITY_OMITTED reason=pixels_changed. "
        + "This is a screenshot-only observation, not synchronized Accessibility. "
        + "No snapshot_id is available; do not reuse an older one. "
        + "For animated surfaces prefer include_accessibility=false."

    static func run<Result>(
        isolation: isolated (any Actor)? = #isolation,
        includeAccessibility: Bool,
        capture: () async throws -> Result,
        screenshotOnly: () async throws -> Result
    ) async throws -> Result {
        do { return try await capture() }
        catch {
            guard includeAccessibility,
                  NativePostActionImageObservation.allowsSynchronizationFallback(error) else { throw error }
            try Task.checkCancellation()
            // Deliberately outside another catch/retry: at most two captures,
            // and neither path may perform computer input.
            return try await screenshotOnly()
        }
    }
}

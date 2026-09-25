import Foundation

/// Observation is a separate, read-only phase after exactly one dispatch. A
/// failed observation must never look like a failed mutation to be replayed.
enum NativePostActionExecution {
    static func run(
        isolation: isolated (any Actor)? = #isolation,
        invalidate: () throws -> Void,
        dispatch: () async throws -> Void,
        observe: () async throws -> String,
        discardObservation: () -> Void
    ) async throws -> String {
        try invalidate()
        try await dispatch()
        do {
            let observation = try await observe()
            return "POST_ACTION_OBSERVATION status=available action_dispatched=true modality=accessibility. "
                + "Use the new snapshot_id below. Verify the actual outcome; dispatch is not success. Do not repeat the action.\n"
                + observation
        } catch {
            discardObservation()
            return "POST_ACTION_OBSERVATION status=unavailable action_dispatched=true. "
                + "The action was dispatched once, but its outcome is unverified. No observation IDs remain valid. "
                + "Do not repeat the action; call computer_v2_snapshot to observe. Reason: "
                + String(error.localizedDescription.prefix(400))
        }
    }
}

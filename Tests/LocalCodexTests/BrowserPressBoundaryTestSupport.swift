import Foundation
@testable import LocalCodex

struct BrowserPressBoundaryChild: BrowserOwnedChild {
    let processIdentifier: Int32
    let isRunning = true
    func stop() async -> OwnedChildProcess.StopResult {
        .init(rootReaped: true, groupGone: true, issues: [])
    }
}

actor BrowserPressBoundaryPause {
    struct Snapshot: Sendable {
        var events = [String]()
        var handle: UUID?
        var snapshotID: UUID?
    }
    private var value = Snapshot()
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter(handle: UUID, snapshotID: UUID) async {
        value.handle = handle
        value.snapshotID = snapshotID
        value.events.append("proof_started")
        entered = true
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entryWaiter?.resume()
            entryWaiter = nil
        }
        value.events.append("proof_completed")
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
    func returned() { value.events.append("press_returned") }
    func snapshot() -> Snapshot { value }
}

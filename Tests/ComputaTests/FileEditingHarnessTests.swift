import Foundation
import XCTest
@testable import Computa

final class FileEditingContractTests: XCTestCase {
    func testFileKindsPreserveNativeDiffAndMoveIdentity() throws {
        let raw: [[String: Any]] = [
            ["path": "/fixture/new.swift", "kind": ["type": "add"], "diff": "let value = 1\n"],
            ["path": "/fixture/old.swift", "kind": ["type": "delete"], "diff": "let old = 0\n"],
            ["path": "/fixture/name.swift", "kind": ["type": "update", "move_path": "/fixture/renamed.swift"],
             "diff": "@@ -1 +1 @@\n-old\n+new\n\n\nMoved to: /fixture/renamed.swift"],
        ]
        let changes = try XCTUnwrap(AppServerFileChangeContract.changes(raw))
        XCTAssertEqual(changes.map(\.kind), ["add", "delete", "update"])
        XCTAssertEqual(changes[0].diff, "let value = 1\n")
        XCTAssertEqual(changes[2].movePath, "/fixture/renamed.swift")
        XCTAssertEqual(changes[2].diff, "@@ -1 +1 @@\n-old\n+new\n")
    }

    func testExactNativeMoveMetadataNormalizesEmptyAndContentDiffsWithoutChangingPrefixBytes() throws {
        for prefix in ["", "@@ -1 +1 @@\n-old\n+new\n", "@@ -1 +1 @@\n-old\n+e\u{301} +Moved to: text\n"] {
            let path = "/fixture/re\u{301}named with spaces.swift"
            let raw = prefix + "\n\nMoved to: " + path
            let change = try XCTUnwrap(AppServerFileChangeContract.changes([
                ["path": "/fixture/old.swift", "kind": ["type": "update", "move_path": path], "diff": raw],
            ])?.first)
            XCTAssertEqual(change.movePath, path)
            XCTAssertEqual(Array(change.diff.utf8), Array(prefix.utf8))
        }
    }

    func testUnknownUnmovedOrNonByteExactMoveMetadataRemainsUntouched() throws {
        let path = "/fixture/re\u{301}named.swift"
        let diffs = ["\n\nMoved to: /fixture/different.swift", "\nMoved to: " + path,
                     "\n\nMoved to: " + path + "\n", "\n\nMoved to: /fixture/rénamed.swift"]
        for diff in diffs {
            let change = try XCTUnwrap(AppServerFileChangeContract.changes([
                ["path": "/fixture/old.swift", "kind": ["type": "update", "move_path": path], "diff": diff],
            ])?.first)
            XCTAssertEqual(Array(change.diff.utf8), Array(diff.utf8))
        }
        let metadata = "\n\nMoved to: " + path
        for kind in ["add", "delete", "update"] {
            let change = try XCTUnwrap(AppServerFileChangeContract.changes([
                ["path": "/fixture/file.swift", "kind": ["type": kind], "diff": metadata],
            ])?.first)
            XCTAssertEqual(change.diff, metadata, "Untyped content must never be interpreted as move metadata")
        }
    }

    @MainActor
    func testActualSavedNativeMoveWireHydratesFourFileChangesAndFourLastTurnFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy.py").path
        let destination = root.appendingPathComponent("helpers.py").path
        // Exact shape captured from the installed engine's owned ChatGPT
        // thread/read response: completed fileChange with 3 content changes
        // and a typed pure move carrying the builder's metadata-only suffix.
        let patch: [String: Any] = ["id": "native-patch", "type": "fileChange", "status": "completed", "changes": [
            ["path": root.appendingPathComponent("README.md").path, "kind": ["type": "add"], "diff": "Tests\n"],
            ["path": source, "kind": ["type": "update", "move_path": destination], "diff": "\n\nMoved to: " + destination],
            ["path": root.appendingPathComponent("math_utils.py").path, "kind": ["type": "update", "move_path": NSNull()], "diff": "@@ -1 +1 @@\n-old\n+new\n"],
            ["path": root.appendingPathComponent("obsolete.txt").path, "kind": ["type": "delete"], "diff": "obsolete\n"],
        ]]
        let history = try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": [[
            "id": "owned-turn", "items": [["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Edit the fixture"]]], patch],
        ]]]]])
        let edit = try XCTUnwrap(AppServerThreadHistoryContract.entries(from: history).last)
        XCTAssertEqual(edit.toolEvent?.status, .succeeded)
        XCTAssertEqual(edit.turnID, "owned-turn")
        XCTAssertEqual(edit.fileChanges?.count, 4)
        let move = try XCTUnwrap(edit.fileChanges?.first { $0.movePath == destination })
        XCTAssertEqual(move.diff, "")
        let aggregate = """
        diff --git a/README.md b/README.md
        new file mode 100644
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1 @@
        +Tests
        diff --git a/math_utils.py b/math_utils.py
        --- a/math_utils.py
        +++ b/math_utils.py
        @@ -1 +1 @@
        -old
        +new
        diff --git a/obsolete.txt b/obsolete.txt
        deleted file mode 100644
        --- a/obsolete.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -obsolete
        """ + "\n"
        let snapshot = try await WorkspaceReviewService().load(workspace: root.path, scope: .lastTurn,
            turnDiff: aggregate, turnChanges: edit.fileChanges ?? [])
        XCTAssertEqual(Set(snapshot.files.map(\.path)), Set(["README.md", "math_utils.py", "obsolete.txt", "helpers.py"]))
        let renamed = try XCTUnwrap(snapshot.files.first { $0.path == "helpers.py" })
        XCTAssertEqual(renamed.previousPath, "legacy.py")
        XCTAssertEqual(renamed.status, "renamed")
        XCTAssertEqual(renamed.additions, 0)
        XCTAssertEqual(renamed.deletions, 0)
        XCTAssertFalse(renamed.truncated)
    }

    func testMalformedAmbiguousAndOversizedChangesAreRejectedWithoutPartialProjection() {
        let good: [String: Any] = ["path": "/fixture/a", "kind": ["type": "add"], "diff": "text"]
        XCTAssertNil(AppServerFileChangeContract.changes([good, good]))
        XCTAssertNil(AppServerFileChangeContract.changes([good, ["path": "/fixture/b", "kind": ["type": "exec"], "diff": ""]]))
        XCTAssertNil(AppServerFileChangeContract.changes([["path": "/fixture/a", "kind": ["type": "add", "movePath": "/fixture/b"], "diff": ""]]))
        XCTAssertNil(AppServerFileChangeContract.changes([["path": "/fixture/a", "kind": ["type": "update", "movePath": "/fixture/b", "move_path": "/fixture/c"], "diff": ""]]))
        XCTAssertNil(AppServerFileChangeContract.changes([["path": "bad\0path", "kind": ["type": "add"], "diff": ""]]))
        XCTAssertNil(AppServerFileChangeContract.changes([["path": "/fixture/a", "kind": ["type": "add"],
            "diff": String(repeating: "é", count: AppServerFileChangeContract.maximumDiffBytes / 2 + 1)]]))
    }

    func testFailureAndDeclineNeverPresentAnAppliedClaim() throws {
        for status in ["failed", "declined"] {
            let entry = try XCTUnwrap(AppServerFileChangeContract.entry(item: item(status: status), turnID: "turn"))
            XCTAssertEqual(entry.toolEvent?.status, .failed)
            XCTAssertFalse(entry.body.hasPrefix("Changed"))
            XCTAssertEqual(entry.fileChanges?.count, 1, "A failed patch's proposed content stays distinct from aggregate actual changes")
            XCTAssertEqual(entry.turnID, "turn")
        }
    }

    func testStreamingCompletionKeepsItemIdentityAndRejectsLateOrCrossedUpdates() throws {
        var transcript = AppServerFileChangeTranscript()
        let first = try XCTUnwrap(transcript.patchUpdated(itemID: "patch", turnID: "turn", changes: item(status: "inProgress")["changes"]))
        XCTAssertEqual(first.toolEvent?.status, .running)
        XCTAssertNil(transcript.receive(item: item(status: "inProgress"), turnID: "other", isCompleted: false))
        XCTAssertNil(transcript.receive(item: item(status: "inProgress"), turnID: "turn", isCompleted: true))
        let completed = try XCTUnwrap(transcript.receive(item: item(status: "completed"), turnID: "turn", isCompleted: true))
        XCTAssertEqual(completed.timestamp, first.timestamp)
        XCTAssertEqual(completed.toolEvent?.status, .succeeded)
        XCTAssertNil(transcript.patchUpdated(itemID: "patch", turnID: "turn", changes: []))
        XCTAssertNil(transcript.receive(item: item(status: "completed"), turnID: "turn", isCompleted: true))
    }

    func testUnconfirmedInterruptedProposalCanLaterAcceptAuthoritativeCompletion() throws {
        var transcript = AppServerFileChangeTranscript()
        _ = transcript.receive(item: item(status: "inProgress"), turnID: "turn", isCompleted: false)
        let entries = transcript.finishUnconfirmed(turnID: "turn")
        XCTAssertEqual(entries.first?.body, "File-change outcome unconfirmed")
        XCTAssertEqual(entries.first?.toolEvent?.status, .failed)
        let completed = try XCTUnwrap(transcript.receive(item: item(status: "failed"), turnID: "turn", isCompleted: true))
        XCTAssertEqual(completed.body, "File changes failed: 1 file")
    }

    func testAggregateStoreReplacesSameTurnPreservesOtherTurnsAndCannotTraversePath() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentTurnDiffStore(directory: root)
        try store.save(threadID: "../../thread", turnID: "one", diff: "first")
        try store.save(threadID: "../../thread", turnID: "two", diff: "other")
        try store.save(threadID: "../../thread", turnID: "one", diff: "latest")
        XCTAssertEqual(try store.load(threadID: "../../thread"), [AgentTurnDiff(id: "one", diff: "latest"), AgentTurnDiff(id: "two", diff: "other")])
        XCTAssertEqual(try store.load(threadID: "another"), [])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.deletingLastPathComponent().resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        try store.save(threadID: "../../thread", turnID: "one", diff: "")
        XCTAssertEqual(try store.load(threadID: "../../thread").first?.diff, "", "An engine clear must replace the old aggregate")
    }

    func testAggregateStoreRejectsInvalidIdentityAndCorruptRecord() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentTurnDiffStore(directory: root)
        XCTAssertThrowsError(try store.save(threadID: "thread", turnID: "", diff: "diff"))
        XCTAssertThrowsError(try store.save(threadID: "thread", turnID: "turn",
            diff: String(repeating: "x", count: AppServerFileChangeContract.maximumDiffBytes + 1)))
        try store.save(threadID: "thread", turnID: "turn", diff: "diff")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(threadID: "thread"))
    }

    func testAggregateStoreRetainsMostRecent256TurnsWithoutBlockingLaterWork() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentTurnDiffStore(directory: root)
        for index in 0..<260 { try store.save(threadID: "thread", turnID: "turn-\(index)", diff: index == 259 ? "" : "diff") }
        let turns = try store.load(threadID: "thread")
        XCTAssertEqual(turns.count, 256)
        XCTAssertEqual(turns.first?.id, "turn-4")
        XCTAssertEqual(turns.last, AgentTurnDiff(id: "turn-259", diff: ""))
    }

    func testHistoryHydratesFileChangesAtTheirRealTurnAndUserGroup() throws {
        var patch = item(status: "completed")
        patch["type"] = "fileChange"
        let data = try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": [[
            "id": "saved-turn", "startedAt": 1234,
            "items": [["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Edit this file"]]], patch],
        ]]]]])
        let entries = try AppServerThreadHistoryContract.entries(from: data)
        let edit = try XCTUnwrap(entries.last)
        XCTAssertEqual(edit.id, "patch")
        XCTAssertEqual(edit.turnID, "saved-turn")
        XCTAssertEqual(edit.activityGroupID, "user")
        XCTAssertEqual(edit.timestamp, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(edit.toolEvent?.status, .succeeded)
        XCTAssertEqual(edit.fileChanges?.first?.diff, "content\n")
    }

    func testLastTurnReviewClearsEarlierPatchWhenLaterUserTurnHasNoEdits() throws {
        let data = try JSONSerialization.data(withJSONObject: ["result": ["thread": ["turns": [
            ["id": "edited", "items": [["id": "user-one", "type": "userMessage"]]],
            ["id": "no-edits", "items": [["id": "user-two", "type": "userMessage"]]],
            ["id": "maintenance", "items": [["id": "compaction", "type": "contextCompaction"]]],
        ]]]])
        let diffs = try AppServerThreadHistoryContract.turnDiffs(from: data,
            saved: [AgentTurnDiff(id: "edited", diff: "authoritative old patch")])
        XCTAssertEqual(diffs, [AgentTurnDiff(id: "edited", diff: "authoritative old patch"), AgentTurnDiff(id: "no-edits", diff: "")])
    }

    func testCatalogEnablesOnlyPatchCapabilityAndPreservesFallbackContextAndModalities() throws {
        let data = try ComputaModelToolCatalog.catalogData(additionalModelID: "fixture/model")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(Set(models.compactMap { $0["slug"] as? String }), Set(LocalModelCatalog.options.map(\.id) + ["fixture/model"]))
        for model in models {
            let id = try XCTUnwrap(model["slug"] as? String)
            if LocalModelCatalog.isWebBrowser(id) { XCTAssertEqual(model["apply_patch_tool_type"] as? String, "freeform") }
            else { XCTAssertTrue(model["apply_patch_tool_type"] is NSNull, "The local MLX contract supports function calls, not custom freeform calls") }
            XCTAssertEqual(model["shell_type"] as? String, "unified_exec")
            XCTAssertEqual(model["context_window"] as? Int, 272_000)
            XCTAssertEqual(model["input_modalities"] as? [String], ["text", "image"])
            XCTAssertEqual(model["effective_context_window_percent"] as? Int, 95)
            XCTAssertEqual(model["experimental_supported_tools"] as? [String], [])
            XCTAssertEqual(model["include_apps_usage_instructions"] as? Bool, false)
            XCTAssertEqual(model["supports_experimental_context"] as? Bool, false)
            let messages = try XCTUnwrap(model["model_messages"] as? [String: Any])
            XCTAssertTrue((messages["instructions_template"] as? String)?.hasPrefix("You are Computa") == true)
        }
    }

    func testCatalogAtomicallyWritesPrivateFileAndQuotesLaunchPathAsData() throws {
        let root = try temporaryRoot().appendingPathComponent("project with \"quote\"", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = try ComputaModelToolCatalog.prepare(codexHomePath: root.path)
        XCTAssertEqual(try Data(contentsOf: url), try ComputaModelToolCatalog.catalogData())
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
        let arguments = try ComputaModelToolCatalog.launchArguments(catalogURL: url)
        XCTAssertEqual(arguments.first, "-c")
        let quoted = String(try XCTUnwrap(arguments.last).dropFirst("model_catalog_json=".count))
        XCTAssertFalse(quoted.contains("\\/"), "TOML does not accept JSON's optional escaped slash")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(quoted.utf8)), url.path)
    }

    private func item(status: String) -> [String: Any] {
        ["id": "patch", "status": status, "changes": [["path": "/fixture/file", "kind": ["type": "add"], "diff": "content\n"]]]
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaFileChanges-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

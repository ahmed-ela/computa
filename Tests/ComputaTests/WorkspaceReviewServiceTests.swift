import Foundation
import XCTest
@testable import Computa

final class WorkspaceReviewServiceTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var service: WorkspaceReviewService!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: "/Volumes/t7/computa-file-review-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceReviewService()
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Computa review fixture"])
        _ = try git(["config", "user.email", "fixture@example.invalid"])
        try write("code.swift", "let number = 1\nlet name = \"original\"\n")
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "Fixture baseline"])
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
        service = nil
    }

    func testUnstagedAndStagedAreDistinctAndStagePreservesWorktree() async throws {
        try write("code.swift", "let number = 2\nlet name = \"original\"\n")
        _ = try git(["add", "code.swift"])
        try write("code.swift", "let number = 2\nlet name = \"changed\"\n")
        let staged = try await load(.staged)
        XCTAssertTrue(staged.files[0].diff.contains("+let number = 2"))
        XCTAssertFalse(staged.files[0].diff.contains("+let name = \"changed\""))
        let unstaged = try await load(.unstaged)
        XCTAssertTrue(unstaged.canStage)
        XCTAssertTrue(unstaged.canRevert)
        XCTAssertFalse(unstaged.canUnstage)
        XCTAssertTrue(unstaged.files[0].diff.contains("+let name = \"changed\""))
        let updated = try await service.mutate(snapshotID: unstaged.id, operation: .stage, fileID: unstaged.files[0].id)
        XCTAssertTrue(updated.files.isEmpty)
        XCTAssertEqual(try read("code.swift"), "let number = 2\nlet name = \"changed\"\n")
        XCTAssertEqual(try git(["show", ":code.swift"]), try read("code.swift"))
    }

    func testUnstagePreservesWorkingFileAndMovesChangeToUnstaged() async throws {
        try write("code.swift", "let number = 42\n")
        _ = try git(["add", "code.swift"])
        let staged = try await load(.staged)
        let updated = try await service.mutate(snapshotID: staged.id, operation: .unstage)
        XCTAssertTrue(updated.files.isEmpty)
        XCTAssertEqual(try read("code.swift"), "let number = 42\n")
        let unstaged = try await load(.unstaged)
        XCTAssertEqual(unstaged.files.count, 1)
    }

    func testRevertUnstagedPreservesExistingStagedChange() async throws {
        try write("code.swift", "let number = 2\nlet name = \"original\"\n")
        _ = try git(["add", "code.swift"])
        try write("code.swift", "let number = 2\nlet name = \"later\"\n")
        let snapshot = try await load(.unstaged)
        let result = try await service.mutate(snapshotID: snapshot.id, operation: .revert)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(try read("code.swift"), "let number = 2\nlet name = \"original\"\n")
        let staged = try await load(.staged)
        XCTAssertEqual(staged.files.count, 1)
    }

    func testStageAndUnstageOneHunkLeavesOtherHunkUntouched() async throws {
        let baseline = (1...30).map { "line \($0)\n" }.joined()
        try write("two.txt", baseline)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "Two hunk fixture"])
        let changed = baseline.replacingOccurrences(of: "line 2\n", with: "first change\n")
            .replacingOccurrences(of: "line 28\n", with: "second change\n")
        try write("two.txt", changed)
        let snapshot = try await load(.unstaged)
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "two.txt" })
        XCTAssertEqual(file.hunks.count, 2)
        let afterStage = try await service.mutate(snapshotID: snapshot.id, operation: .stage, fileID: file.id, hunkID: file.hunks[0].id)
        XCTAssertEqual(afterStage.files[0].hunks.count, 1)
        let indexed = try git(["show", ":two.txt"])
        XCTAssertTrue(indexed.contains("first change"))
        XCTAssertFalse(indexed.contains("second change"))
        let staged = try await load(.staged)
        let afterUnstage = try await service.mutate(snapshotID: staged.id, operation: .unstage,
                                                   fileID: staged.files[0].id, hunkID: staged.files[0].hunks[0].id)
        XCTAssertTrue(afterUnstage.files.isEmpty)
        XCTAssertEqual(try read("two.txt"), changed)
    }

    func testRevertOneHunkLeavesOtherWorkingChange() async throws {
        let baseline = (1...30).map { "line \($0)\n" }.joined()
        try write("two.txt", baseline)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "Two hunk fixture"])
        try write("two.txt", baseline.replacingOccurrences(of: "line 2\n", with: "first change\n")
            .replacingOccurrences(of: "line 28\n", with: "second change\n"))
        let snapshot = try await load(.unstaged)
        let file = snapshot.files[0]
        let result = try await service.mutate(snapshotID: snapshot.id, operation: .revert, fileID: file.id, hunkID: file.hunks[0].id)
        XCTAssertEqual(result.files[0].hunks.count, 1)
        XCTAssertFalse(try read("two.txt").contains("first change"))
        XCTAssertTrue(try read("two.txt").contains("second change"))
    }

    func testStaleWorkingContentRejectedEvenWhenStatusAndLengthAreSame() async throws {
        try write("code.swift", "let number = 2\n")
        let snapshot = try await load(.unstaged)
        try write("code.swift", "let number = 3\n")
        await assertFailure(.staleSnapshot) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .revert)
        }
        XCTAssertEqual(try read("code.swift"), "let number = 3\n")
        XCTAssertTrue(try git(["diff", "--cached"]).isEmpty)
    }

    func testStaleIndexAndHEADRejected() async throws {
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        _ = try git(["add", "code.swift"])
        await assertFailure(.staleSnapshot) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage)
        }
        let staged = try await load(.staged)
        _ = try git(["commit", "-qm", "Changed HEAD"])
        await assertFailure(.staleSnapshot) {
            _ = try await self.service.mutate(snapshotID: staged.id, operation: .unstage)
        }
    }

    func testSuccessfulMutationConsumesOldSnapshots() async throws {
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .stage)
        await assertFailure(.staleSnapshot) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage)
        }
    }

    func testUntrackedTextCanStageUnstageAndRevert() async throws {
        try write("new file.txt", "new text\nsecond line\n")
        let snapshot = try await load(.unstaged)
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "new file.txt" })
        XCTAssertEqual(file.status, "untracked")
        XCTAssertEqual(file.additions, 2)
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .stage, fileID: file.id)
        let staged = try await load(.staged)
        XCTAssertEqual(staged.files[0].status, "added")
        _ = try await service.mutate(snapshotID: staged.id, operation: .unstage)
        let untracked = try await load(.unstaged)
        _ = try await service.mutate(snapshotID: untracked.id, operation: .revert, fileID: untracked.files[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new file.txt").path))
    }

    func testBinaryCanStageAndRevertWithoutFabricatedTextLines() async throws {
        let original = Data([0, 1, 2, 3, 4])
        try original.write(to: root.appendingPathComponent("binary.dat"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "Binary fixture"])
        try Data([0, 1, 8, 9, 10]).write(to: root.appendingPathComponent("binary.dat"))
        let snapshot = try await load(.unstaged)
        XCTAssertTrue(snapshot.files[0].binary)
        XCTAssertEqual(snapshot.files[0].additions, 0)
        XCTAssertEqual(snapshot.files[0].hunks.count, 0)
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .revert)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary.dat")), original)
        try Data([0, 7, 8]).write(to: root.appendingPathComponent("new-binary.dat"))
        let untracked = try await load(.unstaged)
        _ = try await service.mutate(snapshotID: untracked.id, operation: .stage)
        XCTAssertEqual(try gitData(["show", ":new-binary.dat"]), Data([0, 7, 8]))
    }

    func testRenameMetadataAndWholeFileUnstage() async throws {
        _ = try git(["mv", "code.swift", "renamed.swift"])
        let snapshot = try await load(.staged)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertEqual(snapshot.files[0].status, "renamed")
        XCTAssertEqual(snapshot.files[0].previousPath, "code.swift")
        XCTAssertEqual(snapshot.files[0].path, "renamed.swift")
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .unstage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("code.swift").path))
    }

    func testLiteralQuotedUnicodeNewlineAndOptionPathsNeverBecomeCommands() async throws {
        let paths = ["-n.txt", "$(touch SHOULD_NOT_EXIST).txt", "quote\"back\\slash.txt", "tab\tnewline\n🦋.txt"]
        for path in paths { try write(path, "content for \(path)\n") }
        let snapshot = try await load(.unstaged)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), Set(paths))
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .stage)
        let staged = try await load(.staged)
        XCTAssertEqual(Set(staged.files.map(\.path)), Set(paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        for file in staged.files {
            let url = try await service.fileURL(snapshotID: staged.id, fileID: file.id)
            XCTAssertEqual(url.lastPathComponent, file.path)
        }
    }

    func testForgedFileHunkAndOperationRejected() async throws {
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        await assertFailure(.invalidSelection) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage, fileID: "forged")
        }
        await assertFailure(.invalidSelection) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage,
                                              fileID: snapshot.files[0].id, hunkID: "forged")
        }
        await assertFailure(.unsupportedMutation) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .unstage)
        }
        await assertFailure(.unsupportedMutation) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage, hunkID: "forged")
        }
        XCTAssertTrue(try git(["diff", "--cached"]).isEmpty)
    }

    func testCommitAndBranchScopesAreReadOnlyAndResolveReferences() async throws {
        _ = try git(["branch", "fixture-base"])
        try write("code.swift", "committed change\n")
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "Feature change"])
        let commit = try await load(.commit, reference: "HEAD")
        XCTAssertEqual(commit.files.count, 1)
        XCTAssertTrue(commit.files[0].diff.contains("+committed change"))
        XCTAssertFalse(commit.canStage || commit.canUnstage || commit.canRevert)
        let branch = try await load(.branch, reference: "fixture-base")
        XCTAssertEqual(branch.files[0].diff, commit.files[0].diff)
        XCTAssertEqual(branch.reference, "fixture-base")
        await assertFailure(.unsupportedMutation) {
            _ = try await self.service.mutate(snapshotID: branch.id, operation: .revert)
        }
    }

    func testRootCommitWorksWithoutParent() async throws {
        let commit = try await load(.commit, reference: "HEAD")
        XCTAssertEqual(commit.files.count, 1)
        XCTAssertEqual(commit.files[0].status, "added")
    }

    func testReferenceIsLiteralAndCannotRunAnOptionOrShellCommand() async throws {
        do {
            _ = try await load(.commit, reference: "--output=SHOULD_NOT_EXIST")
            XCTFail("Expected invalid reference")
        } catch {}
        do {
            _ = try await load(.branch, reference: "$(touch SHOULD_NOT_EXIST)")
            XCTFail("Expected invalid reference")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testLastTurnReadOnlyDiffWorksOutsideGitAndRejectsTraversal() async throws {
        let patch = "diff --git a/code.swift b/code.swift\n--- a/code.swift\n+++ b/code.swift\n@@ -1 +1 @@\n-old\n+new\n"
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertEqual(snapshot.files[0].additions, 1)
        XCTAssertEqual(snapshot.files[0].deletions, 1)
        XCTAssertFalse(snapshot.canRevert)
        let bad = patch.replacingOccurrences(of: "code.swift", with: "../outside.txt")
        await assertFailure(.invalidSelection) {
            _ = try await self.service.load(workspace: self.root.path, scope: .lastTurn, turnDiff: bad)
        }
        let standalone = root.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        let outsideGit = try await service.load(workspace: standalone.path, scope: .lastTurn, turnDiff: patch)
        XCTAssertEqual(outsideGit.files.count, 1)
    }

    func testLastTurnAddedDeletedQuotedPathsAndMissingNewline() async throws {
        let patch = "diff --git a/added.txt b/added.txt\nnew file mode 100644\n--- /dev/null\n+++ b/added.txt\n@@ -0,0 +1 @@\n+added\n\\ No newline at end of file\n"
            + "diff --git a/\"unused\" b/\"unused\"\n--- \"a/space\\tname.txt\"\n+++ /dev/null\n@@ -1 +0,0 @@\n-deleted\n"
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertEqual(snapshot.files[0].status, "added")
        XCTAssertEqual(snapshot.files[1].status, "deleted")
        XCTAssertEqual(snapshot.files[1].path, "space\tname.txt")
        XCTAssertNil(snapshot.files[1].previousPath, "A deletion must not display the same path as a rename")
    }

    func testLastTurnSupplementsMissingPureRenameWithOnlyRecordedMetadata() async throws {
        let changes = [AgentFileChange(path: root.appendingPathComponent("old.swift").path, kind: "update",
                                       movePath: root.appendingPathComponent("new.swift").path, diff: "")]
        let empty = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "")
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: changes)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertEqual(snapshot.files[0].path, "new.swift")
        XCTAssertEqual(snapshot.files[0].previousPath, "old.swift")
        XCTAssertEqual(snapshot.files[0].status, "renamed")
        XCTAssertEqual(snapshot.files[0].diff, "rename from \"old.swift\"\nrename to \"new.swift\"\n")
        XCTAssertEqual(snapshot.files[0].additions, 0)
        XCTAssertEqual(snapshot.files[0].deletions, 0)
        XCTAssertTrue(snapshot.files[0].hunks.isEmpty)
        XCTAssertFalse(snapshot.canStage || snapshot.canUnstage || snapshot.canRevert)
        XCTAssertNotEqual(snapshot.revision, empty.revision)
        await assertFailure(.unsupportedMutation) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .revert)
        }
    }

    func testLastTurnRecordedRenameDeduplicatesAggregatePathsAndRepeatedReceipts() async throws {
        let patch = "diff --git a/old.swift b/new.swift\nindex abcdef0..abcdef0 100644\n"
        let represented = AgentFileChange(path: "old.swift", kind: "update", movePath: "new.swift", diff: "")
        let additional = AgentFileChange(path: "other.swift", kind: "update", movePath: "moved.swift", diff: "")
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch,
                                             turnChanges: [represented, represented, additional, additional])
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertEqual(snapshot.files.map(\.path), ["new.swift", "moved.swift"])
        XCTAssertTrue(snapshot.files[0].diff.contains("index abcdef0..abcdef0"))
        let aggregateOnly = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
        let duplicateOnly = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch,
                                                  turnChanges: [represented, represented])
        XCTAssertEqual(aggregateOnly.revision, duplicateOnly.revision)
        XCTAssertEqual(Set(snapshot.files.map(\.id)).count, 2)
    }

    func testLastTurnRecordedRenameChainRetainsEachDistinctCompletedOperation() async throws {
        let changes = [
            AgentFileChange(path: "first.swift", kind: "update", movePath: "middle.swift", diff: ""),
            AgentFileChange(path: "middle.swift", kind: "update", movePath: "final.swift", diff: ""),
        ]
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: changes)
        XCTAssertEqual(snapshot.files.map(\.path), ["middle.swift", "final.swift"])
        XCTAssertEqual(snapshot.files.map(\.previousPath), ["first.swift", "middle.swift"])
        XCTAssertEqual(Set(snapshot.files.map(\.id)).count, 2)
        XCTAssertTrue(snapshot.files.allSatisfy { $0.status == "renamed" && $0.hunks.isEmpty && $0.additions == 0 && $0.deletions == 0 })
    }

    func testLastTurnRecordedRenameCycleRetainsMoveBackToOriginalPath() async throws {
        let outward = AgentFileChange(path: "first.swift", kind: "update", movePath: "second.swift", diff: "")
        let home = AgentFileChange(path: "second.swift", kind: "update", movePath: "first.swift", diff: "")
        let one = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [outward])
        let cycle = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [outward, home])
        XCTAssertEqual(cycle.files.map(\.path), ["second.swift", "first.swift"])
        XCTAssertEqual(cycle.files.map(\.previousPath), ["first.swift", "second.swift"])
        XCTAssertNotEqual(cycle.revision, one.revision)
        XCTAssertEqual(Set(cycle.files.map(\.id)).count, 2)
    }

    func testLastTurnRepeatedExactMovesDeduplicateWithoutSuppressingLinkedMoves() async throws {
        let outward = AgentFileChange(path: "first.swift", kind: "update", movePath: "second.swift", diff: "")
        let home = AgentFileChange(path: "second.swift", kind: "update", movePath: "first.swift", diff: "")
        let distinct = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [outward, home])
        let repeated = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [outward, outward, home, outward, home])
        XCTAssertEqual(repeated.files, distinct.files)
        XCTAssertEqual(repeated.revision, distinct.revision)
    }

    func testLastTurnDoesNotReconstructOtherFileChangeContent() async throws {
        let changes = [
            AgentFileChange(path: "added.swift", kind: "add", movePath: "moved.swift", diff: ""),
            AgentFileChange(path: "deleted.swift", kind: "delete", movePath: "moved.swift", diff: ""),
            AgentFileChange(path: "updated.swift", kind: "update", movePath: "moved.swift", diff: "@@ -1 +1 @@\n-old\n+new\n"),
            AgentFileChange(path: "unchanged.swift", kind: "update", movePath: nil, diff: ""),
            AgentFileChange(path: "same.swift", kind: "update", movePath: "same.swift", diff: ""),
        ]
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: changes)
        XCTAssertTrue(snapshot.files.isEmpty)
    }

    func testLastTurnRecordedRenameRejectsOutsideTraversalGitAndSymlinkPaths() async throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path,
                                                   withDestinationPath: "/etc")
        for source in ["../outside.swift", "/etc/hosts", ".git/config", "outside-link/hosts"] {
            let change = AgentFileChange(path: source, kind: "update", movePath: "new.swift", diff: "")
            await assertFailure(.invalidSelection) {
                _ = try await self.service.load(workspace: self.root.path, scope: .lastTurn, turnDiff: "", turnChanges: [change])
            }
            let destination = AgentFileChange(path: "old.swift", kind: "update", movePath: source, diff: "")
            await assertFailure(.invalidSelection) {
                _ = try await self.service.load(workspace: self.root.path, scope: .lastTurn, turnDiff: "", turnChanges: [destination])
            }
        }
    }

    func testLastTurnRecordedRenameQuotesLiteralPathsAndChangesRevision() async throws {
        let change = AgentFileChange(path: "old\tquote\"🦋.swift", kind: "update", movePath: "sub/new\nfile.swift", diff: "")
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [change])
        XCTAssertEqual(snapshot.files[0].previousPath, change.path)
        XCTAssertEqual(snapshot.files[0].path, change.movePath)
        XCTAssertTrue(snapshot.files[0].diff.contains("old\\tquote\\\""))
        XCTAssertTrue(snapshot.files[0].diff.contains("new\\nfile.swift"))
        let changed = AgentFileChange(path: change.path, kind: "update", movePath: "different.swift", diff: "")
        let second = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: "", turnChanges: [changed])
        XCTAssertNotEqual(snapshot.revision, second.revision)
    }

    func testLastTurnColumnZeroHeadersDoNotSplitCodeContainingDiffText() async throws {
        let patch = "diff --git a/code.swift b/code.swift\n--- a/code.swift\n+++ b/code.swift\n@@ -1 +1 @@\n-old\n+let text = \"diff --git a/other b/other\"\n"
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertTrue(snapshot.files[0].diff.contains("let text = \"diff --git"))
        XCTAssertEqual(snapshot.files[0].additions, 1)
    }

    func testLastTurnRenameOnlyAndBinaryHeadersRemainVisible() async throws {
        let patch = "diff --git a/old.swift b/new.swift\nindex abcdef0..abcdef0 100644\n"
            + "diff --git \"a/quoted\\told\" \"b/quoted\\tnew\"\nindex abcdef0..abcdef0 100644\n"
            + "diff --git a/binary.dat b/binary.dat\nindex abcdef0..1234567 100644\nGIT binary patch\nliteral 3\nKcmZQzU|?Vb0000\n"
        let snapshot = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
        XCTAssertEqual(snapshot.files.count, 3)
        XCTAssertEqual(snapshot.files[0].status, "renamed")
        XCTAssertEqual(snapshot.files[0].previousPath, "old.swift")
        XCTAssertEqual(snapshot.files[0].path, "new.swift")
        XCTAssertEqual(snapshot.files[0].additions, 0)
        XCTAssertEqual(snapshot.files[1].path, "quoted\tnew")
        XCTAssertTrue(snapshot.files[2].binary)
    }

    func testLastTurnAmbiguousHeaderIsExplicitError() async throws {
        let patch = "diff --git a/old b/extra b/new\nindex abcdef0..abcdef0 100644\n"
        do {
            _ = try await service.load(workspace: root.path, scope: .lastTurn, turnDiff: patch)
            XCTFail("Ambiguous header should not silently disappear")
        } catch let error as FileReviewError {
            XCTAssertTrue(error.errorDescription?.contains("ambiguous") == true)
        }
    }

    func testRepositoryReplacementInvalidatesRetainedSnapshot() async throws {
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        let moved = root.appendingPathExtension("original")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.copyItem(at: moved, to: root)
        await assertFailure(.staleSnapshot) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .revert)
        }
        XCTAssertEqual(try read("code.swift"), "changed\n")
    }

    func testReviewDisablesRepositoryFilesystemMonitorAndHooks() async throws {
        let hook = root.appendingPathComponent(".git/hooks/review-fsmonitor")
        try Data("#!/bin/sh\ntouch FS_MONITOR_EXECUTED\nprintf 'token\\0'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try git(["config", "core.fsmonitor", hook.path])
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        XCTAssertEqual(snapshot.files.count, 1)
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("FS_MONITOR_EXECUTED").path))
    }

    func testConfiguredCleanFilterIsRejectedBeforeItsHelperCanExecute() async throws {
        let marker = try configureFilter(property: "clean", name: "review-clean", passThrough: true)
        // Reproduce the risk with the same no-ext-diff/no-textconv switches.
        _ = try git(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                     "diff", "--binary", "--no-ext-diff", "--no-textconv", "--", "code.swift"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Git diff still executes a clean filter")
        try FileManager.default.removeItem(at: marker)
        await assertContentFilterRejected { _ = try await self.load(.unstaged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Computa must reject before status or diff runs the helper")
    }

    func testConfiguredProcessFilterIsRejectedBeforeItsHelperCanExecute() async throws {
        let marker = try configureFilter(property: "process", name: "review-process", passThrough: false)
        // A process filter launches before Git's protocol handshake. It need not
        // be a valid protocol peer to demonstrate an executable side effect.
        _ = try? git(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                      "diff", "--binary", "--no-ext-diff", "--no-textconv", "--", "code.swift"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Git diff launches the configured process helper")
        try FileManager.default.removeItem(at: marker)
        await assertContentFilterRejected { _ = try await self.load(.unstaged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testContentFilterAddedAfterSnapshotRejectsMutationWithoutIndexOrFileChanges() async throws {
        try write("code.swift", "changed\n")
        let snapshot = try await load(.unstaged)
        let marker = try configureFilter(property: "clean", name: "new-filter", passThrough: true)
        let index = root.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: index)
        let originalFile = try Data(contentsOf: root.appendingPathComponent("code.swift"))
        await assertContentFilterRejected {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("code.swift")), originalFile)
    }

    func testGlobalCleanFilterIsDetectedUsingPrivateConfigWithoutChangingUserSettings() async throws {
        let name = "global-driver"
        let marker = try configureFilter(property: "clean", name: name, passThrough: true)
        _ = try git(["config", "--unset", "filter.\(name).clean"])
        let configuration = root.appendingPathComponent(".git/private-global-config")
        _ = try git(["config", "--file", configuration.path, "filter.\(name).clean", root.appendingPathComponent(".git/hooks/" + name).path])
        let environment = ["GIT_CONFIG_GLOBAL": configuration.path, "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        _ = try gitData(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                         "diff", "--binary", "--no-ext-diff", "--no-textconv", "--", "code.swift"], environmentOverrides: environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The private global driver reproduces normal Git conversion")
        try FileManager.default.removeItem(at: marker)
        service = WorkspaceReviewService(configurationEnvironment: environment)
        await assertContentFilterRejected { _ = try await self.load(.unstaged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Config-only discovery must not launch the global driver")
    }

    func testSystemProcessFilterIsDetectedUsingPrivateConfigWithoutExecutingHelper() async throws {
        let name = "system-driver"
        let marker = try configureFilter(property: "process", name: name, passThrough: false)
        _ = try git(["config", "--unset", "filter.\(name).process"])
        let configuration = root.appendingPathComponent(".git/private-system-config")
        _ = try git(["config", "--file", configuration.path, "filter.\(name).process", root.appendingPathComponent(".git/hooks/" + name).path])
        let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": configuration.path, "GIT_CONFIG_NOSYSTEM": "0"]
        _ = try? gitData(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                          "diff", "--binary", "--no-ext-diff", "--no-textconv", "--", "code.swift"], environmentOverrides: environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        service = WorkspaceReviewService(configurationEnvironment: environment)
        await assertContentFilterRejected { _ = try await self.load(.unstaged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Config-only discovery must not launch the system driver")
    }

    func testBinaryFileCannotBeOpenedThroughReview() async throws {
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.dat"))
        let snapshot = try await load(.unstaged)
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "binary.dat" })
        XCTAssertTrue(file.binary)
        await assertFailure(.invalidSelection) {
            _ = try await self.service.fileURL(snapshotID: snapshot.id, fileID: file.id)
        }
    }

    func testSymlinkOutsideWorkspaceCannotBeOpenedOrMutated() async throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path,
                                                   withDestinationPath: "/etc/hosts")
        await assertFailure(.invalidSelection) { _ = try await self.load(.unstaged) }
        XCTAssertTrue(try git(["diff", "--cached"]).isEmpty)
    }

    func testTruncatedDiffDisplaysButCannotBeMutated() async throws {
        try write("large.txt", String(repeating: "long line content\n", count: 70_000))
        let snapshot = try await load(.unstaged)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertTrue(snapshot.files[0].truncated)
        XCTAssertLessThanOrEqual(snapshot.files[0].diff.utf8.count, 1_048_576)
        XCTAssertTrue(snapshot.files[0].hunks.isEmpty)
        await assertFailure(.unsupportedMutation) {
            _ = try await self.service.mutate(snapshotID: snapshot.id, operation: .stage)
        }
        XCTAssertTrue(try git(["diff", "--cached"]).isEmpty)
    }

    func testDeletionCanStageThenUnstageAndRevert() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("code.swift"))
        let snapshot = try await load(.unstaged)
        XCTAssertEqual(snapshot.files[0].status, "deleted")
        _ = try await service.mutate(snapshotID: snapshot.id, operation: .stage)
        let staged = try await load(.staged)
        _ = try await service.mutate(snapshotID: staged.id, operation: .unstage)
        let unstaged = try await load(.unstaged)
        _ = try await service.mutate(snapshotID: unstaged.id, operation: .revert)
        XCTAssertEqual(try read("code.swift"), "let number = 1\nlet name = \"original\"\n")
    }

    private func load(_ scope: FileReviewScope, reference: String? = nil) async throws -> FileReviewSnapshot {
        try await service.load(workspace: root.path, scope: scope, reference: reference)
    }

    private func write(_ path: String, _ content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func configureFilter(property: String, name: String, passThrough: Bool) throws -> URL {
        let marker = root.appendingPathComponent(".git/" + name + "-executed")
        let helper = root.appendingPathComponent(".git/hooks/" + name)
        // Fixture paths are owned ASCII UUID directories; single-quote escaping
        // also keeps the script's marker path literal if that base ever changes.
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n: > \(quotedMarker)\n" + (passThrough ? "cat\n" : "exit 0\n")
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try write(".gitattributes", "code.swift filter=\(name)\n")
        _ = try git(["config", "filter.\(name).\(property)", helper.path])
        try write("code.swift", "changed through configured filter\n")
        return marker
    }

    private func assertContentFilterRejected(operation: () async throws -> Void,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected content-filter rejection", file: file, line: line) }
        catch let error as FileReviewError {
            XCTAssertTrue(error.errorDescription?.contains("configured Git clean or process filters") == true,
                          "Unexpected rejection: \(error)", file: file, line: line)
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    @discardableResult private func git(_ args: [String]) throws -> String {
        String(decoding: try gitData(args), as: UTF8.self)
    }

    private func gitData(_ args: [String], environmentOverrides: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, value in value }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
        }
        return data
    }

    private func assertFailure(_ expected: FileReviewError, operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as FileReviewError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

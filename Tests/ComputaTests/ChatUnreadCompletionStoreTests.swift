import Darwin
import Foundation
import XCTest
@testable import Computa

final class ChatUnreadCompletionStoreTests: XCTestCase {
    func testAtomicRoundTripRetainsReadCompletionAndPrivateMetadataOnly() throws {
        let root = try directory()
        let store = ChatUnreadCompletionStore(fileURL: root.appendingPathComponent("state/completions.json"))
        let thread = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        XCTAssertTrue(try store.load().isEmpty)
        try store.save([thread: .init(completionID: turn, hasUnreadCompletion: true)])
        XCTAssertEqual(try store.load()[thread], .init(completionID: turn, hasUnreadCompletion: true))
        try store.save([thread: .init(completionID: turn, hasUnreadCompletion: false)])
        XCTAssertEqual(try ChatUnreadCompletionStore(fileURL: store.fileURL).load()[thread],
                       .init(completionID: turn, hasUnreadCompletion: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "threads"])
        let records = try XCTUnwrap(object["threads"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(records[thread]).keys), ["completionID", "hasUnreadCompletion"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path), ["completions.json"])
    }

    func testCorruptOrUnknownStoreIsNeverReplacedByNewState() throws {
        let root = try directory()
        let store = ChatUnreadCompletionStore(fileURL: root.appendingPathComponent("completions.json"))
        let records = [UUID().uuidString.lowercased(): ChatUnreadCompletionStore.Record(
            completionID: UUID().uuidString.lowercased(), hasUnreadCompletion: true)]
        for body in ["not JSON", "{\"schemaVersion\":2,\"threads\":{}}",
                     "{\"schemaVersion\":1,\"threads\":{\"foreign\":{\"completionID\":\"invalid\",\"hasUnreadCompletion\":true}}}"] {
            let bytes = Data(body.utf8)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(records))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
    }

    func testSymlinkInvalidIdentityAndOversizeCannotReplaceStore() throws {
        let root = try directory()
        let target = root.appendingPathComponent("target.json")
        let original = Data("retained".utf8); try original.write(to: target)
        let file = root.appendingPathComponent("completions.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = ChatUnreadCompletionStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([:]))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.save(["not-a-thread": .init(completionID: UUID().uuidString.lowercased(), hasUnreadCompletion: true)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data(repeating: 0, count: ChatUnreadCompletionStore.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([:]))
        XCTAssertEqual(try Data(contentsOf: file).count, ChatUnreadCompletionStore.maximumBytes + 1)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnreadStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}

import Foundation
import OSLog

/// A display-only record of the handoff from a new Mac agent tab to its runtime transcript.
/// It contains user submissions and local delivery errors, never executable turn state.
struct FirstMessageStore: Sendable {
    let directory: URL
    static let log = Logger(subsystem: "com.ahmedelamin.LocalCodex", category: "FirstMessageStore")

    struct Record: Codable {
        let localID: UUID
        var threadID: String?
        var metadata: SavedWorkspace.Draft
        var entries: [TimelineEntry]

        var id: String { threadID ?? localID.uuidString }
        var restoredTask: AgentTask {
            var task = metadata.task(id: id)
            task.runtimeThreadID = threadID
            task.entries = entries
            task.updatedAt = entries.last?.timestamp ?? task.updatedAt
            task.summary = entries.last(where: { $0.kind == .user })?.body ?? task.summary
            task.status = entries.last?.kind == .user ? .waiting : .failed
            if let last = entries.last, last.kind == .user {
                task.entries.append(.init(id: "unconfirmed-" + last.id, kind: .system,
                    title: "Prompt delivery unconfirmed", body: "Kolmogor closed before delivery was confirmed.",
                    timestamp: last.timestamp, activityGroupID: last.id))
            }
            return task
        }

        /// The first persisted user item in the owning thread confirms the handoff.
        /// Earlier local delivery failures remain visible, including retries with identical text.
        func entriesMissing(from history: AgentTask) -> [TimelineEntry] {
            let local = restoredTask.entries
            guard let first = history.entries.first(where: { $0.kind == .user }),
                  let index = local.lastIndex(where: { $0.kind == .user }), local[index].body == first.body else { return local }
            return Array(local.prefix(upTo: index))
        }
    }

    func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: url(record.localID), options: .atomic)
    }

    func load() throws -> [Record] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                guard record.localID == id, record.threadID.map({ UUID(uuidString: $0) != nil }) != false,
                      record.entries.first?.kind == .user,
                      record.entries.allSatisfy({ $0.kind == .user || $0.kind == .system }) else { throw CocoaError(.coderReadCorrupt) }
                return record
            } catch {
                Self.log.error("A first-message record could not be read.")
                return nil
            }
        }
    }

    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

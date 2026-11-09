import CryptoKit
import Darwin
import Foundation

/// Shared same-UID diagnostic file discipline. The caller alone validates an
/// explicit arm and creates its record; this helper grants no inference authority.
/// It never creates directories or replaces an existing output.
enum WebsitePrivateDiagnosticCapture {
    enum Record: String, Sendable {
        case request = "request.json"
        case rejectedReply = "rejected-reply.json"
        case claudeResponseMetadata = "response-metadata.json"
        case adapterFailureStructure = "adapter-failure-structure.json"
        case groqOwnedStatus = "owned-status.json"
        case qwenMarkerWire = "marker-wire.json"

        var maximumBytes: Int {
            if self == .qwenMarkerWire || self == .groqOwnedStatus { return 4_096 }
            return self == .claudeResponseMetadata || self == .adapterFailureStructure ? 96 * 1_024 : 2_000_000
        }
    }

    /// Holds the exact private directory opened during the single arm claim.
    /// The descriptor/lock live through publication; no replacement directory
    /// can inherit a claim. The caller must still enforce its native lease.
    final class Claim: @unchecked Sendable {
        fileprivate let directory: URL
        fileprivate let directoryFD: Int32
        fileprivate let directoryInfo: stat
        fileprivate let record: Record
        private let lock = NSLock()
        private var attempted = false

        fileprivate init(directory: URL, directoryFD: Int32, directoryInfo: stat, record: Record) {
            self.directory = directory; self.directoryFD = directoryFD
            self.directoryInfo = directoryInfo; self.record = record
        }
        deinit { close(directoryFD) }
        fileprivate func beginPublication() -> Bool {
            lock.withLock { guard !attempted else { return false }; attempted = true; return true }
        }
    }

    // Compatibility wrapper: record construction still precedes the arm claim,
    // and a raced replacement is restored rather than granting old authority.
    static func publish(directory: URL, outputName: String, maximumArmBytes: Int,
                        maximumRecordBytes: Int, makeRecord: (Data) -> Data?,
                        isCurrent: () -> Bool = { true },
                        beforeArmClaim: (@Sendable () -> Void)? = nil) -> Bool {
        guard let kind = Record(rawValue: outputName), kind == .request || kind == .rejectedReply,
              maximumRecordBytes > 0, maximumRecordBytes <= kind.maximumBytes else { return false }
        var record: Data?
        guard let claimed = claim(directory: directory, record: kind, maximumArmBytes: maximumArmBytes,
            validate: { arm in
                guard let value = makeRecord(arm), !value.isEmpty, value.count <= maximumRecordBytes else { return false }
                record = value; return true
            }, isCurrent: isCurrent, beforeArmClaim: beforeArmClaim), let record else { return false }
        return publish(record, using: claimed, isCurrent: isCurrent, commit: { rename in
            guard isCurrent() else { return false }; return rename()
        })
    }

    /// Validate and consume once. No output is written and no directories are
    /// created. Filesystem/expiry checks are deliberately separate from a lease.
    static func claim(directory: URL, record: Record, maximumArmBytes: Int,
                      validate: (Data) -> Bool, isCurrent: () -> Bool,
                      beforeArmClaim: (@Sendable () -> Void)? = nil) -> Claim? {
        // Legacy validators establish their monotonic deadline while creating
        // the record. Their first eligibility check must remain after validate.
        guard (1...4096).contains(maximumArmBytes) else { return nil }
        let directoryFD = openDirectoryWithoutSymlinks(directory)
        guard directoryFD >= 0 else { return nil }
        var retained = false
        defer { if !retained { close(directoryFD) } }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, privateDirectory(directoryInfo),
              flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { return nil }
        let armFD = openat(directoryFD, "arm.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard armFD >= 0 else { return nil }
        defer { close(armFD) }
        var before = stat()
        guard fstat(armFD, &before) == 0, privateFile(before), before.st_size > 0,
              before.st_size <= maximumArmBytes, let arm = readArm(armFD, maximum: maximumArmBytes),
              arm.count == before.st_size, validate(arm), isCurrent() else { return nil }
        var after = stat(), named = stat(), output = stat()
        guard fstat(armFD, &after) == 0, sameUnchangedFile(before, after),
              fstatat(directoryFD, "arm.json", &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(before, named),
              fstatat(directoryFD, record.rawValue, &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return nil }
        let claimed = ".claimed-arm-" + UUID().uuidString.lowercased()
        beforeArmClaim?()
        guard renameatx_np(directoryFD, "arm.json", directoryFD, claimed, UInt32(RENAME_EXCL)) == 0 else { return nil }
        var claimedInfo = stat()
        // Preserve a raced replacement exclusively, or leave its private claimed
        // file recoverable if another new arm already occupies the original name.
        guard fstatat(directoryFD, claimed, &claimedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              privateFile(claimedInfo), before.st_dev == claimedInfo.st_dev, before.st_ino == claimedInfo.st_ino,
              before.st_size == claimedInfo.st_size,
              before.st_mtimespec.tv_sec == claimedInfo.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == claimedInfo.st_mtimespec.tv_nsec,
              lseek(armFD, 0, SEEK_SET) == 0, readArm(armFD, maximum: maximumArmBytes) == arm,
              fstat(armFD, &after) == 0, sameUnchangedFile(claimedInfo, after),
              fstatat(directoryFD, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0, sameUnchangedFile(after, named) else {
            _ = renameatx_np(directoryFD, claimed, directoryFD, "arm.json", UInt32(RENAME_EXCL))
            return nil
        }
        let authorizedClaim = after
        defer {
            var remaining = stat()
            if fstatat(directoryFD, claimed, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(authorizedClaim, remaining) { _ = unlinkat(directoryFD, claimed, 0) }
        }
        guard isCurrent(), directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return nil }
        // Consumption is irreversible even if a later snapshot is unavailable.
        guard unlinkat(directoryFD, claimed, 0) == 0 else { return nil }
        guard fsync(directoryFD) == 0 else { return nil }
        guard isCurrent() else { return nil }
        retained = true
        return Claim(directory: directory, directoryFD: directoryFD, directoryInfo: directoryInfo, record: record)
    }

    /// All preparation and fsync happen before/after commit. The caller uses
    /// commit to serialize only the final eligibility check and exclusive rename
    /// with lease revocation; slow writes cannot hold the caller's lease lock.
    static func publish(_ record: Data, using claim: Claim, isCurrent: () -> Bool,
                        beforeRecordWrite: (() -> Void)? = nil,
                        beforeCommit: (() -> Void)? = nil,
                        commit: (_ rename: @escaping @Sendable () -> Bool) -> Bool) -> Bool {
        guard !record.isEmpty, record.count <= claim.record.maximumBytes,
              claim.beginPublication(), isCurrent() else { return false }
        let directoryFD = claim.directoryFD, directory = claim.directory, directoryInfo = claim.directoryInfo
        guard directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo) else { return false }
        let temporary = ".diagnostic-record-" + UUID().uuidString.lowercased() + ".tmp"
        let outputFD = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { return false }
        defer {
            var held = stat(), remaining = stat()
            if fstat(outputFD, &held) == 0,
               fstatat(directoryFD, temporary, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
               sameUnchangedFile(held, remaining) { _ = unlinkat(directoryFD, temporary, 0) }
            close(outputFD)
        }
        beforeRecordWrite?()
        guard fchmod(outputFD, 0o600) == 0, writeAll(record, descriptor: outputFD), fsync(outputFD) == 0,
              isCurrent() else { return false }
        beforeCommit?()
        guard directoryStillMatches(directory, descriptor: directoryFD, initial: directoryInfo), isCurrent() else { return false }
        var written = stat(), temporaryInfo = stat()
        guard fstat(outputFD, &written) == 0, privateFile(written), written.st_size == record.count,
              fstatat(directoryFD, temporary, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              sameUnchangedFile(written, temporaryInfo),
              commit({ [claim] in renameatx_np(claim.directoryFD, temporary, claim.directoryFD, claim.record.rawValue, UInt32(RENAME_EXCL)) == 0 })
        else { return false }
        _ = fsync(directoryFD)
        return true
    }

    private static func openDirectoryWithoutSymlinks(_ url: URL) -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { return -1 }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func directoryStillMatches(_ directory: URL, descriptor: Int32, initial: stat) -> Bool {
        let currentFD = openDirectoryWithoutSymlinks(directory)
        guard currentFD >= 0 else { return false }
        defer { close(currentFD) }
        var current = stat(), held = stat()
        return fstat(currentFD, &current) == 0 && fstat(descriptor, &held) == 0
            && privateDirectory(current) && privateDirectory(held)
            && current.st_dev == initial.st_dev && current.st_ino == initial.st_ino
            && held.st_dev == initial.st_dev && held.st_ino == initial.st_ino
    }

    private static func privateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }

    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1
            && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o600
    }

    private static func sameUnchangedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        privateFile(rhs) && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readArm(_ descriptor: Int32, maximum: Int) -> Data? {
        var bytes = Data(count: maximum + 1)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            var count = 0
            while count < buffer.count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return nil }
                if result == 0 { return count }
                count += result
            }
            return count
        }
        guard let count, count <= maximum else { return nil }
        bytes.count = count
        return bytes
    }

    private static func writeAll(_ bytes: Data, descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if result < 0 { if errno == EINTR { continue }; return false }
                guard result > 0 else { return false }
                count += result
            }
            return true
        }
    }
}

/// Optional content-free outcome for an opted-in synthetic marker or controlled
/// fixture child. Native identity, selection and submission must survive publication.
final class GroqOwnedStatusLease: @unchecked Sendable {
    @TaskLocal static var current: GroqOwnedStatusLease?
    static let directoryName = "GroqOwnedStatus-v1"
    enum Profile: String, CaseIterable {
        case gptoss20b, qwen27b, gptoss120b
        var choice: WebsiteModelChoice {
            switch self {
            case .gptoss20b: return .init(provider: "groq", key: "openai/gpt-oss-20b", label: "GPT OSS 20B")
            case .qwen27b: return .init(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B")
            case .gptoss120b: return .init(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B")
            }
        }
        var purpose: String {
            switch self {
            case .gptoss20b: return "groq_20b_synthetic_status_v1"
            case .qwen27b: return "groq_qwen27b_synthetic_status_v1"
            case .gptoss120b: return "groq_120b_synthetic_status_v1"
            }
        }
    }
    // Preserve the original 20B arm contract for existing callers.
    static let purpose = Profile.gptoss20b.purpose
    static let choice = Profile.gptoss20b.choice
    let profile: Profile
    var modelChoice: WebsiteModelChoice { profile.choice }
    static func userText(_ nonce: UUID) -> String {
        "Return exactly GROQSTATUS" + nonce.uuidString.replacingOccurrences(of:"-",with:"") + " and nothing else. Do not call any tools."
    }
    static let stages: Set<String> = ["no_matching_fetch_observed", "matched_fetch_unsettled", "http_2xx_opened", "http_400", "http_401", "http_403", "http_413", "http_429", "http_other_non_2xx", "transport_rejected", "ambiguous"]
    private let file: WebsitePrivateDiagnosticCapture.Claim
    let admission: WebModelStartAdmission
    let deadline: ContinuousClock.Instant
    private let promptHash: String
    private let fixtureTurn: FixtureTurn?
    private let lock = NSLock()
    private var active = true
    private var observerArmed = false
    var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } && (fixtureTurn?.isCurrent ?? true) }
    func revoke() { lock.withLock { active = false } }
    var isFixture: Bool { fixtureTurn != nil }
    func recordObserverArmed() { lock.withLock { observerArmed = true } }
    var unavailableStage: String? {
        guard isFixture,isCurrent else { return nil }
        return lock.withLock { observerArmed ? "observer_unavailable" : "observer_not_armed" }
    }
    static func digest(_ input: String) -> String { SHA256.hash(data:Data(input.utf8)).map { String(format:"%02x",$0) }.joined() }
    func matches(_ prompt: String) -> Bool { isCurrent && Self.digest(prompt) == promptHash }
    private init(_ file: WebsitePrivateDiagnosticCapture.Claim, _ admission: WebModelStartAdmission, _ deadline: ContinuousClock.Instant, _ prompt: String, profile: Profile, fixtureTurn: FixtureTurn? = nil) {
        self.file=file; self.admission=admission; self.deadline=deadline; promptHash=Self.digest(prompt); self.profile=profile
        self.fixtureTurn=fixtureTurn
    }
    static func consume(directory: URL?, admission: WebModelStartAdmission, request: WebModelResponseCodec.Request,
                        first: Bool, now: Date = Date()) -> GroqOwnedStatusLease? {
        guard first, !Task.isCancelled, let directory, admission.provider == "groq",
              let profile = Profile.allCases.first(where: { $0.choice.modelID == admission.modelID }),
              request.model == admission.modelID, [admission.taskID,admission.threadID,admission.turnID].allSatisfy({ UUID(uuidString:$0)?.uuidString.lowercased()==$0 }) else { return nil }
        let started=ContinuousClock.now
        var deadline: ContinuousClock.Instant?
        guard let file=WebsitePrivateDiagnosticCapture.claim(directory:directory,record:.groqOwnedStatus,maximumArmBytes:4096,validate:{ data in
            guard APIModelCorrectionJSON.isUnambiguous(data), let v=try? JSONSerialization.jsonObject(with:data) as? [String:String],
                  Set(v.keys)==["purpose","nonce","modelID","userPromptSHA256","expiresAt"], v["purpose"]==profile.purpose,v["modelID"]==profile.choice.modelID,
                  let raw=v["nonce"], let id=UUID(uuidString:raw),id.uuidString.lowercased()==raw,
                  let exp=v["expiresAt"],exp.utf8.count==24 else { return false }
            let fmt=ISO8601DateFormatter();fmt.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let user=userText(id)
            guard let end=fmt.date(from:exp),fmt.string(from:end)==exp,(0...600).contains(end.timeIntervalSince(now)),end>now,
                  v["userPromptSHA256"]==digest(user), WebsiteSyntheticFirstRequest.matches(request,expectedUserText:user) else {return false}
            deadline=started + .seconds(end.timeIntervalSince(now));return true
        },isCurrent:{ !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? false) }),let deadline else{return nil}
        return .init(file,admission,deadline,request.prompt,profile:profile)
    }

    /// A separate opt-in for one controlled local fixture turn. Each child still
    /// observes only one fresh owned page's exact outbound prompt and one fetch.
    /// The claim is shared across children, so only the first failure can publish.
    final class FixtureTurn: @unchecked Sendable {
        static let purpose = "groq_qwen27b_fixture_failure_status_v1"
        private let file: WebsitePrivateDiagnosticCapture.Claim
        private let first: WebModelStartAdmission
        private let userHash: String
        private let deadline: ContinuousClock.Instant
        private let lock = NSLock()
        private var active = true
        private var children = Set<UUID>()
        var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } }
        func revoke() { lock.withLock { active = false } }

        private init(file: WebsitePrivateDiagnosticCapture.Claim, first: WebModelStartAdmission, deadline: ContinuousClock.Instant, user: String) {
            self.file=file; self.first=first; self.deadline=deadline; userHash=GroqOwnedStatusLease.digest(user)
        }

        static func consume(directory: URL?, admission: WebModelStartAdmission, request: WebModelResponseCodec.Request,
                            first: Bool, now: Date = Date()) -> FixtureTurn? {
            guard first, !Task.isCancelled, let directory, admission.provider == "groq",
                  admission.modelID == Profile.qwen27b.choice.modelID, request.model == admission.modelID,
                  [admission.taskID, admission.threadID, admission.turnID].allSatisfy({ UUID(uuidString:$0)?.uuidString.lowercased()==$0 }),
                  let user = controlledUserText(request,allowingContinuation:false) else { return nil }
            let started=ContinuousClock.now
            var deadline: ContinuousClock.Instant?
            guard let file=WebsitePrivateDiagnosticCapture.claim(directory:directory,record:.groqOwnedStatus,maximumArmBytes:4096,validate:{ data in
                guard APIModelCorrectionJSON.isUnambiguous(data),
                      let v=try? JSONSerialization.jsonObject(with:data) as? [String:String],
                      Set(v.keys)==["purpose","nonce","modelID","userPromptSHA256","expiresAt"],
                      v["purpose"]==purpose, v["modelID"]==admission.modelID,
                      let nonce=v["nonce"], UUID(uuidString:nonce)?.uuidString.lowercased()==nonce,
                      v["userPromptSHA256"]==GroqOwnedStatusLease.digest(user), let expiry=v["expiresAt"], expiry.utf8.count==24 else { return false }
                let fmt=ISO8601DateFormatter(); fmt.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
                guard let end=fmt.date(from:expiry),fmt.string(from:end)==expiry,
                      end>now,end.timeIntervalSince(now)<=600 else { return false }
                deadline=started + .seconds(end.timeIntervalSince(now)); return true
            },isCurrent:{ !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? false) }),let deadline else { return nil }
            return .init(file:file,first:admission,deadline:deadline,user:user)
        }

        func child(admission: WebModelStartAdmission, request: WebModelResponseCodec.Request) -> GroqOwnedStatusLease? {
            lock.withLock {
                guard !Task.isCancelled, active, ContinuousClock.now < deadline,
                      admission.taskID==first.taskID, admission.threadID==first.threadID, admission.turnID==first.turnID,
                      admission.runtimeGeneration==first.runtimeGeneration, admission.preparationID==first.preparationID,
                      admission.transportGeneration==first.transportGeneration, admission.provider==first.provider,
                      admission.modelID==first.modelID, request.model==first.modelID,
                      let user=Self.controlledUserText(request,allowingContinuation:true),GroqOwnedStatusLease.digest(user)==userHash,
                      children.count < WebModelServer.maximumTurnInferences,
                      children.insert(admission.inferenceID).inserted else { return nil }
                return .init(file,admission,deadline,request.prompt,profile:.qwen27b,fixtureTurn:self)
            }
        }

        fileprivate func commit(_ rename: () -> Bool) -> Bool {
            lock.withLock {
                guard !Task.isCancelled,active,ContinuousClock.now < deadline else { return false }
                active=false
                return rename()
            }
        }

        private static func controlledUserText(_ request: WebModelResponseCodec.Request, allowingContinuation: Bool) -> String? {
            guard APIModelCorrectionJSON.isUnambiguous(request.continuationRequest),
                  var root=try? JSONSerialization.jsonObject(with:request.continuationRequest) as? [String:Any],
                  let input=root["input"] as? [[String:Any]],let environment=input.firstIndex(where: { $0["role"] as? String == "user" }),
                  input.indices.contains(environment+1) else { return nil }
            let userIndex=environment+1
            guard (allowingContinuation || userIndex==input.count-1),
                  input.dropFirst(userIndex+1).allSatisfy({ item in
                      ["function_call","function_call_output","custom_tool_call","custom_tool_call_output"].contains(item["type"] as? String ?? "")
                          || item["type"] as? String == "message" && item["role"] as? String == "assistant"
                  }),let parts=input[userIndex]["content"] as? [[String:Any]],let text=parts.first?["text"] as? String else { return nil }
            let suffix="\n"+ComputaAgentInstructions.runtimeInteractionPolicy()
            let user=parts.count==1 && text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
            // Groq clears and closes each physical inference. It does not use the
            // retained-page continuation proof, so recheck the controlled initial
            // user prefix before deriving every diagnostic-only child.
            root["input"]=Array(input.prefix(userIndex+1))
            guard matchesPrompt(user),let prefix=try? JSONSerialization.data(withJSONObject:root),
                  WebsiteSyntheticFirstRequest.matches(prefix,model:request.model,expectedUserText:user) else { return nil }
            return user
        }

        static func matchesPrompt(_ user: String) -> Bool {
            let prefix="In "
            let middle=", fix the invoice aggregation bug in reconcile.py according to its README. Keep the tests, sample data, and reference format unchanged. Run python3 -m unittest -v, then run python3 reconcile.py.\n\nUse the built-in browser to open http://127.0.0.1:"
            let suffix="/, enter the printed reference, and submit it once. Read the resulting receipt, then close the tab you opened. Use browser tools for the website; do not use terminal HTTP requests or inspect the fixture's control directory, server source, or receipt files.\n\nReturn the test result, the reference, and the receipt shown by the page."
            guard user.utf8.count<=8_192,user.hasPrefix(prefix),user.hasSuffix(suffix) else { return false }
            let pieces=String(user.dropFirst(prefix.count).dropLast(suffix.count)).components(separatedBy:middle)
            guard pieces.count==2, let port=UInt16(pieces[1]),port>=1_024,String(port)==pieces[1] else { return false }
            let path=pieces[0]
            guard path.utf8.count<=4_096,path.hasPrefix("/"),!path.contains("\n"),!path.contains("\r"),!path.contains("\0"),
                  URL(fileURLWithPath:path).standardizedFileURL.path==path,
                  path.range(of:#"/fixtures/cases/invoice-[1-9][0-9]{2,5}-groq-qwen27b-[a-f0-9]{16}/coding$"#,options:.regularExpression) != nil else { return false }
            return true
        }
    }
    struct Observation: Sendable {
        let stage: String
        let sessionToken: String
        let generation: UUID
    }
    // Called synchronously on the server after it has rejoined this exact current inference.
    func publish(_ observation: Observation, trigger: String) {
        let stage=observation.stage, owner=observation.sessionToken, generation=observation.generation
        guard !Task.isCancelled, isCurrent,
              Self.stages.contains(stage) || isFixture && ["observer_not_armed","observer_unavailable"].contains(stage),
              ["response_deadline","groq_draft_restored","groq_reported_submission_error"].contains(trigger),
              let session=UUID(uuidString:owner) else{return}
        let v:[String:Any]=["schemaVersion":1,"purpose":fixtureTurn == nil ? profile.purpose : FixtureTurn.purpose,"provider":"groq","modelID":admission.modelID,
            "taskID":admission.taskID,"threadID":admission.threadID,"turnID":admission.turnID,
            "inferenceID":admission.inferenceID.uuidString.lowercased(),"preparationID":admission.preparationID.uuidString.lowercased(),
            "runtimeGeneration":admission.runtimeGeneration.uuidString.lowercased(),"session":session.uuidString.lowercased(),
            "documentGeneration":generation.uuidString.lowercased(),"trigger":trigger,"stage":stage,
            "evidenceClass":["observer_not_armed","observer_unavailable"].contains(stage) ? "native_observer_availability" : "page_world_observation"]
        guard let bytes=try? JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]) else{return}
        _=WebsitePrivateDiagnosticCapture.publish(bytes,using:file,isCurrent:{ !Task.isCancelled && self.isCurrent },commit:{ rename in
            self.lock.withLock {
                guard !Task.isCancelled,self.active,ContinuousClock.now < self.deadline else { return false }
                return self.fixtureTurn.map { $0.commit(rename) } ?? rename()
            }
        })
    }
}

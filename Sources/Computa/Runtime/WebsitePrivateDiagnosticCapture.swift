import CoreFoundation
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
    enum InstallationMode: String, Sendable { case late, earlyPassive }
    enum SetupReason: String, CaseIterable, Sendable {
        case notAttempted = "not_attempted"
        case transportPreconditionsSkipped = "transport_preconditions_skipped"
        case nativePrepareGuardSkipped = "native_prepare_guard_skipped"
        case nativeProbeAbsent = "native_probe_absent"
        case nativeInitialStartMissing = "native_initial_start_missing"
        case nativeOwnerAlreadySet = "native_owner_already_set"
        case nativeSignalOwnerMismatch = "native_signal_owner_mismatch"
        case nativeSignalOriginMismatch = "native_signal_origin_mismatch"
        case controllerAbsent = "controller_absent"
        case armFalse = "arm_false"
        case armException = "arm_exception"
        case armTimeout = "arm_timeout"
        case postAwaitContextRetired = "post_await_context_retired"
        case jsFetchDescriptor = "js_fetch_descriptor"
        case jsResponseGetters = "js_response_getters"
        case jsProfileUnavailable = "js_profile_unavailable"
        case jsFetchReplaced = "js_fetch_replaced"
        case jsPickerUnavailable = "js_picker_unavailable"
        case jsPickerNotClosed = "js_picker_not_closed"
        case jsPickerLabelMismatch = "js_picker_label_mismatch"
        case jsRouteUnavailable = "js_route_unavailable"
        case jsModelMismatch = "js_model_mismatch"
        case jsPromptUnavailable = "js_prompt_unavailable"
        case jsArmStateUnavailable = "js_arm_state_unavailable"
        case armed

        // Page-world strings cannot claim a native timeout, exception or guard.
        static func javaScriptArmReason(_ value: String) -> Self? {
            guard let reason = Self(rawValue: value) else { return nil }
            switch reason {
            case .controllerAbsent, .armFalse, .jsFetchDescriptor, .jsResponseGetters,
                 .jsProfileUnavailable, .jsFetchReplaced, .jsPickerUnavailable,
                 .jsPickerNotClosed, .jsPickerLabelMismatch, .jsRouteUnavailable,
                 .jsModelMismatch, .jsPromptUnavailable, .jsArmStateUnavailable:
                return reason
            default: return nil
            }
        }
    }
    private let file: WebsitePrivateDiagnosticCapture.Claim
    let admission: WebModelStartAdmission
    let deadline: ContinuousClock.Instant
    private let promptHash: String
    private let fixtureTurn: FixtureTurn?
    private let lock = NSLock()
    private var active = true
    private var observerArmed = false
    private var inspectorBound = false
    private var inspectorActivated = false
    private var inspectorRevoked = false
    private var inspectorRevocation: (@Sendable () -> Void)?
    private var earlyObserverRevocation: (@Sendable () -> Void)?
    let installationMode: InstallationMode
    let inspectorOrdinal: Int?
    private var setupReason: SetupReason = .notAttempted
    var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } && (fixtureTurn?.isCurrent ?? true) }
    func revoke() {
        let callbacks = lock.withLock {
            active = false; inspectorRevoked = true
            let callbacks = (inspectorRevocation, earlyObserverRevocation)
            inspectorRevocation = nil; earlyObserverRevocation = nil
            return callbacks
        }
        callbacks.0?(); callbacks.1?()
    }

    // Lifecycle notification only; this registers no observation or authority.
    func onEarlyObserverRevocation(_ callback: @escaping @Sendable () -> Void) -> Bool {
        let registered = lock.withLock {
            guard installationMode == .earlyPassive, active, ContinuousClock.now < deadline,
                  earlyObserverRevocation == nil else { return false }
            earlyObserverRevocation = callback
            return true
        }
        guard registered else { return false }
        guard fixtureTurn?.isCurrent == true else { revoke(); return false }
        return true
    }

    /// Native-only public-WebKit inspection grant for an explicitly manual
    /// fixture purpose. This carries no request, response, replay or cleanup proof.
    final class InspectorBinding: @unchecked Sendable {
        private let lease: GroqOwnedStatusLease
        private let view: ObjectIdentifier, ownerToken: String, generation: UUID
        let deadline: ContinuousClock.Instant
        fileprivate init(_ lease: GroqOwnedStatusLease, view: ObjectIdentifier, ownerToken: String, generation: UUID) {
            self.lease = lease; self.view = view; self.ownerToken = ownerToken; self.generation = generation
            deadline = lease.deadline
        }
        func activate(view: ObjectIdentifier, ownerToken: String, generation: UUID,
                      onRevocation: @escaping @Sendable () -> Void, action: () -> Void) -> Bool {
            lease.lock.withLock {
                guard !Task.isCancelled, lease.active, !lease.inspectorRevoked, !lease.inspectorActivated,
                      ContinuousClock.now < deadline, lease.fixtureTurn?.isCurrent == true,
                      self.view == view, self.ownerToken == ownerToken, self.generation == generation else { return false }
                lease.inspectorActivated = true; lease.inspectorRevocation = onRevocation
                action()
                return true
            }
        }
        func revoke() { lease.revokeInspector() }
    }

    func bindInspector(view: ObjectIdentifier, ownerToken: String, generation: UUID) -> InspectorBinding? {
        lock.withLock {
            guard !Task.isCancelled, active, !inspectorBound, !inspectorRevoked, ContinuousClock.now < deadline,
                  let ordinal = inspectorOrdinal, (2...4).contains(ordinal), profile == .gptoss120b,
                  fixtureTurn?.isCurrent == true, UUID(uuidString: ownerToken) != nil else { return nil }
            inspectorBound = true
            return InspectorBinding(self, view: view, ownerToken: ownerToken, generation: generation)
        }
    }

    private func revokeInspector() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            inspectorRevoked = true
            let callback = inspectorRevocation; inspectorRevocation = nil
            return callback
        }
        callback?()
    }
    var isFixture: Bool { fixtureTurn != nil }
    var capturesFailureProgress: Bool {
        isCurrent && profile == .gptoss120b && installationMode == .earlyPassive
            && fixtureTurn?.publicationPurpose == FixtureTurn.earlyPassivePurpose
    }
    func recordSetupReason(_ reason: SetupReason) {
        guard isFixture, reason != .armed else { return }
        lock.withLock {
            guard active, !observerArmed, ContinuousClock.now < deadline else { return }
            setupReason = reason
        }
    }
    func recordObserverArmed() { lock.withLock { observerArmed = true; setupReason = .armed } }
    var unavailableStage: String? {
        guard isFixture,isCurrent else { return nil }
        return lock.withLock { observerArmed ? "observer_unavailable" : "observer_not_armed" }
    }
    static func digest(_ input: String) -> String { SHA256.hash(data:Data(input.utf8)).map { String(format:"%02x",$0) }.joined() }
    func matches(_ prompt: String) -> Bool { isCurrent && Self.digest(prompt) == promptHash }
    private init(_ file: WebsitePrivateDiagnosticCapture.Claim, _ admission: WebModelStartAdmission, _ deadline: ContinuousClock.Instant, _ prompt: String, profile: Profile, fixtureTurn: FixtureTurn? = nil, inspectorOrdinal: Int? = nil, installationMode: InstallationMode = .late) {
        self.file=file; self.admission=admission; self.deadline=deadline; promptHash=Self.digest(prompt); self.profile=profile
        self.fixtureTurn=fixtureTurn; self.inspectorOrdinal=inspectorOrdinal; self.installationMode=installationMode
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
        enum Kind: CaseIterable, Equatable {
            case qwen27b, gptoss120b
            static func supportsModel(_ modelID: String) -> Bool {
                allCases.contains { $0.profile.choice.modelID == modelID }
            }
            var profile: GroqOwnedStatusLease.Profile {
                switch self { case .qwen27b: return .qwen27b; case .gptoss120b: return .gptoss120b }
            }
            var purpose: String {
                switch self {
                case .qwen27b: return "groq_qwen27b_fixture_failure_status_v1"
                case .gptoss120b: return "groq_120b_fixture_failure_status_v1"
                }
            }
            var casePathToken: String {
                switch self { case .qwen27b: return "groq-qwen27b"; case .gptoss120b: return "groq-gptoss120b" }
            }
        }
        // Preserve the original Qwen fixture arm for existing callers.
        static let purpose = Kind.qwen27b.purpose
        static let inspectorPurpose = "groq_120b_fixture_inferences_2_to_4_network_inspector_v1"
        static let earlyPassivePurpose = "groq_120b_fixture_early_passive_status_v1"
        private enum Mode { case status, manualInspector, earlyPassive }
        private struct WeakChild { weak var lease: GroqOwnedStatusLease? }
        private let kind: Kind
        private let mode: Mode
        var publicationPurpose: String {
            switch mode {
            case .status: return kind.purpose
            case .manualInspector: return Self.inspectorPurpose
            case .earlyPassive: return Self.earlyPassivePurpose
            }
        }
        private let file: WebsitePrivateDiagnosticCapture.Claim
        private let first: WebModelStartAdmission
        private let userHash: String
        private let deadline: ContinuousClock.Instant
        private let lock = NSLock()
        private var active = true
        private var children = Set<UUID>()
        private var lastScopedInferenceID: UUID?
        private var dependentChildren: [WeakChild] = []
        var isCurrent: Bool { lock.withLock { active && ContinuousClock.now < deadline } }
        func revoke() {
            let leases = lock.withLock {
                active = false
                let leases = dependentChildren.compactMap(\.lease); dependentChildren.removeAll()
                return leases
            }
            leases.forEach { $0.revoke() }
        }

        private init(file: WebsitePrivateDiagnosticCapture.Claim, first: WebModelStartAdmission, deadline: ContinuousClock.Instant, user: String, kind: Kind, mode: Mode) {
            self.file=file; self.first=first; self.deadline=deadline; userHash=GroqOwnedStatusLease.digest(user); self.kind=kind; self.mode=mode
        }

        static func consume(directory: URL?, admission: WebModelStartAdmission, request: WebModelResponseCodec.Request,
                            first: Bool, allowManualInspector: Bool = false, allowEarlyPassive: Bool = false, now: Date = Date()) -> FixtureTurn? {
            guard first, !Task.isCancelled, let directory, admission.provider == "groq",
                  let kind=Kind.allCases.first(where: { $0.profile.choice.modelID == admission.modelID }), request.model == admission.modelID,
                  [admission.taskID, admission.threadID, admission.turnID].allSatisfy({ UUID(uuidString:$0)?.uuidString.lowercased()==$0 }),
                  let user = controlledUserText(request,allowingContinuation:false,kind:kind) else { return nil }
            let started=ContinuousClock.now
            var deadline: ContinuousClock.Instant?
            var mode: Mode = .status
            guard let file=WebsitePrivateDiagnosticCapture.claim(directory:directory,record:.groqOwnedStatus,maximumArmBytes:4096,validate:{ data in
                guard APIModelCorrectionJSON.isUnambiguous(data),
                      let v=try? JSONSerialization.jsonObject(with:data) as? [String:String],
                      Set(v.keys)==["purpose","nonce","modelID","userPromptSHA256","expiresAt"],
                      v["purpose"]==kind.purpose || allowManualInspector && kind == .gptoss120b && v["purpose"]==Self.inspectorPurpose
                        || allowEarlyPassive && kind == .gptoss120b && v["purpose"]==Self.earlyPassivePurpose,
                      v["modelID"]==admission.modelID,
                      let nonce=v["nonce"], UUID(uuidString:nonce)?.uuidString.lowercased()==nonce,
                      v["userPromptSHA256"]==GroqOwnedStatusLease.digest(user), let expiry=v["expiresAt"], expiry.utf8.count==24 else { return false }
                let fmt=ISO8601DateFormatter(); fmt.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
                guard let end=fmt.date(from:expiry),fmt.string(from:end)==expiry,
                      end>now,end.timeIntervalSince(now)<=600 else { return false }
                mode = v["purpose"] == Self.inspectorPurpose ? .manualInspector
                    : v["purpose"] == Self.earlyPassivePurpose ? .earlyPassive : .status
                deadline=started + .seconds(end.timeIntervalSince(now)); return true
            },isCurrent:{ !Task.isCancelled && (deadline.map { ContinuousClock.now < $0 } ?? false) }),let deadline else { return nil }
            return .init(file:file,first:admission,deadline:deadline,user:user,kind:kind,mode:mode)
        }

        func child(admission: WebModelStartAdmission, request: WebModelResponseCodec.Request,
                   closedInferenceID: UUID? = nil, closedContinuation: WebsiteTurnContinuation? = nil) -> GroqOwnedStatusLease? {
            lock.withLock {
                guard !Task.isCancelled, active, ContinuousClock.now < deadline,
                      admission.taskID==first.taskID, admission.threadID==first.threadID, admission.turnID==first.turnID,
                      admission.runtimeGeneration==first.runtimeGeneration, admission.preparationID==first.preparationID,
                      admission.transportGeneration==first.transportGeneration, admission.provider==first.provider,
                      admission.modelID==first.modelID, request.model==first.modelID,
                      let user=Self.controlledUserText(request,allowingContinuation:true,kind:kind),GroqOwnedStatusLease.digest(user)==userHash,
                      children.count < WebModelServer.maximumTurnInferences,
                      !children.contains(admission.inferenceID) else { return nil }
                var inspectorOrdinal: Int?
                if mode == .manualInspector || mode == .earlyPassive {
                    let ordinal = children.count + 1
                    if mode == .manualInspector { guard ordinal <= 4 else { return nil } }
                    if ordinal == 1 {
                        guard admission == first, closedInferenceID == nil, closedContinuation == nil else { return nil }
                    } else {
                        guard closedInferenceID == lastScopedInferenceID,
                              let closedContinuation, closedContinuation.pendingToolCallCount > 0,
                              (try? closedContinuation.validate(next: request)) != nil else { return nil }
                        if mode == .manualInspector { inspectorOrdinal = ordinal }
                    }
                    lastScopedInferenceID = admission.inferenceID
                }
                children.insert(admission.inferenceID)
                let child = GroqOwnedStatusLease(file,admission,deadline,request.prompt,profile:kind.profile,
                    fixtureTurn:self,inspectorOrdinal:inspectorOrdinal, installationMode:mode == .earlyPassive ? .earlyPassive : .late)
                if inspectorOrdinal != nil || mode == .earlyPassive { dependentChildren.append(WeakChild(lease: child)) }
                return child
            }
        }

        fileprivate func commit(_ rename: () -> Bool) -> Bool {
            lock.withLock {
                guard !Task.isCancelled,active,ContinuousClock.now < deadline else { return false }
                active=false
                return rename()
            }
        }

        // publish() invokes commit while holding its child's lock. Drain only
        // after that outer lock has been released; never re-enter a child lock.
        fileprivate func revokeRetiredChildren() {
            let leases: [GroqOwnedStatusLease] = lock.withLock {
                guard !active else { return [] }
                let leases = dependentChildren.compactMap(\.lease); dependentChildren.removeAll()
                return leases
            }
            leases.forEach { $0.revoke() }
        }

        private static func controlledUserText(_ request: WebModelResponseCodec.Request, allowingContinuation: Bool, kind: Kind) -> String? {
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
            guard matchesPrompt(user,kind:kind),let prefix=try? JSONSerialization.data(withJSONObject:root),
                  WebsiteSyntheticFirstRequest.matches(prefix,model:request.model,expectedUserText:user) else { return nil }
            return user
        }

        static func matchesPrompt(_ user: String, kind: Kind = .qwen27b) -> Bool {
            let prefix="In "
            let middle=", fix the invoice aggregation bug in reconcile.py according to its README. Keep the tests, sample data, and reference format unchanged. Run python3 -m unittest -v, then run python3 reconcile.py.\n\nUse the built-in browser to open http://127.0.0.1:"
            let suffix="/, enter the printed reference, and submit it once. Read the resulting receipt, then close the tab you opened. Use browser tools for the website; do not use terminal HTTP requests or inspect the fixture's control directory, server source, or receipt files.\n\nReturn the test result, the reference, and the receipt shown by the page."
            guard user.utf8.count<=8_192,user.hasPrefix(prefix),user.hasSuffix(suffix) else { return false }
            let pieces=String(user.dropFirst(prefix.count).dropLast(suffix.count)).components(separatedBy:middle)
            guard pieces.count==2, let port=UInt16(pieces[1]),port>=1_024,String(port)==pieces[1] else { return false }
            let path=pieces[0]
            guard path.utf8.count<=4_096,path.hasPrefix("/"),!path.contains("\n"),!path.contains("\r"),!path.contains("\0"),
                  URL(fileURLWithPath:path).standardizedFileURL.path==path,
                  path.range(of:#"/fixtures/cases/invoice-[1-9][0-9]{2,5}-"# + kind.casePathToken + #"-[a-f0-9]{16}/coding$"#,options:.regularExpression) != nil else { return false }
            return true
        }
    }
    /// Negative troubleshooting metadata only. These values cannot admit a
    /// response, extend a deadline, grant an action, or establish HTTP/body proof.
    enum CompletionGate: String, CaseIterable, Sendable {
        case notSubmitted = "not_submitted", cleared, userAbsent = "user_absent", answerAbsent = "answer_absent"
        case textEmpty = "text_empty", editorDisabled = "editor_disabled", editorNotEmpty = "editor_not_empty"
        case sendDisabled = "send_disabled", footerMissing = "footer_missing", footerShape = "footer_shape"
        case footerHidden = "footer_hidden", copyCount = "copy_count", copyParent = "copy_parent"
        case copyDisabled = "copy_disabled", copyIconCount = "copy_icon_count", complete
    }
    struct ProgressInspection: Sendable {
        let gate: CompletionGate
        let users: Int, answers: Int, textBytes: Int
        let busy: Bool, answerComplete: Bool
        static func parse(_ raw: Any?, observed: [String: Any]) -> Self? {
            guard let value = raw as? [String: Any], Set(value.keys) == ["kind", "reason"],
                  value["kind"] as? String == "groq_completion_gate_v1",
                  let name = value["reason"] as? String, let gate = CompletionGate(rawValue: name),
                  let users = ComputerToolArgumentContract.exactInt64(observed["userCount"]), (0...1).contains(users),
                  let answers = ComputerToolArgumentContract.exactInt64(observed["responseCount"]), (0...1).contains(answers),
                  let text = observed["text"] as? String,
                  let busy = observed["busy"] as? NSNumber, CFGetTypeID(busy) == CFBooleanGetTypeID(),
                  let complete = observed["answerComplete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(),
                  complete.boolValue == (gate == .complete), busy.boolValue != complete.boolValue else { return nil }
            return .init(gate: gate, users: Int(users), answers: Int(answers),
                         textBytes: text.utf8.prefix(220_001).count, busy: busy.boolValue, answerComplete: complete.boolValue)
        }
        var fields: [String: Any] {
            ["gate": gate.rawValue, "users": users, "answers": answers, "textBytes": textBytes,
             "busy": busy, "answerComplete": answerComplete]
        }
    }
    struct FailureProgress: Sendable {
        let inspection: ProgressInspection?
        let readsStarted: Int, readsReturned: Int, admittedReads: Int, waitsStarted: Int, waitsReturned: Int
        let inspectionAgeMS: Int?, readAgeMS: Int?, waitAgeMS: Int?, responseChangeAgeMS: Int?, quietAgeMS: Int?
        let completionCandidate: Bool
        var fields: [String: Any] {
            ["kind": "groq_failure_progress_v1", "inspection": inspection.map { $0.fields as Any } ?? NSNull(),
             "readsStarted": readsStarted, "readsReturned": readsReturned, "admittedReads": admittedReads,
             "waitsStarted": waitsStarted, "waitsReturned": waitsReturned,
             "inspectionAgeMS": inspectionAgeMS.map { $0 as Any } ?? NSNull(),
             "readAgeMS": readAgeMS.map { $0 as Any } ?? NSNull(), "waitAgeMS": waitAgeMS.map { $0 as Any } ?? NSNull(),
             "responseChangeAgeMS": responseChangeAgeMS.map { $0 as Any } ?? NSNull(),
             "quietAgeMS": quietAgeMS.map { $0 as Any } ?? NSNull(), "completionCandidate": completionCandidate]
        }
    }
    struct ProgressCache {
        private(set) var readsStarted = 0, readsReturned = 0, admittedReads = 0, waitsStarted = 0, waitsReturned = 0
        private var reading: ContinuousClock.Instant?, waiting: ContinuousClock.Instant?
        private var last: (ProgressInspection, ContinuousClock.Instant)?
        private static func increment(_ n: Int) -> Int { min(65_535, n + 1) }
        mutating func readStarted(now: ContinuousClock.Instant = .now) { readsStarted = Self.increment(readsStarted); reading = now }
        mutating func readReturned() { readsReturned = Self.increment(readsReturned); reading = nil }
        mutating func waitStarted(now: ContinuousClock.Instant = .now) { waitsStarted = Self.increment(waitsStarted); waiting = now }
        mutating func waitReturned() { waitsReturned = Self.increment(waitsReturned); waiting = nil }
        mutating func admit(_ inspection: ProgressInspection, now: ContinuousClock.Instant = .now) {
            admittedReads = Self.increment(admittedReads); last = (inspection, now)
        }
        static func age(_ at: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Int? {
            guard let at else { return nil }
            let span = at.duration(to: now).components
            // Clamp before integer conversion, including a crossed/invalid clock.
            guard span.seconds >= 0 else { return 0 }
            guard span.seconds < 300 else { return 300_000 }
            return max(0, min(300_000, Int(span.seconds) * 1_000 + Int(span.attoseconds / 1_000_000_000_000_000)))
        }
        func snapshot(now: ContinuousClock.Instant = .now, candidate: Bool,
                      changed: ContinuousClock.Instant?, quietSince: ContinuousClock.Instant?) -> FailureProgress {
            .init(inspection: last?.0, readsStarted: readsStarted, readsReturned: readsReturned, admittedReads: admittedReads,
                  waitsStarted: waitsStarted, waitsReturned: waitsReturned, inspectionAgeMS: Self.age(last?.1, now: now),
                  readAgeMS: Self.age(reading, now: now), waitAgeMS: Self.age(waiting, now: now),
                  responseChangeAgeMS: last.map { _ in Self.age(changed, now: now) } ?? nil,
                  quietAgeMS: candidate ? Self.age(quietSince, now: now) : nil, completionCandidate: candidate)
        }
    }
    struct Observation: Sendable {
        let stage: String
        let sessionToken: String
        let generation: UUID
        let failureProgress: FailureProgress?
        init(stage: String, sessionToken: String, generation: UUID, failureProgress: FailureProgress? = nil) {
            self.stage = stage; self.sessionToken = sessionToken; self.generation = generation; self.failureProgress = failureProgress
        }
    }
    // Called synchronously on the server after it has rejoined this exact current inference.
    func publish(_ observation: Observation, trigger: String) {
        let stage=observation.stage, owner=observation.sessionToken, generation=observation.generation
        guard !Task.isCancelled, isCurrent,
              Self.stages.contains(stage) || isFixture && ["observer_not_armed","observer_unavailable"].contains(stage),
              ["response_deadline","groq_draft_restored","groq_reported_submission_error"].contains(trigger),
              let session=UUID(uuidString:owner) else{return}
        var v:[String:Any]=["schemaVersion":1,"purpose":fixtureTurn?.publicationPurpose ?? profile.purpose,"provider":"groq","modelID":admission.modelID,
            "taskID":admission.taskID,"threadID":admission.threadID,"turnID":admission.turnID,
            "inferenceID":admission.inferenceID.uuidString.lowercased(),"preparationID":admission.preparationID.uuidString.lowercased(),
            "runtimeGeneration":admission.runtimeGeneration.uuidString.lowercased(),"session":session.uuidString.lowercased(),
            "documentGeneration":generation.uuidString.lowercased(),"trigger":trigger,"stage":stage,
            "evidenceClass":["observer_not_armed","observer_unavailable"].contains(stage) ? "native_observer_availability" : "page_world_observation"]
        if isFixture, ["observer_not_armed","observer_unavailable"].contains(stage) {
            v["setupReason"] = lock.withLock { setupReason.rawValue }
        }
        if capturesFailureProgress, let progress = observation.failureProgress { v["failureProgress"] = progress.fields }
        guard let bytes=try? JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]) else{return}
        _=WebsitePrivateDiagnosticCapture.publish(bytes,using:file,isCurrent:{ !Task.isCancelled && self.isCurrent },commit:{ rename in
            self.lock.withLock {
                guard !Task.isCancelled,self.active,ContinuousClock.now < self.deadline else { return false }
                return self.fixtureTurn.map { $0.commit(rename) } ?? rename()
            }
        })
        fixtureTurn?.revokeRetiredChildren()
    }
}

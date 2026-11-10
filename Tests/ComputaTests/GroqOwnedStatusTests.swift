import AppKit
import Foundation
import WebKit
import XCTest
@testable import Computa

@MainActor final class GroqOwnedStatusTests: XCTestCase {
    // Actual native server, normal ownership/selection/cleanup, real WebKit. No network endpoint is contacted.
    private final class LocalView: WKWebView {
        var html = ""
        override func load(_ request: URLRequest) -> WKNavigation? { loadHTMLString(html,baseURL:request.url) }
    }
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    func testResponseStreamOuterPacketKeepsTheOldStatusVocabularyAndRejectsUnrepresentedOrContradictoryMetadata() throws {
        typealias Packet = EmbeddedBrowserSession.GroqResponseStreamStatus
        let inner = try responseStreamMetadataJSON()
        func outer(_ stage: Any = "http_2xx_opened", _ metadata: Any = NSNull()) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["stage": stage, "responseStream": metadata]), as: UTF8.self)
        }
        let packet = try XCTUnwrap(Packet.parse(try outer("http_2xx_opened", inner)))
        XCTAssertEqual(packet.stage, "http_2xx_opened")
        XCTAssertEqual(packet.metadata?.fields.count, 20)
        let headerOnly = try XCTUnwrap(Packet.parse(try outer("http_429")))
        XCTAssertEqual(headerOnly.stage, "http_429")
        XCTAssertNil(headerOnly.metadata, "A header observation supplies no body or completion facts")
        for stage in ["http_429", "ambiguous", "matched_fetch_unsettled"] {
            XCTAssertNil(Packet.parse(try outer(stage, inner)), "Only a matched 2xx branch can clone a body")
        }
        for invalid in [try outer("PRIVATE_FOREIGN_STATUS"), try outer(true),
                        try outer("http_2xx_opened", "PRIVATE_BODY"),
                        try outer("http_2xx_opened", ["version": 1]),
                        try outer("http_2xx_opened", try responseStreamMetadataJSON(["content": 1])),
                        "[]", "{\"stage\":\"http_2xx_opened\"}",
                        "{\"stage\":\"http_2xx_opened\",\"responseStream\":null,\"privateBody\":\"PRIVATE_BODY\"}",
                        "{\"stage\":\"http_429\",\"stage\":\"http_2xx_opened\",\"responseStream\":null}",
                        #"{"stage":"http_429","sta\u0067e":"http_2xx_opened","responseStream":null}"#,
                        String(repeating: " ", count: 2_049) + (try outer())] {
            XCTAssertNil(Packet.parse(invalid))
        }
    }

    func testResponseStreamMetadataRequiresOnlyClosedBoundedFieldsAndExactJSONTypes() throws {
        typealias Metadata = GroqOwnedStatusLease.ResponseStreamMetadata
        let good = try responseStreamMetadataJSON()
        let parsed = try XCTUnwrap(Metadata.parse(good))
        XCTAssertEqual(parsed.fields.count, 20)
        XCTAssertEqual(parsed.fields["apiErrorType"] as? String, "tokens")
        for (field, maximum) in [("bytes", 262_144), ("chunks", 8_192), ("events", 4_096), ("jsonEvents", 4_096), ("unknownFrames", 4_096)] {
            XCTAssertNotNil(Metadata.parse(try responseStreamMetadataJSON([field: maximum])))
            for invalid in ([-1, maximum + 1, 1.5, true, "1", NSNull()] as [Any]) {
                XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON([field: invalid])), field)
            }
        }
        for field in ["content", "reasoning", "toolCalls", "topLevelError", "eventError", "done", "eof", "incompleteFrame"] {
            XCTAssertNotNil(Metadata.parse(try responseStreamMetadataJSON([field: false])))
            for invalid in ([0, 1, "true", NSNull()] as [Any]) {
                XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON([field: invalid])), field)
            }
        }
        for field in ["framing", "xGroqError", "apiErrorCode", "apiErrorType", "finishReason", "outcome"] {
            XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON([field: "PRIVATE_UNKNOWN_PROVIDER_TEXT"])), field)
            XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON([field: NSNull()])), field)
        }
        for value in ["tokens", "requests", "other"] {
            XCTAssertNotNil(Metadata.parse(try responseStreamMetadataJSON(["apiErrorType": value])))
        }
        for value in ["revoked", "disposed"] {
            XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON(["outcome": value])), "Retired callbacks do not publish")
        }
        XCTAssertNotNil(Metadata.parse(good + String(repeating: " ", count: 2_048 - good.utf8.count)))
        for bad in [try responseStreamMetadataJSON(["privateText": "PRIVATE_BODY"]),
                    good.replacingOccurrences(of: "\"done\":true,", with: ""),
                    good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                    good.replacingOccurrences(of: "\"version\":1", with: #""version":1,"\u0076ersion":1"#),
                    "[" + good + "]", String(repeating: " ", count: 2_049) + good] {
            XCTAssertNil(Metadata.parse(bad))
        }
        XCTAssertNil(Metadata.parse(["version": 1])); XCTAssertNil(Metadata.parse(nil))
        XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON(["version": true])))
        XCTAssertNil(Metadata.parse(try responseStreamMetadataJSON(["version": 2])))
        let saved = try JSONSerialization.data(withJSONObject: parsed.fields, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(saved.count, 2_048)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("PRIVATE_"))
    }

    func testResponseStreamPurposeRequiresSeparateNativeOptInAndCannotGrantInspector() throws {
        typealias Lease = GroqOwnedStatusLease
        for refusal in ["disabled", "earlyOnly", "manualOnly", "qwen", "hash", "purpose", "extraKey", "publicArm", "expired", "future"] {
            let arm = try inspectorArm(kind: refusal == "qwen" ? .qwen27b : .gptoss120b,
                purpose: Lease.FixtureTurn.responseStreamPurpose, mutation: refusal,
                expiresIn: refusal == "expired" ? -1 : refusal == "future" ? 601 : 60)
            XCTAssertNil(Lease.FixtureTurn.consume(directory: arm.directory, admission: arm.admission,
                request: arm.request, first: true, allowManualInspector: refusal == "manualOnly",
                allowEarlyPassive: refusal == "earlyOnly", allowResponseStream: !["disabled", "earlyOnly", "manualOnly"].contains(refusal)), refusal)
            XCTAssertTrue(FileManager.default.fileExists(atPath: arm.directory.appendingPathComponent("arm.json").path))
        }
        let arm = try inspectorArm(purpose: Lease.FixtureTurn.responseStreamPurpose)
        let parent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: arm.directory, admission: arm.admission,
            request: arm.request, first: true, allowResponseStream: true))
        XCTAssertEqual(parent.publicationPurpose, Lease.FixtureTurn.responseStreamPurpose)
        let child = try XCTUnwrap(parent.child(admission: arm.admission, request: arm.request))
        XCTAssertEqual(child.installationMode, .earlyPassive)
        XCTAssertTrue(child.capturesResponseStreamMetadata); XCTAssertTrue(child.capturesFailureProgress)
        XCTAssertNil(child.inspectorOrdinal)
        XCTAssertNil(child.bindInspector(view: ObjectIdentifier(NSObject()), ownerToken: UUID().uuidString.lowercased(), generation: UUID()))
        for (purpose, manual, early) in [(Lease.FixtureTurn.Kind.gptoss120b.purpose, false, false),
                                        (Lease.FixtureTurn.inspectorPurpose, true, false),
                                        (Lease.FixtureTurn.earlyPassivePurpose, false, true)] {
            let old = try inspectorArm(purpose: purpose)
            let oldParent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: old.directory, admission: old.admission,
                request: old.request, first: true, allowManualInspector: manual, allowEarlyPassive: early, allowResponseStream: true))
            let oldChild = try XCTUnwrap(oldParent.child(admission: old.admission, request: old.request))
            XCTAssertFalse(oldChild.capturesResponseStreamMetadata, "Other purposes cannot inherit the new probe")
        }
    }

    func testResponseStreamChildrenRequireCurrentClosedNativeHandoffAndRetireTogether() throws {
        typealias Lease = GroqOwnedStatusLease
        let arm = try inspectorArm(purpose: Lease.FixtureTurn.responseStreamPurpose)
        let parent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: arm.directory, admission: arm.admission,
            request: arm.request, first: true, allowResponseStream: true))
        let first = try XCTUnwrap(parent.child(admission: arm.admission, request: arm.request))
        let continued = try inspectorContinuation(arm.request)
        let next = inspectorAdmission(after: arm.admission)
        XCTAssertNil(parent.child(admission: next, request: continued.next))
        for changed in ["task", "thread", "turn", "runtime", "preparation", "transport", "provider", "model"] {
            XCTAssertNil(parent.child(admission: inspectorAdmission(after: arm.admission, changing: changed),
                request: continued.next, closedInferenceID: arm.admission.inferenceID, closedContinuation: continued.closed), changed)
        }
        XCTAssertNil(parent.child(admission: next, request: continued.next,
            closedInferenceID: UUID(), closedContinuation: continued.closed))
        let second = try XCTUnwrap(parent.child(admission: next, request: continued.next,
            closedInferenceID: arm.admission.inferenceID, closedContinuation: continued.closed))
        XCTAssertTrue(second.capturesResponseStreamMetadata); XCTAssertNil(second.inspectorOrdinal)
        XCTAssertNil(parent.child(admission: next, request: continued.next,
            closedInferenceID: arm.admission.inferenceID, closedContinuation: continued.closed))
        parent.revoke()
        XCTAssertFalse(first.capturesResponseStreamMetadata); XCTAssertFalse(second.capturesResponseStreamMetadata)
        XCTAssertFalse(first.capturesFailureProgress); XCTAssertFalse(second.isCurrent)
        XCTAssertNil(parent.child(admission: inspectorAdmission(after: arm.admission), request: continued.next,
            closedInferenceID: next.inferenceID, closedContinuation: continued.closed))
    }

    func testResponseStreamMetadataPublishesOnlyOnFirstCurrentNewPurposeFailureWithinPrivateRecordCap() throws {
        typealias Lease = GroqOwnedStatusLease
        let metadata = try XCTUnwrap(Lease.ResponseStreamMetadata.parse(try responseStreamMetadataJSON()))
        let arm = try inspectorArm(purpose: Lease.FixtureTurn.responseStreamPurpose)
        let parent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: arm.directory, admission: arm.admission,
            request: arm.request, first: true, allowResponseStream: true))
        let child = try XCTUnwrap(parent.child(admission: arm.admission, request: arm.request))
        let progress = Lease.ProgressCache().snapshot(candidate: false, changed: nil, quietSince: nil)
        let observation = Lease.Observation(stage: "http_2xx_opened", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID(), failureProgress: progress, responseStreamMetadata: metadata)
        child.publish(observation, trigger: "response_deadline")
        let bytes = try Data(contentsOf: arm.output)
        XCTAssertLessThanOrEqual(bytes.count, 4_096)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(row.count, 17); XCTAssertEqual(row["purpose"] as? String, Lease.FixtureTurn.responseStreamPurpose)
        let saved = try XCTUnwrap(row["responseStreamMetadata"] as? [String: Any])
        XCTAssertEqual(saved.count, 20); XCTAssertEqual(saved["apiErrorType"] as? String, "tokens")
        XCTAssertNotNil(row["failureProgress"])
        child.publish(.init(stage: "http_429", sessionToken: observation.sessionToken, generation: observation.generation,
            responseStreamMetadata: nil), trigger: "groq_reported_submission_error")
        XCTAssertEqual(try Data(contentsOf: arm.output), bytes)
        XCTAssertFalse(child.capturesResponseStreamMetadata)
        for ordinary in [try setupLease(fixture: false), try setupLease(fixture: true)] {
            ordinary.lease.publish(observation, trigger: "response_deadline")
            let old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ordinary.output)) as? [String: Any])
            XCTAssertEqual(old.count, 15); XCTAssertNil(old["responseStreamMetadata"])
        }
        let retired = try inspectorArm(purpose: Lease.FixtureTurn.responseStreamPurpose)
        let retiredParent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: retired.directory, admission: retired.admission,
            request: retired.request, first: true, allowResponseStream: true))
        let retiredChild = try XCTUnwrap(retiredParent.child(admission: retired.admission, request: retired.request))
        retiredParent.revoke(); retiredChild.publish(observation, trigger: "response_deadline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.output.path))
        for secret in ["PRIVATE_BODY", "PRIVATE_UNKNOWN_PROVIDER_TEXT", "http://127.0.0.1"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        }
    }

    private func responseStreamMetadataJSON(_ changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["version": 1, "framing": "sse", "bytes": 262_144, "chunks": 8_192,
            "events": 4_096, "jsonEvents": 4_096, "content": true, "reasoning": true, "toolCalls": true,
            "topLevelError": true, "eventError": true, "xGroqError": "rate_limit_exceeded",
            "apiErrorCode": "rate_limit_exceeded", "apiErrorType": "tokens", "finishReason": "length",
            "done": true, "eof": false, "unknownFrames": 4_096, "incompleteFrame": true, "outcome": "byte_limit"]
        value.merge(changes) { _, replacement in replacement }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testSyntheticOwnedDeadlineDistinguishesPreflightAndOutstandingFetchWithoutAuthorizingCleanup() async throws {
        for (variant,expected) in [("preflight","no_matching_fetch_observed"),("pending","matched_fetch_unsettled"),("wrongBody","ambiguous"),("unarmed","none"),("nativeDeadline","no_matching_fetch_observed"),("retiredDuringRead","none")] {
            try await run(variant,expected:expected)
        }
    }
    func testSuccessfulOrdinaryReplyAndMismatchedSyntheticArmPublishNothing() async throws {
        try await run("success",expected:"none")
        try await run("wrongNonce",expected:"none")
    }
    func testRestoredOwnedDraftPreservesOriginalRejectionAndNeverSendsAgain() async throws {
        try await run("rollback",expected:"transport_rejected")
    }
    func testQwenAnd120BProfilesCaptureOnlyTheirFirstSyntheticOwnedRollback() async throws {
        for profile in [GroqOwnedStatusLease.Profile.qwen27b, .gptoss120b] {
            try await run("rollback",expected:"transport_rejected",profile:profile)
        }
    }
    func testQwenAnd120BProfilesRejectForeignArmsAndRetiredNativeContexts() async throws {
        for profile in [GroqOwnedStatusLease.Profile.qwen27b, .gptoss120b] {
            try await run("wrongProfile",expected:"none",profile:profile)
            try await run("retiredDuringRead",expected:"none",profile:profile)
        }
    }
    func testControlledFixtureCapturesFirstAndContinuationFailureWithOneFetchPerFreshView() async throws {
        try await run("rollback",expected:"transport_rejected",profile:.qwen27b,fixture:true)
        try await run("rollback",expected:"transport_rejected",profile:.qwen27b,fixture:true,continuation:true)
        try await run("rollback",expected:"transport_rejected",profile:.qwen27b,fixture:true,continuation:true,customHistory:true)
        try await run("observerNotArmed",expected:"observer_not_armed",profile:.qwen27b,fixture:true)
        try await run("observerUnavailable",expected:"observer_unavailable",profile:.qwen27b,fixture:true)
    }

    func testControlledFixtureSuccessForeignArmAndRetiredContextPublishNothing() async throws {
        for mode in ["success","wrongNonce","wrongProfile","wrongPurpose","wrongFixture","retiredDuringRead","navigatedDuringRead"] {
            try await run(mode,expected:"none",profile:.qwen27b,fixture:true)
        }
        try await run("wrongModel",expected:"none",profile:.gptoss120b,fixture:true)
    }

    func test120BControlledFixtureCapturesOnlyItsExactFirstOrContinuationFailure() async throws {
        try await run("rollback",expected:"transport_rejected",profile:.gptoss120b,fixture:true,fixtureKind:.gptoss120b)
        try await run("rollback",expected:"transport_rejected",profile:.gptoss120b,fixture:true,continuation:true,fixtureKind:.gptoss120b)
        try await run("rollback",expected:"transport_rejected",profile:.gptoss120b,fixture:true,continuation:true,customHistory:true,fixtureKind:.gptoss120b)
        try await run("observerNotArmed",expected:"observer_not_armed",profile:.gptoss120b,fixture:true,fixtureKind:.gptoss120b)
        try await run("observerUnavailable",expected:"observer_unavailable",profile:.gptoss120b,fixture:true,fixtureKind:.gptoss120b)
    }

    func test120BControlledFixtureRejectsCrossedPurposeModelAndRetiredContext() async throws {
        for mode in ["success","wrongNonce","wrongProfile","wrongPurpose","crossFixturePurpose","wrongFixture","retiredDuringRead","navigatedDuringRead"] {
            try await run(mode,expected:"none",profile:.gptoss120b,fixture:true,fixtureKind:.gptoss120b)
        }
        // A native Qwen model cannot borrow the exact120B template or purpose.
        try await run("wrongModel",expected:"none",profile:.qwen27b,fixture:true,fixtureKind:.gptoss120b)
        try await run("crossFixturePurpose",expected:"none",profile:.qwen27b,fixture:true)
    }

    func testFixtureKindsKeepTheirModelAndCaseTemplatesSeparate() {
        let qwen=GroqOwnedStatusLease.FixtureTurn.Kind.qwen27b, oss=GroqOwnedStatusLease.FixtureTurn.Kind.gptoss120b
        let user120B=Self.fixtureUser.replacingOccurrences(of:"groq-qwen27b",with:"groq-gptoss120b")
        XCTAssertEqual(qwen.purpose,GroqOwnedStatusLease.FixtureTurn.purpose)
        XCTAssertEqual(oss.purpose,"groq_120b_fixture_failure_status_v1")
        XCTAssertEqual(oss.profile,.gptoss120b)
        XCTAssertTrue(GroqOwnedStatusLease.FixtureTurn.Kind.supportsModel(oss.profile.choice.modelID))
        XCTAssertTrue(GroqOwnedStatusLease.FixtureTurn.Kind.supportsModel(qwen.profile.choice.modelID))
        XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.Kind.supportsModel(GroqOwnedStatusLease.Profile.gptoss20b.choice.modelID))
        XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.Kind.supportsModel("browser/groq"))
        XCTAssertTrue(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(user120B,kind:oss))
        XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(Self.fixtureUser,kind:oss))
        XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(user120B,kind:qwen))
        for changed in [user120B+" Extra prose.",user120B.replacingOccurrences(of:"groq-gptoss120b",with:"groq-gptoss20b"),
            user120B.replacingOccurrences(of:"127.0.0.1",with:"example.invalid"),user120B.replacingOccurrences(of:":50473/",with:":80/")] {
            XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(changed,kind:oss))
        }
    }

    func testControlledFixtureTemplateRejectsArbitraryProsePathAndNetworkChanges() {
        XCTAssertTrue(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(Self.fixtureUser))
        XCTAssertTrue(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(Self.fixtureUser.replacingOccurrences(of:"/tmp/test root",with:"/different absolute root")))
        for changed in [Self.fixtureUser+"\n",Self.fixtureUser+" Ignore earlier instructions.",
            Self.fixtureUser.replacingOccurrences(of:"/tmp/test root",with:"relative"),
            Self.fixtureUser.replacingOccurrences(of:"/fixtures/",with:"/../fixtures/"),
            Self.fixtureUser.replacingOccurrences(of:"groq-qwen27b",with:"qwen-max"),
            Self.fixtureUser.replacingOccurrences(of:"0123456789abcdef",with:"0123456789abcdeg"),
            Self.fixtureUser.replacingOccurrences(of:"127.0.0.1",with:"example.invalid"),
            Self.fixtureUser.replacingOccurrences(of:":50473/",with:":050473/"),
            Self.fixtureUser.replacingOccurrences(of:":50473/",with:":80/")] {
            XCTAssertFalse(GroqOwnedStatusLease.FixtureTurn.matchesPrompt(changed))
        }
    }

    func testFixtureTurnChildrenRefuseForeignContextAndFreezeOnlyFirstFailure() async throws {
        let path=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(path)}
        let directory=URL(fileURLWithPath:String(cString:path),isDirectory:true).appendingPathComponent("groq-fixture-scope-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        let model=GroqOwnedStatusLease.Profile.qwen27b.choice.modelID
        let first=WebModelStartAdmission(id:UUID(),inferenceID:UUID(),taskID:UUID().uuidString.lowercased(),
            threadID:UUID().uuidString.lowercased(),turnID:UUID().uuidString.lowercased(),runtimeGeneration:UUID(),
            preparationID:UUID(),transportGeneration:UUID(),provider:"groq",modelID:model,parameters:Data("{}".utf8))
        func admission(changing field:String="") -> WebModelStartAdmission {
            .init(id:UUID(),inferenceID:UUID(),taskID:field=="task" ? UUID().uuidString.lowercased() : first.taskID,
                threadID:field=="thread" ? UUID().uuidString.lowercased() : first.threadID,
                turnID:field=="turn" ? UUID().uuidString.lowercased() : first.turnID,
                runtimeGeneration:field=="runtime" ? UUID() : first.runtimeGeneration,
                preparationID:field=="preparation" ? UUID() : first.preparationID,
                transportGeneration:field=="transport" ? UUID() : first.transportGeneration,
                provider:field=="provider" ? "qwen" : first.provider,
                modelID:field=="model" ? GroqOwnedStatusLease.Profile.gptoss120b.choice.modelID : model,parameters:first.parameters)
        }
        func request(continuation:Bool=false,customHistory:Bool=false,user:String?=nil,extraUser:Bool=false) throws -> WebModelResponseCodec.Request {
            func item(_ role:String,_ text:String)->[String:Any] {
                ["type":"message","role":role,"content":[["type":"input_text","text":text]]]
            }
            var input:[[String:Any]]=[item("developer","Synthetic policy"),
                item("user","<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
                item("user",(user ?? Self.fixtureUser)+"\n"+ComputaAgentInstructions.runtimeInteractionPolicy())]
            if continuation { input += [["type":"function_call","name":"fixture_read","arguments":"{}","call_id":"call_fixture"],
                ["type":"function_call_output","call_id":"call_fixture","output":"Synthetic read result"]] }
            if customHistory { input += [["type":"custom_tool_call","name":"apply_patch","input":"Synthetic patch bytes","call_id":"call_patch"],
                ["type":"custom_tool_call_output","call_id":"call_patch","output":"Synthetic patch result"]] }
            if extraUser { input.append(item("user","A different user instruction")) }
            return try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject:["model":model,"input":input,
                "tools":[["type":"function","name":"fixture_read","parameters":["type":"object","properties":[String:Any](),"additionalProperties":false]],
                    ["type":"custom","name":"apply_patch"]]]))
        }
        let date=ISO8601DateFormatter();date.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let arm=directory.appendingPathComponent("arm.json"),output=directory.appendingPathComponent("owned-status.json")
        let values=["purpose":GroqOwnedStatusLease.FixtureTurn.purpose,"nonce":UUID().uuidString.lowercased(),"modelID":model,
            "userPromptSHA256":GroqOwnedStatusLease.digest(Self.fixtureUser),"expiresAt":date.string(from:Date().addingTimeInterval(60))]
        let armBytes=try JSONSerialization.data(withJSONObject:values)
        func writeArm() throws {
            try armBytes.write(to:arm);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:arm.path)
        }
        try writeArm()
        let initial=try request(),next=try request(continuation:true)
        XCTAssertNil(GroqOwnedStatusLease.FixtureTurn.consume(directory:directory,admission:first,request:initial,first:false))
        XCTAssertNil(GroqOwnedStatusLease.FixtureTurn.consume(directory:directory,admission:admission(changing:"model"),request:initial,first:true))
        let parent=try XCTUnwrap(GroqOwnedStatusLease.FixtureTurn.consume(directory:directory,admission:first,request:initial,first:true))
        let child=try XCTUnwrap(parent.child(admission:first,request:initial))
        XCTAssertNil(parent.child(admission:first,request:initial),"An inference cannot get a second child")
        for field in ["task","thread","turn","runtime","preparation","transport","provider","model"] {
            XCTAssertNil(parent.child(admission:admission(changing:field),request:next),field)
        }
        XCTAssertNil(parent.child(admission:admission(),request:try request(continuation:true,
            user:Self.fixtureUser.replacingOccurrences(of:"0123456789abcdef",with:"fedcba9876543210"))))
        XCTAssertNil(parent.child(admission:admission(),request:try request(continuation:true,extraUser:true)))
        let cancelled=Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return parent.child(admission:admission(),request:next)==nil
        }
        let cancelledRefused=await cancelled.value
        XCTAssertTrue(cancelledRefused)
        child.revoke() // Ordinary first-page cleanup retires only that child.
        XCTAssertFalse(child.isCurrent);XCTAssertTrue(parent.isCurrent)
        let afterPatch=try request(continuation:true,customHistory:true)
        let patchChild=try XCTUnwrap(parent.child(admission:admission(),request:afterPatch))
        XCTAssertTrue(patchChild.matches(afterPatch.prompt));XCTAssertFalse(patchChild.matches(initial.prompt))
        patchChild.revoke();XCTAssertTrue(parent.isCurrent)
        let secondAdmission=admission()
        let second=try XCTUnwrap(parent.child(admission:secondAdmission,request:next))
        XCTAssertTrue(second.matches(next.prompt));XCTAssertFalse(second.matches(initial.prompt))
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path),"Success/cleanup does not publish a failure")
        let observation=GroqOwnedStatusLease.Observation(stage:"http_429",sessionToken:UUID().uuidString.lowercased(),generation:UUID())
        second.publish(observation,trigger:"groq_draft_restored")
        let frozen=try Data(contentsOf:output),row=try XCTUnwrap(JSONSerialization.jsonObject(with:frozen) as? [String:Any])
        XCTAssertEqual(row["purpose"] as? String,GroqOwnedStatusLease.FixtureTurn.purpose)
        XCTAssertEqual(row["inferenceID"] as? String,secondAdmission.inferenceID.uuidString.lowercased())
        XCTAssertEqual(row["stage"] as? String,"http_429");XCTAssertEqual(row.count,15)
        XCTAssertFalse(String(decoding:frozen,as:UTF8.self).contains(Self.fixtureUser))
        XCTAssertFalse(parent.isCurrent);XCTAssertNil(parent.child(admission:admission(),request:next))
        second.publish(.init(stage:"http_400",sessionToken:observation.sessionToken,generation:observation.generation),trigger:"response_deadline")
        child.publish(observation,trigger:"groq_draft_restored")
        XCTAssertEqual(try Data(contentsOf:output),frozen,"Later failure/cleanup cannot overwrite the first packet")

        let revokedDirectory=directory.appendingPathComponent("revoked")
        try FileManager.default.createDirectory(at:revokedDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let revokedArm=revokedDirectory.appendingPathComponent("arm.json")
        try armBytes.write(to:revokedArm);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:revokedArm.path)
        let revoked=try XCTUnwrap(GroqOwnedStatusLease.FixtureTurn.consume(directory:revokedDirectory,admission:first,request:initial,first:true))
        let pending=try XCTUnwrap(revoked.child(admission:first,request:initial))
        revoked.revoke() // Native cancellation/context/transport retirement.
        pending.publish(observation,trigger:"groq_draft_restored")
        XCTAssertFalse(pending.isCurrent);XCTAssertFalse(FileManager.default.fileExists(atPath:revokedDirectory.appendingPathComponent("owned-status.json").path))
    }

    func testSetupReasonVocabularyKeepsPageClaimsSeparateFromNativeStages() {
        typealias Reason = GroqOwnedStatusLease.SetupReason
        let expected: Set<String> = ["not_attempted", "transport_preconditions_skipped", "native_prepare_guard_skipped",
            "native_probe_absent", "native_initial_start_missing", "native_owner_already_set",
            "native_signal_owner_mismatch", "native_signal_origin_mismatch",
            "controller_absent", "arm_false", "arm_exception", "arm_timeout", "post_await_context_retired",
            "js_fetch_descriptor", "js_response_getters", "js_profile_unavailable", "js_fetch_replaced",
            "js_picker_unavailable", "js_picker_not_closed", "js_picker_label_mismatch", "js_route_unavailable", "js_model_mismatch", "js_prompt_unavailable",
            "js_arm_state_unavailable", "armed"]
        let page: Set<String> = ["controller_absent", "arm_false", "js_fetch_descriptor", "js_response_getters",
            "js_profile_unavailable", "js_fetch_replaced", "js_picker_unavailable", "js_picker_not_closed", "js_picker_label_mismatch", "js_route_unavailable",
            "js_model_mismatch", "js_prompt_unavailable", "js_arm_state_unavailable"]
        XCTAssertEqual(Set(Reason.allCases.map(\.rawValue)), expected)
        for reason in Reason.allCases {
            XCTAssertEqual(Reason.javaScriptArmReason(reason.rawValue)?.rawValue,
                           page.contains(reason.rawValue) ? reason.rawValue : nil)
        }
        for foreign in ["PRIVATE_https://example.invalid/secret", "ARMED", "arm_timeout\n", "js_fetch_descriptor suffix", ""] {
            XCTAssertNil(Reason(rawValue: foreign)); XCTAssertNil(Reason.javaScriptArmReason(foreign))
        }
    }

    func testFixtureAvailabilityReasonsAreClosedPrivateAndCannotForgeArmedState() throws {
        for reason in GroqOwnedStatusLease.SetupReason.allCases where reason != .armed {
            let fixture = try setupLease()
            if reason != .notAttempted { fixture.lease.recordSetupReason(reason) }
            fixture.lease.recordSetupReason(.armed) // Only recordObserverArmed may establish this native fact.
            XCTAssertEqual(fixture.lease.unavailableStage, "observer_not_armed")
            fixture.lease.publish(.init(stage: "observer_not_armed", sessionToken: UUID().uuidString.lowercased(),
                generation: UUID()), trigger: "groq_reported_submission_error")
            let bytes = try Data(contentsOf: fixture.output)
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let keys: Set<String> = ["schemaVersion", "purpose", "provider", "modelID", "taskID", "threadID", "turnID",
                "inferenceID", "preparationID", "runtimeGeneration", "session", "documentGeneration", "trigger", "stage",
                "evidenceClass", "setupReason"]
            XCTAssertEqual(Set(row.keys), keys)
            XCTAssertEqual(row["setupReason"] as? String, reason.rawValue)
            XCTAssertEqual(row["evidenceClass"] as? String, "native_observer_availability")
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(fixture.user))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("http://127.0.0.1"))
            fixture.lease.recordSetupReason(.armTimeout)
            fixture.lease.publish(.init(stage: "observer_unavailable", sessionToken: UUID().uuidString.lowercased(),
                generation: UUID()), trigger: "response_deadline")
            XCTAssertEqual(try Data(contentsOf: fixture.output), bytes, "Only the first exact failure may publish")
        }
        let armed = try setupLease()
        armed.lease.recordSetupReason(.controllerAbsent); armed.lease.recordObserverArmed()
        armed.lease.recordSetupReason(.armTimeout)
        XCTAssertEqual(armed.lease.unavailableStage, "observer_unavailable")
        armed.lease.publish(.init(stage: "observer_unavailable", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID()), trigger: "groq_reported_submission_error")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: armed.output)) as? [String: Any])
        XCTAssertEqual(row["setupReason"] as? String, "armed", "A later setup error cannot downgrade actual arm success")
    }

    func testSetupDiagnosticsDoNotBroadenMarkerPacketsOrReviveRetiredFixtureLeases() throws {
        let marker = try setupLease(fixture: false)
        marker.lease.recordSetupReason(.jsFetchDescriptor)
        XCTAssertNil(marker.lease.unavailableStage)
        marker.lease.publish(.init(stage: "observer_not_armed", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID()), trigger: "groq_reported_submission_error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.output.path))
        marker.lease.publish(.init(stage: "http_429", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID()), trigger: "groq_reported_submission_error")
        let markerRow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker.output)) as? [String: Any])
        XCTAssertEqual(markerRow.count, 15); XCTAssertNil(markerRow["setupReason"])
        XCTAssertEqual(markerRow["evidenceClass"] as? String, "page_world_observation")
        let retired = try setupLease()
        retired.lease.recordSetupReason(.controllerAbsent); retired.lease.revoke()
        retired.lease.recordObserverArmed(); retired.lease.recordSetupReason(.armTimeout)
        XCTAssertFalse(retired.lease.isCurrent); XCTAssertNil(retired.lease.unavailableStage)
        retired.lease.publish(.init(stage: "observer_unavailable", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID()), trigger: "groq_reported_submission_error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.output.path))
    }

    func testFailureProgressParserAdmitsOnlyClosedTypedContentFreeInspectionFacts() throws {
        typealias Lease = GroqOwnedStatusLease
        let expected: Set<String> = ["not_submitted", "cleared", "user_absent", "answer_absent", "text_empty",
            "editor_disabled", "editor_not_empty", "send_disabled", "footer_missing", "footer_shape", "footer_hidden",
            "copy_count", "copy_parent", "copy_disabled", "copy_icon_count", "complete"]
        XCTAssertEqual(Set(Lease.CompletionGate.allCases.map(\.rawValue)), expected)
        let canary = "PRIVATE_PROGRESS_TEXT_DO_NOT_EXPORT"
        func observation(_ complete: Bool = false) -> [String: Any] {
            ["userCount": 1, "responseCount": 1, "text": canary, "busy": !complete, "answerComplete": complete]
        }
        func raw(_ reason: String) -> [String: Any] { ["kind": "groq_completion_gate_v1", "reason": reason] }
        for gate in Lease.CompletionGate.allCases {
            let inspection = try XCTUnwrap(Lease.ProgressInspection.parse(raw(gate.rawValue), observed: observation(gate == .complete)))
            XCTAssertEqual(inspection.gate, gate); XCTAssertEqual(inspection.users, 1); XCTAssertEqual(inspection.answers, 1)
            XCTAssertEqual(inspection.textBytes, canary.utf8.count)
            XCTAssertEqual(inspection.answerComplete, gate == .complete); XCTAssertEqual(inspection.busy, gate != .complete)
            XCTAssertEqual(Set(inspection.fields.keys), ["gate", "users", "answers", "textBytes", "busy", "answerComplete"])
            let encoded = try JSONSerialization.data(withJSONObject: inspection.fields)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(canary))
        }
        let malformedRaw: [Any] = [NSNull(), ["kind": "foreign", "reason": "complete"],
            ["kind": "groq_completion_gate_v1", "reason": "PRIVATE_PROVIDER_ERROR"],
            ["kind": "groq_completion_gate_v1", "reason": "footer_missing", "body": canary],
            ["kind": "groq_completion_gate_v1"], ["kind": "groq_completion_gate_v1", "reason": 1] as [String: Any]]
        for value in malformedRaw {
            XCTAssertNil(Lease.ProgressInspection.parse(value, observed: observation()))
        }
        XCTAssertNil(Lease.ProgressInspection.parse(nil, observed: observation()))
        let malformed: [(String, Any)] = [("userCount", -1), ("userCount", 2), ("userCount", true), ("userCount", 0.5),
            ("responseCount", -1), ("responseCount", 2), ("responseCount", false), ("responseCount", "1"),
            ("text", NSNull()), ("busy", 1), ("busy", "true"), ("busy", false),
            ("answerComplete", 0), ("answerComplete", "false"), ("answerComplete", true)]
        for (key, value) in malformed {
            var changed = observation(); changed[key] = value
            XCTAssertNil(Lease.ProgressInspection.parse(raw("footer_missing"), observed: changed), key)
        }
        XCTAssertNil(Lease.ProgressInspection.parse(raw("complete"), observed: observation()))
        var huge = observation(); huge["text"] = canary + String(repeating: "🌍", count: 70_000)
        let bounded = try XCTUnwrap(Lease.ProgressInspection.parse(raw("footer_missing"), observed: huge))
        XCTAssertEqual(bounded.textBytes, 220_001, "The sentinel is a bounded UTF-8 count, never retained response text")
        var empty = observation(); empty["userCount"] = 0; empty["responseCount"] = 0; empty["text"] = ""
        XCTAssertNotNil(Lease.ProgressInspection.parse(raw("answer_absent"), observed: empty))
    }

    func testFailureProgressCacheBoundsCountersAgesAndUnknownInspectionWithoutCreatingCompletionProof() throws {
        typealias Lease = GroqOwnedStatusLease
        let now = ContinuousClock.now
        let inspection = try XCTUnwrap(Lease.ProgressInspection.parse(
            ["kind": "groq_completion_gate_v1", "reason": "footer_missing"],
            observed: ["userCount": 1, "responseCount": 1, "text": "PRIVATE_CACHE_TEXT", "busy": true, "answerComplete": false]))
        var cache = Lease.ProgressCache()
        let unknown = cache.snapshot(now: now, candidate: false, changed: now, quietSince: now)
        XCTAssertNil(unknown.inspection); XCTAssertNil(unknown.inspectionAgeMS)
        XCTAssertNil(unknown.readAgeMS); XCTAssertNil(unknown.waitAgeMS)
        XCTAssertNil(unknown.responseChangeAgeMS); XCTAssertNil(unknown.quietAgeMS)
        XCTAssertFalse(unknown.completionCandidate); XCTAssertTrue(unknown.fields["inspection"] is NSNull)
        cache.readStarted(now: now); cache.waitStarted(now: now); cache.admit(inspection, now: now)
        let active = cache.snapshot(now: now.advanced(by: .milliseconds(1234)), candidate: true, changed: now, quietSince: now)
        XCTAssertEqual(active.readsStarted, 1); XCTAssertEqual(active.readsReturned, 0); XCTAssertEqual(active.admittedReads, 1)
        XCTAssertEqual(active.waitsStarted, 1); XCTAssertEqual(active.waitsReturned, 0)
        XCTAssertEqual(active.inspectionAgeMS, 1234); XCTAssertEqual(active.readAgeMS, 1234); XCTAssertEqual(active.waitAgeMS, 1234)
        XCTAssertEqual(active.responseChangeAgeMS, 1234); XCTAssertEqual(active.quietAgeMS, 1234)
        XCTAssertEqual(active.inspection?.gate, .footerMissing); XCTAssertEqual(active.inspection?.answerComplete, false)
        cache.readReturned(); cache.waitReturned()
        let returned = cache.snapshot(now: now.advanced(by: .seconds(600)), candidate: false, changed: now, quietSince: now)
        XCTAssertEqual(returned.inspectionAgeMS, 300_000); XCTAssertEqual(returned.responseChangeAgeMS, 300_000)
        XCTAssertNil(returned.readAgeMS); XCTAssertNil(returned.waitAgeMS); XCTAssertNil(returned.quietAgeMS)
        XCTAssertEqual(Lease.ProgressCache.age(now.advanced(by: .seconds(1)), now: now), 0)
        XCTAssertNil(Lease.ProgressCache.age(nil, now: now))
        for _ in 0..<65_540 {
            cache.readStarted(now: now); cache.readReturned(); cache.waitStarted(now: now); cache.waitReturned()
            cache.admit(inspection, now: now)
        }
        let saturated = cache.snapshot(now: now.advanced(by: .seconds(600)), candidate: true, changed: now, quietSince: now)
        for count in [saturated.readsStarted, saturated.readsReturned, saturated.admittedReads, saturated.waitsStarted, saturated.waitsReturned] {
            XCTAssertEqual(count, 65_535)
        }
        XCTAssertEqual(saturated.quietAgeMS, 300_000)
        let fields = saturated.fields
        XCTAssertEqual(Set(fields.keys), ["kind", "inspection", "readsStarted", "readsReturned", "admittedReads", "waitsStarted",
            "waitsReturned", "inspectionAgeMS", "readAgeMS", "waitAgeMS", "responseChangeAgeMS", "quietAgeMS", "completionCandidate", "lastAttempt"])
        XCTAssertEqual(fields["kind"] as? String, "groq_failure_progress_v1")
        let encoded = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_CACHE_TEXT"))
        XCTAssertEqual(saturated.inspection?.answerComplete, false, "A native quiet candidate cannot promote an incomplete gate")
    }

    func testLatestAttemptOrdinalSeparatesAnEarlierUnrepresentedReadFromTheLastAdmittedRead() throws {
        typealias Lease = GroqOwnedStatusLease
        let now = ContinuousClock.now
        var cache = Lease.ProgressCache()
        XCTAssertNil(cache.beginAttempt(now: now))
        XCTAssertNil(cache.snapshot(now: now, candidate: false, changed: nil, quietSince: nil).lastAttempt)
        cache.readStarted(now: now)
        let earlier = try XCTUnwrap(cache.beginAttempt(now: now))
        cache.attemptReached(.evaluationReturned, for: earlier)
        cache.attemptAdmitted(earlier) // No validated ordinary read: cannot promote it.
        cache.attemptReturned(earlier, now: now.advanced(by: .milliseconds(100))); cache.readReturned()
        let rejected = try XCTUnwrap(cache.snapshot(now: now, candidate: false, changed: nil, quietSince: nil).lastAttempt)
        XCTAssertEqual(rejected.ordinal, 1); XCTAssertEqual(rejected.outcome, .unrepresented)
        XCTAssertEqual(rejected.phase, .evaluationReturned); XCTAssertNil(rejected.error)
        cache.readStarted(now: now.advanced(by: .milliseconds(200)))
        let latest = try XCTUnwrap(cache.beginAttempt(now: now.advanced(by: .milliseconds(200))))
        cache.attemptReached(.evaluationReturned, for: latest); cache.attemptReached(.decoded, for: latest)
        cache.attemptReached(.validated, for: latest)
        let inspection = try XCTUnwrap(Lease.ProgressInspection.parse(
            ["kind": "groq_completion_gate_v1", "reason": "answer_absent"],
            observed: ["userCount": 1, "responseCount": 0, "text": "", "busy": true, "answerComplete": false]))
        cache.admit(inspection, now: now.advanced(by: .milliseconds(240))); cache.attemptAdmitted(latest)
        cache.attemptReturned(latest, now: now.advanced(by: .milliseconds(400))); cache.readReturned()
        let snapshot = cache.snapshot(now: now.advanced(by: .milliseconds(500)), candidate: false, changed: now, quietSince: nil)
        let last = try XCTUnwrap(snapshot.lastAttempt)
        XCTAssertEqual(snapshot.readsStarted, 2); XCTAssertEqual(snapshot.readsReturned, 2); XCTAssertEqual(snapshot.admittedReads, 1)
        XCTAssertEqual(last.ordinal, 2); XCTAssertEqual(last.phase, .validated); XCTAssertEqual(last.outcome, .admitted)
        XCTAssertNil(last.error); XCTAssertEqual(last.startedAgeMS, 300); XCTAssertEqual(last.returnedAgeMS, 100)
        XCTAssertEqual(snapshot.inspection?.gate, .answerAbsent); XCTAssertEqual(snapshot.inspectionAgeMS, 260)
        XCTAssertFalse(snapshot.completionCandidate)
        XCTAssertEqual(Set(last.fields.keys), ["ordinal", "phase", "outcome", "error", "startedAgeMS", "returnedAgeMS"])
    }

    func testAttemptErrorIsClosedAndPreservesTheEarlierAdmittedInspection() throws {
        typealias Lease = GroqOwnedStatusLease
        typealias Failure = EmbeddedWebModelTransport.Failure
        let canary = "PRIVATE_ATTEMPT_ERROR_DO_NOT_EXPORT", now = ContinuousClock.now
        let errors: [(Error, String)] = [(CancellationError(), "cancelled"), (Failure.pageUnavailable, "page_unavailable"),
            (Failure.deadline, "deadline"), (Failure.preparationDeadline, "deadline"),
            (Failure.modelUnverified, "model_unverified"), (Failure.modelMismatch, "model_mismatch"),
            (Failure.ownershipFailure(.groqDraftRestored), "ownership"), (Failure.signInRequired, "native_refusal"),
            (NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSLocalizedDescriptionKey: canary]), "json_decode"),
            (NSError(domain: canary, code: 3840, userInfo: [NSLocalizedDescriptionKey: canary]), "other")]
        for (error, expected) in errors {
            XCTAssertEqual(EmbeddedWebModelTransport.groqFailureProgressAttemptError(error).rawValue, expected)
        }
        var cache = Lease.ProgressCache()
        let inspection = try XCTUnwrap(Lease.ProgressInspection.parse(
            ["kind": "groq_completion_gate_v1", "reason": "answer_absent"],
            observed: ["userCount": 1, "responseCount": 0, "text": "", "busy": true, "answerComplete": false]))
        cache.readStarted(now: now); let first = try XCTUnwrap(cache.beginAttempt(now: now))
        cache.attemptReached(.validated, for: first); cache.admit(inspection, now: now); cache.attemptAdmitted(first)
        cache.attemptReturned(first, now: now); cache.readReturned()
        cache.readStarted(now: now.advanced(by: .seconds(1)))
        let failed = try XCTUnwrap(cache.beginAttempt(now: now.advanced(by: .seconds(1))))
        cache.attemptReached(.evaluationReturned, for: failed); cache.attemptReached(.decoded, for: failed)
        cache.attemptFailed(failed, error: EmbeddedWebModelTransport.groqFailureProgressAttemptError(Failure.pageUnavailable))
        cache.attemptReturned(failed, now: now.advanced(by: .seconds(2))); cache.readReturned()
        cache.attemptReached(.validated, for: failed); cache.attemptAdmitted(failed) // A later callback cannot promote a terminal failure.
        let snapshot = cache.snapshot(now: now.advanced(by: .seconds(3)), candidate: false, changed: now, quietSince: nil)
        let last = try XCTUnwrap(snapshot.lastAttempt)
        XCTAssertEqual(last.ordinal, 2); XCTAssertEqual(last.phase, .decoded); XCTAssertEqual(last.outcome, .failed)
        XCTAssertEqual(last.error, .pageUnavailable); XCTAssertEqual(snapshot.inspection?.gate, .answerAbsent)
        XCTAssertEqual(snapshot.admittedReads, 1); XCTAssertEqual(snapshot.inspectionAgeMS, 3_000)
        XCTAssertEqual(last.startedAgeMS, 2_000); XCTAssertEqual(last.returnedAgeMS, 1_000)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: snapshot.fields), as: UTF8.self).contains(canary))
    }

    func testStaleAttemptTokensCannotRelabelANewerReadEvenWhenOrdinalsSaturate() throws {
        typealias Lease = GroqOwnedStatusLease
        let now = ContinuousClock.now
        var cache = Lease.ProgressCache(), foreign = Lease.ProgressCache()
        for _ in 0..<65_535 { cache.readStarted(now: now) }
        let earlier = try XCTUnwrap(cache.beginAttempt(now: now))
        cache.readStarted(now: now)
        let latest = try XCTUnwrap(cache.beginAttempt(now: now))
        foreign.readStarted(now: now); let alien = try XCTUnwrap(foreign.beginAttempt(now: now))
        XCTAssertEqual(earlier.ordinal, latest.ordinal); XCTAssertEqual(latest.ordinal, 65_535)
        for stale in [earlier, alien] {
            cache.attemptReached(.validated, for: stale); cache.attemptAdmitted(stale)
            cache.attemptFailed(stale, error: .ownership); cache.attemptReturned(stale, now: now)
        }
        let untouched = try XCTUnwrap(cache.snapshot(now: now, candidate: false, changed: nil, quietSince: nil).lastAttempt)
        XCTAssertEqual(untouched.phase, .evaluation); XCTAssertEqual(untouched.outcome, .inFlight)
        XCTAssertNil(untouched.error); XCTAssertNil(untouched.returnedAgeMS)
        cache.attemptReached(.decoded, for: latest); cache.attemptReached(.evaluationReturned, for: latest) // Phase cannot regress.
        cache.attemptReturned(latest, now: now.advanced(by: .seconds(1)))
        cache.attemptFailed(latest, error: .other) // Returned unrepresented is already terminal.
        let bounded = cache.snapshot(now: now.advanced(by: .seconds(600)), candidate: false, changed: nil, quietSince: nil)
        let last = try XCTUnwrap(bounded.lastAttempt)
        XCTAssertEqual(last.phase, .decoded); XCTAssertEqual(last.outcome, .unrepresented); XCTAssertNil(last.error)
        XCTAssertEqual(last.startedAgeMS, 300_000); XCTAssertEqual(last.returnedAgeMS, 300_000)
        XCTAssertNil(bounded.inspection); XCTAssertNil(bounded.inspectionAgeMS); XCTAssertEqual(bounded.readsStarted, 65_535)
    }

    func testNativeAttemptRetainsTheOriginalReadErrorBeforePollDeadlineMasking() async throws {
        try await run("nativeDeadline", expected: "no_matching_fetch_observed", profile: .gptoss120b,
                      fixture: true, fixtureKind: .gptoss120b, earlyPassive: true, maskReadFailure: true)
    }

    func testFailureProgressPublishesOnlyForCurrentEarlyFixtureAndCannotChangeItsFirstFailure() throws {
        typealias Lease = GroqOwnedStatusLease
        let fixture = try inspectorArm(purpose: Lease.FixtureTurn.earlyPassivePurpose)
        let parent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: fixture.directory, admission: fixture.admission,
            request: fixture.request, first: true, allowEarlyPassive: true))
        let lease = try XCTUnwrap(parent.child(admission: fixture.admission, request: fixture.request))
        XCTAssertTrue(lease.capturesFailureProgress)
        var cache = Lease.ProgressCache()
        let inspection = try XCTUnwrap(Lease.ProgressInspection.parse(
            ["kind": "groq_completion_gate_v1", "reason": "footer_missing"],
            observed: ["userCount": 1, "responseCount": 1, "text": "PRIVATE_FAILURE_PROGRESS", "busy": true, "answerComplete": false]))
        cache.readStarted(); cache.admit(inspection); cache.waitStarted()
        let now = ContinuousClock.now
        let progress = cache.snapshot(now: now, candidate: true, changed: now, quietSince: now)
        let observation = Lease.Observation(stage: "http_2xx_opened", sessionToken: UUID().uuidString.lowercased(),
            generation: UUID(), failureProgress: progress)
        lease.publish(observation, trigger: "response_deadline")
        let bytes = try Data(contentsOf: fixture.output)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(row.count, 16); XCTAssertEqual(row["stage"] as? String, "http_2xx_opened")
        XCTAssertEqual(row["purpose"] as? String, Lease.FixtureTurn.earlyPassivePurpose)
        let saved = try XCTUnwrap(row["failureProgress"] as? [String: Any])
        XCTAssertEqual(saved["kind"] as? String, "groq_failure_progress_v1")
        let savedInspection = try XCTUnwrap(saved["inspection"] as? [String: Any])
        XCTAssertEqual(savedInspection["gate"] as? String, "footer_missing"); XCTAssertEqual(savedInspection["answerComplete"] as? Bool, false)
        for secret in ["PRIVATE_FAILURE_PROGRESS", "http://127.0.0.1"] {
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
        }
        lease.publish(.init(stage: "http_429", sessionToken: observation.sessionToken, generation: observation.generation,
            failureProgress: nil), trigger: "groq_reported_submission_error")
        XCTAssertEqual(try Data(contentsOf: fixture.output), bytes)
        XCTAssertFalse(lease.capturesFailureProgress)
        for isFixture in [false, true] {
            let ordinary = try setupLease(fixture: isFixture)
            XCTAssertFalse(ordinary.lease.capturesFailureProgress)
            ordinary.lease.publish(observation, trigger: "response_deadline")
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ordinary.output)) as? [String: Any])
            XCTAssertEqual(value.count, 15); XCTAssertNil(value["failureProgress"])
        }
        let absent = try inspectorArm(purpose: Lease.FixtureTurn.earlyPassivePurpose)
        let absentParent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: absent.directory, admission: absent.admission,
            request: absent.request, first: true, allowEarlyPassive: true))
        let absentChild = try XCTUnwrap(absentParent.child(admission: absent.admission, request: absent.request))
        absentChild.publish(.init(stage: "http_2xx_opened", sessionToken: observation.sessionToken,
            generation: observation.generation), trigger: "response_deadline")
        let absentRow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: absent.output)) as? [String: Any])
        XCTAssertEqual(absentRow.count, 15); XCTAssertNil(absentRow["failureProgress"], "Missing diagnostics remain optional")
        let retired = try inspectorArm(purpose: Lease.FixtureTurn.earlyPassivePurpose)
        let retiredParent = try XCTUnwrap(Lease.FixtureTurn.consume(directory: retired.directory, admission: retired.admission,
            request: retired.request, first: true, allowEarlyPassive: true))
        let child = try XCTUnwrap(retiredParent.child(admission: retired.admission, request: retired.request))
        retiredParent.revoke(); XCTAssertFalse(child.capturesFailureProgress)
        child.publish(observation, trigger: "response_deadline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.output.path))
    }

    private func setupLease(fixture: Bool = true) throws -> (lease: GroqOwnedStatusLease, output: URL, user: String) {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("groq-setup-" + UUID().uuidString)
        let directory = root.appendingPathComponent(GroqOwnedStatusLease.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let kind = GroqOwnedStatusLease.FixtureTurn.Kind.gptoss120b, nonce = UUID(), model = kind.profile.choice.modelID
        let user = fixture ? Self.fixtureUser.replacingOccurrences(of: "groq-qwen27b", with: "groq-gptoss120b") : GroqOwnedStatusLease.userText(nonce)
        func item(_ role: String, _ text: String) -> [String: Any] {
            ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        }
        let input = [item("developer", "Synthetic policy"),
            item("user", "<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
            item("user", user + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())]
        let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: ["model": model, "input": input,
            "tools": [["type": "function", "name": "fixture_read", "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false]]]]))
        let admission = WebModelStartAdmission(id: UUID(), inferenceID: UUID(), taskID: UUID().uuidString.lowercased(),
            threadID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased(), runtimeGeneration: UUID(),
            preparationID: UUID(), transportGeneration: UUID(), provider: "groq", modelID: model, parameters: Data("{}".utf8))
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let arm: [String: String] = ["purpose": fixture ? kind.purpose : kind.profile.purpose,
            "nonce": nonce.uuidString.lowercased(), "modelID": model, "userPromptSHA256": GroqOwnedStatusLease.digest(user),
            "expiresAt": formatter.string(from: Date().addingTimeInterval(60))]
        let armURL = directory.appendingPathComponent("arm.json")
        try JSONSerialization.data(withJSONObject: arm).write(to: armURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: armURL.path)
        let lease: GroqOwnedStatusLease
        if fixture {
            let parent = try XCTUnwrap(GroqOwnedStatusLease.FixtureTurn.consume(directory: directory, admission: admission,
                request: request, first: true))
            lease = try XCTUnwrap(parent.child(admission: admission, request: request))
        } else {
            lease = try XCTUnwrap(GroqOwnedStatusLease.consume(directory: directory, admission: admission, request: request, first: true))
        }
        return (lease, directory.appendingPathComponent("owned-status.json"), user)
    }

    func testLateArmPreservesTheWebsiteFetchWrapperAndTracksOnlyOneOwnedRequest() async throws {
        try await run("siteWrapper", expected: "transport_rejected", profile: .qwen27b, fixture: true, fixtureKind: .qwen27b)
        try await run("siteWrapper", expected: "transport_rejected", profile: .gptoss120b, fixture: true, fixtureKind: .gptoss120b)
    }

    func testEarlyPassiveLeaseRequiresItsPrivate120BPurposeAndNativeHistoryOptIn() throws {
        for refusal in ["disabled","notFirst","wrongModel","hash","purpose","extraKey","expired","tooLong","publicArm"] {
            let fixture = try inspectorArm(kind:refusal == "wrongModel" ? .qwen27b : .gptoss120b,
                purpose:GroqOwnedStatusLease.FixtureTurn.earlyPassivePurpose,mutation:refusal,
                expiresIn:refusal == "expired" ? -1 : refusal == "tooLong" ? 601 : 60)
            XCTAssertNil(GroqOwnedStatusLease.FixtureTurn.consume(directory:fixture.directory,
                admission:fixture.admission,request:fixture.request,first:refusal != "notFirst",
                allowEarlyPassive:refusal != "disabled"),refusal)
            XCTAssertTrue(FileManager.default.fileExists(atPath:fixture.directory.appendingPathComponent("arm.json").path),refusal)
            XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.output.path),refusal)
        }
        let fixture = try inspectorArm(purpose:GroqOwnedStatusLease.FixtureTurn.earlyPassivePurpose)
        let parent = try XCTUnwrap(GroqOwnedStatusLease.FixtureTurn.consume(directory:fixture.directory,
            admission:fixture.admission,request:fixture.request,first:true,allowEarlyPassive:true))
        XCTAssertEqual(parent.publicationPurpose,GroqOwnedStatusLease.FixtureTurn.earlyPassivePurpose)
        let first = try XCTUnwrap(parent.child(admission:fixture.admission,request:fixture.request))
        XCTAssertEqual(first.installationMode,.earlyPassive);XCTAssertNil(first.inspectorOrdinal)
        let callbacks = GroqManualInspectorCounter()
        XCTAssertTrue(first.onEarlyObserverRevocation { callbacks.increment() })
        XCTAssertFalse(first.onEarlyObserverRevocation { callbacks.increment() },"The callback cannot be replaced")
        XCTAssertNil(first.bindInspector(view:ObjectIdentifier(NSObject()),ownerToken:UUID().uuidString,generation:UUID()))
        let handoff = try inspectorContinuation(fixture.request)
        let nextAdmission = inspectorAdmission(after:fixture.admission)
        XCTAssertNil(parent.child(admission:nextAdmission,request:handoff.next),"A bare matching context is not a closed native handoff")
        first.revoke();first.revoke()
        XCTAssertEqual(callbacks.value,1);XCTAssertTrue(parent.isCurrent)
        let next = try XCTUnwrap(parent.child(admission:nextAdmission,request:handoff.next,
            closedInferenceID:fixture.admission.inferenceID,closedContinuation:handoff.closed))
        XCTAssertEqual(next.installationMode,.earlyPassive);XCTAssertNil(next.inspectorOrdinal)
        XCTAssertTrue(next.onEarlyObserverRevocation { callbacks.increment() })
        parent.revoke();parent.revoke()
        XCTAssertFalse(next.isCurrent);XCTAssertEqual(callbacks.value,2)
        let legacy = try setupLease()
        XCTAssertEqual(legacy.lease.installationMode,.late)
        XCTAssertFalse(legacy.lease.onEarlyObserverRevocation { callbacks.increment() })
        legacy.lease.revoke();XCTAssertEqual(callbacks.value,2)
    }

    func testEarlyPassiveFixtureObservesTheSDKFetchCachedBeforeNativeArm() async throws {
        try await run("cachedSDK", expected: "transport_rejected", profile: .gptoss120b,
            fixture: true, fixtureKind: .gptoss120b, earlyPassive: true)
        try await run("cachedSDK", expected: "transport_rejected", profile: .gptoss120b,
            fixture: true, continuation: true, fixtureKind: .gptoss120b, earlyPassive: true)
    }

    func testEarlyPassivePurposeDoesNotBroadenLateModeOrNativeFailurePublication() async throws {
        try await run("cachedSDK", expected: "no_matching_fetch_observed", profile: .gptoss120b,
            fixture: true, fixtureKind: .gptoss120b)
        try await run("wrongFixture", expected: "none", profile: .gptoss120b,
            fixture: true, fixtureKind: .gptoss120b, earlyPassive: true)
        try await run("retiredDuringRead", expected: "none", profile: .gptoss120b,
            fixture: true, fixtureKind: .gptoss120b, earlyPassive: true)
    }

    func testManualInspectorRequiresPrivateExact120BFixtureAndExplicitNativeOptIn() throws {
        for refusal in ["disabled", "notFirst", "wrongModel", "hash", "purpose", "extraKey", "expired", "tooLong", "publicArm"] {
            let fixture = try inspectorArm(kind: refusal == "wrongModel" ? .qwen27b : .gptoss120b,
                mutation: refusal, expiresIn: refusal == "expired" ? -1 : refusal == "tooLong" ? 601 : 60)
            XCTAssertNil(GroqOwnedStatusLease.FixtureTurn.consume(directory: fixture.directory, admission: fixture.admission,
                request: fixture.request, first: refusal != "notFirst", allowManualInspector: refusal != "disabled"), refusal)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("arm.json").path), refusal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path), refusal)
        }
        let fixture = try inspectorArm()
        let parent = try inspectorParent(fixture)
        XCTAssertEqual(parent.publicationPurpose, GroqOwnedStatusLease.FixtureTurn.inspectorPurpose)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("arm.json").path))
        XCTAssertNil(GroqOwnedStatusLease.FixtureTurn.consume(directory: fixture.directory, admission: fixture.admission,
            request: fixture.request, first: true, allowManualInspector: true), "The private arm is consumed only once")
        let status = try inspectorArm(purpose: GroqOwnedStatusLease.FixtureTurn.Kind.gptoss120b.purpose)
        let statusParent = try inspectorParent(status)
        let statusChild = try XCTUnwrap(statusParent.child(admission: status.admission, request: status.request))
        let view = NSObject()
        XCTAssertNil(statusChild.inspectorOrdinal)
        XCTAssertNil(statusChild.bindInspector(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: UUID()))
        let marker = try setupLease(fixture: false)
        XCTAssertNil(marker.lease.bindInspector(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: UUID()))
        parent.revoke(); statusParent.revoke()
    }

    func testManualInspectorRequiresValidatedClosedHandoffsAndIssuesOnlyChildrenTwoThroughFour() throws {
        let fixture = try inspectorArm(), parent = try inspectorParent(fixture)
        let first = try XCTUnwrap(parent.child(admission: fixture.admission, request: fixture.request))
        XCTAssertNil(first.inspectorOrdinal)
        let view = NSObject()
        XCTAssertNil(first.bindInspector(view: ObjectIdentifier(view), ownerToken: UUID().uuidString, generation: UUID()))
        XCTAssertNil(parent.child(admission: fixture.admission, request: fixture.request))
        let step = try inspectorContinuation(fixture.request)
        let nextAdmission = inspectorAdmission(after: fixture.admission)
        XCTAssertNil(parent.child(admission: nextAdmission, request: step.next, closedInferenceID: fixture.admission.inferenceID))
        XCTAssertNil(parent.child(admission: nextAdmission, request: step.next, closedInferenceID: UUID(), closedContinuation: step.closed))
        for field in ["task", "thread", "turn", "runtime", "preparation", "transport", "provider", "model"] {
            XCTAssertNil(parent.child(admission: inspectorAdmission(after: fixture.admission, changing: field), request: step.next,
                closedInferenceID: fixture.admission.inferenceID, closedContinuation: step.closed), field)
        }
        var changedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: step.next.continuationRequest) as? [String: Any])
        var changedInput = try XCTUnwrap(changedRoot["input"] as? [[String: Any]])
        changedInput[0] = ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Changed governing policy"]]]
        changedRoot["input"] = changedInput
        let changedRequest = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: changedRoot))
        XCTAssertNil(parent.child(admission: nextAdmission, request: changedRequest,
            closedInferenceID: fixture.admission.inferenceID, closedContinuation: step.closed))
        let finalBytes = try WebModelResponseCodec.completedResponse(for: .message("Synthetic final"), request: fixture.request)
        let final = try WebsiteTurnContinuation(request: fixture.request, encodedResponse: finalBytes)
        XCTAssertEqual(final.pendingToolCallCount, 0)
        XCTAssertNil(parent.child(admission: nextAdmission, request: step.next,
            closedInferenceID: fixture.admission.inferenceID, closedContinuation: final))
        first.revoke() // Successful physical-view cleanup cannot retire the native fixture parent.
        XCTAssertTrue(parent.isCurrent)
        let winners = GroqManualInspectorLeaseResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let child = parent.child(admission: nextAdmission, request: step.next,
                closedInferenceID: fixture.admission.inferenceID, closedContinuation: step.closed) { winners.append(child) }
        }
        XCTAssertEqual(winners.values.count, 1)
        let second = try XCTUnwrap(winners.values.first)
        XCTAssertEqual(second.inspectorOrdinal, 2)
        var previous = nextAdmission, request = step.next
        var retained = [second]
        for ordinal in 3...4 {
            let next = try inspectorContinuation(request), admission = inspectorAdmission(after: previous)
            let child = try XCTUnwrap(parent.child(admission: admission, request: next.next,
                closedInferenceID: previous.inferenceID, closedContinuation: next.closed))
            XCTAssertEqual(child.inspectorOrdinal, ordinal)
            retained.append(child); previous = admission; request = next.next
        }
        let fifth = try inspectorContinuation(request)
        XCTAssertNil(parent.child(admission: inspectorAdmission(after: previous), request: fifth.next,
            closedInferenceID: previous.inferenceID, closedContinuation: fifth.closed))
        parent.revoke()
        XCTAssertTrue(retained.allSatisfy { !$0.isCurrent })
    }

    func testManualInspectorBindingIsExactOnceOnlyAndInspectorRevocationDoesNotGrantOtherAuthority() async throws {
        let fixture = try inspectorArm(), parent = try inspectorParent(fixture)
        let first = try XCTUnwrap(parent.child(admission: fixture.admission, request: fixture.request))
        let step = try inspectorContinuation(fixture.request), admission = inspectorAdmission(after: fixture.admission)
        let child = try XCTUnwrap(parent.child(admission: admission, request: step.next,
            closedInferenceID: fixture.admission.inferenceID, closedContinuation: step.closed))
        let view = NSObject(), other = NSObject(), owner = UUID().uuidString, generation = UUID()
        let identity = ObjectIdentifier(view)
        XCTAssertNil(child.bindInspector(view: identity, ownerToken: "not-a-native-owner", generation: generation))
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return child.bindInspector(view: identity, ownerToken: owner, generation: generation) == nil
        }
        let cancelledRefused = await cancelled.value
        XCTAssertTrue(cancelledRefused)
        let bindings = GroqManualInspectorBindingResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let binding = child.bindInspector(view: identity, ownerToken: owner, generation: generation) { bindings.append(binding) }
        }
        XCTAssertEqual(bindings.values.count, 1)
        let binding = try XCTUnwrap(bindings.values.first), callbacks = GroqManualInspectorCounter()
        for mismatch in ["view", "owner", "generation"] {
            XCTAssertFalse(binding.activate(view: mismatch == "view" ? ObjectIdentifier(other) : identity,
                ownerToken: mismatch == "owner" ? UUID().uuidString : owner,
                generation: mismatch == "generation" ? UUID() : generation,
                onRevocation: { callbacks.increment() }, action: { callbacks.increment() }), mismatch)
        }
        XCTAssertEqual(callbacks.value, 0)
        XCTAssertTrue(binding.activate(view: identity, ownerToken: owner, generation: generation,
            onRevocation: { if child.isCurrent { callbacks.increment() } }, action: { callbacks.increment() }))
        XCTAssertFalse(binding.activate(view: identity, ownerToken: owner, generation: generation,
            onRevocation: {}, action: { callbacks.increment() }))
        XCTAssertEqual(callbacks.value, 1)
        binding.revoke(); binding.revoke()
        XCTAssertEqual(callbacks.value, 2, "The revocation callback runs once, outside the lease lock")
        XCTAssertTrue(child.isCurrent, "Inspector-only revocation is not model evidence or cleanup authority")
        XCTAssertTrue(parent.isCurrent); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertNil(child.bindInspector(view: identity, ownerToken: owner, generation: generation))
        XCTAssertFalse(binding.activate(view: identity, ownerToken: owner, generation: generation, onRevocation: {}, action: {}))
        child.revoke(); first.revoke(); parent.revoke()
        XCTAssertFalse(child.isCurrent)
    }

    func testManualInspectorFirstFailurePublishesWithinABoundAndRevokesEveryActiveChild() async throws {
        let fixture = try inspectorArm(), parent = try inspectorParent(fixture)
        let first = try XCTUnwrap(parent.child(admission: fixture.admission, request: fixture.request))
        var previous = fixture.admission, request = fixture.request
        var children: [GroqOwnedStatusLease] = [], bindings: [GroqOwnedStatusLease.InspectorBinding] = []
        let view = NSObject(), owner = UUID().uuidString, generation = UUID(), revoked = GroqManualInspectorCounter()
        for _ in 2...4 {
            let step = try inspectorContinuation(request), admission = inspectorAdmission(after: previous)
            let child = try XCTUnwrap(parent.child(admission: admission, request: step.next,
                closedInferenceID: previous.inferenceID, closedContinuation: step.closed))
            let binding = try XCTUnwrap(child.bindInspector(view: ObjectIdentifier(view), ownerToken: owner, generation: generation))
            XCTAssertTrue(binding.activate(view: ObjectIdentifier(view), ownerToken: owner, generation: generation,
                onRevocation: { if !child.isCurrent { revoked.increment() } }, action: {}))
            children.append(child); bindings.append(binding); previous = admission; request = step.next
        }
        let publishing = try XCTUnwrap(children.last), terminalAdmission = previous
        let observation = GroqOwnedStatusLease.Observation(stage: "http_429", sessionToken: UUID().uuidString.lowercased(), generation: generation)
        let completed = expectation(description: "First failure publishes without re-entering its child lock")
        let returned = GroqManualInspectorCounter()
        DispatchQueue.global().async {
            publishing.publish(observation, trigger: "groq_reported_submission_error")
            returned.increment(); completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        guard returned.value == 1 else { return } // A lock regression must fail finitely; never acquire its held locks below.
        XCTAssertEqual(revoked.value, 3)
        XCTAssertFalse(parent.isCurrent); XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(children.allSatisfy { !$0.isCurrent })
        for binding in bindings {
            XCTAssertFalse(binding.activate(view: ObjectIdentifier(view), ownerToken: owner, generation: generation, onRevocation: {}, action: {}))
        }
        let bytes = try Data(contentsOf: fixture.output)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(row.count, 15)
        XCTAssertEqual(row["purpose"] as? String, GroqOwnedStatusLease.FixtureTurn.inspectorPurpose)
        XCTAssertEqual(row["inferenceID"] as? String, terminalAdmission.inferenceID.uuidString.lowercased())
        XCTAssertEqual(row["stage"] as? String, "http_429")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(Self.fixtureUser.replacingOccurrences(of: "groq-qwen27b", with: "groq-gptoss120b")))
        publishing.publish(.init(stage: "http_400", sessionToken: observation.sessionToken, generation: generation), trigger: "response_deadline")
        XCTAssertEqual(try Data(contentsOf: fixture.output), bytes)
    }

    func testManualInspectorBrowserRequiresExactOwned120BViewAndRevokesOnEveryLifecycle() async throws {
        for lifecycle in ["finish", "reload", "navigation", "close", "shutdown", "nativeContext", "expiry"] {
            let fixture = try inspectorArm(expiresIn: lifecycle == "expiry" ? 3 : 60), parent = try inspectorParent(fixture)
            let first = try XCTUnwrap(parent.child(admission: fixture.admission, request: fixture.request))
            let step = try inspectorContinuation(fixture.request), admission = inspectorAdmission(after: fixture.admission)
            let child = try XCTUnwrap(parent.child(admission: admission, request: step.next,
                closedInferenceID: fixture.admission.inferenceID, closedContinuation: step.closed))
            let browser = EmbeddedBrowserSession(persistent: false)
            defer { browser.shutdown(); parent.revoke(); first.revoke() }
            let tab = try browser.createUnloadedModelTabForTesting { InspectorView(frame: .zero, configuration: $0) }
            let view = try XCTUnwrap(browser.webView(for: tab) as? InspectorView)
            let generation = try XCTUnwrap(browser.documentGeneration(for: tab)), owner = UUID().uuidString
            view.navigationDelegate = nil
            try browser.installModelChangeSignal(tabID: tab, ownerToken: owner, world: .world(name: "computa-groq-inspector-fixture"), originHost: "chat.groq.com")
            let binding = try XCTUnwrap(child.bindInspector(view: ObjectIdentifier(view), ownerToken: owner, generation: generation))
            let human = try browser.createTab(), humanView = try XCTUnwrap(browser.webView(for: human))
            for failure in ["view", "tab", "owner", "generation", "origin", "model"] {
                if failure == "origin" { view.observedURL = URL(string: "https://example.invalid/") }
                if failure == "model" { view.observedURL = EmbeddedWebModelTransport.Provider.groq.startURL(choice: GroqOwnedStatusLease.Profile.qwen27b.choice) }
                XCTAssertFalse(browser.grantGroqFixtureInspectorDiagnostic(binding, tabID: failure == "tab" ? human : tab,
                    view: failure == "view" ? humanView : view, ownerToken: failure == "owner" ? UUID().uuidString : owner,
                    generation: failure == "generation" ? UUID() : generation), failure)
                view.observedURL = EmbeddedWebModelTransport.Provider.groq.startURL(choice: GroqOwnedStatusLease.Profile.gptoss120b.choice)
                XCTAssertFalse(view.isInspectable)
            }
            XCTAssertFalse(browser.canInspect(tabID: tab))
            XCTAssertThrowsError(try browser.setWebInspectorEnabled(true, for: tab))
            XCTAssertTrue(browser.grantGroqFixtureInspectorDiagnostic(binding, tabID: tab, view: view, ownerToken: owner, generation: generation))
            XCTAssertTrue(view.isInspectable); XCTAssertFalse(humanView.isInspectable)
            XCTAssertFalse(browser.canInspect(tabID: tab))
            XCTAssertFalse(try XCTUnwrap(browser.tabs.first(where: { $0.id == tab })).isWebInspectorEnabled)
            XCTAssertFalse(browser.grantGroqFixtureInspectorDiagnostic(binding, tabID: tab, view: view, ownerToken: owner, generation: generation))
            switch lifecycle {
            case "finish":
                browser.revokeGroqFixtureInspectorDiagnostic(tabID: tab, ownerToken: UUID().uuidString)
                XCTAssertTrue(view.isInspectable)
                browser.revokeGroqFixtureInspectorDiagnostic(tabID: tab, ownerToken: owner)
            case "reload": browser.reload(tabID: tab)
            case "navigation": try browser.navigate(tabID: tab, to: XCTUnwrap(URL(string: "about:blank")))
            case "close": browser.closeTab(tab)
            case "shutdown": browser.shutdown()
            case "nativeContext": parent.revoke()
            default: break // Expiry has its own monotonic timer; no page or clock mutation.
            }
            let deadline = ContinuousClock.now + .seconds(lifecycle == "expiry" ? 4 : 2)
            while view.isInspectable && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(view.isInspectable, lifecycle)
            XCTAssertFalse(browser.grantGroqFixtureInspectorDiagnostic(binding, tabID: tab, view: view, ownerToken: owner, generation: generation), lifecycle)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path), "Inspection never supplies failure, completion or cleanup evidence")
        }
    }

    private final class InspectorView: WKWebView {
        var observedURL: URL? = EmbeddedWebModelTransport.Provider.groq.startURL(choice: GroqOwnedStatusLease.Profile.gptoss120b.choice)
        override var url: URL? { observedURL }
        override func load(_ request: URLRequest) -> WKNavigation? { nil }
        override func reload() -> WKNavigation? { nil }
    }
    private func inspectorArm(kind: GroqOwnedStatusLease.FixtureTurn.Kind = .gptoss120b, purpose: String? = nil,
                              mutation: String = "", expiresIn: TimeInterval = 60) throws -> GroqManualInspectorArm {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(path) }
        let directory = URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("groq-manual-inspector-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = kind.profile.choice.modelID
        let user = kind == .gptoss120b ? Self.fixtureUser.replacingOccurrences(of: "groq-qwen27b", with: "groq-gptoss120b") : Self.fixtureUser
        func item(_ role: String, _ text: String) -> [String: Any] {
            ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        }
        let request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: ["model": model, "stream": false,
            "input": [item("developer", "Synthetic policy"), item("user", "<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
                item("user", user + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())],
            "tools": [["type": "function", "name": "fixture_read", "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false]]]]))
        let admission = WebModelStartAdmission(id: UUID(), inferenceID: UUID(), taskID: UUID().uuidString.lowercased(),
            threadID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased(), runtimeGeneration: UUID(),
            preparationID: UUID(), transportGeneration: UUID(), provider: "groq", modelID: model, parameters: Data("{}".utf8))
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = ["purpose": purpose ?? GroqOwnedStatusLease.FixtureTurn.inspectorPurpose, "nonce": UUID().uuidString.lowercased(),
            "modelID": model, "userPromptSHA256": GroqOwnedStatusLease.digest(user), "expiresAt": formatter.string(from: Date().addingTimeInterval(expiresIn))]
        if mutation == "hash" { fields["userPromptSHA256"] = GroqOwnedStatusLease.digest("A different fixture") }
        if mutation == "purpose" { fields["purpose"] = "groq_unknown_inspector_purpose" }
        if mutation == "extraKey" { fields["scope"] = "foreign" }
        let arm = directory.appendingPathComponent("arm.json")
        try JSONSerialization.data(withJSONObject: fields).write(to: arm)
        try FileManager.default.setAttributes([.posixPermissions: mutation == "publicArm" ? 0o644 : 0o600], ofItemAtPath: arm.path)
        return .init(directory: directory, output: directory.appendingPathComponent("owned-status.json"), admission: admission, request: request)
    }
    private func inspectorParent(_ fixture: GroqManualInspectorArm) throws -> GroqOwnedStatusLease.FixtureTurn {
        try XCTUnwrap(GroqOwnedStatusLease.FixtureTurn.consume(directory: fixture.directory, admission: fixture.admission,
            request: fixture.request, first: true, allowManualInspector: true))
    }
    private func inspectorAdmission(after first: WebModelStartAdmission, changing field: String = "") -> WebModelStartAdmission {
        .init(id: UUID(), inferenceID: UUID(), taskID: field == "task" ? UUID().uuidString.lowercased() : first.taskID,
            threadID: field == "thread" ? UUID().uuidString.lowercased() : first.threadID,
            turnID: field == "turn" ? UUID().uuidString.lowercased() : first.turnID,
            runtimeGeneration: field == "runtime" ? UUID() : first.runtimeGeneration,
            preparationID: field == "preparation" ? UUID() : first.preparationID,
            transportGeneration: field == "transport" ? UUID() : first.transportGeneration,
            provider: field == "provider" ? "qwen" : first.provider,
            modelID: field == "model" ? GroqOwnedStatusLease.Profile.qwen27b.choice.modelID : first.modelID, parameters: first.parameters)
    }
    private func inspectorContinuation(_ request: WebModelResponseCodec.Request) throws -> (closed: WebsiteTurnContinuation, next: WebModelResponseCodec.Request) {
        let encoded = try WebModelResponseCodec.completedResponse(for: .toolCalls([.init(name: "fixture_read", argumentsJSON: "{}", namespace: nil)]), request: request)
        let closed = try WebsiteTurnContinuation(request: request, encodedResponse: encoded)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let calls = try XCTUnwrap(response["output"] as? [[String: Any]])
        let callID = try XCTUnwrap(calls.first?["call_id"] as? String)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: request.continuationRequest) as? [String: Any])
        var input = try XCTUnwrap(root["input"] as? [[String: Any]])
        input += calls + [["type": "function_call_output", "call_id": callID, "output": "Synthetic native read result"]]
        root["input"] = input
        let next = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]))
        try closed.validate(next: next)
        return (closed, next)
    }

    private static let fixtureUser = """
        In /tmp/test root/fixtures/cases/invoice-457-groq-qwen27b-0123456789abcdef/coding, fix the invoice aggregation bug in reconcile.py according to its README. Keep the tests, sample data, and reference format unchanged. Run python3 -m unittest -v, then run python3 reconcile.py.

        Use the built-in browser to open http://127.0.0.1:50473/, enter the printed reference, and submit it once. Read the resulting receipt, then close the tab you opened. Use browser tools for the website; do not use terminal HTTP requests or inspect the fixture's control directory, server source, or receipt files.

        Return the test result, the reference, and the receipt shown by the page.
        """

    private func run(_ mode:String,expected:String,profile:GroqOwnedStatusLease.Profile = .gptoss20b,
                     fixture:Bool=false,continuation:Bool=false,customHistory:Bool=false,
                     fixtureKind:GroqOwnedStatusLease.FixtureTurn.Kind?=nil,earlyPassive:Bool=false,maskReadFailure:Bool=false) async throws {
        let path=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(path)}
        let tmp=URL(fileURLWithPath:String(cString:path),isDirectory:true).appendingPathComponent("groq-status-"+UUID().uuidString)
        let directory=tmp.appendingPathComponent(GroqOwnedStatusLease.directoryName)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:tmp)}
        let kind=fixtureKind ?? .qwen27b
        let controlledUser=kind == .gptoss120b ? Self.fixtureUser.replacingOccurrences(of:"groq-qwen27b",with:"groq-gptoss120b") : Self.fixtureUser
        let nonce=UUID(),user=fixture ? controlledUser + (mode=="wrongFixture" ? " Extra prose." : "") : GroqOwnedStatusLease.userText(nonce),model=profile.choice
        let armProfile:GroqOwnedStatusLease.Profile = mode=="wrongProfile" ? .gptoss20b : profile
        let output=directory.appendingPathComponent("owned-status.json"),arm=directory.appendingPathComponent("arm.json")
        let date=ISO8601DateFormatter();date.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let fixturePurpose=earlyPassive ? GroqOwnedStatusLease.FixtureTurn.earlyPassivePurpose : mode=="crossFixturePurpose"
            ? (kind == .qwen27b ? GroqOwnedStatusLease.FixtureTurn.Kind.gptoss120b.purpose : GroqOwnedStatusLease.FixtureTurn.Kind.qwen27b.purpose)
            : kind.purpose
        let purpose=fixture && !["wrongProfile","wrongPurpose"].contains(mode) ? fixturePurpose : armProfile.purpose
        let data:[String:String]=["nonce":nonce.uuidString.lowercased(),"purpose":purpose,"modelID":armProfile.choice.modelID,
            "userPromptSHA256":GroqOwnedStatusLease.digest(mode=="wrongNonce" ? "different" : user),"expiresAt":date.string(from:Date().addingTimeInterval(80))]
        if mode != "unarmed" {
            try JSONSerialization.data(withJSONObject:data).write(to:arm)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:arm.path)
        }
        let fixtureURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/groq-chat.html")
        let html=try String(contentsOf:fixtureURL,encoding:.utf8)
        let browser = EmbeddedBrowserSession(persistent:false)
        let window = Window(contentRect:NSRect(x:20,y:20,width:1024,height:768),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=EmbeddedModelRenderContainer(session:browser);host.frame=window.contentView!.bounds
        window.contentView=host;browser.installModelRenderHost(host);window.orderBack(nil)
        defer { browser.shutdown();host.detach();window.orderOut(nil);window.close() }
        let human=try browser.createTab()
        var view:LocalView?
        var pages:[LocalView]=[]
        browser.setModelViewFactoryForTesting { config in
            let source=(mode == "cachedSDK"
                ? "window.fetch=function(){'use strict';window.requests=(window.requests||0)+1;window.groqBaseReceiver=this;window.groqBaseArgs=Array.from(arguments);const result=['tool','patch','success'].includes(window.variant)?new Promise(()=>{}):Promise.reject(Error('synthetic'));window.groqBasePromise=result;return result;};window.groqBaseFetch=window.fetch;"
                : mode == "siteWrapper"
                ? "window.fetch=function(){window.requests=(window.requests||0)+1;window.groqBaseReceiver=this;window.groqBaseArgs=Array.from(arguments);const result=Promise.reject(Error('synthetic'));window.groqBasePromise=result;return result;}"
                : "window.fetch=function(){window.requests=(window.requests||0)+1;return ['rollback','observerNotArmed','observerUnavailable'].includes(window.variant)?Promise.reject(Error('synthetic')):new Promise(()=>{})}")
                + (mode=="observerNotArmed" ? ";Object.defineProperty(window,'fetch',{writable:false})" : "")
            let stub = WKUserScript(source:source,
                                    injectionTime:.atDocumentStart,forMainFrameOnly:true,in:.page)
            config.userContentController.addUserScript(stub)
            let created=LocalView(frame:.init(x:0,y:0,width:1024,height:768),configuration:config)
            let variant=continuation && pages.isEmpty ? (customHistory ? "patch" : "tool") : mode
            let siteWrapper = mode == "siteWrapper" ? """
                window.groqSawNoEarlyObserver=!Object.getOwnPropertyNames(window).some(key=>key.startsWith('__computaGroqStatus_'));
                const groqSiteBase=window.fetch;
                window.groqSiteWrapper=function(...args){window.groqSiteCalls=(window.groqSiteCalls||0)+1;
                  window.groqSiteReceiver=this;window.groqSiteArgs=args;
                  const result=Reflect.apply(groqSiteBase,this,args);window.groqSitePromise=result;return result;};
                window.fetch=window.groqSiteWrapper;
                """ : ""
            let cachedSDK = mode == "cachedSDK" ? """
                window.groqEarlyObserverPresent=Object.getOwnPropertyNames(window).some(key=>key.startsWith('__computaGroqStatus_'));
                window.groqCachedFetch=window.fetch;
                window.groqCachedReceiver=Object.freeze({synthetic:true});
                const groqSiteBase=window.fetch;
                window.groqSiteWrapper=function(...args){window.groqSiteCalls=(window.groqSiteCalls||0)+1;
                  return Reflect.apply(groqSiteBase,this,args);};
                window.fetch=window.groqSiteWrapper;
                """ : ""
            created.html=html+"<script>window.variant='"+variant+"';"+siteWrapper+cachedSDK+Self.client+"</script>"
            pages.append(created);view=created;return created
        }
        let transport=EmbeddedWebModelTransport(browser:browser)
        let server=WebModelServer(rejectedReplyDirectory:tmp.appendingPathComponent("replies"))
        await server.configureEmbeddedTransport(transport)
        if continuation { await server.setGroqSubmissionIntervalForTesting(.zero) }
        await server.setTimeoutsForTesting(readiness:.seconds(10),response:mode=="nativeDeadline" ? .seconds(6) : .seconds(3))
        if mode=="nativeDeadline" {transport.setTimeoutsForTesting(preparation:.seconds(10),response:maskReadFailure ? .seconds(2) : .seconds(1))}
        var maskedReadCallbacks = 0, readFailureDelayed = false
        if maskReadFailure {
            transport.setBeforePageResultValidationForTesting { action in
                guard action == "inspect", !readFailureDelayed, let page = view,
                      (try? await page.evaluateJavaScript("window.groqFixture.sendCount") as? Int) == 1 else { return }
                maskedReadCallbacks += 1
                if maskedReadCallbacks <= 2 {
                    // Callback1 is submit's mandatory nested model recheck,
                    // before native acknowledgedSendSequence=1: no progress attempt.
                    // Callback2 is the first eligible answer-absent inspection.
                    // Wake after each so callback3 can fail AFTER one admission.
                    _ = try? await page.evaluateJavaScript("setTimeout(()=>window.groqFixture.editor.classList.toggle('fixture-progress-wake'),50)")
                } else {
                    readFailureDelayed = true
                    // Cross only the already-fixed native response deadline;
                    // the page's original error must be recorded before poll masks it.
                    try? await Task.sleep(for: .milliseconds(2_100))
                }
            }
        }
        var retired=false
        var sendCountBeforeNavigation:Int?
        if mode=="retiredDuringRead" {
            let replacement=EmbeddedWebModelTransport(browser:browser)
            transport.setBeforePageResultValidationForTesting { action in
                guard action=="groqOwnedStatusObserved" else{return}
                await server.configureEmbeddedTransport(replacement)
                retired=true
            }
        }
        if mode=="navigatedDuringRead" {
            transport.setBeforePageResultValidationForTesting { action in
                guard action=="groqOwnedStatusObserved",let page=view,
                      let tab=browser.tabs.first(where:{ browser.webView(for:$0.id)===page }) else { return }
                sendCountBeforeNavigation=try? await page.evaluateJavaScript("window.groqFixture.sendCount") as? Int
                try? browser.navigate(tabID:tab.id,to:URL(string:"https://chat.groq.com/?model=openai/gpt-oss-120b")!)
                retired=true
            }
        }
        await server.configureEvidenceDirectory(tmp.appendingPathComponent("evidence"))
        let runtime=UUID(),task=UUID().uuidString.lowercased(),thread=UUID().uuidString.lowercased(),turn=UUID().uuidString.lowercased(),prep=UUID()
        await server.configureCleanupReceipts(directory:tmp.appendingPathComponent("cleanup"),runtimeGeneration:runtime){_ in}
        let coreGeneration = UUID()
        try await server.prepareInferenceTurn(taskID:task,threadID:thread,runtimeGeneration:runtime,preparationID:prep,
            isNewThread:true,isCompactToolThread:earlyPassive,
            historyPreparation:earlyPassive ? .init(modelID:model.modelID,coreGeneration:coreGeneration) : nil)
        if earlyPassive {
            let writerValue = try await server.prepareGroqHistoryTurn(taskID:task,threadID:thread,turnID:turn,
                runtimeGeneration:runtime,preparationID:prep,modelID:model.modelID,coreGeneration:coreGeneration)
            let writer = try XCTUnwrap(writerValue)
            XCTAssertTrue(writer.isCurrent(current:.init(taskID:task,threadID:thread,turnID:turn,
                runtimeGeneration:runtime,preparationID:prep,modelID:model.modelID,coreGeneration:coreGeneration)))
            try await server.registerInferenceTurn(taskID:task,threadID:thread,turnID:turn,
                runtimeGeneration:runtime,preparationID:prep)
        }
        func item(_ role:String,_ text:String)->[String:Any] {
            ["type":"message","role":role,"content":[["type":"input_text","text":text]]]
        }
        var input:[Any]=[item("developer","Synthetic policy"),
            item("user","<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
            item("user",user+"\n"+ComputaAgentInstructions.runtimeInteractionPolicy())]
        let fixtureTools:[[String:Any]]=[["type":"function","name":"fixture_read",
            "parameters":["type":"object","properties":[String:Any](),"additionalProperties":false]],
            ["type":"custom","name":"apply_patch"]]
        var tools = continuation ? fixtureTools : []
        if earlyPassive {
            tools = [GroqToolCatalog.specification,GroqHistoryTool.specification].map { definition in
                var wire = definition
                wire["parameters"] = wire.removeValue(forKey:"inputSchema")
                return wire
            } + fixtureTools
        }
        func request() throws -> Data {
            var object:[String:Any] = ["model":model.modelID,"input":input,"tools":tools]
            if earlyPassive {
                // The synthetic read is already offered by this exact policy;
                // no loader replay or unregistered-history opt-in is needed.
                object["tool_choice"] = ["type":"allowed_tools","mode":"auto","tools":[
                    ["type":"function","name":GroqHistoryTool.name],
                    ["type":"function","name":"fixture_read"],
                    ["type":"custom","name":"apply_patch"]]]
            }
            return try JSONSerialization.data(withJSONObject:object)
        }
        if continuation {
            let first=try await server.fixtureInfer(request(),taskID:task,threadID:thread,turnID:turn,runtimeGeneration:runtime,preparationID:prep)
            let response=try XCTUnwrap(JSONSerialization.jsonObject(with:first) as? [String:Any])
            let calls=try XCTUnwrap(response["output"] as? [[String:Any]])
            XCTAssertEqual(calls.count,1);XCTAssertEqual(calls.first?["name"] as? String,customHistory ? "apply_patch" : "fixture_read")
            XCTAssertEqual(calls.first?["type"] as? String,customHistory ? "custom_tool_call" : "function_call")
            input += calls + [["type":customHistory ? "custom_tool_call_output" : "function_call_output",
                "call_id":try XCTUnwrap(calls.first?["call_id"]),"output":"Synthetic tool result"]]
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path),"A successful first inference publishes no failure")
            let firstPage=try XCTUnwrap(pages.first)
            XCTAssertFalse(browser.tabs.contains { browser.webView(for:$0.id)===firstPage },"Groq clears and closes the first physical view")
        }
        do {
            let result=try await server.fixtureInfer(request(),taskID:task,threadID:thread,turnID:turn,runtimeGeneration:runtime,preparationID:prep)
            XCTAssertEqual(mode,"success")
            let response=try XCTUnwrap(JSONSerialization.jsonObject(with:result) as? [String:Any])
            XCTAssertEqual(response["status"] as? String,"completed")
            let items=try XCTUnwrap(response["output"] as? [[String:Any]])
            XCTAssertEqual(items.count,1)
            XCTAssertEqual((items.first?["content"] as? [[String:Any]])?.first?["text"] as? String,"Fixture complete")
        } catch {
            XCTAssertNotEqual(mode,"success")
            switch error {
            case EmbeddedWebModelTransport.Failure.ownershipFailure(.groqDraftRestored):XCTAssertTrue(["rollback","observerNotArmed","observerUnavailable","siteWrapper","cachedSDK"].contains(mode))
            case WebModelServer.Failure.deadline:XCTAssertNotEqual(mode,"nativeDeadline");XCTAssertNotEqual(mode,"rollback")
            case EmbeddedWebModelTransport.Failure.deadline:XCTAssertEqual(mode,"nativeDeadline")
            default:XCTFail("Unexpected synthetic terminal error: "+String(describing:error))
            }
        }
        if maskReadFailure { XCTAssertTrue(readFailureDelayed); XCTAssertEqual(maskedReadCallbacks, 3) }
        XCTAssertEqual(retired,["retiredDuringRead","navigatedDuringRead"].contains(mode))
        let page=try XCTUnwrap(view)
        let count:Int?
        if let saved=sendCountBeforeNavigation { count=saved }
        else { count=try await page.evaluateJavaScript("window.groqFixture.sendCount") as? Int }
        XCTAssertEqual(count,1)
        XCTAssertEqual(pages.count,continuation ? 2 : 1)
        if mode == "siteWrapper" {
            let encoded = try await page.evaluateJavaScript("""
                JSON.stringify({noEarlyObserver:window.groqSawNoEarlyObserver===true,
                  oneSiteCall:window.groqSiteCalls===1,oneBaseCall:window.requests===1,
                  receiverIdentity:window.groqSiteReceiver===window.groqBaseReceiver,
                  argumentIdentity:window.groqSiteArgs.length===2&&window.groqBaseArgs.length===2&&window.groqSiteArgs.every((value,index)=>value===window.groqBaseArgs[index]),
                  promiseIdentity:window.groqSitePromise===window.groqBasePromise,
                  restoredSiteFetch:window.fetch===window.groqSiteWrapper})
                """)
            let flags = try JSONDecoder().decode([String: Bool].self, from: Data(try XCTUnwrap(encoded as? String).utf8))
            XCTAssertEqual(flags, ["noEarlyObserver":true,"oneSiteCall":true,"oneBaseCall":true,
                "receiverIdentity":true,"argumentIdentity":true,"promiseIdentity":true,"restoredSiteFetch":true])
        }
        if mode == "cachedSDK" {
            let encoded = try await page.evaluateJavaScript("""
                JSON.stringify({earlyObserver:window.groqEarlyObserverPresent===true,
                  cachedWrapper:window.groqCachedFetch!==window.groqBaseFetch,
                  oneBaseCall:window.requests===1,siteWrapperUnused:!window.groqSiteCalls,
                  receiverIdentity:window.groqBaseReceiver===window.groqCachedReceiver,
                  argumentIdentity:window.groqSDKArgs.length===2&&window.groqBaseArgs.length===2&&window.groqSDKArgs.every((value,index)=>value===window.groqBaseArgs[index]),
                  promiseIdentity:window.groqSDKPromise===window.groqBasePromise,
                  preservedSiteFetch:window.fetch===window.groqSiteWrapper})
                """)
            let flags = try JSONDecoder().decode([String: Bool].self, from: Data(try XCTUnwrap(encoded as? String).utf8))
            XCTAssertEqual(flags, ["earlyObserver":earlyPassive,"cachedWrapper":earlyPassive,
                "oneBaseCall":true,"siteWrapperUnused":true,"receiverIdentity":true,
                "argumentIdentity":true,"promiseIdentity":true,"preservedSiteFetch":true])
        }
        if continuation {
            XCTAssertFalse(pages[0] === pages[1],"Continuation must exercise a genuinely new owned view")
            for page in pages {
                let sends=try await page.evaluateJavaScript("window.groqFixture.sendCount") as? Int
                let requests=try await page.evaluateJavaScript("window.requests") as? Int
                XCTAssertEqual(sends,1);XCTAssertEqual(requests,1)
            }
        }
        XCTAssertNotNil(browser.webView(for:human))
        _=await server.fixtureFinish(taskID:task,runtimeGeneration:runtime)
        let receipts=await server.latestCleanupReceipts()
        XCTAssertEqual(receipts.last?.outcome,mode=="success" ? .closed : .unconfirmed)
        XCTAssertEqual(receipts.last?.reason,mode=="success" ? .transcriptCleared : .cleanupUnverified)
        if expected=="none" {
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath:arm.path),["wrongNonce","wrongProfile","wrongPurpose","crossFixturePurpose","wrongFixture","wrongModel"].contains(mode))
        }
        else {
            XCTAssertFalse(FileManager.default.fileExists(atPath:arm.path),"Authorized arm must be consumed")
            let report=try XCTUnwrap(try? Data(contentsOf:output),"Missing finite packet for "+mode)
            let row=try XCTUnwrap(JSONSerialization.jsonObject(with:report) as? [String:Any])
            XCTAssertEqual(row["stage"] as? String,expected);XCTAssertEqual(row["taskID"] as? String,task)
            XCTAssertEqual(row["modelID"] as? String,model.modelID)
            XCTAssertEqual(row["purpose"] as? String,fixture ? (earlyPassive ? GroqOwnedStatusLease.FixtureTurn.earlyPassivePurpose : kind.purpose) : profile.purpose)
            XCTAssertEqual(row["trigger"] as? String,["rollback","observerNotArmed","observerUnavailable","siteWrapper","cachedSDK"].contains(mode) ? "groq_draft_restored" : "response_deadline")
            XCTAssertEqual(row["evidenceClass"] as? String,["observer_not_armed","observer_unavailable"].contains(expected) ? "native_observer_availability" : "page_world_observation")
            if earlyPassive {
                let progress = try XCTUnwrap(row["failureProgress"] as? [String: Any])
                XCTAssertEqual(progress["kind"] as? String, "groq_failure_progress_v1")
                if maskReadFailure {
                    let last = try XCTUnwrap(progress["lastAttempt"] as? [String: Any])
                    let admitted = try XCTUnwrap(progress["inspection"] as? [String: Any])
                    XCTAssertEqual(last["outcome"] as? String, "failed"); XCTAssertEqual(last["error"] as? String, "page_unavailable")
                    XCTAssertEqual(last["ordinal"] as? Int, 2)
                    XCTAssertEqual(progress["readsStarted"] as? Int, 2); XCTAssertEqual(progress["admittedReads"] as? Int, 1)
                    XCTAssertEqual(progress["readsReturned"] as? Int, 2)
                    let started = try XCTUnwrap(progress["readsStarted"] as? Int)
                    XCTAssertEqual(maskedReadCallbacks, started + 1, "The pre-ack submit recheck is not a progress attempt")
                    XCTAssertEqual(admitted["gate"] as? String, "answer_absent"); XCTAssertEqual(admitted["answers"] as? Int, 0)
                    XCTAssertEqual(admitted["users"] as? Int, 1); XCTAssertEqual(admitted["answerComplete"] as? Bool, false)
                }
            } else {
                XCTAssertNil(row["failureProgress"])
            }
            if ["observer_not_armed", "observer_unavailable"].contains(expected) {
                XCTAssertEqual(row.count, earlyPassive ? 17 : 16)
                XCTAssertNotNil((row["setupReason"] as? String).flatMap(GroqOwnedStatusLease.SetupReason.init(rawValue:)))
                XCTAssertEqual(row["setupReason"] as? String, mode == "observerNotArmed" ? "js_fetch_descriptor" : "armed")
            } else {
                XCTAssertEqual(row.count, earlyPassive ? 16 : 15); XCTAssertNil(row["setupReason"])
            }
            XCTAssertFalse(String(decoding:report,as:UTF8.self).contains(nonce.uuidString))
        }
        _=await server.shutdown()
        if earlyPassive {
            browser.shutdown()
            for created in pages {
                let scripts = created.configuration.userContentController.userScripts
                let hasEarlyBootstrap = scripts.contains { $0.source.hasPrefix("// Private prototype. Only a fresh owned tab with a native synthetic lease receives this main-world, main-frame script.") }
                XCTAssertFalse(hasEarlyBootstrap,"Native shutdown removes the exact early bootstrap from every fixture view")
                if mode == "cachedSDK" {
                    let hasOriginalFixture = scripts.contains { $0.source.contains("window.groqBaseFetch=window.fetch;") }
                    XCTAssertTrue(hasOriginalFixture,"Removing the observer preserves the independent original fixture script")
                }
            }
        }
    }
    private static let client = #"""
        const f=window.groqFixture,old=f.send.onclick;
        f.delayResponse=!['success','tool','patch'].includes(variant);
        if(variant==='success')f.reply=JSON.stringify({type:'message',text:'Fixture complete'});
        if(variant==='tool')f.reply=JSON.stringify({type:'tool_calls',calls:[{name:'fixture_read',arguments:{}}]});
        if(variant==='patch')f.reply=JSON.stringify({type:'tool_calls',calls:[{name:'apply_patch',input:'*** Begin Patch\n*** End Patch'}]});
        f.send.onclick=e=>{
          const prompt=f.editor.value;old.call(f.send,e);
          if(['preflight','unarmed','success','wrongNonce','wrongProfile','wrongPurpose','crossFixturePurpose','wrongFixture','wrongModel','nativeDeadline','retiredDuringRead','navigatedDuringRead'].includes(variant))return;
          const qwen=f.model==='qwen/qwen3.8-27b',message={content:variant==='wrongBody'?'different':prompt,role:'user'};
          const body=JSON.stringify({model:f.model,messages:qwen?[message]:[{content:'synthetic system',role:'system'},message],temperature:qwen?0.6:1,max_completion_tokens:qwen?8192:16384,top_p:qwen?0.95:1,stream:true});
          if(variant==='cachedSDK'){
            window.groqSDKArgs=['https://api.groq.com/openai/v1/chat/completions',{method:'POST',body}];
            window.groqSDKPromise=Reflect.apply(window.groqCachedFetch,window.groqCachedReceiver,window.groqSDKArgs);
            window.groqSDKPromise.catch(()=>{
              setTimeout(()=>{f.turn.remove();f.editor.value=prompt;f.editor.disabled=false;f.send.disabled=false;},900);
            });
            return;
          }
          fetch('https://api.groq.com/openai/v1/chat/completions',{method:'POST',body}).catch(()=>{
            setTimeout(()=>{f.turn.remove();f.editor.value=prompt;f.editor.disabled=false;f.send.disabled=false;},900);
          });
          if(variant==='observerUnavailable')for(const key of Object.getOwnPropertyNames(window))if(key.startsWith('__computaGroqStatus_'))delete window[key];
        };
        """#
}

private struct GroqManualInspectorArm: Sendable {
    let directory: URL, output: URL, admission: WebModelStartAdmission, request: WebModelResponseCodec.Request
}
private final class GroqManualInspectorCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class GroqManualInspectorLeaseResults: @unchecked Sendable {
    private let lock = NSLock(); private var children: [GroqOwnedStatusLease] = []
    var values: [GroqOwnedStatusLease] { lock.withLock { children } }
    func append(_ child: GroqOwnedStatusLease) { lock.withLock { children.append(child) } }
}
private final class GroqManualInspectorBindingResults: @unchecked Sendable {
    private let lock = NSLock(); private var bindings: [GroqOwnedStatusLease.InspectorBinding] = []
    var values: [GroqOwnedStatusLease.InspectorBinding] { lock.withLock { bindings } }
    func append(_ binding: GroqOwnedStatusLease.InspectorBinding) { lock.withLock { bindings.append(binding) } }
}

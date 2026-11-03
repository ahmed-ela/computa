import CryptoKit
import Foundation
import XCTest
@testable import Computa

struct QwenMarkerWireTestFixture {
    let directory: URL
    let admission: WebModelStartAdmission
    let request: WebModelResponseCodec.Request
    let lease: QwenMarkerWireLease
    let expectedMarker: String
    let label: String
    let armData: Data

    init(label: String) throws {
        let nonce = UUID()
        self.label = label
        expectedMarker = QwenMarkerWireLease.marker(nonce)
        let userText = QwenMarkerWireLease.userText(nonce)
        let choice = WebsiteModelChoice(provider:"qwen",key:label,label:label)
        let model = choice.modelID
        directory = try websiteBenchmarkTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory:true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
        let dir = directory
        do {
            // Match the normal native first-request projection, retaining the environment and policy.
            func item(_ role: String, _ text: String) -> [String:Any] {
                ["type":"message", "role":role, "content":[["type":"input_text", "text":text]]]
            }
            let input = [item("developer","Synthetic policy"), item("user","<environment_context><cwd>/tmp/marker</cwd><shell>zsh</shell></environment_context>"),
                         item("user", userText + "\n" + ComputaAgentInstructions.runtimeInteractionPolicy())]
            request = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject:["model":model,"input":input,"tools":[]]))
            let start = try JSONSerialization.data(withJSONObject:["provider":"qwen","modelChoice":try XCTUnwrap(choice.canonicalJSONString)])
            admission = WebModelStartAdmission(id:UUID(), inferenceID:UUID(), taskID:UUID().uuidString.lowercased(),
                threadID:UUID().uuidString.lowercased(), turnID:UUID().uuidString.lowercased(), runtimeGeneration:UUID(),
                preparationID:UUID(), transportGeneration:UUID(), provider:"qwen", modelID:model, parameters:start)
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let fields: [String:Any] = ["schemaVersion":1,"purpose":QwenMarkerWireLease.purpose,"provider":"qwen","modelID":model,
                "nonce":nonce.uuidString.lowercased(),"expiresAt":format.string(from:Date().addingTimeInterval(300)),
                "userPromptSHA256":SHA256.hash(data: Data(userText.utf8)).map { String(format:"%02x",$0) }.joined()]
            let arm = directory.appendingPathComponent("arm.json")
            armData = try JSONSerialization.data(withJSONObject:fields); try armData.write(to:arm)
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:arm.path)
            let result = QwenMarkerWireLease.consume(directory:directory, admission:admission, request:request, isNewThread:true,
                                                     isMaintenance:false,isFirstInference:true,hasCorrectionTicket:false)
            lease = try XCTUnwrap(result)
        } catch { try? FileManager.default.removeItem(at:dir); throw error }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func receipt(_ token: String, reason: WebsiteSessionCleanupReceipt.Reason = .deleted,
                 saved: Bool = true, inference: UUID? = nil) -> WebsiteSessionCleanupReceipt {
        WebsiteSessionCleanupReceipt(taskID:admission.taskID, threadID:admission.threadID, turnID:admission.turnID,
            runtimeGeneration:admission.runtimeGeneration, outcome:reason == .cleanupUnverified ? .unconfirmed : .closed,
            provider:.qwen, route:.embedded, modelID:admission.modelID, reason:reason, trigger:.inference, receiptSaved:saved,
            inferenceID:(inference ?? admission.inferenceID).uuidString.lowercased(), sessionToken:token)
    }
    func publishDeleted(token: String, generation: UUID, firstUserFingerprint: String) throws -> String? {
        guard lease.publishAfterRelease(reply:.message(expectedMarker), model:.init(key:label,label:label),
            generation:generation, firstFingerprint:firstUserFingerprint, receipt:receipt(token)) else { return nil }
        let data = try Data(contentsOf: directory.appendingPathComponent("marker-wire.json"))
        return (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["stage"] as? String
    }
}

final class QwenMarkerWireLeaseTests: XCTestCase {
    func testConsumesExactSyntheticArmOnceAndBindsDocumentViewAndFingerprint() throws {
        for label in ["Qwen3.7-Plus","Qwen3.8-Max"] {
            let f = try QwenMarkerWireTestFixture(label:label); defer { f.cleanup() }
            let own = NSObject(), foreign = NSObject(), id = ObjectIdentifier(own), other = ObjectIdentifier(foreign)
            let token = UUID().uuidString, document = UUID(), fp = String(repeating:"a",count:64)
            XCTAssertTrue(f.lease.matches(admission:f.admission)); XCTAssertTrue(f.lease.matchesPrompt(f.request.prompt))
            XCTAssertFalse(f.lease.matchesPrompt(f.request.prompt + " "))
            XCTAssertNil(QwenMarkerWireLease.consume(directory:f.directory, admission:f.admission, request:f.request,
                isNewThread:true,isMaintenance:false,isFirstInference:true,hasCorrectionTicket:false))
            XCTAssertTrue(f.lease.claim(view:id)); XCTAssertFalse(f.lease.claim(view:other))
            XCTAssertFalse(f.lease.bind(view:other,ownerToken:token,generation:document,outboundFingerprint:fp))
            XCTAssertFalse(f.lease.bind(view:id,ownerToken:token,generation:document,outboundFingerprint:"PRIVATE CANARY"))
            XCTAssertTrue(f.lease.bind(view:id,ownerToken:token,generation:document,outboundFingerprint:fp))
            XCTAssertFalse(f.lease.stage("PRIVATE CANARY",view:id,ownerToken:token,generation:document))
            XCTAssertFalse(f.lease.stage("ready",view:id,ownerToken:token,generation:document))
            XCTAssertFalse(f.lease.stage("wire_equal",view:other,ownerToken:token,generation:document))
            XCTAssertFalse(f.lease.stage("wire_equal",view:id,ownerToken:token,generation:UUID()))
            XCTAssertFalse(f.lease.stage("wire_equal",view:id,ownerToken:UUID().uuidString,generation:document))
            let stage = label == "Qwen3.8-Max" ? "response_model_unobserved" : "wire_equal"
            XCTAssertTrue(f.lease.stage(stage,view:id,ownerToken:token,generation:document))
            XCTAssertFalse(f.lease.stage("wire_equal",view:id,ownerToken:token,generation:document))
            XCTAssertEqual(try f.publishDeleted(token:token,generation:document,firstUserFingerprint:fp),stage)
            XCTAssertNil(try f.publishDeleted(token:token,generation:document,firstUserFingerprint:fp))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:f.directory.appendingPathComponent("marker-wire.json"))) as? [String:Any])
            XCTAssertEqual(Set(record.keys), ["schemaVersion","purpose","stage","evidenceClass","taskID","threadID","turnID",
                "inferenceID","runtimeGeneration","preparationID","modelID","sessionToken","documentGeneration","cleanupAttemptID"])
            XCTAssertEqual(record["inferenceID"] as? String,f.admission.inferenceID.uuidString.lowercased())
            XCTAssertEqual(record["evidenceClass"] as? String,"page_world_untrusted")
        }
    }
    func testArmsRejectWrongNativeContextModePromptAndUntrustedInputWithoutConsumption() throws {
        let f = try QwenMarkerWireTestFixture(label:"Qwen3.8-Max"); defer { f.cleanup() }
        let dir = f.directory.appendingPathComponent("separate",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let arm = dir.appendingPathComponent("arm.json")
        func consume(_ admission: WebModelStartAdmission? = nil, _ request: WebModelResponseCodec.Request? = nil,
                     fresh: Bool = true, maintenance: Bool = false, first: Bool = true, correction: Bool = false) -> QwenMarkerWireLease? {
            QwenMarkerWireLease.consume(directory:dir,admission:admission ?? f.admission,request:request ?? f.request,isNewThread:fresh,
                isMaintenance:maintenance,isFirstInference:first,hasCorrectionTicket:correction)
        }
        for field in ["provider","nonce","modelID","expiresAt","userPromptSHA256","purpose","extra","schemaVersion"] {
            var data = try XCTUnwrap(JSONSerialization.jsonObject(with:f.armData) as? [String:Any])
            data[field] = field == "schemaVersion" ? true : "unrecognized"
            try JSONSerialization.data(withJSONObject:data).write(to:arm)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:arm.path)
            XCTAssertNil(consume(),field); XCTAssertTrue(FileManager.default.fileExists(atPath:arm.path))
        }
        try f.armData.write(to:arm)
        XCTAssertNil(consume(fresh:false)); XCTAssertNil(consume(maintenance:true))
        XCTAssertNil(consume(first:false)); XCTAssertNil(consume(correction:true))
        let other = try WebModelResponseCodec.prepareRequest(JSONSerialization.data(withJSONObject:[
            "input":"An ordinary user request", "model":f.admission.modelID, "tools":[]]))
        XCTAssertNil(consume(nil,other))
        XCTAssertFalse(WebsitePrivateDiagnosticCapture.publish(directory:dir,outputName:"marker-wire.json",maximumArmBytes:4096,
            maximumRecordBytes:128,makeRecord:{ _ in Data("untrusted".utf8) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath:arm.path))
        let c = f.admission
        for changed in 0...9 {
            let different = WebModelStartAdmission(id:changed == 0 ? UUID() : c.id,inferenceID:changed == 1 ? UUID() : c.inferenceID,
                taskID:changed == 2 ? UUID().uuidString.lowercased() : c.taskID,threadID:changed == 3 ? UUID().uuidString.lowercased() : c.threadID,
                turnID:changed == 4 ? UUID().uuidString.lowercased() : c.turnID,runtimeGeneration:changed == 5 ? UUID() : c.runtimeGeneration,
                preparationID:changed == 6 ? UUID() : c.preparationID,transportGeneration:changed == 7 ? UUID() : c.transportGeneration,
                provider:changed == 8 ? "claude" : c.provider,modelID:c.modelID,parameters:changed == 9 ? Data() : c.parameters)
            XCTAssertFalse(f.lease.matches(admission:different))
        }
        XCTAssertNotNil(consume()); XCTAssertNil(consume())
    }
    func testFiniteStageCannotPublishForAnyOtherReplyModeReceiptBindingOrAfterRevocation() throws {
        let f = try QwenMarkerWireTestFixture(label:"Qwen3.7-Plus"); defer { f.cleanup() }
        let own = NSObject(), id = ObjectIdentifier(own), token = UUID().uuidString, document = UUID()
        let fp = String(repeating:"a",count:64)
        XCTAssertTrue(f.lease.claim(view:id)); XCTAssertTrue(f.lease.bind(view:id,ownerToken:token,generation:document,outboundFingerprint:fp))
        XCTAssertTrue(f.lease.stage("wire_equal",view:id,ownerToken:token,generation:document))
        let correct = WebsiteModelEvidence.Identity(key:f.label,label:f.label)
        func check(_ r: WebModelResponseCodec.Reply? = nil, model: WebsiteModelEvidence.Identity? = nil, doc: UUID? = nil,
                   fingerprint: String? = nil, receipt: WebsiteSessionCleanupReceipt? = nil) -> Bool {
            f.lease.publishAfterRelease(reply:r ?? .message(f.expectedMarker), model:model ?? correct, generation:doc ?? document,
                firstFingerprint:fingerprint ?? fp, receipt:receipt ?? f.receipt(token))
        }
        XCTAssertFalse(check(.message(f.expectedMarker + "."))); XCTAssertFalse(check(.assistantMessage(f.expectedMarker,phase:.commentary)))
        XCTAssertFalse(check(.toolCalls([]))); XCTAssertFalse(check(model:.init(key:"Qwen3.8-Max",label:"Qwen3.8-Max")))
        XCTAssertFalse(check(doc:UUID())); XCTAssertFalse(check(fingerprint:String(repeating:"b",count:64)))
        XCTAssertFalse(check(receipt:f.receipt(token,saved:false))); XCTAssertFalse(check(receipt:f.receipt(token, reason:.notCreated)))
        XCTAssertFalse(check(receipt:f.receipt(token,reason:.cleanupUnverified))); XCTAssertFalse(check(receipt:f.receipt(UUID().uuidString)))
        XCTAssertFalse(check(receipt:f.receipt(token,inference:UUID())))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.directory.appendingPathComponent("marker-wire.json").path))
        f.lease.revoke(); XCTAssertFalse(check()); XCTAssertFalse(f.lease.isCurrent)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.directory.appendingPathComponent("marker-wire.json").path))
    }
}

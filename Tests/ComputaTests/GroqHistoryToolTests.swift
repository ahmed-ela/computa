import Foundation
import XCTest
@testable import Computa

final class GroqHistoryToolTests: XCTestCase {
    private var model: String {
        WebsiteModelChoice(provider: "groq", key: "openai/gpt-oss-120b", label: "GPT OSS 120B").modelID
    }

    func testExactNativeAndEngineDeclarationsRetainOneReservedReader() throws {
        XCTAssertEqual(GroqHistoryTool.registeredName(in: [GroqHistoryTool.specification]), GroqHistoryTool.name)
        var engine = GroqHistoryTool.specification
        engine["parameters"] = engine.removeValue(forKey: "inputSchema")
        XCTAssertEqual(GroqHistoryTool.registeredName(in: [engine]), GroqHistoryTool.name)
        XCTAssertEqual(GroqHistoryTool.registeredName(in: [["type": "namespace", "name": "functions", "tools": [engine]]]),
                       "functions." + GroqHistoryTool.name)
        XCTAssertNil(GroqHistoryTool.registeredName(in: [["type": "namespace", "name": "foreign", "tools": [engine]]]))
        XCTAssertNil(GroqHistoryTool.registeredName(in: [engine, engine]))
    }

    func testConflictingSchemaDescriptionOrKindCannotBorrowReaderInterpretation() {
        for key in ["inputSchema", "description", "type"] {
            var changed = GroqHistoryTool.specification
            changed[key] = key == "inputSchema" ? ["type": "object"] as Any : "foreign"
            XCTAssertNil(GroqHistoryTool.registeredName(in: [changed]))
        }
        var both = GroqHistoryTool.specification
        both["parameters"] = ["type": "object"]
        XCTAssertNil(GroqHistoryTool.registeredName(in: [both]))
        var incomplete = GroqHistoryTool.specification
        incomplete.removeValue(forKey: "inputSchema")
        XCTAssertNil(GroqHistoryTool.registeredName(in: [incomplete]))
    }

    func testOnlyTheCurrentOpaqueReferenceSchemaCanAcquireRegistration() throws {
        let schema = GroqHistoryTool.argumentSchema
        XCTAssertEqual(schema["required"] as? [String], ["ref"])
        XCTAssertEqual(Set(try XCTUnwrap(schema["properties"] as? [String: Any]).keys), ["ref"])
        var legacy = GroqHistoryTool.specification
        legacy["inputSchema"] = ["type": "object", "properties": [
            "context_revision": ["type": "string"], "ref": ["type": "string"]],
            "required": ["context_revision", "ref"], "additionalProperties": false]
        XCTAssertNil(GroqHistoryTool.registeredName(in: [legacy]),
            "A former argument contract cannot borrow the current reader registration")
    }

    func testAcknowledgedMembershipBindsHomeThreadModelAndSeparateHistoryContract() throws {
        let suite = "GroqHistoryToolTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let thread = UUID().uuidString.lowercased(), otherThread = UUID().uuidString.lowercased()
        let home = "/synthetic/groq-history-home"
        XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: thread, modelID: model, defaults: defaults))
        GroqToolThreadRegistration.remember(codexHome: home, threadID: thread, modelID: model, defaults: defaults)
        XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: thread, modelID: model, defaults: defaults),
                       "The older schema-loader registration is not a history-reader registration")
        GroqHistoryThreadRegistration.remember(codexHome: home, threadID: thread, modelID: model, defaults: defaults)
        XCTAssertTrue(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: thread, modelID: model, defaults: defaults))
        XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home + "-other", threadID: thread, modelID: model, defaults: defaults))
        XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: otherThread, modelID: model, defaults: defaults))
        let otherModel = WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B").modelID
        XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: thread, modelID: otherModel, defaults: defaults))
        let markers = try XCTUnwrap(defaults.stringArray(forKey: GroqHistoryThreadRegistration.preferenceKey))
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].utf8.count, 64)
        XCTAssertFalse(markers[0].contains(home))
        XCTAssertTrue(GroqToolThreadRegistration.contains(codexHome: home, threadID: thread, modelID: model, defaults: defaults))
    }

    func testInvalidMembershipAndOtherProvidersRemainUnregistered() throws {
        let suite = "GroqHistoryToolTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let otherModel = WebsiteModelChoice(provider: "qwen", key: "Qwen3.7-Plus", label: "Qwen3.7-Plus").modelID
        for (home, thread, selected) in [("", UUID().uuidString.lowercased(), model),
                                         ("/synthetic", "not-a-native-thread", model),
                                         ("/synthetic", UUID().uuidString.lowercased(), otherModel)] {
            GroqHistoryThreadRegistration.remember(codexHome: home, threadID: thread, modelID: selected, defaults: defaults)
            XCTAssertFalse(GroqHistoryThreadRegistration.contains(codexHome: home, threadID: thread, modelID: selected, defaults: defaults))
        }
        XCTAssertNil(defaults.stringArray(forKey: GroqHistoryThreadRegistration.preferenceKey))
    }
}

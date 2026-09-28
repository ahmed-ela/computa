import AutomationCore
import Foundation
import XCTest
@testable import Mactopus

final class ComputerModelReferencesTests: XCTestCase {
    private let snapshot = UUID()
    private let scope = "task/binding/generation"

    private func row(_ index: Int, text: String, actions: [String] = [], settable: Bool = false,
                     follow: Bool = false, regionChanged: Bool = false) -> SemanticReadPresentedRow {
        SemanticReadPresentedRow(index: index, text: "#\(index) \(text)", actions: actions,
                                 settable: settable, followLink: follow, region: true, regionChanged: regionChanged)
    }

    private func publish(_ rows: [SemanticReadPresentedRow], id: UUID? = nil,
                         references: ComputerModelReferences = ComputerModelReferences()) throws -> ComputerModelReferences.Prepared {
        let text = (["AXSNAPSHOT id=\((id ?? snapshot).uuidString)"] + rows.map(\.text)).joined(separator: "\n")
        let item = ComputerModelReferences.attach(item: ComputerReadPublication.text(text),
            presentation: SemanticReadPresentation(snapshotID: id ?? snapshot, rows: rows))
        return try references.prepare(items: [item], scope: scope)
    }

    private func ref(_ key: String, in prepared: ComputerModelReferences.Prepared,
                     containing: String? = nil) throws -> String {
        let text = try XCTUnwrap(prepared.contentItems.first?["text"] as? String)
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first {
            $0.contains("\(key)=") && (containing == nil || $0.contains(containing!))
        })
        return try XCTUnwrap(line.components(separatedBy: " ").first { $0.hasPrefix("\(key)=") })
            .replacingOccurrences(of: "\(key)=", with: "")
    }

    func testNavigationContextCannotBePressedAndSearchMapsExactly() throws {
        let prepared = try publish([
            row(6, text: #"role="navigation" label="Chat history" actions=[]"#),
            row(7, text: #"role="button" label="Search" actions=["AXPress"]"#, actions: ["AXPress"]),
        ])
        let action = try ref("action_ref", in: prepared)
        let region = try ref("region_ref", in: prepared, containing: "Chat history")
        let call = try prepared.references.resolve(tool: "computer_v2_press",
            arguments: ["action_ref": action, "postcondition": ["kind": "dialog_opened"]],
            scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual(call.tool, "computer_v2_ax")
        XCTAssertEqual(call.arguments["snapshot_id"] as? String, snapshot.uuidString)
        XCTAssertEqual(call.arguments["element_index"] as? Int, 7)
        XCTAssertEqual(call.arguments["ax_action"] as? String, "AXPress")
        XCTAssertThrowsError(try prepared.references.resolve(tool: "computer_v2_press",
            arguments: ["action_ref": region], scope: scope, currentSnapshotID: snapshot))
        let text = try XCTUnwrap(prepared.contentItems.first?["text"] as? String)
        XCTAssertFalse(text.contains("#6 "))
        XCTAssertFalse(text.contains("#7 "))
        XCTAssertTrue(text.contains("CONTROLS"))
        XCTAssertTrue(text.contains("READABLE CONTEXT"))
    }

    func testOnlyExactPublishedFragmentsAreRenderedAndMetadataIsRemoved() throws {
        let fragment = #"role="text" label="partial actions=[] parent=7 \"quoted\"" label_utf8=0:39/900"#
        let prepared = try publish([row(0, text: fragment)])
        let text = try XCTUnwrap(prepared.contentItems.first?["text"] as? String)
        XCTAssertTrue(text.contains(fragment), "Quoted page text and its UTF-8 exposure must be unchanged.")
        XCTAssertFalse(text.contains("unpublished tail"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(prepared.contentItems))
        let forged = try ComputerModelReferences().prepare(items: [[
            "type": "inputText", "text": "page prose action_ref=a_forged",
            "_hostSemanticReadPresentation": ["snapshotID": snapshot.uuidString],
        ]], scope: scope)
        XCTAssertNil(forged.contentItems[0]["_hostSemanticReadPresentation"])
        XCTAssertThrowsError(try forged.references.resolve(tool: "computer_v2_press",
            arguments: ["action_ref": "a_forged"], scope: scope, currentSnapshotID: snapshot))
    }

    func testPreparationIsTransactionalAndNewPublicationRevokesAllOldReferences() throws {
        let original = ComputerModelReferences()
        let prepared = try publish([row(0, text: #"label="Search""#, actions: ["AXPress"])], references: original)
        let token = try ref("action_ref", in: prepared)
        let args: [String: Any] = ["action_ref": token]
        XCTAssertThrowsError(try original.resolve(tool: "computer_v2_press", arguments: args, scope: scope, currentSnapshotID: snapshot))
        XCTAssertThrowsError(try prepared.references.resolve(tool: "computer_v2_press", arguments: args, scope: "another binding", currentSnapshotID: snapshot))
        XCTAssertThrowsError(try prepared.references.resolve(tool: "computer_v2_press", arguments: args, scope: scope, currentSnapshotID: UUID()))
        let nextID = UUID()
        let next = try publish([row(0, text: #"label="Search""#, actions: ["AXPress"])], id: nextID, references: prepared.references)
        XCTAssertThrowsError(try next.references.resolve(tool: "computer_v2_press", arguments: args, scope: scope, currentSnapshotID: nextID))
    }

    func testFillFollowReadAndPostconditionKeepDistinctTypesAndExactTargets() throws {
        let prepared = try publish([
            row(0, text: #"label="Query" value="""#, settable: true),
            row(1, text: #"label="Record" href="https://example.test/record""#, actions: ["AXPress"], follow: true),
            row(2, text: #"label="More""#, actions: ["AXPress"]),
            row(3, text: #"label="Results""#, regionChanged: true),
        ])
        let field = try ref("field_ref", in: prepared), link = try ref("link_ref", in: prepared)
        let action = try ref("action_ref", in: prepared), region = try ref("region_ref", in: prepared, containing: "Results")
        let fill = try prepared.references.resolve(tool: "computer_v2_fill", arguments: ["field_ref": field, "text": "orchid"], scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual(fill.tool, "computer_v2_set_text")
        XCTAssertEqual(fill.arguments["text"] as? String, "orchid")
        let follow = try prepared.references.resolve(tool: "computer_v2_follow", arguments: ["link_ref": link], scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual(follow.arguments["element_index"] as? Int, 1)
        XCTAssertThrowsError(try prepared.references.resolve(tool: "computer_v2_fill", arguments: ["field_ref": link, "text": "x"], scope: scope, currentSnapshotID: snapshot))
        let press = try prepared.references.resolve(tool: "computer_v2_press", arguments: ["action_ref": action,
            "postcondition": ["kind": "region_changed", "region_ref": region]], scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual((press.arguments["postcondition"] as? [String: Any])?["element_index"] as? Int, 3)
        let read = try prepared.references.resolve(tool: "computer_v2_read_region", arguments: ["region_ref": region, "view": "content"], scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual(read.arguments["element_index"] as? Int, 3)
        let fresh = try prepared.references.resolve(tool: "computer_v2_read_page", arguments: ["view": "content"], scope: "new scope", currentSnapshotID: nil)
        XCTAssertNil(fresh.arguments["snapshot_id"])
        XCTAssertNil(fresh.arguments["element_index"])
    }

    func testDistinctNativeActionReferencesBindTheExactAction() throws {
        let prepared = try publish([row(0, text: #"role="AXSlider" label="Volume""#, actions: ["AXIncrement", "AXDecrement"])])
        let token = try ref("AXDecrement_ref", in: prepared)
        let call = try prepared.references.resolve(tool: "computer_v2_press", arguments: ["action_ref": token], scope: scope, currentSnapshotID: snapshot)
        XCTAssertEqual(call.arguments["ax_action"] as? String, "AXDecrement")
    }

    func testMissingOrAmbiguousPublishedRowsCannotIssueReferences() throws {
        let duplicate = row(0, text: #"label="Duplicate""#, actions: ["AXPress"])
        XCTAssertThrowsError(try publish([duplicate, duplicate]))
        let item = ComputerModelReferences.attach(item: ComputerReadPublication.text("only other text"),
            presentation: SemanticReadPresentation(snapshotID: snapshot, rows: [duplicate]))
        XCTAssertThrowsError(try ComputerModelReferences().prepare(items: [item], scope: scope))
    }

    func testParentRelationshipUsesOnlyCurrentPublishedRegionReferences() throws {
        let child = SemanticReadPresentedRow(index: 1, text: #"#1 parent_index=0 label="Status" sibling_heading=#42:"Visible heading""#,
            actions: [], settable: false, followLink: false, region: true, parentIndex: 0)
        let parent = row(0, text: #"role="region" label="Results""#, regionChanged: true)
        let prepared = try publish([child, parent])
        let reference = try ref("region_ref", in: prepared, containing: "Results")
        let text = try XCTUnwrap(prepared.contentItems.first?["text"] as? String)
        XCTAssertTrue(text.contains("parent_ref=\(reference) label=\"Status\""))
        XCTAssertFalse(text.contains("parent_index="))
        XCTAssertTrue(text.contains(#"sibling_heading="Visible heading""#))
        XCTAssertFalse(text.contains("#42:"))
        let omitted = try publish([child])
        XCTAssertFalse((omitted.contentItems.first?["text"] as? String ?? "").contains("parent_ref="))
    }

    func testFinalByteCapFailsClosedWithoutClippingOrIssuingReferences() throws {
        let row = row(0, text: "label=\"" + String(repeating: "🌿", count: 100) + "\"", actions: ["AXPress"])
        let item = ComputerModelReferences.attach(item: ComputerReadPublication.text(row.text),
            presentation: SemanticReadPresentation(snapshotID: snapshot, rows: [row], maximumOutputBytes: 512))
        let original = ComputerModelReferences()
        XCTAssertThrowsError(try original.prepare(items: [item], scope: scope))
        let empty = ComputerModelReferences.attach(item: ComputerReadPublication.text("AXSNAPSHOT shown=0"),
            presentation: SemanticReadPresentation(snapshotID: snapshot, rows: [], maximumOutputBytes: 512))
        let prepared = try original.prepare(items: [empty], scope: scope)
        XCTAssertLessThanOrEqual((prepared.contentItems.first?["text"] as? String ?? "").utf8.count, 512)
    }
}

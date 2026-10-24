import AutomationCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Computa

/// Real model / real App Server / production Computa Core. The test-only stdio
/// wrapper replaces status execution with synthetic read-only output and blocks
/// every other server request. This is not a production desktop-broker test.
@MainActor
final class RuntimeAutomaticCompactionPathsLiveTests: XCTestCase {
    private let model = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
    private var shippingContext: LocalThreadContext { .forModel(model) }
    // These fixed-size synthetic tool results force a native within-turn
    // boundary; they do not prove the shipping profile's stress capacity.
    private let forcedWithinTurnLimit = 6_144
    private let forcedPayloads: Set<String> = ["bounded-observation", "bounded-image", "bounded-activation-failure"]

    /// Real Qwen, owned App Server and unchanged production instructions/tools;
    /// every tool result is synthetic. No desktop executor is ever invoked.
    /// This diagnoses one recovery decision, not general browser reliability.
    func testRealQwenRecoversMissingCardStatusWithTargetedAXQueryWithoutDesktop() async throws {
        try requireOptIn("HEYDASH_LIVE_AX_QUERY_RECOVERY_TEST")
        try await runAXQueryRecoveryCase(.original)
    }

    func testRealQwenRecoversSecondCardStatusWithDifferentLabelsWithoutDesktop() async throws {
        try requireOptIn("HEYDASH_LIVE_AX_QUERY_RECOVERY_TEST")
        try await runAXQueryRecoveryCase(.secondCard)
    }

    /// Two synthetic missing-information mechanisms: a first card's value is
    /// unavailable in the initial AX acquisition, or a later card's value is
    /// present at source but omitted by the initial output budget. The query
    /// observes the complete second state. This does not assert that a query
    /// can reveal a value that remains unavailable in the actual application.
    /// Keeping the first case source-incomplete makes the recovery decision
    /// independent of title-versus-value ranking; it must not turn into a
    /// passing already-visible-answer test when that ranking is corrected.
    private struct AXQueryRecoveryCase: Sendable {
        let id: String
        let target: String
        let expectedStatus: String
        let distractor: String
        let distractorStatus: String
        let targetSecond: Bool
        let targetValueInitiallyUnavailable: Bool

        static let original = Self(id: "order-a-first-initial-value-unavailable", target: "Order A", expectedStatus: "Arrives Tuesday",
            distractor: "Order B", distractorStatus: "Delivered Friday", targetSecond: false, targetValueInitiallyUnavailable: true)
        static let secondCard = Self(id: "shipment-cedar-second-value", target: "Shipment Cedar", expectedStatus: "Expected Thursday",
            distractor: "Shipment Maple", distractorStatus: "Delivered Monday", targetSecond: true, targetValueInitiallyUnavailable: false)
    }

    func testAXQueryRecoveryFixturesKeepTargetStatusMissingUntilQueriedObservation() throws {
        for scenario in [AXQueryRecoveryCase.original, .secondCard] {
            let fixture = try makeAXQueryRecoveryFixture(scenario)
            let initial = try XCTUnwrap(fixture["initial"])
            let targeted = try XCTUnwrap(fixture["targeted"])
            XCTAssertFalse(initial.contains(scenario.expectedStatus))
            XCTAssertTrue(initial.contains(scenario.distractorStatus))
            XCTAssertTrue(targeted.contains(scenario.expectedStatus))
            XCTAssertTrue(initial.contains("output_truncated=1"))
            XCTAssertTrue(initial.count <= 3_000 && targeted.count <= 1_000)
        }
    }

    private func runAXQueryRecoveryCase(_ scenario: AXQueryRecoveryCase) async throws {
        let root = try fixtureRoot("AXQueryRecovery-\(scenario.id)")
        print("HEYDASH_AX_QUERY_RECOVERY_CASE_STARTED case=\(scenario.id) targetSourcePosition=\(scenario.targetSecond ? 2 : 1) fixture=\(root.path)")
        let developerInstructions = ComputaAgentInstructions.developerInstructions()
        let expected = scenario.expectedStatus
        let fixture: [String: String]
        do {
            fixture = try makeAXQueryRecoveryFixture(scenario)
        } catch {
            attach("axQueryRecoveryVerified=false\ncase=\(scenario.id)\nfixturePreconditionsFailed=true\nmodelStarted=false\nerror=\(error.localizedDescription)\nfixtureRoot=\(root.path)")
            throw error
        }
        let fixtureURL = root.appendingPathComponent("ax-query-recovery.json")
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: fixtureURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixtureURL.path)
        let runtime = try makeRuntime(root: root, phase: "within", payload: "ax-query-recovery")
        let audit = Audit(taskID: "ax-query-recovery-\(UUID().uuidString)",
            permittedSyntheticTools: ["computer_v2_apps", "computer_v2_open", "computer_v2_read_page"], permitsUnboundSnapshotFailure: true)
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        let prompt = "In the already-running Computa Orders Fixture app, what is the delivery status for \(scenario.target)? Return only its exact status text."
        do {
            try require(try await runtime.loadTasks().isEmpty, "The diagnostic requires isolated history.")
            try await send(prompt, runtime: runtime, audit: audit, timeoutSeconds: 120)
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            let records = try toolAudit(root, phase: "within")
            let calls = records.filter { $0["kind"] as? String == "query-recovery" }
            let stages = calls.compactMap { $0["stage"] as? String }
            let missingTextRecovery = stages.contains("initial")
            let mode = missingTextRecovery ? "missing_text_recovery" : "direct_lookup"
            attach("axQueryRecoveryDiagnostic=true\nrealQwen=true\nownedRuntime=true\ndesktopExecuted=false\n"
                + "case=\(scenario.id)\nsyntheticInitialElementLimit=6\nshortLiteralQuery=\(scenario.target)\n"
                + "targetSourcePosition=\(scenario.targetSecond ? 2 : 1)\ntargetStatusBacking=value\ndistractorStatusBacking=title\n"
                + "targetValueInitiallyUnavailable=\(scenario.targetValueInitiallyUnavailable)\n"
                + "observedMode=\(mode)\nbindingRecovery=\(stages.contains("unbound"))\n"
                + "elapsedSeconds=\(Date.now.timeIntervalSince(audit.startedAt))\n"
                + "stages=\(stages.joined(separator: ","))\nfinal=\(audit.finalReply ?? "<none>")\nfixtureRoot=\(root.path)")
            try require(!records.contains { ["blocked", "proxy-error", "query-limit"].contains($0["kind"] as? String ?? "") },
                "An unsupported call, repeated observation, or fixture limit stopped the diagnostic.")
            try require(!trace.messages.contains { $0.method == "item/tool/call" || $0.method == "thread/inject_items" },
                "No server tool request may reach the real desktop executor; no history injection is permitted.")

            let start = try exactlyOne("thread/start", in: trace)
            let params = try XCTUnwrap(start.object["params"] as? [String: Any])
            let tools = try XCTUnwrap(params["dynamicTools"] as? [[String: Any]])
            try require(NSArray(array: tools).isEqual(to: ComputerV2ToolContract.referenceSpecs(for: model) + [ComputerOutcomeToolContract.spec]),
                "Use all current production model tools, not a narrowed fixture contract.")
            let baseInstructions = try XCTUnwrap(params["baseInstructions"] as? String)
            try require(baseInstructions.hasPrefix(CodexAppServerRuntime.Configuration.externalLocalQwen.baseInstructions)
                && baseInstructions.contains(ComputerV2ToolContract.instructions(for: .backgroundOnly))
                && !baseInstructions.contains(scenario.target) && !baseInstructions.contains(scenario.expectedStatus),
                "The diagnostic must retain production native policy without fixture-specific strategy hints.")
            let submitted = try exactlyOne("turn/start", in: trace)
            let submittedInput = try XCTUnwrap((submitted.object["params"] as? [String: Any])?["input"] as? [[String: Any]])
            try require(submittedInput.count == 1 && submittedInput[0]["text"] as? String == prompt,
                "Only the unchanged natural question may be submitted; no retry or helper prompt.")
            let reply = try rpcReply(to: submitted, in: trace)
            let turnID = try XCTUnwrap(((reply.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let done = try terminal(turnID: turnID, in: trace)
            let completions = trace.messages.filter { message in
                let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any]
                return message.method == "item/completed" && item?["type"] as? String == "dynamicToolCall"
            }
            try require(completions.count == calls.count, "Every intercepted call needs exactly one correlated tool completion.")
            for (call, completion) in zip(calls, completions) {
                let completed = try XCTUnwrap(completion.object["params"] as? [String: Any])
                let item = try XCTUnwrap(completed["item"] as? [String: Any])
                let contents = try XCTUnwrap(item["contentItems"] as? [[String: Any]])
                let text = try XCTUnwrap(contents.first?["text"] as? String)
                let stage = try XCTUnwrap(call["stage"] as? String)
                let expectedSuccess = stage != "unbound"
                try require(completed["turnId"] as? String == turnID && call["turnId"] as? String == turnID
                    && item["id"] as? String == call["callId"] as? String
                    && item["tool"] as? String == call["tool"] as? String
                    && item["success"] as? Bool == expectedSuccess && call["success"] as? Bool == expectedSuccess
                    && contents.count == 1 && contents.first?["type"] as? String == "inputText"
                    && SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() == call["payloadSHA256"] as? String
                    && completion.sequence < done.sequence, "Synthetic result identity, bytes, order, or turn changed.")
                if let original = fixture[["query", "direct-query"].contains(stage) ? "targeted" : stage] {
                    try require(text == original, "The completed tool must contain the exact Swift-formatted observation.")
                }
            }
            let unboundCalls = calls.filter { $0["stage"] as? String == "unbound" }
            try require(unboundCalls.count <= 1 && audit.unboundSnapshotFailures == unboundCalls.count,
                "Only the one exact synthetic production no-bound-app failure may be tolerated.")
            let forbidden = Set(["commandExecution", "fileChange", "mcpToolCall", "webSearch"])
            try require(!trace.messages.contains {
                let item = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
                return $0.method == "item/completed" && forbidden.contains(item?["type"] as? String ?? "")
            }, "No built-in action is allowed in this no-desktop diagnostic.")
            let rollout = try RolloutPrimitiveTrace.loadLatest(in: root.path)
            try require(rollout.parseFailures.isEmpty && rollout.functionCalls.map(\.name) == calls.compactMap { $0["tool"] as? String }
                && rollout.functionCalls.map(\.callID) == calls.compactMap { $0["callId"] as? String },
                "Durable rollout must retain the same exact tool calls and order.")
            let raw = String(decoding: try Data(contentsOf: rollout.rolloutURL), as: UTF8.self).split(separator: "\n")
            let saved = try raw.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let session = try XCTUnwrap(saved.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any])
            try require(session["cwd"] as? String == CodexAppServerRuntime.Configuration.externalLocalQwen.workspacePath,
                "The production workspace must be unchanged.")
            let contextItems = saved.filter { $0["type"] as? String == "response_item" }
                .compactMap { $0["payload"] as? [String: Any] }
            try require(containsDeveloperInstructions(developerInstructions, in: contextItems),
                "The app-owned developer instructions must be present in actual model context with their developer role.")
            print("HEYDASH_AX_QUERY_RECOVERY_PROVENANCE_VERIFIED case=\(scenario.id) synthetic=true desktopExecuted=false terminalCompleted=true exactToolReceipts=true appOwnedInstructionsVerified=true answerQualityNotYetVerified=true fixture=\(root.path)")
            // Validate integrity before answer quality so failed answers retain
            // a proven terminal, exact synthetic results, and instruction provenance.
            let prefix = stages.prefix { ["status", "apps", "apps-default", "unbound"].contains($0) }
            let expectedStages = missingTextRecovery ? ["open", "initial", "query"] : ["open", "direct-query"]
            try require(Array(stages.dropFirst(prefix.count)) == expectedStages && calls.count <= 8
                && stages.filter { $0 == "status" }.count <= 1
                && stages.filter { ["apps", "apps-default"].contains($0) }.count <= 1,
                "Require binding then a literal query; classify a valid direct lookup separately from missing-text recovery.")
            let finalMessages = trace.messages.filter {
                let parameters = $0.object["params"] as? [String: Any]
                let item = parameters?["item"] as? [String: Any]
                return $0.method == "item/completed" && item?["type"] as? String == "agentMessage"
                    && parameters?["turnId"] as? String == turnID
            }
            let finalMessage = try XCTUnwrap(finalMessages.last, "A final assistant message is required.")
            let finalItem = try XCTUnwrap((finalMessage.object["params"] as? [String: Any])?["item"] as? [String: Any])
            try require(finalMessage.sequence > (completions.last?.sequence ?? Int.max)
                && finalMessage.sequence < done.sequence, "The final answer must follow the query result in the same completed turn.")
            try require((finalItem["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
                && audit.finalReply == expected, "The model did not return the exact status revealed only by the query.")
            try require(audit.compactions == 0, "This small recovery diagnostic should not need compaction.")
            print("HEYDASH_AX_QUERY_RECOVERY_VERIFIED case=\(scenario.id) synthetic=true desktopExecuted=false mode=\(mode) missingTextRecoveryVerified=\(missingTextRecovery) calls=\(calls.count) elapsedSeconds=\(Date.now.timeIntervalSince(audit.startedAt)) fixture=\(root.path)")
        } catch {
            _ = await runtime.shutdown()
            attach("axQueryRecoveryVerified=false\ncase=\(scenario.id)\nerror=\(error.localizedDescription)\nfixtureRoot=\(root.path)")
            throw error
        }
    }

    private func makeAXQueryRecoveryFixture(_ scenario: AXQueryRecoveryCase) throws -> [String: String] {
        var nodes = [[String: Any]]()
        func add(_ parent: Int?, _ role: String, title: String? = nil, value: String? = nil,
                 subrole: String? = nil, frame: [String: Double]? = nil) -> Int {
            let index = nodes.count
            var node: [String: Any] = ["index": index, "childIndices": [Int](),
                "depth": parent.map { (nodes[$0]["depth"] as! Int) + 1 } ?? 0,
                "role": role, "supportedActions": ["AXButton", "AXLink"].contains(role) ? ["AXPress"] : [], "isValueSettable": false]
            if let parent {
                node["parentIndex"] = parent
                var children = nodes[parent]["childIndices"] as! [Int]
                children.append(index)
                nodes[parent]["childIndices"] = children
            }
            if let title { node["title"] = title }
            if let value { node["value"] = value }
            if let subrole { node["subrole"] = subrole }
            if let frame { node["frame"] = frame }
            nodes.append(node)
            return index
        }
        let window = add(nil, "AXWindow", title: "Orders — Computa Orders Fixture",
            frame: ["x": 0, "y": 0, "width": 1_280, "height": 900])
        let document = add(window, "AXWebArea", title: "Orders")
        let navigation = add(document, "AXGroup", subrole: "AXLandmarkNavigation")
        for index in 0..<23 {
            _ = add(navigation, "AXLink", title: "Browse section \(index + 1)",
                frame: ["x": 20, "y": Double(50 + index * 24), "width": 140, "height": 20])
        }
        let main = add(document, "AXGroup", subrole: "AXLandmarkMain")
        var targetParent = -1
        var targetStatusIndex = -1
        let targetCard = (label: scenario.target, status: scenario.expectedStatus, titleBacked: false)
        let distractorCard = (label: scenario.distractor, status: scenario.distractorStatus, titleBacked: true)
        let cards = scenario.targetSecond ? [distractorCard, targetCard] : [targetCard, distractorCard]
        for (offset, entry) in cards.enumerated() {
            let (label, status, titleBacked) = entry
            let card = add(main, "AXGroup")
            if label == scenario.target { targetParent = card }
            let y = Double(220 + offset * 200)
            let heading = String((label + " — USB-C charging cable and accessories for everyday desk use "
                + String(repeating: "x", count: 20)).prefix(70))
            _ = add(card, "AXHeading", title: heading,
                frame: ["x": 200, "y": y, "width": 740, "height": 26])
            let statusIndex = add(card, "AXStaticText", title: titleBacked ? status : nil, value: titleBacked ? nil : status,
                frame: ["x": 200, "y": y + 36, "width": 300, "height": 24])
            if label == scenario.target { targetStatusIndex = statusIndex }
            _ = add(card, "AXButton", title: "Details",
                frame: ["x": 950, "y": y + 36, "width": 110, "height": 28])
        }
        var initialNodes = nodes
        if scenario.targetValueInitiallyUnavailable {
            try require(targetStatusIndex >= 0, "The synthetic target status node must exist.")
            initialNodes[targetStatusIndex].removeValue(forKey: "value")
            try require(initialNodes[targetStatusIndex]["title"] == nil
                && initialNodes[targetStatusIndex]["value"] == nil,
                "The first acquisition must genuinely lack the target text, not merely hide its output line.")
        }
        var raw: [String: Any] = ["id": UUID().uuidString,
            "application": ["processIdentifier": 4242, "bundleIdentifier": "com.ahmedelamin.ComputaOrdersFixture", "applicationName": "Computa Orders Fixture"],
            "limits": ["maxDepth": 16, "maxElements": 240, "maxChildrenPerElement": 80, "maxActionsPerElement": 12, "maxTextLength": 4096],
            "rootIndex": window, "elements": initialNodes, "wasTruncated": false]
        let initialTree = try JSONDecoder().decode(AccessibilityTreeSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        let initial = AccessibilitySnapshotTextFormatter(elementLimit: 6, fieldCharacterLimit: 72,
            outputCharacterLimit: 3_000, prioritizesRelevantElements: true, usesCompactElementLines: true,
            prioritizesFocusedDocument: true).format(initialTree)
        raw["id"] = UUID().uuidString
        raw["elements"] = nodes
        let queryTree = try JSONDecoder().decode(AccessibilityTreeSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        let targeted = AccessibilitySnapshotTextFormatter(elementLimit: 1_000, fieldCharacterLimit: 72,
            outputCharacterLimit: 1_000, prioritizesRelevantElements: true, preferredText: scenario.target,
            usesCompactElementLines: true).format(queryTree)
        try require(initial.contains("output_truncated=1") && initial.contains(scenario.distractorStatus) && !initial.contains(scenario.expectedStatus),
            "The initial real-format observation must omit only the requested card's status.")
        let statusLine = targeted.split(separator: "\n").first { $0.contains("value=\"\(scenario.expectedStatus)\"") }
        try require(statusLine?.hasSuffix("parent=\(targetParent)") == true && targeted.contains("parents=["),
            "The targeted real-format observation must reveal the status with its card association.")
        let application = ActivatedApplication(processIdentifier: 4242, bundleIdentifier: "com.ahmedelamin.ComputaOrdersFixture", localizedName: "Computa Orders Fixture")
        let open = String(decoding: try JSONEncoder().encode(application), as: UTF8.self)
            + "\nBound this app for the current turn. Observe before acting; no process ID is needed."

        let unbound = ComputerToolFailureEvidence.text(
            for: Failure(ComputerV2ToolContract.unboundApplicationMessage), tool: "computer_v2_read_page")
        let syntheticApps = [RunningApplicationInfo(processIdentifier: 4242,
            bundleIdentifier: "com.ahmedelamin.ComputaOrdersFixture", localizedName: "Computa Orders Fixture", activationPolicy: .regular,
            isActive: true, isHidden: false, isTerminated: false)]
        var fixture = ["queryLiteral": scenario.target, "open": open, "initial": initial, "targeted": targeted, "unbound": unbound,
                "apps": ComputerV2ToolContract.appInventory(syntheticApps, query: "Computa Orders Fixture"),
                "apps-default": ComputerV2ToolContract.appInventory(syntheticApps, query: nil)]
        // A shorter unique literal is a valid production query. Accept it only
        // after proving the real formatter returns exactly the same bytes.
        if let lastWord = scenario.target.split(separator: " ").last, lastWord.count >= 3 {
            let shortQuery = String(lastWord)
            let shortResult = AccessibilitySnapshotTextFormatter(elementLimit: 1_000, fieldCharacterLimit: 72,
                outputCharacterLimit: 1_000, prioritizesRelevantElements: true, preferredText: shortQuery,
                usesCompactElementLines: true).format(queryTree)
            try require(shortResult == targeted, "A short query alias must have identical actual formatter output.")
            fixture["shortQuery"] = shortQuery
        }
        return fixture
    }

    func testRealQwenNativeActivationFailureStopsWithoutInventedExplanation() async throws {
        try requireOptIn("HEYDASH_LIVE_NATIVE_FAILURE_STOP_TEST")
        let root = try fixtureRoot("NativeFailureStop")
        let taskID = "native-stop-\(UUID().uuidString)"
        let runtime = try makeRuntime(root: root, phase: "within", payload: "native-stop")
        var stopped = false
        var nativeMessages = [String]()
        var assistant = [String]()
        var connectionFailure: String?
        let pump = Task { @MainActor in
            for await event in runtime.events() {
                switch event {
                case .taskStatusChanged(let owner, .waiting) where owner == taskID: stopped = true
                case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                    if entry.title == "Native action stopped" { nativeMessages.append(entry.body) }
                    if entry.kind == .assistant, !nativeMessages.isEmpty { assistant.append(entry.body) }
                case .connectionChanged(.failed(let message)): connectionFailure = message
                case .approvalRequested(let request): try? await runtime.resolveApproval(requestID: request.id, approved: false)
                default: break
                }
            }
        }
        defer { pump.cancel() }
        let began = Date()
        do {
            _ = try await runtime.loadTasks()
            try await runtime.submit(prompt: "Call computer_v2_open exactly once with {\"bundle_id\":\"com.google.Chrome\"}. Tell me what happened. Do not call other tools.",
                toTaskID: taskID, modelID: model)
            for _ in 0..<240 where !stopped && connectionFailure == nil {
                try await Task.sleep(for: .milliseconds(250))
            }
            try require(stopped, connectionFailure ?? "The native boundary did not stop within 60 seconds.")
            try require(nativeMessages.count == 1 && nativeMessages[0].contains("cause is unknown"), "The factual native diagnostic is missing.")
            try require(assistant.isEmpty, "An assistant explanation escaped the native terminal boundary.")
            let tasks = try await runtime.loadTasks()
            try require(tasks.contains { $0.entries.contains { $0.title == "Native action stopped" && $0.body == nativeMessages[0] } }, "Evidence was not restored from the native store.")
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            let interrupt = try exactlyOne("turn/interrupt", in: trace)
            let calls = trace.messages.filter { $0.direction == .serverToClient && $0.method == "item/tool/call" }
            try require(calls.count == 1, "Expected exactly one server-to-client native tool call.")
            let call = try XCTUnwrap(calls.first)
            try require(call.sequence < interrupt.sequence, "The exact tool call must precede native stop.")
            try require(!trace.messages.contains { message in
                guard message.sequence > call.sequence, message.method == "item/completed",
                      let item = (message.object["params"] as? [String: Any])?["item"] as? [String: Any],
                      item["type"] as? String == "agentMessage" else { return false }
                return !(item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, "App Server emitted a post-failure explanation despite interruption.")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || ($0.object["params"] as? [String: Any])?["item"].flatMap { ($0 as? [String: Any])?["type"] as? String } == "contextCompaction" }, "Native stop must not trigger compaction.")
            print("HEYDASH_NATIVE_FAILURE_STOP_VERIFIED real_qwen=true owned_runtime=true synthetic_failure=true assistant_explanation=false elapsed_seconds=\(Date().timeIntervalSince(began)) fixture=\(root.path)")
        } catch { _ = await runtime.shutdown(); throw error }
    }

    func testColdAutomaticCompactionPrecedesUnchangedSubmissionAndRetainsCanary() async throws {
        try requireOptIn("HEYDASH_LIVE_COLD_AUTO_CONTEXT_TEST")
        let root = try fixtureRoot("ColdAuto")
        let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let originalTask = "cold-auto-\(UUID().uuidString)"
        let before = try makeRuntime(root: root, phase: "before", payload: "small")
        let beforeAudit = Audit(taskID: originalTask)
        let beforePump = pump(before, audit: beforeAudit)
        defer { beforePump.cancel() }
        let threadID: String
        let priorMeasuredTokens: Int
        do {
            let existing = try await before.loadTasks()
            try require(existing.isEmpty, "A cold fixture must start with an empty isolated home.")
            try await send(retentionPrompt(canary), runtime: before, audit: beforeAudit)
            try require(beforeAudit.finalReply == "KEY_SAVED", "The first real assistant acknowledgment must match.")
            // Stop at the first measured shipping-threshold footprint before another warm
            // submission could preflight it. User messages stay short and all
            // generated filler is genuine disposable assistant output.
            // Smaller batches reduce overshoot without weakening the measured
            // threshold/headroom requirements or the final exact-key assertion.
            let maximumWarmupRounds = 5 * shippingContext.contextWindow / 8_192
            for round in 1...maximumWarmupRounds {
                if beforeAudit.lastUsage?.usedTokens ?? 0 >= shippingContext.autoCompactTokenLimit { break }
                try await send("Write chapter \(round) of a fictional story about a walk through a peaceful park, roughly 800 words. "
                    + "This generated story is disposable background. "
                    + "Keep the original retention key but do not repeat it here. Do not use tools.",
                    runtime: before, audit: beforeAudit)
            }
            let usage = try XCTUnwrap(beforeAudit.lastUsage, "The cold starting footprint must be measured, not estimated.")
            priorMeasuredTokens = usage.usedTokens
            try require(usage.usedTokens >= shippingContext.autoCompactTokenLimit, "The fixture did not reach the production automatic threshold.")
            try require(usage.usedTokens < (usage.contextWindow ?? 0),
                "This fixture must start with usable headroom, not an already oversized history.")
            try await shutDown(before)
            beforePump.cancel()
            let trace = try readTrace(root, phase: "before")
            let start = try exactlyOne("thread/start", in: trace)
            let reply = try rpcReply(to: start, in: trace)
            threadID = try XCTUnwrap(((reply.object["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String)
            try requireToolAudit(root, phase: "before", expectedCalls: 0)
        } catch {
            _ = await before.shutdown()
            throw error
        }

        // A new Core/process receives no first-runtime usage/evidence state.
        let after = try makeRuntime(root: root, phase: "after", payload: "small")
        let afterAudit = Audit(taskID: threadID)
        let afterPump = pump(after, audit: afterAudit)
        defer { afterPump.cancel() }
        do {
            let tasks = try await after.loadTasks()
            try require(tasks.map(\.id) == [threadID], "Cold runtime did not recover exactly the fixture thread.")
            let prompt = recallPrompt
            // No compact() call: automatic cold-submission behavior is the gate.
            try await send(prompt, runtime: after, audit: afterAudit)
            try require(afterAudit.finalReply == canary, "Cold automatic compaction changed the exact retention key.")
            try require(afterAudit.statusTools == 1, "Expected exactly one completed synthetic status call.")
            try require(afterAudit.compactions > 0, "Cold automatic compaction did not occur.")
            try await shutDown(after)
            let trace = try readTrace(root, phase: "after")
            try require(!trace.messages.contains { $0.method == "thread/start" }, "Cold resume must not create a replacement thread.")
            let resume = try exactlyOne("thread/resume", in: trace)
            let compact = try exactlyOne("thread/compact/start", in: trace)
            let injection = try exactlyOne("thread/inject_items", in: trace)
            let user = try exactlyOne("turn/start", in: trace)
            let params = try XCTUnwrap(user.object["params"] as? [String: Any])
            let input = try XCTUnwrap(params["input"] as? [[String: Any]])
            try require(input.count == 1 && input.first?["text"] as? String == prompt,
                "The user prompt must remain unchanged, with no hidden retry or helper prompt.")
            try require(try rpcReply(to: resume, in: trace).sequence < compact.sequence, "Resume must precede automatic maintenance.")
            try require(try rpcReply(to: compact, in: trace).sequence < injection.sequence, "Compaction acknowledgment must precede restoration.")
            try require(try rpcReply(to: injection, in: trace).sequence < user.sequence, "Durable restoration must precede user submission.")
            try verifyCompactionLifecycle(trace, beforeSequence: injection.sequence)
            try requireToolAudit(root, phase: "after", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "after")
            attach("coldAutomaticVerified=true\nstartingMeasuredTokens=\(priorMeasuredTokens)\n"
                + "exactCanaryRetained=true\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await after.shutdown()
            throw error
        }
    }

    func testNativeWithinTurnCompactionAfterBoundedToolResultRetainsCanaryWithoutRepeatedAction() async throws {
        try requireOptIn("HEYDASH_LIVE_WITHIN_TURN_CONTEXT_TEST")
        let root = try fixtureRoot("WithinTurn")
        let taskID = "within-turn-\(UUID().uuidString)"
        let canary = "HD_KEEP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let runtime = try makeRuntime(root: root, phase: "within", payload: "bounded-observation")
        let audit = Audit(taskID: taskID)
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        do {
            let tasks = try await runtime.loadTasks()
            try require(tasks.isEmpty, "The within-turn fixture must start isolated.")
            try await send(retentionPrompt(canary), runtime: runtime, audit: audit)
            try require(audit.finalReply == "KEY_SAVED", "The real first acknowledgment must match.")
            // App Server bounds the synthetic tool result before adding it to
            // model context. A short real assistant reply provides enough
            // existing history for that bounded result to cross the threshold.
            // The following measured gate still forbids pre-turn compaction.
            try await send("Generate exactly 40 numbered lines. Each line must contain ten plain words describing a fictional park. "
                + "This generated text is disposable. Keep the original retention key but do not repeat it here. Do not use tools.",
                runtime: runtime, audit: audit)
            let before = try XCTUnwrap(audit.lastUsage)
            try require(before.usedTokens < forcedWithinTurnLimit && audit.compactions == 0,
                "This gate must begin below its explicit fixture threshold, without preflight compaction.")
            try await send(recallPrompt, runtime: runtime, audit: audit)
            try require(audit.finalReply == canary, "The within-turn continuation must return the complete exact key.")
            try require(audit.statusTools == 1, "The observed action must not be repeated after native compaction.")
            try require(audit.compactions == 1, "Expected one native within-turn compaction, not zero or churn.")
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" },
                "A managed idle or injected-history path cannot stand in for native within-turn compaction.")
            let starts = trace.messages.filter { $0.method == "turn/start" }
            try require(starts.count == 3, "Only retention, warmup, and recall turns are permitted; no hidden retries.")
            let user = try XCTUnwrap(starts.last)
            let response = try rpcReply(to: user, in: trace)
            let turnID = try XCTUnwrap(((response.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
            let compactStart = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
            let compactEnd = try exactlyOneCompletedItem("contextCompaction", in: trace)
            for item in [status, compactStart, compactEnd] {
                try require((item.object["params"] as? [String: Any])?["turnId"] as? String == turnID,
                    "Status and compaction must belong to the exact same user turn.")
            }
            try require(status.sequence < compactStart.sequence && compactStart.sequence < compactEnd.sequence,
                "The tool result must cause compaction inside the active turn.")
            let terminal = try terminal(turnID: turnID, in: trace)
            try require(compactEnd.sequence < terminal.sequence, "Continuation must complete after native compaction.")
            try requireToolAudit(root, phase: "within", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "within")
            attach("nativeWithinTurnVerified=true\npreTurnMeasuredTokens=\(before.usedTokens)\n"
                + "fixtureCompactLimit=\(forcedWithinTurnLimit)\nshippingThresholdStressVerified=false\n"
                + "exactCanaryRetained=true\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private var recallPrompt: String {
        "Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
            + "After the result, reply with only the exact retention key recorded in my first user message."
    }

    func testNativeWithinTurnCompactionPreservesUnseenImageForRealQwen() async throws {
        try requireOptIn("HEYDASH_LIVE_WITHIN_TURN_IMAGE_CONTEXT_TEST")
        let root = try fixtureRoot("WithinTurnImage")
        let palette: [(String, [CGFloat])] = [("red", [1, 0, 0]), ("green", [0, 1, 0]),
            ("blue", [0, 0, 1]), ("yellow", [1, 1, 0]), ("cyan", [0, 1, 1]), ("magenta", [1, 0, 1])]
        let colors = Array(palette.shuffled().prefix(4))
        let expected = colors.map(\.0).joined(separator: ",")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 512, height: 160,
            bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 512, height: 160))
        for (index, color) in colors.enumerated() {
            canvas.setFillColor(CGColor(red: color.1[0], green: color.1[1], blue: color.1[2], alpha: 1))
            canvas.fill(CGRect(x: CGFloat(14 + index * 128), y: 30, width: 100, height: 100))
        }
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), nil)
        try require(CGImageDestinationFinalize(destination), "Synthetic PNG encoding failed.")
        let bytes = png as Data
        try require(bytes.count < 512 * 1024, "Synthetic PNG exceeds its fixture limit.")
        let imageSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let imageURL = root.appendingPathComponent("status-image.png")
        try bytes.write(to: imageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
        let runtime = try makeRuntime(root: root, phase: "within", payload: "bounded-image")
        let audit = Audit(taskID: "within-image-\(UUID().uuidString)")
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        do {
            let tasks = try await runtime.loadTasks()
            try require(tasks.isEmpty, "The image fixture must start isolated.")
            try await send("Reply only IMAGE_FIXTURE_READY. Do not use tools.", runtime: runtime, audit: audit)
            try require(audit.finalReply == "IMAGE_FIXTURE_READY", "The initial acknowledgment must match.")
            try await send("Generate exactly 40 numbered lines. Each line must contain ten plain words describing a fictional park. "
                + "This generated text is disposable. Do not use tools.", runtime: runtime, audit: audit)
            let before = try XCTUnwrap(audit.lastUsage)
            try require(before.usedTokens < forcedWithinTurnLimit && audit.compactions == 0,
                "The image gate must begin below its explicit fixture threshold without preflight compaction.")
            let prompt = "Call computer_v2_status exactly once with empty arguments {}. Do not use other tools. "
                + "Its synthetic result includes an image with four solid colored squares. "
                + "Read the colors left to right and reply only four lowercase color names separated by commas, with no spaces. "
                + "The possible color names are red, green, blue, yellow, cyan, magenta."
            try require(!prompt.contains(expected), "The expected image answer must not be supplied as text.")
            try await send(prompt, runtime: runtime, audit: audit)
            try require(audit.finalReply == expected, "Qwen did not correctly read the unseen image after compaction.")
            try require(audit.statusTools == 1 && audit.compactions == 1,
                "Exactly one status call and one native within-turn compaction are required.")
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" },
                "An idle compaction or history injection cannot substitute for native mid-turn image retention.")
            let starts = trace.messages.filter { $0.method == "turn/start" }
            try require(starts.count == 3, "Only acknowledgment, warmup, and image turns are permitted.")
            let user = try XCTUnwrap(starts.last)
            let response = try rpcReply(to: user, in: trace)
            let turnID = try XCTUnwrap(((response.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
            let compactStart = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
            let compactEnd = try exactlyOneCompletedItem("contextCompaction", in: trace)
            for item in [status, compactStart, compactEnd] {
                try require((item.object["params"] as? [String: Any])?["turnId"] as? String == turnID,
                    "Image result and compaction must belong to the exact same user turn.")
            }
            let done = try terminal(turnID: turnID, in: trace)
            try require(status.sequence < compactStart.sequence && compactStart.sequence < compactEnd.sequence
                && compactEnd.sequence < done.sequence,
                "The image result must precede native compaction and successful continuation.")
            try requireToolAudit(root, phase: "within", expectedCalls: 1)
            try verifyOnlySyntheticStatus(trace, root: root, phase: "within", imageSHA256: imageSHA256)
            let rollout = try RolloutPrimitiveTrace.loadLatest(in: root.path)
            try require(rollout.parseFailures.isEmpty && rollout.functionCalls.count == 1,
                "The isolated native rollout must contain exactly one actual tool call.")
            let lines = String(decoding: try Data(contentsOf: rollout.rolloutURL), as: UTF8.self).split(separator: "\n")
            let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let checkpoints = records.filter { $0["type"] as? String == "compacted" }
            try require(checkpoints.count == 1, "Exactly one durable replacement checkpoint is required.")
            let checkpoint = try XCTUnwrap(checkpoints.first?["payload"] as? [String: Any])
            let history = try XCTUnwrap(checkpoint["replacement_history"] as? [[String: Any]])
            let outputs = history.filter { $0["type"] as? String == "function_call_output" }
            try require(outputs.count == 1 && outputs.first?["call_id"] as? String == rollout.functionCalls.first?.callID,
                "The retained image must belong to the original exact status call.")
            let content = try XCTUnwrap(outputs.first?["output"] as? [[String: Any]])
            let images = content.filter { $0["type"] as? String == "input_image" }
            try require(images.count == 1, "The latest image must survive exactly once in replacement history.")
            try verifyImage(try XCTUnwrap(images.first?["image_url"] as? String), digest: imageSHA256)
            attach("nativeWithinTurnImageVerified=true\npreTurnMeasuredTokens=\(before.usedTokens)\n"
                + "fixtureCompactLimit=\(forcedWithinTurnLimit)\nshippingThresholdStressVerified=false\n"
                + "unseenColorOrderCorrect=true\nretainedImageSHA256=\(imageSHA256)\nsyntheticStatusCalls=1\nfixtureRoot=\(root.path)")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    private func retentionPrompt(_ canary: String) -> String {
        "Remember this important retention key for this task: \(canary). "
            + "Preserve this exact key in any future context summary. Reply only KEY_SAVED; do not use tools."
    }

    func testRealQwenReportsActivationFailureWithoutInventingPolicyCause() async throws {
        try requireOptIn("HEYDASH_LIVE_ACTIVATION_EVIDENCE_TEST")
        try await runActivationEvidenceGate(forceCompaction: false)
    }

    func testNativeCompactionDoesNotTurnActivationFailureIntoPolicyDiagnosis() async throws {
        try requireOptIn("HEYDASH_LIVE_COMPACT_ACTIVATION_EVIDENCE_TEST")
        try await runActivationEvidenceGate(forceCompaction: true)
    }

    func testAttributionCheckRejectsGuessesWithoutRejectingTheStandingPolicy() throws {
        for text in ["StudyLock policy must remain intact throughout all operations.",
                     "StudyLock policy is active; no bypass attempts allowed.",
                     "No evidence establishes StudyLock enforcement as the cause.",
                     "StudyLock involvement is unknown.",
                     "**StudyLock Enforcement**: Strict baseline preserved. No weakening, allowlists, or exemptions applied.",
                     "Resume any pending tasks while maintaining StudyLock enforcement.",
                     "Pending tasks should proceed while preserving StudyLock items.",
                     "User Preferences: None explicitly stated beyond StudyLock compliance and Chrome access request."] {
            XCTAssertNoThrow(try verifyNoInventedPolicyCause(text, surface: "unit fixture"))
        }
        for text in ["Chrome could not be activated, likely due to StudyLock enforcement or browser state.",
                     "StudyLock is actively blocking Chrome.",
                     "The cause is unknown but StudyLock is blocking Chrome.",
                     "Chrome is inaccessible due to the security policy.",
                     "Disable StudyLock and try Chrome again.",
                     "StudyLock Enforcement: Strict baseline preserved, which caused the activation failure.",
                     "Chrome was denied while maintaining StudyLock enforcement.",
                     "The website is blocked while preserving StudyLock items.",
                     "The failure was due to StudyLock compliance and Chrome access request.",
                     "StudyLock definitely did not cause the activation failure.",
                     "Error Type: Native tool failure, not a StudyLock block."] {
            XCTAssertThrowsError(try verifyNoInventedPolicyCause(text, surface: "unit fixture"))
        }
    }

    /// The question specifies the one diagnostic call, not a cause or expected answer. Only
    /// the intercepted native diagnostic is synthetic; app-owned instructions,
    /// the model and runtime path remain production ones. The forced-compaction
    /// variant uses an explicit fixture threshold, not a shipping-capacity gate.
    private func runActivationEvidenceGate(forceCompaction: Bool) async throws {
        let root = try fixtureRoot(forceCompaction ? "CompactActivationEvidence" : "ActivationEvidence")
        let developerInstructions = ComputaAgentInstructions.developerInstructions()
        let instructionsHash = SHA256.hash(data: Data(developerInstructions.utf8)).map { String(format: "%02x", $0) }.joined()
        let failureText = ComputerToolFailureEvidence.text(for:
            ComputerInputError.applicationActivationFailed(processIdentifier: 52339))
        let runtime = try makeRuntime(root: root, phase: "within",
            payload: forceCompaction ? "bounded-activation-failure" : "activation-failure", failureText: failureText)
        let audit = Audit(taskID: "activation-evidence-\(UUID().uuidString)", permitsActivationFailure: true)
        let events = pump(runtime, audit: audit)
        defer { events.cancel() }
        do {
            try require(try await runtime.loadTasks().isEmpty, "The diagnostic gate must start with isolated history.")
            if forceCompaction {
                try await send("Reply only FIXTURE_READY. Do not use tools.", runtime: runtime, audit: audit)
                try require(audit.finalReply == "FIXTURE_READY", "The initial acknowledgment must match.")
                let before = try XCTUnwrap(audit.lastUsage)
                try require(before.usedTokens < forcedWithinTurnLimit && audit.compactions == 0,
                    "The diagnostic gate must begin below its explicit fixture threshold without preflight compaction.")
            }
            let prompt = "Call computer_v2_open exactly once with {\"bundle_id\":\"com.google.Chrome\"}. "
                + "Tell me what happened and what to do next. Do not call other tools."
            try await send(prompt, runtime: runtime, audit: audit)
            let final = try XCTUnwrap(audit.finalReply)
            try await shutDown(runtime)
            let trace = try readTrace(root, phase: "within")
            try require(!trace.messages.contains { $0.method == "thread/compact/start" || $0.method == "thread/inject_items" },
                "Only native in-turn compaction is permitted; no injected history or hidden retries.")
            let starts = trace.messages.filter { $0.method == "turn/start" }
            try require(starts.count == (forceCompaction ? 2 : 1), "The gate must not silently retry or add helper prompts.")
            let user = try XCTUnwrap(starts.last)
            let input = try XCTUnwrap((user.object["params"] as? [String: Any])?["input"] as? [[String: Any]])
            try require(input.count == 1 && input.first?["text"] as? String == prompt,
                "The natural diagnostic question must arrive unchanged.")
            let response = try rpcReply(to: user, in: trace)
            let turnID = try XCTUnwrap(((response.object["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String)
            let toolCompletions = trace.messages.filter {
                let entry = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
                return $0.method == "item/completed" && entry?["type"] as? String == "dynamicToolCall"
            }
            let openCompletions = toolCompletions.filter {
                (($0.object["params"] as? [String: Any])?["item"] as? [String: Any])?["tool"] as? String == "computer_v2_open"
            }
            let statusCompletions = toolCompletions.filter {
                (($0.object["params"] as? [String: Any])?["item"] as? [String: Any])?["tool"] as? String == "computer_v2_status"
            }
            try require(openCompletions.count == 1 && statusCompletions.count <= 1
                && toolCompletions.count == openCompletions.count + statusCompletions.count,
                "Only one failed open and at most one permission preflight are permitted.")
            let completed = try XCTUnwrap(openCompletions.first)
            let params = try XCTUnwrap(completed.object["params"] as? [String: Any])
            let item = try XCTUnwrap(params["item"] as? [String: Any])
            try require(item["tool"] as? String == "computer_v2_open" && item["success"] as? Bool == false
                && params["turnId"] as? String == turnID, "Exactly one native-shaped failed Chrome open is required.")
            let contents = try XCTUnwrap(item["contentItems"] as? [[String: Any]])
            let diagnosticText = try XCTUnwrap(contents.first?["text"] as? String)
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diagnosticText.utf8)) as? [String: Any])
            let originalDiagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failureText.utf8)) as? [String: Any])
            try require(contents.count == 1 && contents.first?["type"] as? String == "inputText"
                && originalDiagnostic.allSatisfy { key, value in
                    guard let returned = diagnostic[key] else { return false }
                    return NSDictionary(dictionary: [key: value]).isEqual(to: [key: returned])
                }, "The fixture must return the exact production diagnostic, with only disposable padding added.")
            let calls = try toolAudit(root, phase: "within")
            let preflightCalls = calls.filter { $0["kind"] as? String == "activation-preflight" }
            try require(calls.filter { $0["kind"] as? String == "activation-failure" }.count == 1
                && preflightCalls.count == statusCompletions.count && audit.statusTools == statusCompletions.count
                && !calls.contains { ["blocked", "proxy-error"].contains($0["kind"] as? String ?? "") },
                "The model attempted an extra, malformed, or interactive action.")
            if let preflight = statusCompletions.first {
                let preflightParams = try XCTUnwrap(preflight.object["params"] as? [String: Any])
                let preflightItem = try XCTUnwrap(preflightParams["item"] as? [String: Any])
                let preflightContent = try XCTUnwrap(preflightItem["contentItems"] as? [[String: Any]])
                let preflightText = try XCTUnwrap(preflightContent.first?["text"] as? String)
                let preflightOutput = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preflightText.utf8)) as? [String: Any])
                try require(preflight.sequence < completed.sequence && preflightParams["turnId"] as? String == turnID
                    && preflightItem["success"] as? Bool == true
                    && preflightItem["id"] as? String == preflightCalls.first?["callId"] as? String
                    && preflightContent.count == 1 && preflightContent.first?["type"] as? String == "inputText"
                    && preflightOutput.count == 3
                    && preflightOutput["fixture"] as? String == "synthetic permission status; no desktop was inspected or changed"
                    && preflightOutput["accessibility"] as? String == "granted"
                    && preflightOutput["screenRecording"] as? String == "granted",
                    "An optional status must be the exact synthetic permission preflight before the failed open.")
            }
            try require(!trace.messages.contains { $0.method == "item/tool/call" },
                "No request may reach the real desktop executor.")
            let forbidden = Set(["commandExecution", "fileChange", "mcpToolCall", "webSearch"])
            try require(!trace.messages.contains {
                let entry = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
                return $0.method == "item/completed" && forbidden.contains(entry?["type"] as? String ?? "")
            }, "Unexpected built-in action appeared in the synthetic diagnostic gate.")
            let done = try terminal(turnID: turnID, in: trace)
            try require(audit.compactions == (forceCompaction ? 1 : 0), "Unexpected compaction count.")
            if forceCompaction {
                let start = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
                let end = try exactlyOneCompletedItem("contextCompaction", in: trace)
                try require((start.object["params"] as? [String: Any])?["turnId"] as? String == turnID
                    && (end.object["params"] as? [String: Any])?["turnId"] as? String == turnID
                    && completed.sequence < start.sequence && start.sequence < end.sequence && end.sequence < done.sequence,
                    "The failed tool result must precede native compaction and same-turn continuation.")
            }
            let rollout = try RolloutPrimitiveTrace.loadLatest(in: root.path)
            let expectedNames = statusCompletions.isEmpty ? ["computer_v2_open"] : ["computer_v2_status", "computer_v2_open"]
            try require(rollout.parseFailures.isEmpty && rollout.functionCalls.map(\.name) == expectedNames,
                "The native rollout must contain exactly the optional preflight then the original failed open.")
            let failedCall = try XCTUnwrap(rollout.functionCalls.last)
            let lines = String(decoding: try Data(contentsOf: rollout.rolloutURL), as: UTF8.self).split(separator: "\n")
            let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let session = try XCTUnwrap(records.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any])
            try require(session["cwd"] as? String == CodexAppServerRuntime.Configuration.externalLocalQwen.workspacePath,
                "The diagnostic fixture must use the unchanged production workspace.")
            let initial = records.filter { $0["type"] as? String == "response_item" }
                .compactMap { $0["payload"] as? [String: Any] }
            try require(containsDeveloperInstructions(developerInstructions, in: initial),
                "The app-owned developer instructions are missing from model context or have the wrong role.")
            let checkpoints = records.filter { $0["type"] as? String == "compacted" }
                .compactMap { $0["payload"] as? [String: Any] }
            try require(checkpoints.count == (forceCompaction ? 1 : 0), "The durable checkpoint count must match the native lifecycle.")
            for checkpoint in checkpoints {
                let history = try XCTUnwrap(checkpoint["replacement_history"] as? [[String: Any]])
                try require(containsDeveloperInstructions(developerInstructions, in: history),
                    "Mid-turn compaction must preserve the app-owned instructions verbatim with their developer role.")
                let outputs = history.filter { $0["type"] as? String == "function_call_output" }
                let retainedIDs = outputs.compactMap { $0["call_id"] as? String }
                let retainedFailure = try XCTUnwrap(outputs.first { $0["call_id"] as? String == failedCall.callID })
                try require(retainedIDs == rollout.functionCalls.map(\.callID)
                    && containsString("application_activation_failed", in: retainedFailure),
                    "The genuine failed diagnostic and optional preflight must survive with their exact identities and order.")
            }
            let summaries = checkpoints.compactMap { $0["message"] as? String }
            let evidence = "forcedCompaction=\(forceCompaction)\nappOwnedInstructionsSHA256=\(instructionsHash)\n"
                + "syntheticFailedOpenCalls=1\nsyntheticPermissionPreflights=\(statusCompletions.count)\nfixtureRoot=\(root.path)\n"
                + "Manual review required; automated checks are conservative language checks, not a semantic correctness proof.\n"
                + "SUMMARIES:\n\(summaries.joined(separator: "\n---\n"))\nFINAL:\n\(final)"
            attach(evidence)
            // Preserve both surfaces before assertions, so even an unexpected
            // phrasing is reviewable rather than hidden by a permissive matcher.
            for (index, summary) in summaries.enumerated() {
                try verifyNoInventedPolicyCause(summary, surface: "summary \(index + 1)")
            }
            try verifyNoInventedPolicyCause(final, surface: "final response")
            let normalized = final.lowercased()
            try require(normalized.contains("activat") || normalized.contains("open chrome") || normalized.contains("open google chrome"),
                "The response must identify the observed application-opening failure.")
            try require(["undetermined", "unknown", "not established", "not confirmed", "could not determine", "cannot determine", "can't determine", "unconfirmed"]
                .contains(where: normalized.contains), "The response must preserve uncertainty about the cause.")
        } catch {
            _ = await runtime.shutdown()
            throw error
        }
    }

    func testInstructionProvenanceRequiresExactDeveloperContentRatherThanQuotedHistory() {
        let instructions = "App-owned instruction fixture: retain exact content."
        func message(_ role: String, _ text: String) -> [String: Any] {
            ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        }
        XCTAssertTrue(containsDeveloperInstructions(instructions, in: [message("developer", instructions)]))
        XCTAssertFalse(containsDeveloperInstructions(instructions, in: [message("user", instructions)]))
        XCTAssertFalse(containsDeveloperInstructions(instructions, in: [message("assistant", instructions)]))
        XCTAssertFalse(containsDeveloperInstructions(instructions, in: [message("developer", "Summarized instructions")]))
        XCTAssertFalse(containsDeveloperInstructions(instructions, in: [["type": "function_call_output", "output": instructions]]))
    }

    private func containsDeveloperInstructions(_ instructions: String, in items: [[String: Any]]) -> Bool {
        items.contains { item in
            item["type"] as? String == "message" && item["role"] as? String == "developer"
                && containsString(instructions, in: item["content"] ?? [])
        }
    }

    private func containsString(_ needle: String, in value: Any) -> Bool {
        if let text = value as? String { return text.contains(needle) }
        if let list = value as? [Any] { return list.contains { containsString(needle, in: $0) } }
        if let object = value as? [String: Any] { return object.values.contains { containsString(needle, in: $0) } }
        return false
    }

    private func verifyNoInventedPolicyCause(_ text: String, surface: String) throws {
        let clauses = text.lowercased().components(separatedBy: CharacterSet(charactersIn: ".\n;"))
        for clause in clauses where clause.contains("studylock") || clause.contains("firewall")
            || clause.contains("security policy") || clause.contains("network restriction") {
            let causal = ["due to", "because", "caused", "blocking", "blocked", "enforcement", "prevented", "denied"]
                .contains(where: clause.contains)
            let evidenceNegation = ["no evidence", "not confirmed", "not established", "cannot conclude",
                                    "does not establish", "does not prove", "unverified"].contains(where: clause.contains)
                && ![" but ", " however ", " nonetheless "].contains(where: clause.contains)
            let unknownWithoutCausalClaim = ["undetermined", "unknown"].contains(where: clause.contains)
                && !["due to", "because", "caused", "blocking", "blocked", "prevented", "denied"].contains(where: clause.contains)
            let explicitlyUnconfirmed = evidenceNegation || unknownWithoutCausalClaim
            // Merely mentioning the requested app is not a failure diagnosis.
            // Preservation statements remain permitted only without a concrete
            // failure/cause link; affirmative or exclusionary diagnoses fail.
            let relatesToFailure = ["activation", "failed", "failure", "error", "inaccessible", "blocked", "blocking",
                                    "denied", "prevented", "cause", "due to", "because", "responsible"]
                .contains(where: clause.contains)
            let plainClause = clause.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            let standingPreservation = ["studylock enforcement: strict baseline preserved",
                                       "while maintaining studylock enforcement", "while preserving studylock items",
                                       "studylock compliance and chrome access request"].contains(where: plainClause.contains)
            let standingRuleOnly = !relatesToFailure && ((!causal && clause.contains("policy"))
                || ["must remain", "no bypass", "do not bypass", "respect", "non-bypass"].contains(where: clause.contains)
                || standingPreservation)
            try require(explicitlyUnconfirmed || standingRuleOnly,
                "\(surface) contains an unsupported or ambiguous restriction attribution; inspect its saved attachment.")
        }
        let lower = text.lowercased()
        try require(!["disable studylock", "bypass studylock", "turn off studylock", "remove studylock"].contains { phrase in
            lower.components(separatedBy: "\n").contains { $0.contains(phrase)
                && !$0.contains("not ") && !$0.contains("never ") && !$0.contains("cannot ") && !$0.contains("no ") }
        }, "\(surface) proposes changing protection despite no evidence it caused this failure.")
    }

    private func requireOptIn(_ name: String) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[name] == "1",
            "Opt in with TEST_RUNNER_\(name)=1; serial live inference only.")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/Users/ahmedelamin/.bun/bin/bun"),
            "The no-desktop live wrapper requires the installed Bun executable.")
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Computa\(name)Live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReadOnlyLiveCompactionProxy.ts")
        let executable = root.appendingPathComponent("read-only-live-proxy.ts")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        print("automaticPathFixtureRoot=\(root.path)")
        return root
    }

    private func makeRuntime(root: URL, phase: String, payload: String, failureText: String? = nil) throws -> CodexAppServerRuntime {
        let artifact = try ComputaRuntimeArtifact.resolve()
        var fixture: [String: String] = ["executable": artifact.executableURL.path,
                                       "payload": payload, "auditName": phase]
        if let failureText { fixture["failureText"] = failureText }
        try JSONSerialization.data(withJSONObject: fixture).write(to: root.appendingPathComponent("read-only-proxy.json"))
        var config = CodexAppServerRuntime.Configuration.externalLocalQwen
        config.executable = .fixture(path: root.appendingPathComponent("read-only-live-proxy.ts").path)
        config.codexHomePath = root.path
        config.protocolTracePath = root.appendingPathComponent("\(phase)-protocol.jsonl").path
        config.model = model
        if payload == "native-stop" { config.fixtureActivationFailurePID = 1234 }
        if forcedPayloads.contains(payload) {
            config.autoCompactLimitOverride = forcedWithinTurnLimit
        }
        // Cold/automatic gates use shipping defaults. Fixed-size within-turn
        // fixtures explicitly lower only the trigger, not the window or policy.
        // Root/operator controls the actual LM Studio hard capacity.
        return CodexAppServerRuntime(configuration: config, visualGrounder: NoDesktopGrounder())
    }

    private func pump(_ runtime: CodexAppServerRuntime, audit: Audit) -> Task<Void, Never> {
        Task { @MainActor in
            for await event in runtime.events() {
                if Task.isCancelled { return }
                audit.record(event)
                if case .approvalRequested(let request) = event {
                    audit.failures.append("An interactive request escaped the read-only wrapper.")
                    try? await runtime.resolveApproval(requestID: request.id, approved: false)
                }
            }
        }
    }

    private func send(_ prompt: String, runtime: CodexAppServerRuntime, audit: Audit, timeoutSeconds: TimeInterval = 300) async throws {
        let before = audit.completedTurns
        let attempt = SubmissionAttempt()
        let submission = Task {
            do {
                try await runtime.submit(prompt: prompt, toTaskID: audit.taskID, modelID: model)
                attempt.result = .success(())
            } catch {
                attempt.result = .failure(error)
            }
        }
        do {
            for _ in 0..<1_200 {
                try require(Date.now.timeIntervalSince(audit.startedAt) < timeoutSeconds,
                    "The entire bounded fixture exceeded its \(timeoutSeconds)-second limit.")
                try require(audit.failures.isEmpty, audit.failures.joined(separator: "\n"))
                if case .failure(let error) = attempt.result { throw error }
                if audit.completedTurns > before, attempt.result != nil {
                    await submission.value
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw Failure("Timed out waiting for the bounded automatic-context turn.")
        } catch {
            submission.cancel()
            _ = await runtime.shutdown()
            await submission.value
            throw error
        }
    }

    private func shutDown(_ runtime: CodexAppServerRuntime) async throws {
        let report = await runtime.shutdown()
        try require(report.succeeded, "Fixture shutdown failed: \(report.issues.joined(separator: "; "))")
    }

    private func readTrace(_ root: URL, phase: String) throws -> AppServerWireTrace {
        let trace = try AppServerWireTrace.load(root.appendingPathComponent("\(phase)-protocol.jsonl"))
        try require(trace.parseFailures.isEmpty, "Protocol trace contains malformed records.")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("read-only-proxy.json"))) as? [String: String])
        let forced = forcedPayloads.contains(fixture["payload"] ?? "")
        let expectedLimit = forced ? forcedWithinTurnLimit : shippingContext.autoCompactTokenLimit
        let configs = trace.messages.filter { $0.method == "thread/start" || $0.method == "thread/resume" }
        for request in configs {
            let params = try XCTUnwrap(request.object["params"] as? [String: Any])
            let config = try XCTUnwrap(params["config"] as? [String: Any])
            try require(config["model_context_window"] as? Int == shippingContext.contextWindow
                && config["model_auto_compact_token_limit"] as? Int == expectedLimit,
                "The live path must use the shipping window and its declared production or forced-fixture threshold.")
            let developerInstructions = ComputaAgentInstructions.developerInstructions()
            try require(config["compact_prompt"] as? String == ComputaAgentInstructions.compactionPrompt
                && params["developerInstructions"] as? String == developerInstructions,
                "The live path must use the shipping instructions and compaction provenance contract.")
        }
        print("contextWindow=\(shippingContext.contextWindow) compactLimit=\(expectedLimit) forcedFixtureThreshold=\(forced) usesShippingCompactionThreshold=\(!forced)")
        return trace
    }

    private func exactlyOne(_ method: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter { $0.direction == .clientToServer && $0.method == method }
        try require(values.count == 1, "Expected exactly one \(method), got \(values.count).")
        return try XCTUnwrap(values.first)
    }

    private func rpcReply(to request: AppServerWireTrace.Message, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter { $0.direction == .serverToClient && $0.method == nil
            && $0.identifier == request.identifier && $0.sequence > request.sequence }
        try require(values.count == 1, "RPC acknowledgment must be unique.")
        let response = try XCTUnwrap(values.first)
        try require(response.object["result"] is [String: Any]
            && (response.object["error"] == nil || response.object["error"] is NSNull), "RPC did not succeed.")
        return response
    }

    private func exactlyOneItem(_ method: String, type: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter {
            let params = $0.object["params"] as? [String: Any]
            return $0.method == method && (params?["item"] as? [String: Any])?["type"] as? String == type
        }
        try require(values.count == 1, "Expected exactly one \(method) \(type), got \(values.count).")
        return try XCTUnwrap(values.first)
    }

    private func exactlyOneCompletedItem(_ type: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        try exactlyOneItem("item/completed", type: type, in: trace)
    }

    private func terminal(turnID: String, in trace: AppServerWireTrace) throws -> AppServerWireTrace.Message {
        let values = trace.messages.filter {
            let params = $0.object["params"] as? [String: Any]
            return $0.method == "turn/completed" && (params?["turn"] as? [String: Any])?["id"] as? String == turnID
        }
        try require(values.count == 1, "Expected one exact-turn terminal, without retries.")
        let terminal = try XCTUnwrap(values.first)
        let turn = try XCTUnwrap((terminal.object["params"] as? [String: Any])?["turn"] as? [String: Any])
        try require(turn["status"] as? String == "completed" && (turn["error"] == nil || turn["error"] is NSNull),
            "The exact user/maintenance turn must finish successfully.")
        return terminal
    }

    private func verifyCompactionLifecycle(_ trace: AppServerWireTrace, beforeSequence: Int) throws {
        let start = try exactlyOneItem("item/started", type: "contextCompaction", in: trace)
        let end = try exactlyOneCompletedItem("contextCompaction", in: trace)
        let params = try XCTUnwrap(start.object["params"] as? [String: Any])
        let ended = try XCTUnwrap(end.object["params"] as? [String: Any])
        let turnID = try XCTUnwrap(params["turnId"] as? String)
        try require(ended["turnId"] as? String == turnID
            && (params["item"] as? [String: Any])?["id"] as? String == (ended["item"] as? [String: Any])?["id"] as? String,
            "Compaction item and turn identity must match.")
        let done = try terminal(turnID: turnID, in: trace)
        try require(start.sequence < end.sequence && end.sequence < done.sequence && done.sequence < beforeSequence,
            "Successful native lifecycle must precede history append and prompt delivery.")
    }

    private func toolAudit(_ root: URL, phase: String) throws -> [[String: Any]] {
        let bytes = try Data(contentsOf: root.appendingPathComponent("\(phase)-tool-audit.jsonl"))
        return try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func requireToolAudit(_ root: URL, phase: String, expectedCalls: Int) throws {
        let records = try toolAudit(root, phase: phase)
        try require(!records.contains { ["blocked", "proxy-error"].contains($0["kind"] as? String ?? "") },
            "The model attempted an unrequested, interactive, malformed, or repeated action.")
        try require(records.filter { $0["kind"] as? String == "status" }.count == expectedCalls,
            "The synthetic executor's exact call count did not match.")
    }

    private func verifyOnlySyntheticStatus(_ trace: AppServerWireTrace, root: URL, phase: String, imageSHA256: String? = nil) throws {
        try require(!trace.messages.contains { $0.method == "item/tool/call" },
            "No dynamic tool request may reach Computa's real desktop executor in this fixture.")
        let status = try exactlyOneCompletedItem("dynamicToolCall", in: trace)
        let params = try XCTUnwrap(status.object["params"] as? [String: Any])
        let item = try XCTUnwrap(params["item"] as? [String: Any])
        let call = try XCTUnwrap(toolAudit(root, phase: phase).first { $0["kind"] as? String == "status" })
        try require(item["tool"] as? String == "computer_v2_status" && item["success"] as? Bool == true
            && item["id"] as? String == call["callId"] as? String
            && params["turnId"] as? String == call["turnId"] as? String,
            "Native completed status result must match the intercepted call exactly.")
        let content = try XCTUnwrap(item["contentItems"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        try require(content.count == (imageSHA256 == nil ? 1 : 2) && content.first?["type"] as? String == "inputText"
            && output["fixture"] as? String == "synthetic read-only status; no desktop was inspected or changed"
            && text.utf8.count == call["payloadBytes"] as? Int,
            "Completed status content must be the exact bounded synthetic result, not a desktop observation.")
        if let imageSHA256 {
            try require(content.last?["type"] as? String == "inputImage" && call["imageSHA256"] as? String == imageSHA256,
                "The completed synthetic image must match the independently recorded fixture hash.")
            try verifyImage(try XCTUnwrap(content.last?["imageUrl"] as? String), digest: imageSHA256)
        }
        let forbidden = Set(["commandExecution", "fileChange", "mcpToolCall", "webSearch"])
        try require(!trace.messages.contains {
            let item = ($0.object["params"] as? [String: Any])?["item"] as? [String: Any]
            return $0.method == "item/completed" && forbidden.contains(item?["type"] as? String ?? "")
        }, "Unexpected built-in action appeared in a read-only fixture.")
    }

    private func verifyImage(_ url: String, digest: String) throws {
        let prefix = "data:image/png;base64,"
        try require(url.hasPrefix(prefix) && url.utf8.count < 700_000, "Expected one bounded inline PNG fixture.")
        let bytes = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        try require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest,
            "The image bytes changed or disappeared across the native compaction boundary.")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private func attach(_ evidence: String) {
        let value = XCTAttachment(string: evidence)
        value.name = "Automatic compaction path evidence (synthetic tool executor)"
        value.lifetime = .keepAlways
        add(value)
        print(evidence)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private final class SubmissionAttempt {
        var result: Result<Void, Error>?
    }

    @MainActor
    private final class Audit {
        let taskID: String
        let startedAt = Date.now
        var completedTurns = 0
        var compactions = 0
        var statusTools = 0
        let permitsActivationFailure: Bool
        let permittedSyntheticTools: Set<String>
        let permitsUnboundSnapshotFailure: Bool
        var unboundSnapshotFailures = 0
        var assistantMessages = [String]()
        var lastUsage: RuntimeContextUsage?
        var failures = [String]()
        var finalReply: String? { assistantMessages.last?.trimmingCharacters(in: .whitespacesAndNewlines) }
        init(taskID: String, permitsActivationFailure: Bool = false, permittedSyntheticTools: Set<String> = [],
             permitsUnboundSnapshotFailure: Bool = false) {
            self.taskID = taskID
            self.permitsActivationFailure = permitsActivationFailure
            self.permittedSyntheticTools = permittedSyntheticTools
            self.permitsUnboundSnapshotFailure = permitsUnboundSnapshotFailure
        }
        func record(_ event: AgentRuntimeEvent) {
            switch event {
            case .taskStatusChanged(let owner, let status) where owner == taskID:
                if status == .completed { completedTurns += 1 }
                if status == .waiting { failures.append("The user turn failed or was interrupted.") }
            case .contextUsageUpdated(let owner, let value) where owner == taskID:
                lastUsage = value
            case .contextCompactionChanged(let owner, let phase) where owner == taskID:
                if case .completed = phase { compactions += 1 }
                if case .failed(let message) = phase { failures.append(message) }
            case .timelineEntryAppended(let owner, let entry) where owner == taskID:
                if entry.kind == .assistant { assistantMessages.append(entry.body) }
                if let tool = entry.toolEvent {
                    if tool.name == "computer_v2_status", tool.status == .succeeded { statusTools += 1 }
                    else if permittedSyntheticTools.contains(tool.name), tool.status == .succeeded { /* Intercepted synthetic result. */ }
                    else if permitsUnboundSnapshotFailure && tool.name == "computer_v2_read_page"
                        && tool.status == .failed && unboundSnapshotFailures == 0 { unboundSnapshotFailures += 1 }
                    else if permitsActivationFailure && tool.name == "computer_v2_open" && tool.status == .failed { /* Expected synthetic failure. */ }
                    else { failures.append("Unexpected tool or failed status: \(tool.name)") }
                }
                if entry.kind == .system, entry.title == "Agent error" { failures.append(entry.body) }
            case .connectionChanged(.failed(let message)): failures.append(message)
            default: break
            }
        }
    }

    private struct NoDesktopGrounder: VisualGroundingClient {
        func prepare() async throws {}
        func ground(_ request: VisualGroundingRequest) async throws -> VisualGroundingDecision {
            throw Failure("Visual grounding is forbidden in this synthetic read-only fixture.")
        }
        func shutdown() async -> [String] { [] }
    }
}

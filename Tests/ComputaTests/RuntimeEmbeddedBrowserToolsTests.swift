import Foundation
import XCTest
@testable import Computa

/// The production runtime's JSON-RPC, active-turn and native approval boundary
/// with an inert browser backend. No provider, Chrome, UI or network is used.
@MainActor
final class RuntimeEmbeddedBrowserToolsTests: XCTestCase {
    func testBuiltInToolsAreOfferedOnlyWhenConfiguredAndNeedNoChromeBinding() async throws {
        for configured in [false, true] {
            try await withHarness(configured: configured) { harness in
                try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
                try await self.waitFor { harness.rowCount == 1 && harness.audit.status == .completed }
                let offered = try harness.offeredNames()
                XCTAssertEqual(offered.intersection(EmbeddedBrowserTools.names), configured ? EmbeddedBrowserTools.names : [])
                let row = try XCTUnwrap(harness.rows().first)
                XCTAssertEqual(row["success"] as? Bool, configured)
                if configured {
                    XCTAssertTrue((row["text"] as? String)?.contains("computa_builtin") == true)
                    XCTAssertTrue((row["text"] as? String)?.contains(InertRuntimeBrowser.humanID) == true)
                }
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.inventories, configured ? 1 : 0)
                XCTAssertEqual(counts.activations, 0)
                XCTAssertEqual(counts.mutations, 0)
                XCTAssertTrue(harness.audit.approvals.isEmpty)
            }
        }
    }

    func testNativeReferenceInterfaceDoesNotRewriteDedicatedBuiltInBrowserOutput() async throws {
        try await withHarness { harness in
            try await harness.submit([
                ["tool": "computer_v2_read_page", "arguments": [:]],
                ["tool": "browser_tabs", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 2 }
            let row = try XCTUnwrap(harness.rows().last)
            XCTAssertEqual(row["success"] as? Bool, true)
            let text = try XCTUnwrap(row["text"] as? String)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(json["browser"] as? String, "computa_builtin")
            XCTAssertEqual((json["tabs"] as? [[String: Any]])?.first?["tab_id"] as? String, InertRuntimeBrowser.humanID)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.activations, 0)
        }
    }

    func testApprovedOpenReadFillClickAndCompletionUseExactBackendAndCleanOnlyOwnedTab() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["snapshot_id": "@snapshot", "element_index": "@field", "text": "UA 123"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_click", "arguments": ["snapshot_id": "@snapshot", "element_index": "@button"]],
                ["tool": "browser_read", "arguments": ["view": "content"]],
            ])
            try await self.waitFor { harness.rowCount == 6 && harness.audit.status == .completed }
            try await self.waitForAsync { await harness.backend.counts().ownedClosed == 1 }
            let rows = try harness.rows()
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == true })
            XCTAssertTrue((rows[3]["text"] as? String)?.contains("UA 123") == true)
            XCTAssertTrue((rows[5]["text"] as? String)?.contains("UA 123 departs at 14:35") == true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.created, 1)
            XCTAssertEqual(counts.fills, 1)
            XCTAssertEqual(counts.presses, 1)
            XCTAssertEqual(counts.activations, 0)
            XCTAssertEqual(counts.humanCloseAttempts, 0)
            XCTAssertTrue(counts.humanIntact)
            XCTAssertEqual(harness.audit.approvals.map(\.kind), [.computerUse, .computerUse, .computerUse])
            XCTAssertEqual(harness.audit.approvals.map(\.summary), ["browser_open", "browser_fill", "browser_click"])
            XCTAssertFalse(harness.audit.entries.contains { $0.toolEvent?.name.hasPrefix("computer_v2_") == true })
        }
    }

    func testDecliningOpenAndFillNeverDispatchesBrowserInput() async throws {
        for mutation in ["browser_open", "browser_fill"] {
            try await withHarness(approval: false) { harness in
                let calls: [[String: Any]] = mutation == "browser_open"
                    ? [["tool": mutation, "arguments": ["url": "https://example.invalid/flight"]]]
                    : [
                        ["tool": "browser_tabs", "arguments": [:]],
                        ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                        ["tool": "browser_read", "arguments": ["view": "all"]],
                        ["tool": mutation, "arguments": ["snapshot_id": "@snapshot", "element_index": "@field", "text": "MUST_NOT_FILL"]],
                    ]
                try await harness.submit(calls)
                try await self.waitFor { harness.rowCount == calls.count && harness.audit.status == .completed }
                let final = try XCTUnwrap(harness.rows().last)
                XCTAssertEqual(final["success"] as? Bool, false)
                XCTAssertTrue((final["text"] as? String)?.contains("declined") == true)
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.created, 0)
                XCTAssertEqual(counts.mutations, 0)
                XCTAssertTrue(counts.humanIntact)
                XCTAssertEqual(counts.humanCloseAttempts, 0)
                XCTAssertEqual(harness.audit.approvals.map(\.kind), [.computerUse])
                XCTAssertEqual(harness.audit.approvals.first?.summary, mutation)
            }
        }
    }

    func testStopRetiresPendingApprovalBeforeLateAcceptanceAndNextTurnIsUsable() async throws {
        try await withHarness { harness in
            try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]], interruptProbe: true)
            try await self.waitFor { harness.audit.approvals.count == 1 }
            let approval = try XCTUnwrap(harness.audit.approvals.first)
            try await harness.runtime.interrupt(taskID: Harness.taskID)
            do {
                try await harness.runtime.resolveApproval(requestID: approval.id, approved: true)
                XCTFail("An approval from the stopped turn must be retired")
            } catch { XCTAssertTrue(error.localizedDescription.contains("no longer pending")) }
            let stopped = await harness.backend.counts()
            XCTAssertEqual(stopped.created, 0)
            let stopProbe = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("stop-window-result.json"))) as? [String: Any])
            XCTAssertEqual(stopProbe["success"] as? Bool, false,
                           "A correctly tagged call arriving after Stop but before terminal notification has no active browser authority")
            XCTAssertTrue(stopProbe["error"] is String || !(stopProbe["text"] as? String ?? "").isEmpty)
            XCTAssertEqual(harness.audit.approvals.count, 1, "The new call in the stopping turn cannot request another approval")
            harness.audit.status = nil
            try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
            try await self.waitFor { harness.audit.status == .completed && harness.rowCount == 1 }
            XCTAssertEqual(try harness.rows().last?["success"] as? Bool, true)
            XCTAssertEqual(harness.audit.approvals.count, 1)
            let continued = await harness.backend.counts()
            XCTAssertEqual(continued.mutations, 0)
        }
    }

    func testWrongMissingStaleAndForeignTurnRequestsNeverReachApprovalOrBackend() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "wrong"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "missing"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "turn": "previous"],
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"], "foreignThread": true],
                ["tool": "browser_tabs", "arguments": [:]],
            ])
            try await self.waitFor { harness.rowCount == 5 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertTrue(rows.prefix(4).allSatisfy { $0["success"] as? Bool == false })
            XCTAssertTrue(rows.prefix(4).allSatisfy { ($0["error"] as? String)?.contains("active turn") == true })
            XCTAssertEqual(rows.last?["success"] as? Bool, true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.inventories, 1)
            XCTAssertEqual(counts.created, 0)
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
        }
    }

    func testThreeIdenticalInvalidURLsStopBeforeFourthInputAndFreshTurnStillWorks() async throws {
        try await withHarness(approval: true) { harness in
            let invalid: [String: Any] = ["tool": "browser_open", "arguments": ["url": "file:///MUST_NOT_OPEN"]]
            try await harness.submit([
                invalid, invalid, invalid,
                ["tool": "browser_open", "arguments": ["url": "https://example.invalid/MUST_NOT_OPEN"]],
            ])
            try await self.waitFor {
                harness.rowCount == 3 && harness.audit.status == .waiting
                    && harness.audit.entries.contains { $0.title == "Native action stopped" }
            }
            let rows = try harness.rows()
            XCTAssertTrue(rows.allSatisfy { $0["success"] as? Bool == false })
            XCTAssertTrue((rows[0]["text"] as? String)?.contains("HTTP or HTTPS") == true)
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.root.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(sent.count, 3, "The runtime must interrupt while the third failed call is outstanding, before the fixture sends its fourth input")
            XCTAssertTrue(sent.allSatisfy { $0["tool"] as? String == "browser_open" })
            let stopped = await harness.backend.counts()
            XCTAssertEqual(stopped.created, 0)
            XCTAssertEqual(stopped.inventories, 0)
            XCTAssertEqual(stopped.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)

            harness.audit.status = nil
            try await harness.submit([["tool": "browser_tabs", "arguments": [:]]])
            try await self.waitFor { harness.rowCount == 4 && harness.audit.status == .completed }
            XCTAssertEqual(try harness.rows().last?["success"] as? Bool, true)
            let continued = await harness.backend.counts()
            XCTAssertEqual(continued.inventories, 1)
            XCTAssertEqual(continued.created, 0)
            XCTAssertEqual(continued.mutations, 0)
            XCTAssertTrue(harness.audit.approvals.isEmpty)
        }
    }

    func testTurnCompletionRetiresOldSnapshotAndPreservesBoundHumanPage() async throws {
        try await withHarness(approval: true) { harness in
            try await harness.submit([
                ["tool": "browser_tabs", "arguments": [:]],
                ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                ["tool": "browser_read", "arguments": ["view": "all"], "saveSnapshot": "old_snapshot"],
            ])
            try await self.waitFor { harness.rowCount == 3 && harness.audit.status == .completed }
            harness.audit.status = nil
            try await harness.submit([
                ["tool": "browser_tabs", "arguments": [:]],
                ["tool": "browser_bind", "arguments": ["tab_id": "@human"]],
                ["tool": "browser_read", "arguments": ["view": "all"]],
                ["tool": "browser_fill", "arguments": ["snapshot_id": "@old_snapshot", "element_index": "@field", "text": "MUST_NOT_FILL"]],
            ])
            try await self.waitFor { harness.rowCount == 7 && harness.audit.status == .completed }
            let rows = try harness.rows()
            XCTAssertTrue(rows.prefix(6).allSatisfy { $0["success"] as? Bool == true })
            XCTAssertEqual(rows[6]["success"] as? Bool, false)
            XCTAssertTrue((rows[6]["text"] as? String)?.lowercased().contains("stale") == true)
            let counts = await harness.backend.counts()
            XCTAssertEqual(counts.mutations, 0)
            XCTAssertEqual(counts.humanCloseAttempts, 0)
            XCTAssertTrue(counts.humanIntact)
        }
    }

    func testStopAndShutdownCloseOnlyTaskCreatedPages() async throws {
        for stop in [false, true] {
            try await withHarness(approval: true) { harness in
                try await harness.submit([["tool": "browser_open", "arguments": ["url": "https://example.invalid/flight"]]], hold: true)
                try await self.waitFor { harness.rowCount == 1 }
                let opened = await harness.backend.counts()
                XCTAssertEqual(opened.created, 1)
                if stop { try await harness.runtime.interrupt(taskID: Harness.taskID) }
                else {
                    let shutdown = await harness.runtime.shutdown()
                    XCTAssertTrue(shutdown.succeeded, shutdown.issues.joined(separator: "; "))
                }
                try await self.waitForAsync { await harness.backend.counts().ownedClosed == 1 }
                let counts = await harness.backend.counts()
                XCTAssertEqual(counts.humanCloseAttempts, 0)
                XCTAssertTrue(counts.humanIntact)
                XCTAssertEqual(counts.activations, 0)
            }
        }
    }

    @MainActor
    private final class Audit {
        var status: TaskStatus?
        var approvals = [ActionApprovalRequest]()
        var entries = [TimelineEntry]()
    }

    @MainActor
    private final class Harness {
        static let taskID = "embedded-browser-task"
        static let modelID = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
        let root: URL
        let runtime: CodexAppServerRuntime
        let backend = InertRuntimeBrowser()
        let audit = Audit()
        var events: Task<Void, Never>?

        init(configured: Bool, approval: Bool?) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaBrowserRuntime-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fixture = root.appendingPathComponent("fixture.ts")
            try Data(RuntimeEmbeddedBrowserToolsTests.fixture.utf8).write(to: fixture)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            var configuration = CodexAppServerRuntime.Configuration.localQwen
            configuration.executable = .fixture(path: fixture.path)
            configuration.codexHomePath = root.path
            configuration.workspacePath = root.path
            configuration.model = Self.modelID
            configuration.protocolTracePath = root.appendingPathComponent("protocol.jsonl").path
            runtime = CodexAppServerRuntime(configuration: configuration)
            if configured { await runtime.configureEmbeddedBrowserTools(EmbeddedBrowserToolController(transport: backend)) }
            events = Task { @MainActor [runtime, audit] in
                for await event in runtime.events() {
                    switch event {
                    case .taskStatusChanged(let id, let status) where id == Self.taskID: audit.status = status
                    case .timelineEntryAppended(let id, let entry) where id == Self.taskID: audit.entries.append(entry)
                    case .approvalRequested(let request):
                        audit.approvals.append(request)
                        if let approval { try? await runtime.resolveApproval(requestID: request.id, approved: approval) }
                    default: break
                    }
                }
            }
            _ = try await runtime.loadTasks()
        }

        func submit(_ calls: [[String: Any]], hold: Bool = false, interruptProbe: Bool = false) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["calls": calls, "hold": hold, "interruptProbe": interruptProbe], options: [.sortedKeys])
            try await runtime.submit(prompt: String(decoding: data, as: UTF8.self), toTaskID: Self.taskID, modelID: Self.modelID)
        }
        func rows() throws -> [[String: Any]] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("results.json"))) as? [[String: Any]])
        }
        var rowCount: Int {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("results.json")),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let rows = object as? [[String: Any]] else { return 0 }
            return rows.count
        }
        func offeredNames() throws -> Set<String> {
            let specs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("specs.json"))) as? [[String: Any]])
            try CanonicalDynamicToolTestContract.validate(specs)
            return Set(specs.compactMap { $0["name"] as? String })
        }
    }

    private func withHarness(configured: Bool = true, approval: Bool? = nil, _ body: @MainActor (Harness) async throws -> Void) async throws {
        let harness = try await Harness(configured: configured, approval: approval)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        do {
            try await body(harness)
            let report = await harness.runtime.shutdown()
            harness.events?.cancel()
            XCTAssertTrue(report.succeeded, report.issues.joined(separator: "; "))
        } catch {
            _ = await harness.runtime.shutdown()
            harness.events?.cancel()
            throw error
        }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        try await waitForAsync { predicate() }
    }
    private func waitForAsync(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "RuntimeEmbeddedBrowserToolsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for owned fixture evidence"])
    }

    nonisolated private static let fixture = #"""
    #!/usr/bin/env bun
    import { writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    import { createInterface } from 'node:readline';
    const root = process.env.CODEX_HOME;
    const threadId = 'embedded-browser-thread';
    const send = value => process.stdout.write(JSON.stringify(value) + '\n');
    const result = (id, value = {}) => send({id, result:value});
    const notify = (method, params) => send({method, params:{threadId, ...params}});
    const save = (name, value) => writeFileSync(join(root, name), JSON.stringify(value));
    const plainObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
    function canonicalToolError(specs) {
      if (!Array.isArray(specs) || specs.length === 0) return 'Invalid request: missing dynamic tools';
      const legacy = specs.some(spec => !plainObject(spec) || !Object.hasOwn(spec, 'type') || Object.hasOwn(spec, 'namespace') || Object.hasOwn(spec, 'exposeToContext'));
      const canonical = specs.some(spec => plainObject(spec) && Object.hasOwn(spec, 'type'));
      if (legacy && canonical) return 'Invalid request: dynamic tools must use either canonical or legacy format consistently';
      if (legacy) return 'Invalid request: this fixture requires canonical dynamic function tools';
      const names = new Set();
      const allowed = new Set(['type', 'name', 'description', 'inputSchema', 'deferLoading']);
      for (const spec of specs) {
        const schema = spec.inputSchema;
        if (spec.type !== 'function' || typeof spec.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(spec.name) || names.has(spec.name)
            || typeof spec.description !== 'string' || !spec.description.trim() || Object.keys(spec).some(key => !allowed.has(key))
            || (Object.hasOwn(spec, 'deferLoading') && typeof spec.deferLoading !== 'boolean')
            || !plainObject(schema) || schema.type !== 'object' || !plainObject(schema.properties) || schema.additionalProperties !== false
            || !Array.isArray(schema.required) || new Set(schema.required).size !== schema.required.length
            || schema.required.some(key => typeof key !== 'string' || !Object.hasOwn(schema.properties, key))) {
          return 'Invalid request: invalid canonical dynamic function tool definition';
        }
        names.add(spec.name);
      }
      return null;
    }
    const rows = [], refs = {}, requests = [];
    let turnCount = 0, turnId = '', step = 0, plan = {}, finished = true, interruptRequest;
    function complete(status = 'completed') {
      if (finished) return;
      finished = true;
      if (status === 'completed') {
        const item = {id:`answer-${turnCount}`, type:'agentMessage', phase:'final_answer', text:'Fixture workflow finished.'};
        notify('item/started', {turnId, item:{...item, text:''}});
        notify('item/agentMessage/delta', {turnId, itemId:item.id, delta:item.text});
        notify('item/completed', {turnId, item});
      }
      notify('turn/completed', {turn:{id:turnId, status, items:[], error:null}});
    }
    function next() {
      if (finished) return;
      if (step >= plan.calls.length) { if (!plan.hold) complete(); return; }
      const call = plan.calls[step], args = {};
      for (const [key,value] of Object.entries(call.arguments ?? {})) args[key] = typeof value === 'string' && value.startsWith('@') ? refs[value.slice(1)] : value;
      const params = {threadId:call.foreignThread ? 'foreign-thread' : threadId, turnId, callId:`call-${turnCount}-${step}`, tool:call.tool, arguments:args};
      if (call.turn === 'wrong') params.turnId = 'wrong-turn';
      if (call.turn === 'previous') params.turnId = `embedded-turn-${turnCount-1}`;
      if (call.turn === 'missing') delete params.turnId;
      requests.push({turnId, step, tool:call.tool}); save('requests.json', requests);
      send({id:`request-${turnCount}-${step}`, method:'item/tool/call', params});
    }
    function received(message) {
      if (message.id === 'stop-window-probe') {
        const text = (message.result?.contentItems ?? []).map(item => item.text ?? '').join('\n');
        save('stop-window-result.json', {success:message.result?.success === true, text, error:message.error?.message ?? null});
        result(interruptRequest); complete('interrupted'); return;
      }
      if (message.id !== `request-${turnCount}-${step}`) return;
      const text = (message.result?.contentItems ?? []).map(item => item.text ?? '').join('\n');
      rows.push({turnId, tool:plan.calls[step].tool, success:message.result?.success === true, text, error:message.error?.message ?? null});
      save('results.json', rows);
      if (message.result?.success) {
        try { const data = JSON.parse(text); if (data.tabs?.[0]?.tab_id) refs.human = data.tabs[0].tab_id; } catch {}
        const snapshot = text.match(/AXSNAPSHOT id=([A-Fa-f0-9-]{36})/);
        if (snapshot) {
          refs.snapshot = snapshot[1];
          if (plan.calls[step].saveSnapshot) refs[plan.calls[step].saveSnapshot] = snapshot[1];
          const field = text.split('\n').find(line => line.startsWith('#') && line.includes('label="Search flights"'));
          const button = text.split('\n').find(line => line.startsWith('#') && line.includes('label="Find flight"'));
          if (field) refs.field = Number(field.match(/^#(\d+)/)[1]);
          if (button) refs.button = Number(button.match(/^#(\d+)/)[1]);
        }
      }
      step++; setTimeout(next, 0);
    }
    createInterface({input:process.stdin}).on('line', line => {
      const message = JSON.parse(line);
      if (!Object.hasOwn(message, 'id')) return;
      if (!message.method) { received(message); return; }
      switch (message.method) {
        case 'initialize': result(message.id, {userAgent:'embedded-browser-runtime-fixture'}); break;
        case 'thread/list': result(message.id, {data:[], nextCursor:null}); break;
        case 'thread/start': {
          save('specs.json', message.params.dynamicTools);
          const error = canonicalToolError(message.params.dynamicTools);
          if (error) send({id:message.id, error:{code:-32600, message:error}});
          else result(message.id, {thread:{id:threadId, turns:[]}});
          break;
        }
        case 'thread/resume': result(message.id, {thread:{id:threadId, turns:[], status:{type:'idle'}}, initialTurnsPage:{data:[], nextCursor:null, hasMore:false}, model:'lmstudio-community/Qwen3.5-4B-MLX-4bit'}); break;
        case 'thread/name/set': case 'thread/inject_items': result(message.id); break;
        case 'turn/start':
          turnCount++; turnId = `embedded-turn-${turnCount}`; step = 0; finished = false;
          plan = JSON.parse(message.params.input[0].text);
          result(message.id, {turn:{id:turnId, status:'inProgress', items:[]}});
          notify('turn/started', {turn:{id:turnId, status:'inProgress', items:[]}}); setTimeout(next, 10); break;
        case 'turn/interrupt':
          if (plan.interruptProbe) {
            interruptRequest = message.id;
            // Keep the original turn active on the wire until this correctly
            // tagged late call receives the host's refusal. Stop has already
            // retired its epoch, key and pending approvals before this RPC.
            send({id:'stop-window-probe', method:'item/tool/call', params:{threadId, turnId, callId:'stop-window-call', tool:'browser_open', arguments:{url:'https://example.invalid/MUST_NOT_OPEN'}}});
          } else { result(message.id); complete('interrupted'); }
          break;
        default: send({id:message.id, error:{code:-32601, message:`Unexpected embedded fixture method: ${message.method}`}});
      }
    }).on('close', () => process.exit(0));
    """#
}

/// Inspects the complete thread/start payload, including native and browser
/// tools together. Real-engine tests also require the pinned parser to accept it.
enum CanonicalDynamicToolTestContract {
    static func validate(_ specs: [[String: Any]]) throws {
        guard !specs.isEmpty else { throw invalid("No dynamic tools were offered") }
        let allowed: Set<String> = ["type", "name", "description", "inputSchema", "deferLoading"]
        var names = Set<String>()
        for (index, spec) in specs.enumerated() {
            guard spec["type"] as? String == "function",
                  Set(spec.keys).isSubset(of: allowed),
                  let name = spec["name"] as? String,
                  name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  names.insert(name).inserted,
                  let description = spec["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let schema = spec["inputSchema"] as? [String: Any],
                  schema["type"] as? String == "object",
                  schema["additionalProperties"] as? Bool == false,
                  let properties = schema["properties"] as? [String: Any],
                  let required = schema["required"] as? [String],
                  Set(required).count == required.count,
                  Set(required).isSubset(of: Set(properties.keys)),
                  spec["deferLoading"] == nil || spec["deferLoading"] is Bool
            else { throw invalid("Offered tool \(index) is not a canonical dynamic function definition") }
        }
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "CanonicalDynamicToolTestContract", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Shared only with native-engine contract tests; never a production backend.
actor InertRuntimeBrowser: EmbeddedBrowserControlBackend {
    static let humanID = "11111111-1111-4111-8111-111111111111"
    struct Counts: Sendable {
        var inventories = 0, created = 0, ownedClosed = 0, humanCloseAttempts = 0, activations = 0
        var fills = 0, presses = 0, navigations = 0
        var humanIntact = true
        var mutations: Int { fills + presses + navigations }
    }
    private var ledger = Counts()
    private var targets: [String: BrowserTarget] = [humanID: BrowserTarget(targetID: humanID, instanceToken: "human-incarnation", title: "User flight page", url: URL(string: "https://example.invalid/user")!, webSocketURL: nil)]
    private var owned = Set<String>()
    private var values = [String: String]()
    private var results = [String: String]()

    func counts() -> Counts {
        var result = ledger
        result.humanIntact = targets[Self.humanID]?.url.absoluteString == "https://example.invalid/user"
            && values[Self.humanID] == nil && results[Self.humanID] == nil
        return result
    }
    func humanTargets() -> [BrowserTarget] { ledger.inventories += 1; return Array(targets.values).sorted { $0.targetID < $1.targetID } }
    func createTarget(url: URL) -> BrowserTarget {
        ledger.created += 1
        let id = UUID().uuidString
        let target = BrowserTarget(targetID: id, instanceToken: UUID().uuidString, title: "Fixture flight", url: url, webSocketURL: nil)
        targets[id] = target; owned.insert(id); return target
    }
    func target(id: String) -> BrowserTarget? { targets[id] }
    func activateTarget(id: String) { ledger.activations += 1 }
    func closeTarget(target: BrowserTarget) throws {
        guard owned.remove(target.targetID) != nil else { ledger.humanCloseAttempts += 1; throw BrowserTabBrokerError.ownershipMismatch }
        ledger.ownedClosed += 1; targets.removeValue(forKey: target.targetID)
    }
    func closeOwnedTargets() -> [String] {
        for id in owned { targets.removeValue(forKey: id); ledger.ownedClosed += 1 }
        owned.removeAll(); return []
    }
    func observe(target: BrowserTarget) throws -> BrowserDocumentObservation {
        guard targets[target.targetID] == target else { throw BrowserTabBrokerError.targetClosed }
        let nodes = [
            BrowserDocumentNode(backendNodeID: 1, role: "main", name: "Flight lookup", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "main", childNodeIDs: ["heading", "query", "find", "result"]),
            BrowserDocumentNode(backendNodeID: 2, role: "heading", name: "United flight fixture", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "heading", parentNodeID: "main"),
            BrowserDocumentNode(backendNodeID: 3, role: "textbox", name: "Search flights", value: values[target.targetID] ?? "", isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "query", parentNodeID: "main", isEditable: true),
            BrowserDocumentNode(backendNodeID: 4, role: "button", name: "Find flight", value: nil, isDisabled: false, isReadOnly: false, isIgnored: false, nodeID: "find", parentNodeID: "main", isDOMClickable: true),
            BrowserDocumentNode(backendNodeID: 5, role: "StaticText", name: results[target.targetID] ?? "Enter a flight number", value: nil, isDisabled: false, isReadOnly: true, isIgnored: false, nodeID: "result", parentNodeID: "main"),
        ]
        var document = BrowserDocumentObservation(loaderID: "loader-" + target.instanceToken, title: target.title, url: target.url, nodes: nodes)
        document.sourceName = "computa_webkit_dom"
        return document
    }
    func press(target: BrowserTarget, backendNodeID: Int64, document: BrowserDocumentObservation, permit: BrowserMutationPermit) throws {
        guard backendNodeID == 4 else { throw BrowserTabBrokerError.elementNotFound }
        try permit.commit { ledger.presses += 1; results[target.targetID] = "UA 123 departs at 14:35" }
    }
    func setText(target: BrowserTarget, backendNodeID: Int64, text: String, document: BrowserDocumentObservation, permit: BrowserMutationPermit) throws {
        guard backendNodeID == 3 else { throw BrowserTabBrokerError.elementNotFound }
        try permit.commit { ledger.fills += 1; values[target.targetID] = text }
    }
    func navigate(target: BrowserTarget, url: URL, permit: BrowserMutationPermit) throws {
        try permit.commit {
            ledger.navigations += 1
            targets[target.targetID] = BrowserTarget(targetID: target.targetID, instanceToken: target.instanceToken, title: target.title, url: url, webSocketURL: nil)
        }
    }
    func wait(target: BrowserTarget, text: String?, timeoutMS: Int) -> Bool { text.map { (results[target.targetID] ?? "").contains($0) } ?? true }
}

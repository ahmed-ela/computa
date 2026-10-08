import Darwin
import Foundation

/// Disposable project and independent outcome verifier. Setup uses fixed argv;
/// the workflow itself goes through the real engine's offered tools.
struct WorkflowBenchmarkFixture: Sendable {
    let root: URL
    let project: URL
    let home: URL
    let remote: URL
    let marker: String

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ComputaWorkflow-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Project with spaces", isDirectory: true)
        home = root.appendingPathComponent("PrivateHome", isDirectory: true)
        // Inside the chosen workspace so a local push cannot require access to
        // any real repository, credential store, or external Git endpoint.
        remote = project.appendingPathComponent(".benchmark/remote.git", isDirectory: true)
        marker = "WORKFLOW_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do { try seed() }
        catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func seed() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try write(".gitignore", ".benchmark/\n__pycache__/\n")
        try write("src/math_utils.py", "def total(values):\n    return len(values)\n")
        try write("tests/test_math.py", """
        import unittest
        from src.math_utils import total
        class MathTests(unittest.TestCase):
            def test_values(self):
                self.assertEqual(total([2, 3, 7]), 12)
            def test_empty(self):
                self.assertEqual(total([]), 0)
        """ + "\n")
        try write("obsolete.txt", "remove this fixture file\n")
        try write("user-note.txt", "seed\n")
        try write("server.py", serverSource)
        try write("interactive.py", """
        import os, sys
        from pathlib import Path
        Path('.benchmark/interactive.pid').write_text(str(os.getpid()))
        print('INTERACTIVE_READY', flush=True)
        answer = sys.stdin.readline().strip()
        print('INTERACTIVE_RESULT=' + answer, flush=True)
        """ + "\n")
        try git(["init", "--quiet", "--initial-branch=main"])
        try git(["config", "user.name", "Computa Workflow Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["init", "--quiet", "--bare", remote.path])
        try git(["remote", "add", "origin", remote.path])
        try git(["add", "--", ".gitignore", "src", "tests", "obsolete.txt", "user-note.txt", "server.py", "interactive.py"])
        try git(["commit", "--quiet", "-m", "Seed disposable workflow"])
        try write("user-note.txt", "seed\nexisting user edit must survive\n")
    }

    var patch: String {
        """
        *** Begin Patch
        *** Update File: src/math_utils.py
        @@
         def total(values):
        -    return len(values)
        +    return sum(values)
        *** Add File: README.md
        +Run `/usr/bin/python3 -m unittest discover -s tests`.
        *** Delete File: obsolete.txt
        *** End Patch
        """
    }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: project.appendingPathComponent(path))
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try command("/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments)
    }

    @discardableResult
    func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = project
        // Independent verification cannot inherit the user's Git helpers or
        // account configuration. The fixture creates its own local identity.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw WorkflowBenchmarkFailure("Fixture verifier failed (\(process.terminationStatus)): \(text.prefix(2_000))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func verifyCommittedOutcome() throws -> String {
        try WorkflowBenchmarkFailure.require(try String(contentsOf: project.appendingPathComponent("src/math_utils.py"), encoding: .utf8)
            == "def total(values):\n    return sum(values)\n", "The actual edited source differs")
        try WorkflowBenchmarkFailure.require(!FileManager.default.fileExists(atPath: project.appendingPathComponent("obsolete.txt").path),
            "The deleted fixture still exists")
        try WorkflowBenchmarkFailure.require(try String(contentsOf: project.appendingPathComponent("user-note.txt"), encoding: .utf8)
            == "seed\nexisting user edit must survive\n", "The pre-existing user edit was modified")
        let head = try git(["rev-parse", "HEAD"])
        let remoteHead = try git(["--git-dir", remote.path, "rev-parse", "refs/heads/benchmark"])
        try WorkflowBenchmarkFailure.require(head == remoteHead && head.count == 40, "The bare remote did not receive the exact local commit")
        let changed = try git(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]).split(separator: "\n").map(String.init)
        try WorkflowBenchmarkFailure.require(Set(changed) == Set(["README.md", "obsolete.txt", "src/math_utils.py"]),
            "The commit includes unrelated files: \(changed)")
        try WorkflowBenchmarkFailure.require(try git(["status", "--porcelain"]) == "M user-note.txt",
            "The independent Git status no longer contains only the untouched user edit")
        try WorkflowBenchmarkFailure.require(try git(["--git-dir", remote.path, "show", "refs/heads/benchmark:src/math_utils.py"])
            == "def total(values):\n    return sum(values)", "The remote committed source differs")
        return head
    }

    func serverRecord() throws -> (pid: Int32, port: Int) {
        let data = try Data(contentsOf: project.appendingPathComponent(".benchmark/server.json"))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["marker"] as? String == marker, let rawPID = value["pid"] as? Int,
              let pid = Int32(exactly: rawPID), pid > 1, let port = value["port"] as? Int,
              (1...65_535).contains(port) else { throw WorkflowBenchmarkFailure("Owned server readiness record is invalid") }
        return (pid, port)
    }

    struct ServerObservation: Sendable {
        let pid: Int32
        let port: Int
        let processResult: Int32
        let processErrno: Int32
        let connectResult: Int32
        let connectErrno: Int32
        var processAbsent: Bool { processResult == -1 && processErrno == ESRCH }
        var portRefused: Bool { connectResult == -1 && connectErrno == ECONNREFUSED }
        var closed: Bool { processAbsent && portRefused }
    }

    func observeServer() throws -> ServerObservation {
        let server = try serverRecord()
        let processResult = kill(server.pid, 0)
        let processErrno = processResult == -1 ? errno : 0
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WorkflowBenchmarkFailure("Could not inspect the closed localhost port") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(server.port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ServerObservation(pid: server.pid, port: server.port, processResult: processResult,
            processErrno: processErrno, connectResult: result, connectErrno: result == -1 ? errno : 0)
    }

    func verifyServerClosed() throws {
        try requireServerClosed(observeServer())
    }

    private func requireServerClosed(_ observation: ServerObservation) throws {
        try WorkflowBenchmarkFailure.require(observation.processAbsent, "The owned localhost server process is still running")
        try WorkflowBenchmarkFailure.require(observation.portRefused, "The localhost port still accepts connections")
    }

    /// The pinned engine acknowledges session removal before its PTY waiter
    /// finishes reaping. Observe that asynchronous boundary without sending
    /// signals or shutting down the runtime; only exact PID/socket absence passes.
    func waitForServerClosed() async throws -> Duration {
        let began = ContinuousClock.now
        let deadline = began + .seconds(5)
        var observation = try observeServer()
        if !observation.closed {
            print("workflowStopInitialObservation " + (try serverDiagnostic(observation)))
        }
        while !observation.closed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            observation = try observeServer()
        }
        try requireServerClosed(observation)
        return began.duration(to: .now)
    }

    /// Fixed structural columns from the recorded PID only. Commands, page
    /// text, prompts and model responses never enter the retained test log.
    func serverDiagnostic(_ supplied: ServerObservation? = nil) throws -> String {
        let observation = try supplied ?? observeServer()
        let columns = (try? command("/bin/ps", ["-p", String(observation.pid), "-o", "pid=,ppid=,pgid=,stat="])) ?? "unavailable"
        let value: [String: Any] = ["schemaVersion": 1, "fixtureID": root.lastPathComponent,
            "pid": observation.pid, "port": observation.port,
            "processResult": observation.processResult, "processErrno": observation.processErrno,
            "connectResult": observation.connectResult, "connectErrno": observation.connectErrno,
            "processAbsent": observation.processAbsent, "portRefused": observation.portRefused,
            "psColumns": String(columns.prefix(256))]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Always called after runtime shutdown, including failures. Emergency
    /// cleanup targets only recorded PIDs whose live command contains this
    /// unique fixture path; it never kills by executable name or port.
    func cleanup() async throws {
        var pids = [Int32]()
        if let record = try? serverRecord() { pids.append(record.pid) }
        if let text = try? String(contentsOf: project.appendingPathComponent(".benchmark/interactive.pid"), encoding: .utf8),
           let pid = Int32(text), pid > 1 { pids.append(pid) }
        for pid in pids where kill(pid, 0) == 0 {
            let command = try self.command("/bin/ps", ["-p", String(pid), "-o", "command="])
            guard command.contains(project.path) else {
                throw WorkflowBenchmarkFailure("Cleanup refused a PID without the unique fixture path")
            }
            guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
                throw WorkflowBenchmarkFailure("Could not stop the owned fixture PID")
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try WorkflowBenchmarkFailure.require(kill(pid, 0) == -1 && errno == ESRCH,
                "Emergency cleanup did not confirm its owned process stopped")
        }
        try FileManager.default.removeItem(at: root)
    }

    private var serverSource: String {
        """
        import json, os
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from pathlib import Path
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/health':
                    self.send_error(404)
                    return
                body = b'\(marker)'
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        Path('.benchmark/server.json').write_text(json.dumps({'pid': os.getpid(), 'port': server.server_port, 'marker': '\(marker)'}))
        print('SERVER_READY port=' + str(server.server_port), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print('SERVER_STOPPED', flush=True)
        finally:
            server.server_close()
        """ + "\n"
    }
}

struct WorkflowBenchmarkFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw WorkflowBenchmarkFailure(message) }
    }
}

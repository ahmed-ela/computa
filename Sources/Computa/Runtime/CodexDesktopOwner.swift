import AppKit
import Darwin
import Foundation
import Security

/// A live desktop connection to the same private Unix socket is required. Another
/// app-server can share CODEX_HOME and even have its own copy of the thread loaded.
enum CodexDesktopOwner {
    static func socket(in home: URL) -> URL? {
        let link = home.appendingPathComponent("app-server-control/app-server-control.sock")
        let endpoint = link.resolvingSymlinksInPath()
        for folder in [link.deletingLastPathComponent(), endpoint.deletingLastPathComponent()] {
            guard owned(folder, kind: S_IFDIR) else { return nil }
        }
        guard owned(endpoint, kind: S_IFSOCK) else { return nil }
        return endpoint
    }

    private static func owned(_ url: URL, kind: mode_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() &&
            info.st_mode & S_IFMT == kind && info.st_mode & 0o077 == 0
    }

    private static func isOfficialProcess(_ pid: pid_t, main: Bool) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        var expression = #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#
        if main { expression += #" and identifier "com.openai.codex""# }
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    @MainActor private static func candidates() -> [(pid_t, URL)] {
        NSRunningApplication.runningApplications(withBundleIdentifier: CodexDesktopSidebarClient.bundleID).compactMap { app in
            guard !app.isTerminated, let url = app.bundleURL else { return nil }
            return (app.processIdentifier, url)
        }
    }

    private struct Peer {
        let desktop: pid_t
        let resources: URL
    }

    private struct DaemonRecord: Decodable { let pid: pid_t }

    private static func connectedDesktop(to daemon: pid_t) async -> Peer? {
        let handles = serverHandles(daemon)
        guard !handles.isEmpty else { return nil }
        for (root, bundle) in await candidates() {
            guard let resources = Bundle(url: bundle)?.resourceURL else { continue }
            // Only the main application or its signed framework host can establish ownership.
            guard isOfficialProcess(root, main: true) else { continue }
            let capacity = max(0, Int(proc_listchildpids(root, nil, 0))) + 16
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes { proc_listchildpids(root, $0.baseAddress, Int32($0.count)) }
            let pids = [root] + children.prefix(max(0, Int(count)))
            for pid in pids where pid > 0 {
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                      pid == root || String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix(bundle.path + "/Contents/Frameworks/"),
                      connected(pid, to: handles), pid == root || isOfficialProcess(pid, main: false) else { continue }
                return Peer(desktop: pid, resources: resources)
            }
        }
        return nil
    }

    private static func serverHandles(_ pid: pid_t) -> Set<UInt64> {
        Set(sockets(pid).map(\.soi_so)).subtracting([0])
    }

    private static func connected(_ pid: pid_t, to server: Set<UInt64>) -> Bool {
        sockets(pid).contains { server.contains($0.soi_proto.pri_un.unsi_conn_so) }
    }

    private static func sockets(_ pid: pid_t) -> [socket_info] {
        let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: needed / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        return fds.prefix(max(0, Int(bytes)) / stride).compactMap { fd in
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET,
                  proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_UN else { return nil }
            return info.psi
        }
    }

    static func connect(home: URL) async throws -> AgentCLIConnection? {
        let record = home.appendingPathComponent("app-server-daemon/daemon.pid")
        guard let endpoint = socket(in: home), let data = try? Data(contentsOf: record),
              let daemon = try? JSONDecoder().decode(DaemonRecord.self, from: data).pid, daemon > 0,
              isOfficialProcess(daemon, main: false), let peer = await connectedDesktop(to: daemon) else { return nil }
        let node = peer.resources.appendingPathComponent("node")
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard FileManager.default.isExecutableFile(atPath: node.path),
              let relay = bundle.url(forResource: "codex-owner", withExtension: "cjs", subdirectory: "CodexDesktop")
        else { return nil }
        let conn = try AgentCLIConnection(executable: node, arguments: [relay.path, endpoint.path], directory: home,
                                          environment: ["PATH": "/usr/bin:/bin", "WS_NO_BUFFER_UTIL": "1", "WS_NO_UTF_8_VALIDATE": "1"],
                                          codexProtocol: true, reportInvalidRequests: true) { _ in }
        do {
            struct Handshake: Decodable { let codexHome: String }
            let result = try await conn.request("initialize", params: Data(#"{"clientInfo":{"name":"kolmogor_model_picker","version":"1"},"capabilities":{"experimentalApi":true}}"#.utf8), timeout: .seconds(5))
            // A socket pathname can be rebound while old connections are still
            // alive. Check both established peers against the server's live
            // kernel socket handles before trusting its account or thread state.
            let handles = serverHandles(daemon)
            guard connected(peer.desktop, to: handles), connected(conn.processIdentifier, to: handles) else {
                await conn.close()
                return nil
            }
            let cwd = try JSONDecoder().decode(Handshake.self, from: result).codexHome
            guard URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path else {
                throw CodexDesktopSidebarClient.Failure.noChat
            }
            try await conn.send(Data(#"{"method":"initialized"}"#.utf8))
            return conn
        } catch { await conn.close(); throw error }
    }
}

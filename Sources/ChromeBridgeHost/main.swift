import Darwin
import Foundation

/// Chrome owns this process and the stdio native-messaging channel. The helper
/// never starts Chrome/the app, navigates tabs, reads a profile, or stores data.
final class NativeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutLock = NSLock()
    private var socket: ChromeBridgeSocket?
    private let parent: Int32

    init() throws {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1] == "chrome-extension://" + ChromeBridgeIdentity.extensionID + "/" else {
            throw ChromeBridgeIPC.Failure.identity
        }
        parent = try ChromeBridgeIPC.verifiedChromeParent(of: getpid())
        try ChromeBridgeIPC.prepareDirectory()
    }

    func run() {
        DispatchQueue(label: "macrouse.native.chrome-reader").async { [self] in
            do {
                while let data = try ChromeBridgeIPC.readFrame(STDIN_FILENO) {
                    let current = lock.withLock { socket }
                    // Messages from a previous disconnected generation are not
                    // buffered/replayed. A new link asks the extension for hello.
                    if let current {
                        do { try current.send(data) } catch { current.close() }
                    }
                }
            } catch { }
            lock.withLock { socket?.close() }
            Darwin.exit(0)
        }
        while true {
            var current: ChromeBridgeSocket?
            var wasConnected = false
            do {
                guard getppid() == parent else { throw ChromeBridgeIPC.Failure.identity }
                try ChromeBridgeIPC.validateCode(pid: parent, identifier: "com.google.Chrome", team: "EQHXZ8M8AV")
                let fd = try ChromeBridgeIPC.connect()
                let peer = ChromeBridgeSocket(fd: fd)
                current = peer
                try ChromeBridgeIPC.validateCode(pid: ChromeBridgeIPC.peerPID(fd), identifier: ChromeBridgeIPC.appIdentifier)
                lock.withLock { socket = peer }
                wasConnected = true
                try emit(["version": 1, "event": "requestHello"])
                while let data = try ChromeBridgeIPC.readFrame(fd) {
                    try stdoutLock.withLock { try ChromeBridgeIPC.writeFrame(STDOUT_FILENO, data: data) }
                }
            } catch { /* Fixed-category only; never dump payloads or paths. */ }
            lock.withLock {
                if socket === current { socket = nil }
            }
            current?.close()
            if wasConnected { try? emit(["version": 1, "event": "appDisconnected"]) }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try stdoutLock.withLock { try ChromeBridgeIPC.writeFrame(STDOUT_FILENO, data: data) }
    }
}

signal(SIGPIPE, SIG_IGN)
do { try NativeRelay().run() }
catch {
    // Chrome surfaces a closed native port; no arbitrary OS error or secret is
    // written into stderr/stdout. An invalid caller never opens a local socket.
    Darwin.exit(1)
}

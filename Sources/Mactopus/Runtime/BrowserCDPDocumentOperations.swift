import Foundation

/// A response or cleanup failure must not erase the possibility that the DOM
/// action already ran. Callers can reconcile with a read without replaying it.
struct BrowserMutationFailure: Error, LocalizedError, Sendable {
    let dispatchState: ComputerActionEvidence.DispatchState
    let underlyingError: any Error

    var errorDescription: String? {
        let prefix = dispatchState == .dispatched
            ? "The browser action was dispatched, but cleanup failed."
            : "The browser action's delivery is unknown."
        return prefix + " Its outcome is unverified; do not repeat the action. Observe the same target to reconcile. "
            + underlyingError.localizedDescription
    }
}

/// Commands carry encoded JSON across actor boundaries; DOM handles never leave
/// the exact channel that created them. Only fixed broker operations use this seam.
protocol BrowserDocumentChannel: Sendable {
    func request(method: String, params: Data, permit: BrowserMutationPermit?) async throws -> Data
    func invalidate() async
}

extension BrowserDocumentChannel {
    nonisolated(nonsending)
    func command(
        method: String,
        params: [String: Any] = [:],
        permit: BrowserMutationPermit? = nil
    ) async throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: params)
        let data = try await request(method: method, params: encoded, permit: permit)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse("a document command returned no object")
        }
        return object
    }
}

/// Shared semantic operations for an owned page channel or a borrowed exact
/// attached session. These are DOM actions, not trusted physical mouse input.
struct BrowserCDPDocumentOperations {
    nonisolated(nonsending)
    func observe(
        target: BrowserTarget,
        socket: any BrowserDocumentChannel
    ) async throws -> BrowserDocumentObservation {
        let before = try await frameIdentity(socket: socket)
        _ = try await socket.command(method: "Accessibility.enable")
        let axResult = try await socket.command(
            method: "Accessibility.getFullAXTree",
            params: ["depth": 64]
        )
        guard let rawNodes = axResult["nodes"] as? [[String: Any]] else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "Accessibility.getFullAXTree did not return nodes"
            )
        }
        let actionEvidence: BrowserDOMActionProjection
        do {
            let dom = try await socket.command(method: "DOMSnapshot.captureSnapshot", params: [
                "computedStyles": BrowserDOMActionProjection.styles,
            ])
            actionEvidence = try BrowserDOMActionProjection.parse(dom, frameID: before.id, url: before.url)
        } catch ChromeBridgeIPC.Failure.unsupportedCommand {
            // An older paired extension may lack the new read-only command.
            // Preserve existing semantic controls; never invent clickability.
            actionEvidence = .unavailable
        }
        let after = try await frameIdentity(socket: socket)
        guard after == before else {
            throw BrowserTabBrokerError.staleDocument
        }
        let nodes = try rawNodes.prefix(12_000).map { try parseNode($0, actionEvidence: actionEvidence) }
        let knownIDs = Set(nodes.compactMap(\.nodeID))
        let hasMissingChildren = nodes.contains { node in
            node.childNodeIDs.contains { !knownIDs.contains($0) }
        }
        // A bounded CDP capture is not evidence of completeness. Retain a
        // conservative depth-boundary signal even when CDP omits childIds.
        let parents = Dictionary(nodes.compactMap { node in
            node.nodeID.map { ($0, node.parentNodeID) }
        }, uniquingKeysWith: { first, _ in first })
        let reachesDepthBound = nodes.contains { node in
            var seen = Set<String>()
            var parent = node.parentNodeID
            while let id = parent, seen.insert(id).inserted {
                if seen.count >= 64 { return true }
                parent = parents[id] ?? nil
            }
            return false
        }
        return BrowserDocumentObservation(
            loaderID: before.loaderID,
            title: target.title,
            url: before.url,
            nodes: nodes,
            sourceTruncated: rawNodes.count > nodes.count || hasMissingChildren || reachesDepthBound
                || (axResult["macrouseSourceTruncated"] as? Bool ?? false) || actionEvidence.truncated
        )
    }

    nonisolated(nonsending)
    func press(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit,
        socket: any BrowserDocumentChannel
    ) async throws {
        let objectGroup = "heydash-mutation-\(UUID().uuidString)"
        var dispatch: ComputerActionEvidence.DispatchState?
        do {
            let objectID = try await prepareMutation(
                target: target,
                backendNodeID: backendNodeID,
                document: document,
                objectGroup: objectGroup,
                socket: socket
            )
            dispatch = .unknown
            let result = try await socket.command(
                method: "Runtime.callFunctionOn",
                params: [
                    "objectId": objectID,
                    "functionDeclaration": """
                    function(expectedURL) {
                      if (!(this instanceof HTMLElement) || !this.isConnected ||
                          this.ownerDocument !== document || window !== window.top ||
                          document.URL !== expectedURL || this.matches(":disabled") ||
                          this.closest('[inert], [aria-disabled="true" i]')) return false;
                      HTMLElement.prototype.click.call(this);
                      return true;
                    }
                    """,
                    "arguments": [["value": document.url.absoluteString]],
                    "returnByValue": true,
                    "awaitPromise": true,
                    "userGesture": true,
                ],
                permit: permit
            )
            if result["exceptionDetails"] == nil,
               let remote = result["result"] as? [String: Any], remote["value"] as? Bool == false {
                // The fixed function returns false only from its preconditions.
                dispatch = .notDispatched
            }
            try requireTrueCallResult(result, operation: "press")
            dispatch = .dispatched
        } catch {
            try? await releaseGroup(objectGroup, socket: socket)
            if let dispatch, dispatch != .notDispatched {
                throw BrowserMutationFailure(dispatchState: dispatch, underlyingError: error)
            }
            throw error
        }
        do { try await releaseGroup(objectGroup, socket: socket) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }

    nonisolated(nonsending)
    func setText(
        target: BrowserTarget,
        backendNodeID: Int64,
        text: String,
        document: BrowserDocumentObservation,
        permit: BrowserMutationPermit,
        socket: any BrowserDocumentChannel
    ) async throws {
        let objectGroup = "heydash-mutation-\(UUID().uuidString)"
        var dispatch: ComputerActionEvidence.DispatchState?
        do {
            let objectID = try await prepareMutation(
                target: target,
                backendNodeID: backendNodeID,
                document: document,
                objectGroup: objectGroup,
                socket: socket
            )
            dispatch = .unknown
            let result = try await socket.command(
                method: "Runtime.callFunctionOn",
                params: [
                    "objectId": objectID,
                    "functionDeclaration": """
                    function(expectedURL, value) {
                      if (!(this instanceof HTMLElement) || !this.isConnected ||
                          this.ownerDocument !== document || window !== window.top ||
                          document.URL !== expectedURL || this.matches(":disabled") ||
                          this.closest('[inert], [aria-disabled="true" i], [aria-readonly="true" i]')) {
                        return false;
                      }
                      if (this instanceof HTMLInputElement) {
                        if (this.readOnly ||
                            !["text", "search", "email", "url", "tel", "password"].includes(this.type)) {
                          return false;
                        }
                        const setter = Object.getOwnPropertyDescriptor(
                          HTMLInputElement.prototype, "value"
                        ).set;
                        setter.call(this, value);
                      } else if (this instanceof HTMLTextAreaElement) {
                        if (this.readOnly) return false;
                        const setter = Object.getOwnPropertyDescriptor(
                          HTMLTextAreaElement.prototype, "value"
                        ).set;
                        setter.call(this, value);
                      } else if (this.isContentEditable) {
                        this.textContent = value;
                      } else {
                        return false;
                      }
                      this.dispatchEvent(new Event("input", { bubbles: true }));
                      this.dispatchEvent(new Event("change", { bubbles: true }));
                      return true;
                    }
                    """,
                    "arguments": [
                        ["value": document.url.absoluteString],
                        ["value": text],
                    ],
                    "returnByValue": true,
                    "awaitPromise": true,
                    "userGesture": true,
                ],
                permit: permit
            )
            if result["exceptionDetails"] == nil,
               let remote = result["result"] as? [String: Any], remote["value"] as? Bool == false {
                dispatch = .notDispatched
            }
            try requireTrueCallResult(result, operation: "set text")
            dispatch = .dispatched
        } catch {
            try? await releaseGroup(objectGroup, socket: socket)
            if let dispatch, dispatch != .notDispatched {
                throw BrowserMutationFailure(dispatchState: dispatch, underlyingError: error)
            }
            throw error
        }
        do { try await releaseGroup(objectGroup, socket: socket) }
        catch { throw BrowserMutationFailure(dispatchState: .dispatched, underlyingError: error) }
    }

    /// Cleanup is an uncancelled, bounded request on the original channel. A
    /// failed release abandons that channel rather than leaking handles into a
    /// persistent session or retrying any mutation on a replacement session.
    nonisolated(nonsending)
    private func releaseGroup(_ group: String, socket: any BrowserDocumentChannel) async throws {
        let params = try JSONSerialization.data(withJSONObject: ["objectGroup": group])
        let cleanup = Task {
            try await socket.request(method: "Runtime.releaseObjectGroup", params: params, permit: nil)
        }
        do {
            _ = try await cleanup.value
        } catch {
            await socket.invalidate()
            throw error
        }
    }

    private struct FrameIdentity: Equatable, Sendable {
        let id: String
        let loaderID: String
        let url: URL
    }

    nonisolated(nonsending)
    private func frameIdentity(socket: any BrowserDocumentChannel) async throws -> FrameIdentity {
        let result = try await socket.command(method: "Page.getFrameTree")
        guard let tree = result["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any],
              let id = frame["id"] as? String, !id.isEmpty,
              let loaderID = frame["loaderId"] as? String, !loaderID.isEmpty,
              let rawURL = frame["url"] as? String,
              let url = URL(string: rawURL + (frame["urlFragment"] as? String ?? "")) else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "Page.getFrameTree did not contain a main-frame identity"
            )
        }
        return FrameIdentity(id: id, loaderID: loaderID, url: url)
    }

    nonisolated(nonsending)
    private func prepareMutation(
        target: BrowserTarget,
        backendNodeID: Int64,
        document: BrowserDocumentObservation,
        objectGroup: String,
        socket: any BrowserDocumentChannel
    ) async throws -> String {
        let current = try await observe(target: target, socket: socket)
        guard current.loaderID == document.loaderID, current.url == document.url else {
            throw BrowserTabBrokerError.staleDocument
        }
        let approvedNodes = document.nodes.filter { $0.backendNodeID == backendNodeID }
        let currentNodes = current.nodes.filter { $0.backendNodeID == backendNodeID }
        guard approvedNodes.count == 1, currentNodes.count == 1 else {
            throw BrowserTabBrokerError.elementNotFound
        }
        guard currentNodes[0] == approvedNodes[0],
              !currentNodes[0].isDisabled, !currentNodes[0].isIgnored else {
            throw BrowserTabBrokerError.elementChanged
        }
        try document.verificationPlan?.revalidateBaseline(document: current)

        let frame = try await frameIdentity(socket: socket)
        guard frame.loaderID == document.loaderID, frame.url == document.url else {
            throw BrowserTabBrokerError.staleDocument
        }
        let world = try await socket.command(
            method: "Page.createIsolatedWorld",
            params: [
                "frameId": frame.id,
                "worldName": "LocalCodexBrowserBroker",
            ]
        )
        guard let contextID = (world["executionContextId"] as? NSNumber)?.int64Value,
              contextID > 0 else {
            throw BrowserTabBrokerError.malformedDevToolsResponse(
                "Page.createIsolatedWorld did not return an execution context"
            )
        }
        let objectID = try await resolveObject(
            backendNodeID: backendNodeID,
            executionContextID: contextID,
            objectGroup: objectGroup,
            socket: socket
        )
        let after = try await frameIdentity(socket: socket)
        guard after == frame else {
            throw BrowserTabBrokerError.staleDocument
        }
        return objectID
    }

    nonisolated(nonsending)
    private func resolveObject(
        backendNodeID: Int64,
        executionContextID: Int64,
        objectGroup: String,
        socket: any BrowserDocumentChannel
    ) async throws -> String {
        let result = try await socket.command(
            method: "DOM.resolveNode",
            params: [
                "backendNodeId": backendNodeID,
                "executionContextId": executionContextID,
                "objectGroup": objectGroup,
            ]
        )
        guard let object = result["object"] as? [String: Any],
              let objectID = object["objectId"] as? String,
              !objectID.isEmpty else {
            throw BrowserTabBrokerError.elementNotFound
        }
        return objectID
    }

    private func requireTrueCallResult(
        _ result: [String: Any],
        operation: String
    ) throws {
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw BrowserTabBrokerError.mutationRejected(
                exception["text"] as? String ?? "\(operation) raised an exception"
            )
        }
        guard let remote = result["result"] as? [String: Any],
              (remote["value"] as? Bool) == true else {
            throw BrowserTabBrokerError.mutationRejected(
                "\(operation) did not return true"
            )
        }
    }

    private func parseNode(_ object: [String: Any], actionEvidence: BrowserDOMActionProjection) throws -> BrowserDocumentNode {
        let role = stringValue(object["role"]) ?? ""
        let name = stringValue(object["name"]) ?? ""
        var value = stringValue(object["value"])
        let properties = object["properties"] as? [[String: Any]] ?? []
        let disabled = properties.contains { property in
            property["name"] as? String == "disabled"
                && boolValue(property["value"]) == true
        }
        let readOnly = properties.contains { property in
            property["name"] as? String == "readonly"
                && boolValue(property["value"]) == true
        }
        let editable = properties.contains { property in
            guard property["name"] as? String == "editable" else { return false }
            return ["plaintext", "richtext", "true"].contains(stringValue(property["value"]) ?? "")
                || boolValue(property["value"]) == true
        }
        let backendID = (object["backendDOMNodeId"] as? NSNumber)?.int64Value
        let protectedValue = properties.contains { property in
            ["protected", "password"].contains(property["name"] as? String ?? "")
                && boolValue(property["value"]) == true
        }
        if !actionEvidence.truncated, let backendID, actionEvidence.emptyTextValues.contains(backendID),
           ["textbox", "searchbox", "combobox"].contains(role.lowercased()), editable,
           !disabled, !readOnly, !protectedValue, object["ignored"] as? Bool != true {
            guard value == nil || value == "" else { throw BrowserTabBrokerError.elementChanged }
            // Only this exact native field was explicitly observed empty.
            // Missing/unsupported DOM evidence never turns an absent AX value into empty.
            value = ""
        }
        let focusable = properties.contains { property in
            property["name"] as? String == "focusable" && boolValue(property["value"]) == true
        }
        return BrowserDocumentNode(
            backendNodeID: (object["backendDOMNodeId"] as? NSNumber)?.int64Value,
            role: role,
            name: name,
            value: value,
            isDisabled: disabled,
            isReadOnly: readOnly,
            isIgnored: object["ignored"] as? Bool ?? false,
            nodeID: object["nodeId"] as? String,
            parentNodeID: object["parentId"] as? String,
            childNodeIDs: object["childIds"] as? [String] ?? [],
            linkURL: properties.first { $0["name"] as? String == "url" }
                .flatMap { stringValue($0["value"]) },
            isDOMClickable: backendID.map { actionEvidence.clickable.contains($0) } ?? false,
            isFocusablePointer: focusable && (backendID.map { actionEvidence.pointer.contains($0) } ?? false),
            isEditable: editable
        )
    }

    private func stringValue(_ raw: Any?) -> String? {
        guard let object = raw as? [String: Any] else { return nil }
        if let value = object["value"] as? String {
            return value
        }
        if let value = object["value"] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        guard let object = raw as? [String: Any] else { return nil }
        return object["value"] as? Bool
    }

}

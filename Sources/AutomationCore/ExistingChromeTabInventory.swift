import ApplicationServices
import Foundation

@MainActor
protocol ExistingChromeTabIdentity: AnyObject {
    func isSame(as other: any ExistingChromeTabIdentity) -> Bool
}

@MainActor
struct ExistingChromeTabInventory {
    let tabs: [any ExistingChromeTabIdentity]
    let selected: any ExistingChromeTabIdentity

    func isSame(as other: Self) -> Bool {
        tabs.count == other.tabs.count && hasUniqueTabs && other.hasUniqueTabs
            && tabs.allSatisfy { old in other.tabs.contains { $0.isSame(as: old) } }
            && selected.isSame(as: other.selected)
    }

    func newlySelectedTab(since before: Self) -> (any ExistingChromeTabIdentity)? {
        guard hasUniqueTabs, before.hasUniqueTabs, tabs.count == before.tabs.count + 1,
              before.tabs.allSatisfy({ old in tabs.contains { $0.isSame(as: old) } }) else { return nil }
        let added = tabs.filter { tab in !before.tabs.contains { $0.isSame(as: tab) } }
        guard added.count == 1, selected.isSame(as: added[0]) else { return nil }
        return added[0]
    }

    func hasSelected(_ identity: any ExistingChromeTabIdentity) -> Bool {
        hasUniqueTabs && selected.isSame(as: identity) && tabs.contains { $0.isSame(as: identity) }
    }

    private var hasUniqueTabs: Bool {
        !tabs.isEmpty && tabs.enumerated().allSatisfy { index, tab in
            !tabs.prefix(index).contains { $0.isSame(as: tab) }
        }
    }
}

@MainActor
private final class NativeChromeTabIdentity: ExistingChromeTabIdentity {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    func isSame(as other: any ExistingChromeTabIdentity) -> Bool {
        guard let other = other as? NativeChromeTabIdentity else { return false }
        return CFEqual(element, other.element)
    }
}

@MainActor
enum NativeChromeTabInventory {
    /// Native browser chrome only. Never read titles, URLs, labels, or web
    /// descendants. More than one tab group or an incomplete traversal refuses.
    static func read(window: AXUIElement, processIdentifier: Int32) throws -> ExistingChromeTabInventory {
        guard AXIsProcessTrusted() else { throw AutomationError.permissionNotGranted(.accessibility) }
        var queue: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var cursor = 0
        var visited = [AXUIElement]()
        var groups = 0
        var tabs = [NativeChromeTabIdentity]()
        var selected = [NativeChromeTabIdentity]()
        while cursor < queue.count {
            guard cursor < 512 else { throw ExistingChromeError.tabStateNotVerified }
            let (element, depth, inTabGroup) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == processIdentifier,
                  let role = try attribute(element, kAXRoleAttribute) as? String else {
                throw ExistingChromeError.tabStateNotVerified
            }
            if role == "AXWebArea" || role == "AXDocument" { continue }
            let isGroup = role == "AXTabGroup"
            if isGroup { groups += 1 }
            if inTabGroup, role == "AXRadioButton" {
                let tab = NativeChromeTabIdentity(element)
                tabs.append(tab)
                if let value = try attribute(element, kAXValueAttribute) as? NSNumber,
                   value == 1 { selected.append(tab) }
            }
            guard let children = try attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            guard children.isEmpty || depth < 20, queue.count + children.count <= 512 else {
                throw ExistingChromeError.tabStateNotVerified
            }
            queue += children.map { ($0, depth + 1, inTabGroup || isGroup) }
        }
        guard groups == 1, !tabs.isEmpty, selected.count == 1 else {
            throw ExistingChromeError.tabStateNotVerified
        }
        return ExistingChromeTabInventory(tabs: tabs, selected: selected[0])
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return nil }
        guard result == .success else {
            throw AutomationError.accessibilityFailure(operation: name, code: result.rawValue)
        }
        return value
    }
}

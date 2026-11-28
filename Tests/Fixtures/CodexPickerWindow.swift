// Test-only. Inspect the isolated Codex process launched by the fixture driver.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count >= 3, let pid = pid_t(CommandLine.arguments[1]) else { exit(2) }
let app = AXUIElementCreateApplication(pid)
guard AXIsProcessTrusted() else { fputs("Accessibility is required to verify the test window.\n", stderr); exit(2) }
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
func get(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
var wanted = Set(CommandLine.arguments.dropFirst(2))
let button = CommandLine.arguments.count == 4 && CommandLine.arguments[2] == "--press" ? CommandLine.arguments[3] : nil
var stack = get(app, "AXWindows") as? [AXUIElement] ?? []
var visited = 0
while let node = stack.popLast(), visited < 5000 {
    visited += 1
    let title = get(node, "AXTitle") as? String
    if let button, title == button, let role = get(node, "AXRole") as? String,
       ["AXButton", "AXRadioButton"].contains(role) {
        exit(AXUIElementPerformAction(node, kAXPressAction as CFString) == .success ? 0 : 1)
    }
    if let title { wanted.remove(title) }
    if let value = get(node, "AXValue") as? String { wanted.remove(value) }
    if wanted.isEmpty { exit(0) }
    stack += get(node, "AXChildren") as? [AXUIElement] ?? []
}
exit(1)

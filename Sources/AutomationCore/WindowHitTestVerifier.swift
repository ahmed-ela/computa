import CoreGraphics
import Foundation

/// A single entry in the system window list. The list is ordered front to back.
/// Missing metadata is retained so a window in front of the target cannot be
/// silently discarded when its bounds or identifier cannot be decoded.
struct WindowHitTestDescriptor: Sendable {
    let windowID: CGWindowID?
    let frame: WindowFrame?
    let ownerName: String?
    let ownerPID: Int32?

    init(
        windowID: CGWindowID?,
        frame: WindowFrame?,
        ownerName: String? = nil,
        ownerPID: Int32? = nil
    ) {
        self.windowID = windowID
        self.frame = frame
        self.ownerName = WindowHitTestOwnerDiagnostic.sanitizeName(ownerName)
        self.ownerPID = ownerPID.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Observed process metadata is untrusted diagnostic text, never an input to
/// hit-testing or authorization. Do not include window titles here.
private enum WindowHitTestOwnerDiagnostic {
    static func sanitizeName(_ name: String?) -> String? {
        guard let name else { return nil }
        var sanitized = String.UnicodeScalarView()
        // Bound both input inspection and output, including combining marks.
        for scalar in name.unicodeScalars.prefix(1_024) {
            let isControl: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                isControl = true
            default:
                isControl = false
            }
            if isControl || scalar.properties.isWhitespace {
                if !sanitized.isEmpty, sanitized.last != " " {
                    sanitized.append(" ")
                }
            } else {
                sanitized.append(scalar)
            }
            if sanitized.count >= 80 { break }
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    static func pid(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(Int32.max),
              value.rounded(.towardZero) == value else { return nil }
        return Int32(value)
    }

    static func quotedName(_ name: String) -> String {
        guard let encoded = try? JSONEncoder().encode(name) else { return "\"unavailable\"" }
        return String(decoding: encoded, as: UTF8.self)
    }
}

public enum WindowHitTestError: Error, Equatable, LocalizedError, Sendable {
    case windowListUnavailable
    case noActionPoints
    case invalidActionPoint
    case expectedWindowMissing(CGWindowID)
    case expectedWindowGeometryUnavailable(CGWindowID)
    case pointOutsideExpectedWindow(CGWindowID)
    case frontWindowGeometryUnavailable
    case obscuredByWindow(CGWindowID?)
    case obscuredByWindowOwner(windowID: CGWindowID?, ownerName: String?, ownerPID: Int32?)

    public var errorDescription: String? {
        switch self {
        case .windowListUnavailable:
            return "The on-screen window order could not be read. The action was not sent."
        case .noActionPoints:
            return "At least one screen point is required to verify the action target."
        case .invalidActionPoint:
            return "The action contains a non-finite screen point."
        case let .expectedWindowMissing(windowID):
            return "The expected window \(windowID) is not in the on-screen window list."
        case let .expectedWindowGeometryUnavailable(windowID):
            return "The expected window \(windowID) has unavailable or invalid geometry."
        case let .pointOutsideExpectedWindow(windowID):
            return "The action point or path is outside the expected window \(windowID)."
        case .frontWindowGeometryUnavailable:
            return "A window above the target has unavailable geometry, so the action target cannot be verified."
        case let .obscuredByWindow(windowID):
            if let windowID {
                return "On-screen window \(windowID) is above the target at the action point or path."
            }
            return "An unidentified on-screen window is above the target at the action point or path."
        case let .obscuredByWindowOwner(windowID, ownerName, ownerPID):
            let base = Self.obscuredByWindow(windowID).localizedDescription
            var details: [String] = []
            // Sanitize here too: callers can construct this public error directly.
            if let name = WindowHitTestOwnerDiagnostic.sanitizeName(ownerName) {
                details.append("name=\(WindowHitTestOwnerDiagnostic.quotedName(name))")
            }
            if let ownerPID, ownerPID > 0 {
                details.append("pid=\(ownerPID)")
            }
            guard !details.isEmpty else { return base }
            return "\(base) Observed owner metadata (diagnostic only): \(details.joined(separator: ", ")). The action was not sent."
        }
    }
}

/// Pure, conservative hit-target check. `points` describe the action path in
/// order; a pair of points also checks the segment between them for drag-like
/// actions. Quartz does not expose whether a window ignores mouse events, so
/// *every* on-screen window above the expected one is treated as potentially
/// intercepting, including a transparent overlay.
enum WindowHitTestReducer {
    static func verify(
        expectedWindowID: CGWindowID,
        points: [ScreenPoint],
        windowsFrontToBack: [WindowHitTestDescriptor]
    ) throws {
        guard !points.isEmpty else {
            throw WindowHitTestError.noActionPoints
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw WindowHitTestError.invalidActionPoint
        }

        var windowsAboveTarget: [WindowHitTestDescriptor] = []
        for window in windowsFrontToBack {
            guard window.windowID == expectedWindowID else {
                windowsAboveTarget.append(window)
                continue
            }

            guard let targetFrame = window.frame, valid(targetFrame) else {
                throw WindowHitTestError.expectedWindowGeometryUnavailable(expectedWindowID)
            }
            guard points.allSatisfy({ contains($0, in: targetFrame) }) else {
                throw WindowHitTestError.pointOutsideExpectedWindow(expectedWindowID)
            }

            for frontWindow in windowsAboveTarget {
                guard let frontFrame = frontWindow.frame, valid(frontFrame, mayBeEmpty: true) else {
                    throw WindowHitTestError.frontWindowGeometryUnavailable
                }
                // A finite, zero-area window cannot contain or cross a point.
                if frontFrame.width == 0 || frontFrame.height == 0 {
                    continue
                }
                if pathIntersects(points, frame: frontFrame) {
                    if frontWindow.ownerName != nil || frontWindow.ownerPID != nil {
                        throw WindowHitTestError.obscuredByWindowOwner(
                            windowID: frontWindow.windowID,
                            ownerName: frontWindow.ownerName,
                            ownerPID: frontWindow.ownerPID
                        )
                    }
                    throw WindowHitTestError.obscuredByWindow(frontWindow.windowID)
                }
            }
            return
        }
        throw WindowHitTestError.expectedWindowMissing(expectedWindowID)
    }

    private static func valid(
        _ frame: WindowFrame,
        mayBeEmpty: Bool = false
    ) -> Bool {
        frame.x.isFinite && frame.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            (mayBeEmpty ? frame.width >= 0 : frame.width > 0) &&
            (mayBeEmpty ? frame.height >= 0 : frame.height > 0) &&
            (frame.x + frame.width).isFinite &&
            (frame.y + frame.height).isFinite
    }

    private static func contains(_ point: ScreenPoint, in frame: WindowFrame) -> Bool {
        point.x >= frame.x && point.x < frame.x + frame.width &&
            point.y >= frame.y && point.y < frame.y + frame.height
    }

    private static func pathIntersects(_ points: [ScreenPoint], frame: WindowFrame) -> Bool {
        if points.contains(where: { contains($0, in: frame) }) {
            return true
        }
        for index in 1 ..< points.count {
            if segmentIntersects(points[index - 1], points[index], frame: frame) {
                return true
            }
        }
        return false
    }

    /// Liang-Barsky clipping against the closed rectangle. Treating even a
    /// boundary touch as overlap is intentional: the action must fail closed.
    private static func segmentIntersects(
        _ start: ScreenPoint,
        _ end: ScreenPoint,
        frame: WindowFrame
    ) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let constraints: [(Double, Double)] = [
            (-dx, start.x - frame.x),
            (dx, frame.x + frame.width - start.x),
            (-dy, start.y - frame.y),
            (dy, frame.y + frame.height - start.y),
        ]
        var lower = 0.0
        var upper = 1.0
        for (p, q) in constraints {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let ratio = q / p
                if p < 0 {
                    lower = max(lower, ratio)
                } else {
                    upper = min(upper, ratio)
                }
                if lower > upper { return false }
            }
        }
        return true
    }
}

/// Checks the actual z-order immediately before a screen-coordinate input
/// event. This is a best-effort snapshot, not an atomic lock on the WindowServer;
/// callers should perform this synchronously adjacent to posting the event.
@MainActor
public final class WindowHitTestVerifier {
    public init() {}

    public func verifyUnobstructed(
        expectedWindowID: CGWindowID,
        points: [ScreenPoint]
    ) throws {
        guard let rawList = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw WindowHitTestError.windowListUnavailable
        }
        let descriptors = rawList.map(Self.describe)
        try WindowHitTestReducer.verify(
            expectedWindowID: expectedWindowID,
            points: points,
            windowsFrontToBack: descriptors
        )
    }

    nonisolated static func describe(_ values: [String: Any]) -> WindowHitTestDescriptor {
        let windowID = (values[kCGWindowNumber as String] as? NSNumber).map {
            CGWindowID(truncating: $0)
        }
        let frame: WindowFrame?
        if let bounds = values[kCGWindowBounds as String] as? [String: Any],
           let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
            frame = WindowFrame(
                x: rectangle.origin.x,
                y: rectangle.origin.y,
                width: rectangle.width,
                height: rectangle.height
            )
        } else {
            frame = nil
        }
        return WindowHitTestDescriptor(
            windowID: windowID,
            frame: frame,
            ownerName: values[kCGWindowOwnerName as String] as? String,
            ownerPID: WindowHitTestOwnerDiagnostic.pid(values[kCGWindowOwnerPID as String])
        )
    }
}

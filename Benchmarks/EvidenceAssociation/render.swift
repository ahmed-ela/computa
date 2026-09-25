// Offscreen synthetic page renderer. No window, browser, or desktop capture.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: String) throws -> CGColor {
    guard hex.count == 7, hex.first == "#", let n = UInt32(hex.dropFirst(), radix: 16) else { throw Failure.invalid }
    return CGColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
}
enum Failure: Error { case invalid }
guard CommandLine.arguments.count == 3 else { throw Failure.invalid }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [[String: Any]] else { throw Failure.invalid }
for fixture in fixtures {
    guard let id = fixture["id"] as? String, id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { throw Failure.invalid }
    var observations: [(String, [String: Any])] = [(id, fixture)]
    if let prior = fixture["priorObservation"] as? [String: Any] { observations.append((id + "-prior", prior)) }
    for (name, observation) in observations {
        guard let primitives = observation["primitives"] as? [[String: Any]],
              let context = CGContext(data: nil, width: 1000, height: 650, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalid }
        for p in primitives {
            guard let kind = p["kind"] as? String, let x = p["x"] as? Double, let y = p["y"] as? Double,
                  let fill = p["fill"] as? String else { throw Failure.invalid }
            let paint = try color(fill)
            if kind == "rect" {
                guard let w = p["width"] as? Double, let h = p["height"] as? Double else { throw Failure.invalid }
                let rect = CGRect(x: x, y: 650 - y - h, width: w, height: h)
                let radius = p["radius"] as? Double ?? 0
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.addPath(path); context.setFillColor(paint); context.fillPath()
                if let stroke = p["stroke"] as? String { context.addPath(path); context.setStrokeColor(try color(stroke)); context.setLineWidth(1); context.strokePath() }
            } else if kind == "text" {
                guard let text = p["text"] as? String, let size = p["size"] as? Double else { throw Failure.invalid }
                let font = CTFontCreateWithName(((p["weight"] as? Int ?? 400) >= 600 ? "Arial-BoldMT" : "ArialMT") as CFString, size, nil)
                let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: paint] as [CFString: Any]
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
                let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                guard x >= 0, x + bounds.width <= 1000, y - size >= 0, y <= 650 else { throw Failure.invalid }
                context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: 650 - y); CTLineDraw(line, context)
            } else { throw Failure.invalid }
        }
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalid }
        print(name)
    }
}

import AppKit
import ScreenCaptureKit
import XCTest

/// Reads only the marked search icon in the test's own window. No screen recording grant is needed.
@available(macOS 14.4, *)
final class SidebarIconCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "KolmogorTests.sidebar-icon")
    private let stream: SCStream
    private var samples: [CGFloat?] = []
    var positions: [CGFloat?] { queue.sync { samples } }

    @MainActor
    init(window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.sourceRect = CGRect(x: 0, y: 0, width: 180, height: 160)
        configuration.width = 180
        configuration.height = 160
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: ownWindow),
                          configuration: configuration, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws { try await stream.startCapture() }
    func stop() async throws { try await stream.stopCapture() }

    func waitForIcon() async throws -> CGFloat {
        for _ in 0..<60 {
            if let first = queue.sync(execute: { samples.compactMap { $0 }.first }) {
                queue.sync { samples.removeAll() }
                return first
            }
            try await Task.sleep(for: .milliseconds(32))
        }
        return try XCTUnwrap(positions.compactMap { $0 }.first, "WindowServer must render the marked test icon")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue,
              let image = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(image), stride = CVPixelBufferGetBytesPerRow(image)
        var left = width, right = -1
        for y in 0..<CVPixelBufferGetHeight(image) {
            for x in 0..<width {
                let p = y * stride + x * 4
                if pixels[p] > 180, pixels[p + 1] < 75, pixels[p + 2] > 180 {
                    left = min(left, x)
                    right = max(right, x)
                }
            }
        }
        samples.append(right >= left ? CGFloat(left + right) / 2 : nil)
    }
}

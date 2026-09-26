// Benchmark-only, one PNG -> private bounded OCR JSON. No UI or model server.
import Foundation
import Vision
import ImageIO
import CryptoKit
import Darwin

enum Failure: Error { case invalid(String) }
struct Record: Codable { let text: String; let confidence: Float; let box: [Double] }
struct Result: Encodable {
    let schema_version = 1
    let recognizer = "apple_vision"
    let recognition_level = "accurate"
    let language = "en-US"
    let uses_language_correction = false
    let compute_policy: String
    let recognition_revision: Int
    let image_sha256: String
    let width: Int
    let height: Int
    let detected_count: Int
    let omitted_count: Int
    let records: [Record]
    let elapsed_ms: Double
}

guard CommandLine.arguments.count == 3 || (CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--cpu-only") else {
    throw Failure.invalid("Usage: swift native-ocr.swift INPUT.png OUTPUT.json [--cpu-only]")
}
guard CommandLine.arguments[1].hasPrefix("/"), CommandLine.arguments[2].hasPrefix("/") else {
    throw Failure.invalid("Use absolute input and output paths")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard input.path.hasPrefix("/"), output.path.hasPrefix("/"),
      !FileManager.default.fileExists(atPath: output.path) else {
    throw Failure.invalid("Use absolute paths and a new private output file")
}
let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
guard size > 0 && size <= 32 * 1_024 * 1_024 else { throw Failure.invalid("PNG byte bound exceeded") }
let bytes = try Data(contentsOf: input)
guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetType(source) as String? == "public.png",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 8_000_000 / height,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    throw Failure.invalid("Expected one PNG with at most 8 million pixels")
}
let request = VNRecognizeTextRequest()
let cpuOnly = CommandLine.arguments.count == 4
if cpuOnly { request.usesCPUOnly = true }
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
request.minimumTextHeight = 0
// A process-level hard bound also covers a native Vision request that ignores
// cooperative cancellation. Timeout cannot leave a plausible success JSON.
signal(SIGALRM) { _ in _exit(124) }
// Cold on-device model compilation was observed in an owned-process sample.
// Keep a hard bound, but do not mistake the old 10-second deadline for a
// measured recognition latency. Warm recognition is reported separately.
alarm(60)
let started = DispatchTime.now().uptimeNanoseconds
try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
alarm(0)
let observations = request.results ?? []
var records = [Record]()
for observation in observations.prefix(128) {
    guard let candidate = observation.topCandidates(1).first,
          !candidate.string.isEmpty, candidate.string.utf8.count <= 512,
          candidate.confidence.isFinite, (0 ... 1).contains(candidate.confidence) else { continue }
    let b = observation.boundingBox
    let box = [Double(b.minX), Double(1 - b.maxY), Double(b.width), Double(b.height)]
    guard box.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
          box[2] > 0, box[3] > 0, box[0] + box[2] <= 1.000001,
          box[1] + box[3] <= 1.000001 else { continue }
    records.append(Record(text: candidate.string, confidence: candidate.confidence, box: box))
}
let result = Result(
    compute_policy: cpuOnly ? "cpu_only" : "automatic",
    recognition_revision: request.revision,
    image_sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    width: width, height: height, detected_count: observations.count,
    omitted_count: observations.count - records.count, records: records, elapsed_ms: elapsed
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(result)
guard data.count <= 128 * 1_024 else { throw Failure.invalid("OCR result bound exceeded") }
try data.write(to: output, options: .withoutOverwriting)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
print("OCR saved: records=\(records.count) omitted=\(result.omitted_count) elapsed_ms=\(elapsed)")

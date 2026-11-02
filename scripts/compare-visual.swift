// Compare native-size PNGs in sRGB. No rescaling, registration, or automatic baseline recording.
// Usage: compare-visual reference.png actual.png difference.png [channel-tolerance]
//        compare-visual --self-test
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VisualError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= 32_000_000 / height, bytes.count == width * height * 4 else {
            throw VisualError("Invalid or excessive image dimensions or byte length")
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width <= 32_000_000 / height else {
            throw VisualError("Missing, unreadable, or oversized image: \(url.lastPathComponent)")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VisualError("Cannot decode image: \(url.lastPathComponent)")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { throw VisualError("Cannot normalize image pixels") }
        try self.init(width: width, height: height, bytes: bytes)
    }

    func write(to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw VisualError("Cannot create difference image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VisualError("Cannot finish difference image") }
    }
}

func compare(_ reference: Pixels, _ actual: Pixels, tolerance: Int) throws -> (Int, Pixels) {
    guard (0...16).contains(tolerance) else { throw VisualError("Channel tolerance must be in 0...16") }
    guard reference.width == actual.width, reference.height == actual.height else {
        throw VisualError("Image dimensions differ; native captures must not be resized")
    }
    var difference = [UInt8](repeating: 0, count: actual.bytes.count)
    var changed = 0
    for index in stride(from: 0, to: actual.bytes.count, by: 4) {
        var maximum = 0
        for channel in 0..<4 {
            maximum = max(maximum, abs(Int(reference.bytes[index + channel]) - Int(actual.bytes[index + channel])))
        }
        difference[index + 3] = 255
        if maximum > tolerance {
            changed += 1
            difference[index] = 255
            difference[index + 2] = 180
        } else {
            for channel in 0..<3 { difference[index + channel] = actual.bytes[index + channel] / 4 }
        }
    }
    return (changed, try Pixels(width: actual.width, height: actual.height, bytes: difference))
}

func selfTest() throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VisualError("Self-test failed: \(message)") }
    }
    let reference = try Pixels(width: 8, height: 8, bytes: [UInt8](repeating: 255, count: 256))
    try require(compare(reference, reference, tolerance: 0).0 == 0, "identical image")
    var missingControl = reference
    missingControl.bytes[4 * 19 + 1] = 0
    try require(compare(reference, missingControl, tolerance: 0).0 == 1, "one-pixel change is detected")
    var mappingError = reference
    for pixel in 0..<32 { mappingError.bytes[4 * pixel] = 0 }
    try require(compare(reference, mappingError, tolerance: 2).0 == 32, "mapping failure is detected")
    var noise = reference
    noise.bytes[0] = 253
    try require(compare(reference, noise, tolerance: 2).0 == 0, "bounded per-channel tolerance")
    try require(compare(reference, noise, tolerance: 0).0 == 1, "exact comparison is the default")
    let wrongSize = try Pixels(width: 4, height: 16, bytes: reference.bytes)
    do { _ = try compare(reference, wrongSize, tolerance: 0); throw VisualError("Dimension mismatch accepted") }
    catch let error as VisualError { try require(error.description.contains("dimensions differ"), "dimensions rejected") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-visual-compare-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = directory.appendingPathComponent("test.png")
    try reference.write(to: png)
    try require(compare(reference, Pixels(url: png), tolerance: 0).0 == 0, "PNG round trip")
    let invalid = directory.appendingPathComponent("invalid.png")
    try Data("not a PNG".utf8).write(to: invalid)
    do { _ = try Pixels(url: invalid); throw VisualError("Invalid image accepted") }
    catch let error as VisualError { try require(error.description.contains("unreadable"), "invalid image rejected") }
    print("PASS: identical, one-pixel, mapping, tolerance, dimensions, PNG round-trip, and corrupt-image checks")
}

do {
    let args = CommandLine.arguments
    if args.count == 2, args[1] == "--self-test" {
        try selfTest()
    } else {
        guard args.count == 4 || args.count == 5 else {
            throw VisualError("Usage: compare-visual reference.png actual.png difference.png [channel-tolerance]")
        }
        let tolerance: Int
        if args.count == 5 {
            guard let parsed = Int(args[4]) else { throw VisualError("Invalid channel tolerance") }
            tolerance = parsed
        } else { tolerance = 0 }
        let reference = try Pixels(url: URL(fileURLWithPath: args[1]))
        let actual = try Pixels(url: URL(fileURLWithPath: args[2]))
        let (changed, difference) = try compare(reference, actual, tolerance: tolerance)
        try difference.write(to: URL(fileURLWithPath: args[3]))
        let report: [String: Any] = ["changed_pixels": changed, "total_pixels": actual.width * actual.height,
                                   "channel_tolerance": tolerance, "match": changed == 0]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        if changed > 0 { exit(1) }
    }
} catch {
    FileHandle.standardError.write(Data("visual-compare: \(error)\n".utf8))
    exit(2)
}

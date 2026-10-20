// Generates the media for Piq's PhotoKit end-to-end tests:
//
//   60 photos E2E_1001 ... E2E_1060, with distinct EXIF capture dates over two days
//   (10 and 11 Oct 2026, local time, 08:00 to 19:07, 23 minutes apart). Filename order, import
//   order and capture order all differ, so a test can tell "oldest first" from either of them.
//   Landscape (4032x3024 or 3600x2400) and portrait (3024x4032 or 2400x3600); E2E_1010 is 48 MP
//   (8064x6048). Each photo shows its name and capture time in large type, and a fine grid that
//   only reads as sharp at full resolution. Files listed in heic.txt are converted to HEIC by
//   prepare-library.sh with `sips -s format heic` (EXIF dates survive the conversion).
//
//   E2E_SMALL.JPG, 1200x900 (10 Oct 07:30:00): an original smaller than the screen, to check that
//   Piq never upscales a photo. It is in no album.
//
//   2 videos E2E_CLIP1.MOV (10 Oct 12:00:30) and E2E_CLIP2.MOV (11 Oct 15:30:30), 2 s of H.264,
//   written with AVAssetWriter.
//
// Also writes manifest.tsv (file, capture date, size) and import-order.txt (the order to pass
// to `xcrun simctl addmedia`).
//
// The tests derive what they expect (capture dates, pixel sizes, the HEIC set, the 48 MP photo,
// the grid patch they measure sharpness on) from these formulas: PhotoKitTestMedia in
// PiqTests/PhotoKitTestLibrary.swift and E2EMedia in PiqUITests/PhotoKitEndToEndTests.swift
// mirror them, so change them together.
//
// Usage (prepare-library.sh compiles and runs it): gen_media <out-dir>
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let photoCount = 60
let exifFormatter = DateFormatter()
exifFormatter.locale = Locale(identifier: "en_US_POSIX")
exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

/// Capture slot of photo `index` (0-based): a permutation of 0..<60, so names don't follow time.
func slot(of index: Int) -> Int { (index * 37) % photoCount }

/// "2026:10:10 08:00:13": slots 0-29 on the first day, 30-59 on the second, 23 minutes apart.
func captureDate(slot: Int) -> String {
    let day = slot < 30 ? 10 : 11
    let minutes = 8 * 60 + (slot % 30) * 23
    let seconds = (slot * 13) % 60
    return String(format: "2026:10:%02d %02d:%02d:%02d", day, minutes / 60, minutes % 60, seconds)
}

func isPortrait(_ index: Int) -> Bool { index % 3 == 1 }
func isHEIC(_ index: Int) -> Bool { index % 10 == 4 }
let bigIndex = 9

let smallIndex = 99

func pixelSize(_ index: Int) -> (Int, Int) {
    if index == bigIndex { return (8064, 6048) }
    if index == smallIndex { return (1200, 900) }
    let (long, short) = index % 5 == 2 ? (3600, 2400) : (4032, 3024)
    return isPortrait(index) ? (short, long) : (long, short)
}

func color(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
    // HSB to RGB.
    let h = (hue.truncatingRemainder(dividingBy: 1)) * 6
    let c = brightness * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = brightness - c
    let (r, g, b): (CGFloat, CGFloat, CGFloat)
    switch Int(h) {
    case 0: (r, g, b) = (c, x, 0)
    case 1: (r, g, b) = (x, c, 0)
    case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c)
    case 4: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
}

func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}

func renderPhoto(index: Int, name: String, date: String) -> CGImage {
    let (width, height) = pixelSize(index)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let w = CGFloat(width), h = CGFloat(height)
    let s = min(w, h) / 3024
    let hue = CGFloat(slot(of: index % photoCount)) / CGFloat(photoCount)

    // Two-tone background (a "sky" and a "ground"), so thumbnails are easy to tell apart.
    context.setFillColor(color(hue, 0.45, 0.85))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    context.setFillColor(color(hue + 0.08, 0.6, 0.45))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.38))

    // A fine grid: 2 px lines every 12 px. Crisp at full resolution, mush in a blurred preview.
    let grid = CGRect(x: w * 0.55, y: h * 0.08, width: w * 0.38, height: h * 0.24)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(grid)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    var x = grid.minX
    while x < grid.maxX {
        context.fill(CGRect(x: x, y: grid.minY, width: 2, height: grid.height))
        x += 12
    }
    var y = grid.minY
    while y < grid.maxY {
        context.fill(CGRect(x: grid.minX, y: y, width: grid.width, height: 2))
        y += 12
    }

    // An "up" marker at the top edge: a triangle.
    context.setFillColor(CGColor(gray: 1, alpha: 0.9))
    context.move(to: CGPoint(x: w / 2, y: h - 60 * s))
    context.addLine(to: CGPoint(x: w / 2 - 120 * s, y: h - 260 * s))
    context.addLine(to: CGPoint(x: w / 2 + 120 * s, y: h - 260 * s))
    context.fillPath()

    let ink = CGColor(gray: 0.05, alpha: 1)
    drawText(name, in: context, at: CGPoint(x: 140 * s, y: h * 0.62), size: 420 * s, color: ink)
    drawText(date, in: context, at: CGPoint(x: 150 * s, y: h * 0.62 - 330 * s), size: 200 * s, color: ink)
    drawText("\(width) x \(height)", in: context, at: CGPoint(x: 150 * s, y: h * 0.62 - 560 * s), size: 140 * s, color: ink)
    return context.makeImage()!
}

func writeJPEG(_ image: CGImage, date: String, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.82,
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: date,
            kCGImagePropertyExifDateTimeDigitized: date,
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: date,
            kCGImagePropertyTIFFMake: "Piq",
            kCGImagePropertyTIFFModel: "E2E Generator",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

// MARK: Photos

var manifest = ["file\tcapture\twidth\theight"]
var heicFiles: [String] = []
var importOrder: [String] = []
for index in 0..<photoCount {
    let name = "E2E_\(1001 + index)"
    let date = captureDate(slot: slot(of: index))
    let url = outDir.appendingPathComponent("\(name).JPG")
    let converted = outDir.appendingPathComponent("\(name).HEIC")
    if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: converted.path) {
        writeJPEG(renderPhoto(index: index, name: name, date: date), date: date, to: url)
    }
    let (width, height) = pixelSize(index)
    let file = isHEIC(index) ? "\(name).HEIC" : "\(name).JPG"
    if isHEIC(index) { heicFiles.append(name) }
    manifest.append("\(file)\t\(date)\t\(width)\t\(height)")
    importOrder.append(file)
}

let smallDate = "2026:10:10 07:30:00"
let smallURL = outDir.appendingPathComponent("E2E_SMALL.JPG")
if !FileManager.default.fileExists(atPath: smallURL.path) {
    writeJPEG(renderPhoto(index: smallIndex, name: "E2E_SMALL", date: smallDate), date: smallDate, to: smallURL)
}
manifest.append("E2E_SMALL.JPG\t\(smallDate)\t1200\t900")
importOrder.append("E2E_SMALL.JPG")

// MARK: Videos

func writeVideo(name: String, creationDate: String, hue: CGFloat) throws {
    let url = outDir.appendingPathComponent("\(name).MOV")
    if FileManager.default.fileExists(atPath: url.path) { return }
    let width = 1280, height = 720, frames = 60
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let creation = AVMutableMetadataItem()
    creation.identifier = .quickTimeMetadataCreationDate
    creation.value = creationDate as NSString
    creation.dataType = kCMMetadataBaseDataType_UTF8 as String
    writer.metadata = [creation]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("No pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(color(hue, 0.5, 0.8))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: CGFloat(frame) * CGFloat(width - 120) / CGFloat(frames), y: 300, width: 120, height: 120))
        drawText(name, in: context, at: CGPoint(x: 60, y: 560), size: 90, color: CGColor(gray: 0.05, alpha: 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

try writeVideo(name: "E2E_CLIP1", creationDate: "2026-10-10T12:00:30+0200", hue: 0.6)
try writeVideo(name: "E2E_CLIP2", creationDate: "2026-10-11T15:30:30+0200", hue: 0.1)
manifest.append("E2E_CLIP1.MOV\t2026:10:10 12:00:30\t1280\t720")
manifest.append("E2E_CLIP2.MOV\t2026:10:11 15:30:30\t1280\t720")

// Import order: every 7th file, wrapping (another permutation), then the videos.
let shuffled = (0..<photoCount).map { importOrder[($0 * 7) % photoCount] }
try (shuffled + ["E2E_SMALL.JPG", "E2E_CLIP1.MOV", "E2E_CLIP2.MOV"]).joined(separator: "\n").appending("\n")
    .write(to: outDir.appendingPathComponent("import-order.txt"), atomically: true, encoding: .utf8)
try heicFiles.joined(separator: "\n").appending("\n").write(to: outDir.appendingPathComponent("heic.txt"), atomically: true, encoding: .utf8)
try manifest.joined(separator: "\n").appending("\n").write(to: outDir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
print("Wrote \(photoCount) photos and 2 videos to \(outDir.path)")

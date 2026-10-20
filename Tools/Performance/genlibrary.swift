// Generates a realistic photo library for measuring Piq against real PhotoKit.
//
// Each photo starts from one of Piq's mock photos (Preview Assets.xcassets/MockPhotoNN), gets a
// random crop, exposure / white balance / vibrance changes, a vignette, multi-scale texture and
// film-like luminance + chroma grain, and is upscaled to camera resolution, so JPEG sizes and
// decode costs are those of real photos (12 MP: about 2.5-5 MB). EXIF carries a distinct capture
// date (three days, daytime, in bursts), camera make/model and pixel size.
//
// Mix (defaults): 450 photos; 12 MP 4032x3024 or 3024x4032 (portrait when the mock photo is);
// every 45th photo is 48 MP 8064x6048; every 10th 12 MP photo, and 2 of the 48 MP ones, are HEIC
// (written with ImageIO's HEIC encoder, EXIF kept); the rest are JPEG.
//
// Build:  swiftc -O -o genlibrary genlibrary.swift
// Usage:  genlibrary <mock-assets-dir> <out-dir> [count=450] [first=0] [workers=3] [quality=0.85] [grain=0.02] [texture=0.04] [grain-softness=0.7]
//         (env LIMIT=n renders only the first n; ONLY=3,22 renders only those indices)
// Then:   xcrun simctl addmedia <SIM> <out-dir>/IMG_6*  (in batches; see prepare-library.sh)
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: genlibrary <mock-assets-dir> <out-dir> [count] [first] [workers] [quality] [grain]")
    exit(2)
}
let mockDir = args[1]
let outDir = args[2]
let count = args.count > 3 ? Int(args[3])! : 450
let first = args.count > 4 ? Int(args[4])! : 0
let workers = args.count > 5 ? Int(args[5])! : 3
let quality = args.count > 6 ? Double(args[6])! : 0.85
let grain = args.count > 7 ? Double(args[7])! : 0.02
let texture = args.count > 8 ? Double(args[8])! : 0.04
let grainSoftness = args.count > 9 ? Double(args[9])! : 0.7
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// SplitMix64: deterministic per photo, so a photo can be regenerated alone.
struct RNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

// MARK: Sources

let sources: [(name: String, image: CIImage)] = (1...16).map { n in
    let name = String(format: "MockPhoto%02d", n)
    let url = URL(fileURLWithPath: "\(mockDir)/\(name).imageset/\(name).jpg")
    guard let image = CIImage(contentsOf: url) else { fatalError("can't read \(url.path)") }
    return (name, image)
}
let landscapeSources = sources.indices.filter { sources[$0].image.extent.width > sources[$0].image.extent.height }

// MARK: Plan

struct Plan {
    let index: Int
    let source: Int
    let width: Int
    let height: Int
    let isHEIC: Bool
    let date: Date
    var filename: String { String(format: "IMG_%04d.%@", 6001 + index, isHEIC ? "HEIC" : "JPG") }
}

/// Capture dates: three days from 9 Oct 2026, 07:30 local time, mostly bursts 15-90 s apart,
/// sometimes a few minutes, now and then a long pause. Distinct to the second.
func captureDates(_ total: Int) -> [Date] {
    var rng = RNG(424_242)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let perDay = Int((Double(total) / 3).rounded(.up))
    var dates: [Date] = []
    for day in 0..<3 {
        var date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9 + day, hour: 7, minute: 30))!
        for _ in 0..<perDay where dates.count < total {
            let roll = rng.unit()
            let gap = roll < 0.7 ? rng.range(15, 90) : roll < 0.95 ? rng.range(120, 480) : rng.range(1200, 3600)
            date = date.addingTimeInterval(gap.rounded())
            dates.append(date)
        }
    }
    return dates
}

let dates = captureDates(count)
let plans: [Plan] = (0..<count).map { i in
    let isBig = i % 45 == 22
    var source = (i * 7 + i / 16) % sources.count
    if isBig && !landscapeSources.contains(source) {
        source = landscapeSources[i % landscapeSources.count]
    }
    let portrait = sources[source].image.extent.height > sources[source].image.extent.width
    let (w, h) = isBig ? (8064, 6048) : portrait ? (3024, 4032) : (4032, 3024)
    let isHEIC = isBig ? (i == 22 || i == 247) : (i % 10 == 3)
    return Plan(index: i, source: source, width: w, height: h, isHEIC: isHEIC, date: dates[i])
}

// MARK: Rendering

let context = CIContext(options: [.cacheIntermediates: false, .name: "genlibrary"])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func filter(_ name: String, _ params: [String: Any]) -> CIImage {
    guard let f = CIFilter(name: name, parameters: params), let out = f.outputImage else { fatalError("filter \(name)") }
    return out
}

/// Uniform noise, one value per channel, offset so every photo gets its own.
func noise(_ rng: inout RNG) -> CIImage {
    filter("CIRandomGenerator", [:]).transformed(by: CGAffineTransform(translationX: CGFloat(rng.range(0, 4000)).rounded(), y: CGFloat(rng.range(0, 4000)).rounded()))
}

/// Grey noise from the red channel: value = 1 + (n - 0.5) * 2 * amount (a multiplier around 1).
func multiplier(_ n: CIImage, amount: Double) -> CIImage {
    let a = CGFloat(2 * amount)
    let r = CIVector(x: a, y: 0, z: 0, w: 0)
    return filter("CIColorMatrix", [
        kCIInputImageKey: n, "inputRVector": r, "inputGVector": r, "inputBVector": r,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 1 - a / 2, y: 1 - a / 2, z: 1 - a / 2, w: 1),
    ])
}

func render(_ plan: Plan) -> CGImage {
    var rng = RNG(UInt64(plan.index) &+ 1)
    let src = sources[plan.source].image
    let target = CGSize(width: plan.width, height: plan.height)

    // Random crop with the target's aspect ratio, 0-25% in.
    let aspect = target.width / target.height
    var cw = src.extent.width, ch = cw / aspect
    if ch > src.extent.height { ch = src.extent.height; cw = ch * aspect }
    let zoom = CGFloat(rng.range(1.0, 1.25))
    cw /= zoom; ch /= zoom
    let cx = CGFloat(rng.range(0, Double(src.extent.width - cw)))
    let cy = CGFloat(rng.range(0, Double(src.extent.height - ch)))
    var image = src.cropped(to: CGRect(x: cx, y: cy, width: cw, height: ch))
        .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
    let scale = target.width / cw
    image = filter("CILanczosScaleTransform", [kCIInputImageKey: image.clampedToExtent(), kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        .cropped(to: CGRect(origin: .zero, size: target))

    // Exposure, white balance, vibrance.
    image = filter("CIExposureAdjust", [kCIInputImageKey: image, kCIInputEVKey: rng.range(-0.35, 0.3)])
    image = filter("CITemperatureAndTint", [
        kCIInputImageKey: image,
        "inputNeutral": CIVector(x: 6500, y: 0),
        "inputTargetNeutral": CIVector(x: CGFloat(rng.range(5600, 7400)), y: CGFloat(rng.range(-12, 12))),
    ])
    image = filter("CIVibrance", [kCIInputImageKey: image, "inputAmount": rng.range(-0.15, 0.35)])

    // Lens: a touch of sharpening and a vignette.
    let s = target.width / 4032
    image = filter("CISharpenLuminance", [kCIInputImageKey: image, kCIInputSharpnessKey: 0.4, kCIInputRadiusKey: 2.0 * s])
    image = filter("CIVignette", [kCIInputImageKey: image, kCIInputIntensityKey: rng.range(0.2, 0.5), kCIInputRadiusKey: 1.6])

    // Texture: coarse and fine luminance modulation (surfaces never are flat in a photo).
    let coarse = filter("CIGaussianBlur", [kCIInputImageKey: noise(&rng).transformed(by: CGAffineTransform(scaleX: 9 * s, y: 9 * s)), kCIInputRadiusKey: 5 * s])
    let fine = filter("CIGaussianBlur", [kCIInputImageKey: noise(&rng).transformed(by: CGAffineTransform(scaleX: 2.2 * s, y: 2.2 * s)), kCIInputRadiusKey: 1.2 * s])
    image = filter("CIMultiplyCompositing", [kCIInputImageKey: multiplier(coarse, amount: texture * 1.2), kCIInputBackgroundImageKey: image])
    image = filter("CIMultiplyCompositing", [kCIInputImageKey: multiplier(fine, amount: texture), kCIInputBackgroundImageKey: image])

    // Sensor grain: per-pixel luminance, plus a little chroma.
    // Demosaicing and noise reduction leave real grain slightly soft, not one-pixel sharp.
    let luma = multiplier(filter("CIGaussianBlur", [kCIInputImageKey: noise(&rng), kCIInputRadiusKey: grainSoftness]), amount: grain)
    image = filter("CIMultiplyCompositing", [kCIInputImageKey: luma, kCIInputBackgroundImageKey: image])
    let chroma = filter("CIColorMatrix", [
        kCIInputImageKey: noise(&rng),
        "inputRVector": CIVector(x: CGFloat(grain * 0.5), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(grain * 0.5), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(grain * 0.5), w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 1 - CGFloat(grain * 0.25), y: 1 - CGFloat(grain * 0.25), z: 1 - CGFloat(grain * 0.25), w: 1),
    ])
    image = filter("CIMultiplyCompositing", [kCIInputImageKey: chroma, kCIInputBackgroundImageKey: image])
        .cropped(to: CGRect(origin: .zero, size: target))

    guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else { fatalError("render \(plan.filename)") }
    return cg
}

func write(_ cg: CGImage, _ plan: Plan) -> Int {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.timeZone = .current
    let date = formatter.string(from: plan.date)
    let offsetFormatter = DateFormatter()
    offsetFormatter.locale = Locale(identifier: "en_US_POSIX")
    offsetFormatter.dateFormat = "xxx"
    offsetFormatter.timeZone = .current
    let offset = offsetFormatter.string(from: plan.date)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(plan.filename)
    let type = plan.isHEIC ? UTType.heic : UTType.jpeg
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { fatalError("dest \(plan.filename)") }
    let big = plan.width * plan.height > 20_000_000
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: plan.isHEIC ? 0.75 : quality,
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: date,
            kCGImagePropertyExifDateTimeDigitized: date,
            kCGImagePropertyExifOffsetTimeOriginal: offset,
            kCGImagePropertyExifOffsetTimeDigitized: offset,
            kCGImagePropertyExifPixelXDimension: plan.width,
            kCGImagePropertyExifPixelYDimension: plan.height,
            kCGImagePropertyExifLensModel: big ? "iPhone 16 Pro back triple camera 6.765mm f/1.78" : "iPhone 15 back dual wide camera 6.86mm f/1.6",
            kCGImagePropertyExifFNumber: big ? 1.78 : 1.6,
            kCGImagePropertyExifISOSpeedRatings: [80],
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: date,
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: big ? "iPhone 16 Pro" : "iPhone 15",
            kCGImagePropertyTIFFSoftware: "Piq perf library",
        ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(plan.filename)") }
    return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

// MARK: Run

let limit = ProcessInfo.processInfo.environment["LIMIT"].flatMap(Int.init) ?? Int.max
let only = ProcessInfo.processInfo.environment["ONLY"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
let todo = Array(plans.filter { $0.index >= first && (only?.contains($0.index) ?? true) }.prefix(limit))
let lock = NSLock()
var done = 0
var bytes = 0
let started = Date()
DispatchQueue.concurrentPerform(iterations: workers) { worker in
    for plan in todo where plan.index % workers == worker {
        autoreleasepool {
            let size = write(render(plan), plan)
            lock.lock()
            done += 1
            bytes += size
            print(String(format: "%@ %dx%d %@ %.2f MB  (%d/%d, %.0fs)", plan.filename, plan.width, plan.height, sources[plan.source].name,
                         Double(size) / 1_000_000, done, todo.count, Date().timeIntervalSince(started)))
            fflush(stdout)
            lock.unlock()
        }
    }
}
print(String(format: "wrote %d photos, %.1f MB, in %.0fs", done, Double(bytes) / 1_000_000, Date().timeIntervalSince(started)))

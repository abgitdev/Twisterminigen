import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import Krea2Pipeline
import Krea2Sampler

enum RemixABSuite: String, CaseIterable, ExpressibleByArgument {
    case all
    case strength
    case crop
}

/// Reproducible real-weight gate for Twister's img2img extension. This deliberately lives in the
/// developer CLI rather than the public app surface: Remix is not an official Krea editing API.
struct RemixAB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remix-ab",
        abstract: "Run same-seed Remix strength and crop A/B pairs with one resident model group.")

    @Option(name: .long) var input: String
    @Option(name: .long) var outDir: String
    @Option(name: .long) var prompt: String
    @Option(name: .long) var width: Int = 512
    @Option(name: .long) var height: Int = 512
    @Option(name: .long) var steps: Int = 8
    @Option(name: .long) var seed: UInt64 = 0
    @Option(name: .long) var lowStrength: Double = 0.35
    @Option(name: .long) var highStrength: Double = 0.75
    @Option(name: .long) var cropStrength: Double = 0.55
    @Option(name: .long, help: "all | strength | crop") var suite: RemixABSuite = .all
    @Flag(name: .long, help: "Write the exact prepared full/crop inputs, then exit before loading models.")
    var prepareOnly = false
    @Option(name: .long) var officialDir: String = Krea2CLIPaths.official
    @Option(name: .long) var ditQuant: String = Krea2CLIPaths.turboMixed
    @Option(name: .long) var vae: String = Krea2CLIPaths.vae

    mutating func validate() throws {
        try Generate.validateCanvas(width: width, height: height)
        try Generate.validateStepCount(steps)
        guard FileManager.default.fileExists(atPath: input) else {
            throw ValidationError("--input must name an existing image.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outDir, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ValidationError("--out-dir must name an existing directory.")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--prompt must not be empty.")
        }
        for (name, value) in [
            ("--low-strength", lowStrength),
            ("--high-strength", highStrength),
            ("--crop-strength", cropStrength),
        ] {
            guard value.isFinite, value > 0, value < 1 else {
                throw ValidationError("\(name) must be finite and in (0, 1).")
            }
        }
        guard lowStrength < highStrength else {
            throw ValidationError("--low-strength must be lower than --high-strength.")
        }
    }

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: input).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: outDir).standardizedFileURL
        let full = try Self.imageInput(
            sourceURL: sourceURL,
            width: width,
            height: height,
            normalizedCrop: nil)
        let leftCrop = try Self.imageInput(
            sourceURL: sourceURL,
            width: width,
            height: height,
            normalizedCrop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let preparedFullURL = outputDirectory.appendingPathComponent("prepared-full.png")
        let preparedLeftURL = outputDirectory.appendingPathComponent("prepared-left-crop.png")
        try Self.writePreparedInput(full, to: preparedFullURL)
        try Self.writePreparedInput(leftCrop, to: preparedLeftURL)
        print("prepared full: \(preparedFullURL.path)")
        print("prepared left crop: \(preparedLeftURL.path)")
        if prepareOnly { return }

        var params = Krea2Sampler.Params()
        params.width = width
        params.height = height
        params.steps = steps
        params.seed = seed

        let allCases: [(name: String, image: Krea2Pipeline.ImageInput, strength: Float)] = [
            ("strength-low", full, Float(lowStrength)),
            ("strength-high", full, Float(highStrength)),
            ("crop-full", full, Float(cropStrength)),
            ("crop-left", leftCrop, Float(cropStrength)),
        ]
        let cases = switch suite {
        case .all: allCases
        case .strength: Array(allCases.prefix(2))
        case .crop: Array(allCases.suffix(2))
        }
        let requests = cases.map { item in
            Krea2Pipeline.PlannedRequest(
                prompt: prompt,
                params: params,
                inputImage: item.image,
                imageStrength: item.strength)
        }
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialDir),
            ditQuantFile: URL(fileURLWithPath: ditQuant),
            vaeFile: URL(fileURLWithPath: vae))

        print("== remix-ab ==")
        print("source: \(sourceURL.path)")
        print("size: \(width)x\(height), steps: \(steps), CFG: 0, seed: \(seed)")
        let started = Date()
        let outputs = try await Krea2Pipeline.generatePlanned(
            requests: requests,
            weights: weights,
            itemStepCallback: { index, step, total in
                print("  \(cases[index].name): step \(step)/\(total)")
            })
        for output in outputs {
            let item = cases[output.requestIndex]
            let destination = outputDirectory
                .appendingPathComponent("\(item.name)-seed-\(seed).png")
            try Generate.writePNG(output.pixels, to: destination)
            print("  \(item.name) strength \(item.strength) -> \(destination.path)")
        }
        print(String(
            format: "completed %d planned outputs in %.1f s",
            outputs.count,
            Date().timeIntervalSince(started)))
    }

    private enum RasterError: Error {
        case decode
        case crop
        case context
    }

    /// Deterministic sRGB preprocessing for the A/B harness, matching Generate's default order:
    /// apply the normalized crop, then centered Fill to the output aspect ratio.
    private static func imageInput(
        sourceURL: URL,
        width: Int,
        height: Int,
        normalizedCrop: CGRect?
    ) throws -> Krea2Pipeline.ImageInput {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw RasterError.decode
        }
        let crop = normalizedCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let pixelCrop = CGRect(
            x: crop.minX * CGFloat(decoded.width),
            y: crop.minY * CGFloat(decoded.height),
            width: crop.width * CGFloat(decoded.width),
            height: crop.height * CGFloat(decoded.height)).integral
        guard pixelCrop.minX >= 0,
              pixelCrop.minY >= 0,
              pixelCrop.maxX <= CGFloat(decoded.width),
              pixelCrop.maxY <= CGFloat(decoded.height),
              pixelCrop.width > 0,
              pixelCrop.height > 0,
              let selected = decoded.cropping(to: pixelCrop) else {
            throw RasterError.crop
        }
        let targetAspect = CGFloat(width) / CGFloat(height)
        let selectedAspect = CGFloat(selected.width) / CGFloat(selected.height)
        let fillRect: CGRect
        if selectedAspect > targetAspect {
            let fillWidth = CGFloat(selected.height) * targetAspect
            fillRect = CGRect(
                x: (CGFloat(selected.width) - fillWidth) / 2,
                y: 0,
                width: fillWidth,
                height: CGFloat(selected.height)).integral
        } else {
            let fillHeight = CGFloat(selected.width) / targetAspect
            fillRect = CGRect(
                x: 0,
                y: (CGFloat(selected.height) - fillHeight) / 2,
                width: CGFloat(selected.width),
                height: fillHeight).integral
        }
        guard let filled = selected.cropping(to: fillRect) else { throw RasterError.crop }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RasterError.context
        }
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(filled, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw RasterError.context }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let planeSize = width * height
        var planar = [Float](repeating: 0, count: planeSize * 3)
        for index in 0 ..< planeSize {
            planar[index] = Float(bytes[index * 4]) / 127.5 - 1
            planar[planeSize + index] = Float(bytes[index * 4 + 1]) / 127.5 - 1
            planar[planeSize * 2 + index] = Float(bytes[index * 4 + 2]) / 127.5 - 1
        }
        return try Krea2Pipeline.ImageInput(width: width, height: height, planarRGB: planar)
    }

    private static func writePreparedInput(
        _ input: Krea2Pipeline.ImageInput,
        to url: URL
    ) throws {
        let planeSize = input.width * input.height
        var rgba = [UInt8](repeating: 255, count: planeSize * 4)
        for index in 0 ..< planeSize {
            for channel in 0 ..< 3 {
                let normalized = (input.planarRGB[channel * planeSize + index] + 1) * 127.5
                rgba[index * 4 + channel] = UInt8(clamping: Int(normalized.rounded()))
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: input.width,
                  height: input.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: input.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.png" as CFString,
                  1,
                  nil) else {
            throw RasterError.context
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.context }
    }
}

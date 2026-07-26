import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Krea2Pipeline
import Krea2Sampler
import MLX
import Testing
import UniformTypeIdentifiers
@testable import Twisterminigen

@Suite(.serialized) struct InputImageStoreTests {
    @Test func importPNGDataPersistsPrivateCanonicalAssetAndExactResolve() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 2,
            height: 1,
            rgba: [255, 0, 0, 255, 0, 0, 255, 255],
            type: .png)
        let store = try InputImageStore(root: fixture.library)

        let asset = try await store.importPNGData(png)
        let managed = fixture.library.appendingPathComponent(asset.managedFilename)
        let managedData = try Data(contentsOf: managed)
        #expect(asset.width == 2)
        #expect(asset.height == 1)
        #expect(asset.byteCount == managedData.count)
        #expect(asset.sha256 == Self.sha256(managedData))
        #expect(await store.snapshot().assets == [asset])
        #expect(try Self.permissions(fixture.library) == 0o700)
        #expect(try Self.permissions(managed) == 0o600)
        #expect(try Self.permissions(fixture.library.appendingPathComponent("catalog.json")) == 0o600)
        #expect(Self.imageType(managedData)?.conforms(to: .png) == true)

        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.55,
            resize: .fit)
        let resolved = try await store.resolve(reference)
        #expect(resolved.asset == asset)
        #expect(resolved.reference == reference)
        #expect(resolved.url == managed)

        var mismatch = reference
        mismatch.sha256 = String(repeating: "0", count: 64)
        await Self.expectStoreError({ _ = try await store.resolve(mismatch) }) {
            if case .assetMismatch(let id) = $0 { return id == asset.id }
            return false
        }
        await Self.expectStoreError({ _ = try await store.importPNGData(png) }) {
            if case .duplicateContent(let id) = $0 { return id == asset.id }
            return false
        }

        let reopened = try InputImageStore(root: fixture.library)
        #expect(await reopened.snapshot().assets == [asset])
        _ = try await reopened.remove(id: asset.id)
        #expect(await reopened.snapshot() == .empty)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test func fileImportAcceptsPNGJPEGAndHEICAndAppliesOrientation() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let store = try InputImageStore(root: fixture.library)

        let pngURL = try fixture.writeImage(
            name: "source.png",
            width: 8,
            height: 6,
            rgba: Self.solidRGBA(width: 8, height: 6, color: (255, 0, 0)),
            type: .png)
        let jpegURL = try fixture.writeImage(
            name: "oriented.jpg",
            width: 6,
            height: 4,
            rgba: Self.solidRGBA(width: 6, height: 4, color: (0, 255, 0)),
            type: .jpeg,
            orientation: 6)
        let heicURL = try fixture.writeImage(
            name: "source.heic",
            width: 32,
            height: 24,
            rgba: Self.solidRGBA(width: 32, height: 24, color: (0, 0, 255)),
            type: .heic)

        let png = try await store.import(sourceURL: pngURL)
        let jpeg = try await store.import(sourceURL: jpegURL)
        let heic = try await store.import(sourceURL: heicURL)
        #expect((png.width, png.height) == (8, 6))
        #expect((jpeg.width, jpeg.height) == (4, 6))
        #expect((heic.width, heic.height) == (32, 24))

        let link = fixture.sources.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pngURL)
        await Self.expectStoreError({ _ = try await store.import(sourceURL: link) }) {
            if case .unsafeSource = $0 { return true }
            return false
        }
        let jpegData = try Data(contentsOf: jpegURL)
        await Self.expectStoreError({ _ = try await store.importPNGData(jpegData) }) {
            if case .unsupportedFormat = $0 { return true }
            return false
        }
    }

    @Test func sourceByteAndDecodedPixelLimitsAreEnforcedBeforePersistence() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 2,
            height: 2,
            rgba: Self.solidRGBA(width: 2, height: 2, color: (64, 128, 192)),
            type: .png)

        let byteLimited = try InputImageStore(
            root: fixture.root.appendingPathComponent("ByteLimited", isDirectory: true),
            limits: InputImageStoreLimits(maximumSourceBytes: Int64(png.count - 1)))
        await Self.expectStoreError({ _ = try await byteLimited.importPNGData(png) }) {
            if case .payloadTooLarge(let maximum) = $0 {
                return maximum == Int64(png.count - 1)
            }
            return false
        }
        #expect(await byteLimited.snapshot() == .empty)

        let pixelLimited = try InputImageStore(
            root: fixture.root.appendingPathComponent("PixelLimited", isDirectory: true),
            limits: InputImageStoreLimits(maximumPixelCount: 3))
        await Self.expectStoreError({ _ = try await pixelLimited.importPNGData(png) }) {
            if case .imageTooLarge(let width, let height, let maximum) = $0 {
                return width == 2 && height == 2 && maximum == 3
            }
            return false
        }
        #expect(await pixelLimited.snapshot() == .empty)
    }

    @Test func futureCatalogIsNonMutatingAndCompatibleStartupQuarantinesOrphans() throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.library,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fixture.library.path)
        let catalog = fixture.library.appendingPathComponent("catalog.json")
        let futureData = Data("{\"schemaVersion\":999,\"sentinel\":\"keep\"}".utf8)
        try futureData.write(to: catalog)
        let orphanName = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png"
        let orphan = fixture.library.appendingPathComponent(orphanName)
        let orphanData = try fixture.imageData(
            width: 1,
            height: 1,
            rgba: [1, 2, 3, 255],
            type: .png)
        try orphanData.write(to: orphan)

        do {
            _ = try InputImageStore(root: fixture.library)
            Issue.record("Expected future catalog rejection")
        } catch let error as InputImageStoreError {
            #expect(error == .unsupportedCatalogVersion(999))
        }
        #expect(try Data(contentsOf: catalog) == futureData)
        #expect(try Data(contentsOf: orphan) == orphanData)
        #expect(try Self.permissions(fixture.library) == 0o755)

        try FileManager.default.removeItem(at: catalog)
        _ = try InputImageStore(root: fixture.library)
        let quarantined = fixture.library
            .appendingPathComponent("Orphans", isDirectory: true)
            .appendingPathComponent(orphanName)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: quarantined) == orphanData)
        #expect(try Self.permissions(fixture.library) == 0o700)
        #expect(try Self.permissions(quarantined.deletingLastPathComponent()) == 0o700)
        #expect(try Self.permissions(quarantined) == 0o600)
    }

    @Test func interruptedRemovalRecoversAndTamperingFailsExactResolve() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 2,
            height: 2,
            rgba: Self.solidRGBA(width: 2, height: 2, color: (255, 255, 255)),
            type: .png)
        let store = try InputImageStore(root: fixture.library)
        let asset = try await store.importPNGData(png)
        let managed = fixture.library.appendingPathComponent(asset.managedFilename)
        let trash = fixture.library.appendingPathComponent(
            ".trash-\(asset.id.uuidString.lowercased()).png")
        try FileManager.default.moveItem(at: managed, to: trash)

        let recovered = try InputImageStore(root: fixture.library)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        #expect(!FileManager.default.fileExists(atPath: trash.path))
        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.5,
            resize: .stretch)
        #expect(try await recovered.resolve(reference).asset == asset)

        let handle = try FileHandle(forWritingTo: managed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await Self.expectStoreError({ _ = try await recovered.resolve(reference) }) {
            if case .tamperedAsset(let id) = $0 { return id == asset.id }
            return false
        }
    }

    @Test func preprocessingProducesExactPlanarFitFillStretchAndCrop() throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let twoPixels = try fixture.imageData(
            width: 2,
            height: 1,
            rgba: [255, 0, 0, 255, 0, 0, 255, 255],
            type: .png)

        let stretch = try InputImagePreprocessor.preprocess(
            pngData: twoPixels,
            targetWidth: 2,
            targetHeight: 2,
            resizeMode: .stretch)
        #expect(stretch.tensorShape == [1, 3, 2, 2])
        #expect(Self.close(stretch[.red, 0, 0], 1))
        #expect(Self.close(stretch[.blue, 1, 0], 1))
        #expect(Self.close(stretch[.red, 0, 1], 1))
        #expect(Self.close(stretch[.blue, 1, 1], 1))

        let fit = try InputImagePreprocessor.preprocess(
            pngData: twoPixels,
            targetWidth: 4,
            targetHeight: 4,
            resizeMode: .fit)
        #expect(fit.width == 4 && fit.height == 4)
        for channel in [InputImagePlanarRGB.Channel.red, .green, .blue] {
            for x in 0 ..< 4 {
                #expect(fit[channel, x, 0] == 0)
                #expect(fit[channel, x, 3] == 0)
            }
        }
        #expect(Self.close(fit[.red, 0, 1], 1))
        #expect(Self.close(fit[.blue, 3, 2], 1))

        let fourPixels = try fixture.imageData(
            width: 4,
            height: 1,
            rgba: [
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                255, 255, 255, 255,
            ],
            type: .png)
        let fill = try InputImagePreprocessor.preprocess(
            pngData: fourPixels,
            targetWidth: 2,
            targetHeight: 1,
            resizeMode: .fill)
        #expect(Self.close(fill[.green, 0, 0], 1))
        #expect(Self.close(fill[.blue, 1, 0], 1))

        let crop = GenerationRecipe.NormalizedRect(x0: 0.25, y0: 0, x1: 0.75, y1: 1)
        let cropped = try InputImagePreprocessor.preprocess(
            pngData: fourPixels,
            targetWidth: 2,
            targetHeight: 1,
            resizeMode: .stretch,
            crop: crop)
        #expect(Self.close(cropped[.green, 0, 0], 1))
        #expect(Self.close(cropped[.blue, 1, 0], 1))
        #expect(cropped.values.allSatisfy { (-1 ... 1).contains($0) })
    }

    @Test func canonicalImportPreservesAsymmetricPixelOrientation() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 2,
            height: 2,
            rgba: [
                255, 0, 0, 255, 0, 255, 0, 255,
                0, 0, 255, 255, 255, 255, 255, 255,
            ],
            type: .png)
        let store = try InputImageStore(root: fixture.library)
        let asset = try await store.importPNGData(png)
        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.5,
            resize: .stretch)
        let prepared = try await store.prepare(
            reference,
            targetWidth: 2,
            targetHeight: 2)

        #expect(Self.close(prepared[.red, 0, 0], 1))
        #expect(Self.close(prepared[.green, 1, 0], 1))
        #expect(Self.close(prepared[.blue, 0, 1], 1))
        #expect(Self.close(prepared[.red, 1, 1], 1))
        #expect(Self.close(prepared[.green, 1, 1], 1))
        #expect(Self.close(prepared[.blue, 1, 1], 1))
    }

    @MainActor
    @Test func schemaV1PreviewIsUprightAndCropAlignedWithoutMutatingManagedAsset() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 4,
            height: 4,
            rgba: Self.quadrantRGBA(width: 4, height: 4),
            type: .png)
        let store = try InputImageStore(root: fixture.library)
        let asset = try await store.importPNGData(png)
        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.5,
            resize: .stretch)
        let managedURL = fixture.library.appendingPathComponent(asset.managedFilename)
        let catalogURL = fixture.library.appendingPathComponent("catalog.json")
        let managedBefore = try Data(contentsOf: managedURL)
        let catalogBefore = try Data(contentsOf: catalogURL)

        // The legacy layout is part of the persisted schema-v1 compatibility contract.
        #expect(try Self.decodedRGB(managedBefore, x: 0, yFromTop: 0) == (0, 0, 255))
        #expect(try Self.decodedRGB(managedBefore, x: 3, yFromTop: 0) == (255, 255, 255))
        #expect(try Self.decodedRGB(managedBefore, x: 0, yFromTop: 3) == (255, 0, 0))
        #expect(try Self.decodedRGB(managedBefore, x: 3, yFromTop: 3) == (0, 255, 0))

        let previewData = try await store.managedPreviewPNGData(reference)
        #expect(try Self.decodedRGB(png, x: 0, yFromTop: 0) == (255, 0, 0))
        #expect(try Self.decodedRGB(previewData, x: 0, yFromTop: 0) == (255, 0, 0))
        #expect(try Self.decodedRGB(previewData, x: 3, yFromTop: 0) == (0, 255, 0))
        #expect(try Self.decodedRGB(previewData, x: 0, yFromTop: 3) == (0, 0, 255))
        #expect(try Self.decodedRGB(previewData, x: 3, yFromTop: 3) == (255, 255, 255))

        let prepared = try await store.prepare(
            reference,
            targetWidth: 4,
            targetHeight: 4)
        #expect(Self.isColor(prepared, x: 0, y: 0, rgb: (1, -1, -1)))
        #expect(Self.isColor(prepared, x: 3, y: 0, rgb: (-1, 1, -1)))
        #expect(Self.isColor(prepared, x: 0, y: 3, rgb: (-1, -1, 1)))
        #expect(Self.isColor(prepared, x: 3, y: 3, rgb: (1, 1, 1)))

        var topCrop = reference
        topCrop.crop = .init(x0: 0, y0: 0, x1: 1, y1: 0.5)
        let preparedTop = try await store.prepare(
            topCrop,
            targetWidth: 2,
            targetHeight: 1)
        #expect(Self.isColor(preparedTop, x: 0, y: 0, rgb: (1, -1, -1)))
        #expect(Self.isColor(preparedTop, x: 1, y: 0, rgb: (-1, 1, -1)))

        var bottomCrop = reference
        bottomCrop.crop = .init(x0: 0, y0: 0.5, x1: 1, y1: 1)
        let preparedBottom = try await store.prepare(
            bottomCrop,
            targetWidth: 2,
            targetHeight: 1)
        #expect(Self.isColor(preparedBottom, x: 0, y: 0, rgb: (-1, -1, 1)))
        #expect(Self.isColor(preparedBottom, x: 1, y: 0, rgb: (1, 1, 1)))

        #expect(try Data(contentsOf: managedURL) == managedBefore)
        #expect(try Data(contentsOf: catalogURL) == catalogBefore)
        #expect(Self.sha256(try Data(contentsOf: managedURL)) == asset.sha256)
        #expect(await store.snapshot().assets == [asset])
    }

    @MainActor
    @Test func galleryRemixKeepsAnIndependentVerifiedManagedSource() async throws {
        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let png = try fixture.imageData(
            width: 256,
            height: 256,
            rgba: Self.quadrantRGBA(width: 256, height: 256),
            type: .png)
        let generationStore = GenerationStore(
            paths: LibraryPaths(root: fixture.root.appendingPathComponent("Gallery")))
        let inputStore = try InputImageStore(root: fixture.library)
        let catalog = ModelCatalog(root: fixture.root.appendingPathComponent("Models"))
        let recipe = GenerationRecipeRuntime.currentTurboRecipe(
            prompt: "source",
            width: 256,
            height: 256,
            steps: 8,
            seed: .fixed(9),
            catalog: catalog)
        let generation = try await generationStore.save(
            pngData: png,
            recipe: recipe,
            duration: 1)
        let viewModel = GenerateViewModel(
            store: generationStore,
            coordinator: InferenceCoordinator(),
            memoryGovernor: MemoryGovernor(snapshot: .init(
                swapUsedBytes: 0,
                pressure: .normal)),
            inputImageStore: inputStore,
            weightsRootProvider: { fixture.root.appendingPathComponent("Models") })

        #expect(await viewModel.beginRemix(from: generation))
        let reference = try #require(viewModel.inputImageReference)
        #expect(reference.sourceGenerationID == generation.id)
        #expect(reference.strength == 0.65)
        #expect(reference.resize == .fill)
        #expect(viewModel.seedText.isEmpty)
        let preview = try #require(viewModel.inputImagePreview)
        #expect(try Self.visibleRGB(preview, x: 16, yFromTop: 16) == (255, 0, 0))
        #expect(try Self.visibleRGB(preview, x: 16, yFromTop: 240) == (0, 0, 255))

        _ = try await generationStore.delete(id: generation.id)
        let prepared = try await inputStore.prepare(
            reference,
            targetWidth: 256,
            targetHeight: 256)
        #expect(prepared.tensorShape == [1, 3, 256, 256])
        #expect(prepared.values.allSatisfy { $0.isFinite && (-1 ... 1).contains($0) })
    }

    @Test func real512RemixPipelineWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TWISTER_RUN_REAL_IMG2IMG"] == "1" else { return }
        guard let sourcePath = environment["TWISTER_IMG2IMG_SOURCE"],
              let officialPath = environment["TWISTER_OFFICIAL_DIR"],
              let transformerPath = environment["TWISTER_DIT_QUANT"],
              let vaePath = environment["TWISTER_VAE_WEIGHTS"] else {
            Issue.record("Real img2img paths are missing from the environment")
            return
        }

        let fixture = try InputImageFixture()
        defer { fixture.remove() }
        let store = try InputImageStore(root: fixture.library)
        let asset = try await store.import(
            sourceURL: URL(fileURLWithPath: sourcePath))
        let reference = GenerationRecipe.InputImageReference(
            managedID: asset.id,
            sha256: asset.sha256,
            strength: 0.55,
            resize: .fill)
        let source = try await store.prepare(
            reference,
            targetWidth: 512,
            targetHeight: 512)
        let input = try Krea2Pipeline.ImageInput(
            width: source.width,
            height: source.height,
            planarRGB: source.values)
        var params = Krea2Sampler.Params()
        params.width = 512
        params.height = 512
        params.steps = 8
        params.seed = 12_345
        let weights = Krea2Pipeline.Weights(
            officialDir: URL(fileURLWithPath: officialPath),
            ditQuantFile: URL(fileURLWithPath: transformerPath),
            vaeFile: URL(fileURLWithPath: vaePath))
        var previews: [Krea2LatentPreviewFrame] = []
        let outputs = try await Krea2Pipeline.generatePlanned(
            requests: [.init(
                prompt: "A polished translucent glass emblem, soft studio light",
                params: params,
                inputImage: input,
                imageStrength: 0.55)],
            weights: weights,
            previewEverySteps: 4,
            itemPreviewCallback: { index, frame in
                #expect(index == 0)
                previews.append(frame)
            })
        let pixels = try #require(outputs.first?.pixels)
        #expect(pixels.shape == [1, 3, 512, 512])
        #expect(previews.first?.step == 1)
        #expect(previews.last?.step == previews.last?.totalSteps)
        #expect(previews.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(previews.allSatisfy { $0.rgb.count == $0.width * $0.height * 3 })
        let materialized = pixels.asType(.float32)
        eval(materialized)
        #expect(materialized.asArray(Float.self).allSatisfy { $0.isFinite && (0 ... 1).contains($0) })
        if let outputPath = environment["TWISTER_IMG2IMG_OUTPUT"] {
            let png = try GenerateViewModel.pngData(from: pixels)
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    private static func expectStoreError(
        _ body: () async throws -> Void,
        matches: (InputImageStoreError) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            try await body()
            Issue.record("Expected InputImageStoreError", sourceLocation: sourceLocation)
        } catch let error as InputImageStoreError {
            #expect(matches(error), "Unexpected error: \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func imageType(_ data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func solidRGBA(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        Array(repeating: [color.0, color.1, color.2, 255], count: width * height).flatMap { $0 }
    }

    private static func quadrantRGBA(width: Int, height: Int) -> [UInt8] {
        (0 ..< height).flatMap { y in
            (0 ..< width).flatMap { x -> [UInt8] in
                switch (x < width / 2, y < height / 2) {
                case (true, true): [255, 0, 0, 255]
                case (false, true): [0, 255, 0, 255]
                case (true, false): [0, 0, 255, 255]
                case (false, false): [255, 255, 255, 255]
                }
            }
        }
    }

    @MainActor
    private static func visibleRGB(
        _ image: NSImage,
        x: Int,
        yFromTop: Int
    ) throws -> (Int, Int, Int) {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil) else {
            throw InputImageStoreError.decodeFailed
        }
        return try decodedRGB(cgImage, x: x, yFromTop: yFromTop)
    }

    private static func decodedRGB(
        _ data: Data,
        x: Int,
        yFromTop: Int
    ) throws -> (Int, Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw InputImageStoreError.decodeFailed
        }
        return try decodedRGB(image, x: x, yFromTop: yFromTop)
    }

    private static func decodedRGB(
        _ image: CGImage,
        x: Int,
        yFromTop: Int
    ) throws -> (Int, Int, Int) {
        guard x >= 0,
              x < image.width,
              yFromTop >= 0,
              yFromTop < image.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw InputImageStoreError.decodeFailed
        }
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else { throw InputImageStoreError.decodeFailed }
        let offset = (yFromTop * image.width + x) * 4
        return (Int(rgba[offset]), Int(rgba[offset + 1]), Int(rgba[offset + 2]))
    }

    private static func isColor(
        _ image: InputImagePlanarRGB,
        x: Int,
        y: Int,
        rgb: (Float, Float, Float)
    ) -> Bool {
        close(image[.red, x, y], rgb.0)
            && close(image[.green, x, y], rgb.1)
            && close(image[.blue, x, y], rgb.2)
    }

    private static func close(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) < 0.01
    }
}

private struct InputImageFixture {
    let root: URL
    let library: URL
    let sources: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Twisterminigen-InputImageStore-\(UUID().uuidString)",
                isDirectory: true)
        library = root.appendingPathComponent("InputImages", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    func writeImage(
        name: String,
        width: Int,
        height: Int,
        rgba: [UInt8],
        type: UTType,
        orientation: Int? = nil
    ) throws -> URL {
        let data = try imageData(
            width: width,
            height: height,
            rgba: rgba,
            type: type,
            orientation: orientation)
        let url = sources.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func imageData(
        width: Int,
        height: Int,
        rgba: [UInt8],
        type: UTType,
        orientation: Int? = nil
    ) throws -> Data {
        guard rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil) else {
            throw FixtureError.destinationCreation(type.identifier)
        }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encoding(type.identifier)
        }
        return output as Data
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private enum FixtureError: Error {
        case imageCreation
        case destinationCreation(String)
        case encoding(String)
    }
}

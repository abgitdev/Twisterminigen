import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Twisterminigen

@Suite("Built-in preset cover curation", .serialized)
struct BuiltinPresetCoverCurationTests {
    @Test("Publishes only a complete exact Gallery set and seals every asset")
    func completeVerifiedPublish() async throws {
        let fixture = try CoverCurationFixture()
        defer { fixture.remove() }
        let catalog = ModelCatalog(root: fixture.root.appendingPathComponent("Models"))
        let cards = BuiltinPresetCatalog.cards(catalog: catalog)
        #expect(cards.count == 243)

        let gallery = GenerationStore(paths: fixture.galleryPaths)
        var selections: [BuiltinPresetCoverCurator.Selection] = []
        for (index, card) in cards.enumerated() {
            let png = try fixture.png(
                width: card.recipe.canvas.width,
                height: card.recipe.canvas.height,
                colorIndex: index)
            let generation = try await gallery.save(
                pngData: png,
                recipe: card.recipe,
                duration: 1)
            selections.append(.init(presetID: card.id, generationID: generation.id))
        }

        let firstGeneration = try #require((await gallery.all()).last)
        let firstSourceBefore = try await gallery.pngDataForExport(for: firstGeneration)

        let incomplete = fixture.root.appendingPathComponent("Incomplete", isDirectory: true)
        do {
            _ = try await BuiltinPresetCoverCurator.publish(
                selections: Array(selections.dropLast()),
                gallery: gallery,
                catalog: catalog,
                destinationDirectory: incomplete)
            Issue.record("A partial cover set was accepted")
        } catch {
            #expect(error is BuiltinPresetCoverCurationError)
        }
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))

        var mismatched = selections
        let firstID = mismatched[0].generationID
        mismatched[0] = .init(
            presetID: mismatched[0].presetID,
            generationID: mismatched[1].generationID)
        mismatched[1] = .init(
            presetID: mismatched[1].presetID,
            generationID: firstID)
        let mismatchOutput = fixture.root.appendingPathComponent("Mismatch", isDirectory: true)
        do {
            _ = try await BuiltinPresetCoverCurator.publish(
                selections: mismatched,
                gallery: gallery,
                catalog: catalog,
                destinationDirectory: mismatchOutput)
            Issue.record("Gallery generations with swapped recipes were accepted")
        } catch {
            #expect(error is BuiltinPresetCoverCurationError)
        }
        #expect(!FileManager.default.fileExists(atPath: mismatchOutput.path))

        let wrongSizePNG = try fixture.png(width: 256, height: 256, colorIndex: 99)
        let wrongSizeGeneration = try await gallery.save(
            pngData: wrongSizePNG,
            recipe: cards[0].recipe,
            duration: 1)
        var wrongSizeSelections = selections
        let firstSelectionIndex = try #require(
            wrongSizeSelections.firstIndex(where: { $0.presetID == cards[0].id }))
        wrongSizeSelections[firstSelectionIndex] = .init(
            presetID: cards[0].id,
            generationID: wrongSizeGeneration.id)
        let wrongSizeOutput = fixture.root.appendingPathComponent(
            "WrongDimensions",
            isDirectory: true)
        do {
            _ = try await BuiltinPresetCoverCurator.publish(
                selections: wrongSizeSelections,
                gallery: gallery,
                catalog: catalog,
                destinationDirectory: wrongSizeOutput)
            Issue.record("A Gallery PNG whose pixels disagree with its exact recipe was accepted")
        } catch {
            #expect(error is BuiltinPresetCoverCurationError)
        }
        #expect(!FileManager.default.fileExists(atPath: wrongSizeOutput.path))

        let output = fixture.root.appendingPathComponent("SealedPresetCovers", isDirectory: true)
        let manifest = try await BuiltinPresetCoverCurator.publish(
            selections: selections,
            gallery: gallery,
            catalog: catalog,
            destinationDirectory: output)
        #expect(manifest.covers.count == 243)
        #expect(Set(manifest.covers.map(\.presetID)) == BuiltinPresetCatalog.stableIDs)
        #expect(Set(manifest.covers.map(\.assetFilename)) == BuiltinPresetCatalog.expectedCoverFilenames)
        let manifestURL = output.appendingPathComponent(
            BuiltinPresetCoverContract.manifestFilename)
        let publicManifestData = try Data(contentsOf: manifestURL)
        let publicManifestObject = try #require(
            JSONSerialization.jsonObject(with: publicManifestData) as? [String: Any])
        #expect(Set(publicManifestObject.keys) == ["schema", "version", "covers"])
        #expect(publicManifestObject["version"] as? Int == 2)
        let publicEntries = try #require(
            publicManifestObject["covers"] as? [[String: Any]])
        let expectedPublicEntryKeys: Set<String> = [
            "presetID",
            "assetFilename",
            "recipeSHA256",
            "fixedSeed",
            "jpegSHA256",
            "pixelWidth",
            "pixelHeight",
            "byteCount",
            "crop",
        ]
        #expect(publicEntries.allSatisfy { Set($0.keys) == expectedPublicEntryKeys })

        // Swift's synthesized `Decodable` normally ignores unknown keys. Prove that the runtime
        // contract fails closed if a stale publisher tries to retain private Gallery provenance.
        var staleObject = publicManifestObject
        var staleEntries = publicEntries
        staleEntries[0]["sourceGenerationID"] = UUID().uuidString
        staleObject["covers"] = staleEntries
        try JSONSerialization.data(
            withJSONObject: staleObject,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        #expect(BuiltinPresetCoverContract.url(for: cards[0], directory: output) == nil)
        do {
            _ = try BuiltinPresetCoverContract.validate(
                directory: output,
                expectedCards: cards)
            Issue.record("A public cover manifest with private Gallery fields was accepted")
        } catch {
            #expect(error is BuiltinPresetCoverCurationError)
        }
        try publicManifestData.write(to: manifestURL, options: .atomic)

        let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let characterSheetEntries = manifest.covers.filter {
            cardsByID[$0.presetID]?.categoryID == BuiltinPresetCatalog.characterSheetCategoryID
        }
        #expect(characterSheetEntries.count == 10)
        #expect(characterSheetEntries.allSatisfy {
            $0.crop == BuiltinPresetCoverContract.fullFrameLetterboxPolicy
        })
        #expect(manifest.covers.filter {
            cardsByID[$0.presetID]?.categoryID != BuiltinPresetCatalog.characterSheetCategoryID
        }.allSatisfy {
            $0.crop == BuiltinPresetCoverContract.cropPolicy
        })

        let validated = try BuiltinPresetCoverContract.validate(
            directory: output,
            expectedCards: cards)
        #expect(validated == manifest)
        for card in cards {
            let url = try #require(BuiltinPresetCoverContract.url(for: card, directory: output))
            let data = try Data(contentsOf: url)
            #expect(data.count <= BuiltinPresetCatalog.maximumCoverBytes)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect((CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier)
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 256)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 256)
        }

        let characterSheetEntry = try #require(characterSheetEntries.first)
        let fullFrameJPEG = try Data(contentsOf: output.appendingPathComponent(
            characterSheetEntry.assetFilename))
        let leftEdge = try fixture.pixel(in: fullFrameJPEG, x: 4, y: 128)
        let rightEdge = try fixture.pixel(in: fullFrameJPEG, x: 251, y: 128)
        let letterbox = try fixture.pixel(in: fullFrameJPEG, x: 128, y: 8)
        #expect(leftEdge.red > 180 && leftEdge.green < 80 && leftEdge.blue < 80)
        #expect(rightEdge.blue > 180 && rightEdge.red < 80 && rightEdge.green < 80)
        #expect(letterbox.red < 32 && letterbox.green < 32 && letterbox.blue < 32)

        let firstSourceAfter = try await gallery.pngDataForExport(for: firstGeneration)
        #expect(firstSourceAfter == firstSourceBefore)
        #expect(FileManager.default.fileExists(atPath: try fixture.galleryPaths.imageURL(
            for: firstGeneration.imageFileName).path))

        let tamperedURL = try #require(BuiltinPresetCoverContract.url(
            for: cards[0],
            directory: output))
        var tampered = try Data(contentsOf: tamperedURL)
        tampered.append(0)
        try tampered.write(to: tamperedURL, options: .atomic)
        #expect(BuiltinPresetCoverContract.url(for: cards[0], directory: output) == nil)
        do {
            _ = try BuiltinPresetCoverContract.validate(directory: output, expectedCards: cards)
            Issue.record("A JPEG with a changed checksum was accepted")
        } catch {
            #expect(error is BuiltinPresetCoverCurationError)
        }

        let stagingLeftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix(".preset-covers-staging-") }
        #expect(stagingLeftovers.isEmpty)
    }

}

private struct CoverCurationFixture {
    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    let root: URL
    let galleryPaths: LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TwisterCoverCurationTests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        galleryPaths = LibraryPaths(
            root: root.appendingPathComponent("Gallery", isDirectory: true),
            thumbnails: root.appendingPathComponent("Thumbnails", isDirectory: true))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func png(width: Int, height: Int, colorIndex: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let red = CGFloat((colorIndex * 41) % 255) / 255
        let green = CGFloat((colorIndex * 83 + 31) % 255) / 255
        let blue = CGFloat((colorIndex * 127 + 67) % 255) / 255
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1))
        context.fill(CGRect(
            x: CGFloat(width) * 0.25,
            y: CGFloat(height) * 0.25,
            width: CGFloat(width) * 0.5,
            height: CGFloat(height) * 0.5))
        let edgeWidth = max(24, width / 16)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: edgeWidth, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width - edgeWidth, y: 0, width: edgeWidth, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BuiltinPresetCoverCurationError.invalidSourcePNG("test fixture")
        }
        return data as Data
    }

    func pixel(in jpeg: Data, x: Int, y: Int) throws -> Pixel {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        guard (0 ..< width).contains(x), (0 ..< height).contains(y) else {
            throw BuiltinPresetCoverCurationError.invalidAsset("test pixel is out of bounds")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                throw BuiltinPresetCoverCurationError.invalidAsset(
                    "could not decode test cover pixel")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let offset = (y * width + x) * 4
            return Pixel(
                red: storage[offset],
                green: storage[offset + 1],
                blue: storage[offset + 2])
        }
    }
}

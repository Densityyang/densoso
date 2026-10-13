import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Densoso

final class PhotoEvidenceSanitizerTests: XCTestCase {
    func testSanitizedJPEGRemovesGPSAndExifMetadata() throws {
        let original = try jpegWithLocationMetadata()
        let sourceProperties = try imageProperties(for: original)
        let sourceExif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(
            sourceExif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            "2026:07:26 16:00:00"
        )
        XCTAssertEqual(sourceExif?[kCGImagePropertyExifMakerNote] as? Data, Data("gate05-maker-note".utf8))
        XCTAssertNotNil(try xmpTagValue(in: original))

        let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(from: original)

        let properties = try imageProperties(for: sanitized)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        // JPEG encoders may emit a new EXIF container for pixel dimensions or
        // color space. Verify that no source EXIF value is retained instead.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif?[kCGImagePropertyExifMakerNote])
        XCTAssertNil(try xmpTagValue(in: sanitized))
    }

    func testUnreadableDataIsRejected() {
        XCTAssertThrowsError(try PhotoEvidenceSanitizer.sanitizedJPEG(from: Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? PhotoEvidenceSanitizer.SanitizationError, .unreadableImage)
        }
    }

    func testLongestEdgeIsBoundedTo1280Pixels() throws {
        let original = try jpeg(width: 2_000, height: 1_000)

        let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(from: original)

        guard let source = CGImageSourceCreateWithData(sanitized as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Expected sanitized JPEG")
        }
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1_280)
        XCTAssertEqual(image.width, 1_280)
        XCTAssertEqual(image.height, 640)
    }

    func testCameraImageOrientationIsAppliedBeforeSanitizing() throws {
        let sourceData = try jpeg(width: 160, height: 80)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("Expected camera fixture pixels")
        }

        for orientation in [UIImage.Orientation.right, .leftMirrored] {
            let cameraImage = UIImage(cgImage: pixels, scale: 1, orientation: orientation)
            let cameraJPEG = try XCTUnwrap(
                CameraImageOrientationNormalizer.uprightJPEG(from: cameraImage)
            )
            let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(from: cameraJPEG)
            let properties = try imageProperties(for: sanitized)

            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? Int), 80)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? Int), 160)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        }
    }

    func testConfiguredJPEGQualitiesProduceDecodableBoundedImages() throws {
        let original = try jpeg(width: 400, height: 200)

        for quality: CGFloat in [0.25, 0.75] {
            let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(
                from: original,
                maximumPixelSize: 1280,
                compressionQuality: quality
            )
            let properties = try imageProperties(for: sanitized)
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 400)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 200)
        }
    }

    private func jpegWithLocationMetadata() throws -> Data {
        try jpeg(width: 1, height: 1, includeLocation: true)
    }

    private func jpeg(width: Int, height: Int, includeLocation: Bool = false) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 1)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 2)
        }
        if includeLocation {
            let exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:26 16:00:00" as CFString,
                kCGImagePropertyExifMakerNote: Data("gate05-maker-note".utf8) as CFData,
            ]
            let properties: [CFString: Any] = [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitudeRef: "N" as CFString,
                    kCGImagePropertyGPSLatitude: NSNumber(value: 31.2304),
                    kCGImagePropertyGPSLongitudeRef: "E" as CFString,
                    kCGImagePropertyGPSLongitude: NSNumber(value: 121.4737),
                ],
                kCGImagePropertyExifDictionary: exif,
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 3)
        }
        let encoded = data as Data
        return includeLocation ? try addingXMPMetadata(to: encoded) : encoded
    }

    private func addingXMPMetadata(to imageData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 8)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 9)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: try fixtureXMPMetadata(),
            kCGImageDestinationMergeMetadata: kCFBooleanTrue as Any,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 10)
        }
        return output as Data
    }

    private func fixtureXMPMetadata() throws -> CGMutableImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        let namespace = "https://densoso.example/meal/1.0/" as CFString
        let prefix = "densoso" as CFString
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil),
              let tag = CGImageMetadataTagCreate(
                namespace,
                prefix,
                "marker" as CFString,
                .string,
                "gate05-xmp-marker" as CFString
              ),
              CGImageMetadataSetTagWithPath(metadata, nil, "densoso:marker" as CFString, tag) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 6)
        }
        return metadata
    }

    private func xmpTagValue(in data: Data) throws -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 7)
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "densoso:marker" as CFString)
        return tag.flatMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    private func imageProperties(for data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 4)
        }
        return properties
    }
}

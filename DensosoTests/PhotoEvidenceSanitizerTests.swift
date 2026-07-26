import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Densoso

final class PhotoEvidenceSanitizerTests: XCTestCase {
    func testSanitizedJPEGRemovesGPSAndExifMetadata() throws {
        let original = try jpegWithLocationMetadata()

        let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(from: original)

        let properties = try imageProperties(for: sanitized)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        // JPEG encoders may emit a new EXIF container for pixel dimensions or
        // color space. Verify that no source EXIF value is retained instead.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
    }

    func testUnreadableDataIsRejected() {
        XCTAssertThrowsError(try PhotoEvidenceSanitizer.sanitizedJPEG(from: Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? PhotoEvidenceSanitizer.SanitizationError, .unreadableImage)
        }
    }

    private func jpegWithLocationMetadata() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 1)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 2)
        }
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLongitude: 121.4737
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:26 16:00:00"
            ]
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 3)
        }
        return data as Data
    }

    private func imageProperties(for data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 4)
        }
        return properties
    }
}

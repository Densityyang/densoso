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
        XCTAssertNotNil(original.range(of: Data("gate05-maker-note".utf8)))
        XCTAssertNotNil(original.range(of: Data("gate05-xmp-marker".utf8)))

        let sanitized = try PhotoEvidenceSanitizer.sanitizedJPEG(from: original)

        let properties = try imageProperties(for: sanitized)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        // JPEG encoders may emit a new EXIF container for pixel dimensions or
        // color space. Verify that no source EXIF value is retained instead.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif?[kCGImagePropertyExifMakerNote])
        XCTAssertNil(sanitized.range(of: Data("gate05-maker-note".utf8)))
        XCTAssertNil(sanitized.range(of: Data("gate05-xmp-marker".utf8)))
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
        let image = try jpeg(width: 1, height: 1)
        var output = Data(image.prefix(2))
        output.append(try app1Segment(payload: exifPayload()))
        output.append(try app1Segment(payload: xmpPayload()))
        output.append(contentsOf: image.dropFirst(2))
        return output
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
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
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 3)
        }
        return data as Data
    }

    private func app1Segment(payload: Data) throws -> Data {
        let segmentLength = payload.count + 2
        guard segmentLength <= Int(UInt16.max) else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 5)
        }
        var segment = Data([0xFF, 0xE1])
        appendUInt16BigEndian(UInt16(segmentLength), to: &segment)
        segment.append(payload)
        return segment
    }

    private func exifPayload() -> Data {
        var tiff = Data([0x49, 0x49])
        appendUInt16LittleEndian(42, to: &tiff)
        appendUInt32LittleEndian(8, to: &tiff)

        // IFD0 at offset 8: EXIF IFD at 38 and GPS IFD at 105.
        appendUInt16LittleEndian(2, to: &tiff)
        appendTIFFEntry(tag: 0x8769, type: 4, count: 1, value: 38, to: &tiff)
        appendTIFFEntry(tag: 0x8825, type: 4, count: 1, value: 105, to: &tiff)
        appendUInt32LittleEndian(0, to: &tiff)

        // EXIF IFD at offset 38: date at 68 and MakerNote at 88.
        appendUInt16LittleEndian(2, to: &tiff)
        appendTIFFEntry(tag: 0x9003, type: 2, count: 20, value: 68, to: &tiff)
        appendTIFFEntry(tag: 0x927C, type: 7, count: 17, value: 88, to: &tiff)
        appendUInt32LittleEndian(0, to: &tiff)
        tiff.append(contentsOf: "2026:07:26 16:00:00\0".utf8)
        tiff.append(contentsOf: "gate05-maker-note".utf8)

        // GPS IFD at offset 105 with valid hemisphere refs and coordinates.
        appendUInt16LittleEndian(5, to: &tiff)
        appendTIFFEntry(tag: 0x0000, type: 1, count: 4, value: 0x00000302, to: &tiff)
        appendTIFFEntry(tag: 0x0001, type: 2, count: 2, value: 0x4E, to: &tiff) // N
        appendTIFFEntry(tag: 0x0002, type: 5, count: 3, value: 171, to: &tiff)
        appendTIFFEntry(tag: 0x0003, type: 2, count: 2, value: 0x45, to: &tiff) // E
        appendTIFFEntry(tag: 0x0004, type: 5, count: 3, value: 195, to: &tiff)
        appendUInt32LittleEndian(0, to: &tiff)
        for component: UInt32 in [31, 13, 49, 121, 28, 24] {
            appendUInt32LittleEndian(component, to: &tiff)
            appendUInt32LittleEndian(1, to: &tiff)
        }

        var payload = Data("Exif\0\0".utf8)
        payload.append(tiff)
        return payload
    }

    private func xmpPayload() -> Data {
        let header = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        let packet = Data(
            #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:densoso="https://densoso.example/meal/1.0/" densoso:marker="gate05-xmp-marker"/></rdf:RDF></x:xmpmeta>"#.utf8
        )
        return header + packet
    }

    private func appendTIFFEntry(
        tag: UInt16,
        type: UInt16,
        count: UInt32,
        value: UInt32,
        to data: inout Data
    ) {
        appendUInt16LittleEndian(tag, to: &data)
        appendUInt16LittleEndian(type, to: &data)
        appendUInt32LittleEndian(count, to: &data)
        appendUInt32LittleEndian(value, to: &data)
    }

    private func appendUInt16LittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    private func appendUInt32LittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8((value >> 24) & 0x000000FF))
    }

    private func appendUInt16BigEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0x00FF))
        data.append(UInt8(value & 0x00FF))
    }

    private func imageProperties(for data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "PhotoEvidenceSanitizerTests", code: 4)
        }
        return properties
    }
}

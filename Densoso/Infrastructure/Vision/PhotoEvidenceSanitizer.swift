import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a captured image in memory without copying source metadata.
/// Callers must keep the returned bytes transient unless the user separately
/// enables photo retention; this type never writes a file or contacts a model.
enum PhotoEvidenceSanitizer {
    enum SanitizationError: Error, Equatable {
        case unreadableImage
        case unableToEncode
    }

    static func sanitizedJPEG(
        from imageData: Data,
        maximumPixelSize: Int = 1_280,
        compressionQuality: CGFloat = 0.75
    ) throws -> Data {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw SanitizationError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw SanitizationError.unableToEncode
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: min(max(compressionQuality, 0), 1),
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw SanitizationError.unableToEncode
        }
        return output as Data
    }
}

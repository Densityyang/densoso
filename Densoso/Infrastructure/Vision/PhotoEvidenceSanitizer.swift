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

    static func sanitizedJPEG(from imageData: Data, compressionQuality: CGFloat = 0.9) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw SanitizationError.unableToEncode
        }
        return output as Data
    }
}

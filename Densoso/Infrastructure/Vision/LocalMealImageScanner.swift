import CoreGraphics
import DensosoDomain
import Foundation
import ImageIO

protocol MealImageScanning: Sendable {
    func scan(imageJPEG: Data) async throws -> [MealEvidence]
}

protocol MealPhotoSanitizing: Sendable {
    func sanitize(originalData: Data) async throws -> Data
}

actor ImageIOMealPhotoSanitizer: MealPhotoSanitizing {
    func sanitize(originalData: Data) async throws -> Data {
        try PhotoEvidenceSanitizer.sanitizedJPEG(from: originalData)
    }
}

actor LocalMealImageScanner: MealImageScanning {
    func scan(imageJPEG: Data) async throws -> [MealEvidence] {
        guard let source = CGImageSourceCreateWithData(imageJPEG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotoEvidenceSanitizer.SanitizationError.unreadableImage
        }
        return try BarcodeAndLabelScanner.scan(cgImage: image, orientation: .up)
    }
}

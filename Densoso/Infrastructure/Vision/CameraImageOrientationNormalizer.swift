import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Converts UIImagePickerController's display orientation into upright JPEG
/// pixels before the image enters the shared ImageIO sanitizer.
enum CameraImageOrientationNormalizer {
    static func uprightJPEG(from image: UIImage) -> Data? {
        guard let sourceImage = image.cgImage,
              let orientation = exifOrientation(for: image.imageOrientation) else {
            return nil
        }

        let uprightImage: CGImage
        if orientation == .up {
            uprightImage = sourceImage
        } else {
            let transformed = CIImage(cgImage: sourceImage)
                .oriented(forExifOrientation: Int32(orientation.rawValue))
            guard let result = CIContext().createCGImage(transformed, from: transformed.extent.integral) else {
                return nil
            }
            uprightImage = result
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, uprightImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func exifOrientation(
        for orientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation? {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        case .left: .left
        @unknown default: nil
        }
    }
}

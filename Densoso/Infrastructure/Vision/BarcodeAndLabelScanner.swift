import CoreGraphics
import DensosoDomain
import ImageIO
import Vision

/// Local Vision adapter for static meal images. It emits sanitized evidence
/// only; no image bytes, OCR text, or barcode value can invoke a tool by
/// itself, and the coordinator still requires user confirmation.
enum BarcodeAndLabelScanner {
    struct BarcodeCandidate: Equatable {
        let payload: String
        let confidence: Float
        var isUPCE: Bool = false
    }

    struct TextCandidate: Equatable {
        let value: String
        let confidence: Float
    }

    static func scan(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [MealEvidence] {
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.ean8, .ean13, .upce, .code128]

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        textRequest.usesLanguageCorrection = true

        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([barcodeRequest, textRequest])
        let barcodes = (barcodeRequest.results ?? []).compactMap { observation -> BarcodeCandidate? in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeCandidate(
                payload: payload,
                confidence: observation.confidence,
                isUPCE: observation.symbology == .upce
            )
        }
        let texts = (textRequest.results ?? []).compactMap { observation -> TextCandidate? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextCandidate(value: candidate.string, confidence: candidate.confidence)
        }
        return evidence(barcodes: barcodes, text: texts)
    }

    static func evidence(barcodes: [BarcodeCandidate], text: [TextCandidate]) -> [MealEvidence] {
        let barcodeEvidence = barcodes.compactMap { candidate -> MealEvidence? in
            let digits = String(decoding: candidate.payload.utf8.filter { (48...57).contains($0) }, as: UTF8.self)
            let normalized = candidate.isUPCE ? expandUPCE(digits) : digits
            guard let normalized else { return nil }
            guard isValidGTIN(normalized) else { return nil }
            return MealEvidence(
                kind: .barcode,
                value: normalized,
                confidence: Double(candidate.confidence),
                sourceVersion: "local-vision-v1"
            )
        }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.value < $1.value
        }

        let textLines = text
            .map(\.value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !textLines.isEmpty else { return barcodeEvidence }
        let averageConfidence = text.map { Double($0.confidence) }.reduce(0, +) / Double(text.count)
        return barcodeEvidence + [MealEvidence(
            kind: .nutritionLabel,
            value: textLines.joined(separator: "\n"),
            confidence: averageConfidence,
            sourceVersion: "local-vision-v1"
        )]
    }

    private static func isValidGTIN(_ value: String) -> Bool {
        guard [8, 12, 13, 14].contains(value.count),
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let checkDigit = value.utf8.last.map({ Int($0 - 48) }) else { return false }
        let payload = value.utf8.dropLast().reversed().map { Int($0 - 48) }
        guard payload.count == value.count - 1 else { return false }
        let sum = payload.enumerated().reduce(0) { partial, pair in
            partial + pair.element * (pair.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == checkDigit
    }

    private static func expandUPCE(_ value: String) -> String? {
        let digits = Array(value.utf8)
        guard digits.count == 8,
              digits.allSatisfy({ (48...57).contains($0) }),
              digits[0] == 48 || digits[0] == 49 else { return nil }
        let zero = UInt8(48)
        let expanded: [UInt8]
        switch digits[6] {
        case 48...50:
            expanded = [digits[0], digits[1], digits[2], digits[6], zero, zero, zero, zero,
                        digits[3], digits[4], digits[5], digits[7]]
        case 51:
            expanded = [digits[0], digits[1], digits[2], digits[3], zero, zero, zero, zero, zero,
                        digits[4], digits[5], digits[7]]
        case 52:
            expanded = [digits[0], digits[1], digits[2], digits[3], digits[4], zero, zero, zero, zero, zero,
                        digits[5], digits[7]]
        case 53...57:
            expanded = [digits[0], digits[1], digits[2], digits[3], digits[4], digits[5], zero, zero, zero, zero,
                        digits[6], digits[7]]
        default:
            return nil
        }
        return String(decoding: expanded, as: UTF8.self)
    }
}

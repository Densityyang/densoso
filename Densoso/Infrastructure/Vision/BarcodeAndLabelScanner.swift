import CoreGraphics
import DensosoWorkoutDomain
import Vision

/// Local Vision adapter for static meal images. It emits sanitized evidence
/// only; no image bytes, OCR text, or barcode value can invoke a tool by
/// itself, and the coordinator still requires user confirmation.
enum BarcodeAndLabelScanner {
    struct BarcodeCandidate: Equatable {
        let payload: String
        let confidence: Float
    }

    struct TextCandidate: Equatable {
        let value: String
        let confidence: Float
    }

    static func scan(cgImage: CGImage) throws -> [MealEvidence] {
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.ean8, .ean13, .upce, .code128]

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        textRequest.usesLanguageCorrection = true

        try VNImageRequestHandler(cgImage: cgImage).perform([barcodeRequest, textRequest])
        let barcodes = (barcodeRequest.results ?? []).compactMap { observation -> BarcodeCandidate? in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeCandidate(payload: payload, confidence: observation.confidence)
        }
        let texts = (textRequest.results ?? []).compactMap { observation -> TextCandidate? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextCandidate(value: candidate.string, confidence: candidate.confidence)
        }
        return evidence(barcodes: barcodes, text: texts)
    }

    static func evidence(barcodes: [BarcodeCandidate], text: [TextCandidate]) -> [MealEvidence] {
        let barcodeEvidence = barcodes.compactMap { candidate -> MealEvidence? in
            let normalized = candidate.payload.filter(\.isNumber)
            guard (8...14).contains(normalized.count) else { return nil }
            return MealEvidence(kind: .barcode, value: normalized, confidence: Double(candidate.confidence))
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
            confidence: averageConfidence
        )]
    }
}

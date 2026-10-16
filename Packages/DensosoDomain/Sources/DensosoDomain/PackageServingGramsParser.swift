import Foundation

/// Extracts a package serving mass from user text or locally scanned label
/// evidence. Model-provided grams-per-serving values are not accepted here.
public struct PackageServingGramsParser: Sendable {
    public init() {}

    public func gramsPerServing(in sourceText: String) -> Double? {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        guard lower.range(
            of: #"(?:每\s*100\s*(?:g|克)|per\s*100\s*g)"#,
            options: .regularExpression
        ) == nil else {
            return nil
        }

        let patterns = [
            #"(?:每份|每一份|每份净含量|每包|每一包|一包净含量|serving(?: size)?|package(?: size)?)\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:g|克)"#,
            #"([0-9]+(?:\.[0-9]+)?)\s*(?:g|克)\s*(?:每份|每一份|每包|每一包)"#,
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var parsed: [(value: Double, numberRange: NSRange)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in regex.matches(in: text, range: range) {
                guard let fullMatchRange = Range(match.range, in: text),
                      !hasAlternativeServingSize(around: fullMatchRange, in: text),
                      let valueRange = Range(match.range(at: 1), in: text),
                      let value = Double(text[valueRange]),
                      value.isFinite,
                      (0.1...5_000).contains(value) else { continue }
                let numberRange = match.range(at: 1)
                if !parsed.contains(where: { $0.numberRange == numberRange }) {
                    parsed.append((value, numberRange))
                }
            }
        }
        guard parsed.count == 1 else { return nil }
        return parsed[0].value
    }

    private func hasAlternativeServingSize(around match: Range<String.Index>, in text: String) -> Bool {
        let separators = "，,。.;；\n"
        let prefix = text[..<match.lowerBound]
            .split(whereSeparator: { separators.contains($0) })
            .last.map(String.init) ?? ""
        let suffix = String(text[match.upperBound...].prefix { !separators.contains($0) })
        let alternatives = [
            #"(?:[0-9]+(?:\.[0-9]+)?\s*(?:g|克)\s*(?:或|或者|or|to|[-–—])\s*)+$"#,
            #"^(?:(?:或|或者|or|to|[-–—])\s*[0-9]+(?:\.[0-9]+)?\s*(?:g|克))+"#,
        ]
        for pattern in alternatives {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            if regex.firstMatch(
                in: prefix,
                range: NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
            ) != nil || regex.firstMatch(
                in: suffix,
                range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
            ) != nil {
                return true
            }
        }
        return false
    }
}

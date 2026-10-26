import Foundation

/// Finds an unhedged gram amount attached directly to an ingredient name in
/// the current user text. Model output and image/OCR text are never inputs.
public struct ExplicitUserGramsParser: Sendable {
    public init() {}

    public func exactGrams(in userText: String, matching ingredientTerms: [String]) -> Double? {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let terms = Set(ingredientTerms.compactMap(Self.normalizedTerm)).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
        guard !terms.isEmpty else { return nil }

        let number = "([0-9]+(?:\\.[0-9]+)?)"
        let units = "(?:grams?|g|公克|克)"
        let householdCount = "(?:[0-9]+(?:\\.[0-9]+)?|one|a|an|一|两|二|三|半)"
        let householdUnit = "(?:(?:small\\s*|large\\s*)?bowls?|fists?|palms?|cups?|slices?|eggs?|dumplings?|bananas?|apples?|小碗|大碗|碗|拳头|拳|掌心|掌|杯|片|鸡蛋|蛋|饺子|香蕉|苹果)"
        let householdQuantity = "\(householdCount)\\s*(?:个|枚|根|只)?\\s*\(householdUnit)(?:半)?"
        let connectorsAfterTerm = "(?:(?:\\s|[:：=，,]|的|重|重量|是|为|称重|准确)|\(householdQuantity)){0,8}"
        let connectorsBeforeTerm = "(?:\\s|的|净重|为|是){0,6}"
        var parsedValues: [(value: Double, numberRange: NSRange)] = []

        for term in terms {
            let termPattern = Self.regexTerm(term)
            let patterns = [
                "\(termPattern)\(connectorsAfterTerm)\(number)\\s*\(units)",
                "\(number)\\s*\(units)\(connectorsBeforeTerm)\(termPattern)",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else { continue }
                let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in regex.matches(in: text, range: fullRange) {
                    guard let fullMatchRange = Range(match.range, in: text),
                          !Self.hasUncertainContext(around: fullMatchRange, in: text),
                          !Self.hasAlternativeGramAmount(around: fullMatchRange, in: text),
                          let valueRange = Range(match.range(at: 1), in: text),
                          let value = Double(text[valueRange]),
                          value.isFinite,
                          (0.1...5_000).contains(value) else {
                        continue
                    }
                    let numberRange = match.range(at: 1)
                    if !parsedValues.contains(where: { $0.numberRange == numberRange }) {
                        parsedValues.append((value, numberRange))
                    }
                }
            }
        }

        guard parsedValues.count == 1 else { return nil }
        return parsedValues[0].value
    }

    private static func normalizedTerm(_ value: String) -> String? {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 120 else { return nil }
        return term
    }

    private static func regexTerm(_ term: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let isASCIIWord = term.unicodeScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
                || ($0.value >= 0x30 && $0.value <= 0x39)
                || $0 == "_"
        }
        return isASCIIWord ? "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])" : escaped
    }

    private static func hasUncertainContext(around match: Range<String.Index>, in text: String) -> Bool {
        let prefix = text[..<match.lowerBound]
        let prefixClause = prefix.split(whereSeparator: { "，,。.;；\n".contains($0) }).last ?? ""
        let prefixContext = String(prefixClause.suffix(16))
        let suffix = text[match.upperBound...]
        let suffixClause = String(suffix.prefix { !"，,。.;；\n".contains($0) }.prefix(16))
        let context = "\(prefixContext)\(text[match])\(suffixClause)".lowercased()
        let uncertainTerms = [
            "大约", "大概", "大致", "估计", "差不多", "左右", "约", "maybe", "about", "around",
            "roughly", "approx", "approximately", "不是", "没有", "没称", "未称", "没量", "不确定",
            "不要按", "别按", "别写", "不要记", "没说", "未提供", "not", "isn't", "wasn't",
        ]
        return uncertainTerms.contains(where: context.contains)
    }

    private static func hasAlternativeGramAmount(around match: Range<String.Index>, in text: String) -> Bool {
        let separators = "，,。.;；\n"
        let prefixClause = text[..<match.lowerBound]
            .split(whereSeparator: { separators.contains($0) })
            .last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let suffixClause = String(text[match.upperBound...].prefix { !separators.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let units = "(?:grams?|g|公克|克)"
        let joiners = "(?:或|或者|还是|到|\\bor\\b|\\bto\\b|/|\\\\|[-–—])"
        let alternatives = [
            "(?:[0-9]+(?:\\.[0-9]+)?\\s*\(units)\\s*\(joiners)\\s*)+$",
            "(?:[0-9]+(?:\\.[0-9]+)?\\s*\(joiners)\\s*)+$",
            "^(?:\(joiners)\\s*[0-9]+(?:\\.[0-9]+)?\\s*\(units))+",
        ]
        for pattern in alternatives {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let prefixRange = NSRange(prefixClause.startIndex..<prefixClause.endIndex, in: prefixClause)
            let suffixRange = NSRange(suffixClause.startIndex..<suffixClause.endIndex, in: suffixClause)
            if regex.firstMatch(in: prefixClause, range: prefixRange) != nil
                || regex.firstMatch(in: suffixClause, range: suffixRange) != nil {
                return true
            }
        }
        return false
    }
}

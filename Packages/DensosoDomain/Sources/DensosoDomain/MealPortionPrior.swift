import Foundation

/// A user-supplied relation between a household unit and the amount weighed.
/// It is carried as ordinary meal evidence while the meal is pending and only
/// becomes a stored prior when the confirmation transaction commits.
public struct MealPortionPriorCorrection: Codable, Equatable, Sendable {
    public static let evidenceSourceID = "personal-meal-portion-prior-correction"
    public static let evidenceVersion = "personal-meal-portion-prior-v1"

    public let unit: String
    public let unitCount: Double
    public let totalGrams: Double

    public init?(unit: String, unitCount: Double = 1, totalGrams: Double) {
        guard let normalizedUnit = Self.normalizeSupportedUnit(unit),
              unitCount.isFinite, (0.1...100).contains(unitCount),
              totalGrams.isFinite, (0.1...5_000).contains(totalGrams),
              (0.1...5_000).contains(totalGrams / unitCount) else {
            return nil
        }
        self.unit = normalizedUnit
        self.unitCount = unitCount
        self.totalGrams = totalGrams
    }

    public var gramsPerUnit: Double { totalGrams / unitCount }

    public var evidenceSnapshot: EvidenceSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summary = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return EvidenceSnapshot(
            grade: .userReported,
            sourceID: Self.evidenceSourceID,
            sourceVersion: Self.evidenceVersion,
            summary: summary,
            confidence: 1
        )
    }

    public static func correction(from evidence: EvidenceSnapshot) -> MealPortionPriorCorrection? {
        guard evidence.grade == .userReported,
              evidence.sourceID == evidenceSourceID,
              evidence.sourceVersion == evidenceVersion,
              let data = evidence.summary.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MealPortionPriorCorrection.self, from: data) else {
            return nil
        }
        return MealPortionPriorCorrection(
            unit: decoded.unit,
            unitCount: decoded.unitCount,
            totalGrams: decoded.totalGrams
        )
    }

    /// Reads only explicit unit and gram values from the user's current text.
    /// Model fields, photo observations, and recipe data are deliberately not inputs.
    public static func parse(
        userText: String,
        matching ingredientTerms: [String],
        gramsParser: ExplicitUserGramsParser = .init()
    ) -> MealPortionPriorCorrection? {
        var relations: [MealPortionPriorCorrection] = []
        for clause in clauses(in: userText) {
            guard let grams = gramsParser.exactGrams(in: clause, matching: ingredientTerms),
                  let unitMatch = explicitUnitMatch(in: clause),
                  let correction = MealPortionPriorCorrection(
                    unit: unitMatch.unit,
                    unitCount: unitMatch.count,
                    totalGrams: grams
                  ) else {
                continue
            }
            relations.append(correction)
        }
        return relations.count == 1 ? relations.first : nil
    }

    public static func explicitHouseholdQuantity(in userText: String) -> (unit: String, count: Double)? {
        explicitUnitMatch(in: userText)
    }

    public static func explicitHouseholdQuantity(
        in userText: String,
        matching ingredientTerms: [String]
    ) -> (unit: String, count: Double)? {
        let normalizedTerms = ingredientTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedTerms.isEmpty else { return nil }
        let matches = clauses(in: userText).compactMap { clause -> (String, Double)? in
            guard normalizedTerms.contains(where: { clause.localizedCaseInsensitiveContains($0) }) else {
                return nil
            }
            return explicitUnitMatch(in: clause)
        }
        return matches.count == 1 ? matches.first : nil
    }

    public static func normalizeSupportedUnit(_ unit: String) -> String? {
        let normalized = unit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let aliases: [String: String] = [
            "bowl": "bowl", "bowls": "bowl", "碗": "bowl",
            "smallbowl": "smallbowl", "smallbowls": "smallbowl", "小碗": "smallbowl",
            "largebowl": "largebowl", "largebowls": "largebowl", "大碗": "largebowl",
            "fist": "fist", "fists": "fist", "拳": "fist", "拳头": "fist",
            "palm": "palm", "palms": "palm", "掌": "palm", "掌心": "palm",
            "cup": "cup", "cups": "cup", "杯": "cup",
            "slice": "slice", "slices": "slice", "片": "slice",
            "egg": "egg", "eggs": "egg", "鸡蛋": "egg", "蛋": "egg",
            "个鸡蛋": "egg", "枚鸡蛋": "egg", "个蛋": "egg", "枚蛋": "egg",
            "dumpling": "dumpling", "dumplings": "dumpling", "饺子": "dumpling",
            "个饺子": "dumpling", "只饺子": "dumpling",
            "banana": "banana", "bananas": "banana", "香蕉": "banana",
            "根香蕉": "banana", "个香蕉": "banana",
            "apple": "apple", "apples": "apple", "苹果": "apple", "个苹果": "apple",
        ]
        return aliases[normalized]
    }

    private static func explicitUnitMatch(in text: String) -> (unit: String, count: Double)? {
        let unitAlternatives: [(String, String)] = [
            ("smallbowl", "small\\s*bowls?"), ("largebowl", "large\\s*bowls?"),
            ("bowl", "bowls?"), ("fist", "fists?"), ("palm", "palms?"),
            ("cup", "cups?"), ("slice", "slices?"), ("egg", "eggs?"),
            ("dumpling", "dumplings?"), ("banana", "bananas?"), ("apple", "apples?"),
            ("小碗", "小碗"), ("大碗", "大碗"), ("碗", "碗"),
            ("拳头", "拳头"), ("拳", "拳"), ("掌心", "掌心"), ("掌", "掌"),
            ("杯", "杯"), ("片", "片"), ("鸡蛋", "鸡蛋"), ("蛋", "蛋"),
            ("饺子", "饺子"), ("香蕉", "香蕉"), ("苹果", "苹果"),
        ]
        let alternatives = unitAlternatives.map { $0.1 }.joined(separator: "|")
        let count = "([0-9]+(?:\\.[0-9]+)?|one|a|an|一|两|二|三|半)"
        let pattern = "(?<![A-Za-z0-9一二三四五六七八九十百千两半])\(count)\\s*(?:个|枚|根|只)?\\s*(\(alternatives))(半)?(?![A-Za-z0-9一二三四五六七八九十百千两半多左右上下])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard matches.count == 1,
              let countRange = Range(matches[0].range(at: 1), in: text),
              let unitRange = Range(matches[0].range(at: 2), in: text) else {
            return nil
        }
        let hasTrailingHalf = matches[0].range(at: 3).location != NSNotFound
        let rawCount = text[countRange].lowercased()
        var unitCount: Double
        switch rawCount {
        case "one", "a", "an", "一": unitCount = 1
        case "两", "二": unitCount = 2
        case "三": unitCount = 3
        case "半":
            guard !hasTrailingHalf else { return nil }
            unitCount = 0.5
        default:
            guard let parsed = Double(rawCount) else { return nil }
            unitCount = parsed
        }
        if hasTrailingHalf { unitCount += 0.5 }
        let rawUnit = String(text[unitRange]).lowercased().replacingOccurrences(of: " ", with: "")
        guard let unit = Self.normalizeSupportedUnit(rawUnit) else {
            return nil
        }
        return (unit, unitCount)
    }

    private static func clauses(in text: String) -> [String] {
        text.split(whereSeparator: { "，,。.;；\n".contains($0) })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Persisted evidence that a meal estimate consumed a user-managed personal prior.
/// The snapshot records the selected range so a future estimate remains auditable
/// even if the user later edits or removes the prior.
public struct MealPortionPriorUsage: Codable, Equatable, Sendable {
    public static let evidenceSourceID = "personal-meal-portion-prior-used"

    public let unit: String
    public let count: Double
    public let p10Grams: Double
    public let p50Grams: Double
    public let p90Grams: Double
    public let version: String

    public init?(prior: HouseholdPortionPrior, count: Double) {
        guard let unit = MealPortionPriorCorrection.normalizeSupportedUnit(prior.unit),
              count.isFinite, (0.1...100).contains(count),
              prior.p10Grams.isFinite, prior.p50Grams.isFinite, prior.p90Grams.isFinite,
              prior.p10Grams > 0,
              prior.p10Grams <= prior.p50Grams,
              prior.p50Grams <= prior.p90Grams,
              prior.p90Grams <= 5_000,
              prior.p90Grams * count <= 5_000,
              !prior.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.unit = unit
        self.count = count
        self.p10Grams = prior.p10Grams
        self.p50Grams = prior.p50Grams
        self.p90Grams = prior.p90Grams
        self.version = prior.version
    }

    public var evidenceSnapshot: EvidenceSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summary = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return EvidenceSnapshot(
            grade: .weak,
            sourceID: Self.evidenceSourceID,
            sourceVersion: version,
            summary: summary,
            confidence: 0.4
        )
    }

    public static func usage(from evidence: EvidenceSnapshot) -> MealPortionPriorUsage? {
        guard evidence.grade == .weak,
              evidence.sourceID == evidenceSourceID,
              let data = evidence.summary.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MealPortionPriorUsage.self, from: data),
              let validated = MealPortionPriorUsage(
                prior: HouseholdPortionPrior(
                    unit: decoded.unit,
                    p10Grams: decoded.p10Grams,
                    p50Grams: decoded.p50Grams,
                    p90Grams: decoded.p90Grams,
                    version: decoded.version
                ),
                count: decoded.count
              ),
              decoded == validated,
              evidence.sourceVersion == validated.version else {
            return nil
        }
        return validated
    }
}

import Foundation

public struct FoodResolutionQuery: Codable, Equatable, Sendable {
    public let label: String
    public let preparation: FoodPreparation
    public let categoryHint: String?
    public let sourceQuality: Double
    public let barcodeMatchedFoodID: String?
    public let confirmedHistoryFoodIDs: Set<String>

    public init(
        label: String,
        preparation: FoodPreparation = .unknown,
        categoryHint: String? = nil,
        sourceQuality: Double = 0.5,
        barcodeMatchedFoodID: String? = nil,
        confirmedHistoryFoodIDs: Set<String> = []
    ) {
        self.label = label
        self.preparation = preparation
        self.categoryHint = categoryHint
        self.sourceQuality = min(max(sourceQuality, 0), 1)
        self.barcodeMatchedFoodID = barcodeMatchedFoodID
        self.confirmedHistoryFoodIDs = confirmedHistoryFoodIDs
    }
}

public struct FoodScoreBreakdown: Codable, Equatable, Sendable {
    public let lexicalMatch: Double
    public let preparationCompatibility: Double
    public let categoryCompatibility: Double
    public let sourceQuality: Double
    public let confirmedUserHistory: Double

    public var finalScore: Double {
        0.60 * lexicalMatch
            + 0.15 * preparationCompatibility
            + 0.10 * categoryCompatibility
            + 0.10 * sourceQuality
            + 0.05 * confirmedUserHistory
    }
}

public struct FoodCandidate: Codable, Equatable, Identifiable, Sendable {
    public let entry: FoodCatalogEntry
    public let score: Double
    public let breakdown: FoodScoreBreakdown
    public let resolutionScoreV2: FoodResolutionScore?
    public let evidence: [EvidenceSnapshot]

    public var id: String { entry.id }

    public init(
        entry: FoodCatalogEntry,
        score: Double,
        breakdown: FoodScoreBreakdown,
        evidence: [EvidenceSnapshot],
        resolutionScoreV2: FoodResolutionScore? = nil
    ) {
        self.entry = entry
        self.score = min(max(score, 0), 1)
        self.breakdown = breakdown
        self.resolutionScoreV2 = resolutionScoreV2
        self.evidence = evidence
    }
}

public struct FoodResolution: Codable, Equatable, Sendable {
    public let candidates: [FoodCandidate]
    public let autoPreselect: FoodCandidate?
    public let requiresConfirmation: Bool

    public init(candidates: [FoodCandidate], autoPreselect: FoodCandidate?) {
        self.candidates = Array(candidates.prefix(3))
        self.autoPreselect = autoPreselect
        self.requiresConfirmation = true
    }
}

public protocol FoodResolving: Sendable {
    func resolve(_ query: FoodResolutionQuery) -> FoodResolution
}

public protocol ConfirmedFoodHistoryProviding: Sendable {
    func confirmedFoodIDs(matching label: String) async throws -> Set<String>
}

public struct FoodResolver: FoodResolving, Sendable {
    public static let automaticThreshold = 0.85
    public static let automaticMargin = 0.12

    private let catalog: [FoodCatalogEntry]

    public init(catalog: [FoodCatalogEntry]) {
        self.catalog = catalog
    }

    public func resolve(_ query: FoodResolutionQuery) -> FoodResolution {
        let normalizedLabel = Self.normalize(query.label)
        guard !normalizedLabel.isEmpty else {
            return FoodResolution(candidates: [], autoPreselect: nil)
        }

        var candidates = catalog.map { entry -> FoodCandidate in
            if let barcodeMatchedFoodID = query.barcodeMatchedFoodID,
               barcodeMatchedFoodID == entry.id || barcodeMatchedFoodID == entry.localFoodID {
                let exact = FoodScoreBreakdown(
                    lexicalMatch: 1,
                    preparationCompatibility: 1,
                    categoryCompatibility: 1,
                    sourceQuality: 1,
                    confirmedUserHistory: 1
                )
                return FoodCandidate(
                    entry: entry,
                    score: 1,
                    breakdown: exact,
                    evidence: [
                        EvidenceSnapshot(
                            grade: .label,
                            sourceID: "barcode",
                            sourceVersion: entry.sourceVersion,
                            summary: "本地条码精确命中",
                            confidence: 1
                        )
                    ]
                )
            }

            let lexical = Self.lexicalScore(label: normalizedLabel, entry: entry)
            let preparation = Self.preparationScore(query.preparation, entry.preparation)
            let category = Self.categoryScore(query.categoryHint, entry.category)
            let history = query.confirmedHistoryFoodIDs.contains(entry.localFoodID ?? entry.id) ? 1.0 : 0.0
            let breakdown = FoodScoreBreakdown(
                lexicalMatch: lexical,
                preparationCompatibility: preparation,
                categoryCompatibility: category,
                sourceQuality: query.sourceQuality,
                confirmedUserHistory: history
            )
            return FoodCandidate(
                entry: entry,
                score: breakdown.finalScore,
                breakdown: breakdown,
                evidence: [
                    EvidenceSnapshot(
                        grade: lexical == 1 ? .databaseMatch : .estimated,
                        sourceID: "food-resolver:\(entry.id)",
                        sourceVersion: entry.sourceVersion,
                        summary: "本地候选：\(entry.name)",
                        confidence: breakdown.finalScore
                    )
                ]
            )
        }
        candidates = candidates.filter { candidate in
            guard candidate.breakdown.lexicalMatch > 0 else { return false }
            guard query.preparation != .unknown else { return true }
            return candidate.entry.preparation == query.preparation
        }
        candidates.sort {
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            if abs($0.breakdown.lexicalMatch - $1.breakdown.lexicalMatch) > 0.000_001 {
                return $0.breakdown.lexicalMatch > $1.breakdown.lexicalMatch
            }
            return $0.id < $1.id
        }
        let top = Array(candidates.prefix(3))
        let first = top.first
        let secondScore = top.dropFirst().first?.score ?? 0
        let auto = first.flatMap {
            $0.score >= Self.automaticThreshold && $0.score - secondScore >= Self.automaticMargin
                ? $0
                : nil
        }
        return FoodResolution(candidates: top, autoPreselect: auto)
    }

    public static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh-CN"))
        return folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func lexicalScore(label: String, entry: FoodCatalogEntry) -> Double {
        let terms = [entry.name] + entry.aliases
        let normalizedTerms = terms.map(normalize).filter { !$0.isEmpty }
        if normalizedTerms.contains(label) { return 1 }
        if normalizedTerms.contains(where: { $0.hasPrefix(label) || label.hasPrefix($0) }) { return 0.86 }
        if normalizedTerms.contains(where: { $0.contains(label) || label.contains($0) }) { return 0.78 }
        return normalizedTerms.map { bigramSimilarity(label, $0) }.max() ?? 0
    }

    private static func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func grams(_ value: String) -> Set<String> {
            let chars = Array(value)
            guard chars.count > 1 else { return Set([value]) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let left = grams(lhs)
        let right = grams(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        let similarity = Double(left.intersection(right).count) / Double(union.count)
        return similarity >= 0.34 ? min(similarity, 0.72) : 0
    }

    private static func preparationScore(_ requested: FoodPreparation, _ candidate: FoodPreparation) -> Double {
        if requested == .unknown { return 0.6 }
        if candidate == .unknown { return 0.4 }
        return requested == candidate ? 1 : 0
    }

    private static func categoryScore(_ hint: String?, _ category: String) -> Double {
        guard let hint, !normalize(hint).isEmpty else { return 0.5 }
        return normalize(category).contains(normalize(hint)) || normalize(hint).contains(normalize(category)) ? 1 : 0
    }
}

import Foundation

public struct FoodResolutionV2Query: Equatable, Sendable {
    public let label: String
    public let preparation: FoodPreparation
    public let massBasis: FoodMassBasis?
    public let categoryHint: String?
    public let sourceQuality: Double
    public let barcodeMatchedFoodID: String?
    public let confirmedHistoryFoodIDs: Set<String>
    public let evidence: [MealEvidence]

    public init(
        label: String,
        preparation: FoodPreparation = .unknown,
        massBasis: FoodMassBasis? = nil,
        categoryHint: String? = nil,
        sourceQuality: Double = 0.5,
        barcodeMatchedFoodID: String? = nil,
        confirmedHistoryFoodIDs: Set<String> = [],
        evidence: [MealEvidence] = []
    ) {
        self.label = label
        self.preparation = preparation
        self.massBasis = massBasis
        self.categoryHint = categoryHint
        self.sourceQuality = min(max(sourceQuality, 0), 1)
        self.barcodeMatchedFoodID = barcodeMatchedFoodID
        self.confirmedHistoryFoodIDs = confirmedHistoryFoodIDs
        self.evidence = Array(evidence.prefix(12))
    }
}

/// Explicit V2 score axes keep identity, preparation, mass basis, history and
/// evidence quality independently inspectable.
public struct FoodResolutionScore: Codable, Equatable, Sendable {
    public let lexical: Double
    public let alias: Double
    public let preparation: Double
    public let massBasis: Double
    public let category: Double
    public let history: Double
    public let evidence: Double

    public init(
        lexical: Double,
        alias: Double,
        preparation: Double,
        massBasis: Double,
        category: Double,
        history: Double,
        evidence: Double
    ) {
        self.lexical = Self.bound(lexical)
        self.alias = Self.bound(alias)
        self.preparation = Self.bound(preparation)
        self.massBasis = Self.bound(massBasis)
        self.category = Self.bound(category)
        self.history = Self.bound(history)
        self.evidence = Self.bound(evidence)
    }

    public var finalScore: Double {
        0.55 * lexical
            + 0.10 * alias
            + 0.10 * preparation
            + 0.05 * massBasis
            + 0.05 * category
            + 0.05 * history
            + 0.10 * evidence
    }

    private static func bound(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct FoodResolutionV2Candidate: Codable, Equatable, Identifiable, Sendable {
    public let entry: FoodCatalogEntry
    public let score: FoodResolutionScore
    public let evidence: [EvidenceSnapshot]

    public var id: String { entry.id }

    public init(entry: FoodCatalogEntry, score: FoodResolutionScore, evidence: [EvidenceSnapshot]) {
        self.entry = entry
        self.score = score
        self.evidence = evidence
    }
}

public struct FoodResolutionV2: Codable, Equatable, Sendable {
    public let candidates: [FoodResolutionV2Candidate]
    public let autoPreselectID: String?
    public let requiresConfirmation: Bool

    public init(candidates: [FoodResolutionV2Candidate], autoPreselectID: String?) {
        self.candidates = Array(candidates.prefix(3))
        self.autoPreselectID = autoPreselectID
        self.requiresConfirmation = true
    }

    public var autoPreselect: FoodResolutionV2Candidate? {
        guard let autoPreselectID else { return nil }
        return candidates.first { $0.id == autoPreselectID }
    }

    /// Bridges into MealEstimator's stable input contract while preserving the
    /// V2 ranking and the explicit confirmation boundary.
    public var mealEstimatorResolution: FoodResolution {
        let mapped = candidates.map { candidate in
            FoodCandidate(
                entry: candidate.entry,
                score: candidate.score.finalScore,
                breakdown: FoodScoreBreakdown(
                    lexicalMatch: candidate.score.lexical,
                    preparationCompatibility: candidate.score.preparation,
                    categoryCompatibility: candidate.score.category,
                    sourceQuality: candidate.score.evidence,
                    confirmedUserHistory: candidate.score.history
                ),
                evidence: candidate.evidence,
                resolutionScoreV2: candidate.score
            )
        }
        let selected = autoPreselectID.flatMap { id in mapped.first { $0.id == id } }
        return FoodResolution(candidates: mapped, autoPreselect: selected)
    }
}

public struct FoodResolverV2: Sendable {
    public static let automaticThreshold = 0.85
    public static let automaticMargin = 0.12

    private let catalog: [FoodCatalogEntry]

    public init(catalog: [FoodCatalogEntry]) {
        self.catalog = catalog
    }

    public func resolve(_ query: FoodResolutionV2Query) -> FoodResolutionV2 {
        let normalizedLabel = FoodResolver.normalize(query.label)
        guard !normalizedLabel.isEmpty else {
            return FoodResolutionV2(candidates: [], autoPreselectID: nil)
        }

        let ranked = catalog.compactMap { entry -> FoodResolutionV2Candidate? in
            let barcodeMatch = query.barcodeMatchedFoodID.map {
                $0 == entry.id || $0 == entry.localFoodID
            } ?? false
            let lexical = barcodeMatch
                ? 1
                : lexicalScore(label: normalizedLabel, rawLabel: query.label, entry: entry)
            guard lexical > 0 else { return nil }
            let score = FoodResolutionScore(
                lexical: lexical,
                alias: aliasScore(label: normalizedLabel, rawLabel: query.label, entry: entry),
                preparation: preparationCompatibility(query.preparation, entry.preparation),
                massBasis: massBasisCompatibility(query.massBasis, entry: entry),
                category: categoryCompatibility(query.categoryHint, entry.category),
                history: query.confirmedHistoryFoodIDs.contains(entry.localFoodID ?? entry.id) ? 1 : 0,
                evidence: evidenceScore(query, entry: entry, barcodeMatch: barcodeMatch)
            )
            return FoodResolutionV2Candidate(
                entry: entry,
                score: score,
                evidence: evidenceSnapshots(query, entry: entry, score: score, barcodeMatch: barcodeMatch)
            )
        }
        .sorted {
            if abs($0.score.finalScore - $1.score.finalScore) > 0.000_001 {
                return $0.score.finalScore > $1.score.finalScore
            }
            if abs($0.score.lexical - $1.score.lexical) > 0.000_001 {
                return $0.score.lexical > $1.score.lexical
            }
            return $0.id < $1.id
        }
        let top = Array(ranked.prefix(3))
        guard let best = top.first else {
            return FoodResolutionV2(candidates: [], autoPreselectID: nil)
        }
        let secondScore = top.dropFirst().first?.score.finalScore ?? 0
        let barcodeCandidate = query.barcodeMatchedFoodID.flatMap { barcodeID in
            top.first { $0.entry.id == barcodeID || $0.entry.localFoodID == barcodeID }
        }
        let selectedID: String?
        if let barcodeCandidate {
            selectedID = barcodeCandidate.id
        } else {
            selectedID = best.score.finalScore >= Self.automaticThreshold
                && best.score.finalScore - secondScore >= Self.automaticMargin
                ? best.id
                : nil
        }
        return FoodResolutionV2(candidates: top, autoPreselectID: selectedID)
    }

    private func lexicalScore(label: String, rawLabel: String, entry: FoodCatalogEntry) -> Double {
        let terms = [entry.name] + entry.aliases
        let normalizedTerms = terms.map(FoodResolver.normalize).filter { !$0.isEmpty }
        if normalizedTerms.contains(label) { return 1 }
        // One-character Han labels can be useful broad vision hints, but must
        // remain far below the automatic-match threshold so the user chooses.
        if isSingleHanCharacter(label), normalizedTerms.contains(where: { $0.contains(label) }) {
            return 0.45
        }
        if terms.contains(where: {
            matchesFoodTerm($0, term: rawLabel) || matchesFoodTerm(rawLabel, term: $0)
        }) {
            return 0.86
        }
        guard label.count >= 5 else { return 0 }
        return normalizedTerms.map { bigramSimilarity(label, $0) }.max() ?? 0
    }

    private func isSingleHanCharacter(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x2FA1F).contains(scalar.value)
            || (0x30000...0x3134F).contains(scalar.value)
    }

    private func aliasScore(label: String, rawLabel: String, entry: FoodCatalogEntry) -> Double {
        let name = FoodResolver.normalize(entry.name)
        let aliases = entry.aliases
        if aliases.map(FoodResolver.normalize).contains(label) { return 1 }
        if aliases.contains(where: {
            matchesFoodTerm($0, term: rawLabel) || matchesFoodTerm(rawLabel, term: $0)
        }) {
            return 0.8
        }
        return label == name ? 0.5 : 0
    }

    private func evidenceScore(
        _ query: FoodResolutionV2Query,
        entry: FoodCatalogEntry,
        barcodeMatch: Bool
    ) -> Double {
        if barcodeMatch { return 1 }
        let names = ([entry.name] + entry.aliases).filter { !FoodResolver.normalize($0).isEmpty }
        let evidenceConfidence = query.evidence.compactMap { evidence -> Double? in
            switch evidence.kind {
            case .nutritionLabel, .foodCandidate:
                return names.contains(where: { matchesFoodTerm(evidence.value, term: $0) })
                    ? evidence.confidence
                    : nil
            case .barcode:
                return nil
            case .portionReference, .voiceTranscript, .manualEntry:
                return nil
            }
        }.max() ?? 0
        let catalogQuality = entry.localFoodID == nil ? 0.55 : 0.8
        return max(query.sourceQuality * 0.7, evidenceConfidence, catalogQuality)
    }

    private func evidenceSnapshots(
        _ query: FoodResolutionV2Query,
        entry: FoodCatalogEntry,
        score: FoodResolutionScore,
        barcodeMatch: Bool
    ) -> [EvidenceSnapshot] {
        if barcodeMatch {
            return [EvidenceSnapshot(
                grade: .label,
                sourceID: "barcode",
                sourceVersion: entry.sourceVersion,
                summary: "本地条码精确命中",
                confidence: 1
            )]
        }
        let matchedEvidence = query.evidence.compactMap { evidence -> EvidenceSnapshot? in
            guard evidence.kind == .nutritionLabel || evidence.kind == .foodCandidate else { return nil }
            let names = ([entry.name] + entry.aliases).filter { !FoodResolver.normalize($0).isEmpty }
            guard names.contains(where: { matchesFoodTerm(evidence.value, term: $0) }) else { return nil }
            return EvidenceSnapshot(
                grade: evidence.kind == .nutritionLabel ? .label : .estimated,
                sourceID: "food-evidence-v2:\(evidence.kind.rawValue)",
                sourceVersion: evidence.sourceVersion ?? "food-resolution-v2",
                summary: "本地食物线索与候选相符",
                confidence: evidence.confidence
            )
        }
        if !matchedEvidence.isEmpty { return matchedEvidence }
        return [EvidenceSnapshot(
            grade: score.lexical >= 0.99 ? .databaseMatch : .estimated,
            sourceID: "food-resolver-v2:\(entry.id)",
            sourceVersion: entry.sourceVersion,
            summary: "本地候选：\(entry.name)",
            confidence: score.finalScore
        )]
    }

    private func preparationCompatibility(_ requested: FoodPreparation, _ candidate: FoodPreparation) -> Double {
        if requested == .unknown || candidate == .unknown { return 0.6 }
        return requested == candidate ? 1 : 0
    }

    private func massBasisCompatibility(_ basis: FoodMassBasis?, entry: FoodCatalogEntry) -> Double {
        guard let basis else { return 0.5 }
        switch basis {
        case .asPurchased:
            // The catalog's edible fraction is applied later to quantities
            // reported as purchased weight, so this basis is valid for either
            // whole or fully edible foods.
            return 1
        case .edibleRaw:
            switch entry.preparation {
            case .raw: return 1
            case .cooked: return 0.35
            case .unknown: return 0.6
            }
        case .cooked:
            if entry.isCookedComposite || entry.preparation == .cooked { return 1 }
            return entry.preparation == .raw ? 0.35 : 0.6
        }
    }

    private func categoryCompatibility(_ hint: String?, _ category: String) -> Double {
        guard let hint else { return 0.5 }
        let normalizedHint = FoodResolver.normalize(hint)
        let normalizedCategory = FoodResolver.normalize(category)
        guard !normalizedHint.isEmpty, !normalizedCategory.isEmpty else { return 0.5 }
        return normalizedCategory.contains(normalizedHint) || normalizedHint.contains(normalizedCategory) ? 1 : 0
    }

    private func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func bigrams(_ value: String) -> Set<String> {
            let characters = Array(value)
            guard characters.count > 1 else { return Set([value]) }
            return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        let similarity = Double(left.intersection(right).count) / Double(union.count)
        return similarity >= 0.34 ? min(similarity, 0.72) : 0
    }

    private func matchesFoodTerm(_ text: String, term: String) -> Bool {
        let termScalars = Array(term.unicodeScalars)
        let isASCII = termScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
                || ($0.value >= 0x30 && $0.value <= 0x39)
                || CharacterSet.whitespacesAndNewlines.contains($0)
                || "-_/%".unicodeScalars.contains($0)
        }
        if isASCII {
            let termTokens = asciiTokens(term)
            let textTokens = asciiTokens(text)
            guard !termTokens.isEmpty, termTokens.count <= textTokens.count else { return false }
            return (0...(textTokens.count - termTokens.count)).contains { start in
                Array(textTokens[start..<(start + termTokens.count)]) == termTokens
            }
        }

        let normalizedTerm = FoodResolver.normalize(term)
        let normalizedText = FoodResolver.normalize(text)
        guard !normalizedTerm.isEmpty else { return false }
        if normalizedTerm.count == 1 { return normalizedText == normalizedTerm }
        return normalizedText.contains(normalizedTerm)
    }

    private func asciiTokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in value.lowercased().unicodeScalars {
            let isASCIIAlphaNumeric = (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isASCIIAlphaNumeric {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

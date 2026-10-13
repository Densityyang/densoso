import Foundation

public struct PackagedNutritionObservation: Codable, Equatable, Sendable {
    public enum Basis: Codable, Equatable, Sendable {
        case per100Grams
        case perServing(grams: Double)
    }

    public let productName: String?
    public let basis: Basis
    public let energyKcal: Double
    public let proteinGrams: Double?
    public let fatGrams: Double?
    public let carbohydrateGrams: Double?
    public let sourceText: String

    public init(
        productName: String?,
        basis: Basis,
        energyKcal: Double,
        proteinGrams: Double?,
        fatGrams: Double?,
        carbohydrateGrams: Double?,
        sourceText: String
    ) {
        self.productName = productName
        self.basis = basis
        self.energyKcal = energyKcal
        self.proteinGrams = proteinGrams
        self.fatGrams = fatGrams
        self.carbohydrateGrams = carbohydrateGrams
        self.sourceText = sourceText
    }
}

public struct NutritionLabelParser: Sendable {
    public init() {}

    public func parse(lines: [String]) -> PackagedNutritionObservation? {
        let normalizedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedLines.isEmpty else { return nil }
        let text = normalizedLines.joined(separator: "\n")
        let lower = text.lowercased()

        let serving = firstNumber(
            patterns: [
                #"(?:每份|serving(?: size)?)\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:g|克)"#,
            ],
            text: lower
        )
        let hasPer100Basis = lower.range(of: #"每\s*100\s*(?:g|克)"#, options: .regularExpression) != nil
            || lower.range(of: #"per\s*100\s*g"#, options: .regularExpression) != nil
        guard !(serving != nil && hasPer100Basis) else { return nil }
        let basis: PackagedNutritionObservation.Basis
        if let serving { basis = .perServing(grams: serving) }
        else if hasPer100Basis { basis = .per100Grams }
        else { return nil }

        let kcal = firstNumber(
            patterns: [
                #"(?:能量|热量|energy)\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)\s*kcal"#,
                #"([0-9]+(?:\.[0-9]+)?)\s*kcal"#,
            ],
            text: lower
        )
        let kilojoules = firstNumber(
            patterns: [
                #"(?:能量|energy)\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:kj|千焦)"#,
            ],
            text: lower
        )
        guard let energy = kcal ?? kilojoules.map({ $0 / 4.184 }),
              energy.isFinite,
              energy >= 0 else { return nil }

        return PackagedNutritionObservation(
            productName: productName(from: normalizedLines),
            basis: basis,
            energyKcal: energy,
            proteinGrams: nutrient(named: ["蛋白质", "protein"], in: lower),
            fatGrams: nutrient(named: ["脂肪", "fat"], in: lower),
            carbohydrateGrams: nutrient(named: ["碳水化合物", "carbohydrate", "carbs"], in: lower),
            sourceText: text
        )
    }

    private func nutrient(named names: [String], in text: String) -> Double? {
        let escaped = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return firstNumber(
            patterns: ["(?:\(escaped))\\s*[:：]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(?:g|克)"],
            text: text
        )
    }

    private func productName(from lines: [String]) -> String? {
        lines.first { line in
            let lower = line.lowercased()
            return !lower.contains("营养")
                && !lower.contains("nutrition")
                && !lower.contains("每100")
                && !lower.contains("每份")
                && line.count <= 80
        }
    }

    private func firstNumber(patterns: [String], text: String) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: range),
                  let capture = Range(match.range(at: 1), in: text),
                  let value = Double(text[capture]),
                  value.isFinite else { continue }
            return value
        }
        return nil
    }
}

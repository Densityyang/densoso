import DensosoDomain
import Foundation

enum MealRecordAuditPresentation {
    static func summary(evidenceData: Data?, algorithmVersion: String) -> String {
        let evidence = evidenceData.flatMap {
            try? JSONDecoder().decode([EvidenceSnapshot].self, from: $0)
        } ?? []
        var observedLabels = Set<String>()

        for item in evidence {
            if let sourceID = item.sourceID,
               let label = sourceLabel(for: sourceID) {
                observedLabels.insert(label)
            } else if item.sourceID == nil,
                      let label = gradeLabel(for: item.grade) {
                observedLabels.insert(label)
            }
        }

        let orderedLabels = [
            "餐食照片",
            "本机营养标签",
            "本机条码",
            "本地食物库",
            "商品营养来源",
            "个人份量先验",
            "个人份量校准",
            "用户补充",
            "实测",
            "估算",
            "历史估算",
        ].filter(observedLabels.contains)
        let source = orderedLabels.isEmpty ? "历史记录" : orderedLabels.joined(separator: "、")
        let version = algorithmVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(64)
        let displayVersion = version.isEmpty ? "legacy" : String(version)
        let baseSummary = "来源：\(source) · 算法：\(displayVersion)"
        guard let priorUsage = portionPriorUsageSummary(from: evidence) else {
            return baseSummary
        }
        return "\(priorUsage) · \(baseSummary)"
    }

    static func sourceVersionSummary(evidenceData: Data?) -> String? {
        let versions = decodedEvidence(from: evidenceData)
            .compactMap { evidence in
                evidence.sourceVersion?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(64)) }
        let uniqueVersions = Array(Set(versions)).sorted()
        guard !uniqueVersions.isEmpty else { return nil }

        let displayedVersions = uniqueVersions.prefix(3).joined(separator: "、")
        let remainingCount = uniqueVersions.count - min(uniqueVersions.count, 3)
        let suffix = remainingCount > 0 ? "（共 \(uniqueVersions.count) 项）" : ""
        return "证据版本：\(displayedVersions)\(suffix)"
    }

    static func portionCalibrationSummary(evidenceData: Data?) -> String? {
        let corrections = decodedEvidence(from: evidenceData)
            .compactMap(MealPortionPriorCorrection.correction(from:))
        let descriptions = Array(Set(corrections.map { correction in
            let count = quantityLabel(correction.unitCount)
            let unit = unitLabel(correction.unit)
            let grams = quantityLabel(correction.totalGrams)
            return "\(count)\(unit) = \(grams) g"
        })).sorted()
        guard !descriptions.isEmpty else { return nil }
        return "个人份量校准：" + descriptions.joined(separator: "、")
    }

    private static func decodedEvidence(from evidenceData: Data?) -> [EvidenceSnapshot] {
        evidenceData.flatMap {
            try? JSONDecoder().decode([EvidenceSnapshot].self, from: $0)
        } ?? []
    }

    private static func portionPriorUsageSummary(from evidence: [EvidenceSnapshot]) -> String? {
        let matchingEvidence = evidence.filter {
            $0.sourceID == MealPortionPriorUsage.evidenceSourceID
        }
        guard !matchingEvidence.isEmpty else { return nil }

        let details = matchingEvidence.compactMap { snapshot -> String? in
            guard let usage = MealPortionPriorUsage.usage(from: snapshot) else { return nil }
            return "\(quantityLabel(usage.count))\(unitLabel(usage.unit)) · P10/P50/P90 "
                + "\(quantityLabel(usage.p10Grams))/\(quantityLabel(usage.p50Grams))/"
                + "\(quantityLabel(usage.p90Grams)) g · \(String(usage.version.prefix(64)))"
        }
        guard !details.isEmpty else { return "估算使用个人先验" }
        return "估算使用个人先验：" + Array(Set(details)).sorted().joined(separator: "；")
    }

    private static func sourceLabel(for sourceID: String) -> String? {
        if sourceID == MealPortionPriorUsage.evidenceSourceID {
            return "个人份量先验"
        }
        if sourceID == MealPortionPriorCorrection.evidenceSourceID {
            return "个人份量校准"
        }
        if sourceID.hasPrefix("agent-image:") || sourceID == "portion:photo" {
            return "餐食照片"
        }
        if sourceID == "barcode" || sourceID == "capture:barcode" {
            return "本机条码"
        }
        if sourceID == "capture:nutritionLabel"
            || sourceID == "food-evidence-v2:nutritionLabel" {
            return "本机营养标签"
        }
        if sourceID.hasPrefix("food-resolver:")
            || sourceID.hasPrefix("food-resolver-v2:") {
            return "本地食物库"
        }
        if sourceID == "packaged-food-attribution" {
            return "商品营养来源"
        }
        if sourceID == "capture:voiceTranscript"
            || sourceID == "capture:manualEntry"
            || sourceID == "user-reported-oil"
            || sourceID == "user-corrected-portion"
            || sourceID == "user-selected-candidate"
            || sourceID == "user-clarified-oil" {
            return "用户补充"
        }
        return nil
    }

    private static func quantityLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func unitLabel(_ unit: String) -> String {
        switch unit {
        case "bowl": "碗"
        case "smallbowl": "小碗"
        case "largebowl": "大碗"
        case "fist", "拳", "拳头": "拳头"
        case "palm", "掌", "掌心": "掌心"
        case "cup": "杯"
        case "slice": "片"
        case "egg", "鸡蛋", "蛋": "个鸡蛋"
        case "dumpling", "饺子": "个饺子"
        case "banana", "香蕉": "根香蕉"
        case "apple", "苹果": "个苹果"
        default: unit
        }
    }

    private static func gradeLabel(for grade: EvidenceGrade) -> String? {
        switch grade {
        case .measured:
            "实测"
        case .userReported:
            "用户补充"
        case .legacyPointEstimate:
            "历史估算"
        case .strong, .moderate, .weak, .label, .databaseMatch, .estimated, .unresolved:
            "估算"
        }
    }
}

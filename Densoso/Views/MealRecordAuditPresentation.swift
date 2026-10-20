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
        return "来源：\(source) · 算法：\(displayVersion)"
    }

    private static func sourceLabel(for sourceID: String) -> String? {
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

import DensosoDomain
import Foundation

struct DailyCheckInSelfReportResolver {
    private static let negations = ["并没有", "不是", "没有", "并不", "不太", "不", "没", "未", "not"]
    private static let otherPersonCues = [
        "我朋友", "我的朋友", "我妈妈", "我爸爸", "我孩子", "我同事", "我伴侣",
        "我丈夫", "我妻子", "我老公", "我老婆", "我和朋友", "朋友说", "他说", "她说",
        "myfriend", "mymother", "myfather", "mychild", "mycoworker", "mypartner",
    ]

    func validate(_ checkIn: DailyCheckIn, userText: String, asOf date: Date) throws {
        let text = Self.normalized(userText)
        guard !text.isEmpty else { throw DailyCheckInSelfReportError.emptyReport }
        guard text.count <= 4_000 else { throw DailyCheckInSelfReportError.reportTooLong }
        guard !Self.otherPersonCues.contains(where: text.contains) else {
            throw DailyCheckInSelfReportError.otherPerson
        }

        try requireMatch(
            checkIn.energy.rawValue,
            field: .energy,
            signals: Self.energySignals,
            in: text
        )
        try requireMatch(
            checkIn.stress.rawValue,
            field: .stress,
            signals: Self.stressSignals,
            in: text
        )
        try requireMatch(
            checkIn.subjectiveSleep.rawValue,
            field: .subjectiveSleep,
            signals: Self.sleepSignals,
            in: text
        )
        try validateNote(checkIn.note, in: text)
        try validateDate(checkIn.occurredAt, in: userText, asOf: date)
    }

    private func requireMatch(
        _ proposedValue: String,
        field: DailyCheckInSelfReportField,
        signals: [DailyCheckInSelfReportSignal],
        in text: String
    ) throws {
        var observed = Set<String>()
        for signal in signals where signal.cues.contains(where: { Self.containsUnnegated($0, in: text) }) {
            observed.insert(signal.value)
        }
        guard !observed.isEmpty else { throw DailyCheckInSelfReportError.missing([field]) }
        guard observed.count == 1, let value = observed.first else {
            throw DailyCheckInSelfReportError.conflicting(field)
        }
        guard proposedValue == value else {
            throw DailyCheckInSelfReportError.modelValueNotSupported(field)
        }
    }

    private func validateNote(_ note: String?, in normalizedText: String) throws {
        guard let note else { return }
        let normalizedNote = Self.normalized(note)
        guard normalizedNote.isEmpty || normalizedText.contains(normalizedNote) else {
            throw DailyCheckInSelfReportError.noteNotReported
        }
    }

    private func validateDate(_ occurredAt: Date, in rawText: String, asOf date: Date) throws {
        let text = Self.normalized(rawText)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        var expectedDays: [Date] = []
        if text.contains("前天") || text.contains("daybeforeyesterday"),
           let day = calendar.date(byAdding: .day, value: -2, to: today) {
            expectedDays.append(day)
        }
        if text.contains("昨天") || text.contains("yesterday"),
           let day = calendar.date(byAdding: .day, value: -1, to: today) {
            expectedDays.append(day)
        }
        if text.contains("今天") || text.contains("today") { expectedDays.append(today) }
        if let explicitDate = Self.explicitDay(in: rawText) { expectedDays.append(explicitDate) }
        if expectedDays.isEmpty { expectedDays.append(today) }
        let uniqueDays = Set(expectedDays)
        guard uniqueDays.count == 1,
              let expectedDay = uniqueDays.first,
              calendar.isDate(occurredAt, inSameDayAs: expectedDay) else {
            throw DailyCheckInSelfReportError.dateNotSupported
        }
    }

    private static let energySignals: [DailyCheckInSelfReportSignal] = [
        .init(value: UserReportedEnergy.low.rawValue, cues: [
            "特别累", "非常累", "很累", "好累", "有点累", "感觉累", "累得", "累坏了", "精疲力尽", "筋疲力尽", "疲惫", "疲倦", "疲劳",
            "没精神", "精力低", "精力差", "精力很差", "精力不足", "没有精力", "没力气", "没劲", "tired", "exhausted", "lowenergy",
        ]),
        .init(value: UserReportedEnergy.typical.rawValue, cues: [
            "不累", "不太累", "精力一般", "精力正常", "精力不错", "精神一般", "精神不错", "状态还行", "还可以", "一般",
            "normalenergy", "nottired",
        ]),
        .init(value: UserReportedEnergy.high.rawValue, cues: [
            "精力充沛", "精神很好", "特别有精神", "精力很好", "很有活力", "energized", "highenergy",
        ]),
    ]

    private static let stressSignals: [DailyCheckInSelfReportSignal] = [
        .init(value: UserReportedStress.low.rawValue, cues: [
            "没有压力", "没什么压力", "没压力", "压力不大", "压力偏低", "压力较低", "压力低", "不太有压力", "轻松", "不焦虑",
            "relaxed", "notstressed", "lowpressure", "lowstress", "stressislow",
        ]),
        .init(value: UserReportedStress.typical.rawValue, cues: [
            "压力一般", "压力正常", "压力适中", "压力还行", "normalstress", "normalpressure", "stressisnormal",
        ]),
        .init(value: UserReportedStress.elevated.rawValue, cues: [
            "压力特别大", "压力很大", "压力较大", "压力有点大", "有点压力", "压力偏高", "压力大", "压力高", "压力重", "很焦虑", "焦虑",
            "紧张", "stressed", "anxious", "overwhelmed", "highpressure", "highstress", "stresshigh", "stresselevated",
        ]),
    ]

    private static let sleepSignals: [DailyCheckInSelfReportSignal] = [
        .init(value: SubjectiveSleepQuality.poor.rawValue, cues: [
            "昨晚没睡好", "没睡好", "睡得不好", "睡不好", "睡眠不好", "主观睡眠质量不好", "睡眠质量不好", "睡眠质量很差", "主观睡眠差", "睡眠质量差", "睡得很差",
            "失眠", "睡不着", "醒了几次", "多次醒", "poorsleep", "sleptbadly", "didntsleepwell",
        ]),
        .init(value: SubjectiveSleepQuality.fair.rawValue, cues: [
            "睡得一般", "睡眠一般", "主观睡眠一般", "睡眠质量一般", "睡得还行", "fair sleep",
        ]),
        .init(value: SubjectiveSleepQuality.good.rawValue, cues: [
            "睡得很好", "睡得不错", "睡得好", "睡眠很好", "睡眠质量好", "主观睡眠好", "休息得不错",
            "sleptwell", "goodsleep",
        ]),
    ]

    private static func containsUnnegated(_ cue: String, in text: String) -> Bool {
        let normalizedCue = normalized(cue)
        guard !normalizedCue.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: normalizedCue, range: searchRange) {
            let prefix = String(text[..<range.lowerBound].suffix(8))
            if !negations.contains(where: prefix.hasSuffix) { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }

    private static func explicitDay(in text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: String(text[matchRange])) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }
}

private struct DailyCheckInSelfReportSignal {
    let value: String
    let cues: [String]
}

enum DailyCheckInSelfReportField: Equatable {
    case energy
    case stress
    case subjectiveSleep

    var displayName: String {
        switch self {
        case .energy: "精力"
        case .stress: "压力"
        case .subjectiveSleep: "主观睡眠质量"
        }
    }
}

enum DailyCheckInSelfReportError: LocalizedError, Equatable {
    case emptyReport
    case reportTooLong
    case otherPerson
    case missing([DailyCheckInSelfReportField])
    case conflicting(DailyCheckInSelfReportField)
    case modelValueNotSupported(DailyCheckInSelfReportField)
    case noteNotReported
    case dateNotSupported

    var errorDescription: String? {
        switch self {
        case .emptyReport:
            return "没有可核对的用户自述；请先询问用户，不要依据健康数据补全每日状态。"
        case .reportTooLong:
            return "本轮自述过长，无法安全核对每日状态字段；请用户简要描述后再试。"
        case .otherPerson:
            return "当前文字描述的是其他人，不能作为用户本人的每日状态记录。"
        case .missing(let fields):
            let names = fields.map(\.displayName).joined(separator: "、")
            return "用户原话没有明确说明\(names)；请只询问缺少的主观感受，收到回答后再准备草稿。"
        case .conflicting(let field):
            return "用户原话对\(field.displayName)的描述有冲突；请先请用户澄清，再准备草稿。"
        case .modelValueNotSupported(let field):
            return "模型填写的\(field.displayName)等级与用户原话不一致；请只询问该主观感受并等待回答，不得推断或生成草稿。"
        case .noteNotReported:
            return "每日状态备注必须来自用户原话，不能由模型补写。"
        case .dateNotSupported:
            return "自述日期无法由用户原话支持；请按当前日期记录或先询问用户。"
        }
    }
}

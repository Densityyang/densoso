import Foundation

/// A versioned, privacy-safe set of utterances for evaluating speech-to-text
/// and typed draft extraction on a physical device.
///
/// This set contains reference text and expected slots only. It never contains
/// microphone audio, user health records, or model output.
struct SpeechGoldenCase: Sendable, Equatable, Identifiable {
    enum Domain: String, Sendable, Equatable {
        case meal
        case workout
    }

    let id: String
    let domain: Domain
    let referenceTranscript: String
    let expectedSlots: [String: String]
}

struct SpeechGoldenSet: Sendable {
    static let version = "zh-CN-v1"

    let cases: [SpeechGoldenCase]

    static let zhCNV1 = SpeechGoldenSet(cases: mealCases + workoutCases)

    private static let mealItems: [(food: String, amount: String, brand: String?)] = [
        ("米饭", "二百克", nil),
        ("宫保鸡丁", "一份", nil),
        ("番茄鸡蛋面", "一大碗", nil),
        ("拿铁", "三百毫升", "瑞幸"),
        ("酸奶", "两百五十毫升", "安慕希"),
        ("鸡胸肉", "一百五十克", nil),
        ("红烧牛肉面", "一桶", "康师傅"),
        ("全麦面包", "两片", nil),
        ("香蕉", "一根", nil),
        ("牛肉粉", "一碗", nil),
        ("豆浆", "四百毫升", nil),
        ("沙拉", "半份", nil),
        ("蛋白粉", "三十克", "ON"),
        ("火锅", "一人份", nil),
        ("苹果", "两个", nil)
    ]

    private static let mealPatterns = [
        "早餐吃了%@%@",
        "午饭吃了%@%@",
        "晚餐我要记%@%@",
        "帮我记录%@%@",
        "今天加餐%@%@",
        "刚刚吃完%@%@",
        "把%@%@做成餐食草稿",
        "我想补记%@%@",
        "这一餐是%@%@",
        "请先识别%@%@但不要保存"
    ]

    private static let workoutItems: [(exercise: String, sets: String, reps: String, weight: String)] = [
        ("深蹲", "三组", "每组十二次", "四十公斤"),
        ("硬拉", "五组", "每组五次", "六十公斤"),
        ("卧推", "四组", "每组八次", "五十公斤"),
        ("引体向上", "三组", "每组六次", "自重"),
        ("哑铃划船", "四组", "每组十次", "二十公斤"),
        ("箭步蹲", "三组", "每组十二次", "十公斤"),
        ("肩推", "四组", "每组八次", "十五公斤"),
        ("卷腹", "三组", "每组二十次", "自重"),
        ("平板支撑", "三组", "每组四十五秒", "自重"),
        ("跑步", "一组", "三十分钟", "五公里"),
        ("骑行", "一组", "四十分钟", "十二公里"),
        ("游泳", "一组", "二十分钟", "八百米"),
        ("高位下拉", "四组", "每组十次", "三十公斤"),
        ("腿举", "四组", "每组十二次", "一百公斤"),
        ("壶铃摆动", "五组", "每组十五次", "十六公斤")
    ]

    private static let workoutPatterns = [
        "记录%@%@%@%@",
        "我要做%@%@%@%@",
        "今天训练%@%@%@%@",
        "补记%@%@%@%@",
        "明天安排%@%@%@%@",
        "给我创建%@%@%@%@的计划",
        "这一组是%@%@%@%@",
        "先生成%@%@%@%@草稿",
        "我刚完成%@%@%@%@",
        "不保存，只识别%@%@%@%@"
    ]

    private static var mealCases: [SpeechGoldenCase] {
        mealItems.enumerated().flatMap { itemIndex, item in
            mealPatterns.enumerated().map { patternIndex, pattern in
                let spokenFood = (item.brand ?? "") + item.food
                SpeechGoldenCase(
                    id: "meal-\(itemIndex + 1)-\(patternIndex + 1)",
                    domain: .meal,
                    referenceTranscript: String(format: pattern, spokenFood, item.amount),
                    expectedSlots: slots(food: item.food, amount: item.amount, brand: item.brand)
                )
            }
        }
    }

    private static var workoutCases: [SpeechGoldenCase] {
        workoutItems.enumerated().flatMap { itemIndex, item in
            workoutPatterns.enumerated().map { patternIndex, pattern in
                SpeechGoldenCase(
                    id: "workout-\(itemIndex + 1)-\(patternIndex + 1)",
                    domain: .workout,
                    referenceTranscript: String(format: pattern, item.exercise, item.sets, item.reps, item.weight),
                    expectedSlots: workoutSlots(exercise: item.exercise, sets: item.sets, reps: item.reps, weight: item.weight)
                )
            }
        }
    }

    private static func slots(food: String, amount: String, brand: String?) -> [String: String] {
        var result = ["food": food, "amount": amount]
        if let brand { result["brand"] = brand }
        return result
    }

    private static func workoutSlots(exercise: String, sets: String, reps: String, weight: String) -> [String: String] {
        ["exercise": exercise, "sets": sets, "reps": reps, "weight": weight]
    }
}

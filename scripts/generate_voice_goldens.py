#!/usr/bin/env python3
"""Generate the versioned Chinese voice-routing golden set used by PR-H."""

import json
from pathlib import Path


MEALS = ["鸡胸肉", "番茄鸡蛋", "牛肉面", "三文鱼", "瑞幸拿铁", "可口可乐", "全家饭团", "麻婆豆腐", "酸奶", "燕麦"]
AMOUNTS = [("一百克", "g"), ("半公斤", "kg"), ("250毫升", "ml"), ("两勺", "serving"), ("一碗", "serving"), ("300克", "g")]
EXERCISES = ["深蹲", "卧推", "硬拉", "引体向上", "哑铃弯举", "划船"]
TIMES = ["今天", "明天", "昨晚", "上午", "训练后"]


def item(text, kind, slots, note):
    return {"text": text, "expectedKind": kind, "slots": slots, "notes": note}


def main():
    rows = []
    for index in range(120):
        meal = MEALS[index % len(MEALS)]
        amount, unit = AMOUNTS[index % len(AMOUNTS)]
        time = TIMES[index % len(TIMES)]
        spoken_meal = "鸡凶肉" if meal == "鸡胸肉" and index % 29 == 0 else meal
        text = f"{time}{'没吃' if index % 17 == 0 else '吃了'}{amount}{spoken_meal}"
        rows.append(item(text, "mealDraft", {"dish": meal, "amount": amount, "unit": unit, "time": time, "negated": index % 17 == 0}, "meal"))
    for index in range(120):
        exercise = EXERCISES[index % len(EXERCISES)]
        sets = (index % 5) + 1
        reps = [3, 5, 8, 10, 12][index % 5]
        load = 20 + (index % 9) * 10
        text = f"{exercise}补{sets}组，每组{reps}次，{load}公斤"
        rows.append(item(text, "strengthSetDraft", {"exercise": exercise, "sets": sets, "repetitions": reps, "loadKg": load}, "strength"))
    for index in range(30):
        exercise = EXERCISES[index % len(EXERCISES)]
        rows.append(item(f"明天做 {index % 4 + 3}×{index % 5 + 5} {exercise}", "workoutPlanDraft", {"exercise": exercise, "time": "明天"}, "workout-plan"))
    for index in range(30):
        rows.append(item(f"查询今天第{index + 1}个热量和本周进度", "readOnlyQuery", {"time": "今天"}, "query"))
    assert len(rows) == 300
    output = Path(__file__).resolve().parents[1] / "evals" / "voice-zh-CN.jsonl"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows), encoding="utf-8")
    print(f"Generated {len(rows)} rows: {output}")


if __name__ == "__main__":
    main()

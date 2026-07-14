# densoso

健康管理应用

**技术栈**: Swift 6 / SwiftUI / SwiftData / GRDB / Apple Speech / HealthKit  
**Agent**: Anthropic function tooling

---

## 项目结构

```
densoso/
├── project.yml                  # XcodeGen 项目定义
├── Densoso/
│   ├── App/                     # AppRoot、Dependencies、AppState
│   ├── Models/                  # SwiftData 数据模型
│   ├── Services/                # Anthropic function tooling、Speech、FoodDatabase、算法引擎、HealthKit、导出
│   ├── Agent/                   # AgentSession、ToolRegistry、SystemPrompt、7 个 Tool
│   └── Views/                   # SwiftUI 界面
├── Densoso/Resources/
│   ├── cooking_coefficients.json    # 自建烹饪方式热量系数表
│   ├── seed_foods.json              # 开发用 30 条食材数据
│   └── food_composition.db          # 构建时由 seed_foods.json 生成
├── scripts/
│   └── import_food_db.py            # JSON → SQLite + FTS5 导入脚本
└── .github/workflows/
    └── build.yml                    # GitHub Actions CI
```

---

## 中餐热量估算核心逻辑

1. LLM 将菜名分解为食材 + 烹饪方式 + 份量
2. 查本地《中国食物成分表》食材热量
3. 应用烹饪方式系数：清蒸 1.0 / 爆炒 1.2 / 红烧 1.3 / 煎炸 2.0
4. 叠加食材吸油修正：茄子/豆腐/鸡蛋等系数 +1.2~1.5
5. 返回热量 + 置信度，用户可一键修正（±20%/±50%）

---

## 许可证

个人项目.

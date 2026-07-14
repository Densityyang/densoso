# densoso

纯 iOS 本地语音驱动的热量缺口管理应用。

**技术栈**: Swift 6 / SwiftUI / SwiftData / GRDB / Apple Speech / HealthKit  
**Agent**: DeepSeek `deepseek-v4-flash` via Anthropic Messages API 格式  
**构建方式**: Windows 本地编辑 + GitHub Actions (macOS runner) 云编译 + AltStore 侧载

---

## 项目结构

```
densoso/
├── project.yml                  # XcodeGen 项目定义
├── Densoso/
│   ├── App/                     # AppRoot、Dependencies、AppState
│   ├── Models/                  # SwiftData 数据模型
│   ├── Services/                # DeepSeekClient(Anthropic 格式)、Speech、FoodDatabase、算法引擎、HealthKit、导出
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

## API 接入说明

本项目通过 **Anthropic Messages API 格式** 调用 DeepSeek：

- Base URL: `https://api.deepseek.com/anthropic`
- Model: `deepseek-v4-flash`
- Auth Header: `x-api-key`

> 暂不使用 Apple Foundation Models (iOS 26 内置) 作为 v1 主模型；后续会考虑作为本地兜底模型。

API Key 由用户在 App 内输入，保存到 iOS Keychain，**不会硬编码在源码中**。

---

## 本地开发（Windows 环境）

由于 iOS 应用必须 macOS + Xcode 编译，本项目采用 **XcodeGen + GitHub Actions**：

1. 在 Windows 上用 VS Code 编辑 Swift 源码。
2. push 到 GitHub 后，Actions 在 `macos-latest` runner 上：
   - 安装 XcodeGen
   - 生成 `Densoso.xcodeproj`
   - 用 `xcodebuild` 构建 iOS Simulator 版本
3. 构建产物（后续可配置 .ipa）从 Actions 下载，通过 AltStore 安装到 iPhone。

---

## 首次上传 GitHub

1. 在 GitHub 上创建空仓库 `densoso`（不要加 README/License）
2. 本地执行：

```bash
cd e:/howtodo/densoso
git init
git add .
git commit -m "init: v1 skeleton"
git branch -M main
git remote add origin https://github.com/你的用户名/densoso.git
git push -u origin main
```

3. 进入 GitHub Actions 页面，等待 `Build` workflow 运行。

---

## 配置 API Key

首次启动 App 时，在 Onboarding 页输入 DeepSeek API Key，保存到 Keychain。后续可在"设置"中修改。

---

## 导出 .ipa 侧载（AltStore）

当前 CI 仅做 Simulator 构建验证。要生成真机可侧载的 `.ipa`：

1. 在 GitHub 仓库 Settings → Secrets and variables → Actions 中添加：
   - `APPLE_ID`: 你的 Apple ID 邮箱
   - `APPLE_APP_PASSWORD`: Apple ID 应用专用密码（在 [appleid.apple.com](https://appleid.apple.com) 生成）
2. 创建 `scripts/exportOptions.plist`（`method: development`）
3. 取消 `.github/workflows/build.yml` 中 "Archive & Export .ipa" 的注释
4. push 后从 Actions 下载 `.ipa`，用 AltStore 安装

注意：免费 Apple ID 签名的 `.ipa` 每 7 天需要重新签名，AltStore 会在后台尝试自动重签。

---

## 中餐热量估算核心逻辑

1. LLM 将菜名分解为食材 + 烹饪方式 + 份量
2. 查本地《中国食物成分表》食材热量
3. 应用烹饪方式系数：清蒸 1.0 / 爆炒 1.2 / 红烧 1.3 / 煎炸 2.0
4. 叠加食材吸油修正：茄子/豆腐/鸡蛋等系数 +1.2~1.5
5. 返回热量 + 置信度，用户可一键修正（±20%/±50%）

---

## 许可证

个人项目，仅用于学习和自用。

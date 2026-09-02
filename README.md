# densoso

densoso 是一个面向 iPhone 与 Apple Watch 的个人健康记录应用：语音优先记录饮食和运动，本地完成结构化、食物匹配、热量估算和确认后写入；HealthKit 负责系统健康数据同步，Apple Watch 负责实测运动链路。

## 产品能力

- 五个原生 SwiftUI 页面：对话、仪表盘、历史、训练计划和设置。
- 语音输入：`SpeechAnalyzer → legacy Speech → 可选单次 Qwen ASR → 手动编辑`；
  云端兜底只在本地失败、已采到音频并单独同意上传时触发。
- 结构化餐食与训练草稿，支持最少量澄清问题和用户修正。
- 本地食物数据库、食物匹配、确定性区间估算和数据证据展示。
- HealthKit 体重、身高、训练和饮食能量同步。
- WorkoutKit/HealthKit 运动记录与 Apple Watch 到 iPhone 的增量导入。
- 滚动七天趋势和自然周报告，缺失日期保持显式缺失。
- 版本化中文语音 golden set，用于 transcript、slot 和 latency 评估。

## 核心架构

```text
语音 / 文本 / 照片证据
        ↓
结构化草稿（不写库）
        ↓
本地校验、食物匹配、区间估算
        ↓
持久化 PendingAction + 用户确认
        ↓
ConfirmationCoordinator 原子写入 record / projection / receipt / outbox
        ↓
DailyMetricsProjector / WeeklyAnalyticsService
        ↓
可选 HealthKit 同步
```

核心边界：

- Agent 只负责意图提取、草稿生成和澄清问题。
- 营养计算、权限判断、确认状态、幂等写入和日指标重算由本地领域代码负责。
- `ConfirmationCoordinator` 与 SwiftData repository 是餐食/体重的确认边界；
  已完成运动事实只由 HealthKit 导入，模型输出不能直接写入。
- `IntelligenceRoutingPolicy` 统一选择本地模型、Speech 路径或显式云端路径。
- `DailyMetrics` 是日指标和周分析的唯一聚合来源。

## 数据与隐私边界

- API Key 保存在设备 Keychain。
- 启用云端路径时，Key 和请求文本会发送给所选服务商；本地路径不应被描述为云端同步。
- Qwen 健康文字与单次临时音频使用两个独立同意项；临时 WAV 使用 Complete
  protection，并在成功、失败、取消和下次启动时清理。
- 原始照片只作为条码、营养标签、食物类别和份量区间的辅助证据，不能从单张图像承诺精确克重或热量。
- HealthKit 读取权限受到系统隐私保护；应用不会把“无数据”误报为用户拒绝读取。
- 所有健康数据写入都应经过用户确认，并通过幂等键避免重复记录。

## HealthKit 与系统能力

HealthKit 有两个独立层面：工程/签名能力和用户授权。工程 target 通过 `project.yml` 与 `Densoso/Densoso.entitlements` 配置 HealthKit，并声明读写用途；运行时由公开的 `HKHealthStore` API 请求具体数据类型。

麦克风和 Speech 是系统运行时权限；HealthKit、麦克风和 Speech 的状态在设置页分开展示。应用不会使用私有 API 读取签名信息，签名能力由授权请求返回结果验证。

## 构建与部署

生成 Xcode 项目并执行共享域测试：

```bash
brew install xcodegen
xcodegen generate
swift test --package-path Packages/DensosoDomain
```

执行 iOS Simulator 测试：

```bash
xcodebuild -project Densoso.xcodeproj \
  -scheme Densoso \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO clean test
```

生成可供重签的 Release IPA：

```bash
gh workflow run build-ipa.yml --repo Densityyang/densoso --ref <branch>
gh run download <run-id> --repo Densityyang/densoso --name Densoso.ipa --dir ./artifacts
```

IPA workflow 生成的包包含 `Payload/Densoso.app` 和嵌入的 Watch App，但不包含最终签名。部署前必须使用与 App ID 匹配、并保留所需 capability 的 provisioning profile 重签；安装后仍需由用户在系统授权页确认具体 HealthKit、麦克风和 Speech 权限。

## 自动化验证

数据和语音基线也可以通过以下命令验证：

```bash
python scripts/validate_food_db.py
python scripts/validate_voice_goldens.py --input evals/voice-zh-CN.jsonl
python -m py_compile scripts/evaluate_voice_transcripts.py scripts/generate_voice_goldens.py \
  scripts/import_exercise_catalog.py scripts/import_food_db.py scripts/validate_food_db.py \
  scripts/validate_gate0_ui.py scripts/validate_phase1_foundation.py \
  scripts/validate_phase2_domain_persistence.py \
  scripts/validate_phase3_agent_provider.py \
  scripts/validate_phase4_speech.py \
  scripts/validate_voice_goldens.py
```

GitHub Actions 工作流位于 `.github/workflows/`：

- `build.yml`：`gate-01-foundation` 执行纯 `DensosoDomain` 测试、确定性 XcodeGen、
  iOS 18 deployment 构建、iOS 26 Simulator 单测/UI 截图与 Watch 编译，
  并上传 `.xcresult` 和日志证据；后续依次运行 `gate-02-domain-persistence`
  `gate-03-agent-provider` 和 `gate-04-speech`；Provider/ASR 测试只使用本地
  fixture/fake transport，物理麦克风矩阵仍由签名真机单独验收。
- `build-ipa.yml`：手动触发 Release device build、IPA 打包和 artifact 上传。

## 文档索引

- [Orbit UI v1.2 实现说明](docs/orbit-ui-v1.2.md)
- [语音评测基线](docs/speech-evaluation.md)
- [PR-001 历史设计与审计基线](docs/PR-001-stabilize-agent-and-calorie-pipeline.md)

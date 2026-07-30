# densoso

densoso 是一个面向 iPhone 与 Apple Watch 的个人健康记录项目：语音优先记录饮食和运动，本地完成结构化、食物匹配、热量估算和确认后写入；HealthKit 负责系统健康数据同步，Watch 负责实测运动链路。

## 当前状态

当前代码线包含已批准的 Orbit UI v1.2 视觉基础、周分析、能力诊断和 iOS 26.5 的云端构建配置。PR #13 的 macOS Build 与 unsigned IPA 打包已经通过；真机语音、HealthKit entitlement 和最终 Sideloadly 签名仍需在实体设备上验收。

本项目的安全边界是：模型只产生草稿和澄清问题，本地代码负责计算、权限、确认和持久化。任何餐食或运动写入都必须经过确认边界，不能把模型输出直接当作健康事实。

## 主要能力

- 五个原生 SwiftUI 页面：对话、仪表盘、历史、训练计划和设置。
- 语音输入链路：`SpeechAnalyzer` 可用时优先使用，否则回退到兼容 Speech 路径。
- 结构化草稿与 `PendingActionStore`：确认前不写入 Meal 或 Workout 记录。
- 本地食物数据库与确定性热量估算，保留食物匹配和数据证据边界。
- HealthKit 体重、身高、训练和饮食能量同步；设置页分开展示设备支持、工程配置、授权状态和隐私保护边界。
- Weekly analytics：仪表盘显示滚动七天数据，同时持久化当前自然周报告。
- Apple Watch WorkoutKit/HealthKit 运动链路与 iPhone 增量导入。
- 300 条版本化中文语音 golden cases，用于文本、槽位和延迟评估。

## 架构边界

```text
语音 / 文本 / 照片证据
        ↓
结构化草稿（不写库）
        ↓
本地校验、食物匹配、区间估算
        ↓
PendingActionStore + 用户确认
        ↓
幂等写入 SwiftData
        ↓
DailyMetricsProjector / WeeklyAnalyticsService
        ↓
可选 HealthKit 同步
```

云端 DeepSeek 路径和本地路径由 `IntelligenceRoutingPolicy` 统一选择。API Key 保存在设备 Keychain；启用云端模式时，Key 和请求文本会发送给所选服务商，不能将云端模式描述为“完全不上传”。

## 开发与验证

Windows 环境不能运行 Xcode；Python 数据校验可以本地执行，Swift 编译和 XCTest 由 GitHub Actions 的 macOS runner 执行。

```powershell
python scripts/validate_food_db.py
python scripts/validate_voice_goldens.py --input evals/voice-zh-CN.jsonl
python -m compileall -q scripts
```

macOS 上生成项目并执行测试：

```bash
brew install xcodegen
xcodegen generate
swift test --package-path Packages/DensosoWorkoutDomain
xcodebuild -project Densoso.xcodeproj \
  -scheme Densoso \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO clean test
```

CI 工作流位于 `.github/workflows/`：

- `build.yml`：食物库校验、XcodeGen、共享 workout domain 测试、iPhone 17 Pro 模拟器上的完整 XCTest。
- `build-ipa.yml`：手动触发 Release device build，打包 unsigned `Densoso.ipa` 并上传 artifact。

IPA 工作流不会替用户签名。下载 artifact 后，需要用 Sideloadly 或拥有 HealthKit capability 的 Apple Developer provisioning profile 重签；unsigned CI 包不能证明真机签名包含 HealthKit entitlement。

## 权限与真机验收

HealthKit 有两个独立层面：工程/签名能力和用户授权。仓库已在 `project.yml` 与 `Densoso/Densoso.entitlements` 配置 HealthKit，并提供读写用途说明；安装到真机后仍需在系统弹窗和“设置 → 隐私与安全性 → 健康”中确认。麦克风和 Speech 主要是系统运行时权限，不需要额外的业务申报。

详细步骤、免费 Personal Team 的限制和 Sideloadly 验收边界见 [HealthKit 与真机验收](docs/healthkit-and-device-testing.md)。

## 文档索引

- [Orbit UI v1.2 实现说明](docs/orbit-ui-v1.2.md)
- [HealthKit 与真机验收](docs/healthkit-and-device-testing.md)
- [CI 与 IPA 发布](docs/ci-and-release.md)
- [语音评测基线](docs/speech-evaluation.md)
- [PR-001 历史设计与审计基线](docs/PR-001-stabilize-agent-and-calorie-pipeline.md)

## 后续工作

1. 用 Sideloadly 在 iPhone 17 / iOS 26.5.2 上完成语音、麦克风和 HealthKit 验收。
2. 在 Apple Watch Series 8 / watchOS 26.5 上完成 WorkoutKit 实测和回传验收。
3. 根据实体设备的授权、音频路由和延迟结果迭代，不在未验证前扩大云端或 UI 承诺。

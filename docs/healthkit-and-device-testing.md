# HealthKit 与真机验收

## 两层权限模型

HealthKit 的“能不能请求”与“用户是否允许”不是同一件事：

1. 工程必须启用 HealthKit capability，并在签名使用的 App ID/provisioning profile 中保留 `com.apple.developer.healthkit`。
2. 用户在 iPhone 上对具体读写类型进行授权；授权可以随时在系统设置或健康 App 中改变。

仓库中的配置位置：

- `project.yml`：HealthKit entitlement 和 `NSHealthShareUsageDescription`、`NSHealthUpdateUsageDescription`。
- `Densoso/Densoso.entitlements`：`com.apple.developer.healthkit`。
- `Densoso/Services/CapabilityDiagnosticsService.swift`：公开 HealthKit API、设备可用性、写入授权和授权请求状态。

应用不会使用私有 `SecTask` API 读取签名信息。设置页的“工程能力”只表示源码 target 已配置 HealthKit；真正的签名能力由用户点击连接时的 `HKHealthStore.requestAuthorization` 验证。

## iPhone 验收步骤

1. 从 GitHub Actions 下载 unsigned `Densoso.ipa`。
2. 在 Sideloadly 中选择 IPA，使用具备相应能力的 Apple Developer 团队完成重签和安装。
3. 首次打开 App，进入“设置 → Apple Health → 连接 Apple Health”。
4. 在系统授权页选择需要的身高、体重、训练和饮食能量读写权限。
5. 在“设置 → 隐私与安全性 → 健康 → densoso”复核权限；也可以在“健康 → 共享 → App 与服务”中复核来源。
6. 返回 App，执行一次 HealthKit 导入，确认“最近导入时间”更新，并检查历史/仪表盘是否出现数据。

如果系统返回缺少 entitlement，问题在 Sideloadly 使用的签名描述文件，而不是 SwiftUI 页面。需要在 Apple Developer 的 Certificates, Identifiers & Profiles 中为对应 App ID 启用 HealthKit，并重新生成 provisioning profile。开发测试不需要先提交 App Review；App Store/ TestFlight 发布阶段才需要按健康数据隐私规则准备隐私政策和审核材料。

## 语音验收步骤

1. 在 iOS 系统弹窗中允许麦克风和语音识别。
2. 在设置页确认“麦克风”和“语音识别”状态不是“拒绝”。
3. 在对话页按住或点击麦克风，说出一条饮食或训练记录。
4. 确认识别结果先进入草稿/确认卡片，确认前不应出现在历史记录或 HealthKit。
5. 若 App 跳出或麦克风按钮不可用，记录 iOS build、语音后端、权限状态和崩溃日志；CI 无法替代这一步。

## 已知边界

- GitHub Actions 使用 `CODE_SIGNING_ALLOWED=NO`，因此只能证明编译和测试，不证明最终 Apple 签名。
- HealthKit 不会向 App 明确暴露用户拒绝读取权限的状态；没有数据不等于 App 能区分“拒绝”和“没有数据”。
- 模拟器不提供真实麦克风、Apple Watch 运动和用户 HealthKit 数据，相关结果必须以实体设备为准。

官方参考：

- [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [Setting up HealthKit](https://developer.apple.com/documentation/healthkit/setting-up-healthkit)
- [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)

# CI 与 IPA 发布

## Build workflow

`.github/workflows/build.yml` 监听 `master` 的 push 和 PR，并在 `macos-latest` 上执行：

1. 校验 31 条 bundled food database 记录。
2. 安装 XcodeGen 并生成 `Densoso.xcodeproj`。
3. 执行 `Packages/DensosoWorkoutDomain` 的 Swift Package 测试。
4. 启动可用的 iPhone 17 Pro Simulator。
5. 执行一次 clean XCTest，并上传 `TestResults.xcresult` 与 `xcodebuild.log`。

## 手动打包 unsigned IPA

`build-ipa.yml` 只接受手动触发，使用当前分支生成 unsigned Release IPA：

```powershell
gh workflow run build-ipa.yml --repo Densityyang/densoso --ref <branch>
gh run list --repo Densityyang/densoso --workflow build-ipa.yml --limit 1
gh run download <run-id> --repo Densityyang/densoso --name Densoso.ipa --dir .\artifacts
```

artifact 中的文件名是 `Densoso.ipa`，内部应包含 `Payload/Densoso.app`，以及嵌入的 Watch App。该包没有最终签名，不能把 CI artifact 直接当作可安装的生产 IPA；需由 Sideloadly 使用可用的 Apple Developer team 重签。

## 合并门禁

PR 合并前必须满足：

- 工作树无未提交的生产代码变更；
- `gh pr checks <number>` 中 Build 为 `SUCCESS`；
- 发生 Swift 编译错误时，以 Actions 的真实日志为准，不以 Windows 本地 Python 校验代替；
- IPA 只在 Build 通过后触发；
- 真机语音、HealthKit 和 Watch 运动验收单独记录，不把 simulator 通过误报为真机通过。

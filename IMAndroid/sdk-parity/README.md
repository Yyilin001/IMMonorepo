# 共享 SDK 的 iOS 兼容性基线

本目录保存编译器导出的公开接口清单，不再维护独立 Kotlin 业务实现的逐项对齐表。第五阶段已移除旧 Kotlin `clientkit` / `platform`；Android 通过 `sharedsdk` 调用同一 Swift 运行时。

当前基线包含 `IMV2ClientKit`、`IMV2ClientRuntime`、`IMV2ClientNetwork`、`IMV2ClientPlatform` 和 `IMV2ClientApple` 五个模块的 iOS 17 / arm64 模拟器公开符号：6,035 项，其中手写 4,196、生成 1,773、无源码位置 66。移除表情回应后，时间线接口不再返回反应集合，客户端不再公开表情回应的提交、恢复和重试接口。

- `swift-public-api.jsonl`：公开符号的精确身份、声明、类型和仓库相对位置。
- `manifest.json`：编译器、目标、输入图和源码摘要；源码覆盖整个 `IMV2ClientKit/Sources`、Package 与实时协议。
- `IMV2SharedSDK`、共享组合层及各平台适配是独立入口，不纳入旧 iOS 门面符号比较；Swift 源摘要仍覆盖它们。第十二阶段新增 Apple 组合后，不能再将 `IMV2SharedSDK` 称为仅限 Android 的产品。

第十三阶段新增的原生 `V2SharedSession` / `V2SharedSessionRestoration` 位于 `IMV2SharedRuntime`，单独保存接口记录，不将新增模块混入旧五模块的兼容性计数。

`--check` 检测源码和清单漂移，不替代重新编译，不代表行为等价或 Android UI 功能覆盖。生成文件不得手改以伪造兼容性结果。

在仓库根目录重新生成（本机 Swift 6.4 / SwiftPM Xcode 构建后端已验证）：

```sh
sdk_audit_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --package-path IMV2ClientKit \
  --disable-automatic-resolution --triple arm64-apple-ios17.0-simulator --sdk "$sdk_audit_sdk"
mkdir -p IMAndroid/build/verification/sdk-audit-ios-symbolgraphs
for sdk_audit_module in IMV2ClientKit IMV2ClientRuntime IMV2ClientNetwork IMV2ClientPlatform IMV2ClientApple; do
  xcrun swift-symbolgraph-extract \
    -module-name "$sdk_audit_module" -target arm64-apple-ios17.0-simulator -sdk "$sdk_audit_sdk" \
    -minimum-access-level public -skip-synthesized-members \
    -I IMV2ClientKit/.build/out/Products/Debug-iphonesimulator \
    -I IMV2ClientKit/.build/checkouts/GRDB.swift/Sources/GRDBSQLite \
    -I IMV2Compression/Sources/CZlib -I MessageSubstringSearch/Sources/CSQLite \
    -output-dir IMAndroid/build/verification/sdk-audit-ios-symbolgraphs
done
python3 IMAndroid/scripts/export_sdk_api_inventory.py \
  --graph IMAndroid/build/verification/sdk-audit-ios-symbolgraphs
python3 IMAndroid/scripts/export_sdk_api_inventory.py --check
```

其他构建后端需要调整 `-I` 到刚构建的 iOS 模块位置；不可用 macOS 模块替代，也不可漏掉 Apple 扩展图。当前模块还依赖 `CSearchFileLock`，提取符号时需要将本次构建生成的该 C target 模块映射目录加入 `-I`。实际 Android、macOS 和 iOS 回归结果见 [第十二阶段结果](../../experiments/swift-desktop/README.md)。

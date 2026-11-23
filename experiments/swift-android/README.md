# Swift Android 迁移验证

这是独立验证工程，验证 Swift 依赖和 Kotlin → JNI → Swift 的实际 Android 运行链路。生产 Android App 不包含探针产品；共享 SDK 的 native 构建当前复用此处 `build_probe.py --shared-sdk`。

第一阶段的 12 项测试结果保留在 `verification/` 和 [RESULTS.md](RESULTS.md)。第二阶段新增共享运行时与生产 HTTP 适配测试，第二阶段运行器执行 16 项测试，结果另存 [`verification/phase2/RESULTS.md`](verification/phase2/RESULTS.md)。第二阶段同时修改了 iOS SDK 模块划分和搜索跨平台依赖，数据库格式不变。

## 固定环境

- 开源 Swift 工具链和 Android Swift SDK：6.4.2，不能用 Xcode 自带 Swift 替代。
- Android NDK：30.0.16248370；目标为 `aarch64-unknown-linux-android31`。
- Android App：minSdk 31，compileSdk/targetSdk 36；沿用仓库 Gradle、AGP 和 Kotlin。
- GRDB 7.11.1、swift-crypto 3.15.1、swift-protobuf 1.38.1；传递依赖由 `Package.resolved` 固定。
- SQLite 3.51.2 官方 amalgamation，校验 SHA-256 后静态链接，启用 FTS5、WAL snapshot 和线程安全。没有依赖 Android 私有 SQLite 库。
- `IMV2ClientRuntime`、`MessageSubstringSearch`、`IMV2Core`、`IMV2Compression` 直接使用仓库源码；Protobuf 文件由脚本从仓库生成目录复制到忽略的构建目录，并记录源文件摘要。

## 执行

已有对应工具链时不要重复安装。所有构建通过 `swiftly run ... +6.4.2` 选择工具链，不修改全局 Swift 选择。

```sh
swiftly install 6.4.2
swiftly run swift sdk install \
  https://download.swift.org/swift-6.4.2-release/android-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz \
  --checksum 4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233 +6.4.2

# 用已安装的 Android CLI，或 Android Studio SDK Manager 安装指定 NDK。
"$ANDROID_HOME/cmdline-tools/23.0/bin/android" sdk install ndk/30.0.16248370

# 在仓库根目录；默认使用 ~/Library/Android/sdk，可用环境变量覆盖。
python3 experiments/swift-android/build_probe.py

cd IMAndroid
./gradlew -PenableSwiftProbe=true \
  :swiftprobe:assembleDebug :swiftprobe:assembleDebugAndroidTest :swiftprobe:lintDebug
cd ..
python3 experiments/swift-android/run_probe.py --serial emulator-5556 --api 31
```

运行前确保选定模拟器已启动且可以访问公网。公网 HTTPS 用例访问 `https://www.swift.org/`；DNS/网络失败会明确失败，不跳过或当作 TLS 成功。其余网络测试使用进程内环回夹具。脚本不会修改设备网络设置。

R8 验证使用以下命令，再运行相同用例：

```sh
cd IMAndroid
./gradlew -PenableSwiftProbe=true -PswiftProbeTestBuildType=release \
  :swiftprobe:assembleRelease :swiftprobe:assembleReleaseAndroidTest :swiftprobe:lintRelease
cd ..
python3 experiments/swift-android/run_probe.py --serial emulator-5556 --api 31 --variant release
```

这里的 Release 是**开启 R8、使用调试签名且保留 debuggable 的测试壳**，以便 `run-as` 导出证据；不是生产发布包。测试壳保留 instrumentation 共享的 Kotlin/coroutines 类型，避免跨 APK 的测试入口被裁剪；这些规则不是正式 SDK 的优化方案。ABI 当前仅验证 arm64-v8a。

## 验证内容

1. 实际加载 Swift 动态库；以 UTF-8 字节数组跨 JNI 传参、取回 JSON，包含中文路径和消息。
2. 仓库 Core、生成 Protobuf、zlib、SHA-256 已知向量、AES-GCM 加解密。
3. GRDB + SQLite：WAL、FTS5 短语位置查询、消息与 ACK 水位共同提交/回滚、关库重开。
4. HTTP：UTF-8 响应、状态码、拒绝自动重定向、已知长度和 chunked 响应的大小上限、绝对截止时间。
5. Kotlin 取消传播到 Swift Task；反复取消 sleep 和 AsyncStream；显式等待 producer 收尾；句柄释放规则与重复取消。
6. 取消实际流式 HTTP 后，环回服务端观察 socket 断开，且 Swift 句柄归零。
7. 默认 TLS 信任接受公网证书、拒绝未信任自签名证书；没有 trust-all、证书绕过或全局信任库修改。
8. 独立编译探针检查现有 URLSession API；原样编译搜索包，记录真实阻塞，不通过删功能掩盖。

`run_probe.py` 同时检查仪器测试完成标记、实际测试名集合、每项结果、API 级别及安装 APK 摘要。旧报告在每次运行前删除；初始化失败、部分运行、跳过和崩溃均不能成为成功。

## 证据与边界

- `build/native-manifest.json`：依赖库、编译能力、源协议和二进制摘要。
- `build/*api*.log`、`build/api31-debug/results.json` 等：本地执行证据。
- `verification/`：本轮保留的结果快照；结论见 [RESULTS.md](RESULTS.md)。

本探针使用小型手写 C ABI/JNI 桥接和轮询结果。它验证调用、任务所有权与取消合同，**不证明 swift-java 自动生成器能直接导出整个 SDK**，也不验证生产级 Kotlin Flow 接口。

Swift 业务代码不依赖 MainActor。第三阶段已实现 Android Keystore 和原生 TLS 字节连接，接入共享认证、同步和运行时，探针运行器包含 23 项测试。详见 [第三阶段结果](verification/phase3/RESULTS.md) 和 [平台适配接入说明](../../IMAndroid/swiftplatform/README.md)。

第四阶段用 `build_probe.py --shared-sdk --reuse-capabilities` 构建独立生产动态库，提供 Kotlin `suspend` / `Flow` 和实际 App 可选入口，已完成真实 IM 后端登录、非空增量同步、断线重连、所有者重开及取消验收。它与原探针分开构建，不包含探针操作。参见 [Kotlin 接入与复现](../../IMAndroid/sharedsdk/README.md) 和 [第四阶段结果](verification/phase4/RESULTS.md)。系统断电/杀进程恢复、系统后台任务、完整 Kotlin 业务接口及旧数据库迁移仍未验证或实现。

第二阶段的 `runtime_http` 使用生产 `V2HTTPExecutor`、调度器和 `V2URLSessionHTTPTransport`。仅对环回测试服务器注入 URL 替换适配器；HTTPS 测试直接走默认生产传输，不放宽生产端点校验或证书信任。`runtime` 运行真实搜索索引的 Unicode 查询、独占锁与重开，并通过安装绑定接口打开生产 GRDB store，启动搜索 actor 后再排空关闭。

参考：[Swift Android 官方入门](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、[Swift Java Android 边界](https://github.com/swiftlang/swift-java/blob/main/Sources/SwiftJavaDocumentation/Documentation.docc/Android.md)、[SQLite FTS5 编译选项](https://www.sqlite.org/fts5.html#building_fts5_as_part_of_sqlite)。

## 第五阶段：唯一共享 SDK

Android App 已默认且唯一使用共享 Swift SDK，旧 Kotlin `clientkit` / `platform`、旧 App 业务入口及其专属测试/benchmark 已删除。会话分页、文本收发、持久发送恢复和退出切换已接入。`protocol` 模块仅在启用历史探针时生成 Java 测试类型，不属于生产 App，也不复制协议源。

当前构建与后端验收以 [Android README](../../IMAndroid/README.md) 为准，结果见 [第五阶段结果](verification/phase5/RESULTS.md)。第四阶段的构建开关、默认旧入口及旧测试类说明仅代表当时状态，已被本阶段替代。

## 第六阶段：联系人与群组

联系人目录、好友请求与屏蔽、私聊创建、群目录和建群、成员管理、公告、角色权限、群主转让、退群与解散已接入共享 Swift 服务及 Android 页面。真实 App 与共享 SDK 对端验收和第五阶段消息回归均通过；iOS 公开接口不变。详情见 [第六阶段结果](verification/phase6/RESULTS.md)，复现时使用 `verify_shared_sdk.py --phase 6`。

## 第七阶段：资料、邀请和禁言

联系人授权资料、私有备注、头像读取，群邀请创建/分享/撤销、申请/取消/审批，以及一小时成员禁言，接入同一 Swift 服务和 Android 页面。详见 [第七阶段结果](verification/phase7/RESULTS.md)，复现使用 `verify_shared_sdk.py --phase 7`，并运行 `--phase 6`、`--phase 5` 回归。

## 第八阶段：头像编辑与邀请扫码

个人/群头像编辑上传与移除、邀请二维码相机扫描及图片识别接入共享 SDK，详情与设备验证范围见 [第八阶段结果](verification/phase8/RESULTS.md)。使用 `verify_shared_sdk.py --phase 8`，并运行第七、六、五阶段回归。

## 第九阶段：图片、文件与资源传输

图片/文件消息、资源上传下载、预览与系统文档保存接入同一 Swift 资源中心；Kotlin 仅保留设备 I/O、流式平台传输和页面绑定。详情见 [第九阶段结果](verification/phase9/RESULTS.md)，复现使用 `verify_shared_sdk.py --phase 9`，隔离后端增加 `--resource-part-uploads` 以覆盖真实分片上传。

## 第十阶段：搜索、消息变更与已读

本地全局/会话搜索及定位、消息编辑撤回、可见区域已读上报、私聊标记和群阅读者分页接入原有 Swift 服务。详情见 [第十阶段结果](verification/phase10/RESULTS.md)，使用 `verify_shared_sdk.py --phase 10`；历史回归使用 `--phase 9 / 8 / 7 / 6 / 5`。

## 第十一阶段：回复、转发和表情回应

回复引用随原 Swift 发送服务冻结，单条转发复用持久转发计划，回应复用可合并的目标状态与操作恢复。Android 只负责页面、导航和参数绑定。详情见 [第十一阶段结果](verification/phase11/RESULTS.md)，复现使用 `verify_shared_sdk.py --phase 11`；前阶段回归使用 `--phase 10 / 9 / 8 / 7 / 6 / 5`。

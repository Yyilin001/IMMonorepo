# 会话与消息列表性能测试

使用官方 [Macrobenchmark](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview) 1.5.0 和 UI Automator，在独立 `com.xmtx.im.android.benchmark` 包中调用生产 `Conversations` / `Chat` Composable，以及 `SqliteClientStore.appSnapshot()` / `ConversationTimelineSession`。最低 Android 12 / API 31。

| 数据集 | 冷启动与首屏 | 滚动与翻页 | 一次增量更新 |
| --- | --- | --- | --- |
| 1,000 / 10,000 个会话，每个一条消息 | SQLite 元数据读取到首屏 | 双向滚动 | 更新 20 个会话的摘要、时间与未读数，触发重新排序 |
| 单会话 10,000 / 100,000 条消息 | SQLite 最新 120 条窗口到首屏 | 双向滚动、替换为上一历史窗口 | 插入 20 条消息，刷新最新窗口并跟随底部 |

以上为 12 个静态场景；另有 8 个持续消息场景，四种数据集各覆盖静止查看与边滚动边接收。默认全部执行，共 20 个场景，每个 5 轮；可用 `--suite lists|stream|all` 选择。

持续负载支持 **1–1,000 msg/s**，默认 1,000 msg/s、持续 30 秒，时长可设为 5–120 秒。独立 IO 生产者按 100 ms 分桶，每桶最多写入 100 条；慢写入不会触发无限追赶突发。读取方合并通知，每次更新完成后间隔 100 ms，再读取真实会话快照或消息窗口。报告同时保存请求速率、指定时间窗口内实际提交速率、生产者积压/迟到、未发布数量及提交到帧边界的采样 P95/最大延迟。该延迟按合并发布采样，不代表每条消息单独绘制的延迟；浏览历史时允许暂停跟随，输入完成后显式返回最新并检查最终追平。

消息数据为固定的长短中文/英文混排，静态场景包含自己和他人的消息。测试断言数据数量、全局快照没有消息历史、消息窗口为 120 条、列表确实能滚动、历史页可返回，以及更新内容已发布。持续负载额外检查总写入数、最终数据库行数和 UI 发布进度，防止丢消息或未追平。数据通过测试专用 SQL 预置；测量期间也通过本地投影写入，包含后续真实读取、不可变快照发布和 Compose 绘制。它不测网络、SDK 协议接收/同步应用、头像下载、图片解码或完整登录导航。

`app:benchmark` 从当前 Release 配置派生，非 debuggable、允许 shell profiling、使用调试签名；Release 与 benchmark 均启用 R8 代码优化、混淆和资源裁剪。保留 Protobuf Lite 的反射字段，序列化依赖使用其自带规则；每轮造数前在优化后的 APK 内检查协议帧编解码、运行时 serializer 查找和多态导航路由恢复。固定 `CompilationMode.Full()`，不将它解释为 Baseline Profile 或未预编译安装的性能。测试入口及造数代码仅在 `src/benchmark`，普通 Debug/Release 不包含。每轮重新造数发生在 `setupBlock`，不计入性能指标；冷启动清空进程状态，不声称清空内核文件缓存。

## 运行

### 手机直接操作

安装 `app/build/outputs/apk/benchmark/app-benchmark.apk` 后，桌面打开「IM 性能测试」即可选择四种列表规模、1–1,000 msg/s 和 5–120 秒，再点「生成数据并进入列表」。进入后点「持续 … msg/s」开始，可同时手动滚动，结束后显示实际吞吐、提交到帧的采样 P95、最大积压和是否达到目标。浏览历史时须点「返回最新」才能完成追平；可停止测试或返回设置重新生成数据。

这是基于 Release 配置、开发证书签名的独立安装包，无需登录，与普通 App 可同时安装。普通 `app-release` 包不包含测试入口。手动界面不采集 Macrobenchmark 的帧耗时或 Perfetto 文件；需要完整性能报告时使用下述自动化命令。

2026-11-12 已在 API 31 上验证桌面图标启动、拒绝 1,001 msg/s、消息列表 1,000 msg/s × 5 秒、会话列表 1 msg/s × 5 秒、停止及返回后重建数据。两次完整运行均最终落盘并发布全部消息；证据及截图位于 `../build/list-perf/manual-launcher-api31/`。手动运行结果不替代正式 Macrobenchmark 基线。

同日启用 R8 后重新验证：测试包约 9.60 MiB（原约 69 MiB），普通签名 Release 约 9.59 MiB；安装包与对应混淆映射位于 `../build/deliverables/`。优化包重新通过上述两种手动负载、停止/重建、速率校验、协议编解码、运行时 serializer 查找及多态路由恢复，并验证生产 MainActivity 登录页可打开。证据为 `../build/list-perf/optimized-manual-api31/` 与 `../build/deliverables/size-checks.json`。构建与 Lint 无错误，JVM 调度测试 4/4、报告校验器 8/8 通过；本轮未重新执行完整自动化性能套件，也未运行真实账号网络端到端验收。

### 自动化报告

先构建，构建完成后再运行。测试期间不要运行 Gradle、其他 instrumentation 或高负载任务。

```sh
cd IMAndroid
./gradlew :app:testBenchmarkUnitTest :app:assembleBenchmark :benchmark:assembleBenchmark
# 固定真机，默认 5 轮；输出目录必须尚不存在。
python3 scripts/benchmark_lists.py --serial DEVICE_SERIAL --output build/list-perf/device-baseline
# 单独执行每秒 1,000 条、持续 30 秒的 8 个负载场景。
python3 scripts/benchmark_lists.py --serial DEVICE_SERIAL --suite stream \
  --message-rate 1000 --stream-seconds 30 --output build/list-perf/stream-1000
# 同设备、系统、屏幕和动画设置、轮数下对比后续版本。
python3 scripts/benchmark_lists.py --serial DEVICE_SERIAL --output build/list-perf/device-candidate \
  --baseline build/list-perf/device-baseline/summary.json --max-regression-percent 15
# 模拟器仅验证功能与采集流程，每场景一轮，持续负载默认 5 秒，不能作为性能基线。
python3 scripts/benchmark_lists.py --serial emulator-5556 --smoke --output build/list-perf/api31-smoke
```

脚本只安装独立测试包，不覆盖正常 App，不修改设备动画、网络或权限设置。选择充电稳定、温度正常、无后台负载的固定真机运行正式比较。默认不抑制 Macrobenchmark 的设备条件错误；`--smoke` 仅放行 EMULATOR。完成后可移除这两个测试专用包：

```sh
adb -s DEVICE_SERIAL uninstall com.xmtx.im.android.benchmark
adb -s DEVICE_SERIAL uninstall com.xmtx.im.benchmark
```

## 指标与回归判定

- `StartupTimingMetric`：首帧与完全绘制耗时；测试入口等到实际数据加载并经过帧边界才报告完全绘制。
- `FrameTimingMetric`：滚动/更新的 CPU 帧耗时、帧超时等；保留原报告的 P95/P99 和全部采样。
- `IM.List.load` / `IM.List.update` / `IM.List.stream`：异步 trace 段，从启动加载/点击更新开始，到结果发布后的帧边界结束，包含 SQLite、调度和界面更新；持续负载包含输入和最终追平。
- `summary.json` 保存设备指纹、屏幕、动画、编译模式、轮数、负载参数、APK 摘要、完整性检查和提取指标；`streams` 保存每场景每轮的负载证据，`raw/` 保留官方 `benchmarkData.json`、每轮 `.perfetto-trace` 和 `stream-*.json`。

选中套件的全部场景必须完整执行、没有跳过/失败、关键指标为正且 trace 齐全。正式持续负载运行还要求每轮在指定窗口内完成至少请求数量的 95%（允许调度抖动），否则 `loadTargetMet=false` 且脚本返回非零；全部消息仍必须最终落盘并发布。实际速率单独报告，95% 容差不等于精确达到请求速率。`--smoke` 只检查功能与采集，允许 `passed=true` 与 `loadTargetMet=false` 同时出现，不能据此认定负载达标。

首次真机运行采集基线，不设跨设备通用毫秒阈值。提供 `--baseline` 时，正耗时指标超过基线 15% 且增加超过 1 ms 返回非零；可调整百分比。基线设备/配置、负载速率/时长、场景或指标集合不同会拒绝比较。基线帧超时为零或负值时，改用增加超过 1 ms 的绝对变化判断，避免漏过从有余量变为超时的回归。模拟器结果明确标记 `baselineEligible: false`。

普通 CI 构建测试 APK、运行负载调度与报告脚本单元测试；实际性能门禁应在固定真机执行上述命令，不能用共享云模拟器的耗时评价回归。

## 本次本机验证（2026-11-11）

以下记录来自启用 R8 之前的 APK，不能冒充当前优化包的测量结果；优化包应重新采集正式基线。

API 31 模拟器：此前静态套件 **12/12** 通过、生成 12 份 trace；本轮持续负载套件以 1,000 msg/s、5 秒、每场景一轮执行，**8/8 功能与采集检查通过**，生成 8 份 trace。负载调度 JVM 测试 **4/4**、报告校验器 **8/8** 通过，覆盖任意速率分桶、慢写入不突发追赶、取消和吞吐不足的识别。Debug、benchmark App 和测试 APK 构建通过，App Debug/benchmark 与平台 Debug Lint 均无错误。

本轮指定 5 秒窗口内的实际提交速率如下；所有场景最终都写入并发布了 5,000 条，消息窗口保持 120 条，但会话列表未达到负载目标，整体 `loadTargetMet=false`。

| 数据集 | 静止查看 | 边滚动边接收 |
| --- | ---: | ---: |
| 1,000 个会话 | 780 msg/s | 720 msg/s |
| 10,000 个会话 | 100 msg/s | 100 msg/s |
| 10,000 条历史消息 | 1,000 msg/s | 1,000 msg/s |
| 100,000 条历史消息 | 1,000 msg/s | 1,000 msg/s |

本地证据：静态套件在 `../build/list-perf/api31-verified/`；本轮负载套件在 `../build/list-perf/stream-1000-api31/`，包含 `summary.json`、`checks.json`、`instrumentation.log` 和 `raw/`。此前静态失败记录保留在 `api31-smoke` 与 `api31-final`。模拟器结果均 `baselineEligible=false`；尚未运行真机 30 秒/5 轮负载验收，也未在本轮执行远端 CI。

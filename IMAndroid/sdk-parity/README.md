# Swift SDK 对齐审查

本目录保存可追溯的公开接口基线和人工审查结论。它不是功能覆盖率报告；一个同名 Kotlin 方法、一份生成的协议文件或一组通过的测试，都不能单独证明行为对等。

当前 iOS 基线共 6,023 项声明：手写来源 4,183、生成来源 1,773、无源码位置 67。相比同一源码的 macOS 导出多出 20 项 iOS 后台会话相关声明。这些是接口清点数量，不是已移植数量。

## 基线范围与使用

- `swift-public-api.jsonl`：编译器导出的每个公开声明，保留精确标识、签名、类型、仓库相对路径及从 1 开始的行列。按来源和标识排序，不保存本机绝对路径。
- `manifest.json`：编译器版本、目标平台、分类数量、输入图摘要、清单摘要及模块源码摘要。以 iOS 17 / arm64 编译目标为准；Android 最低版本仍是 API 31，两者互不约束。
- `handwritten` 是有源码位置的手写声明；`generated` 是 `Generated/` 中的声明；`unlocated` 是编译器未给出位置的声明，包括部分派生成员，保留待审查，不猜测归属。
- 清单覆盖 **IMV2ClientKit 模块当前目标的公开声明**。导入的 `IMV2Core` 等模块类型、内部算法、服务器合同和 App 页面不自动计入；这些仍须按具体能力交叉核对。macOS 导出会遗漏 iOS 条件编译的原生后台会话，因此本目录采用 iOS 导出结果。
- 除下表明确记录的行为外，所有声明均为**未逐项审查**；下表也不把整份来源文件标为已完成。生成代码及无源码位置的成员不计作 Android 业务实现。

检查源码或清单是否已经变化：

```sh
python3 IMAndroid/scripts/export_sdk_api_inventory.py --check
```

该检查不运行 Swift 编译器，不验证行为等价，也不证明导出时的构建新鲜度。源码增加、删除或内容变化后，应重新构建和导出，再重新审查受影响能力；不要仅更新摘要来消除失败。当前摘要包含模块全部 Swift 源文件、Package.swift、Package.resolved 和实时协议原文件，不包含所有传递依赖。

在仓库根目录重新生成（本机 Swift 6.4 / SwiftPM Xcode 构建后端已验证）：

```sh
sdk_audit_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --package-path IMV2ClientKit --target IMV2ClientKit \
  --disable-automatic-resolution --triple arm64-apple-ios17.0 --sdk "$sdk_audit_sdk"
mkdir -p IMAndroid/build/verification/sdk-audit-ios-symbolgraphs
xcrun swift-symbolgraph-extract \
  -module-name IMV2ClientKit -target arm64-apple-ios17.0 -sdk "$sdk_audit_sdk" \
  -minimum-access-level public -skip-synthesized-members \
  -I IMV2ClientKit/.build/out/Products/Debug-iphoneos \
  -I IMV2ClientKit/.build/checkouts/GRDB.swift/Sources/GRDBSQLite \
  -I IMV2Compression/Sources/CZlib -I MessageSubstringSearch/Sources/CSQLite \
  -output-dir IMAndroid/build/verification/sdk-audit-ios-symbolgraphs
python3 IMAndroid/scripts/export_sdk_api_inventory.py \
  --graph IMAndroid/build/verification/sdk-audit-ios-symbolgraphs/IMV2ClientKit.symbols.json
python3 IMAndroid/scripts/export_sdk_api_inventory.py --check
```

换用其他 SwiftPM 构建后端时，`-I` 必须指向刚构建的 iOS 模块目录，不能复用旧编译器或 macOS 的 `.swiftmodule`。生成命令只接收本模块源码路径，拒绝重复标识、非公开声明和仓库外部来源。

## 2026-11-11 人工审查

| 能力 | Swift 依据 | Android 依据与判断 |
| --- | --- | --- |
| 持久操作准入、领取和恢复 | [V2OperationWork](../../IMV2ClientKit/Sources/IMV2ClientKit/V2OperationWork.swift)、[通用工作存储](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2OperationWorkStore.swift)、[跨领域预留统计](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2PersonalPreferenceIntentStore.swift) | **部分实现，仍有缺口**。二十一类业务记录已通过 [SqliteOperationAdmission](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteOperationAdmission.kt) 接入事务性数量/字节预留，已读普通/恢复控制额度、建群/转发、个人偏好/消息操作、发送准备/命令、资料准备/命令和名称预留也已接入；发送需等待实际投影收敛后释放，细节见下文。新增 [通用执行日志](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteOperationWork.kt)，名称与本人资料真实执行路径已接入持久领取、独立重试轮次及排空后的所有者接管；依赖规则已有 SQLite 基础，其他执行适配和业务依赖仍待迁移；[AccountWorkScheduler](../clientkit/src/main/kotlin/com/xmtx/im/client/AccountWorkScheduler.kt) 的网络额度仍不能代替持久账本。 |
| 已完成业务操作历史回收 | [pruneCompletedOperationHistory](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2OperationWorkRetention.swift) | **确认缺口**。Android [资源导入清理](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteResourceImports.kt) 与[下载清理](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteResourceDownloads.kt) 只处理资源任务；未找到等价的跨业务操作历史回收入口。 |
| 持久任务诊断快照 | [accountWorkSnapshot](../../IMV2ClientKit/Sources/IMV2ClientKit/V2AccountWorkSnapshot.swift) | **确认缺口**。Android [OperationStepMetrics](../clientkit/src/main/kotlin/com/xmtx/im/client/OperationStepMetrics.kt) 和 [AccountNetworkActivity](../clientkit/src/main/kotlin/com/xmtx/im/client/AccountNetworkActivity.kt) 已记录执行/网络诊断，未提供同一 SQLite 读快照下的持久任务数量、预留字节及最老未决操作年龄。 |
| 快照准备、激活和旧表回收 | [prepareSnapshotActivation / activateAcknowledgedSnapshot / cleanupRetiredSnapshotTables](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) | **部分实现，已知差异再次确认**。Android [SqliteClientStore](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteClientStore.kt) 的预校验投影事务回滚，ACK 后再投影并提交；未采用 Swift 的预建替换表、激活切换和旧表回收。 |
| 本机在线/输入状态隐私限制 | [localPublicationPolicy / publicationPolicyUpdates](../../IMV2ClientKit/Sources/IMV2ClientKit/V2LocalPublicationPolicy.swift) | **已找到对应策略，尚未完成整条观察流等价验收**。Android [PreferencePublicationPolicy.derive](../clientkit/src/main/kotlin/com/xmtx/im/client/AccountPreferences.kt) 合并权威偏好与未结束任务的限制；[AppViewModel](../app/src/main/kotlin/com/xmtx/im/AppViewModel.kt) 使用该策略。不能仅因公开接口名称不同就判为缺失。 |

### 持久操作缺口的完成条件

Swift 默认普通操作额度为 2,000 项、32 MiB，依赖上限为 32；已读恢复另有 64 项、1 MiB 控制额度。普通额度还涵盖尚未冻结的业务意图，以及已受理但尚未被本地投影观察到的发送，不能只统计未完成命令行数。

对应实现需把配额检查、预留、冻结身份及业务载荷写入放在同一事务中。既有数据库需恢复准确预留，重复命令不能重复占额；草稿变为命令、取消、拒绝、未知结果及发送投影收敛必须遵循各自释放条件。持久领取还需验证所有者、租约、修订、操作顺序与依赖，网络结果回写不能接受旧领取凭据。现有领域恢复、幂等、账号关闭与后台任务所有权不能丢失。

在这些条件完成前，不增加一个未被业务存储调用的通用类来宣称对齐。后续优先把统一准入和领取贯穿真实写入/执行路径，再实现依赖该账本的诊断和回收。

### 历史回收与快照的验收边界

Swift 历史回收默认每次 32 项（允许 1–128），只删除超过七天、已提交完成且满足领域保护条件的记录。未知、拒绝、冲突、被依赖、待释放邀请秘密或受保护发送源不能按年龄删除；发送还必须等到本地展示收敛。Android 的资源任务保留数量不能证明这些条件已实现。

Swift 快照在 ACK 前完成投影过滤、索引及派生表准备，ACK 后切换表并更新代次，再独立清理旧表。Android 已有持久分页前缀、语义预校验和原子激活；其正确性测试不证明最终事务耗时与数据量无关。后续需要覆盖准备中断、ACK 丢失、切换中断、旧表清理恢复及最大支持数据量。

### 接口清点阶段的验证证据

接口清点阶段只新增清单工具与审查文档，没有修改 Android 运行时。`AccountPreferenceTests` 的本机隐私用例、`AccountWorkSchedulerTests` 的调度用例及 `SnapshotPagingTests` 的同步用例用于确认现有能力边界，不验证上述缺口已经解决。[SnapshotPagingStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/SnapshotPagingStorageTests.kt) 保留数据库重开、ACK 丢失和投影失败回滚用例，该阶段未重新运行设备测试。

本轮实际结果：iOS 与 macOS SDK 目标均构建成功；清单新鲜度检查通过；Python 工具测试 10/10（其中清单工具新增 5 项）；Android 上述三个 JVM 测试类分别 9/9、20/20、6/6；`assembleDebug`、App 与平台 `lintDebug` 通过，两份 Lint 各 0 错误、10 个既有警告。APK SHA-256 仍为 `616c8fb7bab24b67fe421c53158e3ec1f5487d93fd7d6be4e6e6b2147810aa55`。

本机证据保存在不入库的 `build/verification/sdk-audit-*`；Swift 构建成功并导出接口不等于 Swift 全套测试通过，Android 的定向回归也不等于全量 SDK 对齐。主 [README](../README.md) 继续记录真实后端、API 31 设备、真机和 Release 的验收范围。推送按用户要求暂缓，不计作本轮缺口。

## 2026-11-11 持久准入第一批接入

[OperationAdmission](../clientkit/src/main/kotlin/com/xmtx/im/client/OperationAdmission.kt) 提供数量/字节限制、明确的超限错误和不可变预留快照。默认 2,000 项、32 MiB；快照的 `domains` 明确列出实际覆盖范围，不冒充全账号任务统计。

[SqliteOperationAdmission](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteOperationAdmission.kt) 已由真实 `SqliteClientStore` 事务入口调用。首批覆盖以下九类持久记录：

| 记录 | 活跃预留 |
| --- | --- |
| 私聊创建 | 冻结命令及本地公开身份编码字节数 + 65,536 字节；旧版无身份记录按实际载荷计量 |
| 社交提案、社交命令、成员操作、成员管理、账号偏好、内容审核 | 每项 73,728 字节 |
| 群邀请操作 | 每项 81,920 字节 |
| 群能力操作 | 每项 131,072 字节 |

固定预留与 Swift 对应业务保持一致；私聊载荷按 Android 当前持久表示计算，不宣称不同平台编码的逐字节大小完全一致。尚未覆盖发送及发送准备、已读普通/控制通道、建群、个人偏好、消息编辑/撤回/反应/转发、个人资料/备注/头像等业务，因此本阶段不能宣称已实现全账号统一额度。

数据库触发器只记录变化主键，事务提交前每批最多读取 128 个变化记录并维护预留。提案确认和取消旧草稿后创建新草稿在同一事务内核算最终状态，不会临时占用双倍额度；容量异常或 SQLite 错误使业务数据、预留和变化键一起回滚。未知结果、暂停和需要关注的记录继续占额，只有领域已确认结束或本地允许取消才释放。

旧库按源表版本迁移，逐批读取，重开后保留已存预留。旧数据已经超过新配置额度时允许不增加数量或字节的恢复、转移和结束，不删除业务记录，也不允许继续增加超额维度。只读开库不会创建账本表；完整持久任务状态统计、通用领取令牌、依赖、历史回收均仍待实现。

实际验证：新增 [OperationAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/OperationAdmissionStorageTests.kt) 七项全部通过；首轮发现的三类复合主键映射错误已修正。最终 API 31 存储回归 36/36，另行只读及账号开库回归 10/10；JVM 私聊、社交、账号偏好测试共 30/30。Debug APK、平台测试 APK 及两模块 Lint 通过，各 0 错误、10 个既有警告。未运行全套 JVM、完整 App UI 或真实后端测试。

证据：`build/verification/operation-admission-*`。最终 APK SHA-256 为 `e3cd85c89975312f51b3d48406126b35d2d1c4bfc9205881bc60d1da64b50208`，设备安装包摘要匹配；新增测试自行清理，回归遗留的 28 个新建测试数据库文件已按基线差集清理。原有平台 5,596 项、App 434 项目录内容及网络、相机设置保留。

## 2026-11-11 已读普通与恢复控制额度接入

已读意图和冻结命令现在与上述业务共享普通数量/字节额度，移除了原先单独的 128 项已读普通队列限制。按实际命令编码预留；同一房间的意图合并保留单项额度，序号增长导致字节增长时必须仍满足额度。冻结、确认、归档均在业务事务中转移或释放预留，失败时连同本地阅读水位一起回滚。

归档恢复另使用最多 64 项、1 MiB 的控制额度，每项为命令编码字节数 + 67,584 字节（64 KiB 回执和 2 KiB 元数据）。普通池满时仍可恢复原命令并查询；查询未解决时，必须先取得普通额度才可重新提交。普通额度不足则保留控制额度、原身份和未知结果，进入 `controlCapacityRequired`。原操作完成后释放控制额度。已恢复的控制操作也阻止同房间后继意图提前冻结。

`OperationAdmissionUsage.activeCount/reservedBytes` 继续表示普通预留，新增 `controlCount/controlReservedBytes` 独立表示控制预留；`domains` 目前包含十一类记录。这不是完整的 Swift `V2AccountWorkSnapshot`，尚不统计全部执行状态或最老未决年龄。旧版单池表会原子增加池分类，已读存量按真实状态回填，保留原命令；只读开库不执行迁移。

本轮 [ReadAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/ReadAdmissionStorageTests.kt) 新增六项，验证跨业务额度、满额冻结转移、只查询后重新准入、控制字节额度回滚与释放、后继意图顺序、序号合并回滚及旧表迁移。API 31 定向回归 **59/59**，包括上一阶段九类业务及只读/账号打开；JVM 已读与账号偏好 **19/19**。Debug APK、平台测试 APK、两模块 Lint 通过，各 0 错误、10 个既有警告。未执行全套 App UI 或真实后端验收。

证据为 `build/verification/read-admission-*`。当前 APK SHA-256：`ed7bf95104eb1f465e9bae69dc168cde56950656d390387ced40ee37bae5c226`，设备安装包摘要匹配。21 个新增回归数据库文件已清理，保留原平台 5,596 项及 App 434 项目录内容、网络与相机设置；测试模拟器已关闭。发送与发送准备、建群、个人偏好、消息操作及资料/头像等预留适配仍待接入，通用领取、依赖和历史回收也未完成。

## 2026-11-11 建群与转发预留接入

建群与转发现在也通过通用事务入口维护预留，覆盖域增加至十三类。建群按冻结意图、成员 Codable 数组、4 KiB 进度及 64 KiB 回执计量；成员数组的计量逐项累加，不额外构建一份完整序列化清单。转发按冻结命令、1 MiB 进度证据及 64 KiB 终态回执计量。这些额度在首次联网前预留；重复点击复用原操作，未知结果、需要关注和已提交取消请求继续占额，只有允许的本地取消或经校验的终态才释放。

新增 [GroupForwardAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/GroupForwardAdmissionStorageTests.kt) 四项，验证 513 人成员清单计量、重复操作不重复收费、转发与建群共享字节额度、未知取消保留预留，以及旧库在超额时仍能恢复原操作。原有转发进度/回执和分步诊断测试也纳入回归。

本轮 API 31 定向回归 **35/35**，JVM 建群/转发测试 **18/18**；Debug APK、平台测试 APK、App/平台 Lint 通过，各 0 错误、10 个既有警告。没有执行最大规模成员清单性能、完整 App UI 或真实后端验收。证据为 `build/verification/group-forward-admission-*`；APK SHA-256 为 `c4b63169882391bfd44529acdcec5a5a5e42a60cb7965c92dbb54ce32cb9ab1f`，设备安装包摘要匹配。

本次启动时平台目录基线为 5,617 项，App 为 434 项，均按本次实际基线保留；四个新增回归数据库文件已清理并执行设备文件系统同步，网络、相机设置及原有模拟器保持不变。发送与发送准备、个人偏好、编辑/撤回/反应、资料/备注/头像等预留仍待接入；通用领取、依赖、完整持久任务诊断和历史回收继续列为未完成。

## 2026-11-11 个人偏好与消息操作预留接入

会话偏好/收藏、消息编辑/撤回和表情反应已接入共享预留，覆盖域增加至十六类记录。个人偏好与编辑/撤回按 Android 持久化命令编码计量；反应按既有命令合同编码计量。尚可合并的个人偏好和反应草稿使用最大合法修订号 `Long.MAX_VALUE - 1` 计算冻结预留，冻结后按实际修订号计量。合并导致字节增长时须取得额度，否则目标、身份、截止时间和原预留一起回滚。

这些业务原先独立的 256 项限制已移除，使用账号共享数量/字节额度；未知冻结命令仍不可通过本地取消释放预留。旧存量由源表迁移进入账本，既有领域幂等、回执与投影分离规则继续用于判断终态。

新增 [MessageOperationAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/MessageOperationAdmissionStorageTests.kt) 五项，覆盖满额冻结、未知结果取消保护、草稿变大回滚、UTF-8 编辑载荷计量、终态释放，以及 257 项收藏意图与跨业务拒绝准入。API 31 定向回归 **44/44**；JVM 个人偏好、编辑/撤回、反应测试 **27/27**。Debug APK、平台测试 APK、App/平台 Lint 均通过，各 0 错误、10 个既有警告。未执行全套 App UI、真实后端或最大容量性能验收。

证据为 `build/verification/message-operation-admission-*`。当前 APK SHA-256 为 `ec3e7622ac6daee462fa826016f932e849a8f13d85e8a6d42e4c3016f541595c`，设备安装包摘要匹配。十二个新增回归数据库文件已清理并同步文件系统；保留本轮平台 5,617 项、App 434 项基线，网络/相机设置不变，测试模拟器已关闭。发送与发送准备、资料/备注/头像预留，以及通用领取、依赖、完整持久任务诊断和历史回收仍未完成。


## 2026-11-11 发送准备、发件箱与受理投影预留

发送准备与冻结发送命令已接入共享额度，当前覆盖十八类记录。按 Android 实际持久化的 Protobuf 命令字节数加 256 字节计量；准备阶段使用最大正整数截止时间估算未来信封，包含有序媒体和富文本，冻结后转为实际字节数。最大期限仅用于计量，不会存为命令或发送到服务端。这与 Swift 的 JSON 存储编码不同，不宣称跨平台字节数相同。准备、资源原件接管、上传任务建立和准入处于同一事务；交给发件箱时仅保留一份预留。

已受理命令继续占额，直到本地存在相同消息 ID、房间和受理序号的投影，或同消息/房间的撤回记录。回执先到和投影先到均可收敛；`accepted_projection_observed` 与实际投影事务一起提交，失败一同回滚。该证据只从未观察变为已观察，后续投影清理或回执重放不会重新收费。未知提交与等待人工处理继续占额，已验证拒绝和确定未提交的到期记录释放额度。普通发送的回执写入也校验原命令身份与指纹，并拒绝覆盖已保存结果。

发件箱变化触发器只跟踪回执、恢复状态和投影观察；冻结命令不会被 SDK 改写。分页读取保持原有边界，不因页外记录的非语义更新解码整份发件箱。旧库按源表版本回填存量，超额时保留恢复和完成能力。现有发送准备/资源任务的独立保护上限仍保留；本轮不声称所有领域配额或调度策略已经与 Swift 完全一致。

新增 [SendAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/SendAdmissionStorageTests.kt) 七项，覆盖满额准备转移、字节不足时原件/上传任务回滚、受理后等待投影、序号错配及撤回证据、未知结果与确定未提交到期、错误或覆盖回执拒绝、旧库超额回填和投影事务回滚。首轮新增测试误写发送窗口，已改用正式常量；扩展历史分页回归发现页外解码问题，已收窄发件箱触发条件并重跑。文本重发用例现在验证错误回执在写入时即被拒绝，而非延迟至替换操作才拒绝。

最终 API 31 定向回归 **60/60**、JVM 发送恢复 **10/10** 通过；Debug APK、平台测试 APK、App/平台 Lint 通过，各 **0 错误 / 10 个既有警告**。证据为 `build/verification/send-admission-*`，最终设备报告为 `send-admission-platform-verified.json`。APK SHA-256：`edc0f14682743d61c8e9646537f738bfd741c689491d0da2b36892fd74f45d75`，设备实际安装包摘要一致。未执行完整 App UI、真实后端、Release 或真机验收。

本轮累计新建的 83 个回归数据库文件和 39 个资源夹具目录已按启动基线差集清理，并同步设备文件系统；平台 5,617 项、App 434 项基线保留，网络/相机设置不变，测试模拟器停止、原模拟器保留。资料/备注/头像预留、通用持久领取与依赖、完整任务快照及受保护历史回收仍未完成；Android 12 / API 31 下限不变，推送仍按用户要求暂缓。


## 2026-11-11 本人资料、资料准备与名称预留

本人资料命令、资料准备以及联系人备注/群昵称已接入共享额度，覆盖域增加至二十一类。名称和独立资料命令按 Android 持久化命令的 UTF-8 编码计量；资料准备预留当前意图、未来冻结意图和派生命令编码的最大值。准备中的上传/导入媒体标识已冻结，因此计量使用真实未来媒体标识。冻结后由原资料命令承接整份关联意图的预留，原意图不重复计数；关联行变化只按操作主键触发重算。调度状态变化不改变已准入业务载荷，未知结果保留额度及原身份。

原先独立的 16 项资料队列和 64 项名称队列上限已移除，使用共享数量/字节额度。同目标名称顺序、本人资料基线检查、原件所有权与最多 128 份保留草稿等保护仍保持。准备阶段的头像原件接管与准入原子提交，额度不足时全部回滚；原终态草稿重新申请失败也不会提前清除原草稿。经校验的终态释放操作额度，仍需用户处理的草稿及资源原件不会因此自动丢失。

更正前几节的范围表述：[Swift 群头像任务](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2GroupAvatarIntents.swift) 使用独立的 `v2_group_avatar_intents`，其冻结路径不调用通用工作准入，[普通预留统计](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2PersonalPreferenceIntentStore.swift) 也不将该表计入。因此本轮没有为 Android 群头像强加通用额度；群头像的独立任务、资源限制及恢复行为仍需按其自身合同审查，不能据此声称它已与 Swift 全面对等。当前编码计量同样不声称与 Swift JSON 编码逐字节相等。

新增 [ProfileAdmissionStorageTests](../platform/src/androidTest/kotlin/com/xmtx/im/platform/ProfileAdmissionStorageTests.kt) 六项，验证满额准备交接、未知名称/资料取消保护、有效关闭回执释放、头像字节额度回滚、65 项名称与 17 项资料队列、旧库超额恢复及重新申请失败保留原草稿。旧资料容量用例现显式配置 16 项共享额度并检查 `OperationCapacityExceeded`，保留原件选择不被消耗的验证；首轮旧用例仍依赖独立 16 项上限而失败，调整后重跑通过。

最终 API 31 定向回归 **55/55**、JVM 资料/名称 **13/13** 通过；Debug APK、平台测试 APK、App/平台 Lint 通过，各 **0 错误 / 10 个既有警告**。证据为 `build/verification/profile-admission-*`，最终设备报告为 `profile-admission-platform-final.json`。APK SHA-256：`d52d000c8fd5bcd40a9602da038e715db6d00cbd5765724971a2767be549e53e`，与设备实际安装包一致。本轮未执行完整 App UI、真实后端、Release 或厂商真机验收。

本轮 50 个回归数据库文件和 22 个资源夹具目录已按启动基线差集清理，并同步设备文件系统；平台 5,617 项、App 434 项基线保留，网络/相机设置不变，测试模拟器已停止。通用持久领取、依赖、完整任务诊断及受保护历史回收仍待完成；不能将二十一类预留适配等同于完整通用工作账本或全部 SDK 行为对齐。


## 2026-11-11 通用持久领取与名称执行接入

新增深度不可变 `OperationWork` / `OperationWorkClaim` 与明确覆盖范围的查询接口。SQLite 执行日志保存原身份/指纹、顺序、提交事实、两种自动轮次、终生尝试数、动作/时间、修订和领取所有者/随机令牌；业务命令仍存于原领域表，权威回执也不重复存储，公共日志保留其规范编码摘要。名称入队与共享额度、命令、执行元数据在同一事务提交，准入失败不留下可执行孤儿记录。

联系人备注和群昵称的真实 `NameOperationService` 现使用该日志：先持久领取再执行 HTTP；候选查询最多 32 项，每次处理最多四项。提交与核对各使用五次/六十秒轮次，显式用户重试可重置轮次但保留终生计数、原命令与服务器冷却时间。未提交到期以本地终态结束；结果未知则只能保留原身份继续核对。领取仍被持有时，三十秒租约到期本身不会让另一执行者接管，原所有者也不能靠时间再次领取。

`recoverAfterPreviousOwnerDrained()` 是明确的生命周期前置条件，不是定时抢占。App 已在旧业务任务及账号 runtime 排空后调用它；独立 SDK 调用者重建执行者时也须先取消并等待旧物理任务。接管只恢复核对，不制造新命令。非权威失败回调必须匹配当前所有者、令牌和修订；经领域校验的原身份回执可以在旧领取失效后完成操作，之后迟到失败不会改写终态。任务取消及外层超时在物理子任务退出后以不可取消写入释放领取，保留未知结果；若进程在该写入前中断，下次显式所有者接管继续恢复。

依赖表最多接受 32 个互异、已存在的父任务，禁止自身依赖及后改父集合；父任务必须已提交完成才满足执行条件，缺失父记录不视为完成。顺序前驱和依赖在领取事务中再次检查。当前名称实际入队没有跨领域父依赖，其他业务的资源/命令依赖仍需逐个接入；不能将内部依赖测试视为全 SDK 调度完成。

旧名称记录只迁移未完成工作，保留原命令、未知状态和冷却时间。旧格式混用一个轮次计数，迁移时保守计入两种轮次；无法还原的原始创建时间返回 `null`，不伪造年龄。新操作保存实际创建时间。旧已完成历史仍保留在原表，本轮不补造完成时间；新的通用任务所引用名称载荷不再被原先的数量裁剪删除，受保护七天历史回收仍待完成。`operationWorkKinds` 目前仅为 ContactAlias / GroupNickname，敏感准入等其他领域尚不能使用这份领取策略；它也还不是完整 Swift 通用调度器或 `V2AccountWorkSnapshot`。


新增 [领取策略测试](../clientkit/src/test/kotlin/com/xmtx/im/client/OperationWorkClaimPolicyTests.kt) 三项和 [SQLite 执行日志测试](../platform/src/androidTest/kotlin/com/xmtx/im/platform/OperationWorkStorageTests.kt) 六项，验证双所有者竞领、过期租约不抢占、重开与明确接管、旧失败拒绝/原回执收敛、真实服务调用的取消及外层超时、独立轮次与终生计数、冷却保持、共享额度回滚、旧库未知创建时间、未提交到期零 I/O，以及顺序/依赖和有界候选。

最终 **JVM 9/9、API 31 平台 32/32、App 7/7** 通过；App 集合覆盖真实开库、旧库恢复及退出启动，不代表完整端到端业务验收。Debug 与两个 instrumentation APK、App/平台 Lint 通过，各 **0 错误 / 10 个既有警告**。证据为 `build/verification/operation-work-*`，最终报告为 `operation-work-platform-final.json` / `operation-work-app-final.json`。APK SHA-256：`18f48b8a5046daaf32d088433f56525b5dc1b423a3685b0c28153d9306547fc6`，与设备安装包一致。未新增真实后端名称请求、App 冷进程遗留领取、全量调度压力、Release 或真机验收。

六个回归遗留的新建数据库文件已清理并同步设备文件系统；平台 5,617 项、App 434 项启动基线保留，网络和相机设置未变，无 IM 系统任务及 ADB 转发。测试模拟器已停止，原模拟器保留。整体 SDK 对齐目标保持进行中，不能把两种名称操作的通用执行接入扩大表述为所有操作已经迁移。


## 2026-11-11 本人资料执行与领域隔离

`ProfileUpdate` 接入通用日志，`operationWorkKinds` 当前为 ContactAlias / GroupNickname / ProfileUpdate。[OwnProfileService](../clientkit/src/main/kotlin/com/xmtx/im/client/OwnProfileService.kt) 的实际执行使用持久领取、独立提交/核对预算、终生计数与冷却；直接保存和头像上传/导入准备完成后的冻结交接，均在原业务事务中登记执行元数据。资料意图的重试也经过共同执行记录，避免只重置旧领域字段。

名称与资料分别拥有服务所有者；恢复必须先排空旧服务，并且只恢复自己负责的操作种类。候选种类在 SQL 的 LIMIT 之前过滤，避免其他领域的前三十二项把资料候选挤出窗口。同一账号的资料命令继续按原顺序执行；未提交到期不产生网络请求，保留可重新应用的草稿并释放操作预留。

[资料领取适配](../platform/src/main/kotlin/com/xmtx/im/platform/SqliteOwnProfileClaims.kt) 在同一事务验证回执、完成执行记录、更新资料投影及交接资源消费者。旧失败不能覆盖新领取；原身份的有效回执仍可结束操作。通用完成摘要只包含规范化原回执，之后查询附带更新的 `currentSnapshot` 不会改写原结果；重复确认保留已处理草稿状态。伪造的解码结果与 wire 不一致时整个写入回滚。

旧未完成资料按批迁移，无法恢复的创建时间保持未知，旧混合尝试数保守计入两个自动预算。新冻结命令记录实际冻结时间，新的执行记录引用的资料载荷不会被原先的数量裁剪移除；受保护历史回收仍待实现。其他领域的执行适配、真实依赖、通用公平调度和完整持久任务诊断仍未完成。

新增 [资料执行测试](../platform/src/androidTest/kotlin/com/xmtx/im/platform/OwnProfileExecutionStorageTests.kt) 五项，并扩展既有头像原件交接测试。最终 **JVM 16/16、API 31 平台 59/59、App 7/7** 通过；Debug、两个 instrumentation APK 与 App/平台 Lint 通过，各 0 错误、10 个既有警告。首轮新迁移夹具错误使用了不足二十四小时的截止时间，已修正后重跑全部受影响平台集合；原失败日志保留。证据为 `build/verification/profile-execution-*`，汇总为 `profile-execution-summary.json`。APK SHA-256：`ea8bdeed39e57454caa1beaca8155ad26ebea2843a48e79c18795f122d94a2ad`。本轮没有新增真实后端、App 冷进程遗留领取、完整 UI、Release 或真机验收。Android 12 / API 31 下限不变，推送暂缓。

本轮清理 50 个新增数据库文件和 22 个资源目录，保留平台 5,617 项、App 434 项原目录基线及设备设置；安装 APK 摘要一致，设备文件系统已同步，测试模拟器停止，原模拟器保留。

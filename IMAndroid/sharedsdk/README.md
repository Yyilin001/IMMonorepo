# Kotlin 调用共享 Swift SDK

`sharedsdk` 提供 `suspend` API 和不可变快照 `Flow`。它依赖 `swiftplatform`，不依赖原 Kotlin `clientkit`。账户认证、设备凭据签发、刷新、恢复账本、Protobuf、SQLite 同步及连接代次管理均使用 Swift 共享运行时。

第十二阶段将应用级组合移入平台无关的 `IMV2SharedRuntime`，由 `IMV2SharedAndroid` 注入原有系统能力。`libIMV2SharedSDK.so`、JNI 方法、Kotlin API、凭据命名空间及 Release 压缩策略保持不变；macOS 通过另一个平台适配复用同一业务。桌面验证与 Windows 缺口见 [桌面接入说明](../../experiments/swift-desktop/README.md)。

第十三阶段进一步复用 `V2SharedSession` 的登录、存储和退出所有权，iOS 通过原生 Swift 接口接入；本模块的 JNI/Kotlin API 与持久化命名不变。

## 独立会话窗口（第十四阶段）

会话列表和时间线读取已交给共享 `V2ConversationService`，Kotlin 不执行数据库查询、权限过滤或摘要恢复。原有 App 快照调用保持兼容；多窗口使用独立句柄，彼此不修改默认 `selectedRoom` 或分页位置：

```kotlin
val window = client.openMessageTimeline(roomID, pageSize = 50)
try {
    render(window.snapshot())
    // 用户操作可调用 window.nextPage() / window.reset()。
    window.states().collect { render(it) }
} finally {
    window.close()
}
```

列表入口为 `openConversationList(isArchived, pageSize)`。每个窗口允许一个 Flow 收集者，需要独立观察时另开窗口；取消收集只取消当前等待，关闭窗口释放 Swift 观察者。`states()` 在 Swift 投影变更时完成等待，不以 500ms 请求全量快照；C ABI 操作结果仍使用现有 10ms 完成检查。账号关闭后旧句柄失效。原有 `foregroundStates()` 的前台连接管理与轮询策略本阶段未修改。

跨语言内部操作新增 `openListWindow`、`openTimelineWindow`、`readWindow`、`watchWindow`、`nextWindowPage`、`resetWindow`、`closeWindow`；后五个传 `windowID`，返回同名字段。窗口查询不占用账号变更的串行锁，关闭和取消能够结束正在等待的观察。验收见 [第十四阶段](../../experiments/swift-desktop/verification/phase14/RESULTS.md)。

## 共享消息业务（第十五阶段）

`sendText`（含回复）、`editMessage`、`withdrawMessage`、`forwardMessage`、`reactMessage` 以及对应重试/取消操作均进入 Swift `V2MessageService`。附件发送先沿用资源适配器准备文件，再通过同一门面冻结消息和上传依赖。原有 Kotlin 调用、JSON 请求和页面反馈保持兼容；未新增 Kotlin 业务逻辑。最终结果仍以同步投影与持久化操作状态为准，取消等待不撤销已经保存的发送。关闭或退出账号会排空门面，旧原生服务不能再提交新消息。真实后端证据见 [第十五阶段](../../experiments/swift-desktop/verification/phase15/RESULTS.md)。

## 共享搜索和回执业务（第十六阶段）

现有 `searchMessages`、可见消息上报、回执重试及群已读详情绑定进入 Swift `V2SearchService` / `V2ReadReceiptService`，与 iOS 原生接口使用相同服务。Kotlin 接口和页面保持兼容；索引、权限、序号解析、持久化合并、执行和恢复均在共享 Swift 层。搜索不会发布已读，撤回或过期视口行不会导致整批上报失败。具体覆盖与限制见 [第十六阶段验收](../../experiments/swift-desktop/verification/phase16/RESULTS.md)。

## 构建与 App 入口

```sh
python3 experiments/swift-android/build_probe.py --shared-sdk
JAVA_HOME="$(/usr/libexec/java_home -v 17)" IMAndroid/gradlew -p IMAndroid \
  :app:assembleDebug
```

构建器输出独立 `libIMV2SharedSDK.so` 及依赖至 `sharedsdk/build/native/arm64-v8a`，不包含 Probe 的测试操作；输入、工具链及动态依赖摘要保存在 `experiments/swift-android/build/shared-sdk-manifest.json`。当前支持范围为 Android API 31+、arm64；App 明确限制 arm64，其他 ABI 的系统不能误装后才发现缺少 Swift 库。

App 默认且仅使用 `SharedAppViewModel` / `SharedApplicationContent`，旧 Kotlin `clientkit` / `platform` 及旧业务入口已移除。不存在 `imSharedSDK=false` 回退。当前支持会话分页、文本消息收发、持久发送状态、联系人、群管理、退出和切换账号；详情使用 Navigation 3，三标签共享详情栈。

音视频播放、群元数据编辑、深链接跳转、提前解除禁言、Passkey、系统后台任务及旧数据迁移尚未接入；不宣称全量功能等价。`close()` 是释放所有者，保留凭据；`signOut()` 才是持久退出。

## 公共接口

```kotlin
val client = SharedClient.open(applicationContext,
    SharedEndpoint("https://account.example.com", "gateway.example.com", 7443))
try {
    val state = client.restore() // 本地凭据与数据库恢复，无密码重放
    if (state.state == SharedSessionState.SignedOut) {
        client.login(account, oneTimePassword)
    }
    // 调用方使用自己的前台生命周期 scope 收集；只允许一个前台收集者。
    client.foregroundStates().collect { snapshot ->
        // 不可变快照，不含访问令牌、刷新凭据或撤销证明。
        render(snapshot)
    }
} finally {
    client.close() // NonCancellable 清理：取消、排空 Swift/JNI、关闭 SQLite
}
```

也可显式使用 `connect()`、`disconnect()`、`synchronize()` 和 `snapshot()`。生命周期变更通过 Mutex 串行，Swift actor 再用 busy 栅栏拒绝跨 await 的重入；只读快照有界。`foregroundStates()` 在传输故障后先 stop/drain，再重建认证连接，退避从 1 秒增至最多 30 秒；取消收集会关闭实时连接，认证错误停止重试并交给调用方处理。

`SharedSnapshot` 包含阶段、用户 ID、应用/确认水位、认证连接次数、会话标题/预览、聊天窗口和可空的陌生人消息偏好。账户 ID 和资料仍属于用户数据，调用方不应随意记录；诊断接口 `activeOperationCount()` / `activeClientCount()` 只包含数字。`SharedSdkException.reason` 提供固定错误分类，不透传原始服务端正文或凭据。

## 所有权、取消与持久化

- 每个客户端的存储命名空间绑定账户 HTTPS origin 和网关地址，位于 `noBackupFilesDir/shared-sdk`；不复用原 Kotlin SDK 的凭据或数据库。一个进程内同一命名空间最多一个所有者。
- Swift `V2ClientSessionBootstrapper` 处理签发结果收养及账户存储归属；Keystore 保存凭据与独立恢复账本。未完成的签发、取消和撤销责任在本地持久化，当前进程拥有的恢复 runner 会在 close 时排空，下次打开继续恢复。
- JNI 传有界 UTF-8 请求与不透明数字句柄。最多 8 个客户端和 128 个在途/待释放操作；不传 Swift 对象指针。Kotlin 取消会传到 Swift Task；结果只在物理 I/O 与子任务清理后发布，之后才允许 release。
- `open()` 的取消也会关闭已创建但尚未返回给调用方的客户端。`close()` 可重复调用，并等待当前操作排空；不会用超时直接释放仍被 Swift 使用的句柄。
- 当前跨语言 ABI 使用内部 JSON 编解码，等待结果每 10ms 检查一次；前台状态快照每 500ms 获取一次。它是第一版绑定，不宣称已经完成回调式推送或高吞吐性能优化。

账户 HTTP 使用 `V2AndroidAuthHTTPTransport` / OkHttp，以 Android 系统和应用 network-security-config 校验证书；禁止自动重定向、重试、磁盘缓存和日志。请求体最多 512 KiB，响应体最多 2 MiB，完整调用期限 15 秒。密码断言、签发、刷新和撤销的业务编码仍在 Swift；Android 只执行 HTTPS。实时连接仍使用第三阶段的 TLS 1.3 适配。

本模块不修改 Apple 的默认 HTTP、TLS、Keychain 或后台会话实现。iOS 继续使用 `IMV2ClientKit` 门面。

## 真实后端验收

先启动仓库的隔离 PostgreSQL、账户服务、HTTPS edge、placement quorum 与真实网关：

```sh
python3 IMV2/scripts/verify_v2_isolated_native_account.py --check
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
```

该脚本使用预先构建的真实服务端可执行文件；缺少时先按脚本提示构建。读取它输出的 `test-endpoints.json`，在明确选定的 API 31 arm64 设备执行：

```sh
python3 IMAndroid/scripts/verify_shared_sdk.py --serial <设备序列号> \
  --endpoints <隔离后端/test-endpoints.json> --output <证据目录>
```

驱动构建专用 `.sharedverification` App，仅在该 Debug 构建加入本次 CA，通过自己拥有的 adb reverse 访问真实后端，并使用透明 TLS relay 做远端断线注入。它不会清空正常 App，也不修改设备或系统信任库；Release 不加入测试 CA。默认 Android 测试集合跳过这个显式后端用例，验收驱动要求完整成功及实际设备证据，不能把跳过算作通过。

验收走真实 `MainActivity`：错误密码拒绝 → 登录与会话列表 → 对端消息显示 → App 发出文本并由真实对端确认只出现一次 → relay 断线后入队 → App 所有者关闭、重开恢复同一发送 → 重连送达 → A→B 的私聊/草稿隔离 → B 退出后重新打开仍未认证 → 再登录 A 收到 B 回复 → 阻塞 HTTPS 登录取消和资源排空。详细证据见 [第五阶段结果](../../experiments/swift-android/verification/phase5/RESULTS.md)。

## 会话、消息与退出

- 会话每页 50 条：`nextConversations()` / `firstConversations()`，使用 Swift SQLite 稳定游标。快照提供是否还有下一页。
- `openConversation(roomID)` 需要当前账户具有本地读取权限；不存在或越权房间拒绝。消息每页 50 条，`olderMessages()` / `latestMessages()` 切换有界窗口；不在 Kotlin 重建投影。
- `sendText(roomID, text)` 只冻结并持久交接发送，不把本地入队当作服务器成功。共享 dispatcher 使用原操作身份提交/确认；断线进入等待连接，重连唤醒；`retrySend(intentID)` 只恢复原发送确认，不生成新消息。
- 快照从同一 SQLite 读取版本取得已投影消息和待发送记录，避免回执收敛时丢失或重复气泡。发送历史有界分页：`nextPending()` / `firstPending()`；已撤回消息不输出原正文。当前 UI 只渲染文本和附件提示。
- 取消前台 Flow 关闭连接，账户 dispatcher 由客户端所有者持有；`close()` 排空两者再关闭 SQLite。跨语言结果上限 8 MiB，超限返回固定错误，不分配无界 JNI 结果。
- 调用 `signOut()` 前停止前台收集。退出先在 Keystore 持久保存意图，再使认证代次失效，停止并排空发送和实时任务，关闭数据库，持久交接远端撤销、删除本机凭据及待注册记录，最后清除意图。该本地收尾不可被调用方取消截断，网络撤销由共享持久 runner 重试。
- `restore()` / `login()` 遇到未完成退出会先完成清理，失败不允许打开旧账户。App 退出立即撤下页面，失败保留“重试退出”；账号切换使用退出后重新登录，页面、草稿与结果按账户代次隔离。旧数据库不跨账户复用，也不会把网络不可用误当作删除凭据的理由。

## 联系人与群组（第六阶段）

- `SharedSnapshot.directory` 是不可变的目录和管理快照。`contacts(scope)` / `nextContacts()` 与 `firstGroups()` / `nextGroups()` 使用共享 SQLite 游标，每页 50 条。成员通过 `openGroup(roomID)` / `nextGroupMembers(roomID)` 按需读取，不在 500ms 快照轮询中发 HTTP/目录请求。
- `lookupIdentity(handle)` 精确查询公开账号。名称只在 Swift 的单调时钟授权窗口内展示，不写成永久联系人资料；离开查找页或后台时调用 `clearDiscovery()`。联系人授权资料由第七阶段管线提供，成员仍显示用户 ID。
- `socialAction` 使用共享社会关系服务；`openDirect` 只能使用当前仍有效的查找目标。`createGroup` 使用持久建群服务，最多接受 100 个初始成员 ID。
- `groupAction` 携带用户确认时所见的成员、公告或角色策略修订号。Swift 服务负责准入、冻结命令、提交及回执验证；Kotlin 不重新计算指纹、期限或权限，不自动替换冲突修订号。权限基线由共享恢复 runner 补齐。
- `works` 显示服务端收敛状态；提交返回不等于成功。`retryDirectoryWork(id)` 只确认原身份；未冻结且暂停的草稿可 `discardDirectoryDraft(id)`，之后刷新并由用户重新操作，不自动续期。
- 目录操作、成员/能力准备 runner 和观察任务均属当前账号；关闭或退出会取消并排空，再关闭 SQLite。页面切换仅影响展示，已持久交接的操作继续由账号运行时处理。
- 真实 App 验收使用 `verify_shared_sdk.py --phase 6`，独立对端也调用同一共享 SDK，测试夹具仅注册账户。结果见 [第六阶段验收](../../experiments/swift-android/verification/phase6/RESULTS.md)。

## 资料、邀请和禁言（第七阶段）

- `openProfile(userID)` / `saveAlias(userID, alias, revision)` 复用 `V2ProfilePresentationRepository` 和 `V2NameOperationService`；空备注表示删除。确认使用展示时的原修订号，冲突后不自动覆盖。联系人一页最多 50 个授权条目；无授权时回退用户 ID。
- Swift 验证资料页面授权、资料失效记录、头像原始 grant、字节数和 SHA-256；头像请求仅携带对象能力，不携带账号凭据。最多读取 2 MiB，跨绑定只传有期限的内存图片，不输出 URL/对象凭据、不写磁盘缓存。Kotlin 仅解码显示，并用调用开始时刻加剩余期限得到保守的单调时钟截止值。
- `invitations` / `nextInvitations`、`previewInvite` / `refreshInvite` 和 `inviteAction` 复用邀请查询与持久操作服务。App 支持粘贴邀请链接或邀请码、查看、申请/取消、创建一小时且最多批准 10 人的邀请、系统分享、撤销、批准/拒绝。取消或被拒绝的申请需使用新邀请，不能重新提交旧邀请。
- 邀请 bearer 仅作为用户请求的分享内容或当前预览输入；不放进导航路由、保存状态或日志。持久申请引用保存在 SQLite，secret 单独由 Keystore 加密存入 noBackup，按安装绑定、账号和引用隔离。邀请 DTO 的 `toString()` 隐去 bearer。离页、后台、关闭或退出清理 SDK 展示状态；已持久交接的操作仍由共享服务处理。
- `muteMember(roomID, userID, revision)` 使用 `V2MemberAdministrationOperationService`，沿用现有 iOS 一小时禁言和 `group_rules` 原因。权限、冻结、重试和回执都在 Swift；UI 提交不代表成功，展示同一持久操作结果。
- 新服务加入当前账号 dispatcher，观察和准备任务在关闭时取消并排空。Android 平台 HTTP 增加共享备注接口需要的 `PUT`；Apple 默认传输和既有 iOS API 不变。
- 真实后端验收及第五、六阶段回归见 [第七阶段结果](../../experiments/swift-android/verification/phase7/RESULTS.md)。

## 头像编辑与二维码（第八阶段）

- `openAvatarEditor(roomID?)` 读取个人/群头像编辑状态；`roomID = null` 表示当前用户。`changeAvatar(roomID, revision, jpeg, width, height)` 接收设备裁剪后的有界 JPEG（不传图片则移除）。`avatarAction` 使用类型化动作，查询或重试原操作；个人资料冲突后的重新应用需用户明确确认。
- `SharedAvatars` 组合现有 `V2ResourceCenter`、`V2ResourceTransferEngine`、`V2ProfileIntentService` 与 `V2GroupAvatarIntentEngine`。原件、传输与资料/群头像命令由共享 SQLite 原子交接；上传目标及账号认证不进入 Kotlin 业务模型。群管理重新读授权，但不替换用户确认的修订号。
- Android 使用系统选图，读取源文件最多 10 MiB、解码长边最多 2048；裁剪支持缩放和水平/垂直位置，预览后明确上传。导出为 512×512 JPEG、最多 512 KiB，去除源图片元数据。此阶段不提供拍摄新头像、通用大文件或后台系统传输。
- 有界绑定请求上限由 64 KiB 增至 1 MiB，以容纳编码后的图片；响应上限仍为 8 MiB。对象 PUT 仍受平台请求体 512 KiB 限制，使用计划自己的凭据，不混入账号头。关闭时先取消并排空头像/资源任务，再关闭 SQLite。
- Android 私有文件目录的既有祖先先解析为规范路径，再附加尚不存在的资源目录，避免 `/data/user/0` 与 `/data/data` 的别名造成错误拒绝；Apple 路径处理保持原样。原有子目录符号链接拒绝检查保留。
- Android SELinux 禁止应用数据硬链接，因此头像原件统一存放在账号私有资源目录，缓存/保留分类、配额、淘汰与恢复仍由共享资源账本管理；切换保留状态不改变文件路径，不复制负载，也不使现有租约失效。系统不会自动清理这些缓存原件，由 SDK 配额淘汰；传输临时文件仍在缓存目录。iOS 的硬链接布局与行为保持原样。通用文件展示/导出别名尚未开放给 Android。
- 相机使用 [ZXing Android Embedded 的 ScanContract](https://github.com/journeyapps/zxing-android-embedded)，仅识别 QR、关闭扫码图像保存和提示音，按需请求相机权限。无相机权限可选二维码图片；像素解码后原字符串直接交给 Swift `previewInvite`，不会自动打开网址或自动提交入群。扫码与选图代码只处理设备 I/O 和图像，不实现邀请、HTTP、持久队列或业务授权。
- 后台/离页撤下授权图片和临时编辑数据；返回选图后重新读取头像权限。账户切换销毁旧页面所有者，旧图像任务不能向新账号提交结果。
- 设备验收和实际限制见 [第八阶段结果](../../experiments/swift-android/verification/phase8/RESULTS.md)。


## 图片、文件与传输任务（第九阶段）

- `importAttachment` 将设备输入流按 64 KiB 传入 Swift，最大 32 MiB。Swift 使用账号私有临时文件、资源导入和持久选择身份；`sendAttachment` 将上传依赖和消息意图原子冻结，原有传输与消息引擎推进。临时选择在离开、后台或关闭时清理；空标记使崩溃后未发送选择也能释放，不动已交接给上传的原件。
- `SharedMedia` 与头像共享唯一 `V2ResourceCenter` 和上传引擎，接入原有发送准备调度、Range 下载、SHA-256 校验、缓存授权和持久恢复；没有另建业务数据库或 Kotlin 发送队列。
- 下载策略通过 Swift task-local 传给平台适配器，不依赖 Android Foundation 会丢失的 URLProtocol 请求属性。Android 根据计费网络、蜂窝和 Data Saver 约束选择网络，使用 [Network 的 socketFactory 与网络内 DNS](https://developer.android.com/reference/android/net/Network) 绑定实际连接，并在读取每块前重新检查策略。通用 URLSession 适配器在 Android 上仍拒绝受限策略，不能静默放宽。
- 平台 `V2AndroidStreamingHTTP` / OkHttp 只处理流式 HTTPS 字节，响应头先交给 Swift 验证，再以 64 KiB 分块读取。上传文件路径只在 Swift 与平台之间流转，不出现在 App DTO。保持系统/应用证书信任，禁用跳转、自动重试、缓存及日志；同一取消句柄等待实际 I/O 退出再释放。平台不可用映射为传输失败；对象 HTTP 状态、Retry-After 和过期计划交给原有 Swift 有界恢复策略处理。
- App 支持图片选取（保持长宽比、长边最多 2048、编码 JPEG 去除元数据）、文件选取、附件发送、图片缩略预览、下载原件及 `CreateDocument` 保存。保存通过 256 KiB SDK 分块，每块重新借用授权文件；失败尝试删除未完成的输出文档。外部保存副本由用户所选位置管理，不属于 SDK 缓存。
- 消息 DTO 的 `attachments` 为不可变列表，只含服务端媒体身份和展示元数据。资源页面不接收 URL；Swift 验证消息归属和授权。图片内存展示受原目标期限约束，后台、离页和账号切换撤下。
- `transferAction` 使用类型化动作，权限由共享资源服务控制。任务页当前展示最近 50 项，不宣称完整资源目录、批量多附件、音视频播放、系统后台传输或通用外部文件打开已完成。
- Android Range 临时文件使用私有权限及既有 noBackup/cache 目录，不设置 Apple 备份资源属性；Apple 分支保持原样。导出直接读取有授权的租约，不依赖 Android 不支持的硬链接展示/导出别名。
- 验收与边界见 [第九阶段结果](../../experiments/swift-android/verification/phase9/RESULTS.md)。

## 第十阶段：搜索、编辑撤回与已读回执

- `SharedMessaging` 仅组合现有 `messageSearch`、`V2MessageMutationOperationService`、`V2ReadReceiptOperationService` 和统一任务分发器；同账号索引随会话启动、关闭时排空。没有 Kotlin 索引、数据库、业务队列或协议副本。
- `searchMessages(query, roomID?)` 查询本设备已同步且仍授权的内容；每页 20 条，`nextSearch` 使用 Swift 持有的游标。索引构建、失败和游标失效单独展示；当前页刷新重新验证结果，编辑旧文本和撤回内容不会继续作为搜索命中显示。`openConversation(roomID, messageID)` 通过授权的时间线窗口定位，可离开最近 50 条窗口。
- `editMessage` / `withdrawMessage` 带上用户看到的消息修订号；Swift 验证当前账号、消息归属、读取权限和版本，原有服务持久冻结操作并确认结果。修改只在同步投影后替换正文，不乐观覆盖；冲突/拒绝保留原任务与编辑文本，用户主动重新编辑。`retryMessageAction` 延续已有身份。
- `markVisibleMessages` 只接收 Compose 可见区域中的消息 ID，Swift 查询授权消息并以 **roomSequence** 合并已读意图，不使用时间线序号或同步 ACK。已撤回占位或已失效引用会跳过，避免异步投影变化使整批上报失败。前台恢复/滚动可重复报告，原有服务去重；搜索列表不报告已读。私聊仅在服务端披露许可有效时标记“已读”，其他情况显示“已发送”。
- 群消息作者可通过 `messageReaders` 查看服务端已过滤的阅读者，每页 50 个用户 ID，30 秒后隐藏旧页并要求刷新；当前不取回成员资料或宣称列表等于全部实际阅读者。后台、退出、离页清理搜索/阅读者展示。现有 SDK 和服务器已读隐私策略仍生效，本阶段未新增隐私设置页面。
- `SharedMessagingView` 与消息 DTO 使用深度不可变集合；Kotlin 只做 JSON 绑定、导航、编辑确认和可见区域事件采集。验收范围见 [第十阶段结果](../../experiments/swift-android/verification/phase10/RESULTS.md)。

## 第十一阶段：回复、转发和表情回应

- `sendText(roomID, text, replyToMessageID)` 使用既有 `V2MessageSendOperationService` 冻结回复引用和正文，继续按原发送身份恢复。Swift 验证同会话且仍可读的原消息；快照按当前授权解析引用预览，撤回或失效后不再展示原文。Android 提供回复确认框和引用定位。
- `forwardMessage` 仅传源房间、消息 ID、用户选定版本和目标房间，不在 Kotlin 复制正文、媒体或构造转发协议。`V2ForwardPlanOperationService` 持有整份计划、幂等身份、进度、重试和取消剩余操作。首期页面一次转发一条消息到一个已有会话，支持原消息附件；目标会话可分页选择。
- `reactMessage` 传明确的添加/移除目标状态；`V2MessageReactionOperationService` 合并未冻结意图、获取服务端版本并执行或恢复。界面提供六种常用回应入口，也显示服务端同步来的其他回应，点击计数可添加/移除自己的回应。聚合人数和本人状态由共享 SQLite 展示查询提供，Kotlin 不维护计数。
- `SharedInteractionView` 每类最多展示 50 项状态，包含转发成功/拒绝/取消/未决数量以及重试、取消能力；退出账号排空准备、观察和执行任务。页面先显示真实已同步状态，未确认的回应单独显示为操作记录。
- 当前回复编辑框只发送非空文本；未接入多选批量/多目标转发、合并转发、回复附带附件或完整自定义表情选择器。转发来源显示为标记，不提供跨房间原文跳转。验收与限制见 [第十一阶段结果](../../experiments/swift-android/verification/phase11/RESULTS.md)。

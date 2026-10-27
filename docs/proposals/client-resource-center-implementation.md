# 客户端资源中心实施记录

目标：[完整方案](client-resource-center-plan.md)。不考虑历史兼容性；目标保持完整，不以以下阶段性成果替代交付。

## 当前状态（2026-10-24）

**P1/P2/P3 与 P5 的数据链路正在实施；聊天附件和头像的实际上传原件、下载已接入统一文件所有者，尚未开放资源中心页面，未安装或发布新资源中心。** 当前手机和服务器未因本轮工作被清库或重新部署。

### 已有代码

- Core 的 `ResourceDescriptor.swift`：资源身份、规范化展示名、有验证的持久描述，解码复用验证；ready 资源必须有摘要。
- ClientKit `Resources/GRDBV2ResourceDirectory.swift`：规范 schema、描述/引用事务、多个来源去重、独立版本下界、撤销先于内容的处理、按类型/会话/名称过滤和稳定分页。
- `Resources/GRDBV2ResourceCatalog.swift`：与账号同步库共用 writer 的文件索引、文件依赖及发布/删除 journal。
- `Resources/V2ResourceFileStore.swift`：有界复制、完整性校验、文件/目录同步、rename 后发布、三个发布边界恢复、保留/原件保护、消费者借用、清理计划提交前复核、实际删除计数及关闭等待借用结束。
- `Resources/V2ResourceCenter.swift`：账号归属核验、本地目录快照、最新值缓冲、读取代次防迟到结果、关闭观察与文件消费者。
- 投影观察器新增 `.resources` 作用域：资源表变化不再通过 unknown-table fallback 刷新全部会话或撤销展示资格。
- schema 直接加入当前新库定义，无历史读取器和迁移兼容路径。
- 上传请求要求展示名；App 照片/文件、群头像和失败替换保留展示名，服务端持久化到 resource_catalog；导入和跨 owner 转发也传递展示名。
- `GRDBV2AcceptedResourceBindings`：在真实发送接受回执的同一事务内，用真实 messageID 绑定已确认 ready 的本机上传；未接受的上传不进入聊天资源目录。撤销版本和本地墓碑阻止旧回执/迟到页恢复资源。
- `POST /v2/rooms/{roomID}/resources/query`：HTTP 鉴权后经 RoomRef/Actor 查询，使用现有成员区间和编辑可见性规则；游标绑定账号、会话、筛选和快照，逐页重新授权。只返回描述和来源，不返回对象地址。
- 附件绑定新增受数据库触发器验证的 room/sequence 列和部分索引；规范 schema 与 readiness/SQL contract 同步更新。
- `V2HTTPRoomResourceDirectoryClient`、`GRDBV2ResourceDirectorySync`、ResourceCenter.synchronize：有界响应验证、扫描代次、目录/引用/继续游标一次提交，支持继续分页并拒绝过期响应；关闭会取消并排空网络及事务准入。
- 目录访问代次与成员状态、消息授权、撤回/编辑、墓碑、屏蔽和快照切换关联。在途分页不能越过权限代次；服务端拒绝也会阻止本地目录继续展示该会话。真实快照激活测试验证新 live 表的触发器继续生效。
- `V2ResourceDownloadCache`：每位调用者先获取当前授权，再复用账号内已验证字节；同摘要/大小的传输合并，缓存版本和别名持久化。换版本后停止旧 handle 的新借用，已经开始的真实消费者继续持有原文件。头像按 variant 区分。
- 下载的稳定随机暂存路径、Range 部分文件和预留容量计入同一 journal；中断重建后使用新授权恢复同一暂存路径。每个下载在网络开始前持久预留源文件和未来发布副本，发布事务将副本额度交给文件记录，不产生空窗或重复计费；清理预览包含不活跃暂存，跳过真实生产者和借用者。
- 损坏的已发布文件和中断 rename 可隔离为 invalid，不再污染字节去重；保留文件和原件不因校验失败被自动删除。实际占用仍被统计；借用、过期和容量淘汰读取 journal 事实，不信任文件 mtime。
- App 账号激活时创建 ResourceCenter，并为真实聊天附件、个人/群头像下载装配同一 cache。`V2ConversationMediaDownloadService` 已移除独立缓存路径、索引、清理器和借用计数，只保留展示接口桥接。正常关闭保留缓存，并等待传输和真实文件消费者结束；账号退役仍由既有 incarnation 生命周期执行删除。
- 系统后台文件发布改为受管文件层验证复制后，由协调器删除其收件文件并提交完成；覆盖复制和原移动语义的测试。尚不代表锁屏或真实 OSS 后台链路已经验收。
- 后台 reconciliation 对创建/安装/恢复中的系统任务保留保护，取消前重新读取真实任务，孤儿任务判定重新核对 journal，防止先前快照把新任务误判为消失。并发取消验收保留物理额度直到真实 drain；测试驱动使用与原生 URLSession 一致的多等待者唤醒。
- 本地原件基础：`V2LocalResourceAsset` 以独立资产 ID 保存显示名、已验证 MIME、摘要、大小和用途（具体会话草稿/个人头像/群头像），不持久化导入源 URL。导入先记计划，再由同一 FileStore 发布和绑定；崩溃后只有已完整发布的字节可恢复为可用资产，部分文件不能变成可用草稿。
- 持久文件依赖区分 selection、upload、profileIntent、manualOriginal 和普通 hold。草稿与上传即使采用同一 UUID，也有各自的命名空间；事务交接不再依赖文件名碰巧不同。实际发送/个人头像/群头像冻结已使用同库绑定；替换操作显式继承原消费者，旧上传释放不能移除新上传的保护。
- `v2_resource_file_pins` 保留文件层显式保护用途；用户入口已改为按逻辑 variant 保存到 `v2_resource_retention_intents`，不是给物理 fileID 打标记。`V2ResourceFileRecord.isPinned` 同时派生显式文件保护和所有逻辑保留；原件依赖优先决定 original，依赖结束后再派生 retained/cache。
- ResourceCenter 已提供导入、草稿原件查询、独立借用、丢弃选择，以及保留/清理计划/提交入口。`V2FileConversationAttachmentStager` 现为平台导入桥接，持有 security-scoped 访问到导入结束；不再管理独立原件目录或启动扫描器。正常关闭不会删除原件。
- TransferEngine、发送服务和群头像管理不再拼原件路径或保存 file token；Job/PreparedUpload/个人头像 intent 持有强类型 LocalAssetID，实际上传通过 `.upload(jobID)` 借用，个人头像预览通过 selection/profileIntent 资格借用。原件依赖释放为同库事务，不再由引擎 unlink 文件。
- 原上传分片辅助器已删除；FileStore 由真实源 lease 创建前台及后台有界切片，计入同一账号暂存预算，上传执行器只消费切片，不自行复制或删除。后台上传已移除独立目录扫描和全局 budget；后台下载 inbox 仍需后续收敛。
- 待释放原件进入账号 preparation 调度：消息 ACK 或头像提交闭合会唤醒依赖释放，不必等下一次发送。结果未知、未闭合业务仍保护源；独立业务可各自释放而不影响共享 blob 的其他依赖。
- 聊天附件、个人头像和群头像恢复本机选择。群头像页面展示尚未提交的草稿、受管缩略预览、继续提交及移除；提交失败前未冻结的选择保留，冻结后从选择列表消失并由上传独立持有。聊天重复刷新不重复加入草稿。
- 个人头像导入用选择代次阻止取消/移除后的迟到结果重新出现；导入期间禁止保存。选择清理可由已取消调用者执行，且只释放自身依赖。OperationScope 对成功产出但因取消未交付的值执行清理，close 等待清理结束；App 先排空 stager，再关闭共享文件所有者及数据库。
- 账号存储现在显式注入 persistent/cache 两根，按同一账号散列及 incarnation 派生范围。App 的缓存根来自系统 Library/Caches；原件/保留字节仍在 Application Support。取消了旧单根 bootstrap 参数和无用 media-staging 路径，无历史兼容分支。两根的退役共用持久标记，删除任一根后中断均可继续恢复，旧实例迟到清理不能影响新实例。
- `V2ResourceFileRecord.storage` 与 publish/delete/relocate journal 明确物理位置。普通下载、Range 文件及上传切片位于 cache 根；真实导入原件在冻结业务之前进入持久根。保留/取消保留及原件依赖结束后，FileStore 按依赖事实调整位置。
- 同卷位置切换只给受管不可变字节建立硬链接，先同步目标目录再提交 SQL；已有 lease 的旧 URL 留到真实消费者归还后再删除。崩溃恢复先处理位置 journal，再恢复导入选择，最后按 retention 调整位置。保留切换期间仍只统计同一份物理字节；外部导入源始终复制而非硬链接。损坏的中断切换隔离到自身记录，正常文件仍可用。
- Core `V2ResourceVariantKey` 区分不可变原件和 `derived(id, version)`；版本构造/解码必须正数。`V2ResourceVariantDescriptor` 保存不可变摘要/长度，不含传输计划或访问资格。`v2_resource_variants` 以 home/resource/rendition/version 为身份，关联可缺失的物理文件；同一版本不能替换摘要或长度。原件身份不跟随文件名称等 descriptor revision 改变。
- 真实会话下载按 room/home 注册原件，头像缓存按资料目标账号或群聊上下文注册衍生版本；摘要相同可以共享 blob，但不同 home 和版本保留独立意图。下载缓存别名和 variant 到文件的绑定在同一个 SQL 事务更新；已请求保留时先进入持久根，再交接新文件。文件缺失、损坏或旧文件行清除后，逻辑保留仍存在，新授权下载会重绑定。消息接受回执同库关联已验证上传原件，不额外下载。
- ResourceCenter 按当前可见引用读取 variant 快照，撤权后不暴露旧资源详情；保留不会绕过下载/借用授权。无法访问的资源仍可移除本机保留偏好。目录条目新增保留标记与 retainedOnly 筛选，保留变化通过现有资源投影流发布，不重排条目，也不使聊天/头像展示授权失效。
- 下载发布和第一份真实借用在 FileStore 同步完成；共享 flight 持有发布 lease，各调用者获得自己的交接 lease，直到重授权、逻辑绑定和 handle 创建结束才释放。预算准入失败、取消及关闭仍排空实际生产者并释放这些 lease，不把运行时计数持久化。头像解码现在直接消费独立 lease，删除 URL → 借用表和 releaseFile 桥接；关闭不能抢先释放仍在解码的借用。

### 实际验证

2026-10-23 在本机运行：

```sh
cd IMV2ClientKit
swift test --filter 'V2AcceptedResourceBindingTests|V2Resource(Center|Directory|DirectorySync|FileStore|Journal|Recovery)Tests|V2RoomResourceDirectoryClientTests|V2ProjectionChangeTests'
cd ../IMV2Core
swift test --filter Resource
cd ../IMV2Server
swift test --filter 'V2RoomResourceDirectoryTests|V2RoomActorForwardWireTests|V2ResourceRouteContractTests'
```

最新结果：客户端 37 个测试通过；Core 资源相关 24 个测试通过；服务端上述 8 个测试通过。包含既有发送意图、未知结果恢复、事务提交观察，以及新分页和接受回执绑定的回归。

另外，在本轮创建的独立本机 PostgreSQL 测试库完成：规范 schema 初始化和 SQL contract；`resourceDirectoryPostgresAuthorityAndPagination` 实际执行通过（不是环境禁用后跳过）；`V2ResourceHTTPPostgresTests` 两个前台 PUT/分片用例通过并检查上传名称入库，真实 OSS 用例未启用。它们分别通过 `IMV2_RESOURCE_DIRECTORY_DATABASE_URL`/`IMV2_RESOURCE_DIRECTORY_DISPOSABLE=1` 和 `IMV2_RESOURCE_TEST_DATABASE_URL` 指向隔离库。

iOS 验证：`xcodebuild -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/IMResourceCenterDerivedData CODE_SIGNING_ALLOWED=NO build` 成功。当前没有新增管理页面的 UI 验证，也没有后台/锁屏真机验收。每次后续改动仍需验证受影响链路。

下载所有权接入后的追加验证：

- ClientKit 资源文件/缓存/目录协调/权限、Range 和后台下载相关 35 项测试通过，包含损坏原件隔离、复制峰值预算、断点路径恢复及 12 组单次/重复并发取消场景。复合运行暴露的系统任务旧快照竞态已修复；最终日志 `/tmp/im-resource-ownership-final-test.log`。
- 独立 iOS 27 模拟器上，会话 Store 133 项、文件借用/冷启动 10 项、个人/群头像相关 14 项回归通过。最初组合运行有一处测试改动误改了上传清理断言，修正后重新执行会话全套通过。结果分别在 `/tmp/im-resource-app-media-test.log`、`/tmp/im-resource-app-media-retest.log`、`/tmp/im-resource-app-conversation-retest.log`；首个日志含已修复失败，不能单独作为绿色总报告。
- 最后一次协调器修改后 iOS Simulator App 再次构建成功，日志 `/tmp/im-resource-app-final-build.log`。没有安装到真实手机，也没有执行本地账号 E2E 或真实 OSS/锁屏下载。

本地原件基础的早期验证：资源/原件/缓存/权限/投影相关 36 项测试通过（`/tmp/im-resource-original-final-test.log`）；原件套件单独验证 8 项（`/tmp/im-resource-original-center-test.log`）。Core 元数据套件 5 项通过，包括 MIME 构造/解码边界（`/tmp/im-resource-content-type-test.log`）。当时 App 构建成功（`/tmp/im-resource-original-app-build.log`）；真实上传迁移在其后完成，不能用这些早期结果代替下面的接入验证。

真实上传接入后的追加验证：

- ClientKit 137 项、21 个 suite 通过，日志 `/tmp/im-resource-original-final-client-tests.log`。覆盖真实原件/切片、事务所有权、上传阶段取消、profile/group 闭合和替换、ACK 唤醒依赖释放、离线冻结无需网络、取消者释放选择但不能影响独立上传，以及 close 排空成功值的取消清理。
- App 已完成全测试 target 的模拟器构建；实际执行选择的 11 个 suite、186 项通过，日志 `/tmp/im-resource-original-final-app-tests.log`。包含真实原件冷重建、聊天草稿并发恢复、个人头像迟到取消/移除、群头像恢复/权限失败/事务交接、下载冷重建和文件使用、发送生命周期及头像像素授权。测试 fixture 同样显式关闭 account DB，修复早期测试删除仍打开 SQLite 文件的告警；该日志中无这类告警。
- 最新取消清理及账号关闭顺序调整后，App 同一 11 个 suite、186 项复验全部通过，日志 `/tmp/im-resource-original-verified-app-tests.log`；无删除仍打开 SQLite 文件的告警。测试设备为专用 iOS 27 模拟器 `IM Resource Center Verification`，并非用户手机。
- 以上是本机/模拟器和伪传输控制边界验证；没有真实 OSS 端到端、手机安装或锁屏/系统终止真机验收，也不表示 R0/P2 全部生产门槛已经通过。

双根目录与位置恢复追加验证：

- ClientKit 176 项、28 个 suite 通过，日志 `/tmp/im-resource-placement-client-final.log`。包括系统删除整个缓存根后原件/保留文件仍可读、预览期间保留切换及反复切换、三个位置发布中断点的真实导入恢复、损坏位置操作隔离，以及账号两根的分步删除/延迟旧实例清理。原本依赖元数据占位文件的 shared-source 测试已改为真实导入与共享字节，不再用不匹配摘要绕过文件验证。
- iOS 27 专用模拟器上 14 个选择 suite、199 项测试通过，日志 `/tmp/im-resource-placement-app-tests.log`；App 和全部测试 target 同时构建通过。该组合发现启动测试过早删除尚在关闭的 SQLite：修改测试，等待关闭后发布的最终 route，而不是仅等 UI 被撤下；启动套件 7 项重新执行通过，日志 `/tmp/im-resource-placement-offline-app-retest.log`，无该 SQLite 告警。早期含告警的组合结果不能代替这次关闭边界复验。
- 这些测试不证明后台 AFU 交接、整体磁盘配额、逻辑资源保留恢复、真实 OSS 或真机性能完成。没有安装/部署，也没有清理真实账号目录。

逻辑保留与下载交接追加验证：

- Core 新版本身份/字节事实的 3 项测试通过，包含非法版本与长度的 Codable 验证，日志 `/tmp/im-resource-variant-core-tests.log`。
- ClientKit 190 项、31 个 suite 通过，最终日志 `/tmp/im-resource-logical-retention-verified-client.log`。覆盖真实下载后的跨 home 独立保留、同一 blob 多意图、物理文件丢失与数据库冷重开后的新文件绑定、旧行清除、原件元数据 revision、衍生版本隔离、不可变事实冲突、目录保留筛选快照、资源投影隔离、撤权后不能读取保留内容；还覆盖发布后等待重授权期间并发清理、连续失败准入不占住 flight 槽位。
- App 与全部测试 target 构建通过；iOS 27 模拟器 13 个选择 suite、193 项通过，日志 `/tmp/im-resource-retention-directory-app-final.log`。包含头像真实 lease 关闭等待新增测试以及聊天、头像、文件预览和草稿恢复回归。最后的取消准入检查和版本排序调整后，受影响头像/文件链路 4 个 suite、25 项复验通过，日志 `/tmp/im-resource-logical-retention-verified-app.log`，无删除仍打开 SQLite 文件的告警。
- 没有新增资源管理页面入口、真机安装、服务器部署或真实 OSS 验收；派生尺寸/时长、完整版本查询分页、自动下载/额度策略和全量资源索引仍在目标范围内，不能由这些基础测试推导为全部交付。

## 未完成的交付项

分类策略追加验证与当前边界：

- `V2ResourceStoragePolicy` 取代生产路径的单一标量预算，按账号数据库持久化；普通缓存默认 512 MiB、待发送原件 2 GiB、受管临时预留 512 MiB，保留内容达到 2 GiB 时提示，最低可用空间 16 MiB。默认不设置额外总量上限，支持显式配置总量限制。这些是当前准入默认值，尚无设置页面。
- 实际 FileStore 的发布、原件导入、缓存淘汰和冷启动恢复均使用分类策略。降低额度只回收无消费者的可重建缓存及不活跃暂存；原件、保留意图和真实消费者保持有效，快照报告分类超额。已验证原件即使超过新额度也完成恢复，后续新增原件才受限。已有临时检查点可在额度降低后继续恢复，新预留仍须满足额度。
- 准入以 `max(逻辑长度, 已测分配量)` 计费，不把最终分配量与逻辑长度混为一谈。最终发布采用已验证字节并报告分配舍入产生的超额；这不是整体磁盘绝对硬上限。下载的源/未来发布预留按逻辑长度持久计入额度；后台上传源/保守系统副本已加入同一额度，见后续追加记录。分配块舍入、Range journal 原子写入开销、分享及后台下载 inbox 尚未全部统一。照片规范化应用临时副本已消除；实际 ENOSPC 及整体物理峰值仍须后续收敛。
- 保留下载直接使用持久根和保留类别，无需先占普通缓存额度；最终 SQL 发布与已有逻辑保留绑定原子提交，崩溃恢复执行同一事务。取消逻辑保留不会遗留隐式物理 pin。匹配摘要和长度仅建立本地可用性，不合并资源身份、授予读取资格或导入服务端资源。
- ClientKit 198 项、32 个 suite 通过，日志 `/tmp/im-resource-policy-final-client.log`。新增覆盖分类独立、LRU、降低额度时消费者与原件保护、持久偏好冷恢复、临时检查点恢复、低磁盘无幻影草稿、降额后中断原件恢复，以及超缓存额度的保留下载和保留发布中断恢复。
- App 全部测试 target 构建成功，日志 `/tmp/im-resource-policy-final-app-build.log`；专用 iOS 27 模拟器 8 个相关 suite、41 项测试通过，日志 `/tmp/im-resource-policy-final-app-tests.log`。覆盖附件原件/上传、持久资源闭合、下载/借用及个人群头像链路。未执行真实手机、OSS 或后台锁屏验收。

下载发布峰值追加实现：

- 暂存表新增受约束的 `publication_bytes`。下载准入持有 `源长度 + 未来发布长度`，上传切片只持有单文件长度；无旧整数 copies 兼容入口。临时额度、可选总额度、清理回收和快照均使用相同预留事实。
- `publishDownload` 必须提交当前活跃的暂存能力；发布事务核对长度和未消耗的 credit，将该 credit 与新文件预留原子交接。不能重复花费已消耗的 credit，也不需要第三份复制额度。降低总量/临时额度后，已有 credit 的发布可完成，新增增长仍拒绝。
- 复制失败后保留原始检查点；恢复丢弃未发布 partial 时，不凭空恢复已消耗的副本预留，后续重试必须重新准入补足。rename/SQL 发布中断后，最终文件与剩余源预留分别计量，未活跃的源可被显式清理。旧 owner 已归还的 release 变为幂等，不会删除新 owner 已重新借用的检查点。
- 专项 5 个测试通过（其中并发额度含临时/总量两种用例，发布中断含三个阶段），日志 `/tmp/im-resource-peak-integration-tests.log`。实际 DownloadCache 集成验证第二个不同内容请求在网络开始前因峰值不足被拒绝；另覆盖准确交接、重复消耗拒绝、降额后的已准入发布、冷恢复及迟到释放。
- 最终 ClientKit 203 项、33 个 suite 通过，日志 `/tmp/im-resource-peak-verified-client.log`，包含新增的实际 DownloadCache 集成及暂存数值约束。App 全部测试 target 最终构建成功，日志 `/tmp/im-resource-peak-verified-app-build.log`；专用 iOS 27 模拟器 9 个选择 suite、43 项通过，日志 `/tmp/im-resource-peak-final-app-tests.log`，无 SQLite 文件仍打开时被删除的告警。模拟器执行在最后的暂存数值上界约束前完成；该约束的最终 ClientKit 复验和 iOS 构建已通过，未重复执行相同正常长度的 App 套件。

照片规范化与内存原件追加实现（2026-10-24）：

- 删除照片选择路径的 `im-photo-*` 临时目录和 `V2ImportedPhotoFile`。Transferable 在系统提供者文件有效期内同步读取，使用 ImageIO 有界消费回调产生内存编码，保留输入 50 MiB、最多 8000 万输入像素、输出最长边 4096 的限制，并在每次编码写入前检查 50 MiB 输出上界。透明图输出 PNG，其余静态图输出 JPEG；应用方向变换并剥离源定位等元数据。系统提供者的文件仍由 Photos 管理，应用不删除或持久保存其 URL。
- 新 `ResourceCenter.importLocal(data:)` 及 `V2ResourcePublicationInput` 直接将不可变 Data 分块哈希/写入唯一的受管 partial，沿用既有容量准入、发布 journal、校验、同步、rename 和业务依赖交接。无第二个应用规范化文件，也无需为其建立独立目录或清理器。文件与内存来源共用去重和恢复事务；只有发布后的原件由 selection/upload/profileIntent 等业务事实保护。
- 实际聊天 PhotosPicker → 页面 Store → 账号 stager 已接入数据入口；文件选择及头像文件导入仍使用有效的文件来源 API。stager 与 Center 各自沿用 OperationScope 关闭/取消排空及迟到成功值清理，关闭后拒绝新照片导入；没有引入生产默认实现或把图片字节交给 UI 持久化。
- ClientKit 最终 207 项、33 个 suite 通过，日志 `/tmp/im-resource-photo-original-final-client.log`。新增四个测试覆盖跨多个分块且非零索引 Data、文件/内存同字节共享与冷恢复、输入和额度拒绝无幻影选择、三个发布中断点和发布后取消可回收。数据原件专项 13 项通过，日志 `/tmp/im-resource-data-original-tests.log`。
- App 及全部测试 target 构建成功，日志 `/tmp/im-resource-photo-owner-final-app-build.log`；专用 iOS 27 模拟器 5 个选择 suite、151 项通过，日志 `/tmp/im-resource-photo-owner-final-app-tests.log`，包括聊天全套、实际照片编码、原件/上传/资源闭合。新增验证方向与定位清除、透明 PNG、编码输出超限、规范化不创建磁盘文件、单个账号原件、真实聊天草稿入口、照片额度/取消/关闭及冷恢复。受控输出超限测试会触发 ImageIO finalize 写入失败诊断，该测试与整体执行均通过；无 SQLite 未关闭删除告警。
- 这里限制的是编码字节和像素，不声明完成真机内存峰值、Photos 系统读取的取消时延、真实 OSS 或锁屏验收。相册 UI 的真实选择、跨设备图片发送、真机性能仍需完整端到端验证。资源管理页面尚未创建。

后台上传文件所有权追加实现（2026-10-24）：

- Scope 增加按 incarnation 派生的 `backgroundDirectory`，是 Complete 账号目录的 AFU 同级目录，随 persistent/cache 一同退役。上传原生 session/inbox 已改用此目录；普通原件及账号 DB 不降级保护。根目录、session 目录、sources、partial 和最终上传副本分别请求 UntilFirstAuthentication/noBackup；副本是明确后台授权覆盖的最多 8 MiB 分片。
- `v2_resource_background_upload_sources` 只保存物理源的 session/opaque ID、准备/可用/删除状态、长度/分配量和摘要，不另建任务真相。FileStore 从同一 owner 的真实原件 lease 创建源，先记录容量，再有界复制、同步、摘要验证、rename、提交可用；后台协调器和原生上传 completion 均不再直接写入或删除上传源。协调器构造限于模块内，原生装配校验 Center 与 store 的账号身份。
- 暂存及可选总量共同计入 `max(源逻辑长度, 源实测分配量) + 一份源长度的保守系统上传副本`，一直持有到真实 system completion 或 cancelAndDrain。系统实际 spool 的分配量/元数据开销不可直接观测，不把该预留称为实测磁盘峰值。存储快照分别提供背景预留与应用源的实测分配量；普通缓存清理和降低额度均不能删除系统任务正在使用的源。
- 冷恢复先接管所有实际网络槽位，再对持久源摘要和路径进行验证。无法接管的源先取消/排空实际任务，再闭合原映射并按事实恢复同一上传作业；不能把物理源可用或系统 200 当作服务端媒体 Ready。孤儿行、准备中断和删除 journal 由同一 FileStore 在 OS 任务对账后回收，跳过创建中的与已接管的真实消费者。新旧实例目录隔离，旧 owner 迟到释放不会选中替代账号目录。
- SQL 不可用时，已排空任务仍可归还 FileStore 运行时 claim，使账号关闭完成；文件和 durable charge 保留，解锁/冷重开后的对账再清理。测试通过关闭 pool 确定性覆盖此分支，不声称模拟了 Data Protection 锁屏。系统回调只先写不含 URL/凭证/正文的最小结果；上传源不再由回调 unlink。
- ClientKit 216 项、34 个 suite 通过，日志 `/tmp/im-resource-background-owned-final-client.log`。后台文件/系统协调专项 19 项通过，日志 `/tmp/im-resource-background-source-extra-tests.log`，包含临时/总量分别限制、真实 drain 前保持文件/容量/调度槽位、四个准备中断点、冷接管、损坏/跨账号拒绝、取消复制、SQL 失败后关闭和重开、符号链接替换的删除失败恢复，以及账号三个删除范围每个中断边界。保护策略回归修复后原件与最终 AFU 副本均有显式策略调用。
- iOS App 与全部测试 target 构建通过，日志 `/tmp/im-resource-background-owned-app-build.log`；专用 iOS 27 模拟器 11 个选择 suite、54 项通过，日志 `/tmp/im-resource-background-owned-app-tests.log`。新套件通过真实 App 原件 fixture 验证有界分片、所请求的保护策略、noBackup、缓存清除不影响 AFU 源或唯一原件，以及完成后统一归还；另包含启动、上传、下载/借用、个人/群头像回归。
- 这些检查不证明真实锁屏/重启/进程终止或 OS spool 占用。最小 AFU task mapping、原生下载 inbox 迁入同一作用域及预算、锁屏下载交付和真机生命周期仍未完成；也没有部署、手机安装、真实 OSS 或资源管理页面交付。

后台重唤醒定位与创建/关闭边界追加实现（2026-10-24）：

- `V2BackgroundSessionDirectory` 持久化不超过 2 KiB 的本地 session UUID、incarnation、沙盒相对目录和 upload/download 种类；账号 AFU 范围内另有匹配锚点。记录及锚点均请求 AFU/noBackup，原子写入后同步文件和父目录，不包含业务账号 ID、消息、服务器 URL、请求头或凭证。这是 session 定位，不是尚待完成的每任务 AFU 传输映射。
- 生产定位的受信根为当前应用沙盒容器，索引位于 Application Support 专属目录。允许项目合法注入的沙盒内 Library/Documents/tmp 账号库；拒绝容器外路径、上级/绝对组件、错实例锚点、符号链接和超长记录。索引最多 128 个记录、单次扫描最多 256 项。解析只读取已有目录与锚点，不修复或创建账号目录；经过账号授权的装配才可修复自己损坏的小索引。普通关闭按种类撤销登记，退休后的残留指针不能重新创建旧目录，并在后续注册时安全清理。
- 上传及下载原生工厂都从 ResourceCenter 取得当前作用域，下载 session/inbox 已迁入该实例的 `backgroundDirectory/downloads`。系统重唤醒入口不再按全局根猜测账号；有有效定位就重接原 session，无有效定位只建立不接受新任务/下载字节的临时隔离 session，取消并等待实际 OS 任务结束，再归还系统 completion。隔离目录不作为账号数据或可显示资源。
- 原生 registry 拒绝同一系统标识被另一路径抢占。实例专属 `eventOwnerID` 约束 UIKit completion；旧实例的迟到完成/重复 invalidate 不能移除新实例或结束新 callback。隔离排空 Task 有明确的有界 registry 所有权。创建原生 session 同样纳入 Center OperationScope：账号关闭等待 SDK 创建返回，并关闭取消后迟到成功的 coordinator，然后才关闭文件所有者；关闭后的账号不再调用创建工厂。
- 最终 ClientKit 231 项、37 个 suite 通过，日志 `/tmp/im-resource-session-route-final-verified-client.log`。定位/装配专项 11 项通过，日志 `/tmp/im-resource-session-route-container-tests.log`，覆盖无业务目录冷读取、两种 session 独立撤销、退役不重建、错误路径/锚点/链接、记录大小与数量上界、受信装配修复、沙盒内其他合法根，以及忽略取消的 SDK 迟到结果仍被清理。
- App 与全部测试 target 最终构建通过，日志 `/tmp/im-resource-session-route-container-app-build.log`。专用 iOS 27 模拟器 11 个选择 suite、56 项通过，日志 `/tmp/im-resource-session-route-verified-app-tests.log`；包含重唤醒桥接、真实创建空任务的隔离 session、旧 owner completion 拒绝、启动、原件及头像等回归，无 SQLite 未关闭删除告警。启动专项 7 项另验通过，日志 `/tmp/im-resource-session-route-offline-retest.log`。
- 验证中修复两处问题：最初仅允许 Application Support 导致合法 tmp 账号库被拒绝，本地启动组合有 5 项失败，已改为应用沙盒边界并复验；作业 status 的事务通知会早于文件 actor 完成物理清理，旧后台测试现先等待对账闭合再断言 unlink，不把业务状态当作删除回执。早期 `/tmp/im-resource-session-route-app-tests.log` 和 `/tmp/im-resource-session-route-verified-client.log` 含这些已修复失败，不能当作绿色结果；前者测试失败且 App 已退出后，停止了仍驻留的报告收集进程。
- 仍未完成：下载字节仍由原协调器/native 边界管理，尚未接入 FileStore 的唯一预留/发布交接；下载 callback 仍需改为有容量约束的最小 AFU task permit，锁屏先接收、解锁验证后发布。当前模拟器桥接只证明这些代码与空任务排空行为，不证明真实 OS 重启唤醒、锁屏字节交付、真机性能或 OSS。资源管理页面和完整任务读模型仍未创建。

| 阶段 | 尚需完成 |
| --- | --- |
| P1 | persistent/cache 及 AFU 同级目录、逻辑保留/缺失重绑定、分类额度、下载发布峰值与后台上传源/系统副本预留已实现；仍需派生尺寸/时长、完整版本查询分页、导出及分配/sidecar 开销的整体预算、完整文件操作错误矩阵及任务事实整合。不能视为完整生产文件系统 |
| P2 | 实际 stager、消息/个人和群头像依赖交接、原件借用、选择恢复及分片切片已接入；照片直接从有界内存发布受管原件，后台上传源归 FileStore。普通接收、完整编辑/撤回的同事务目录更新、快照持久分批索引已接入；仍需完整文字草稿、头像引用索引与真实图片/文件对端闭环。发送接受回执绑定已接入 |
| P3 | 下载/头像/预览/导出已通过同一受管文件借用接入；仍需完整任务事实、同版本合并的取消矩阵、统一调度公平性与所有消费者退出后的暂停/取消策略 |
| P4 | 上传源/结果、下载 session/inbox 已在账号后台范围，重唤醒有最小 session 定位、实例 completion 栅栏和创建排空；下载已接入最小 AFU permit 和统一预留/校验/发布，锁屏先收件的隔离测试已加入；仍需上传每任务最小 AFU mapping、整体物理预算、原生后台与前台 Range 的完整能力区分；所有真机生命周期验收 |
| P5 | 资源页面、头像引用及图片 variants 派生元数据覆盖、文件与存储/聊天文件/传输/清理页面及统一导航。消息接收/编辑/撤回与快照索引已接入，详见追加记录。账号装配、目录权限失效和快照访问代次边界已接入；服务端查询、RoomRef 权限/索引与客户端 API/checkpoint 已有实现和上述验证 |
| P6 | 分类淘汰与额度基础已接入；仍需用户设置页面、自动下载与蜂窝策略、统计/指标/错误诊断；真实 OSS 图片与文件闭环、故障矩阵、性能、大字体及 VoiceOver；删除重复状态路径 |

当前目录由发送接受回执、普通接收/编辑/撤回和会话资源分页写入；快照通过同一投影银行的持久队列分批建立索引，未完成时明确标记 isIndexing。头像引用和完整派生元数据仍待整合。ResourceCenter 已在 App 账号装配中创建，尚无页面入口。文件所有者已使用 persistent/cache 和按 incarnation 隔离的 AFU 范围及逻辑保留意图，但整体预算、完整派生元数据及管理交互仍未完成。上述缺口必须在对用户开放页面前解决。

## 接续实施注意事项

- 保留工作区此前的照片选择改动；它们属于用户已经授权的功能，不要覆盖。
- 现有上传和下载 journal 是当前任务真相；不能给新 UI 建一份平行可写任务状态。
- **下一步继续 R1/P1 与 R4 的整体容量/后台故障收口。** 下载的最小 AFU permit 和 FileStore 唯一预留/发布交接已接入，详见本次追加记录；不能把逻辑字节预算视为所有磁盘分配开销的硬界。继续完成导出副本与 Range sidecar 开销、上传最小任务映射、后台真实生命周期，消息接收/快照索引现已接入，接着完成头像索引、canonical 任务读模型和管理页面。下载和授权测试不代表真实 OSS 或真机锁屏能力已开放。
- 消息投影使用影子表原子切换。目录接入必须考虑 snapshot activation、撤回、成员资格变化、消息缓存裁剪和引用覆盖范围，不能只给普通 insert 加一个 hook。
- 分页扫描已关联访问代次，并过滤失去本地访问资格或被服务端拒绝的会话。后续扩展头像/派生资源索引时必须保留这些边界，不能仅靠打开文件时鉴权。
- 描述修订不能改写同一资源已经确认的原件摘要和大小；授权仍由读取上下文判断。
- 当前新 schema 未提供既有安装数据库升级；不要在部署时自行推导为可删除真实手机或服务器数据。
- 继续完成完整方案；本记录不是完成声明。


## 追加实施：统一后台下载字节边界（2026-10-24）

本节覆盖此前“后台下载字节仍由独立 native/coordinator 管理”的在途状态，完整目标继续保持 active，尚无资源管理页面交付。

- `v2_resource_transfer_staging` 增加强类型位置与 session/mapping，前台与后台下载使用同一持久容量账本。后台预留同时覆盖原始收件与未来发布副本；Cache 不再另做前台预留。普通暂存清理始终跳过后台任务，只有系统任务所有者完成真实 adoption/drain 后才能回收。
- 新增 `V2ResourceBackgroundDownloadInbox`，作为 FileStore 的同步 OS callback 边界：只有容量准入成功才能生成最小 AFU permit；创建 suspended task 后持久化业务映射、安装实际 task ID，再 resume。许可文件有大小/数量上界，绑定 grant、长度、摘要、来源摘要和 task ID，不保存 URL、请求头或正文。
- Native delegate 只在 callback 返回前接管精确长度、精确来源的原始文件，应用 AFU/noBackup 并同步文件及目录；不查询 Complete SQLite，不做大文件摘要计算，不走全局 staging budget，也不直接删除收件字节。已撤销许可或已退役目录的迟到回调不能重新建目录。
- 解锁后 FileStore 验证长度与 SHA-256，再用原预留的 publication credit 发布到正式 Complete 文件。协调器实际排空后由 FileStore 撤销许可、删原始文件、释放同一份预留；失败的复制保留原始所有权，重试前重新准入已花费的发布额度，不给清理留下空窗。复用已有已验证 blob 也结算发布额度。
- 后台协调器返回的是内部字节源，不是展示授权。共享 flight 完成后 Cache 对每位消息调用者分别获取新授权；撤销一个调用者不影响另一个合法调用者。发布到账号字节池本身不能使撤权调用者取得 handle/lease。
- 冷启动先接管实际系统槽位，再读取业务事实；最小 AFU permit 可在业务库锁定时限制过期任务。锁屏初始化不自动关闭合法下载；解锁通知恢复业务对账。并发初始化、过期取消均有测试；过期测试使用注入时钟，避免真实 1 秒时限受机器负载影响。
- 新增 callback/文件联合测试：未准入、未安装 ID、错误来源/ID/长度、摘要错误、重复回调、符号链接、撤销与退役迟到回调；关闭业务 DB 后收件并重建 FileStore 验证/发布；冷清理跳过后台预留；容量峰值单次计费；三个发布崩溃点恢复；已有 blob 复用后的 credit 结算。
- 修正后台上传测试驱动与原生行为不一致：已完成或不存在的任务取消应立即返回；多个实际取消等待者都须唤醒。此前单 continuation 和仅检查标识非空可能在并发对账中挂起。诊断用 TRACE 已移除，未把测试专用等待行为加入生产实现。

本次未安装手机、部署服务、操作真实 OSS 或清除用户数据。仍须完成上传最小任务 AFU 映射、导出/sidecar/分配开销的整体预算、完整接收与快照索引、任务读模型、管理页面、偏好和真机/真实 OSS 验收。模拟器和关闭数据库测试不证明真实锁屏、首次解锁前或系统终止后的字节交付。

验证结果：

- 最终 ClientKit 242 项、38 个 suite 通过：`/tmp/im-resource-bg-download-final-client-success.log`。包含新增下载边界、共享授权、锁屏/冷启动、发布恢复，以及原件/头像/调度/账号等相关回归。
- App 与所有测试 target 构建通过；模拟器阶段回归 55 项、11 个 suite 通过：`/tmp/im-resource-bg-download-app-tests.log`。最后生产代码上的后台桥接、离线启动、下载生命周期与文件借用 23 项、4 个 suite 再验通过：`/tmp/im-resource-bg-download-green-app.log`。
- `/tmp/im-resource-bg-download-final-client.log` 含真实 1 秒时限的过期测试超时，已改为注入时钟；`/tmp/im-resource-bg-download-green-client.log` 含并行 App 构建负载下既有 preparation 测试 2 秒等待失败，最终独立回归已通过。若日志因测试驱动取消等待挂起而终止，也不算绿色证据；诊断样本保存在 `/tmp/im-bg-download-regression-sample.txt`、`/tmp/im-bg-download-upload-wait-sample.txt`、`/tmp/im-bg-upload-completed-task-sample.txt`。最终结论仅使用以上明确通过的日志。


## 追加实施：接收消息与快照资源索引（2026-10-24）

- 共享 `V2MediaPresentation` 增加可核验的 `resourceDescriptor`，携带 home/media、描述修订、规范显示名、MIME、长度、摘要及可选尺寸/时长，不含对象地址或凭证。构造和 Codable 解码都验证描述与展示包络的身份/类型/长度一致。本地草稿展示值允许无描述，但这不是旧协议兼容：客户端同步附件与服务端共享接受状态的 wire 均要求完整描述，缺失或错误归属直接拒绝。
- `RoomWriteMediaAcceptance` 在既有接受事务和媒体锁内，从目标 room 的 resource_catalog 与 active placement 读取名称、generation、已核验摘要，核对长度后构造描述。逐条/附件消息接受事件与共享 `V2MessageProjectionState` 都持久化同一 `resource_descriptor`；完整编辑与快照折叠继续保留它。未引入客户端提供描述的可信路径。
- 客户端普通消息接受、完整内容替换及文本编辑在原投影事务内更新目录/原件 variant，并在相同提交内推进游标。引用按 message/ordinal 和业务修订管理；替换后不匹配的槽位撤销，重排不会留下重复来源，撤回和墓碑继续阻止迟到页恢复资源。当前消息能证明的附件位置必须精确匹配 ordinal 与 mediaID。
- 完整快照的资源描述保存在权威消息影子投影中；新增仅含 messageID/room/revision 的 `v2_resource_projection_index_jobs`，随投影银行原子切换。页面导入及 ACK 前准备完成队列构造，最终 activate 不扫描消息或复制资源目录。激活后每批最多 100、默认 50 条，从当前 live 投影派生同一目录，提交后删除任务；崩溃/取消不会丢未完成 ID。ResourceCenter 的账号观察任务持续处理批次，关闭时取消并排空；目录页面提供 `isIndexing`，不把未完成当作空目录。
- 引用新增 `validated_snapshot_id`：快照切换后，旧查询独有且当前消息不能证明的引用先停止展示，不能靠旧目录绕过新投影。新的已授权会话页可以用相同业务修订重新验证；同一 snapshot 下不重复写入未变化引用。该 stamp 不授予文件访问权，实际读取仍使用现有上下文授权和访问代次。
- 新增 `V2MessageResourceIndexTests`，覆盖接收即索引与来源去重、缺失/错房间/错大小/错身份拒绝并回滚游标、第二个附件冲突时整事务回滚、重排/移除/撤回、防迟到恢复、ACK 前不可见、激活后分批与冷启动恢复、ResourceCenter 自动排空，以及新 snapshot 下相同修订重新验证。
- 扩大回归时暴露并修复上传/下载对账的真实时序窗口：对账 Task 已完成、但外部 await 的调用者尚未清理所有权时，迟到请求可能加入已完成的 Task 并留下无人处理的 dirty pulse。现由 Task 自己在结束前的同一 actor turn 释放对账所有权，外层等待者不再清理后来任务的状态。

本次没有新增历史迁移或旧 wire fallback，没有部署/清库、真实 OSS 操作或手机安装。头像引用、派生尺寸/时长的实际采集、统一任务读模型、完整物理预算、所有管理页面与最终真机/OSS 门槛仍未完成，完整目标保持 active。

验证结果：

- Core 描述/媒体/版本/查询 19 项、5 个 suite 通过：`/tmp/im-resource-message-descriptor-final-core.log`。
- 客户端最终相关回归 300 项、41 个 suite 通过：`/tmp/im-resource-message-index-final-client.log`，包括消息索引、快照激活/恢复、目录权限、搜索、原件、下载/后台并发取消与账号生命周期。专项快照/接收初验 29 项通过的日志为 `/tmp/im-resource-message-index-verified.log`；最终回归另包含新增的多附件事务冲突用例。
- 服务端合同、Actor mapper、目录服务和真实隔离 PostgreSQL 20 项、5 个 suite 通过：`/tmp/im-resource-message-descriptor-verified-server.log`。数据库测试实际经过 ready 资源、消息接受、room event JSON、共享状态折叠与目录分页，断言同步描述与目录描述一致。临时 PostgreSQL 16 使用本轮独占的 `127.0.0.1:58847/resource_test`，测试后已停止；未连接现有云服务器或生产数据库。
- App 与测试 target 构建通过：`/tmp/im-resource-message-index-app-build.log`；模拟器阶段回归 55 项、11 个 suite 通过：`/tmp/im-resource-message-index-app-tests.log`；对账修复后的最终桥接/启动/下载/借用 23 项、4 个 suite 通过：`/tmp/im-resource-message-index-final-app.log`。
- 早期 `/tmp/im-resource-message-index-compile.log` 的两个媒体 fixture 缺失新描述，已按新合同更新；该日志还含与大规模并行负载有关的旧 deadline 测量失败，不能当作全部 SyncEngine 回归通过。本次最终选择覆盖受影响快照与消息路径，没有宣称全库所有测试通过。`/tmp/im-resource-message-index-tests.log` 的新快照用例曾给两条消息相同房间序号，已修正 fixture；`/tmp/im-resource-message-descriptor-final-server.log` 曾因非法展示资料现于 decode 提前拒绝而失败，已更新断言位置。`/tmp/im-resource-message-index-client-regression.log` 的并发取消超时促成上述对账所有权修复；这些失败日志均不作绿色证据。


## 追加实施：资源管理页面与真实预览（2026-10-24）

本节覆盖此前“尚无管理页面/入口”的状态。完整目标仍未完成，以下不是发布或完整验收声明。

- 新增 `IMApp/V2/Resources/`：账号级管理 service、资源列表/详情/存储 Store 和对应页面；从“我的 → 文件与存储”进入，沿用登录后 root navigation。会话菜单和设置提供“聊天文件”，设置 sheet 先关闭再导航。路由只携带资源/会话身份。
- 本地目录按图片（含动图）、视频、音频、文件筛选，支持名称搜索、保留筛选及每页 50 条游标翻页。页面先观察本地快照；会话页另由持有 UUID/category 的请求向既有服务分页补齐，取消或旧请求结果不能覆盖新筛选。替换分页而不是保留不可重新验证的旧页尾。当前只有 List，图片网格和缩略图仍待完成。
- ClientKit 增加详情元数据和来源分页，沿用目录的可见引用、成员资格、撤回与 snapshot 边界；sources 不含对象 URL。打开前后再次校验来源，调用既有下载缓存和授权路径，不把资源目录可见性当作字节访问凭证。支持定位原消息、预览、分享、逻辑原件保留；撤权后详情不可用并撤下其 presentation。
- 存储页读取真实 FileStore 分配值及策略，提供缓存额度、清理预览、提交及实际结果。政策修改保留其他分类额度；清理不更改消息、收藏或云端对象。修复 SwiftUI sheet 在结果完成后回写 nil 导致实际结果被清空的问题，关闭 acknowledgement 只处理尚在 preview 的状态。
- Quick Look 初验发现受管 UUID 文件无扩展名，只展示“数据”。现由 FileStore 为已有真实借用建立带 MIME 首选扩展名的独立硬链接借用，文件名仅内部 UUID + 有界小写字母/数字扩展名；不使用用户名称拼路径。位于 Complete 持久根的 `presentations/`，同卷共享 inode，无第二份 payload；运行时至多 64 个真实借用。元数据开销的整体预算仍属于 R1 未完项。
- 平台 controller 强持有 Coordinator/presentation；SwiftUI teardown 只断开 dataSource，借用保护到实际 UIKit 控制器释放。账号 close 等待这个实际消费者，不能在开始 dismiss 时提前归还。释放独立借用时 unlink；冷恢复清除没有活跃借用的平面遗留链接，不递归跟随未知路径。活跃别名采用规范化路径比较，修复 URL 表示差异导致 reconcile 误删。Caches 原路径被清除、但实际预览仍持有持久硬链接时，验证后恢复同一 inode，保持占用与版本事实。
- 新增隔离 DEBUG 签出 fixture，只替换远端授权/字节 leaf，使用正式“我的”、路由、页面、GRDB、FileStore 和缓存；不依赖真实账号或 OSS。XCUITest 验证入口、详情、保留/解除、真实 PNG 像素渲染、右上完成及清理结果；不是只断言 sheet 存在。测试专用目录已清理，未安装手机或操作云服务。

当前未完成：canonical 传输任务快照/页面与调度公平性、完整自动下载/蜂窝偏好、头像引用索引、缩略图/网格和派生尺寸时长、完整导出副本/sidecar/分配开销预算、上传任务最小 AFU mapping、分享所有消费端验证、大字体/VoiceOver/性能、真实 OSS 与真机后台生命周期。未增加假任务或禁用按钮来代替这些能力，也未缩减原方案范围。


本阶段验证结果：

- 最终 ClientKit 资源、原件、接受绑定及消息索引相关 **133 项、25 个 suite 通过**：`/tmp/im-resource-center-verified-client-tests.log`。包含独立预览借用、路径逃逸拒绝、原路径丢失后借用恢复、同 inode 单次统计、遗留链接冷恢复、目录分类/详情/撤权、既有上传与后台资源回归。不是全库测试声明。
- 最终 iOS App/所有测试 target 构建成功；专用 iOS 27 模拟器上的管理 Store、文件借用及下载生命周期 **15 项、3 个 suite 通过**：`/tmp/im-resource-center-verified-app-tests.log`。实际平台 controller 持有、撤权移除 presentation、关闭等待真实释放有自动化证据。
- 实际 UI 路径 **1 项通过**：`/tmp/im-resource-center-rendered-ui-tests.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_05-13-22-+0800.xcresult`；蓝色 PNG 全屏像素检查等待实际渲染，截图已人工查看，文件位于 `/tmp/im-resource-center-ui-rendered-attachments/`。该 UI 验证先于最后的活跃链接恢复路径比较修复，后者经过上述最终 ClientKit/App 回归；不把它视为所有媒体、系统分享或真机验收。
- 初始 UI 日志 `/tmp/im-resource-center-ui-tests.log` 的清理结果断言失败促成 sheet 回写修复；初始截图也证实无扩展名仅显示“数据”。`/tmp/im-resource-center-ui-fixed-tests.log` 中 UI 路径通过，但同次新关闭测试遗漏 close 排空时的合法 CancellationError，已调整等待并在最终 App 日志通过。`/tmp/im-resource-center-final-client-tests.log` 的活跃链接恢复用例曾因 URL 表示差异失败，规范化路径修复后最终 133 项通过。早期混合/失败日志不作整体绿色证据。
- `git diff --check` 通过。本阶段没有提交、推送、手机安装、部署或真实 OSS 操作；未清理用户账户数据。


## 追加实施：canonical 任务快照、传输页与导入执行所有权（2026-10-24）

本节覆盖此前“无统一任务读模型/传输页面”的状态；完整 R3 和整体目标仍未完成。

- 新增 `V2ManagedResourceTransferID`、阶段/失败/用途/分组值、分页 query/page 和快照。上传、系统后台下载、服务端导入直接读取各自 canonical journal，在同一 GRDB 事务中 UNION 身份和创建时间后读取有界记录，没有新增第二份可写 task state。相同 UUID 的三类任务不会冲突；按 `(created_at, kind, job_id)` 降序 keyset，进度/阶段变化不重排。新增创建时间索引，默认每页 50、最多 100。
- ResourceCenter 通过已有资源投影变化合并刷新、去重、bufferingNewest(1) 发布任务快照；目录/任务共享至多 16 个订阅，关闭时结束所有订阅。快照不携带请求、签名、回执字符串、文件路径、数据库对象或后台 task 定位。后台下载记录的文件名和详情路由必须通过当前可见消息引用读取；撤回/撤权后退回通用任务标签。
- 显示 provider 已确认的分片字节；无确认事实时不显示伪造进度，资源 ready 后才显示完整确认值。`downloaded` 表示待校验/发布，下载的 `cancelled` 记录仍显示“正在取消”，直到真实任务和字节排空，不能把取消请求当作已停止。
- 新增“文件与存储 → 传输任务”，提供进行中/需处理/已结束、来源用途图标及阶段颜色、状态详情 sheet（完成在右上角）、游标分页、当前可访问下载资源的详情入口。沿用统一导航，页面任务仅观察快照。传输完成与消息确认分开展示。
- 只开放当前可证明的上传/导入“继续处理”：在同一写事务重新核对暂停/注意状态、取消、执行所有权与终态；然后调用原有重试 SQL，保持同一个上传会话/导入操作、目标 mediaID 和服务器冷却。原账号恢复观察被 DB 变更唤醒，不由页面另开执行循环。不存在、已完成、取消中或仍被执行的任务返回 typed actionUnavailable。未完成的暂停/取消及下载重试能力没有放成假按钮。
- 发现并收口服务端导入没有持久执行所有权的窗口：第 5 次请求尚在 I/O 时，UI 原本可能重置其预算。canonical 导入表增加 execution_owner，claim 在事务中占有，due 查询和重试排除已执行记录；成功/错误/取消后由实际 owner 释放。状态保存和暂停校验精确 owner，旧 owner 的迟到结果不能覆盖新实例；错误 release 不会释放新 owner。冷恢复清旧 owner，保留原请求、次数、deadline 和服务器冷却。每次已排空后的恢复 activity 使用新 execution generation，以便 protected DB 锁定期间 release 失败后重新接管。
- 实际 `V2DurableConversationSendService` 的普通导入和取消路径已接入 claim/save/release，关闭继续等待实际 I/O；上传的共用重试 SQL 也排除 execution_owner，防止聊天入口绕过同一边界。测试的 accepted-import 元数据 fixture 改为 test target 内部注入 helper；生产旧无 owner 状态保存 API 已删除，没有添加兼容 fallback。

仍需继续的完整范围：前台/头像下载的 canonical 执行记录、完整下载完成历史（当前后台下载发布/排空后原 journal 会删除）、500 条/30 天历史保留、原生实时字节进度、统一暂停/继续/取消与每消费者策略、全局并发/公平调度和自动下载策略。当前传输页覆盖现有上传、导入及系统后台下载记录，不代表所有下载已经纳管；尚不能将 R3/P5 判为全部完成。其他 R1/R2/R4/R6 的物理预算、头像索引、派生元数据/缩略图、AFU 上传 mapping、真机/OSS 等门槛继续保留。


本阶段验证结果：

- ClientKit 最终资源/任务、准备调度、导入/上传、发送观察、操作工作与群头像闭合相关 **147 项、26 个 suite 通过**：`/tmp/im-managed-transfer-final-client.log`。新增 `V2ManagedResourceTransferTests` 覆盖三类同 UUID 不碰撞、分页期间状态变化、确认字节、同一操作重试与冷却、无权下载隐藏名称/路由、取消未排空不报完成、流关闭、执行中禁止重试、错误/旧 owner 不能发布或释放新 owner，以及不存在任务的 typed 拒绝。
- iOS 最终 App/所有测试 target 构建成功；管理 Store 和真实 DurableResourceLifecycle **9 项、2 个 suite 通过**：`/tmp/im-managed-transfer-final-adoption-app.log`。导入生命周期现实际先留下前一个 owner 的中断 claim，再由正式恢复 activity 接管；断言 charged attempts 从 1 到 2、实际 I/O 期间不可再次调度、close 等待迟到 I/O、取消后仍保留原请求且归还 execution claim。此前 `/tmp/im-managed-transfer-final-owner-app.log` 的 9 项为执行 generation 调整后的初验。
- 实际 UI **1 项通过**：`/tmp/im-managed-transfer-final-app.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_05-31-42-+0800.xcresult`。包含我的入口 → 任务页需处理 → 原任务重试 → 进行中 → 资源详情/保留/真实 PNG 预览 → 安全清理。正式页面、导航、文件 owner 与 journal 被使用，只有远端 leaf 替换。已导出并查看任务页截图：`/tmp/im-managed-transfer-ui-attachments/6BDC0F7D-4A12-4093-91BC-D04A6DBB85BB.png`。该 UI 路径先于最后的导入 recovery generation 调整及冷接管断言，后续变化已通过上述最终实际服务测试；不据此宣称全机型、VoiceOver 或真实后台/OSS 验收。
- `/tmp/im-managed-transfer-app-tests.log` 的初始 UI 失败来自行 accessibilityIdentifier 覆盖子按钮，已将身份放到标题并保留按钮自己的标识。`/tmp/im-managed-transfer-verified-app.log` 的第二次 UI 清理断言失败来自 fixture 图片与上传原件共享同一 blob，保护原件导致没有可清理项，属于正确生产行为；最终 fixture 使用不同真实 PNG，验证可清理缓存与受保护原件并存。失败日志不作绿色证据。
- `git diff --check` 通过。无历史 schema 迁移、旧 API fallback 或 UI task 双写；未提交、推送、安装手机、部署、连接真实 OSS 或清除用户数据。隔离 UI fixture 的目标实例已由测试清理，剩余受控前缀检查为空。


## 追加实施：前台下载纳管、完成历史与等待任务取消（2026-10-24）

本节覆盖此前“前台/头像下载无 canonical 记录、后台完成即删除”的状态；完整资源中心目标仍保持 active。

- 将下载表直接统一为 `v2_resource_download_jobs`，增加 foreground/background 路由、不可变校验身份/长度、执行 owner、受控 issue、完成时间和终态。没有保留旧表读取、迁移或平行 task state。原 `V2BackgroundDownloadJob` 仅作为该表的原生后台适配读值，过滤前台及终态记录，原有系统任务映射/权限许可仍走单一事实。
- 真实 DownloadCache 的消息和头像字节下载在网络 I/O 前持久化前台任务；相同 checksum/length 的共享 flight 只有一条物理下载记录。中断保留原 UUID 和 FileStore 断点；新请求重新授权后恢复同一条任务。缓存命中不会伪造新网络任务，亦不因一个等待者取消而停止其他合法消费者的共享传输。
- 前台收到完整字节后先标记待校验，FileStore 验证及发布后才提交 completed。任务完成写入须持有正确 owner，并核对已发布文件的摘要/长度。错误仅保存 network/integrity/space/unavailable/interrupted 等枚举原因；归还实际暂存写入 claim 后才暴露可管理的等待状态。
- 账号资源中心建立时立即将旧前台执行标为 interrupted/paused，不等到第一次新下载才恢复，避免冷启动假显示传输中。缓存构造同样完成接管。旧 owner 的待校验、暂停和完成写入不能覆盖新 owner。字节已发布而任务终态未提交时，后续已授权、已验证的缓存命中可补齐原任务；当前 owner 仅在 actor 确认对应 physical flight 已排空时结算自己的遗留 claim。开始实际 flight 前再次检查其他合法发布者已提供的相同字节，避免无必要的网络传输。
- 后台下载发布/排空后转为 completed/stopped/failed 历史，清除已结束的 OS mapping，不再删除任务本体。成功路径先提交完成事实，再释放原始收件，避免原始来源和 completion marker 已删、任务却还像未完成的崩溃窗口。取消请求仍显示 cancelling，真实排空后才写 stopped；损坏/不可用收件不会伪装为完成。
- 下载 closed 历史保留至多 500 条、30 天，启动、终态提交和打开任务页时维护；终态不会占用 active admission。活动、等待、取消中及未发布记录不参与历史清理。此限制目前只收口下载，上传/导入的依赖安全终态保留仍属剩余 P6。
- 新增等待中的前台下载取消命令：同一事务确认 foreground、owner 已归还及 paused/cancelling，持久取消请求；FileStore 只清该身份的非活跃断点、range sidecar 和预留，实际删除后才结算 stopped。清理中断可由冷恢复或同一命令重试；不删保留文件、其他 checkpoint 或共享已发布 blob。仍被执行的前台/后台下载不提供该取消能力，命令也会拒绝过期 UI 动作，未以停止共享物理 I/O 冒充单个消费者取消。
- 任务页实际接入取消按钮、完成/取消历史及类型化空间/完整性说明；GUI 与执行端均按当前能力校验。扩展隔离 UI fixture：通过真实缓存和文件 owner 产生 PNG 完成记录、实际残留 partial 的网络中断和上传需处理记录；只替换远端 leaf。界面操作验证取消后进入历史、上传原任务重试、真实图片预览与清理。

仍未完成：活动任务的完整暂停/继续/每消费者取消、下载任务页直接发起的新授权重试、实时 OS/前台字节进度、统一全局额度/公平调度、上传/导入历史保留和自动下载/蜂窝偏好。头像引用及派生元数据/缩略图、全量物理/导出/sidecar 开销、AFU 上传任务 mapping、真实 OSS 和真机生命周期等原 R0–R6 门槛继续保留。下载记录已纳管不代表这些能力或完整 R3 已交付。

本阶段实际验证：

- 最终 ClientKit 资源、canonical 下载/任务、后台下载、目录/原件/预算等受影响回归 **137 项、27 个 suite 通过**：`/tmp/im-canonical-download-final-verified-client.log`。命令为 `swift test --package-path IMV2ClientKit --filter 'V2CanonicalDownloadJournalTests|V2ManagedResourceTransferTests|V2Resource|V2BackgroundDownload'`；不是全库测试声明。
- 新增/扩展测试覆盖：真实中断 checkpoint 保留并沿用同一 UUID，等待取消只删自己的临时字节并保留其他 retained 文件，再次请求使用新 ID；冷取消重建排空；前台/后台完成进入历史；500/30 天维护不阻挡 active 准入或删除 pending；旧 owner 拒绝；未发布文件不能完成；冷启动在无新下载时显示 interrupted；共享传输取消一位等待者不误停另一位；已发布/同 owner 遗留完成 claim 的缓存命中闭合且无第二次网络下载。
- 最终 App 与所有测试 target 构建成功；专用模拟器资源管理 Store、下载生命周期和文件借用 **17 项、3 个 suite 通过**，实际 UI **1 项通过**：`/tmp/im-canonical-download-final-ui-app.log`。结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_05-54-56-+0800.xcresult`。包括等待下载取消、历史显示、原上传任务恢复、资源详情/保留、蓝色 PNG 像素验证、清理结果和本测试 scope 清理。截图已查看，阶段导出文件 `/tmp/im-canonical-download-ui-attachments/2077E3E5-251D-4356-BF08-5C6F12BD0F62.png` 显示真实完成和已取消记录。最后新增的纯 ClientKit 冷启动/过期断言随后通过上述 137 项，未修改后续 App 生产代码。
- 早期 `/tmp/im-canonical-download-flow-tests.log` 有测试把第二个 actor 属性写入非异步断言 autoclosure 的编译失败，已显式 await；`/tmp/im-canonical-download-final-client.log` 有新测试在 #require 内遗漏嵌套 try 的编译失败，已把查询和 unwrap 分开。它们不作绿色证据；`/tmp/im-canonical-download-regression-tests.log`、`...verified-client.log`、`...recovery-client.log` 为阶段通过结果，最终结论以上述 final-verified 日志为准。
- `git diff --check` 通过。本阶段未提交、推送、安装手机、部署或使用真实云服务；未清除用户数据，也没有放宽文件保护或增加历史兼容路径。


## 追加实施：账号级前台下载重试与冷恢复（2026-10-24）

本节覆盖上一节“下载任务页不能直接授权重试”的缺口；仍不代表完整 R3 或资源中心全部交付。

- `v2_resource_download_jobs.resume_requested` 保存用户重试请求及消息下载崩溃后的恢复意图。约束禁止后台、无消息上下文、已取消或终态携带该标记。没有独立 UI 恢复表或兼容 schema。任务页只写入请求、重置本次显式重试预算，仍以原 job ID 和 checksum/length 断点恢复。
- 只有 idle foreground、paused、尚未请求且原消息引用当前可见的任务提供 retry；相同事务重新检查能力，拒绝重复/过时操作。排队尚未 claim 时仍可取消；开始实际执行后不伪装为可安全取消的等待任务。头像、原生后台及活动共享传输尚未开放该操作。
- 新 `GRDBV2DownloadRecovery` 在 claim 时重新验证原消息引用，固定原媒体、位置、摘要与长度，按 owner 及至多5次崩溃恢复预算接管。排队后撤权直接解除请求并标记来源不可访问，不访问远端。执行前取得新授权；版本/长度变化在重用 partial 前拒绝。正常网络/授权失败记录为需处理并清除请求，不自动无限循环；用户可再次明确重试。
- DownloadCache 持有实际重试 SharedOperation；`runRecovery` 是账号活动，AppStore 以 `resourceDownloadRecovery` 接入已有账号 runtime。页面只发命令，取消 scheduler 等待者不会误取消其已拥有的实际下载。Center/Cache close 会停止准入、取消并等待实际重试和共享字节写入排空，才允许 FileStore/DB 关闭。
- 重试保持原前台任务路由，不因新临时计划支持后台而另建后台任务；允许共享合法字节 flight。缓存命中仍重新授权，真实 FileStore 校验/发布后才结算原任务。授权401/403映射为来源/权限不可用，避免误标网络错误；对应页面说明同时覆盖本地来源与访问权限。
- 恢复阶段的数据库写入失败会传回账号活动诊断，不能吞掉并留下永远 preparing 的任务。普通业务失败在 canonical journal 确实记录后才结束当前重试。
- DEBUG 隔离 UI harness 接入同一账号恢复入口，受控传输第一次产生真实 partial，第二次写入可校验 PNG；没有直接把任务改为 completed。新增 UI 测试点击重试后离开传输页，返回在已结束列表核验原任务 ID；原取消、预览像素和清理路径继续保留。

实际验证：

- ClientKit 相关 **53项、7个 suite 通过**，日志 `/tmp/im-download-recovery-final-client.log`。包括 canonical journal/任务、下载缓存、后台下载、文件所有者、中心和保留链路。新增覆盖原UUID/原partial冷恢复、排队后本地撤权不请求网络、新授权403及版本变化不复用错误字节、scheduler取消不停止账号任务、账号close等待不配合取消的真实写盘、崩溃claim预算1/5、数据库故障传播与后续冷恢复。
- 初版新测试确实发现403被归为network，`/tmp/im-download-recovery-client-tests.log` 有该预期失败；修复后中间22项与最终53项通过，不能把早期失败日志算绿色证据。
- 第一轮模拟器验证24项、4个 App suite 和2项UI通过，日志 `/tmp/im-download-recovery-app-ui.log`；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_06-10-51-+0800.xcresult`。已查看截图 `/tmp/im-download-recovery-ui-attachments/6B5E005B-ED00-4AED-B107-E4F7C0256B34.png`，显示恢复图片在原任务记录中已完成和已确认字节。
- 追加实际 App Store 测试后，最终复验的 **25项、4个 App suite 和2项UI全部通过**，App及所有测试target构建成功。日志 `/tmp/im-download-recovery-final-app-ui.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_06-13-16-+0800.xcresult`。新增 App 测试验证页面命令结束时并未再次请求网络，离开页面后启动账号恢复才完成同一任务，并能借用真实校验字节。

未完成范围：活动任务暂停/继续/每消费者取消、原生后台任务管理页重试、真实字节进度、统一全局公平调度与自动下载/蜂窝策略、上传/导入历史保留。其余原 R0–R6 门槛（头像引用/缩略图/尺寸时长、完整物理开销、AFU上传映射、真实OSS/真机生命周期、AX及性能）继续有效。没有部署、安装手机、提交/推送或清理用户数据。


## 追加实施：活动前台下载暂停、继续与取消（2026-10-24）

本节在前台授权重试基础上增加真正作用于执行器的控制，未增加历史兼容路径。

- canonical 下载行新增类型化的 `control=run/pause/cancel` 持久请求，区分“用户希望停止”与“实际已停止”。请求先落同一账号数据库，再向 Cache 当前持有的 physical flight / resumption 发出取消；live owner 必须与真实运行 map 相符，不能仅凭历史任务 ID 假装停止 I/O。
- 管理页暂停/取消针对这一条物理下载任务，所有等待它的消费者都收到取消；页面自身取消 `download()` 等待者仍只释放自己，不影响其他消费者。已经发布并被借用的合法文件不因停止新下载而删除。
- 新增 pausing/paused 展示阶段及 pause/resume 命令。活动写入未结束时保持“正在暂停/取消”，不提前归还 FileStore 暂存额度或显示终态。字节执行真正结束后，暂停保留同 UUID 的 checkpoint，取消只删除对应的非活跃 partial/sidecar，实际删除后才写 stopped。
- 仅当前消息引用可见、具备重新授权上下文的前台任务开放暂停/继续；头像等没有持久重新授权上下文的任务不提供虚假的继续能力。它们的活动前台字节任务仍可显式取消。原生后台任务及上传/导入尚未接入本轮控制，不显示不可执行按钮。
- 手动暂停阻止普通前台重入暗中恢复；显式继续事务重新检查原引用、切回 run 并排队，沿用上一节账号级重新授权/版本检查及原任务恢复。暂停后进程退出，冷启动保持暂停；取消请求落盘后进程退出，冷启动先排空对应残留，再显示已取消。确认/发布与控制竞争时，完成提交检查 control，迟到成功不能覆盖用户请求。
- 恢复中的单个 SharedOperation 被用户停止时，账号 scheduler 保持存活，可继续接收 resume 和其他任务；只有 scheduler 自身取消才向上结束。还处理旧失败 flight 尚有消费者退场时的新准入：等待旧 flight 移除后再加入/创建，避免新继续请求重用过时的取消结果或串改每键消费者计数。等待有所有者、可独立取消，关闭时会解除。
- 底层传输即使不配合取消或以 URLError.cancelled 返回，也会在写入返回后检查取消；不提交成功阶段，不将用户停止伪装为普通网络失败。清理失败保留 cancelling 事实和可重试清理动作；不虚报暂存已清理。页面反馈改为“已请求”，以快照展示实际结果；手动暂停文件的打开错误提供传输页继续入口说明。

当前验证证据：

- 最终 ClientKit相关 **57项、7个suite通过**，日志 `/tmp/im-active-download-complete-client.log`。覆盖显式停止一条有多个等待者的真实前台任务、非配合写入结束前额度仍保留、暂停保留及恢复原partial/UUID、取消后清理、过期操作拒绝、暂停和取消的崩溃请求恢复、恢复调度器暂停后继续存活，以及原下载/后台/保留/文件所有者回归。
- App及所有测试target构建成功；专用iOS27模拟器最终 **25项、4个App suite及4项UI全部通过**，日志 `/tmp/im-active-download-final-app-ui.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_06-23-36-+0800.xcresult`。包含活动暂停后继续、活动取消、离页重试、实际预览像素、保留与清理路径。最后增加的排队暂停/撤权继续拒绝仅修改ClientKit测试文件，随后通过上述57项，未再次修改App生产代码。早期 `/tmp/im-active-download-app-ui.log` 中暂停后继续UI失败，发现并修复了单任务取消错误结束账号scheduler的问题；该早期日志不作通过证据。

尚未完成：上传/导入及原生后台任务的完整暂停/继续/取消、完整全局公平调度、实时字节进度、自动下载/蜂窝偏好、上传/导入历史保留，以及原R0–R6中的头像引用、派生媒体展示、全物理预算、AFU上传映射、真实OSS/真机后台、无障碍和性能门槛。未提交、推送、部署或安装手机。

本阶段最终截图已查看：`/tmp/im-active-download-ui-attachments/446194E2-E7D3-4F46-9AF0-C63657198AC7.png` 显示真实已暂停及继续入口；`0F7B835A-800D-4711-81E5-1F654BE3BBB4.png` 显示同一任务恢复后完成。专用模拟器中的隔离 `v2-resource-center-ui-<UUID>` 测试遗留已在测试进程结束后清理，同前缀剩余0；未操作真实账号目录。`git diff --check` 通过。


## 追加实施：系统后台下载取消、重新授权重试与无人查看时发布（2026-10-24）

本节补齐之前管理页不能操作系统下载、失败后不能从同一任务恢复及已收到字节仍需原页面完成发布的缺口；后台暂停仍未实现，不展示暂停按钮。

- ResourceCenter 直接登记账号的 BackgroundDownloadCoordinator，而非依赖先创建前台 Cache 才能分派命令。登记核验 account 和同一 FileStore 实例，拒绝其他 incarnation 的执行器且不关闭被拒绝的外部 owner。账号 close 即使没有 Cache 也会排空登记的 native owner；App 装配调用改为可抛错，沿用 activation discard 清理。
- 管理页可按原 job ID 请求后台取消，先提交 canonical cancelled/cancelling，再唤醒账号协调器。实际 OS 任务、后台容量 permit 和收件所有权保留到真正排空后；创建中即使已有未安装映射的 suspended 系统任务，也必须先取消并等待其 preparation 和实际任务结束，才写 stopped。进入本地页面但传输尚未装配时，取消意图可先落盘，由随后 native initialize 对账闭合。
- 后台任务在创建前冻结可信字节数/摘要；后续计划可换 URL/grant，但不能换原文件。等待后台失败任务只在原消息当前可见、冻结事实齐全、无其他执行 owner 时提供 retry。原暂停/需处理后台任务复用 UUID，新授权不具备后台委托或摘要/长度变化时在创建任何 OS 任务之前拒绝，不偷偷退回前台创建另一条下载。
- 恢复命令与前台共用下载 journal 的 resume_requested、账号级恢复观察和 Cache 执行所有权。后台原生状态仍由原协调器唯一维护，publication owner 不另建任务表。冷启动可接管旧 owner；原任务被取消甚至终态历史已被清理后，迟到授权不能用旧 ID 创建新的任务。账号关闭仍等待不配合取消的授权请求实际返回。
- 后台完成回调把可重新授权的消息任务标为待发布恢复。账号活动能在原页面不在时取新授权、校验、发布并闭合任务；本机已有相同 verified 字节时复用文件，同时释放原生 raw inbox 和预留，不再下载第二次。同一 Cache 内仍有原 physical publisher 时先加入它，不能提前删除它正在使用的原始收件。
- 已下载但发布/授权失败的后台任务保留原始收件和恢复事实，展示明确需处理原因，允许合法重试或取消。任务完成以已验证发布为准，临时来源清理随后由真实 owner 排空，不以 UI 命令返回代替清理完成。
- 修复实际重试链路暴露的时序错误：原协调器在查询实际系统任务前读取 receipts，系统任务可能在 await 期间成功完成，旧 receipt 快照却把它当失败，丢弃成功收件并启动下一次下载。现在确认实际任务不存在后重新读取 receipt；确实尚未交付时给予至多2秒、受原许可到期约束的有界等待，持续保有对应容量。映射的等待记录随 release/close 释放，不无限增长。
- 完成提交与用户取消竞争时，原生 didPublish 不再在 retire 失败后静默声称成功；只有已确认 completed 的幂等调用才可接受，否则传播取消。未放宽文件保护、临时许可、校验和访问权限。

实际验证：

- 最终 ClientKit **66项、7个suite通过**，日志 `/tmp/im-native-download-final-scoped-client.log`。选择了 native coordinator、canonical 下载/管理任务、Cache、FileStore、Center和retention回归。新测试包含：5次真实受控原生传输失败后以同UUID重新授权成功、活动取消排空前permit/预算保留、创建未映射任务时取消仍等待真实drain、冷恢复owner、403/版本变化/缺少后台授权不产生native任务、无原页面的收件自动发布及命中缓存、未装配先取消、历史清理后迟到结果不复活、账号close等待实际授权返回、其他incarnation执行器拒绝。
- 初始 `/tmp/im-native-download-management-tests.log`、`...retry-debug.log`、`...retry-debug2.log` 的完成等待失败真实暴露了上述旧receipt快照错误，不作为通过证据。`...full-client.log`、`...final-client.log` 另有测试在完成事实提交与异步raw清理之间立即断言路径的竞态，已改为等待实际预算归零再验证文件消失；最终结果以上述 scoped-client 为准。
- App及所有测试target构建成功，专用iOS27模拟器最终 **31项、5个suite通过**，日志 `/tmp/im-native-download-final-scoped-app.log`；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_06-47-25-+0800.xcresult`。包含资源管理Store、native bridge、媒体下载、lease和本地启动。新增页面Store测试验证没有创建ForegroundCache时，取消也通过登记的native owner进入原任务终态。早期新增测试的跨模块await/闭包@concurrent签名编译问题已修复，没有放宽并发检查。
- 资源中心 **4项UI通过**，日志 `/tmp/im-native-download-app-ui.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_06-41-05-+0800.xcresult`。覆盖原前台暂停/继续、取消、离页重试以及保留、预览像素和清理。后续只补了native创建期取消等待/作用域校验及测试，UI源未变；最终iOS构建和31项已覆盖最新生产代码。上述native传输测试使用受控driver及真实FileStore，**不等于真机URLSession后台或真实OSS验收**。
- `git diff --check` 通过；未提交、推送、部署、安装手机或删除用户数据。

剩余完整目标保持不变：系统后台下载暂停/继续、上传与导入的完整管理控制、实时字节进度、全局公平调度、自动下载/蜂窝策略、上传/导入历史保留、头像引用与衍生媒体展示、完整物理预算及AFU上传映射、真实OSS与真机锁屏/终止、无障碍与Release性能验收。不能用本节替代全部R0–R6退出条件。


## 追加实施：共享字节额度、方向限制、交互预留与排队老化（2026-10-24）

本节完善既有账号网络调度器的资源传输准入；没有另建任务状态表或第二个物理字节调度器，也不表示完整R3的任务生产和管理控制均已结束。

- 核对实际App装配后确认，前台PUT、前台Range、原生上传、原生下载原本已共用 accountRuntime.scheduler；旧问题是只有总量2的无方向字节额度和与普通HTTP共用的等待容量。本次将 WorkKind 改为必须携带 upload/download 方向的关联值，不保留无方向别名或旧调用fallback；四个真实transport均显式使用正确方向。
- 默认总量4、上传2、下载2。已有OS任务先按方向接管，实际I/O超过新总量或任一方向额度时，阻止所有新字节任务，直到越额排空；接管不消耗重试token，也不会假装系统I/O不存在。permit仍必须在实际传输结束/取消排空后归还，普通HTTP和认证维持各自执行通道。
- 字节等待队列独立、默认最多128；普通队列256和控制队列64不与它互相借用。队列满仍允许可立即执行且不插队的另一方向请求直接进入空槽，避免上传积压把空闲下载方向误判过载。orderingKey的先来命令仍跨准入池保持FIFO。
- 自动预取使用background优先级，默认在全局和各方向均保留1个用户/恢复额度；不会因为后台传输载体就把用户明确打开的文件降为预取。单槽/降级配置至少允许一个任务前进，不承诺抢占已运行I/O。既有加权轮转继续运行；字节排队15秒后按先来顺序老化选择，仍必须满足方向/总量、预取保留、服务冷却及同键先后约束。
- 前台Range/PUT继承业务WorkScope优先级；上传步骤的正常用户意图采用interactive，失败恢复采用recovery。原生上传新准入同样继承scope。原生下载在canonical job保存work_priority，由实际prepare读取，不依赖创建prepare的actor/task是否继承了页面上下文。
- 自动下载的前台意图同样保存优先级，冷恢复保持background；只有用户明确重试/继续才提升原任务的持久意图。恢复执行范围使用recovery或保留background，并继续共享retry/cooldown预算。接管已经存在的OS任务时，在受保护业务库可能不可读的边界，保守按background记账；这不改变正在执行任务的物理事实，也不会让预取借走保留额度。
- 账号快照增加活跃上传、活跃下载、等待字节和background字节任务计数，均为数量，不含URL/文件名/凭证。

实际验证：

- 调度器最终 **29项XCTest通过**：`/tmp/im-byte-direction-final-scheduler.log`。覆盖4总量/2每方向、认证独立、各方向/全局预留、真实128等待上限、满字节队列仍可进入空闲方向、接管方向越额及身份不串用、取消等待/实际I/O排空、老化不突破保留或同键顺序，以及原冷却/retry/加权公平回归。
- 资源/后台/Range/目录/预算/下载/上传取消等相关 **198项Swift Testing、34个suite通过**：`/tmp/im-byte-direction-final-client.log`；该组合同时通过当时27项调度器XCTest，之后仅追加两项老化边界测试并通过上述29项。不是整个ClientKit全库测试声明。
- 实际URLSession叶子测试同时启动3个上传和3个下载，验证恰好2上传+2下载占用、其余2个等待，取消后全部准入归零；另验证自动Range下载保持background且不占用户保留槽。它们使用受控URLProtocol黑洞和实际URLSession取消路径，不依赖纯计数mock冒充transport集成。
- 原生driver/真实FileStore测试验证用户和自动下载的持久优先级进入真实scheduler；前台冷恢复测试验证自动优先级不暗中升级，明确继续才提升。所有URL/grant、摘要/长度、发布、权限与账号退役规则继续有效。
- App及全部测试target构建成功，专用模拟器 **36项、7个suite通过**：`/tmp/im-byte-direction-app-tests.log`，结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-00-29-+0800.xcresult`。包括资源页Store、native桥接、媒体下载/lease、附件上传、持久原件和本地启动。本阶段未修改页面结构，未重跑UI自动化，也没有真机/真实OSS结果。
- `git diff --check`通过。未提交、推送、部署、安装手机或清除用户数据；没有历史schema迁移或兼容读取器。

仍须继续：上传步骤/下载恢复等canonical生产者目前仍有串行恢复循环和本地flight上限；共享flight后来加入交互消费者时的排队优先级提升也需接入，不能把本节的物理准入当成完整任务级公平调度交付。系统后台暂停/继续、上传/导入管理控制、实时字节进度、自动下载偏好及实际政策、上传/导入历史保留，以及其他R0–R6的媒体索引/预算/AFU/真机/OSS/AX/性能退出条件全部保留。


## 追加实施：有界上传步骤、下载恢复与实际容量唤醒（2026-10-24）

本轮把此前仍串行的canonical恢复生产者接入事件驱动的有界执行；没有第二份可写任务表，没有新增历史兼容读取或fallback。

- `V2ResourceTransferEngine` 使用既有flights最多执行两个步骤，一个结束即处理下一个，慢任务不阻塞已空闲的位置。查询排除实际运行ID；持久观察包含任务身份而非只MIN(retry_at)，同到期时间的新任务也会触发重新查询。
- `V2ResourceDownloadCache` 使用既有resumedDownloads最多执行两个恢复任务，正常失败写入原journal后继续其他任务；显式暂停/取消不结束整个恢复activity。持久观察包含ID和优先级，不以相同COUNT误判没有变化。
- `V2CommandRetrySchedule.waking` 合并持久数据库变化和运行时容量变化。每轮activity使用独立流，结束时取消其观察者；容量事件是提示，所有决策重新读取canonical事实。
- 恢复下载在四个实际physical flight已占满时等待释放；不会把等待写成space错误。相同identity仍可合并，实际flight完全释放才唤醒容量等待；close终止等待并排空实际I/O。
- 上传activity取消或基础设施错误会取消并等待实际步骤结束；重新启动且无live flight时更换执行owner，回收上轮数据库释放失败留下的claim。下载activity取消维持此前的账号所有权语义，只分离scheduler；同cache重启仅释放既无live resumption也无未结束physical identity的闲置claim。
- journal写入失败向账号activity传播，不默默遗留不可调度任务。测试注入SQLite trigger阻止释放，移除故障后直接在同一engine/cache重启恢复，无需重建账号对象。

验证证据：

- `/tmp/im-resource-pump-regression.log`：50项Swift Testing、4个suite通过，覆盖上传步骤、下载缓存、原生后台下载和重试唤醒。
- `/tmp/im-resource-pump-client-final.log`：190项Swift Testing、32个suite以及29项调度器XCTest通过。新增测试证明A/B占用两位时C保持排队，B完成后C可在A持续阻塞时完成，随后新加入D也能完成；上传和下载均通过。上传claim释放故障的同engine恢复也在此组合通过。
- 之后仅增加下载物理容量边界用例，`/tmp/im-resource-pump-capacity-final.log`：20项下载缓存测试通过。四个不同identity的真实FileStore下载占满局部physical额度，第五个已获恢复claim但仍保持preparing且无space错误；释放一个实际writer后第五个完成，最大实际writer数始终4。同一cache数据库修复后的恢复测试亦通过。
- `/tmp/im-resource-pump-app-final.log`：App和测试target构建成功，专用模拟器36项、7个suite通过；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-14-23-+0800.xcresult`。覆盖资源页Store、native桥接、媒体下载/lease、附件上传、持久原件及本地启动。本轮没有页面布局修改，未重跑UI自动化；后加的容量用例仅改变ClientKit测试源码。
- 未提交、推送、部署、安装手机或清除用户数据。真实OSS、真机锁屏/强退以及Release性能仍无本轮验收证据。

完整目标仍未完成：共享flight后加入交互消费者的优先级提升、直接新请求的完整有界排队、系统后台暂停/继续、上传/导入管理和历史、实时字节进度、自动下载/蜂窝政策、媒体目录/衍生展示、完整物理预算/AFU上传映射与R0–R6真机/OSS/AX/性能门槛继续保留。


## 追加实施：原生后台下载手动暂停、同任务继续及冷预约清理（2026-10-24）

本轮补齐后台下载管理命令，修改目标schema及强类型状态，不增加旧schema读取或兼容fallback。原生系统任务不使用含临时请求信息的resumeData；继续保留job身份并重新授权下载，不声明恢复到原字节偏移。

- canonical download新增pausing状态及合法control约束。requestBackgroundDownloadPause在事务中验证消息引用仍可见、字节事实已冻结、当前处于preparing/transferring；先持久化control=pause及pausing，再通知账号协调器。
- ResourceCenter.pauseTransfer区分前台/原生后台；即便cache与后台owner尚未附加，也能保存原生暂停请求。既有任务读模型在pausing期间显示正在暂停；仅actual drain与暂存回收结束、原mapping清空后显示paused和resume操作。校验/发布期间不提供pause。
- 协调器取消并等待preparation实际返回，再按最新mapping取消并等待OS任务结束。暂停不会把任务写成取消或结束历史。用户在pausing期间取消时，cancel覆盖control并在后续对账结束原任务；paused前不允许resume。
- 继续由原download恢复队列消费，同job ID、原消息、冻结摘要和长度保持不变，显式继续提升interactive意图；新请求重新鉴权并验证后台能力。手动暂停任务拒绝普通页面重开时自动retryPaused。自动故障达到预算的paused仍允许既有显式retry。
- 迟到完成只允许匹配transferring状态及完整mapping推进，不能覆盖pausing/paused。账号close的mapping保留集合和清理已覆盖pausing。
- 冷协调器测试暴露旧FileStore暂存预约未出现在新owner运行时map时无法回收的问题。新增FileStore.discardBackgroundDownload按精确session/mapping及journal记录清理；仅在实际系统writer排空后调用，不需临时申请新容量。旧owner未接管的预约也先物理清理、再发布paused，避免残留预算导致close永远等待。

验证：

- `/tmp/im-native-pause-client-final.log`：193项Swift Testing、32个suite和29项调度器XCTest通过。新增参数化管理测试覆盖正常传输/尚未返回的native create，分别继续成功、暂停中取消、继续前撤权，共6组场景；验证排空前permit和双份磁盘预算保留、排空后归零、不可提前继续、普通打开不恢复、继续同UUID且重新授权、撤权不创建第二个任务。
- 另新增未附加网络owner时持久暂停请求、由新协调器接回原native映射的测试；验证冷预约清理、映射保留到排空、暂停前后迟到成功均不能写入，以及没有第二个OS下载。
- 初次冷预约测试发现预算残留并使cleanup等待；终止已确认失败的本轮测试进程，修复FileStore回收路径后重新执行完整上述组合通过，没有因观察超时直接重启任务。
- `/tmp/im-native-pause-app-final.log`：App与测试target构建成功，专用模拟器36项、7个suite通过。结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-21-57-+0800.xcresult`。页面使用既有pause/resume行和状态展示，本轮未修改布局，也未重跑UI自动化。
- `git diff --check`通过。未提交、推送、部署、安装手机或删除用户数据。原生driver受控集成不能替代真机URLSession锁屏/系统终止或真实OSS验收。

完整目标仍需继续：上传/导入管理控制与历史、共享flight交互优先级提升、直接新请求完整排队、实时字节进度、自动下载/蜂窝政策、头像/衍生媒体目录与展示、完整物理预算/AFU上传映射，以及真实OSS、真机、无障碍和Release性能门槛。后台下载pause/resume的代码与受控集成门槛已推进，但真实设备交付门槛保留。


## 追加实施：账号下载网络偏好、前台Range与原生后台执行限制（2026-10-24）

本轮交付网络政策的纵向链路，未把未实现的自动下载分类或触发器做成假开关。没有历史兼容读取、新旧双写或服务端合同变更。

- 新增V2ResourceDownloadNetworkPreferences及目标schema表，账号内持久化allows_cellular与allows_constrained；默认允许蜂窝、不允许低数据模式。ResourceCenter提供账号关闭边界下的读取和写入，GRDB投影将变化通知为resources。
- 新增短期V2ResourceDownloadNetworkConstraints，临时下载target只可交集收紧约束，不可由后续较宽松的适配器暗中放开；这些限制不进入签名、资源身份或日志，也不使本地已验证字节失效。
- V2ResourceDownloadCache的消息、头像及冷恢复读取当前账号偏好。V2URLSessionMediaByteTransfer对每一条实际Range请求设置allowsCellularAccess、allowsExpensiveNetworkAccess和allowsConstrainedNetworkAccess；原生后台prepare重新读取偏好，V2BackgroundDownloadRequest对实际交给URLSession的请求设置同样限制。
- 后台载体不等于自动预取：用户下载仍按interactive/recovery处理，只有background意图应用自动网络收紧（禁蜂窝、昂贵、受限网络）；既有持久priority恢复不暗中升级。已启动的OS任务保持原设置，新请求和重试读取新偏好；没有假装即时暂停旧任务。
- 存储管理新增两行连续Toggle；页面任务负责执行命令，保存期间禁止并发修改；保存失败保持上次确认值并给出反馈。离页返回从账号DB读取，不使用全局UserDefaults。

验证：

- `/tmp/im-resource-network-client-final.log`：195项Swift Testing、32个suite以及29项调度器XCTest通过。包括逐个Range请求的限制、限制不可放宽、前台冷恢复使用当前偏好、自动意图恢复保持限制和原生driver实际构造的URLRequest限制。
- `/tmp/im-resource-network-persistence.log`：追加1项真实关闭GRDB再打开测试通过，并验证另一账号读取默认值而不是前一账号偏好。这是后加测试，未重新运行前述完整组合。
- `/tmp/im-resource-network-app-final.log`：App及测试target构建成功，37项、7个suite通过；新增Store保存成功、页面重建读取，以及SQLite trigger注入写入失败后保留确认值。结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-27-15-+0800.xcresult`。
- `/tmp/im-resource-network-ui.log`：原目录/详情/保留/真实像素预览/清理UI通过；新增开关UI首次失败，检查测试隔离库发现没有触发写入。该次已明确失败的xcodebuild结果收尾未退出，随后终止该已失败进程。测试点击改为AX开关框右侧实际控件后，`/tmp/im-resource-network-ui-retry.log`单独重跑新增网络开关用例通过：两个开关保存成功、离页返回值一致，且自动清理本次fixture。
- UI最终结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-31-50-+0800.xcresult`。导出并人工检查截图 `/tmp/im-resource-network-ui-final-attachments/C5C8A10B-19AF-4714-AA60-20D40FBF8D07.png`：蜂窝关闭、低数据模式开启，同组连续分隔，标题与页脚无重叠。进程结束后检查首次失败的精确隔离fixture `v2-resource-center-ui-300D5FE9-051F-4A3D-A03B-12066EDC4C98`，该路径已不存在，未再执行删除；没有删除其他账号或用户数据。
- `git diff --check`通过；未提交、推送、部署或安装手机。没有真实蜂窝网络、真实URLSession低数据模式或真实OSS的本轮验收证据；受控请求属性测试不能替代真机网络政策验收。

仍须继续完整目标：自动下载媒体分类/大小阈值/实际生产队列和网络恢复触发、上传/导入管理控制与历史、共享flight交互优先级提升、直接新请求完整排队、实时字节进度、头像/衍生媒体目录与展示、完整物理预算/AFU上传映射、真实OSS/真机/AX/Release性能门槛。网络开关已纵向接通不代表整个自动下载系统或R0–R6完成。


## 追加实施：自动分类/大小政策、持久目录准入与账号执行（2026-10-24）

本轮将上一阶段明确未交付的自动分类与生产者接入真实执行。直接修改目标schema，不增加历史兼容读取或双写。

- V2ResourceAutomaticDownloadPolicy使用明确分类集合及1至512MiB范围内的大小上限；拒绝all这一查询类别作为自动策略。默认图片、10MiB，视频/音频/文件默认关闭。策略与网络偏好同表持久化并触发资源投影。
- 存储管理增加同组四个分类开关和大小Picker。Store命令沿用页面.task执行；保存网络字段时保留自动策略，分类/阈值修改也保留网络字段，失败仍保留确认值。
- GRDBV2AutomaticDownloads只从当前账号本机目录的可见消息引用、ready状态、非空摘要、启用类别与大小范围选择资源；跳过已有published缓存或下载记录，单次最多2条，服从16条未结束download的准入上限。创建既有foreground canonical job，background优先级、冻结摘要/长度、resume_requested，随后原cache恢复worker进行新授权和字节执行。
- 将目录、引用、偏好、缓存和既有任务读入恢复ValueObservation跟踪范围。偏好或目录改变可改变候选集合并唤醒调度，不需要页面轮询或另建后台循环。实际App账号装配已核对：V2AppStore的mediaCacheMaintenance.runRecovery连接同一cache，因此生产者处于账号活动范围。
- 资源目录条目的automatic_download_admitted是一次性准入事实，不复制任务阶段或重试计数。测试删除完成历史并清除物理缓存后，目录重扫不会再建同一资源的自动任务，避免容量淘汰与预取互相循环。
- V2ResourceDownloadCache对background意图重新校验元数据与策略；原生prepare同样在create之前核验。新增policy下载issue和automaticDownloadRestricted展示原因。原生准备被规则拦下时保存paused/policy；显式管理重试仍提升为用户意图，禁止把分类/大小规则套到主动下载上。手动暂停、取消、原权限、冻结版本及网络限制继续生效。
- 原有自动优先级测试使用通用文件夹具；现在显式开启file类别后继续验证原优先级不变，未删除原断言或绕过政策。数据库重开测试也覆盖非默认的video/audio/file集合和大小。

验证证据：

- `/tmp/im-auto-producer-behavior.log`：42项、3个suite通过，包括新增默认大小限制、修改策略唤醒image/file生产者、自动关闭不启动字节但主动下载成功，以及清理物理缓存和完成历史后不重复准入。
- `/tmp/im-auto-policy-client-final.log`：198项Swift Testing、33个suite及29项调度器XCTest通过，覆盖资源、后台、Range、配额、取消/暂停、调度与恢复。
- `/tmp/im-auto-policy-app-final.log`：App及测试target构建成功，37项、7个suite通过；Store测试增加分类与阈值修改，验证保留原网络字段及写入失败时确认值不丢。结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-39-51-+0800.xcresult`。
- `/tmp/im-auto-policy-ui-final.log`：2项UI通过，覆盖新分类开关真实操作、离页返回后保存，以及既有目录/原图预览/保留/任务/清理回归；清理入口增加后通过有界滚动进入。结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-41-05-+0800.xcresult`。
- 为检查完整自动设置区域，在网络/自动偏好UI用例末增加一次实际滚动后，`/tmp/im-auto-policy-ui-visual.log`重跑该用例通过；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-44-29-+0800.xcresult`。导出检查 `/tmp/im-auto-policy-ui-visual-attachments/E0E689A8-CEDD-4FA6-A4E8-16E64AED971F.png`：图片、视频开启，音频、文件关闭，大小Picker及清理入口完整，同组分隔连续且文案无重叠。所有UI用例均清理各自隔离fixture。
- `git diff --check`通过。未提交、推送、部署、安装手机或清除用户数据；没有本轮真实OSS、真机蜂窝/低数据模式或锁屏传输验收。

剩余完整目标保持：网络可用性事件接入、网络恢复后的有界自动重试、规则重新允许时恢复既有受限任务；本轮新自动任务走可恢复前台传输，不承诺进程挂起后继续执行。另有上传/导入管理与历史、共享flight交互提升、完整排队、实时进度、媒体目录/衍生展示、全部物理预算与AFU、真实OSS/真机/AX/Release性能退出条件，不能据本节标记整个方案完成。


## 追加实施：账号网络监听、原意图自动退避与政策恢复（2026-10-24）

本轮补齐前一阶段明确保留的网络事件、有限自动重试与受限任务恢复。目标schema直接增加canonical重试资格列，无旧schema读取或兼容层。

- 新增V2ResourceAutomaticNetworkSource和不可变conditions。system通过NWPathMonitor将可用性、蜂窝、昂贵、受限网络转换成有界AsyncStream；DispatchQueue只用于SDK回调桥接。每个账号recovery activity单独订阅、取消、generation校验，不绑定任何页面。测试可注入同合同源，不读取实际外网状态作为断言依据。
- Cache在未知/不合规路径下不生产自动job，不claim需要新字节的background优先级意图；手动请求仍可尝试，受原URLRequest设置和业务权限限制。合规路径更新唤醒原调度；已下载的native后台收件可以继续授权发布，不受新自动字节门槛误拦。
- 对明确可恢复的URLError、HTTP超时/408/429/5xx以及targetExpired，在实际writer排空后记录原job的automatic_retry_allowed和retry_at_milliseconds。采用指数退避及0.75–1.25倍jitter，与Retry-After取较晚值；request查询和claim都核验到期时间，调度查询返回未来最早时间而非到期空转。普通进度不影响时间或排序。
- 每次claim清除旧重试资格，只有本次明确临时/政策错误才重新授予；不会把泛化的network issue当成重试许可。恢复仍用原消息、摘要/长度、jobID和原attempt_count，最多5次。重启activity或网络反复切换不能重置次数。用户明确retry/resume才重置本轮、清除旧自动标记及冷却时间并提升interactive。
- requeueRecoverableAutomaticDownloads重新核对当前分类/大小、消息可见性和冻结版本，只唤醒有资格且attempt<5的原前台任务。policy从禁用变允许也进入观察签名，解决没有新目录候选时漏唤醒的问题。手动暂停/取消、永久权限/完整性/空间错误均不自动恢复。
- 修正底层byteCountMismatch、checksumMismatch、Range版本变化的任务原因归类为integrity，避免显示成一般网络问题；它们不获得自动重试资格。未来到期的原任务用既有waitingRetry展示，无新增页面结构。

实际验证：

- `/tmp/im-auto-network-behavior-final.log`：25项下载缓存测试通过，包含网络资格门槛、政策恢复与fake clock下五次预算。
- `/tmp/im-auto-network-client-final.log`最终203项Swift Testing、33个suite及29项调度器XCTest通过。新增两组“第5次成功/连续失败”的受控网络测试，验证cellular/constrained不创建自动任务、恢复后同ID、offline期间时钟前进不执行、activity重启保持预算、上限5次以及监听subscriber退出归零。新增Retry-After持久往返、提前claim拒绝；政策与网络同时允许才恢复同job；手动暂停/取消不复活；校验/授权永久失败保持单次且无重试许可。
- 首次较大范围回归暴露测试混用时间：执行器使用fake clock，断言却依赖按真实Date计算的waitingRetry文案。改为直接核对canonical已释放owner、原attempt、resume_requested和基于fake clock的持久到期时间后，保留5秒超时及所有次数/提前执行断言，再跑完整203项通过；未通过延长等待或放宽预算规避问题。
- `/tmp/im-auto-network-app-final.log`：App及测试target构建成功，专用模拟器37项、7个suite通过；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_07-56-42-+0800.xcresult`。本轮没有页面布局/操作改动，未重复UI自动化；此前分类与存储页面截图和UI证据仍属于其相应构建。
- `git diff --check`通过。未提交、推送、部署、安装手机或清除用户数据。测试的网络事件是可控注入，真实NWPathMonitor已编入App但不据此声明真机蜂窝、低数据模式、后台锁屏或真实OSS验证完成。

完整目标仍保留：原生自动下载准备/重试与当前前台自动producer的统一端到端验收、上传/导入管理与历史、共享flight交互提升、完整排队、实时进度、媒体目录/衍生展示、全物理预算与AFU上传映射，以及真实OSS/真机/AX/Release性能退出条件。此阶段不能替代全部R0–R6完成审计。


## 追加实施：统一完成历史、保留恢复事实与有界metadata回收（2026-10-24）

本轮补齐上传/导入完成历史，统一本已存在的下载历史政策。直接修改目标schema并替换内部download-only维护入口，没有旧schema读取器、兼容别名或双写。

- 上传和导入canonical表增加finished_at及history_retired，上传/导入目标schema触发器在首次ready/cancelled时记录SQLite当前终态时间；重复回包不延长年龄。源文件、业务绑定、请求及执行状态仍在原owner/journal，不另建history任务表。
- GRDBV2ResourceTransferHistory对无执行owner及无活跃native映射的ready/cancelled上传/导入、completed/stopped下载统一计算最近500条及30天展示范围。创建很久但刚完成的任务仍保留；未知、失败和待处理任务不自动隐藏。
- 物理metadata GC每类最多64条，仅回收已退役且无任何恢复依赖的事实。上传额外要求source_released且无原件消费者，发送依赖、个人头像非FK引用、群头像FK引用、active/completed原生映射均保护原行；导入发送依赖保护原行。GC不删除依赖边、文件、保留意图、消息或OSS对象。
- 接入账号资源中心初始化、历史订阅、终态upload step/import execution释放、上传源释放及原下载完成/恢复路径。所有旧pruneResourceDownloadHistory调用替换为统一pruneResourceTransferHistory，不保留旧入口。
- 仍有本地执行owner或active原生upload映射时，终态ready/cancelled留在进行中并显示verifying/cancelling，直到实际owner释放或系统任务映射结束，防止取消尚未排空却被算作历史并隐藏。
- 历史和自动下载交叉回归发现：手动取消记录被清理后，目录若没有准入标记会被自动生产者重建。现在在同一退役事务中，将对应room/media的既有处理事实保存到目录标记，再删除历史；不会因历史回收、缓存丢失或网络恢复而复活用户取消。
- 增加上传/导入退役候选partial索引、个人头像upload反查、import dependency job反查、原生mapping job反查索引。自动准入标记更新使用退役下载列表驱动的复合主键IN，避免对整个目录逐项运行相关子查询。新增EXPLAIN QUERY PLAN断言覆盖实际维护SQL的精确主键搜索及三类依赖索引，不把该证据当成完整Release性能验收。

验证证据：

- `/tmp/im-resource-history-behavior.log`初期6项真实GRDB/FileStore用例通过；之后新增群头像、native活跃/迟到回调、手动取消与查询计划保护并纳入最终组合。
- `/tmp/im-resource-history-all-final.log`最终239项Swift Testing、37个suite及29项调度器XCTest通过。包含10项新增历史用例：500条跨三类型共享；删除upload metadata不删除仍借用文件；退役后原上传/导入冻结消息仍可handoff；live import owner保护直到释放；首次完成时间与回放；个人头像非FK引用保护及移除后可GC；群头像引用保护；active native映射仍显示cancelling、completed墓碑保护且迟到回调不能复活；手动取消历史回收不触发自动下载；SQLite注入删除失败事务整体回滚。跨类型500条与借用文件保护合并在同一用例，查询计划为独立用例，共10项。
- 最终组合同时覆盖原有group avatar、profile intent、terminal command retention域回归，不仅资源页单测。此前单独26项域回归也通过，最终239项包含这些26项，不额外重复计数。
- `/tmp/im-resource-history-app-final.log`：App与测试target构建成功，专用模拟器37项、7个suite通过；结果包 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_08-23-25-+0800.xcresult`。本轮无页面结构改动，未重跑UI自动化；active/finished分组及状态在真实journal测试和App Store测试层验证。
- `git diff --check`通过。未提交、推送、部署、安装手机或删除用户数据；所有物理文件借用和删除验证都在本轮隔离临时fixture内。没有本轮真实OSS、真机锁屏/终止、无障碍或Release性能结果。

完整目标仍需继续：上传/导入的暂停/继续/取消等管理命令及失败任务处理，原生自动下载完整闭环、共享flight交互提升、直接请求完整排队、实时进度、媒体目录与衍生展示、全物理预算与AFU上传映射，以及真实OSS/真机/AX/Release性能退出条件。不能据完成历史这一交付标记全方案完成。

### 共享前台flight交互提升（2026-10-24）

- 增加`V2ByteTransferDemand`：同步小边界只保存单调需求与调度订阅，回调离开Mutex后执行，不在锁内做业务或I/O。TaskLocal传递同一物理flight的需求；只供下载byte准入使用，不改变ordinary/authentication/upload流量。
- Scheduler在不挂起的登记/入队边界观察需求，支持登记前和排队后的提升；回调按私有waiter ID定位，乱序提升不能降级，保留service/kind/orderingKey/isRetry、原排队时间与原continuation。订阅在准入返回、取消、过期/关闭退出时清除。不提前归还活跃字节槽位。
- DownloadCache合并消费者时提升同一需求，并按job ID+owner更新前台journal优先级；不改attempt/控制状态/唯一ID，不创建第二个writer。尚未开始的flight以最新需求创建journal，已有journal的自动退避不会重新覆盖已提升为交互的任务。网络限制保持原冻结策略。
- 新增4项行为测试：调度器中提升仅放行对应共享下载、其他自动任务继续等候且占用permit未被释放；登记前提升不会丢失且取消清理订阅；真实GRDB/FileStore共享flight提升持久优先级、原消费者取消后另一个仍读到校验字节且仅1次传输/1条历史；实际URLSession Range传输使用用户预留名额完成且释放订阅与字节permit。HTTP通过隔离URLProtocol提供，不属于真实OSS测试。

本轮证据：`/tmp/im-shared-download-priority-final.log`为198项Swift Testing/31个suite和31项XCTest通过；`/tmp/im-shared-download-priority-app.log`为iOS App与测试target构建及13项/2个suite通过，结果包`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_08-38-38-+0800.xcresult`。`git diff --check`通过。没有本轮真机、OSS、AX或Release性能证据；未提交/部署/安装或清理用户数据。

原生后台prepare/冷恢复/已运行OS任务的需求提升、上传/导入控制、完整排队/进度、媒体网格及R0–R6其余条件继续保留。前台共享优先级这一项已产生验证证据，不代表全目标完成。

### 原生后台需求提升与冷回接（2026-10-24）

- `GRDBV2BackgroundDownloads.promoteBackgroundDownload`按账号/精确job事务单调更新优先级，仅接受control=run且preparing/transferring/downloaded；不改attempt、retryAt、mapping或状态。暂停/取消/终态返回无可提升结果，跨账号明确失败。
- 协调器订阅共享flight需求，将更新合批为有界待处理命令；account activity先提交持久事实，再更新准备任务的需求和运行permit。失败继续向activity传播，并保留未提交的优先级脉冲，不静默只改内存。protected data保护检查之后才处理业务命令。
- 原生prepare每任务显式拥有自己的`V2ByteTransferDemand`。共享token在等待SQL前建立，避免准备快照与提升交错时替换掉新需求。读取方/准备任务退出均清理不再需要的需求；调用方取消只撤等待者，实际OS传输沿用原owner排空语义。
- scheduler增加受身份验证的下载permit提升；只改变准入分类，不多给一个名额，不释放活跃字节，也不改变系统task或网络限制。初始回接先保守adopt所有actual task；业务库可读后按持久priority校正，避免所有用户任务重启后永远记作background。
- 新增共享cache→后台协调器→真实GRDB/FileStore→受控driver的排队与已运行两个参数场景：只创建一次系统task、原job/attempt/retry不变、用户加入提升、原自动等待者取消后用户仍读到完整字节、结束释放真实permit。既有冷owner测试扩为锁定/解锁×interactive/background四种，验证保守回接及可读后的分类。新增实际数据库关闭/重开与域控制保护，以及scheduler活动permit身份/方向/单调性测试。

验证：`/tmp/im-native-demand-final.log`为200项Swift Testing/31个suite及32项XCTest通过；`/tmp/im-native-demand-app.log`为App与测试target构建及16项/3个suite通过，结果包`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_08-45-44-+0800.xcresult`。早期扩展测试因在`||`自动闭包中直接await导致编译失败，改为分步读取两个actor值后已重跑通过；不是产品运行故障。`git diff --check`通过。

本轮没有真实OSS、真机后台/锁屏/强退、AX或Release性能证据；driver测试只能证明协调器协议和持久/文件边界，不保证iOS会立即执行后台字节。未提交、推送、部署、安装手机或删除用户数据。完整目标继续，上传/导入管理、自动原生完整闭环、请求排队、真实进度和媒体网格等仍未完成。

### 直接读取准入队列与恢复入口隔离（2026-10-24）

- 直接消息读取、头像与恢复共用物理容量等待，不再只有resuming请求才能等待。通过内部ticket保留重新授权期间的名额，flight+ticket合计最多4。等待存储最多14项，用户operation scope16、恢复操作scope2、恢复activity scope1分别有界；仍使用同一账号字节scheduler限制真实I/O。
- 等待队列按优先级及单调等待老化选择，同有效优先级按登记顺序。共享key加入已有flight不另占字节；某key正在复核时不阻塞其他有可用名额的key。超出用户入口明确busy，不把排队写成空间不足。
- 排队后重新进入消息授权/版本边界；头像沿用原能力，固定其最初generation/revision且保持media user计数跨重试，防止失效标记被中间attempt清掉。取消、失败、换key与close均退还ticket，权限失败不启动字节。
- 满载测试首次发现恢复调度activity本身也占用户operation scope，单独为恢复worker留入口仍不足。现将activity和workers分别纳入独立关闭边界；关闭取消并排空所有scope。原测试15秒等待失败明确记录于`/tmp/im-download-admission-recovery.log`；修正实际入口后同场景通过，不是通过延长超时或放宽满载要求。
- 新增6项Swift Testing用例（其中取消/账号关闭为两个参数场景）：16用户上限及12等待项、FIFO头取消后下一项启动；用户优先于自动；消息排队后撤权，二次授权拒绝且无字节；头像等待中失效且无字节；持有授权复核ticket时取消/close，其他请求不能抢位且close等待非协作工作；用户满载时恢复仍登记为第13等待项，保持preparing并在取消部分用户后沿用原job完成。物理writer峰值4有断言。

最终证据：`/tmp/im-download-admission-complete.log`为206项Swift Testing/31个suite和32项XCTest通过；`/tmp/im-download-admission-complete-app.log`为App/测试target构建及25项/4个suite通过，结果包`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_08-54-50-+0800.xcresult`。`git diff --check`通过。测试文件与目录均为隔离fixture，无本轮用户数据删除、提交、推送、部署或手机安装。

运行时准入队列不等同于管理页持久排队产品的全部能力。长期任务的显式排队展示/控制、上传与导入管理、真实进度、媒体网格、全物理预算/AFU，以及真实OSS/真机/无障碍/Release性能验收仍须继续，不能标记完整方案完成。

### 媒体网格及本机缩略图（2026-10-24）

- `V2ResourceDirectoryEntry.localState`按原件variant精确主键及file发布状态查询；该字段参与既有不可变快照比较。`V2ResourceLibraryView`的图片/视频分类为ScrollView+LazyVGrid，其他分类继续List，同源筛选/分页与详情路由。新增`V2ResourceMediaCell`，顶部对齐、可扩展名称与状态、视频标识、保留标记；大字体使用更宽自适应列。
- 新增cached-only借用能力并将App协议与全部实际/测试实现同步接通，没有默认伪返回。它只做授权及已验证本机文件读取，miss不enqueue/download；消息的授权计划须符合索引原件摘要/长度。操作scope处理取消时未交付lease的释放；service解码后归还lease并重新确认源仍可见。局部权限边界沿用安全/隐私技能要求，没有改成“文件存在即可读”。
- 账号缩略图缓存接入持久/缓存双根，校正根与路径符号链接，非file URL先拒绝。原来只接收scope.directory会拒绝独立Caches文件；现按账号精确根列表约束。缓存kind加入键，视频通过AVAssetImageGenerator异步抽帧、限制像素并应用轨道变换；图片继续ImageIO下采样。两个实际解码名额满后有界等待，close结束等待并排空实际任务；不在MainActor解码或复制原件生成缩略图。
- 新增真实GRDB/FileStore cached-only用例，证明miss/版本不符/403均不下载、已有文件可借用、使用中清理跳过、释放后清理成功且目录转needsDownload。新增双根及符号链接逃逸、第三个解码等待、AVAssetWriter生成真实视频再抽帧的测试；延续已有账号关闭/解码取消/隔离测试。
- UI在隔离fixture使用生产目录、缓存、路由及真实PNG。网格测试检测真实蓝色像素，通过普通字号与最大AX字号+深色模式，审计sufficientElementDescription和hitRegion，无issue过滤。标签最初直接包含文件扩展名，被审计标为不可读；改成动作+基名，格式放value后通过，未跳过审计。大字体详情操作在屏下，测试增加导航断言及滚动查找后通过。初期编译的缺失import/构造调用方和测试throws声明已修正并验证。
- 新增符号链接测试最初实际失败：URL直接解析对不存在末级文件不解析其父链接。改为解析最近存在祖先再还原缺失后缀，测试通过。这里不是放宽路径断言。首个大字体UI失败批次在Selected tests已明确失败后，构建进程停在收尾；确认具体PID14527后终止该失败进程，再完成修复与新批次验证，没有因一次观察超时重启仍有效的测试。

最终证据：

- `/tmp/im-media-grid-verified-client.log`：207项Swift Testing/31个suite及32项XCTest通过。
- `/tmp/im-media-grid-verified-app.log`：App及测试target构建，缩略图/资源管理/个人头像/群头像30项、4个suite通过。
- `/tmp/im-media-grid-ui-final.log`：2项网格UI通过；结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_09-13-39-+0800.xcresult`；截图已导出查看：`/tmp/im-media-grid-final-attachments/C44397DB-D572-4FC0-B438-F4B5D42484C5.png`普通双列，`D96379A2-BF0E-4345-9C6F-27204B3CD8A7.png`深色大字体单列。
- `/tmp/im-media-grid-list-regression.log`：既有List→详情→保留→真实像素QuickLook→解除保留→清理1项UI通过，结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_09-15-15-+0800.xcresult`。最后非file URL早拒绝与原件摘要匹配变更由最终ClientKit/App回归覆盖，未额外重复UI批次。
- `git diff --check`通过。未提交、推送、部署、安装手机或删除用户数据；UI清理由fixture自己的随机scope限定。

本轮只做了两项局部自动无障碍审计及字体/颜色适配，不声称完整VoiceOver、所有视频/图片格式、真实OSS、真机后台/锁屏、物理预算或Release性能通过。上传/导入管理、持久排队及进度、尺寸/时长与头像引用、自动原生完整链路和最终R0–R6仍需继续。

### 消息附件准备的依赖取消（2026-10-24）

- 新增`V2ResourcePreparationCancellationPlan`及同库事务：确认计划绑定center私有owner和incarnation，包含精确、排序后的未提交父消息集合。实际执行再次读取集合，在写资源取消标记前先原子取消所有父；集合改变、handoff或其他受保护依赖会拒绝旧计划。SQLite失败整体回滚，未提交任何消息/资源部分副作用。
- 目录任务快照派生`cancellableMessageCount`及cancel能力，上传/导入按钮改为“取消发送”，两阶段操作先审阅再确认。UI显示影响数量，保留冻结payload，不从冻结消息里删除单个附件。共用兄弟资源保留，ready/拒绝等资源事实不改；ready发生在确认前也允许撤回尚未提交父消息，handoff后不能撤回。
- `V2ResourceCenter.attachUploads`校验执行器精确持有同center和同store；生产runtime已接通。账号拥有确认后的有界共享取消命令，页面取消仅分离等待者；单独的`drainRequestedCancellation`不重置取消预算，只显式停止/排空原上传flight与native owner。center关闭合并为同一关闭任务，先停止附加上传owner再等待资源操作/文件，以免提前关闭文件或遗留循环持有。
- 没有在线上传owner时先持久写入父撤回/子取消命令。导入继续由已有durable sender查询或以原operation ID定位，再发原locator取消；新App恢复测试证明原ID仅创建/取消一次且没有消息提交。取消与服务端先完成的两种响应都保留原资源事实，父消息仍撤回。
- 修正旧聊天取消共享导入的路径：`requestImportCancellation`只在没有preparing/handedOff父时写标记，防止取消一条消息误伤另一条。已标记取消的导入不能被新的SendIntent引用。个人/群头像仍由其领域规则保护，本轮没有给它们或无父任务添加伪取消按钮。
- 新增12个Core测试方法及参数场景：混合上传/导入同批取消；多父目标及共享兄弟保护；确认范围改变/已handoff拒绝；ready在确认前及取消回复先完成竞争；已拒绝资源撤回父但不改终态；SQLite注入失败回滚再用原计划成功；离线数据库重开后原import标识不变；共享导入单条聊天取消保护；外来center/engine拒绝；已取消调用者不发命令；页面等待取消后账号命令继续、close等待受控writer排空。数据与原件由真实GRDB/FileStore创建，传输和服务端响应是受控fixture，不是OSS/真机结果。
- App新增确认计划/保留/过期范围/新范围确认的Store测试，以及原import恢复取消集成。UI首次因系统popover嵌套按钮查询重复失败，改为精确ID的firstMatch；随后确认popover省略cancel角色的“继续保留”，点击导航标题也因被popover覆盖而未关闭。改产品为始终可见的非破坏性“继续保留”动作，最终UI完整通过，没有跳过保留与状态校验。明确失败后收尾停滞的PID34016已终止；不是因观察超时就重启仍有效的测试。早期App测试误用了只属于Core测试模块的helper，改为生产freezeSendIntent和typed operation查询后通过。

证据：

- `/tmp/im-preparation-cancel-verified-client.log`：267项Swift Testing/37个suite与32项XCTest通过；组合包括资源、下载、调度、group avatar、profile intent和operation retention相关域。
- `/tmp/im-preparation-cancel-verified-app.log`：App/测试target构建和21项/4个suite通过，结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_09-43-20-+0800.xcresult`。
- `/tmp/im-preparation-cancel-ui-keep.log`：确认范围→继续保留→再次确认→原任务cancelling的1项UI通过；结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_09-41-15-+0800.xcresult`。已查看`/tmp/im-preparation-cancel-verified-attachments/E8575966-7A20-4E1E-B6AF-53321DD92CED.png`双动作确认，`C3AFA771-F7D5-4D5D-874B-0FDDFC1B4AB6.png`取消后原任务仍待原操作确认。UIfixture没有durable import activity，因此只证明本地撤回与取消意图展示；远端原ID恢复由上述App集成另行证明。
- `git diff --check`通过。未提交、推送、部署、安装手机或删除用户数据；UI仅清理自身随机scope的测试数据。

完整目标继续。下一步需补取消失败后的可见重试、上传/导入暂停继续、头像/无父任务领域控制及持久排队/真实进度；目录尺寸/时长/头像引用、完整物理预算/AFU、自动原生完整闭环和真实OSS/真机/完整无障碍/Release性能仍未通过全部门槛。

## 37. 取消失败后的原操作确认恢复（2026-10-24）

- 新增类型化的retryCancellation动作与cancellationUnconfirmed原因；上传paused/needsAttention和导入attempts>=5的取消，在无执行owner/native active时显示需处理。普通重试不会重新上传已取消资源。
- Center账号命令与同事务SQL重验能力后只开启新一轮取消确认预算，保留取消标记、原业务身份、终态和已撤回消息。服务端retry下界保留。活跃native mapping也禁止普通上传重试；不提前释放I/O或文件。
- UI增加“继续确认取消”、取消待确认说明与反馈；Store读取动作能力，生产命令执行时再次验证。原sender/engine依赖原journal自动恢复，无第二个页面恢复循环。
- 新增4个参数化Core测试方法：实际失败取消恢复及完成竞争；owner/冷却/冷重开；实际5次claim预算耗尽；活跃native mapping阻止两种重试。App增加Store路径，并参数化实际sender恢复测试覆盖取消失败→继续确认→同operation终态，无消息提交。

证据：

- `/tmp/im-cancellation-recovery-final-client.log`：327项Swift Testing、48个suite与32项调度器XCTest通过。包含资源、后台、调度、群头像和个人头像相关回归。
- `/tmp/im-cancellation-recovery-verified-app.log`：构建及16项/2个suite通过；1项UI `testCancellationAttentionOffersOriginalConfirmationAndReturnsToActive`通过。
- xcresult：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_09-57-13-+0800.xcresult`；已查看截图`/tmp/im-cancellation-recovery-attachments/0C22F89D-4AFF-40E9-AB45-14B9C2E9815F.png`与`37E6A1F8-C76D-4105-AFE7-9D655582783C.png`。fixture使用真实父撤回和needsAttention journal，未启动durable import worker；远端原operation恢复由App集成测试单独证明。
- `git diff --check`通过。初次针对性Core21项、后续22项和App16项均通过，最终Core扩大至327项后通过；没有以这些重叠计数相加声明覆盖。没有部署、提交推送、安装真机或删除用户数据。

完整目标保持进行中；下一步上传/导入暂停继续、头像/无父资源领域管理及持久排队/真实进度，其余目录元数据/引用、预算与真机发布门槛仍未全部满足。

## 38. 上传用户暂停/继续与后台排空（2026-10-24）

- 上传job增加Control.run/pause与user_control schema。资源work due/head/observation/claim及部分索引同时排除用户暂停；native install要求run。取消消息和群头像废弃操作覆盖pause，普通retry不能清掉用户暂停。
- Center暂停命令有账号级共享所有权和4项上限，页面等待取消不撤回已接纳的命令；实际engine flight与native系统任务排空前不显示paused/不允许resume。关闭账号仍先停止engine，再排空命令和文件。
- native冷回接读取持久pause：adopt名额/源后cancelAndDrain，完成mapping仅保留原status确认，不记作失败。paused分支也回收超128条mapping tombstone。OS实际drain后才释放AFU副本、容量与scheduler permit。
- resume同事务重新验证合法能力，保留原job/request/session/media身份及server retry floor。先status再重新获取传输plan。终态胜出、取消覆盖、preCancelled调用和stale操作均不重启错误任务。
- UI区分暂停上传/继续上传与下载操作，解释整文件重传和服务端仍可能处理。消息准备快照增加isUserPaused，观察签名包含user_control；用户暂停显示明确提示且不提供无效普通重试。没有把任务暂停伪装成远端abort。

验证与证据：

- 初次Core编译发现测试nextResourceAttempt缺少excluding参数，修正测试调用后48项/6个suite通过；后续扩大相关回归，`/tmp/im-upload-pause-verified-client.log`333项Swift Testing/49个suite与32项调度器XCTest通过。
- 5个新Core测试方法使用真实受管原件、freeze与GRDB；非协作writer受控gate证明取消页面等待后命令继续、排空前禁止resume、排空后原session先status并成功。native原测试增加pause/drain参数场景，另增冷adopt测试含受控protected-data不可用→恢复，保留名额和副本到driver实际结束。
- `/tmp/im-upload-pause-verified-app.log`App/测试构建及22项/3个suite通过；1项`testUploadPauseAndContinuePreserveTaskAndUseUploadLabels`UI通过。xcresult：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_10-08-27-+0800.xcresult`。
- 已查看`/tmp/im-upload-pause-attachments/06D22819-C902-4F7C-8002-37DA65C08535.png`暂停上传行和继续按钮、`5A848881-B27E-4B1F-AD24-6282F58CF081.png`同任务回到active。UI只证明管理路径，实际I/O/drain由Core测试单独证明。先前同切片的App22项+1UI也通过，未与重跑计数相加。
- `git diff --check`通过。未提交推送、部署、安装手机或清除用户数据。受控driver锁定不等同实际手机Data Protection，真实OSS/锁屏/系统终止仍待验收。

完整目标继续：导入本机跟进暂停、头像/无父任务领域取消管理、持久队列及真实进度、目录可信元数据/引用和其余发布门槛尚未全部完成。

## 39. 导入本机跟进的持久暂停/继续（2026-10-24）

- 新import user_control schema与upload共用V2ResourceTransferControl强类型。due、claim、部分索引和准备调度观察都排除pause，普通retry不能解除用户暂停；取消父消息或原import取消会将control恢复run以完成取消确认。
- 本机暂停不终止服务端复制，也不取消其他import或恢复活动。已claim请求保留owner到实际返回，随后无后续查询，phase由pausing变paused；owner未释放时resume事务拒绝。继续沿原status/operation，不改冻结消息载荷/目标media ID，遵守server retry floor；权威终态胜出，父消息withdraw能力独立保留。
- sender在claim后重读job再选取消或跟进，不再用due候选的旧取消状态。已计费attempt的首值为1，retry context同步改为>1。advance在本机pause时停止追加请求，已有请求的迟到非终态不会清除控制。
- pending快照、会话观察签名增加import control；消息提示改为“附件准备已暂停，可在文件与存储中继续”，不提供无效普通retry。管理按钮和状态明确写“本机跟进”，详情说明服务器仍可能处理。

证据与修复：

- 新测试首次误用不存在的V2ResourceImportStatus.State，按Core实际V2ResourceImportState修正。随后针对性测试中两项终态断言误要求所有动作为空，但失败/已取消资源的未提交父消息仍允许撤回；保留生产能力，仅修正测试为无pause/resume/retry、父撤回仍可用。
- 最终`/tmp/im-import-pause-verified-client.log`339项Swift Testing/50个suite和32项调度器XCTest通过。6个新增测试方法覆盖冷库重开、服务端冷却、owner排空、迟到状态、取消覆盖、ready/cancelled/failed竞争、原retry不解pause及仅control变化唤醒会话快照。
- `/tmp/im-import-pause-app.log`：App及测试target构建、19项/2个suite通过；实际durable sender与受控import gate证明create一次、暂停后恢复status一次使用同locator、父消息不重复创建/提交。Store另外验证本地命令与反馈。
- 1项`testImportPauseExplainsLocalScopeAndContinuesOriginalTask`UI通过；xcresult为`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_10-16-13-+0800.xcresult`。已查看`/tmp/im-import-pause-attachments/44246D1C-5D84-4F80-9A64-BE82FEEDC7A9.png`详情及`160E1998-6B88-41EF-A83F-BEAF87C8E801.png`原任务继续。UIfixture无远端worker，网络恢复由App集成另证；不作为真实OSS/锁屏验证。
- `git diff --check`通过。未部署、提交推送、安装手机或删除用户数据。

完整目标仍在进行：头像与无父任务领域取消、持久队列/真实进度、可信元数据与引用、物理副本预算/AFU和真实设备/OSS/Release/完整无障碍仍未全部交付。

## 40. 无依赖任务取消确认和头像依赖防绕过（2026-10-24）

- 增加UnboundCancellationPlan和cancelUnbound动作：只对无活跃业务消费者的非终态upload、messageAttachment import开放。计划记录原request/asset并绑定Center owner及incarnation，提交时同事务重验；审阅后被新消息取得、已经终态、外来owner或旧计划重复执行都会拒绝。
- 复用账号有界共享取消命令及实际engine drain，不由页面持有I/O；import通过原durable sender收敛。控制覆盖用户pause、遵守server retry floor，不直接删原件或远端正式对象。头像import缺少完整引用合同，暂不误判为无依赖，后续仍需完整实现。
- 统一uploadHasLiveResourceConsumer：包括profile.source_released=0、群avatar活跃及closed awaitingDecision、消息preparing/handedOff。旧requestResourceCancellation补齐这些检查及终态/idempotence，不再重复重置取消预算。群头像显式放弃/替换后，原upload取消会清除失败/暂停的准入阻碍，而不是只写一个永远无法执行的flag。
- 无父上传取消输给完成时，ready事实保留；取消意图允许按同一活跃消费者保护规则释放原件，修复ready无父且无人可用却永久持源。提交前保留原件，物理清理由FileStore负责。
- Store/View新增独立“取消任务”→审阅→继续保留/确认，原消息范围对话框保留。新入口不会绕过头像业务所有者；头像业务精确跳转尚未实现，不能把保护逻辑当成完整入口交付。

证据：

- `/tmp/im-unbound-cancel-verified-client.log`346项Swift Testing/51个suite、32项调度器XCTest通过；针对性49项/5个suite先通过，未叠加计数。
- 新7个无父Core方法覆盖原operation完成竞争及源释放资格、审阅后新父、个人头像防绕过、closed群头像保留决策并由abandon解除、重复取消预算不变、冷库重开/冷却、外来owner/预取消/SQLite失败回滚。
- `/tmp/im-unbound-cancel-drain-client.log`在最终测试源码上16项/1个suite通过，原writer gate场景增加unbound参数，直接证明新命令在页面分离后仍有效，close等待真实writer；这是额外聚焦验证，未与346项相加。
- `/tmp/im-unbound-cancel-app.log`App和测试target构建及39项/4个suite通过；durable sender以message/unbound×首次/失败继续确认组合沿原import operation收敛，没有提交消息。Store验证保留、审阅后新消费者拒绝。另覆盖群/个人头像既有流程回归。
- 2项UI通过：原`testPreparationCancellationShowsMessageScopeBeforeWithdrawingIt`与`testUnboundCancellationCanBeKeptAndThenConfirmsOriginalTask`。xcresult：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_10-29-59-+0800.xcresult`。
- 已查看`/tmp/im-unbound-cancel-attachments/389AB5B0-0BDD-40D8-B3FD-B6DA5FBB57F1.png`双动作确认及`9041DCFE-03E5-4C25-8101-DA694DC44FEE.png`原任务cancelling。UI无真实upload/import远端worker，原身份恢复由Core/App集成单独证明。`git diff --check`通过，无部署、提交推送、安装真机或用户数据清除。

完整目标保持进行中：头像业务管理准确入口、头像import依赖覆盖、持久队列展示和真实进度、可信元数据/引用、物理预算/AFU及真实OSS/真机/Release/完整无障碍仍未全部完成。


## 41. 精确头像业务关联与个人资料处置（2026-10-24）

资源传输现在可进入“处理相关更改”，以原 upload job 查出准确的个人资料 intent 或群头像 room/operation；列表按创建时间及身份稳定分页，受同一账号订阅上限保护。打开前重验关联，群头像工厂返回的 room 和 focused operation 也必须匹配，不以最新一条操作替代用户所选的操作。个人资料详情展示被冻结的昵称和头像；群头像复用既有领域管理页。

个人资料未提交时，可审阅后整体放弃该次昵称与头像更改；已结束但仍保留原件的负结果，可解除其本地源保留。已提交/结果未知不开放此处放弃。已成功提交的原操作原有自动释放逻辑继续生效，不重写服务端回执。计划绑定账号 incarnation、Center owner、原 intent 和 upload 身份；确认时同事务重查冻结状态与消费者，拒绝审阅后已经交接的旧计划。原件释放与原 upload 取消请求沿既有领域事务执行，共享依赖仍保留。

已接纳处置属于账号命令，离开页面不撤销命令；upload engine 等真实 writer 排空后才结束。旧资料编辑页观察 sourceRetained，外部放弃后清除其旧 pending 观察但保留当前编辑内容。修复 profile preparation schedule 仅去重最早时间的问题：同时观察队首 intentID 和 due，两个草稿 due 相同也能在前一条结束后唤醒下一条。

验证与发现：

- ClientKit `/tmp/im-resource-owners-final-client.log`：381 项 Swift Testing / 53 个 suite，通过；另有 32 项 scheduler XCTest，通过。真实 GRDB/FileStore 加受控 I/O 覆盖准确分页、共享依赖、冻结竞争、提交/负结果、事务回滚、同 due 唤醒，以及非协作 writer、页面等待取消和账号 close 排空。
- App `/tmp/im-resource-owners-verified-app.log`：30 项 / 4 个 suite，通过；包括精确旧草稿与无关更新草稿隔离、冻结后拒绝处置、群头像 room/op 工厂校验和原资料编辑页状态收敛。
- 同一 App 测试运行另有 1 项 UI `testProfileOwnerOpensExactDraftAndWithdrawsOnlyThatChange` 通过。结果：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_11-04-00-+0800.xcresult`。已查看 `/tmp/im-resource-owners-final-attachments/` 的原草稿、确认框及已放弃截图。UI 使用真实本地域服务、受控远端边界，不证明 OSS 或手机后台行为。
- 点击测试发现导航目的页没有得到业务 manager，已改成显式构造参数注入；此后原始昵称正确显示。测试还修正 native LabeledContent 的组合无障碍 label 查询，仍断言不出现另一条更新草稿。新增调度测试最初缺少 await，修正后上述最终回归通过。
- `git diff --check` 通过。未提交推送、部署、安装手机或删除用户数据。

尚未交付的完整范围：头像 import 依赖和管理路径、群头像关联入口的完整 UI 端到端、持久队列展示与真实字节进度、可信尺寸/时长及全部引用、物理副本峰值/AFU、原生自动下载真实闭环、OSS/手机/Release/完整无障碍。目标保持进行中。


## 42. 导入结果目标归属校验（2026-10-24）

继续检查头像导入时发现：当前个人/群头像生产入口走本地原件上传，尚未将服务端 import 绑定到 profile/group intent；此部分仍未完成，不能因管理列表已有头像 owner 就宣布导入也有 owner。

本轮修复基础回执校验：`saveResourceImport` 以前只对 messageAttachment 检查目标 room，现统一用 targetUsage.home(actorUserID:) 验证全部用途。actorUserID 从绑定数据库的 local_installation 读取，不取服务端 locator 或源资源上下文；原 operation、mediaID、已接受 locator 以及执行 owner 校验继续保留。错误回执在写入状态/重试事实前拒绝，不将错误账号或群的 ready 当成当前任务成功。正确的后续回执仍可沿原任务保存。

新增 `V2ResourceImportAuthorityTests`：参数覆盖附件、个人头像、群头像的错误 home kind 和同 kind 不同身份；验证 pending 与已接受 copying 均不被错误回执覆盖，随后同 job 正确 ready 成功；另测数据库重开后个人头像仍按绑定账号、而非源消息 room 归属。

证据：

- `/tmp/im-import-authority-client.log`：383 项 Swift Testing / 54 个 suite，另 32 项调度器 XCTest，通过。
- `/tmp/im-import-authority-app.log`：App 及相关测试构建通过，DurableResourceLifecycleTests 6 项 / 1 个 suite 通过；实际 sender 的原 import 继续/取消及消息恢复测试使用受控网络，不等于真实 OSS 或手机后台验证。
- App xcresult：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_11-11-56-+0800.xcresult`。
- `git diff --check` 通过。本轮未新增兼容层、部署、安装手机或删除用户数据。

后续仍需真正把头像导入绑定到业务 intent 并贯穿取消、源引用及资源管理页；持久队列/真实进度、可信元数据、完整引用、物理预算和 R6 验收继续，完整目标保持进行中。


## 43. 前台上传的实际字节进度与账号快照（2026-10-24）

新增账号内有界 `V2ResourceTransferProgressHub`，最多 4 个并存 attempt；URLSession 的 didSendBodyData 同步报告实际 totalBytesSent，不创建逐回调 Task、不写数据库、不保存 URL 或源路径。单槽脉冲流合并为约 250ms 一次的快照发布；使用已读取的 canonical 页面合并进度，不为每次字节变化重扫 SQL。目录/传输原有总订阅上限仍生效。

前台 upload engine 在真正调用 executor 的范围内建立 TaskLocal reporter，实际 executor 返回/排空后结束 attempt。计数限制在当前计划的 expectedBytes 内、单次 attempt 单调增长；重试使用新的 attemptID，归零仅表示新一次实际传输。迟到回调、旧 reporter.end、账号 close 不能污染新 attempt。同 job 不允许同时建立两个 reporter。multipart 的本次进度只覆盖当前 part，不能与 provider confirmedParts 混为同一计数。

传输行新增 attemptProgress，confirmedBytes 仍只来自 provider 已确认事实。界面分别显示本次上传字节和进度条、已确认字节与业务阶段，具备文字及无障碍语义。百分比满不将资源或消息改为成功，attempt 结束即移除暂态计数。

跨层测试发现真实执行与恢复动作的区别：claimResourceStep 在实际 PUT 之前写 ahead 的 next_action=status，用于崩溃后确认原操作；原管理读模型据此显示 confirming。现只在存活的上传 attempt 存在时，将 transferring/confirming 的展示叠加为 transferring；日志中的 status 保持不变，暂停/取消/终态不会被进度改成上传中。测试先因该展示冲突超时，定位修复后完整回归通过。

证据：

- `/tmp/im-live-progress-final-client.log`：388 项 Swift Testing / 55 个 suite，另 32 项 scheduler XCTest，通过。包括 bounded hub、10,000 回调合并、过期 attempt/重试隔离、账号隔离、原 engine/真实 GRDB/FileStore 的稳定快照与恢复动作保留。
- `realURLSessionUploadReportsBytesBeforeHTTPCompletion` 使用实际 localhost TCP/HTTP 服务及 URLSession fromFile 上传 128 KiB；服务器收到全部请求体后刻意不回 HTTP 结果，此时实际 delegate 字节已经到达 hub，随后才放行 200。此证据证明实际 Foundation 字节回调，不是 mock 计时器；不证明生产 HTTPS/OSS 或系统后台任务。
- `/tmp/im-live-progress-final-app.log`：App 及测试构建、21 项 / 2 个 suite，通过；新增 Store 测试证明离开/重开页面仍得到存活 attempt、原排序时间不变、结束后回到 confirming 且 confirmedBytes 不伪增。另 1 项精确 profile owner UI 回归通过。结果：`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_11-20-15-+0800.xcresult`。
- `git diff --check` 通过。本轮未部署、提交推送、安装手机或删除用户数据。

本次只完成前台上传进度；系统后台上传/下载、前台 Range 的真实字节展示，以及持久用户排队仍需贯穿原 mapping/owner/版本边界后验收，不以本轮结果替代。头像 import 业务绑定、可信元数据/完整引用、物理预算/AFU及完整 R6 门槛继续，目标保持进行中。


## 44. 前台 Range 下载的分段真实进度（2026-10-24）

前台下载缓存现在注入账号共享 progress hub，并把 canonical download jobID 通过 TaskLocal 传给字节执行器；不由页面创建独立计时器或恢复任务。进度键从裸 UUID 收敛为 upload/download 的强类型身份，因此同 UUID 的上传和下载不会串用计数。公开瞬时字节字段统一为 transferredBytes；无旧字段 fallback。

每次 HTTP Range 请求有独立 progress request：先由既有 RangeDownloadFile 验证响应状态、Content-Range、版本、编码及长度，再按已接受的响应体长度建立 attempt；文件 append 成功后才累加接收字节。请求返回或失败/取消并实际排空后结束 attempt；迟到旧请求不能修改或结束下一段。恢复前缀不算当前接收字节；200 完整重建创建新计数，206 以当前区间为分母，416 验证完成前缀而不生成虚假的零长度进度。进度仍不等于 checksum 校验或资源可用。

UI 使用“本段下载”区分“本次上传”，同时保持原资源总大小和 confirmedBytes 语义。canonical state 为暂停、取消、校验或终态时不叠加字节条。原 250ms 合批及最多 4 个存活 attempt 沿用；回调不写 SQL，不改变任务排序，不增加原件/partial 之外的字节副本。

新增证据：

- 精确区间 4/4/2 各有独立 attempt；中断接收 2 字节后结束，再由 200 重建只记本次 10 字节，不把旧前缀加成 12；错误 ETag 响应在建立进度前被拒绝。
- 同 UUID 的 upload/download 独立，旧 request consume/end 不能污染新段，超出已接受长度的计数拒绝，server import 不伪造字节进度。
- 实际 ClientKit cache → Range byte executor → 真实 GRDB/FileStore → Center snapshot 的受控集成证明：2/4 字节可见；请求暂停后界面隐藏进度，但非协作 writer 未退出前仍有原 attempt；排空后才移除。继续沿原 job 请求 bytes=2-3，最终验证发布并显示 4 字节已确认，创建时间和任务身份不变。

验证：`/tmp/im-range-progress-verified-client.log` 408 项 Swift Testing / 58 个 suite，另 32 项 scheduler XCTest，通过。范围比第43节增加 Range suites，不能将总数差直接当新增测试数量。`/tmp/im-range-progress-final-app.log` App及测试target构建、23 项 / 3 个 suite，通过，覆盖资源管理 Store、媒体下载生命周期与 durable sender；结果 `/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_11-28-12-+0800.xcresult`。本轮没有新增下载 UI 自动点击/截图或真实 OSS 下载证据；上述分段集成使用受控 transport，既有 URLSession transport 回归另行包含在 Core 范围内。

首次构建发现测试注入参数批量改动范围过宽及嵌套 require 宏编译错误，均已修正。宽回归另发现第43节的旧测试错误假设 finish 后立即 next=nil；AsyncStream 允许先交付单槽缓冲的最后一帧。测试改为排空后确认终止，并检查关闭账号后不能再建立 reporter，完整回归通过。生产关闭/排空逻辑未因测试修改而放宽。

`git diff --check`通过。未部署、安装手机、提交推送或删除用户数据。系统原生后台进度、持久排队、头像 import 业务绑定、可信元数据和全引用、物理预算/AFU及完整 R6 仍待交付，目标继续进行。


## 45. 系统后台传输计数与本地首屏隔离（2026-10-24）

NativeBackgroundSession 的实际系统任务清单新增可选 sentBytes/receivedBytes，来自 URLSessionTask 实际 body counters。上传/下载协调器各保留已落盘且接管文件后的轻量 progress binding；需要实际 permit、源/收件 reservation、非创建中状态，查询时再匹配 mappingID 和 system task identifier。回收 permit 同时解除该 binding，close 不再返回计数。冷启动从既有映射和文件接管重新建立 binding，不新建业务任务。

纯匹配器限制至64条任务/绑定，排除未知、负数、超出预期长度、过期、错误编号/映射及重复歧义。按upload/download的强类型身份选发送或接收计数，attemptID使用当前mappingID；只生成展示快照，不生成完成回执、恢复状态、文件授权或校验结论。系统计数达到总量仍不代表资源ready或消息成功。

ResourceCenter 在传输订阅存在时每250ms请求合批刷新；与前台进度共用单槽脉冲流及约4Hz发布边界。订阅全部结束或账号关闭就取消轮询；无订阅的前台字节事件不会枚举原生任务。原生计数只查询Foundation实际任务和协调器内已接管绑定，不按字节写SQL，也不读取目录数据库。任务排序、动作与终态仍来自canonical journals。

首屏特别处理：本地SQL结果先同步合并现有前台计数并发布，绝不await系统任务枚举；后台计数之后在观察循环补入。暂停/取消/校验/终态不会被旧系统计数覆盖成正在传输；相同canonical job出现前台/后台两个物理来源时不猜选或累加进度。

验证：

- `/tmp/im-native-progress-local-first-client.log`：412项Swift Testing /59个suite及32项scheduler XCTest通过。
- 新纯匹配测试覆盖准确映射、方向隔离、未知/错误/越界/过期/重复计数及64项上限。既有实际FileStore+GRDB上传enqueue/取消参数测试增加进度断言：2/4字节来自当前mapping，原awaitingBackground恢复动作不改变，排空后无残留计数。
- 下载受控driver测试不发送完成wake，仅改变实际task计数，账号订阅仍收到3→7字节，confirmedBytes保持nil；真正完成收件/校验/发布后才显示确认字节且移除attempt，原系统任务只创建一次。
- 冷接管测试从已安装映射和AFU reservation起步，initialize前不返回进度，采用既有系统任务后读取6字节且不新建任务；close后不再返回进度。另阻塞driver枚举，验证本地传输订阅先返回，再放行系统查询，防止进度查询拖慢本地首屏。
- `/tmp/im-native-progress-local-first-app.log`：App及测试target构建、22项/3个suite通过，覆盖资源管理、原生后台桥接与媒体下载生命周期。此处验证真实iOS原生driver代码的构建与既有桥接；后台字节变化测试使用受控driver，不是手机锁屏或真实OSS传输证据。
- 本轮测试编写中发现断言被放入错误fixture作用域及异步autoclosure编译错误，修正后以上最终回归通过。`git diff --check`通过。

未部署、安装手机、提交推送或删除用户数据。完整目标继续：持久排队展示、头像import领域绑定、可信元数据/全引用、物理预算/AFU核验、实际原生自动下载及手机/OSS/Release/完整无障碍门槛尚未全部完成。


## 46. 资源详情手动下载持久入队与 queued 展示（2026-10-24）

资源详情新增“下载文件”和“查看传输任务”。点击先在账号同库事务中验证精确home/media/message/ordinal当前可见、ready描述及摘要，再保存原canonical download journal；不等待网络授权、预览或传输名额。复用已有foreground paused+resume_requested恢复合同，不新建第二份可写队列表。真正执行仍由账号cache恢复活动取得原job、重新授权、验证原摘要及长度，并发布校验文件。

重复点击复用未结束job，可提升为交互优先级，但不重置控制、源上下文、已消耗次数、冷却时间和创建时间。用户pause时明确拒绝隐式恢复；cancel尚未结束时不另建任务。需处理的既有轮次只引导到任务页处理，不暗中重置budget。全局未结束download仍受16项准入上限限制，共享物理identity不生成新授权。

任务读模型新增queued：上传/导入未被执行器取得、download等待恢复/系统安装时，显示“已排队”；实际owner取得后显示准备或相应阶段。未来retry时间仍显示等待重试，用户暂停、取消、需处理、校验和完成优先于queued。原消息/任务顺序不因状态改变，结束逻辑未放宽。

修复优先级与冷却的交互：原foreground恢复只对background优先级检查retry_at，提升为interactive可能越过原冷却。现schedule、候选查询、nextAttempt及claim对全部foreground优先级执行同一retry floor。恢复传输继承持久priority，不把显式交互请求统一降成recovery；isRetry仍保留。自动任务保持background，只有明确用户动作升级。

证据：

- `/tmp/im-durable-queue-final-client-verified.log`：416项Swift Testing/59个suite，另32项scheduler XCTest通过。新增测试证明本地入队无网络、重复同ID、冷Center恢复原job且创建时间不变、最终校验确认；排队后撤权在网络前停止、用户pause不被重复点击解除、优先级提升保留retry floor和attempts，并以交互优先级实际执行。queued/claimed/future retry三种事实分别验证。
- `/tmp/im-durable-queue-final-verified-app.log`：App及测试target构建、22项/2个suite通过。Detail Store验证本地命令完成即返回、不打开预览、不调用network、重复同job及pause错误反馈。
- 1项UI `testExplicitDownloadPersistsQueueAndPauseResumeKeepsOriginalTask`通过：资源详情下载→传输页queued→暂停→需处理→继续→原job回到queued。结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_11-47-50-+0800.xcresult`。已查看`/tmp/im-durable-queue-final-attachments/C74DC7F7-622C-4154-AAF8-CD419302ABA5.png`的原队列、动作及校验说明。UI fixture暂停自动worker以验证排队控制；冷恢复和真实FileStore闭环由Core集成另证，不能当成真实OSS/手机后台证据。
- 开发中修正SQL拼接空白、测试重试时间超出60秒预算、非Sendable Row跨隔离及重复fixture字段错误。旧测试中无owner显示preparing和显式交互恢复降为recovery的预期改为目标queued/interactive；实际取消、排空和恢复ID断言保留，最终全范围通过。`git diff --check`通过。

本次完成资源详情显式下载的持久入队；预览/分享及其他直接消费入口在授权和容量等待之前的请求持久化、精确等待原因/完整队列覆盖仍需继续，不把这一条入口当作W3全部完成。头像import领域绑定、可信元数据/完整引用、物理预算/AFU、实际原生自动下载及OSS/手机/Release/完整无障碍仍待交付。未部署、安装手机、提交推送或删除用户数据，目标保持进行中。


## 47. 资源中心预览/分享在鉴权前持久入队（2026-10-24）

ResourceManagementService.borrow现在先验证资源来源和原件variant的当前本机状态；needsDownload/invalid时复用enqueueDownload，在发起展示网络鉴权或等待字节名额前保存canonical任务。已有available缓存则不为每次预览建立新任务记录，仍按原下载服务重新验证权限并借用受管文件。

页面取消只撤销本次presentation等待，不清除已接纳下载意图；账号恢复活动以后沿原任务继续。用户已经暂停时，预览和分享同样拒绝暗中恢复，沿已有错误映射引导到任务管理页。源在获取文件后再次验证的逻辑、lease和展示副本生命周期保持不变；入队本身不是文件读取授权。这里统一的是资源中心borrow入口，不声称已经覆盖聊天内所有直接下载调用及尚无可信描述的资源。

新增App测试按preview/share参数证明：鉴权gate进入时本地已有一条queued记录；页面取消后没有presentation、工作状态结束且任务保留；再次打开复用原ID；暂停后展示请求在进入网络gate前拒绝。实际FileStore缓存读取另证明反复借用仍取到正确字节，但不新增传输历史。既有QuickLook使用中清理/账号关闭排空及媒体冷缓存重新鉴权测试仍通过。

验证：`/tmp/im-presentation-queue-app-fixed.log` App及测试target构建、20项Swift Testing/2个suite通过；另1项UI `testLeavingPreviewDuringAuthorizationKeepsAcceptedDownloadInQueue`通过。UI真实运行资源详情预览，在授权尚未返回时导航离开，再进入传输列表仍见原资源queued。结果`/tmp/IMResourceCenterDerivedData/Logs/Test/Test-IMApp-2026.10.24_21-29-17-+0800.xcresult`；已查看`/tmp/im-presentation-queue-attachments/39FDCE6D-3F16-445D-A8BC-D1B2711C9FC1.png`。UI使用受控授权gate且关闭fixture自动worker，证明页面分离和持久事实，不代表真实OSS/真机后台传输。首次构建的局部变量同名错误已修正，最终运行通过。

本轮未修改ClientKit生产代码，因此没有重复运行上轮416项Core范围；不把其历史结果算成本轮新测试。`git diff --check`通过。未部署、安装手机、提交推送或删除用户数据。

完整目标仍在进行：聊天等其他读取入口及缺少可信元数据时的排队合同、精确等待原因、头像import领域绑定、可信尺寸/时长和完整引用、物理预算/AFU、实际原生自动下载与OSS/手机/Release/完整无障碍验收仍需补齐。

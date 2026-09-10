# IM V2 修复实施与验证记录

> **历史归档。** 本文按批次记录整改过程与当轮验证结果，**不是当前状态**，
> 也不构成发布批准。**判断当前状态请看** [问题状态表](../status.md)，
> **判断当前合同请看** [合同索引](../README.md)，**判断能力与证据等级请看**
> [`implementation-status.md`](../../../IMV2/docs/implementation-status.md)。

目标：逐一完成[问题表](2026-09-05-system-design-implementation-audit.md)与[修复方案](2026-09-05-system-remediation-plan.md)的全部 47 项。起始基准为 HEAD `220f5be78ed347bbe8a343be634720070efbb597` 加已有未提交工作；保留原有工作区改动。状态不等于发布批准。

状态：未开始、实施中、已实现待验证、已验证、待外部验收。只有具体证据覆盖问题的全部关闭条件才记已验证；需要真实设备/凭据/部署的项目单列，不用本机测试替代。

| ID | 问题 | 状态 | 实现 | 验证与剩余工作 |
| --- | --- | --- | --- | --- |
| B01 | 幂等比较可因 revision 整数越界终止 Gateway | 实施中 | 新增有界 Message/Membership revision；三个命令在进入存储前拒绝越界，重放比较使用安全值。补充富文本 offset+length 的 checked addition，并重验 JSON 解码后实体约束。 | 最新 Core 76 测试通过，覆盖 Int.max 溢出、负数/零长度和非法 link；Gateway revision 越界测试已通过；继续核对恢复 DTO 与其余递增路径。 |
| B02 | 编辑旧消息绕过当前群写入权限 | 实施中 | 发送与编辑共享当前发言授权；编辑校验控制面账号与 owner 内成员/禁言/冻结/权限。 | 35 项相关服务端测试通过，含五类拒绝与零写入断言；并发权限变更提交顺序尚待覆盖。 |
| B03 | room-log 消息的 mutation 缺少原始消息投影，阻塞恢复 | 未开始 | — | — |
| B04 | 转发源缺少消息提交时的成员可见性检查 | 实施中 | 初始源读取与最终接受共用历史区间 ∩ 当前区间 SQL，支持 room_event/message_row 两种 accepted 形式，缺失或身份不符的原始事件拒绝；同 owner 在目标准入前按 UUID 顺序锁完整源/目标房间集合，最终核对源房间、正文与实体。 | 真实 PostgreSQL 与相邻网关/发送回归 57 tests / 3 suites 通过；覆盖新成员、离群/重入、离群期间 accepted、缺失/不匹配证据、实体篡改、16 个反向并发转发、读取后源退群与旧完成重放。已补强类型源版本、转发 v2 指纹和持久 pair 版本绑定，schema 7→8 迁移、ABA 与最终依赖回归通过：Core 76 / ClientKit 291 / Server 59。当前编辑版本受众已补齐转发初读与最终接受，schema 9 与服务端 61 项回归通过；同库多跳媒体、撤销引用与失效素材拒绝已通过 64 项服务端回归；App 父计划完成展示已通过新增 8 项测试；源房间/选中版本已贯穿协议 23 与 SQLite，owner 路由与稳定分块 UUID 已修复，最新 Core 80 / ClientKit 294 / App 170 / Server 82 通过；schema 11 源端不可变 export、owner epoch 栅栏和媒体保留已实现；schema 12 目标 inbox、共享目标接受与提交后恢复已有双库验证；schema 13 实际文件导入、schema 14 源端终态回执与 pin/配额释放已实现并通过 Server 89 项相邻回归；schema 15 持久投递 worker 已通过最终 Server 90 项回归；运行接线、暂停任务恢复、正文保留清理及 owner 迁移仍开放，见 [转发合同](../forward-source-authorization.md)。 |
| B05 | 密码长度规则与 bcrypt 实际输入不一致 | 未开始 | — | — |
| B06 | 同一编辑/撤回经两条事件流到达时不幂等 | 未开始 | — | — |
| B07 | outbox 记录了重试时间，却没有到时唤醒任务 | 已实现待验证 | runtime 拥有重试 worker；SQLite 分 lane 读取索引最早到期时间，有限缓冲变更通知与单个定时器唤醒；预算用尽继续。批量转发等待重试时不再重建同分块。 | 59 项 outbox/runtime/scheduler 测试通过；SQLite EXPLAIN 验证 ready 索引，覆盖安静到期、休眠竞态、预算续跑及延迟分块。全量客户端 223 tests / 40 suites 通过；继续补真实连接重连/休眠及多 lane 组合。 |
| B08 | 认证失效后退出流程依赖已删除的凭据 | 实施中 | restoreState 不刷新，凭据不存在时跳过认证 Push DELETE；新增真实凭据 IO 串行队列与进程内 epoch。旧读/写/删不能覆盖新登录，terminal 删除失败后解锁只重试删除；App 已持久退出意图后失效旧认证工作。 | 客户端全量 271 tests / 47 suites，App 129 tests / 12 suites 通过。覆盖四类挂起存储操作、迟到 provider/旧 TLS 拒绝与同账号 token 刷新。跨重启退出 checkpoint、网络期限和旧 session 专用离线撤销 capability 尚未完成。 |
| B09 | 刷新凭据的终止错误未映射成重新登录 | 已实现待验证 | restore/load/refresh 单飞；TLS/bootstrap 按 epoch 分类。新增按 epoch 隔离的有界认证快照流和 App 观察器，独立刷新终止也会驱动重新登录；锁屏恢复与终止删除失败分开处理，旧通知只结束旧本地展示。 | 客户端 274 tests / 47 suites，App 133 tests / 13 suites 通过。覆盖慢/迟到订阅、观察器替换、独立刷新失效、锁屏、数据库打开中 revocation。生产观察组件与接线已验证，真实账号服务的 restore/logout/kill/relaunch 组合及其余 HTTP 终止入口审查仍待补齐。 |
| B10 | 邀请预览与实际提交 token 可指向不同群 | 已验证 | 预览与 secret 绑定为提交凭证；请求 generation、任务取消、精确意图幂等 ID；按钮关闭和 sheet binding 下拉关闭均调用 dismissJoin，退出调用 invalidate。 | iPhone 17 / iOS 26.2 定向 6 tests / 1 suite 通过。新增 A 提交后 B 加载/ready/提交中 × A 迟到成功/失败六种交错，精确校验 token、note、operation ID 与 B 状态；既有预览替换、失败、迟到、相同意图重试、关闭/退出和无效链接全部通过。 |
| B11 | 编辑/撤回后重放原 SendMessage 被误判冲突 | 实施中 | Core 普通发送 v1、转发 v2 / SHA-256 指纹与原始输入比较；新增 PostgreSQL 无正文完成记录，9 处消息 INSERT 同 SQL/同事务写入；批量保留 typed arrays/credits，记录禁止 UPDATE 变更；重放查原完成记录，operation 键统一 room/actor/client，denial 对比原指纹。协议 23 使用无正文 ACK，schema 当前为 15，保留普通发送 v1 字节并持久绑定转发 source revision。 | Core 76 项指纹测试、客户端 225 项及 App 123 项通过；standard/hybrid/hybrid-mention 路径在编辑、撤回、删除后实际重试返回原 receipt，七类改参冲突通过。服务端 73 项回归通过；最新源版本批 Core 76、ClientKit 291、Server 59 项通过；GC/owner 迁移、精确条件 SQL 竞争与 WAL/CPU 验收仍未完成。 |
| B12 | 房间追赶的一轮预算耗尽后不继续 | 已验证 | runtime 拥有房间追赶 worker；目录扫描捕获上界，按持久游标先尾段后首段各扫描一次；仅 hasMore 房间进入 FIFO backlog，每房间每轮一页并让出执行权。同房间读游标/拉取/落盘整体串行，取消后拒绝迟到结果。 | 13/1000 空房间有限停止、10000 条热房间与冷房间公平、无新 hint 自动追完、目录新增延后至下轮、无游标进展拒绝、前台/后台同房间并发、取消后重试、snapshot fence 等待恢复及 runtime 停止取消通过。客户端全量 232 tests / 42 suites，App 全量 123 tests / 11 suites 通过。 |
| B13 | 并发 flush 同时取到同一 pending 命令 | 已验证 | 15 个 outbox engine 共享 flight，Social 指定入口共用；公平调度器单实例，runtime suspend/cancel/resume/drain。普通完成入口比较 canonical metadata；批量分块使用稳定 UUID，并持久化 v1/SHA-256 结果摘要，与父计划计数同事务，同结果重放 no-op，异结果冲突且不重排 pending。 | 客户端全量 282 tests / 48 suites、App 133 tests / 13 suites 通过。覆盖 20 并发 flush、取消 UI waiter、runtime 停止后迟到成功；新增分块 20 并发重复完成、响应重排、关闭重开、八类结果冲突、取消、事务故障回滚及保留旧 outbox 的升级。旧版已完成分块无摘要时拒绝无法验证的重放，不重计数或伪造结果。 |
| B14 | 取消单个请求会把迟到响应升级为整条 TLS 失败 | 已验证 | 已发送取消请求保留 cancelledOnWire 关联及原硬期限；匹配晚包仅释放记录，默认 256 个总槽位包含取消记录；达到硬期限关闭整代连接后清理，未知响应仍拒绝。 | A 取消与 A/B 回复同包交错、满容量、取消后硬期限、未知回复、三类消费者取消不取走已排队提示均通过。最终客户端 240 tests / 43 suites、App 123 tests / 11 suites 通过。 |
| B15 | 擦除主 SQLite 时遗漏保存正文的独立搜索库 | 实施中 | 共享主库/搜索库/WAL/SHM 六文件集合与双 pool close；新增 UUID 目录清理记录。生产 bootstrap 已使用按账号隔离的 scope，旧主库按原账号归属可恢复迁移并保留 outbox，旧 FTS 删除重建。退出等待 indexer/runtime 后关闭捕获的 store。 | 客户端全量 264 tests / 46 suites，App 129 tests / 12 suites 通过。覆盖迁移前缀、旧 A/outbox 保留、20 并发 open、旧关闭不影响新 A、关闭后迟到写拒绝。目录 retire 尚未贯穿全部显式擦除；完整认证 epoch、旧媒体清理和实际 kill App/冷启动组合仍开放，见存储生命周期合同。 |
| B16 | Push 关闭后，迟到的注册仍可重建远端端点 | 未开始 | — | — |
| B17 | 连接恢复后，仍打开的会话不重建实时订阅 | 已验证 | runtime 持有共享订阅协调器并传入实际连接 UUID；页面按独立 token 消费完整快照，取消单次等待不释放 lease。新连接重建订阅并补拉，清除旧 typing/presence；发送 typing 校验 token/连接代次。保留 live payload、100 ms grace 与序号缺口恢复，周期恢复使用单一时钟。 | 客户端 249 tests / 44 suites，App 129 tests / 12 suites 通过。覆盖页面不退出重连、同房间/不同房间多 scene、最后 token 撤订、迟到 subscribe ACK 与替换交错、取消 grace 后继续收 payload、周期补拉、退群/rejoin、旧 payload/typing 代次拒绝及重连后新输入。真实 TLS scope 边界已有回归；真机网络/生产证书仍由 E01/E04 验收。 |
| B18 | 800 条滑动窗口使更旧搜索命中无法定位 | 未开始 | — | — |
| B19 | 搜索连续加载可重复追加同一页 | 已验证 | 同页单飞，按消息 ID 去重；查询/筛选/请求 generation 校验；SQLite 游标绑定查询、索引 generation 和 tokenizer 版本。原游标重复返回时停止分页，页结果与索引进度读取完成后一次提交；取消保留原页与可重试游标，失败关闭继续加载。 | 最新客户端 282 tests / 48 suites、App 139 tests / 13 suites 通过。覆盖加载中追加 19 次调用只有一页、重复项去重、旧查询/成员/内容筛选迟到、游标停滞、取消后重试、失败/索引重建后恢复、初次查询及分页的旧进度迟到；SQLite 查询变化与实际索引换代拒绝旧游标。 |
| B20 | 搜索索引建好后页面仍停在 indexing | 已验证 | GRDB 观察 singleton 的 state/generation/index_version，有限缓冲且带初值；搜索页生命周期订阅 ready 自动重查，building/换代撤销旧游标。 | 真实 SQLite 观察建库代次与 ready 初值通过；App 覆盖订阅前后完成两种时序，全部 123 tests / 11 suites 通过。 |
| B21 | 实时刷新把已加载会话/联系人分页重置为第一页 | 已验证 | 初载/重置/后台刷新分离；会话、好友和搜索窗口上限 300，申请两组各 150；生产 SQLite 锚点窗口、删除 fallback、前后翻窗与资料补全接入实际 List。事务提交摘要按页面范围过滤，普通更新合并 150ms，紧急更新取消当前刷新并在 drain 后接续最新读取；旧结果有取消和代次检查。 | ClientKit 291 tests / 50 suites；最新 App 161 tests / 16 suites 与 4 项启动 UI 测试通过。覆盖实际 SQLite/SwiftUI 深分页、头部批量插入、锚点删除、独立游标、普通通知合并、紧急位不被覆盖、慢联系人资料读取期间撤权、旧时间线读取期间正文撤回，以及任务取消/退出 drain。证据映射见末尾本批关闭审计；未扩张为像素偏移或真机 VoiceOver 已验收，B28 等外部项目仍按原状态保留。 |
| B22 | 文件时间戳 API 缺少 App 隐私清单声明 | 待外部验收 | PrivacyInfo 声明 FileTimestamp/C617.1，用于沙盒媒体缓存时间戳。 | plist 校验及实际 Debug 模拟器 App 包声明检查通过；正式 Release 归档与隐私报告验收未完成。 |
| B23 | 跨邀请并发申请可突破每人 20 条待审上限 | 未开始 | — | — |
| B24 | 待审批游标随着审批状态变化而失效 | 已验证 | 有界、版本化游标携带 room/filter 与 PostgreSQL 六位微秒时间、唯一请求 ID；每页重新授权和范围验证。 | 真实 PostgreSQL：审批/删除锚点后继续、同微秒不重漏、下一微秒边界、尾页、非法 room/filter/version/time 游标均通过。 |
| B25 | 已耗尽链接不展示，却继续占满活跃链接额度 | 实施中 | 创建额度和可用列表统一 active/未过期/未耗尽条件，部分索引排除已耗尽链接。 | 真实 PostgreSQL：20 可用链接拒绝创建、20 耗尽链接允许创建通过；管理历史状态展示及原子审批并发验收待做。 |
| B26 | 审批冲突重试后未持久化实际 membership revision | 未开始 | — | — |
| B27 | 新增邀请链路没有按群所属数据库路由 | 未开始 | — | — |
| B28 | VoiceOver 筛选值朗读内部 UUID | 待外部验收 | 筛选值使用本地已授权 profile 经 Resolver 得到的名称；未知时“选定成员”，UUID 仅保留在测试标识符。 | 公开名/未知回退/清除筛选测试与 App 全部 122 项测试通过；真机 VoiceOver 焦点和多语言验收待做。 |
| B29 | 当前协议版本文档已漂移 | 已验证 | 当前协议文档与生成代码同步为 23；protobuf 门禁增加文档版本检查脚本。 | 真实文档通过；临时夹具的旧版本、混合版本及缺失声明均被拒绝。 |
| D01 | 旧 TLS reader 的迟到失败可能关闭新连接 | 已实现待验证 | connection UUID 覆盖连接/握手、reader、发送失败、请求超时与取消；每代独有解码缓冲。关闭先摘除状态再取消，显式 disconnect 排空旧 reader/send；事件等待者增加独立 UUID 校验；NW ready bridge 一次完成。 | 可控真实 TLS actor 测试覆盖旧半帧/旧 reader 失败/旧发送失败与复用 request ID；真实 Network.framework 回环 TCP 暂停旧回调队列→新握手→释放旧回调通过。旧 waiter 取消及旧 timeout 的精确跨代组合仍待补，不以本机回环替代 TLS 证书/生产网络验收。 |
| D02 | Push 冷启动依赖 View 出现与会话恢复时序 | 未开始 | — | — |
| D03 | 后台 Push 跑完整 runtime，缺总时间预算 | 未开始 | — | — |
| D04 | 媒体文件和缩略图缺账号/安装级生命周期 | 未开始 | — | — |
| D05 | 原审批人失去权限后，孤立 approving 无接管路径 | 未开始 | — | — |
| D06 | 待审申请缺少申请人取消或清理机制 | 未开始 | — | — |
| D07 | 不同消息路径重复实现授权、准入和投影规则 | 实施中 | 提取发送和编辑共用的当前内容写入授权、validated command 指纹、普通/room-log 共享的完成记录 SQL 片段。 | 授权仍仅覆盖两条常规路径；批量优化路径的授权、准入和投影收敛未完成。 |
| D08 | 关键状态机的组合测试不足，能力证据描述过宽 | 未开始 | — | — |
| E01 | 生产部署、密钥、证书与 operator 入口 | 未开始 | — | — |
| E02 | 生产 Passkey / WebAuthn | 未开始 | — | — |
| E03 | 生产媒体存储、扫描和 CDN | 未开始 | — | — |
| E04 | 真机、多端、无障碍和签名 | 未开始 | — | — |
| E05 | 真实 APNs | 未开始 | — | — |
| E06 | NATS 生产安全和可观测性 | 未开始 | — | — |
| E07 | WAL/PITR、RPO/RTO 和灾备 | 未开始 | — | — |
| E08 | 远端 CI / 干净 checkout 证据 | 未开始 | — | — |
| E09 | 完整混合负载、长期运行与多 Gateway/分片容量 | 未开始 | — | — |
| E10 | ARM64 Linux 压力下历史 SIGSEGV 根因未关闭 | 未开始 | — | — |

## 本轮实施日志

- 2026-09-05：重新核对工作区及工程规则，开始 W1 数值边界、授权与幂等修复。

- 2026-09-05：Core 68 测试通过；独立 PostgreSQL `im_remediation`（localhost:56440）35 项服务端边界测试通过；iPhone 17/iOS 26.2 邀请状态 5 项测试通过。首次数据库运行暴露新增 SQL 列名误写，已修正并完整重跑该范围。

## 已执行命令与本机证据

- `swift test --package-path IMV2Core --disable-automatic-resolution`：68 tests / 21 suites；日志 `/private/tmp/im-remediation-core-tests.log`。
- PostgreSQL 边界：设置 `IMV2_POSTGRES_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:56440/im_remediation` 与 `IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1`，执行 `swift test --package-path IMV2Server --disable-automatic-resolution --jobs 4 --filter 'V2GatewayDomainCommandHandlerTests|V2MessageEditServiceTests|V2RoutedRoomMutationStoresTests|editsRespectCurrentContentWriteAuthorization|editWritesRevisionFencedTransaction|withdrawalWritesTombstoneTransaction|withdrawalWinsOverOlderEdit'`：35 tests / 4 suites；日志 `/private/tmp/im-remediation-server-boundaries.log`。
- 相同 PostgreSQL 环境，filter `invitationCursorSurvivesAnchorChange|exhaustedInvitationsReleaseCreationQuota|V2GroupInvitationServiceTests`：5 tests / 2 suites（游标测试两个参数）；日志 `/private/tmp/im-remediation-invitation-pagination.log`。
- `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4 --filter 'V2RealtimeSessionCoordinatorTests|V2AuthSessionTests|V2MessageSearchTests'`：19 tests / 3 suites；日志 `/private/tmp/im-remediation-auth-search.log`。
- `xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' -disableAutomaticPackageResolution -only-testing:IMAppTests CODE_SIGNING_ALLOWED=NO`：122 tests / 11 suites；日志 `/private/tmp/im-remediation-app-tests.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_12-06-56-+0800.xcresult`。
- `git diff --check`、`python3 scripts/check_v2_protocol_documentation.py`、`plutil -lint IMApp/IMApp/PrivacyInfo.xcprivacy` 通过。正式签名、归档、真机、真实部署与远端 CI 未由上述证据覆盖。

- Outbox/scheduler 回归 filter `V2CommandRetrySchedulerTests|Outbox|V2ClientRuntimeTests|V2FairDurableCommandSchedulerTests`：59 tests / 15 suites；日志 `/private/tmp/im-remediation-outbox-scheduler.log`。将原“取消 UI waiter 等于停止发送”测试改为显式 runtime 停止，另增取消 waiter 仍完成共享发送的测试，与修复合同一致。
- 索引通知接入后的 App 全量单元：123 tests / 11 suites；日志 `/private/tmp/im-remediation-app-index-tests.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_12-24-18-+0800.xcresult`。客户端组合测试出现的延期时间相等断言为 Date 浮点往返精度问题，改为固定整秒夹具后，全量客户端 223 tests / 40 suites 通过。

- 最新 `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4` 全量执行：223 tests / 40 suites 通过，日志 `/private/tmp/im-remediation-client-full.log`。新增普通命令完成入口的 canonical metadata 校验复用单次索引读取，同结果幂等，异结果冲突，完成后禁止重排 pending；批量 forward chunk 尚缺持久结果摘要，未关闭 B13。

- 本批最终 App 全量复验：123 tests / 11 suites 通过，日志 `/private/tmp/im-remediation-app-final-batch.log`；xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_12-31-12-+0800.xcresult`。
- 本批 PostgreSQL 专用实例 `/private/tmp/im-remediation-pg/primary`（端口 56440）已正常停止。未操作其他数据库，未提交代码或部署。全部 47 项仍保留在表内；当前 3 项已验证，7 项实施中，3 项已实现待验证，2 项待外部验收，32 项未开始。

- 2026-09-05 后续批：B11/D07 接入 Core 请求指纹与纯 reducer 原始输入比较，详见 [指纹实施合同](../2026-09-05-send-message-fingerprint-contract.md)。补充 B01 富文本整型溢出和 Codable 绕过校验的边界修复。数据库实际重放仍待改造，没有把 B11 记为已验证。
- `swift test --package-path IMV2Core --disable-automatic-resolution --jobs 4`：76 tests / 22 suites 通过，日志 `/private/tmp/im-remediation-core-fingerprint.log`。包括 Python 独立编码黄金向量、21 类业务字段变化、原转发/投递规则冲突、Unicode/UUID、字段边界和恶意 entity JSON。
- `swift test --package-path IMV2Server --disable-automatic-resolution --jobs 4 --filter 'V2SendMessageServiceTests|V2SpecialAccountMessagingServiceTests|V2GatewayDomainCommandHandlerTests'`：52 tests / 3 suites 通过，日志 `/private/tmp/im-remediation-server-fingerprint.log`。首次编译发现 Gateway 测试仍按旧完成记录结构取 sender，已适配后重跑通过；本批没有运行 PostgreSQL 场景。
- `swift test --package-path IMV2ClientKit --disable-automatic-resolution --disable-build-manifest-caching --jobs 4`：223 tests / 40 suites 通过，日志 `/private/tmp/im-remediation-client-fingerprint.log`。初次 SwiftPM 缓存构建清单未发现新增本地 Core 文件，刷新构建清单后通过，未删除用户数据库或整个 build 缓存。
- 相同 iPhone 17 / iOS 26.2 App 测试命令：123 tests / 11 suites 通过，日志 `/private/tmp/im-remediation-app-fingerprint.log`；xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_12-48-05-+0800.xcresult`。`git diff --check` 通过。
- 最新状态仍共 47 项：3 已验证、8 实施中、3 已实现待验证、2 待外部验收、31 未开始。全部测试进程已结束，专用 PostgreSQL 保持停止；未提交或部署。下一步是 B11 的无正文完成记录与所有 SQL 路径原子落盘，再推进 B03/B04/B06 的历史受众与投影合同。

- 2026-09-05 后续批：B11 新增 `message_send_completions`，9 处消息 INSERT 同 SQL/同事务写入指纹与无正文结果元数据；3 个 prepared statement 更新名称并增加版本/bytea[] 绑定。未增加逐消息 SQL 往返，未取消原 set-based append 或 credits。完成记录没有 message/room 级联外键，UPDATE trigger 拒绝修改既有结果；尚未启用 GC。
- 实际条件写入的完成 metadata 直接来自 INSERT RETURNING 的 membership revision 和既定投递路径，普通路径绑定已锁定 room snapshot；避免条件 SQL 等锁后通过旧 MVCC snapshot 再读 revision。相同房间 delivery mode 在现有 schema 中本就不可变，因此测试保留该约束，只推进 membership revision；运行时 direct delivery 配置切换的重放仍需后续验收。
- 专用 PostgreSQL（127.0.0.1:56440，`im_remediation`）执行 `swift test --package-path IMV2Server --disable-automatic-resolution --jobs 4`，filter 为 `sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|atomicallyPersistsPlainHybridGroupMessagesAcrossRooms|atomicallyPersistsRepeatedPlainHybridGroupRoomMessages|atomicallyPersistsAcceptanceWriteSet|freshDirectUserMicrobatchIsReplicaSafe|persistsDirectRoomLogWithoutPerUserFanoutArtifacts|directRoomLogCommandCreditsPreserveShardCapacity|directRoomLogRoomCommandCreditsPreserveRoomCapacity|reciprocalFirstSendsPromoteBothFastAppendDirections`：最终 10 tests / 1 suite 通过。其中保留性测试 3 种模式、schema 拒绝测试 2 种场景。日志 `/private/tmp/im-remediation-send-completions.log`。
- 新测试精确检查原 digest/event ID/message ID/序号/时间/authority/group mode/membership revision，覆盖内容修改、membership revision 推进、完成记录 UPDATE 拒绝、按现有外键顺序移除主消息与版本/mentions 依赖；现有 8 个集成场景补充完成记录与成功消息对应、回滚无孤立记录的断言。未据此声称所有非生产 SQLKit fallback 分支、全部内容清理、ACK 重放或 owner migration 已覆盖。
- 初次编译发现 Data 不直接支持 PostgresArrayEncodable，改用现有 PostgresNIO ByteBuffer/bytea[]；删除夹具按现有外键依赖调整。最终范围完整重跑通过，没有放宽原外键或房间模式不可变约束。
- 当前 schema 升为 `im-v2-current-6`。实际 `psql -f IMV2/sql/schema.sql` bootstrap 和 `IMV2/scripts/current_v2_schema_contract.sql` gate 验证：完整 schema 返回 `t`，临时移走完成表后返回 `f`；日志 `/private/tmp/im-remediation-send-completion-schema-gate.log`。只操作专用可丢弃数据库，夹具 schema 已移除，PG 已正常停止，未修改开发者现有数据库、提交代码或部署。
- 本批 `git diff --check` 通过。47 项状态计数不变；B11 继续实施中。下一步必须接入完成记录重放读取、无内容 ACK、数据库 room/actor/client 幂等范围，并继续覆盖内容清除/模式切换重试、GC/owner 迁移、forward source revision 与 WAL/CPU 代价。

- 2026-09-05 后续批：B11 的数据库重放现从 `message_send_completions` 读取无正文 receipt，对比原指纹；普通/批量 operation 键及锁统一 room/actor/client，denial 同样保存原指纹。修正普通 Swift UUID 大写与 SQL uuid::text 小写造成的不同锁键，批量锁按 hash 排序。schema 为 `im-v2-current-7`，协议 22 保留 metadata-only MessageAccepted，旧内容字段名与编号 reserved。现有库未自动迁移。
- 服务端最终回归 73 tests / 5 suites 通过，日志 `/private/tmp/im-remediation-receipt-server.log`。其中 PostgreSQL 覆盖 standard/hybrid/hybrid-mention 在编辑、撤回、主消息删除后实际重放原命令返回原 receipt，七类改参冲突、运行 profile 变化、跨房间共用 client ID、同房间八并发只接受一次、denial 原请求重放与改参冲突，以及完成记录保留和 schema gate。此前四处失败是旧测试仍要求跨房间冲突，按三元 operation 合同更新并增加同房间并发验证后通过；新增夹具的字段引用编译问题已修正。
- `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4`：225 tests / 41 suites 通过；日志 `/private/tmp/im-remediation-receipt-client.log`。新增富文本/媒体发送接受最小 ACK，以及错误 room、零/溢出序号、负时间四个拒绝参数。
- 相同 iPhone 17 / iOS 26.2 App 全量单元命令：123 tests / 11 suites 通过；日志 `/private/tmp/im-remediation-receipt-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_13-39-18-+0800.xcresult`。使用已有 protoc-gen-swift 执行 `scripts/check_v2_protobuf_generated.sh` 通过，含生成文件与当前协议文档检查。
- B11 保持实施中：条件 SQL 等待 operation 锁后旧 MVCC snapshot 的精确竞争、模式切换、GC/owner migration、forward source revision 与 WAL/CPU 代价尚无完整关闭证据。全部 47 项保留；下一批处理 B12 的有限目录扫描与剩余页调度。

- 2026-09-05 后续批：完成 B12。新增 `V2RoomLogCatchUpWorker`，作为 runtime 独立拥有并取消的任务；priority commands 之后只发 coalesced wake，不再把房间追赶阻塞在启动/availability 回调内。每次目录扫描由 SQLite 最大 room ID 和持久 round-robin pivot 确定有限尾段/首段，分页加载 room ID；仅实际 hasMore 的房间进入 FIFO backlog，每轮最多 12 页且每房间一页，后续量子主动让出执行权。
- 房间 sync engine 在 actor await 边界之外显式拥有每房间 page task 及维护 pass task，串行完整的读游标→请求→落盘；取消会传入当前 owned task，迟到网络结果在落盘前检查取消，后续调用先等旧任务结束。客户端拒绝 hasMore 却没有游标前进的响应，避免空转。snapshot 激活返回 resetPending 时 worker 等待个人同步完成后的新 wake，不关闭执行激活的连接。
- 新增 `V2RoomLogCatchUpTests`，覆盖 13/1000 空房间有限结束、热房间 10000 条与冷房间 1 条、公平顺序及无 hint 续跑、目录上界/重建 engine 后游标继续、无进展响应、前台与维护并发串行、取消忽略取消的 transport 后不落盘、snapshot fence 恢复。现有 runtime 生命周期测试增加 room loop 启动/取消观测。最小范围先通过 65 tests / 3 suites，最终客户端全量 `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4` 通过 232 tests / 42 suites，日志 `/private/tmp/im-remediation-room-catchup-client-full.log`。
- 最终 App iPhone 17 / iOS 26.2 全量单元 123 tests / 11 suites 通过，日志 `/private/tmp/im-remediation-room-catchup-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_13-53-37-+0800.xcresult`。`git diff --check` 与当前协议文档检查通过。
- 全部 47 项仍在表内：4 已验证、8 实施中、3 已实现待验证、2 待外部验收、30 未开始。B11 的端到端重放已经有证据，但其迁移/GC/性能及 source revision 相关验收仍开放。全部本批测试进程已结束，专用 PostgreSQL 已正常停止；没有修改开发者现有数据库、提交代码或部署。后续继续 B14/D01 的 transport 取消关联与连接代次，并推进 B03/B04/B06 的受众与恢复合同。

- 2026-09-05 后续批：完成 B14 的有界取消关联。移除调用者取消后会结束 deadline 的 request task group，改为连接拥有响应记录、send task 和原 hard deadline；取消只一次结束 continuation，记录仍占 transport 总上限（默认 256）。收到匹配晚响应释放取消记录；到期限仍未收到时关闭该代连接。未知未登记响应维持协议错误行为，没有任意 TTL 删除 ID 后继续复用旧流。
- D01 已接入 connection generation + request/waiter UUID；异步连接、bootstrap deadline、reader/receive、send failure、timeout/cancel 回调在触碰状态前校验代次/身份。每个连接有独立 InboundState，旧 reader 局部引用旧 buffer；close 先清 generation，再取消/释放，显式 disconnect 等旧 reader/send 返回且不再触碰新代状态。Network.framework readiness 使用 Mutex 一次性取出 continuation，防止已排队状态回调重复完成。
- 新增 `V2TLSFrameConnectionLifecycleTests`，测试直接驱动生产 TLS actor 的内部 byte boundary。覆盖 A 取消与晚 A/B 同包、取消记录占满容量直到原回复、取消后原硬期限、未知 response、旧部分帧/旧 reader failure、旧 send failure 与新代复用 request ID，以及三类已经取消的消费者不能取走 pending hint。首轮夹具错误地用版本 0 编码 ServerHello 被 codec 拒绝，修正为协商版本后通过，未放宽 codec。
- 增加真实 Network.framework 回环故障调度：仅绑定 `127.0.0.1` 的临时 TCP listener，暂停旧 NWConnection 的回调 DispatchQueue，关闭并建立新连接后再恢复旧队列；等待旧任务排空，再验证新请求完成。该测试验证系统字节回调/取消顺序；公共生产构造器仍固定 TLS 1.3 + 系统信任验证，未提供公开明文降级选项。本机 TCP 测试不覆盖生产 TLS 证书、外网与真机网络切换。
- 最终 `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4`：240 tests / 43 suites 通过，日志 `/private/tmp/im-remediation-tls-client-full.log`。针对性 Network/生命周期 8 tests / 1 suite（含 3 种提示和 2 种旧 reader 参数）通过，日志 `/private/tmp/im-remediation-tls-network.log`；缓冲切换后的协议/runtime 范围 38 tests / 4 suites 通过，日志 `/private/tmp/im-remediation-tls-final.log`。
- 最终 App iPhone 17 / iOS 26.2 全量单元：123 tests / 11 suites 通过，日志 `/private/tmp/im-remediation-tls-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_14-13-13-+0800.xcresult`。`git diff --check` 与协议文档门禁通过。所有测试进程已结束，回环 listener 已由夹具停止；本批未启动 PostgreSQL、提交或部署。
- 全部 47 项保留：5 已验证、8 实施中、4 已实现待验证、2 待外部验收、28 未开始。D01 仍需旧 waiter 取消与旧 deadline 回调的精确跨代组合证据；后续继续 B17 的连接恢复订阅重建及 B03/B04/B06 的受众和恢复合同。整体目标保持未完成。

- 2026-09-05 后续批：B17 新增 `V2RoomSubscriptionCoordinator` 与 `V2ConnectionRequestScope`。协调器保留 room/consumer UUID/channel 意图，实际 wire 订阅取活跃 token 并集；新连接取消并排空旧 run，重建订阅并清除 typing/presence/wake。每个 consumer 接收 bufferingNewest(1) 的完整、去重快照，带 connection/recovery ID；单一 retry 和 refresh clock 处理重试与补拉意图。共享的 request ID allocator 保持原实例，wire 注册边界核对 TaskLocal connection ID，堵住跨 actor await 后把旧 unsubscribe 发送到新 socket 的窗口。
- 使用 ui-snapshot-mode 约束状态提交：消息投影不进入订阅快照，快照仅含显示/恢复所需的不可变事实。typing 条目有界并清理过期状态，过期 presence 不重新发布。FORBIDDEN 标记 server-revoked，普通 wake 不自动重新订阅；个人同步后的 authorityDidChange 才重新检查，退出 token 幂等释放。
- 新增 `V2RoomSubscriptionCoordinatorTests`：多 scene 同 room 单次 wire 订阅与末 token 取消；顺序和重叠的两个 run 都重建订阅、清旧瞬态 lease；失败无 hint 重试；membership revoke/rejoin；旧 token 重复释放不影响替换。TLS 生命周期增加旧 request scope 不能向新 socket 注册命令或提示等待者的测试。最终针对性 14 tests / 2 suites 通过，日志 `/private/tmp/im-remediation-room-subscriptions.log`。
- 首轮夹具编译缺少 try，随后运行暴露 optional-chain 写 rooms 时同表达式再次读 rooms 的 Swift 独占访问冲突。已使用局部新值后再写回修正，保持 Swift 独占检查开启，完整重跑通过。
- 最终客户端全量 246 tests / 44 suites 通过，日志 `/private/tmp/im-remediation-subscription-client-full.log`。App iPhone 17 / iOS 26.2 全量单元 123 tests / 11 suites 通过，日志 `/private/tmp/im-remediation-subscription-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_14-32-58-+0800.xcresult`。
- [B17 订阅实施合同](../2026-09-05-room-subscription-contract.md) 列出当前组件及未完成的 App 接线。下一步必须把 runtime 和页面迁移到共享 coordinator，保留现有 live payload、100 ms metadata grace、gap recovery，并让 nextWake 的单次超时取消不结束整个 scene lease。现有 App 回归通过只证明当前兼容性，不能替代这条尚未接入的新用户路径证据。
- 全部 47 项保留：5 已验证、9 实施中、4 已实现待验证、2 待外部验收、27 未开始。测试进程均已结束；git diff 检查和当前协议文档门禁通过。本批未启动数据库、提交或部署，整体修复目标继续保持未完成。

- 2026-09-05 后续批：完成 B17 App 接入。`V2AppRealtimeRuntime` 创建唯一 coordinator，使用 localStore 授权、durable/preview cursor 和共享 transport；`V2ClientRuntime` 在认证及初始同步成功后以真实 connection UUID 运行订阅任务，停止和其他循环失败时取消。个人同步完成后触发授权复核。测试显式检查 runtime 传入的连接身份与停止取消。
- 页面新增 `V2ScopedActiveRoomSynchronizer`，单次 nextWake 取消仅释放 waiter，独立 snapshot pump 与 scene lease 保留。页面关闭仅释放自己 token；本地授权缺口不会销毁页面意图，退群暂停、rejoin 恢复。生产使用 coordinator 单一 recovery clock，保留现有 100 ms metadata grace、live payload、cursor gap 检查和补拉。
- 新接入测试实际发现 retained snapshot 不适合直接复用 pending socket buffer 的保守合并规则：纯水位订阅 ACK 会持续压掉后来的 payload。修正为合并无法保留正文时保留最新有界 batch，仍由消费者以 durable cursor 判断是否连续；没有把 hint 视为落盘凭据。增加客户端和 App 回归，覆盖 ACK 后正常 payload、metadata 后新 payload，以及周期恢复剥离旧 payload 后强制补拉。
- activity 页面按完整快照替换 typing/presence，订阅结束与连接换代清理接收方 lease，presence 到 expiresAt 自动失效。发送方 typing 续租捕获 consumer/connection ID 并通过 TaskLocal 送到 wire 边界；旧 token/旧代请求拒绝，重连不会自动重放旧 typing，下一次实际输入可以建立新续租。
- 最终客户端命令 `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4`：249 tests / 44 suites 通过；日志 `/private/tmp/im-remediation-subscription-client-verified.log`。App 全量单元仍使用 iPhone 17 / iOS 26.2：129 tests / 12 suites 通过；日志 `/private/tmp/im-remediation-subscription-app-verified.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_14-54-20-+0800.xcresult`。新增 App suite 4 项以及 ConversationStore 2 项直接走共享 coordinator；新客户端 3 项覆盖 payload、迟到 ACK 替换、发送 typing 代次，已有 runtime 生命周期测试加强连接身份/取消断言。
- 首两次 App 编译分别发现缺失 ClientKit import 和旧 fallback 分支缺少 return，修正后正常编译。首次新增行为测试失败揭示上述 snapshot payload 合并问题，修正后该范围及全量回归均通过；没有缩小成功断言或移除失败测试。
- 全部 47 项保留：6 已验证、8 实施中、4 已实现待验证、2 待外部验收、27 未开始。所有测试进程已结束，`git diff --check` 与当前协议文档检查通过。本批没有启动数据库、提交或部署。整体修复目标仍未完成；后续继续 B03/B04/B06 的历史受众/双流投影，以及 B15/B16 的账号清理与 Push 生命周期。

- 2026-09-05 后续批：开始 B15。新增 `V2LocalDatabaseArtifacts`，安装绑定失配/缺失与 App E2E 清理不再遗漏搜索库及其 WAL/SHM，App 文件保护集合也统一。`GRDBV2LocalSyncStore` 初始化失败显式关闭已打开 pool；新增非 MainActor 的双 pool close，迟到调用保留已关闭句柄而不能重建旧文件。
- 新增 `V2AccountStorageScope` / `V2AccountStorageDirectory`，以 UUID incarnation 绑定目录和待清理记录。清理记录先于 active 指针撤去，关闭成功后才删旧目录；失败保留可恢复状态，旧清理不按账号名寻找删除目标。完整实现和未接入项记录在 [B15 存储生命周期合同](../2026-09-05-account-storage-lifecycle-contract.md)。
- 针对性命令 filter `V2AccountStorageScopeTests|V2LocalStoreBootstrapperTests|V2ClientSessionBootstrapperTests`：15 tests / 3 suites 通过，日志 `/private/tmp/im-remediation-account-storage-foundation-2.log`。新增 suite 8 项包含命名与清理步骤参数化；验证真实 indexer/观察任务排空后双库关闭、关闭失败不删除、旧写不重建、重启恢复、A→B→A、无效记录失败。首次恢复测试暴露 Foundation URL 表示方式导致等值比较失败，改为校验已枚举固定目录内的精确 UUID 文件名后全部通过。
- 最终客户端全量 257 tests / 45 suites 通过，日志 `/private/tmp/im-remediation-account-storage-client-full.log`；App iPhone 17 / iOS 26.2 全量 129 tests / 12 suites 通过，日志 `/private/tmp/im-remediation-account-storage-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_15-04-14-+0800.xcresult`。
- B15 继续实施中：新 catalog 尚未接入生产 bootstrap/退出，App 的 account epoch、任务 drain、legacy 主库迁移和媒体路径迁移仍未完成。不能将组件模拟重启等同真实 kill App 验收，也不能改变未发送 outbox 保留规则来简化清理。所有 47 项保留：6 已验证、9 实施中、4 已实现待验证、2 待外部验收、26 未开始。测试进程均已结束，本批未启动数据库、提交或部署。

- 2026-09-05 后续批：B15 新增 `V2AccountLocalStoreOwner` 并接入生产 `V2ClientSessionBootstrapper`。账号 hash 下分配随机 incarnation，所有 open/close transition 跨 await 串行，同账号重复打开复用 pool；退出只关闭精确捕获的 store，普通退出保留该账号 outbox。App runtime/stager/downloader 改用 scope 路径，旧全局媒体路径生成函数移除。
- 旧固定主库先通过 device binding 验证，再以主库自己的 userID 选择迁移目标。即使 B 先登录，也保留旧 A 的命令在 A scope；global FTS 不迁入。`legacy-import.json` 在移动前提交，恢复移动前缀，目标冲突拒绝覆盖；FTS 删除前先把主库索引状态标记 building。`openTrustedLegacyStore` 将不可信安装与可信但无账号归属的数据分开，避免缺失安装锚点后生成空 unbound 旧库而阻塞新启动。
- App restore/signOut 增加认证尝试代次检查，退出先隐藏旧账号视图，再等待 indexer、停止 runtime 并关闭双 pool。runtime public stop 在断开连接后等待启动任务和所有 owned loops 结束，测试直接断言 stop 返回时循环已退出。完整凭据 epoch 和迟到认证 provider 仍属 B08/B09，未以 UI 代次代替。
- 针对性 31 tests / 5 suites 通过，日志 `/private/tmp/im-remediation-account-owner-tests.log`。最终客户端全量 264 tests / 46 suites 通过，日志 `/private/tmp/im-remediation-account-owner-client-full.log`；App iPhone 17 / iOS 26.2 全量 129 tests / 12 suites 通过，日志 `/private/tmp/im-remediation-account-owner-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_15-17-41-+0800.xcresult`。
- B15 仍实施中：新目录清理 marker 尚未覆盖所有显式擦除，旧媒体目录仍待 D04 清理，全部在途媒体/页面任务的 lifecycle、实际 kill/relaunch 与完整 account epoch 证据尚未补齐。当前 App 回归不能替代这些端到端关闭条件。47 项计数保持 6 已验证、9 实施中、4 已实现待验证、2 待外部验收、26 未开始。本批测试全部结束，未启动数据库、提交或部署。

- 2026-09-05 后续批：推进 B08/B09。检查发现旧 store.save 在 await 内挂起时，仅前后检查 generation 仍可能让旧写在新写之后落盘；新增实际 credentialIO 串行队列，旧操作排空后才允许新 save/delete，且旧结果不修改新内存状态。restore/load 也增加单飞，refresh 维持原持久 operation ID 与 caller cancellation 语义。
- 账号 provider 请求前预留进程内 epoch，后开始的认证/logout invalidation 使旧 provider 无法提交；bootstrap 在提交和打开 store 的 await 后检查。TLS tuple 带 epoch，旧连接认证成功/失败不能作用于新账号；失败还比较实际被拒绝的 access token，刷新后继 token 或刷新进行中不会被旧握手删除。该 epoch 明确不是服务端持久 session epoch。
- terminal deletion 暂时失败后，auth owner 保留只可重试删除的状态，不在 protected-data retry 时重新加载已终止旧凭据。App 在现有持久 logout intent 后调用 invalidateOutstandingWork。新增 [认证生命周期合同](../2026-09-05-authentication-lifecycle-contract.md) 区分本轮已实现与跨重启/离线补偿/Router 尚未完成的要求。
- 最终客户端全量 271 tests / 47 suites，日志 `/private/tmp/im-remediation-auth-epoch-client-verified.log`；App iPhone 17 / iOS 26.2 全量 129 tests / 12 suites，日志 `/private/tmp/im-remediation-auth-epoch-app-verified.log`。新 suite 覆盖四种挂起 store effects、并发 restore 一次读、锁屏删除、旧 epoch/旧 TLS 拒绝与 token 轮换；bootstrap 测试覆盖 A provider 迟到时 B 凭据和 store 不变。
- B08/B09 继续实施中：当前进程内次序已验证，尚未实现绑定旧账号的持久退出 checkpoint、远端专用撤销 capability、离线期限及完整认证状态观察。全部 47 项保留，计数仍为 6 已验证、9 实施中、4 已实现待验证、2 待外部验收、26 未开始。测试进程均已结束，本批未启动数据库、提交或部署；差异与协议文档门禁通过。

- 2026-09-05 后续批：B09 接入 `V2AuthSessionSnapshot` 与 `V2AuthenticationStateObserver`。状态流绑定单一 epoch，保留终止值并 finish，新账号状态不覆盖旧终止消息；临时 Keychain 不可用、terminal 删除待完成和认证已终止分开呈现。App 实际激活绑定观察器，收到对应变化后占有退出 gate、隐藏旧视图并停止/关闭旧 runtime 与 store，不对旧事件再次执行当前凭据删除。
- `requireAuthenticatedEpoch` 把 restore/激活期间已确定的终止归类为 authenticationRequired，解决凭据在主库打开期间失效却显示本地存储错误的窗口。严格 mutation fence 仍校验当前 epoch/token，没有为了路由方便放宽旧事件删除凭据的条件。
- 新 App suite 4 项驱动真实 auth session 与生产观察器，验证非 TLS 路径刷新终止、锁屏/恢复、旧排队观察任务替换和删除失败的独立状态；客户端增加 3 项覆盖慢 stream 跨新登录、删除失败后晚订阅、主库打开期间 revocation。
- 最终客户端全量 274 tests / 47 suites，通过日志 `/private/tmp/im-remediation-auth-observation-client-final.log`；App iPhone 17 / iOS 26.2 全量 133 tests / 13 suites，通过日志 `/private/tmp/im-remediation-auth-observation-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_15-46-22-+0800.xcresult`。真实账号服务、完整退出/冷启动及 HTTP 终止入口组合尚待补充，B09 仅推进为已实现待验证。
- 所有 47 项保留：6 已验证、8 实施中、5 已实现待验证、2 待外部验收、26 未开始。测试进程均已结束；差异检查和协议文档门禁通过。本批没有启动数据库、提交或部署，整体修复目标保持未完成。

- 2026-09-05 后续批：关闭 B13。批量 forward chunk 保存带 v1 域标识的 SHA-256 canonical completion digest；按持久命令的 source 顺序编码 source/target/message ID、room sequence 与成功/失败 error code，wire 结果重排不影响摘要。ACK/拒绝与父计划推进同 SQLite 事务，同结果重复完成不增加计数，异结果和取消后的迟到完成拒绝；本地 consistency error 不被 engine 转成网络 retry。同 plan ID 的 source/target 变化也被拒绝。
- 本地 schema 增加可空 completion_digest 和显式 additive migration，保留既有账号 outbox。历史已完成 chunk 无原结果时不回填推测摘要，重放报冲突；待发送 chunk 正常升级后继续。新 suite 验证 20 并发完成、重排、关闭重开、八类冲突、拒绝重复、取消、父更新故障时整事务回滚及旧布局升级；fresh schema 指纹同步更新。首轮夹具缺失 try/await 已修复，最终全量客户端 282 tests / 48 suites 通过，日志 `/private/tmp/im-remediation-forward-completion-client-full.log`。
- B13 集成验证：App iPhone 17 / iOS 26.2 全量 133 tests / 13 suites 通过，日志 `/private/tmp/im-remediation-forward-completion-app-full.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_16-00-02-+0800.xcresult`。
- 关闭 B10：新增实际 production store 测试，在提交 A 后分别让 B 处于 loading/ready/submitting，再放行 A 的成功或失败，共六种交错，确认 B 的状态与 token/note/operation ID 不变。测试 barrier 支持同时挂起多个 HTTP 提交，不用覆盖 continuation 掩盖交错。定向 6 tests / 1 suite 通过，日志 `/private/tmp/im-remediation-invitation-intent-app.log`；已核对按钮关闭和 sheet binding 均调用 dismissJoin，退出调用 invalidate。此项只覆盖预览与提交绑定，不代表尚未实施的邀请配额/审批/owner 路由已完成。
- 关闭 B19：原游标再次返回时拒绝该页并关闭继续加载；页结果与索引进度读取完成、取消/代次验证后一次提交，避免在挂起点留下半页结果。取消释放分页运行标识并保留原游标，失败/索引重建关闭继续加载，重新搜索可恢复。新增游标停滞、取消后重试、两类失败、query/page 旧进度迟到、成员/内容筛选切换；原单页测试改为运行中追加 19 次调用。最终 App 全量 139 tests / 13 suites 通过，日志 `/private/tmp/im-remediation-search-continuation-app-full.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_16-04-35-+0800.xcresult`。客户端全量已包含实际 SQLite 查询变化与索引 rebuild 后旧 cursor 拒绝证据。
- 全部 47 项保留：9 已验证、7 实施中、3 已实现待验证、2 待外部验收、26 未开始。全部本批测试进程已结束，差异和协议文档门禁通过；未启动 PostgreSQL、提交代码或部署。整体目标仍未完成，下一批继续 B21 的会话/联系人已加载窗口保持，以及 B03/B04/B06 的服务端历史受众与恢复合同。

- 2026-09-05 后续批：推进 B21。会话 refresh 默认按已加载数量进行有限页序列读取（每次至多 100 行），列表已有数据时保持 loaded，避免后台刷新移除整个 List。新增 resetWindow 显式重置入口，归档范围切换使用该入口；刷新占有 operation ID 并清除旧分页所有权，新分页仅在刷新完成后开始，旧请求的 defer/error 不影响新请求。
- 联系人刷新分别捕获 friends/incoming/outgoing 已加载数量，每次仍以 50 条读取与资料补全；搜索保存 loadedSearchQuery，同查询刷新保留搜索范围，新查询从第一页开始。四个分页 lane 各自拥有 operation ID，刷新和搜索刷新有独立所有权，拒绝用旧 query 的 cursor 加载新搜索。刷新结果一次提交并重建查询缓存，删除不从旧数组补回。
- 新回归覆盖 150 条会话刷新期间保持原列表、删除与显式重置，以及旧分页挂起→刷新→新分页挂起→旧响应返回不释放新请求标识；联系人覆盖 120 好友、80 收到申请、75 发出申请和 100 条搜索结果的独立窗口，删除与新查询重置。现有 51 条分页测试补刷新保持断言。最终 App 全量 142 tests / 13 suites 通过，日志 `/private/tmp/im-remediation-list-window-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_16-14-25-+0800.xcresult`。
- 本批仅完成 B21 的已加载数量保留与异步所有权基础。未声称顶部大量插入时仍保持深度浏览位置：下一步必须接入 viewport anchor 和围绕 anchor 的有界窗口、删除 fallback、合并刷新通知，避免刷新成本长期随浏览深度增长。全部 47 项保留：9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始。全部测试进程已结束，未启动 PostgreSQL、提交或部署，整体目标保持未完成。

- 2026-09-05 后续批：B21 新增 `GRDBV2ListWindows.swift` 与两个类型化窗口结果。会话/联系人窗口在同一个 pool.read snapshot 中先按 ID 解析锚点的当前排序值，再读取前后邻居，默认 200 条、最大 500 条；锚点删除或退出当前范围时按捕获的旧 key 选择最近后继，无后继则选前驱。顶部新增不通过扩大 limit 把用户推回头部；末端不足时补前面的邻居。返回解析后的 anchor、hasEarlier 与 nextCursor 供页面前后翻窗。
- keyset 的混合排序条件拆成互斥、分别带 LIMIT 的范围分支，外层只合并有限候选。会话资料物化函数与原 page API 共用，联系人 scope/search predicate 也抽成共用函数；无 OFFSET、无长期 UI 读事务、无 schema 变更。EXPLAIN 检查非搜索主范围分支使用已存在的排序索引范围读取，不能据此推断所有 FTS 选择率下的 CPU 上限。
- `V2ListWindowTests` 验证原 2000 条会话之上再加 2000 条后窗口和锚点不变、锚点改置顶/时间后以当前位置重新定位、三种删除位置的 fallback、相同时间戳 ID 排序、archive 隔离，以及 3000 条关系中 friends/incoming/outgoing 各自的窗口与撤销排除。现有实际 FTS 搜索测试增加 anchored window 与换查询范围，发现并修复关联资料表时 updated_at 列歧义；结果列显式别名后全量通过。
- 最终客户端 `swift test --package-path IMV2ClientKit --disable-automatic-resolution --jobs 4`：287 tests / 49 suites，通过日志 `/private/tmp/im-remediation-anchored-window-client-final.log`。App iPhone 17 / iOS 26.2 全量 142 tests / 13 suites，通过日志 `/private/tmp/im-remediation-anchored-window-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_16-26-24-+0800.xcresult`。
- B21 继续实施中：窗口 API 尚未进入页面调用链，不能把存储层验证算作浏览位置已修复。下一步接入真实可见条目、每个列表的窗口所有权、前后翻窗、ScrollViewReader 恢复和刷新合并，并用实际 UI 验证 List 行重用与滚动位置。SwiftUI API 已核对本机 SDK 声明及 [Apple 滚动接口文档](https://developer.apple.com/documentation/swiftui/scroll-views)，尚无本机 List 运行行为证据。47 项状态数不变：9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始。全部本批测试进程已结束，差异和协议文档门禁通过；未启动 PostgreSQL、提交或部署。

- 2026-09-05 后续批：B21 会话页面正式接入 `V2ConversationWindowReading`，生产 `V2GRDBConversationDataSource` 通过同一格式化函数返回普通页和锚点窗口。store 围绕可见条目刷新，窗口最多 300 条；向后分页移走前端，向前翻窗恢复到新窗口首条，回到最新/归档切换重置。窗口发布、游标和恢复请求在 MainActor 同步提交；原旧请求 operation ID fence 保留。
- 新增 `V2ListViewport`，可见性依据 List 坐标系内的真实 minY/maxY 与容器高度，不能把预加载行的 onAppear 当成可见。几何缓存仅保留当前窗口 ID，视图消失移除行；UI 只观察锚点和 UUID 恢复请求，恢复请求的旧完成不能清掉新请求。生产 List 使用 ScrollViewReader、行几何修饰符及页面 `.task(id:)` 发起恢复。
- 新 App suite 使用正式 room/conversation_state 同步入口创建 4000 个会话，经过真实 GRDB 数据源与 production store 连续分页超过 1300 条，检查 300 条上限、顶部插入、当前锚点归档后的 fallback、向前翻窗和显式重置。初始夹具直接引用 GRDB 导致测试目标链接失败，已改用公共同步入口而未改项目依赖；夹具误用 room_profile kind 导致空列表及测试强制解包崩溃，改成协议正式 room kind 并使用 require 后通过，未放宽生产解析。
- 真实 UI 测试创建模拟器 UIWindow、挂载生产 `V2ConversationListView`，等待真实几何回调，实际执行 ScrollViewReader 翻窗和刷新，再检查目标行仍处于可视区域。该测试发现 onChange 内清除请求造成同帧重复更新并超时；改为页面生命周期拥有的 task，在调度边界复验取消后恢复并消费请求。修正后的定向 3 tests / 1 suite 及最终 App 全量 145 tests / 14 suites 均通过。未据此声称像素级偏移、VoiceOver 焦点或真机滚动体验已完成验收。
- 最终日志 `/private/tmp/im-remediation-conversation-window-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_16-42-13-+0800.xcresult`。本批没有修改 ClientKit，沿用当前版本客户端 287 tests / 49 suites 证据。差异和协议文档门禁通过，全部测试进程已结束；未启动 PostgreSQL、提交或部署。
- B21 仍未完成：联系人 friends/search 与 incoming/outgoing 页面尚需接入各自锚点窗口，合并刷新通知、读取期间用户继续滚动的交错仍待验证。全部 47 项保留，9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始，整体目标保持未完成。


- 2026-09-05 后续批：B21 联系人页面正式接入 `V2ContactsWindowReading`。好友/搜索各保留最多 300 条，收到/发出申请各 150 条；共用申请页面的可见锚点，但只恢复正在查看的分组，另一分组保留自身窗口。提供前翻、后翻与回到开头入口，搜索换查询重置；后台刷新保持同查询窗口。生产数据源复用原资料物化，入站申请徽标继续查询总数，不能把有限窗口大小当作总数，也未声称 COUNT/任意 FTS 选择率下计算量恒定。
- 新生产测试通过正式 relationship 同步和授权 profile view 写入种子，覆盖 600 好友、两组 400 申请、头部新增、删除 fallback、搜索窗口和精确徽标。实际 UIWindow 挂载生产好友/申请 List 后验证目标行可见，UI 测试窗口使用独立 lease 串行占有，其他测试仍并行。
- 刷新读取期间继续滚动：新增共用 `resolveRead`，提交时若可见项已变化且仍在返回窗口中，则恢复最新条目；若越出结果窗口，则在同一 operation/generation 所有权下重新围绕新锚点读取。联系人三个分组共用本轮捕获的锚点，避免顺序读取混合不同滚动位置。结果、游标与恢复请求在 MainActor 无挂起提交。使用真实 SQLite 结果后的 continuation barrier，确定性覆盖窗口内移动、跨窗移动、联系人搜索与请求分组切换，不靠延时猜测数据库交错。
- 真实页面回归先后发现两类问题，未将定向成功代替全量验收：第一次 `scrollTo` 可被估算行高限制，实测目标 minY 854.33 超过容器高 724；以及 List 行复用后几何缓存归零。页面生命周期 task 现在以最多 8 次、每次间隔 20ms 等待布局并校正，拖动开始清除恢复请求。行重新出现时用 GeometryReader 读取当前坐标；每个行实例有 owner UUID，旧实例消失不能删掉新实例的几何。新增 owner/用户滚动取消测试；测试预期锚点改在插入夹具完成、刷新即将开始时捕获，保留刷新后真实可见性断言。
- 中间失败日志保留在 `/private/tmp/im-remediation-scroll-during-read.log`、`/private/tmp/im-remediation-scroll-window-app-full.log`、`/private/tmp/im-remediation-contact-restoration-diagnostic.log`。首个失败后的 xcodebuild 在采样中仅收集 simulator diagnostics，测试与编译进程已退出，最终自行以 65 结束；后续测试禁用额外 sysdiagnose 收集，测试断言与 xcresult 保留。一次单方法过滤没有匹配 Swift Testing、执行 0 tests，不计入通过证据；改用完整 suite/target 后验证。
- 最终 App 全量 `xcodebuild test`：150 tests / 14 suites 与 4 项启动 UI 测试均通过，日志 `/private/tmp/im-remediation-scroll-window-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_17-22-41-+0800.xcresult`。ClientKit 本批未改，沿用当前客户端 287 tests / 49 suites 的证据。差异与协议文档门禁通过，本批所有测试/诊断进程已结束；未提交、启动 PostgreSQL 或部署。
- B21 仍实施中：通知尚缺安全可用的影响范围/紧急程度元数据，不能一律延迟 100–200ms 而推迟撤权或删除；前后翻页过程中用户改变浏览位置、前翻窗资料补全也继续保留为待验证/修复边界。真实拖动回调、像素偏移与 VoiceOver 焦点未以模型测试替代。全部 47 项保留：9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始；整体目标未完成。


- 2026-09-05 后续批：继续推进 B21。会话和四个联系人 lane 在后翻页返回后，先计算追加结果将移走的前端 ID；若当前可见锚点会被移走，保留原窗口、游标和 earlier 状态，释放当前分页 operation，用户再次翻页可重试该页。仅限制当前 UI 窗口提交，不回滚已完成的 SQLite 读取或改变同步事实。会话页顺便对页内 ID 去重后计算窗口大小，避免重复记录影响裁剪判断。
- 前翻页捕获起始可见锚点，返回时若用户已移动且新位置仍在结果中，则保留最新位置；若新位置超出结果，则丢弃此次 UI 窗口提交。申请页面把另一个分组的现有 ID 纳入可保留范围，避免一个分组前翻时抢走另一个分组的可见位置。原 refresh/search generation 和 page operation ID fence 保留。
- 联系人新增共用 `loadAnchoredWindow`，刷新与前翻都按窗口内缺失 profile view 进行授权补全，生产数据源继续按 `V2ProfileViewLookupLimits.maximumKeys` 分批并使用 relationship context。补全后重读同一锚点窗口，保留已取得的总数徽标；第二次读取返回后再次检查取消与刷新/搜索代次。
- 新确定性交错测试暂停实际 GRDB 返回结果：会话验证后翻移除保护、前翻时移到结果内/结果外两类行为、保留游标后再次操作可推进；联系人 friends/search/incoming/outgoing 四个 lane 都验证后翻与前翻的移除保护、游标不前移、重试推进和 300/150 上限。资料补全测试先通过正式同步种下 600 好友，深分页后删除已离开窗口的一个 profile view，再向前翻窗，确认仅请求该一个用户的 relationship 授权资料并写回/显示，未扫描补全窗口外全部用户。
- 定向分页 15 tests / 2 suites 通过；资料补全测试夹具的 `.profile` 参数初次使用了错误标签，修正为正式 `view:` 后联系人 10 tests / 1 suite 通过。最终完整 App 回归：153 tests / 14 suites 与 4 项启动 UI 测试通过，日志 `/private/tmp/im-remediation-page-scroll-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_17-32-27-+0800.xcresult`。ClientKit 本批未改，仍沿用当前 287 tests / 49 suites 的证据。差异与协议文档门禁通过，所有本批进程已结束，未提交或部署。
- B21 未关闭：下一步是合并后台刷新且保留撤权/删除的即时更新。当前 notifier 只有全局 generation，runtime 的个人同步回调无变更参数、room catch-up 只有 appliedEventCount；消费者包括会话、详情、联系人及隐私页，不能根据“同步完成”推断可延迟或无关范围。需在已提交投影边界补充可验证的影响范围/紧急程度，未知变更必须保守立即处理。真实连续拖动、像素偏移、VoiceOver 焦点的验收仍不能由 store barrier 测试替代。全部 47 项及原状态保留：9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始，整体目标未完成。


- 2026-09-05 后续批：B21 新增 `V2ProjectionChanges.swift` 与 `GRDBV2ProjectionChanges.swift`。每个 SQLite 写事务只积累四类页面范围 bitset 与一个紧急位，在 commit 后发布；rollback 清空，GRDB 自身处理 savepoint 回滚。observer 只在 writer queue 构造/使用并由 databaseLifetime 保有，不跨队列暴露可变对象；跨执行器的订阅槽由 Swift Mutex 保护，锁内无 await、数据库读取或 continuation yield。
- 订阅的 AsyncStream 只缓冲一个唤醒，真实待处理范围与紧急程度保存在每个订阅的有限摘要中，消费前持续取并集。慢页面不会因 bufferingNewest 替换而丢掉较早撤权或另一页面范围。订阅先得到全量立即失效，数据库关闭/owner 释放结束所有订阅；初始订阅与提交在 hub 内同步，不能为省成本按 statement 开始时“有没有订阅者”跳过事务观察，否则中途订阅并读到旧快照可漏掉稍后提交。
- 分类依据实际已变动的主库表：普通新消息/衍生会话摘要允许合并；消息更新/删除、权限、隐私和未知投影保守即时处理。shadow/retired bank、同步游标/事件日志及 FTS 维护不代表已发布 UI 数据；快照正式切换时同事务写入的 v2_snapshots 发布全量即时失效。没有新 schema、额外持久日志或逐行 roomID 查询，通知是重读持久投影的提示，不承载唯一业务事实。
- App notifier 移到独立文件。普通提交以首次到达为起点共享一个 150ms timer；紧急变更取消 timer 并立即发布待处理范围的并集。订阅按 conversations/conversationDetails/contacts/privacy 过滤；SQLite 观察任务与 timer 都由当前订阅集合拥有，最后一个订阅结束时取消，UUID 防止旧任务完成影响新观察。runtime 改为使用 localStore 的提交信号，移除个人同步/room catch-up 完成后的重复全局 publish，因此资料网络补全不再阻挡通知产生。
- 客户端新增 4 项测试：同事务多行只产生一次摘要、慢/快两个订阅消费 40 次普通写仍保留早先隐私紧急位、rollback/savepoint 不泄漏、update/delete/未知表/快照标记即时通知、close 后流结束。已有真实快照中断/恢复测试加入暂存阶段无通知、正式 activation 后 .all 的断言。初次夹具缺少 timeline_sequence 导致唯一键冲突，按真实 schema 补齐后通过；未放宽数据库约束。
- App 新增手动时钟测试验证 60 次普通更新只开一个 150ms timer、范围并集、不触发无关隐私页、紧急更新在未放行时钟时已送达、取消后迟到计时器不能重开已结束订阅；正式 message.accepted/withdrawn 同步→实际 GRDB→notifier 验证普通消息合并、撤回即时发送且联系人页未获无关事件。初次测试漏导入 IMV2Core，补齐模块导入后通过。
- 最终 ClientKit 全量：291 tests / 50 suites，通过日志 `/private/tmp/im-remediation-projection-change-client-full.log`。App 全量：156 tests / 15 suites 与 4 项启动 UI 测试通过，日志 `/private/tmp/im-remediation-projection-notifier-app-full.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_17-56-59-+0800.xcresult`。差异和协议文档门禁通过，全部本批进程已结束；未提交、启动 PostgreSQL 或部署。
- B21 仍实施中：上述证据证明通知生成/合并的即时旁路，尚不能证明 UI 已立即应用。四个页面目前仍在 `for await` 内等待一次 refresh；如果其中资料读取较慢，紧急通知会暂留缓冲，旧读也可能先发布。下一步必须把紧急程度带到消费端，处理在途刷新取消、旧结果 fence、任务 drain 与新读取接续，并测试慢刷新/撤权交错。真实连续拖动、像素偏移及 VoiceOver 焦点仍无替代验收。全部 47 项状态数保留：9 已验证、8 实施中、3 已实现待验证、2 待外部验收、25 未开始；整体目标未完成。


- 2026-09-05 后续批：关闭 B21。App notifier 的订阅现在传递 generation 与 requiresImmediateRefresh，仍只缓冲一个唤醒；每个订阅保存尚未消费的紧急位并取 OR，后来普通更新不能把较早的撤权降级。App 自定义迭代器使用 Swift 6 的 `next(isolation:)` 传递调用者隔离，避免将非 Sendable iterator 发送给 @concurrent 方法；未用 unchecked Sendable 或关闭并发检查规避编译错误。
- 新增 MainActor `V2ProjectionRefreshObserver`，每个页面拥有一个通知读取子任务与一个串行刷新 worker。普通更新只保留一次待处理刷新，不取消在途工作；紧急更新立即取消 active task，worker 等它退出后再读最新投影，始终至多一项 active refresh。页面退出/订阅结束取消两子任务并 drain active task，等待槽以 UUID 保护，未累计无界的旧刷新任务。
- 会话、详情、联系人和隐私页面都接入相同 worker。补齐 refresh 的取消/代次检查，覆盖资料读取之前与之后、URLSession 返回 URLError.cancelled 的错误路径、每个隐私读取间隙、媒体清理之后及建群状态恢复之后。旧任务不继续请求资料、不把取消显示成失败反馈、不在异步清理后提交旧时间线；原分页/窗口 operation 所有权保留。
- 新测试证明普通 40 次更新只接续一次刷新且不取消旧读；紧急更新先取消并 drain 旧读再启动第二次，页面退出也等第二次取消完成，最大并行刷新数为 1。通知测试以另一个 scope 的已收到事件为因果屏障，确认缓冲的紧急位在新普通事件覆盖后仍为 true。
- 两条生产路径的交错证据：正式 relationship 同步→真实 GRDB→联系人 store 已显示好友，随后暂停缺失资料读取；本地撤权提交经 notifier 取消该读取，读取器返回 URLError.cancelled，最新窗口移除好友且没有错误提示。正式 message.accepted/withdrawn 同步→真实 GRDB 时间线→详情 store，在旧正文已读取但尚未返回时暂停；撤回取消旧读取，后续读取显示 withdrawn 且旧正文不回写。两条路径都通过真实数据源，测试只在异步边界注入可控暂停。
- 旧会话监听测试原来在上一页返回但尚未 UI 提交时就发布下一次紧急通知，取消新机制使该旧结果不保证显示；测试改为先等待期望消息已提交，再发下一次通知，保留原断言。新增正文撤回用例最初没有被单方法 MainActor 标注下的套件发现，未把 4 项通过当成包含它；将测试套件整体标为 MainActor 后明确看到该用例启动/通过，5 项通知测试全通过。
- 最终 App 全量：161 tests / 16 suites，与 4 项启动 UI 测试通过，日志 `/private/tmp/im-remediation-urgent-refresh-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_18-22-47-+0800.xcresult`。ClientKit 本批未改，当前 291 tests / 50 suites 的证据仍适用。差异和协议文档门禁通过，全部本批进程已结束，未提交或部署。

B21 按修复方案逐项关闭审计（仅此问题，不代表全部目标完成）：

| 关闭条件 | 当前实现与直接证据 |
| --- | --- |
| 初载、手动重置、后台刷新分开，100 条以上刷新保留有效窗口 | 显式 resetWindow/return-to-first 与默认保留窗口；会话、联系人 store 分页和刷新测试，以及最终全量中实际页面测试通过。 |
| 深浏览候选有界，头部大量变化不挤走可见锚点 | 会话/好友/搜索最多 300，申请两个分组共最多 300；ClientKit 同一短快照按锚点 seek，生产 4000 会话和联系人头插测试，实际 SwiftUI List 行几何/滚动恢复通过。没有长期 DB read transaction。 |
| 锚点删除有确定 fallback，联系人子列表独立游标 | ClientKit 窗口测试覆盖首/中/尾删除、归档与关系撤销；App 四 lane 保留各自 cursor，前后翻页与滚动交错不移走当前条目，重试仍可推进。 |
| 后台更新合并 100–200ms，刷新受影响 scope | 提交后有界摘要，150ms timer，四类 scope 订阅；手动时钟与真实 SQLite 测试证明单 timer、范围并集及无关页面不被唤醒。 |
| 权限撤销/内容删除立即生效 | 紧急摘要不等待 timer、两层缓冲均保留紧急位；消费端取消慢刷新后接续最新投影，真实联系人撤权与消息正文撤回交错测试验证旧结果未提交。 |

- B21 标为已验证；像素级偏移、任意非协作外部操作的停止时限与真机 VoiceOver 焦点不在上述测试结论内，其他问题的真机/发布验收状态未变。完整 47 项保留：10 已验证、7 实施中、3 已实现待验证、2 待外部验收、25 未开始。整体目标继续，后续回到 W1/W2 的历史受众、消息 delivery authority 与统一 reducer 等未完成主链路。

## B04 第一批：历史成员区间与接受锁顺序

- 源批量读取和最终接受共用 `v2ForwardSourceVisibility`：历史 accepted 区间与当前区间分别检查，支持两个合法成员区间及两种 accepted 存储表示；缺失或身份不符的原始证据拒绝。继续保留有序批量读取与目标并发上限，不把普通发送改成多房间锁。
- 转发 pair 在接受事务开始按 room UUID 排序锁定完整源/目标集合，再进入目标准入和源消息检查。最终同时核对源房间、作者、撤回状态、正文/实体和媒体引用。源已不存在时依然可重放旧完成记录；不会把不存在的源接受为新消息。
- 精确组合测试让初始读取成功后提交源房间成员移除，目标成员资格保持；实际最终接受返回 FORBIDDEN，消息数和完成记录数不增加。另以 16 个独立 store 实例同时执行两个方向转发，全部接受且各有一条完成记录。
- 验证命令：专用 56440 PostgreSQL + `swift test --package-path IMV2Server --disable-automatic-resolution --jobs 4 --filter 'forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|V2GatewayDomainCommandHandlerTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction'`，最终 **57 tests / 3 suites 通过**，进程退出 0；日志 `/private/tmp/im-remediation-forward-authorization-final.log`。
- 历史区间测试有 room_event/message_row 两个参数；完成重放覆盖 standard/hybrid/hybrid-mention 三种模式。首次夹具修改 immutable event 被数据库拒绝，改为离群期间真实接受第二条消息；并发夹具的房间窗口与 profile 最初不匹配，已修正。未关闭约束或把失败运行计入通过证据。
- 当前全部 **47 项：10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。B04 保持实施中；精确源版本/指纹、当前内容版本受众、跨 owner export/inbox、媒体与迁移仍开放，详见 [转发源授权合同](../forward-source-authorization.md)。没有提交或部署。

## B04/B11 第二批：精确源版本、指纹 v2 与 schema 8

- 新增接受输入 `V2ForwardMessageSource`，源版本必须是正值且可持久化的 `V2MessageRevision`。历史显示的 `V2ForwardedMessageAttribution` 仍只含 message/sender，避免要求旧消息提供不存在的版本；客户端历史解码全量回归通过。初始批量源读取携带 content revision，接受事务在源消息锁下严格比较，正文/实体/媒体检查继续保留。
- 普通发送继续生成原 v1 编码，转发生成包含 source revision 的 v2。持久化构造器接受 v1/v2；独立 Python SHA-256/大端编码向量确认 v1 的 118 字节向量不变，v2 完整转发 Fixture 为 325 字节。版本变化即指纹变化，包括正文改走后又改回的 ABA。
- pair 首次 client ID 分配与 source revision 在同一事务持久化；同一操作重试遇到其他版本返回 IDEMPOTENCY_CONFLICT。数据库 trigger 拒绝改变 pair 身份、源版本与已完成结果。旧 pending 的未知版本保留 NULL 并拒绝新接受；已有成功 pair 仍在源读取前恢复结果。
- schema 8 canonical、Swift readiness、实际本地 SQL gate 和 `20260905_forward_source_revision.sql` 一起更新。迁移在同一事务完成列/约束/trigger 后最后更新合同；真实测试从 schema 7 形状和已有 pending/v1 receipt 迁移，证明未知版本不被回填、旧 receipt 保留、错误重跑回滚。两套 gate 均拒绝缺完成表、旧 schema、缺源版本列、仍只支持 v1 的约束和禁用身份 trigger。
- 最终 **Core 76 tests / 22 suites**：`/private/tmp/im-remediation-forward-revision-core-final.log`；**ClientKit 291 tests / 50 suites**：`/private/tmp/im-remediation-forward-revision-client-final.log`；**Server 59 tests / 3 suites**：`/private/tmp/im-remediation-forward-revision-server-clean-tests.log`。三个最终进程均退出 0。Server 使用专用 56440 PostgreSQL、`--disable-build-manifest-caching --jobs 4`；filter 为 `forwardSourceRevisionFencesABAAndRetry|forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|V2GatewayDomainCommandHandlerTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction`。
- 初次客户端编译暴露展示 attribution 被复用，已用独立接受类型修复；随后服务端增量构建复用了旧签名测试对象，清理对应测试产物后缓存构建计划仍缺 output-file-map，禁用 manifest caching 重新生成并完成验证。失败构建未计入通过证据，未重启任何仍存活的测试进程。
- 当前全部 47 项仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。B04 的当前内容版本受众、跨 owner export/inbox、媒体和迁移仍开放；B11 的 GC/owner 迁移、精确条件竞争和 WAL/CPU 仍开放。下一批可用投影的 state_event_id 定位编辑版本的提交受众；另需验证多跳媒体转发中源消息 sender 与原 media owner 不一致的路径。未修改开发者现有数据库，未提交或部署。

## B04 第三批：当前编辑版本受众

- 转发初始读取与最终接受增加第三个区间条件：`content_revision > 1` 必须对应同一 room/message/version 的 immutable `message.edited` 事件，用户在编辑提交 membership revision 时仍属合法成员。原 accepted、编辑提交、当前 membership 各自检查，允许分别由不同区间满足；重入后不能读取缺席期间的编辑，重入后提交的新编辑可以读取，新成员仍不获得旧消息权限。
- 没有依赖 projection state 的非空 state_event_id：已确认旧 materialization 会为 revision > 1 写 NULL，单靠此指针会误拒绝合法旧消息。新查询直接定位 immutable event，覆盖缺投影状态的合法旧版本；当前版本事件缺失或 payload room 身份不符时拒绝，不能回退到“当前在群”。
- 新增仅覆盖 message.edited 的唯一表达式索引 `room_events_message_edit_revision_idx`，按 room/message/version 点查，并禁止同一版本存在两份不同提交权威。真实 EXPLAIN 在 2,000 条其他历史编辑事件下使用该索引；这只是有界查询计划证据，不是长期容量验收。
- canonical schema、Swift gate、实际 SQL gate 升为 9；迁移 `20260905_message_version_audience.sql` 从 schema 8 在一个事务中创建索引后最后更新合同。测试在已有真实编辑事件上迁移；模拟旧数据同版本的两份不同受众事件时，索引创建失败且整笔回滚，schema 保持 8、两份事件保留、部分索引不存在，服务仍拒绝启动。两套 gate 还拒绝缺索引和同名错误键形状。
- 最终 `IMV2_POSTGRES_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:56440/im_remediation IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 swift test --package-path IMV2Server --disable-automatic-resolution --disable-build-manifest-caching --jobs 4`，filter 为 `forwardChecksEditedVersionAudience|contentAudienceMigrationRejectsDuplicateVersions|forwardSourceRevisionFencesABAAndRetry|forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|V2GatewayDomainCommandHandlerTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction`：**61 tests / 3 suites 通过**，退出 0。日志 `/private/tmp/im-remediation-forward-content-audience-final.log`。普通群/混合群分别验证成员区间，已有两种 accepted 表示、ABA、反向并发、v1/v2 完成重放和 7→8→9 链式迁移一并回归。
- 全部 47 项状态仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。这不关闭 B03 的其他事件流、读取、snapshot/repair 与媒体 grant，也不关闭 B04 的跨 owner export/inbox、多跳媒体、媒体导入和迁移。详见 [转发源授权合同](../forward-source-authorization.md)。未修改开发者现有数据库，未提交或部署。

## B04 第四批：同库多跳媒体与引用撤销

- 确认原实现以 source sender 充当 media owner，A 的素材经 B 转发后 C 无法再次转发；同时最终源引用比较未检查 revoked_at。改为明确的 ownedBy/forwardedFrom 两种内部授权：普通发送继续要求自己的资产，转发只能使用已通过源历史/版本/当前权限检查的完整有效引用集合。
- 源引用按 media ID 取得共享锁，再核对原 ordinal 顺序；媒体对象继续按 ID 锁定并校验 available/有效期。初读发现任一 revoked 引用时拒绝整条源，避免丢图后静默复制说明文字或部分附件。最终接受重新检查所有引用状态；MEDIA_UNAVAILABLE 与普通发送的错误词汇保持一致。
- 普通群与混合群测试均实际发送 A→B→C 多跳，确认 owner 仍为 A、顺序完整；额外测试去掉、删减、反排、替换为 B 所有的无关素材都拒绝，普通 B 发送别人的素材仍拒绝。普通撤回 A 的原消息后，从先前独立授权的 C 副本继续复制成功；未将此行为扩张为显式 redaction 的全局清理已实现。
- 组合时序在初始源读取之后提交单引用撤销，再进入真实接受，返回 FORBIDDEN；后续初读返回 NOT_FOUND，消息/引用/completion 均无新增。初读后素材过期及 failed 状态返回 MEDIA_UNAVAILABLE，同样无部分落盘。先前已完成 pair 在源/素材后续失效后仍返回原结果。
- 最终专用 56440 PostgreSQL 上 `swift test --package-path IMV2Server --disable-automatic-resolution --disable-build-manifest-caching --jobs 4`，filter 为 `forwardedMediaUsesSourceReferences|persistsAuthorizedMediaReferencesWithMessageAcceptance|moderatorRedactionIsDurableAndExplicit|forwardChecksEditedVersionAudience|contentAudienceMigrationRejectsDuplicateVersions|forwardSourceRevisionFencesABAAndRetry|forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|V2GatewayDomainCommandHandlerTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction`：**64 tests / 3 suites 通过**，退出 0；日志 `/private/tmp/im-remediation-forward-media-final.log`。同时覆盖实际 upload/scan/owner media 接受与 moderator redaction 既有链路。本批未改变 Core/ClientKit/App 或 schema 9/协议 22。
- 全部 47 项状态仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。B04 仍需跨 owner 源定位、export/inbox、媒体导入和迁移。已确认 wire/客户端 plan 只有源 message ID，而现有 owner router 需要 room ID；下一步必须补可验证的源定位，不能遍历全部 owner 或默认为 control DB。未提交、部署或修改开发者现有数据库。

## B04 第五批：转发父计划的完成状态

- 沿 App→durable plan→wire 检查跨 owner 源定位时，确认了独立的完成展示问题：`V2OutboxMessageForwarder.forward` 把一次 `flushOnce` 的单块 ACK 当作整项用户操作完成。App 可选 100 条源消息，而生产 chunk 只有 20 条；此外一次 flush 可能处理其他旧计划。首块终止失败时，其余块仍活跃，却向 UI 报整项 rejected，也可能诱发重新提交。
- 改为 enqueue 后进行一次有界 flush，再按原计划 ID 读取持久父计划：active 返回 queued；completed 返回持久累计 succeeded/failed；cancelled 返回明确 CANCELLED；父计划不存在视为本地一致性错误。完成判断不再来自本次 flush 的 chunk results。正常 queued 与断线重试共用“转发任务已保存，剩余消息会继续处理。”，不再让在线待处理计划依赖“连接恢复”。
- 新增 `IMApp/IMAppTests/V2MessageForwardingTests.swift`，使用真实 GRDB、本地 bulk outbox 与生产 App forwarder。覆盖 100 源×2 目标首块后 active/20/200、真实 close/reopen 后 9 个剩余块完成且 200 个源/目标组合唯一、完成计划再次读取不重发；首块 terminal rejection 后仍排队；最终块返回先前累计部分失败；单块部分/全失败；旧计划先被 flush；retryable pending 不增加完成数；cancelled 不伪装 queued；生产详情 Store 提示、关闭选择与父计划状态。
- iPhone 17 / iOS 26.2 `xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' -disableAutomaticPackageResolution -collect-test-diagnostics never -only-testing:IMAppTests/V2MessageForwardingTests CODE_SIGNING_ALLOWED=NO`：**8 tests / 1 suite 通过**，退出 0。日志 `/private/tmp/im-remediation-forward-plan-outcome.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_19-57-56-+0800.xcresult`。首次编译发现测试模块可见性、时间线夹具构造和宏推导问题，修正后完整重跑该 suite。编译全部 App/test target，但未宣称本批重新执行全部 App tests 或真机测试。
- 本批未改变 Core、ClientKit、服务端、schema 9 或 protocol 22；未启动/修改数据库服务。源房间/选中版本在 wire 与 durable queue 的演进尚未实施，不能据此声称跨 owner forwarding 已支持。跨 owner export/inbox、媒体导入与迁移仍需继续；后台长期任务的最终结果展示也不能由一次首块回执代替。
- 47 项总状态仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**；B04 保持实施中。

## B04 第六批：源房间与选中版本贯穿 App、队列和协议

- 本批继续跨 owner 所需的真实源定位，未用默认数据库或遍历 owner 代替。新增 Core `V2ForwardMessageReference(roomID,messageID,revision)`，移除只传源 ID 的命令构造与 outbox enqueue；只保留 sourceMessageIDs 计算属性用于结果匹配。版本 JSON 解码经有界类型校验，重复 message ID 的不同房间/版本声明拒绝。
- App 在勾选时捕获引用，发送时按原序号排序；编辑、撤回或翻窗不能静默替换版本或丢失已选来源。真实生产详情 Store 测试覆盖勾选后 revision 3→5，以及消息离开可见窗口时提交仍为原版本。
- wire 新 sources 字段 4，旧字段 2/名字保留，protocol 升为 23；两端生成物同步，当前协议文档及生成物 gate 通过。网关在存储前拒绝缺失上下文、空房间、零/越界版本及重复消息身份。
- SQLite 新迁移 bindForwardSourceReferences 为三类队列表保存完整引用，parent 保存 terminal_code；懒分块和 reopen 保留混合源房间与版本。旧队列缺选中版本，不从当前投影猜测：未完成项持久标 SOURCE_RESELECTION_REQUIRED，原成功计数/完成摘要不变，旧已完成 chunk 的同摘要确认仍是 no-op。客户端最终 schema 162 objects / fingerprint `0x7dde34bc1f47db8e`；新增字段与迁移已核对。后台升级提示/最终计划展示仍需接入，未声称数据库终态等于用户已看到提示。
- 服务初读按 message+声明房间匹配并比较选中版本；已经通过内容受众授权但版本变化返回 SOURCE_CHANGED。pair 分配与重放都比较持久源房间/版本，改参返回 IDEMPOTENCY_CONFLICT；正确已完成引用不受源后来修改影响。新增 source_room_id、不可变身份字段和 schema 9→10 迁移，已有 FK 可回填房间，未知旧版本不回填。Swift/SQL gate 验证源房间字段，测试新增缺列拒绝。
- Core 全量 **78 tests / 23 suites**：`/private/tmp/im-remediation-forward-source-core.log`；ClientKit 全量 **293 tests / 51 suites**：`/private/tmp/im-remediation-forward-source-client-final.log`。均退出 0。初轮客户端实际测试仅 schema 指纹预期变化失败；核对字段后更新并完整重跑通过。测试编译阶段的夹具可见性/Swift Testing 抛错表达式问题已修正，不计为通过证据。
- iPhone 17 / iOS 26.2 App 全量单元 **170 tests / 17 suites**：`/private/tmp/im-remediation-forward-source-app.log`，退出 0；xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_20-20-12-+0800.xcresult`。本批没有运行 4 项启动 UI 测试或真机验收。
- 专用 56440 PostgreSQL 最终服务端 **75 tests / 4 suites**，退出 0；`/private/tmp/im-remediation-forward-source-server-final.log`。filter 为 `forwardedMediaUsesSourceReferences|persistsAuthorizedMediaReferencesWithMessageAcceptance|moderatorRedactionIsDurableAndExplicit|forwardChecksEditedVersionAudience|contentAudienceMigrationRejectsDuplicateVersions|forwardSourceRevisionFencesABAAndRetry|forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|V2GatewayDomainCommandHandlerTests|V2GatewaySessionTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction`。包含既有 7→8→9→10 迁移链、改源房间/版本、ABA、房间错配、不可变 trigger、八类门禁与完成/媒体回归；未测试跨 owner 导入或迁移。
- `scripts/check_v2_protobuf_generated.sh`（使用仓库已锁定 protoc-gen-swift）与协议文档 gate 通过，日志 `/private/tmp/im-remediation-forward-source-protobuf.log`；git diff --check 通过。部署须停旧 writer 后从实际 schema 起点迁移至 10，再启动协议 23 的匹配服务/客户端；未部署或操作用户现有数据库。
- 总目标仍为全部 47 项，状态保持 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。B04 仍缺实际 owner 路由与 export/inbox/媒体导入/迁移；启动装配尚是固定 database。本批为这些路径提供可验证且持久的输入，不能据此关闭跨 owner 转发。

## B04 第七批：真实 owner 路由与跨层分块身份

- 确认 main 原转发服务固定 control DB，未复用已经按 owner 配置的 room write store。新增公开 V2ForwardMessagesHandling 边界与 V2RoutedForwardMessagesService，main 为每个 owner 使用对应数据库及既有写入 store；同库拓扑继续保留原事务，避免新建额外 command-credit actor。
- 多物理位置一次有界目录查询；单个房间缺失时只做请求集合内的目录点查，保留其他 pair。目录故障、unknown owner 或 owner store 失败不回退到 control/其他数据库。按配置物理键处理共库的不同逻辑 owner；每目标按源顺序处理，目标并发默认 4，结果仍按 source×target 原序归并。跨物理位置暂时明确 CROSS_OWNER_FORWARD_UNAVAILABLE；没有实现或冒充 export 成功，不据此关闭 B04。
- 在专用实例 localhost:56440 新建空的 `im_remediation_owner2` 测试数据库，原 `im_remediation` 作 primary。真实两个数据库中分别创建、发送、转发，只在 owner B 存在的消息可在 B 内转发；两方向跨库组合拒绝且各库仅保留自己的两条消息、一个 forward operation 和两个 completion。源 B 撤回后复用相同操作返回原结果。单实例双库证明独立数据库事务/存储选择，不替代独立主机故障或网络分区验收。
- 路由测试覆盖混合 source/target 顺序、连续同库片段、目标并发上限、全部共库时绕过目录故障、多个逻辑 owner 共用第二个物理库、一个未知房间、配置缺失、目录/owner 故障时无 fallback。原房间 seed helper 增加显式 room/shard 参数，默认值不变；最终回归覆盖共享夹具的消息、媒体与 schema 路径。
- 新发现并修复实际 App 转发阻断：bulk chunk ID 原为 parentUUID-findex，服务端 UUID 解析拒绝，既有假传输未暴露。新增 Core V2ForwardChunkIdentity 生成稳定 UUID，SQLite 新建分块使用它；序号仍由 parent.next_chunk_index 决定。独立 Python SHA-256/struct 黄金值与 Core 80 项测试核对，客户端 wire 夹具现在也拒绝非 UUID，实际 PostgreSQL 转发使用同一黄金值接受并完成重放。
- 新 SQLite 迁移 useUUIDForwardChunkIdentities 只修改精确旧格式的 pending 行，保留已有有效 UUID、terminal 行、源引用、attempt/deadline 与已完成计数；意外 opaque 身份要求重选而不擅自改写。迁移/close/reopen 测试覆盖旧 pending、旧 completed、另一个已有效 UUID pending 与异常身份；终态摘要仍可重复确认，下一块真实发送不会重复累计。物理 schema 仍为 162 objects / fingerprint 0x7dde34bc1f47db8e；迁移 ledger 新增一项。
- 最终 Core 全量 **80 tests / 24 suites**，`/private/tmp/im-remediation-forward-chunk-uuid-core.log`；客户端全量 **294 tests / 52 suites**，`/private/tmp/im-remediation-forward-chunk-uuid-client-final.log`。均退出 0。新测试初次编译的 Swift Testing 抛错闭包推导已修正并重跑，未把编译失败当作执行证据。
- App 全量单元 **170 tests / 17 suites**，退出 0，`/private/tmp/im-remediation-forward-owner-app.log`；xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_20-57-58-+0800.xcresult`。100×2 计划测试明确断言实际分块输出全部为 UUID。未重跑启动 UI tests 或真机。
- 最终服务端 **82 tests / 5 suites**，退出 0，`/private/tmp/im-remediation-forward-chunk-uuid-server.log`。环境为两条专用 DB URL + disposable=1，filter 为 `V2RoutedForwardMessagesServiceTests|forwardUsesPhysicalOwnerDatabases|forwardedMediaUsesSourceReferences|persistsAuthorizedMediaReferencesWithMessageAcceptance|moderatorRedactionIsDurableAndExplicit|forwardChecksEditedVersionAudience|contentAudienceMigrationRejectsDuplicateVersions|forwardSourceRevisionFencesABAAndRetry|forwardRequiresHistoricalAndCurrentMembership|oppositeForwardsUseCanonicalRoomLocks|multiForwardUsesBoundedTargetLanesAndStableResultOrder|sendCompletionIsIndependentOfMutableContent|sendCompletionSchemaReadinessRejectsIncompleteContract|V2GatewayDomainCommandHandlerTests|V2GatewaySessionTests|V2SendMessageServiceTests|editsRespectCurrentContentWriteAuthorization|withdrawalWritesTombstoneTransaction`。初轮路由 35 项及扩展路由 82 项也通过；最终日志另含 UUID 的真实服务端验证。
- git diff --check 与当前协议文档 gate 通过。protocol 23 / schema 10 未变；未部署或修改用户原有数据库。全部 47 项仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。下一步继续实现 source owner 的持久 export 与 target inbox、媒体导入和 owner 迁移；显式拒绝仅是当前能力边界，不能作为完整跨 owner 支持的替代完成条件。


### B04：源端持久 export、owner epoch 与媒体保留

- 新增 `PostgresV2ForwardExportStore`：单个源 owner 事务内锁 pair 和源房间，复用历史/当前/编辑版本受众谓词，核对精确版本、未撤回正文、实体和全部附件；按 UUID 锁素材并校验可用状态。无 target RPC，也不把 export 当目标消息成功。
- schema 11 增加 `message_forward_exports` 与源房间 `owner_epoch`。export 保存固定目标 client UUID、原始 payload 字节及 SHA-256、actor/source/target/operation/两端 epoch 和有序媒体 manifest；UPDATE/DELETE 被拒绝。同 pair 精确引用重放返回原字节，之后编辑/撤回/退群/epoch 改变不重新授权，改源房间或版本拒绝。新 export 检查源本地 epoch；同库目录非零 epoch 迁移回填验证通过。摘要绑定 manifest 元数据，不替代实际文件字节校验或服务身份认证。
- 每房间默认最多 1,024 份 export；成功重放不重复占位。媒体 retention 用索引排除已 export 的素材，并先锁定有限候选、再在新 READ COMMITTED 语句中复核，避免旧快照漏 pin；无引用素材仍正常进入 purge outbox。目标终态回执和 pin 释放尚未实现，因此这一 primitive 尚未接入跨库线上装配，不能作为长期保留策略完成证据。
- 最终 Server **76 tests / 5 suites** 通过（exit 0）：`/private/tmp/im-remediation-forward-export-server-final.log`。新增两个参数化测试覆盖两种 delivery mode 的 16 个 store 并发重试（四连接池）、正文/实体/媒体顺序、失败无新增记录、配额、不可变 trigger、摘要损坏、不同连接池重读、编辑/撤回/退群后的重放、owner 变化、媒体保留和无引用清理，以及 export/withdraw 两种真实事务提交顺序。后到者被验证等待 PostgreSQL transaction ID 锁；初次单连接夹具发生连接等待超时，已修正为四连接，不将该失败当作业务验证。
- 扩展真实历史与编辑受众夹具到 source export；schema 7→11、8→11、10→11 与十二种启动合同故障回归通过。同物理 owner/双物理库路由、同库多跳媒体、普通媒体授权/清理、网关、会话和发送回归也通过。测试使用专用 PostgreSQL 56440 的 `im_remediation` 与 `im_remediation_owner2`，没有使用用户原有 5432 数据库。新批次未改 Core、ClientKit、App 或 wire，沿用上批对应证据，不宣称重跑这些套件。
- git diff --check 与当前协议文档 gate 通过。当前 **protocol 23 / schema 11**；未部署。B04 保持实施中，47 项状态仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。下一步接通持久目标 inbox/目标 admission 与源投递 worker，完成文件校验/导入、终态回执与 pin 释放、丢 ACK/崩溃恢复、owner 迁移。不能用目前明确拒绝跨物理库转发代替这些关闭条件。


### B04：目标持久 inbox、共享接受与提交后恢复

- 新增 `PostgresV2ForwardInboxStore` 和 `PostgresV2RoomWriteStore.importForwardExport`。receive 固定原始 payload/digest、pair、target client UUID，并按房间限制未完成数量；只接受 server-created export。已锁定 inbox 构造内部授权，普通发送不获得跨库源检查例外。新目标接受保留普通写入的当前身份/权限/准入检查与部署配置。
- schema 12 引入 pending → accepted → completed / pending → rejected。目标 message、send completion、日志/准入与 accepted 同事务提交，完成原有提交后工作才返回成功。事务内故障回滚全部目标写入；提交后故障保留 accepted，下一次由原不可变完成记录恢复，不重发，不重复用户投影。completed/rejected 身份与结果不可变。
- 真实双库测试揭示旧消息来源外键要求 source 也在 target DB 中，已从 canonical schema 与 11→12 迁移移除，由源授权/inbox 替代。启动 gate 拒绝残留该外键（含改名）、缺列、禁用 trigger、缺媒体约束或唯一索引。Swift gate 通过但 SQL gate 一度漏掉外键检查，新增反例使该差异暴露，已修正；两种 gate 的 17 个场景最终通过。
- inbox media 持久固定 source ID/顺序，ready 需要不同的 target object ID 和对象摘要；接受复用目标素材 owner/可用性检查并核对 manifest 类型/大小。没有文件 importer 时保持 media pending，零目标消息/素材冒充。retention 增加未完成目标 inbox 素材保护。实际文件传输、摘要验证和扫描仍未实现，不把结构约束当作文件证据。
- 最终 Server **78 tests / 5 suites** 通过（exit 0），日志 `/private/tmp/im-remediation-forward-inbox-server-final.log`。新测试覆盖普通群/Hybrid 两种模式的 16 个独立 store 并发导入，原子回滚、完成标记失败、源撤回后导入、目标副本撤回/退群/epoch 变化/限制缩小后的恢复、不同 envelope 冲突和普通 attribution 拒绝；八个目标边界（移除、禁言、冻结、角色权限、账号 inactive、epoch、准入、媒体）；三种私聊投递配置的真实 shadow adapter 故障恢复。room-log 的 fanout plan/delivery 仍为零，恢复未重复用户投影。
- 相邻源 export/撤回提交顺序、历史/编辑受众、同库多跳媒体、媒体授权/清理、迁移 7→12/8→12/10→12、路由、网关、会话和普通发送回归通过。使用专用 56440 的两个物理数据库，未访问用户原有 5432 库。Core、ClientKit、App 和 wire 未修改，未重跑其上批测试。git diff --check 与协议文档 gate 通过；当前 **protocol 23 / schema 12**，未部署。
- 47 项仍为 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。下一步直接完成实际媒体复制/校验/扫描与 ready 提交、源回执/pin 释放和持久投递 worker 启动装配，再做跨库重试/崩溃/迁移组合。B04 继续实施中，不以保持 CROSS_OWNER_FORWARD_UNAVAILABLE 替代完整支持；终态 envelope 保留/擦除与全局内容封禁清理也仍开放。


- 2026-09-05 后续批：继续 B04，恢复本机验证环境并实现 schema 14 源端终态回执。上一轮媒体导入日志已不可用，本轮重新运行当前代码，而没有沿用无法核实的终态。专用 PostgreSQL 16.13 位于 `/private/tmp/im-remediation-receipts-pg`，仅使用回环 56440 的 `im_remediation` / `im_remediation_owner2` 两个临时数据库。
- 新增 `V2ForwardTerminalReceipt` 和 `PostgresV2ForwardReceiptStore`；目标只从不可变 completed/rejected inbox 生成回执，未完成后处理的 accepted 无终态回执。源端核对原 envelope 与 digest，在源房间锁内检查 epoch 并幂等写入。重复相同结果不修改记录，不同结果/内容拒绝，回执插入回滚不释放额度。已经保存的终态可在后续 epoch 变化后继续恢复。
- 源导出配额和媒体 retention 改为只计没有终态回执的导出。源媒体被多份导出引用时，必须全部终态才能解除这类 pin；随后仍检查普通消息引用和撤回保留期。目标独立文件/引用保持自身生命周期。新建表、13→14 迁移及 Swift/SQL 启动门禁同步，新增四个门禁故障 fixture，迁移链 7/8/10→14 随回归验证。
- 首轮定向测试 `forwardTerminalReceiptRecovery|forwardMediaImportBytesAndRecovery|forwardInbox|forwardExport|sendCompletionSchemaReadinessRejectsIncompleteContract`：8 tests / 1 suite 通过，日志 `/private/tmp/im-remediation-receipts-server.log`。包括 13 种真实文件导入场景、4 种源回执场景、24 种门禁故障；并发回执使用 16 个 store 调用，测试包含插入失败回滚、丢源 ACK、quota 释放/再占用、冲突结果/内容与旧 owner 拒绝。
- 相邻发送/网关/媒体/转发/迁移回归：89 tests / 8 suites 通过，日志 `/private/tmp/im-remediation-receipts-server-final.log`。本轮重新验证 owner-fence、two-files、扫描重试、copy ACK 丢失、lease 接管、并发文件安装、取消及 EICAR/冲突/大小失败。生产代码此后未变；另加真实 purge worker 的文件级验收，最终结果见下条。
- B04 仍实施中：投递 worker 与 runtime 路由装配、跨 owner pending 反馈、终态 envelope 正文保留/擦除、全局封禁及 owner 迁移仍未闭环。router 仍明确拒绝跨物理库请求，不能把当前组件回归当作完整 App 功能验收。47 项状态计数保持 10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始。

- 文件级追加验收终态通过：2 tests / 1 suite（13 种媒体场景与 4 种回执场景），日志 `/private/tmp/im-remediation-receipts-file-purge.log`。真实 PostgreSQL purge worker + 本地 provider 删除全部源文件，逐附件请求下载返回 objectUnavailable；目标副本仍可读，重复 purge 不再领取工作。此处验证了实际文件删除，区别于仅生成清理 outbox。
- 本批三次完整日志与最终生产/测试文件 SHA-256 已保存到 [持久证据目录](../../../docs/reviews/verification-records.md#20260905-forward-receipts)，避免临时目录被清理后只剩测试数量描述。`git diff --check`、schema readiness relation coverage 与协议文档门禁均通过。没有提交或部署，完整 47 项目标继续保持开放。
- 收尾：两座专用测试库的 im_v2 schema 均已清理（查询均为 true），本轮临时 PostgreSQL 已正常停止。全部测试会话均已有退出码 0；未触碰其他数据库或其他编译任务。


- 2026-09-05 后续批：继续 B04 持久投递。开始时逐文件核对上一轮 receipt 证据 manifest，生产/测试文件无漂移。新增 `PostgresV2ForwardDeliveryStore`、`V2ForwardDeliveryWorker`、`V2ForwardImportEndpoint` 与精确目标 shard registry。export 和 delivery job 同源事务入队，目标适配器复用原配置 write store，包括准入、shadow 与后处理恢复。
- schema 15 引入 delivery job 租约/到期/重试/终态，14→15 回填无源回执的旧 export；不是重授权或重建 target UUID。领取使用有界 SKIP LOCKED 与 source owner epoch 条件；相同终态回执后可直接补完 job，不重复目标 I/O；无回执不能完成。暂时 pending 延期而不累积失败次数，传输错误退避，耗尽 paused 保留 pin/配额。重试计数饱和到 Int64.max，仍能领取后暂停/完成，不溢出或永久隐身。
- 首轮定向回归的 12 种非迁移投递场景及 28 种门禁场景通过，迁移夹具失败：整份 SQL 被作为单条 prepared statement 提交，PG 返回 cannot insert multiple commands。改为仓库现有 `postgresStatements` + 同事务逐语句执行；没有修改迁移预期或放宽断言。
- 修正后扩大回归：90 tests / 8 suites 通过，日志 `/private/tmp/im-remediation-delivery-server-final.log`；15 种投递场景包含文本/真实双附件、目标 ACK 丢失、源 receipt 后 job completion 丢失、租约接管、16 个 worker 并发领取、取消、12 轮正常 pending、暂停、源/目标 owner 栅栏、入队回滚、14→15 旧导出回填、2/2/1 有界批次和最大计数恢复。
- 追加目标调用期限与取消排空：默认 deadline 为租约的 80%，小于租约期限以留出重试提交时间；计时器和目标调用都在结构化 task group 内。适配器需传播取消并限制底层 I/O；未把非协作驱动的硬时限宣称为本轮已解决。另补 delivery export FK 缺失的 Swift/SQL gate fixture。最终回归已通过，详细终态见下条。
- B04 仍开放：Gateway/runtime 接线、跨 owner pending 的 wire 映射、暂停任务的 operator 审计恢复、owner 迁移及终态 envelope 清理尚未完成。完整 47 项状态计数保持不变，不把 worker 组件测试当成跨库 App 功能验收。

- 最终 schema 15 回归：90 tests / 8 suites，通过日志 `/private/tmp/im-remediation-delivery-deadline-final.log`。投递 worker 的 16 种场景和 29 种 schema gate 故障全部通过；超时夹具确认目标 await 已取消且 drained，源任务随后退避重试并接受一次，未留下游离调用。包含前几批真实媒体复制、source pin/实际 purge、inbox 后处理恢复与源受众/版本/迁移回归。
- 首轮夹具失败日志、修正后的中间成功日志、最终成功日志及最终相关源码 SHA-256 均保存到 [投递 worker 持久证据](../../../docs/reviews/verification-records.md#20260905-forward-delivery)。schema readiness relation coverage、协议文档门禁和 `git diff --check` 通过。未改 App/ClientKit/wire 合同，也未提交或部署；完整 47 项目标继续开放。
- 本轮收尾：最终测试进程退出码 0，两座专用库的测试 schema 已清理；临时 PostgreSQL 正常停止。未改变其他数据库/编译任务。下一步接通 runtime/Gateway 与暂停任务恢复，47 项计数保持 10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始。


## 2026-09-06：B04 Gateway 入队、投递运行时与持久暂停恢复

- Gateway 已实际装配 `V2CrossOwnerForwardService` 与 `V2ForwardDeliveryRuntime`。前台只提交源 export/job 和读取不可变回执；目标 I/O 在独立后台执行。同库/跨库混合请求先处理所有配对，任何 pending 都不提前取消其他目标入队。整体 `FORWARD_PENDING` 可重试、1 秒，`FORWARD_PAUSED` 可重试、30 秒，未发送部分成功的终态包。
- 目标复用原配置 room write store，值拷贝仅替换为同物理 owner 的 delivery workload pool；原 policy/cache/credit/shadow 依赖保留。每 source shard 独立结构化循环，单批最多 4 个任务，空闲/忙循环有界；Gateway 退出取消并排空后再关闭数据库。缺少目标配置直接失败，不静默跳过。
- 本地 Compose 为 Gateway 与 Account 明确共享测试媒体根目录、配置密钥来源与 volume。Gateway 不执行 provider.prepare，避免其启动清理 Account 上传 staging。未启动或部署该 Compose；生产 provider/scanner 与 Account 重启 staging 所有权仍需单独处理。
- 真实 room directory、router、源服务、目标端点、数据库与 runtime 的双库测试覆盖 standardFanout / largeGroupHybrid：运行中入队、停止期间积压、重启恢复、相同操作不重复、源撤回后的原结果重放及修改源版本的幂等冲突。运行中的 worker 可能在前台读回执前完成，因此测试允许合法的立即完成或 pending，最终用持久回执和消息数量验证结果。停止期间则严格断言 pending 和目标无新增。
- 复核发现并修复目标已暂停但响应丢失的恢复漏洞：旧 `claim == nil` 把持久 paused 当作 idle，使新源 worker 一直延期。现在在无 claim 时查询该 export 的持久暂停状态，并保持源 delivery paused。新故障用例先用真实文件复制与失败扫描提交 paused，再换新 media worker / endpoint / source worker，验证 paused 被恢复、源无回执、目标无消息且之后不再领取。没有释放源 pin 或伪造完成。
- 回归日志依次为：51 tests / 3 suites；扩大 71 tests / 7 suites；最终 **95 tests / 8 suites**，含 17 种投递场景、29 种 schema gate 故障和两种真实运行时模式。配置另用同一编译制品 `--skip-build` 跑 **37 tests / 2 suites**。四次测试会话均退出 0，完整日志及 29 份源码/配置 SHA-256 保存于 [运行时持久证据](../../../docs/reviews/verification-records.md#20260906-forward-runtime)。
- 服务端主回归命令：两条专用 PostgreSQL URL 与 disposable=1，`swift test --disable-build-manifest-caching --disable-automatic-resolution --jobs 4 --filter 'V2RoutedForwardMessagesServiceTests|V2GatewayDomainCommandHandlerTests|V2GatewaySessionTests|V2LocalFilesystemMediaProviderTests|V2MediaScanWorkerTests|V2MediaPurgeWorkerTests|V2SendMessageServiceTests|PostgresV2RoomWriteStoreIntegrationTests/(forward|sendCompletionSchemaReadiness)'`。schema relation coverage、协议文档门禁、本地环境 contract 和 `git diff --check` 均通过。schema 15 / protocol 23 未变；未提交或部署。
- B04 仍开放，新增确认 Account HTTP 的 media grant/session 服务固定控制库，无法为第二 owner 的媒体元数据提供完整下载链路。尚需媒体 HTTP owner 路由、operator 审计重放 paused delivery/media import、owner 迁移及终态 envelope 清理/全局内容封禁。没有把组件运行时测试称为真实 TLS Gateway/App 端到端验收；本轮未重跑 App、ClientKit、Linux 或负载。
- 完整 47 项状态保持 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。两座专用测试库的 im_v2 schema 已确认不存在，临时 PostgreSQL 正常停止；不影响用户其他数据库、App 构建或未提交改动。


## 2026-09-06：B04 暂停任务的 owner 定位与原子审计恢复

- 开始时逐项核对上一轮运行时 manifest，生产/测试文件没有漂移。新增 `V2ForwardWorkOperatorReplayService`、具体 PostgreSQL store 和独立 operator HTTP 路由；明确 shard + export，媒体再指定 ordinal。复用现有 operator replay bearer 与服务配置 principal，不开放普通账户权限，不输入数据库 URL，也不扫描或回退其他 owner。
- Operator 从显式 `IM_V2_ROOM_SHARD_STORES_JSON` 装配 owner store，启动校验每库 schema/session，连接预算包括控制、user 和 room store 的去重物理库。未配置 room registry 时没有 forward owner；本地 Compose 明确配置 rooms-primary，并已解析验证 YAML。独立 main 编译通过，未启动或部署 operator 进程。
- schema **16** 增加不可变 `forward_work_replay_audit`。15→16 创建审计表和 trigger，原任务/export/媒体 ID 不变；更早转发迁移链测试延伸至 16。Swift/SQL 门禁要求审计字段及非空、PK、启用的正确 trigger 和精确目标 CHECK，弱化成 CHECK(true) 也被拒绝。protocol 保持 23。
- 审计与单行 paused→pending、重置重试预算同 owner 事务提交；注入审计更新失败后，无审计且任务仍 paused。新操作检查房间锁内当前 owner/epoch；媒体按 inbox→room→job 取锁，已终态 inbox 不重启媒体。重放同一已审计操作先返回原结果，改 reason/目标返回冲突；保持原媒体 UUID/upload UUID、copied digest、扫描和普通写入授权。
- 双库分别测试源 delivery 与目标 media：16 个相同 operationID 并发仅产生一条审计，8 个不同 operationID 同时恢复同一任务恰好一项 requeued、七项 not_paused；未知/错误 owner、epoch 改变、旧 lease 写回、原审计结果跨 owner 状态变化重放、审计终态改写/删除拒绝均验证。源无伪造回执、目标无额外消息。
- 真实文件场景先让扫描失败持久暂停、丢失响应，再通过目标 media 和源 delivery 的独立审计操作恢复。两份附件实际复制/扫描后仅生成一条消息与一份源回执，重复恢复返回原结果，目标文件逐个读回验证。追加恢复后禁言，目标按当前权限记录 ACTOR_MUTED，源下一轮取得拒绝回执，不生成消息。
- 首轮 **22 tests / 3 suites** 通过。扩展回归初次 **104 tests / 11 suites** 有两个新增断言失败：禁言用例错误要求“媒体 worker 提交拒绝”和“源取得终态回执”在同一 pass 完成。检查实际协议后，测试明确第一轮延期但目标已持久拒绝、源尚无回执，第二轮恢复拒绝终态；没有削弱无消息和最终拒绝断言，也未为测试修改生产调度语义。
- 修正后最终 **104 tests / 11 suites** 全通过，包含 18 种投递场景和 34 种 schema gate 故障。完整初次成功、扩展失败与最终成功日志，以及最终 37 份相关源码/配置 SHA-256 保存到 [operator 恢复持久证据](../../../docs/reviews/verification-records.md#20260906-forward-operator)。测试使用专用端口 56440 双数据库及 disposable=1；主命令沿用 `swift test --disable-build-manifest-caching --disable-automatic-resolution --jobs 4`，filter 含 forward、sendCompletionSchemaReadiness、durableWorkRetryPauseAndReplay、operator config/HTTP、Gateway、普通写入和媒体组件。
- schema relation coverage、协议文档门禁、本地环境 contract、Compose YAML 和 `git diff --check` 通过。两个专用测试库的 schema 已确认不存在，临时 PostgreSQL 已正常停止；所有测试会话均记录终态。未提交、部署、重跑 App/ClientKit/Linux 或做负载验收。
- 恢复步骤与错误处理见 [转发暂停恢复操作合同](../forward-operator-replay.md)。B04 仍缺跨 owner 媒体 HTTP 路由、owner 迁移、终态 envelope 保留/清理与全局内容封禁；本地跨进程 staging 所有权与生产媒体 provider 仍开放。完整 47 项状态保持 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。


## 2026-09-06：B04 / E03 消息媒体下载的 owner 与授权路由

- 会话 Store→App downloader→ClientKit→HTTP 传递强类型 room/message 定位；头像保留无消息位置路径。Vapor 拒绝缺一项或非法 UUID，服务端仅从持久房间路由选择显式配置 owner。Account 装配 room/user 数据库，预算涵盖全部去重连接池，Compose 增加账户服务 registry。
- 新下载服务在控制库验证当前设备及有效账户，在 room owner 验证当前/历史/内容版本受众、媒体引用及 owner epoch。普通个人交付在当前 user store 检查有效投影及内容 revision；room log 根据不可变 send completion 授权，现有数据库拒绝模式修改，下载不能绕过个人投影要求。使用既有 user 路由栅栏和前后 owner 快照，房间锁先于消息/媒体锁，provider I/O 在事务外。
- grant 创建、claim 和 provider 返回后的消费均重新授权；签名等待期间撤回、撤销设备或关闭投影时不返回 URL，claim 释放。取消等待 provider 退出。新 schema **17** 持久完整消息/owner/epoch 范围，去掉本地 auth_devices FK，身份不可改写、consumed 不可重开；旧 store 不能 claim scoped grant。16→17 及已有迁移链、39 种 schema 门禁故障验证。
- 首轮服务端 29 tests / 4 suites 因新增夹具路由与 registry 不一致而失败；客户端 294 tests / 52 suites 中新增夹具使用非法 identifier 字符失败。修正夹具，并修正个人授权查询兼容 Swift 大写与 PostgreSQL 小写 UUID 文本后，第二轮服务端 **39 tests / 5 suites**、ClientKit **294 / 52**、Core **80 / 24** 全通过。
- App 在 iPhone 17 / iOS 26.2 模拟器完成构建与 **170 tests / 17 suites**。扩大回归的两个群模式夹具先因使用不存在的 rooms.group_delivery_mode 列而失败，修正列名后确认现有数据库 trigger 禁止模式变更；最终夹具断言准确的不可变错误，再检查原下载权限，没有禁用 trigger 或改动生产授权规则。最后服务端扩大回归：**Test run with 113 tests in 13 suites passed after 81.899 seconds.**。覆盖 15 个下载场景、群模式变更被拒绝、签名期间撤权与取消；实际跨 owner 两份附件完成导入后，经新 HTTP handler 取得目标并逐字节读回，个人投影夹具使用目标实际 accepted event payload；不把该夹具称为投影 worker 或真实网络端到端验收。
- 初次失败、后续成功及最终源码 SHA-256 见 [媒体路由持久证据](../../../docs/reviews/verification-records.md#20260906-scoped-media)。schema relation coverage、协议文档、本地环境 contract、Compose YAML 和 diff 检查通过。升级合同见 [转发源与媒体授权合同](../forward-source-authorization.md)。schema 17 尚未部署，protocol 23 未变。
- B04 仍实施中：owner 迁移、终态 envelope 清理及全局内容封禁未完成；E03 生产 provider/scanner、普通多 owner 上传分配、各 owner 清理与跨进程 staging 仍开放。未进行生产迁移、真实 TLS/App 服务链路、Linux 或负载验收。47 项状态保持 **10 已验证、8 实施中、3 已实现待验证、2 待外部验收、24 未开始**。

- 本轮所有测试会话已确认终态；专用端口 56440 的两个数据库均无 im_v2 测试 schema，PostgreSQL 已正常停止。28 份源码及 9 份日志校验值一致，完整主表为 47 个唯一问题 ID。


## 2026-09-06：B06 消息效果跨流去重与快照迁移

- 上一轮媒体验证的 28 份源码指纹无漂移；上一目标轮属于已验证进展。本轮继续完整问题表，处理消息 accepted/edit/withdraw/redact 从个人同步、前台预览、持久房间流重复到达而回滚的路径。
- 新增仅能由既有 wire decoder 生成的 `V2LocalMessageEffect`，按解析后的领域内容、规范 ID、默认字段计算 SHA-256。SQLite `v2_message_effects` 在账户绑定的数据库内以 sourceEventID/projectionKind/entityKey 保存 room、revision 和 32 字节摘要，不复制正文。效果记录、消息变更、FTS job 和本次流游标同一事务；重复 no-op，同身份异内容拒绝，失败没有残留 claim。
- 较新消息状态覆盖旧编辑；tombstone 已到时只消费早于撤回版本的编辑，不恢复正文。无基线且无 tombstone 或未来 revision 缺口仍报错，B03 的持久缺失依赖恢复尚未实现。单条个人流原有 sourceEventID 唯一约束保留，未允许同一事实在同一流占用任意新序号。
- `recordSharedMessageEffects` 从旧的已提交个人/room 事件逐行回填摘要。新表参与快照原子切换，只保留新基线同 room/message 且不超出其 revision 的效果记录。升级时若旧版快照正在暂存或已准备激活，补齐 shadow 表；已准备的快照同步筛选记录，避免升级后激活缺表。旧版没有持久事件的预览历史不能凭空补出完整原始事件证据，仍需恢复合同覆盖。
- 新测试覆盖四种入口/升级顺序、关闭重开、三个入口回放、JSON 格式等价、冲突不推进游标、不重发搜索任务、无基线失败后的重试、撤回先于编辑、快照后旧 accepted，以及暂存/已准备快照升级。主 SQLite schema 基线更新为 **163 个对象**，搜索库保持 **5 个**。
- 初始测试构造修正了 GroupEventPage 参数和 GRDB async 调用；随后修正 schema 指纹、同一个人流重复事件的非法夹具，以及刻意编辑后的快照预期正文。中间 **297**、**298** 项 ClientKit 测试先后通过。App 首轮暴露新内部表落入“未知投影→立即全局刷新”分支，导致普通消息计时器等待超时；把效果表列入内部元数据，并增加实际 SQLite observer 验证，没有改变 UI 合并策略。
- 最终 `swift test --disable-automatic-resolution --jobs 2`：**299 tests / 52 suites** 全通过。`xcodebuild test` 在 iPhone 17 / iOS 26.2、IMApp/Debug、only-testing:IMAppTests、关闭签名下：**170 tests / 17 suites** 全通过。失败与成功的 10 份日志、最终源码校验值见 [消息效果持久证据](../../../docs/reviews/verification-records.md#20260906-message-effects)。diff 与 protocol 文档门禁通过，所有测试会话终态已确认。
- PostgreSQL schema **17**、protocol **23** 未变，本轮未启动 PostgreSQL，也未部署、进行服务器/真实网络/Linux/负载验证。B06 进入实施中，reaction、置顶与其他投影的顺序/撤销处理、完整保留窗口与 replay generation fence 仍开放；B03 未关闭。全表状态为 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 reaction 顺序、移除快照与终态保护

- 上一轮消息效果证据的 9 份源码指纹无漂移，属于已验证进展。本轮沿原 47 项任务继续 reaction 的跨流顺序处理，同时修复服务端删除当前 removal 投影导致快照丢失版本的问题。
- `V2LocalReactionEffect` 强制解析正数、Int64 范围内的 payload room_sequence；房间入口额外要求与事件 envelope 序号一致，不使用个人流序号替代。领域 ID、actor、reaction、action 和房间版本生成规范摘要。SQLite 增加 `v2_reaction_versions` 与 `v2_reaction_effects`，保留最新 add/remove 状态和事件摘要，记录、可见表情及游标同一事务。
- 旧版本只消费其所在流，不覆盖更新状态；同源事件异内容或同房间版本异事件拒绝。remove 先于 add、readd 后收到旧 remove、关闭重开、负状态快照后的旧 add 均验证。消息已有 tombstone/withdrawn 标记时，新见到的迟到 reaction 也不会进入可见表。效果与版本表属于内部元数据，实际表情变更触发 UI 通知。退群清理同时清除消息/reaction 效果记录。
- 服务端投影 worker 依据 room_sequence 比较当前状态，较晚个人流序号不能覆盖较新房间事实；remove 保留为当前负投影，进入后续快照。已知消息已撤回时关闭 reaction 投影并忽略迟到事实。真实 PostgreSQL 测试走 send→reaction add→fanout→projection→remove→fanout→negative snapshot，再注入晚到旧 add，最后真实 withdrawal 后再次注入迟到 add，核对快照不会复活 reaction。
- SQLite `orderReactionEffects` 从已持久事件回填版本。旧版暂存快照已丢掉 reaction source version，升级保留 live bank/outbox/pending reset，但清空 staging 后从同一 snapshot 重新导入，不能直接激活无版本影子表；暂存中与已准备两种升级场景通过。新快照同步保留负状态及对应版本/摘要。主库 **165 个对象**、搜索库 **5 个对象**。
- 首轮 ClientKit 的两项失败为新增表后的 schema count/fingerprint，更新为实际结构后，最终 **302 tests / 52 suites** 通过；额外扩展撤回后首次收到迟到 reaction 的测试后再次全量通过。App 在 iPhone 17 / iOS 26.2、IMApp Debug、only-testing:IMAppTests、关闭签名下 **170 tests / 17 suites** 通过。服务端两轮均 **8 tests / 3 suites** 通过，使用专用 56440 PostgreSQL，覆盖实际 reaction pipeline 和选定 snapshot/service 回归；没有把它称为服务端全量测试。
- 6 份失败/成功日志、最终 9 份源码 SHA-256 保存到 [reaction 顺序证据](../../../docs/reviews/verification-records.md#20260906-reaction-effects)。使用 `swift test --disable-automatic-resolution --jobs 2` 跑 ClientKit；Server 使用 `--disable-build-manifest-caching --disable-automatic-resolution --jobs 4`，filter 为 reaction service、sync snapshot 及 PostgreSQL reaction/userProjection/snapshot/v3 匹配项。protocol 文档、schema relation coverage 和 diff 门禁通过。测试会话均已确认终态，临时 schema 清理并正常停止 PostgreSQL。
- PostgreSQL schema **17**、protocol **23** 未变，尚未部署；新服务端负投影行为需要一致版本的 worker。旧版本已删除/压缩的 reaction 移除历史不能由此次迁移凭空恢复，历史回填/代次恢复仍开放。B06 还需置顶等对象的统一版本处理和完整保留窗口；B03 缺基线及 delivery authority 合同未关闭。本轮未做 Linux、负载、真实 TLS/App 到服务器链路验收。全表状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。

## 2026-09-06：B06 群管理源版本与权限幂等

- 本轮开始前 reaction 批的 9 份源码指纹无漂移。检查置顶、公告、角色权限、成员角色发现源事件正文没有 `room_sequence`，客户端把个人同步 cursor 写进 room sequence。现于源提交的 room lock 事务中给新事件正文补上与事件列相同的源序号。
- 真实 PostgreSQL 用例覆盖四类命令、取消置顶、清空权限、重复操作、变更请求冲突及 stale revision，核对六个群控制事实的序号为 2 至 7。普通模式给三位收件人预设不同消费位置，检查 18 条分发记录解析共享 payload 后保留原事件；混合模式核对 room log 正文，并断言没有个人 outbox/投递。
- 首轮在两种模式均复现多个权限的相同请求被误判为幂等冲突，原因是 `jsonb::text` 与 JSONEncoder 的文本格式不同。现按解析后的权限集合比较，仍绑定 room/role/expectedRevision。首轮投递断言未解析 shared payload，第二轮仅剩混合模式误设个人 fanout 数量的测试问题；已按实际合同修正测试，没有改变分发模式。
- 最终 **9 tests / 3 suites** 通过，新群管理 test 含两个模式参数实例。使用 `swift test --disable-build-manifest-caching --disable-automatic-resolution --jobs 4`，filter 覆盖群管理、reaction service、sync snapshot 及选定 PostgreSQL reaction/userProjection/snapshot/v3 测试。三轮失败/成功日志和最终 9 份源文件 SHA-256 见 [群管理源事件证据](../../../docs/reviews/verification-records.md#20260906-group-source-versions)。所有会话已确认终态，专用 56440 数据库无测试 schema，PostgreSQL 正常停止；diff、协议文档、schema relation coverage 检查通过。
- 新增 [群管理效果合同](../group-control-effect-contract.md)。额外静态发现权限操作回执同时作为显式空策略标记，又会被 housekeeping 删除，过期后可能回退默认允许；尚未运行复现或修复。后续必须让当前策略与幂等回执保留解耦，并覆盖各消息写入优化路径。
- **B06 仍实施中**。本批未改客户端群管理 reducer、snapshot ordering、历史和旧 staging 迁移。仅新源事件增加字段，PostgreSQL 17 / protocol 23 / SQLite 165+5 对象不变，未部署。没有新跑 ClientKit、App、Linux、负载或真实 TLS 链路。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 当前群权限与回执保留解耦

- 上一目标轮属于已验证进展。本轮落实此前静态发现：`group_permission_operations` 会被真实 housekeeping 清理，不能作为当前空权限的唯一标记。新增 schema 18 的 `group_role_policies(room_id, role)`，每房间每角色至多一行，设置策略与权限替换、源事件、revision 和操作回执在同一 room lock 事务提交。
- 普通 resolver 与三处批量消息授权 SQL 改读当前策略，不再查回执作为授权依据。优化 SQL 同时检查已有非空权限行，避免无标记旧数据回退默认允许；回执继续按照原期限清理，不无界保留历史操作。
- 新增 schema 17 到 18 事务迁移，从源事件及保留回执验证完整 policy revision 历史，再回填角色标记。历史缺口、非法角色或重复 revision 对应多角色明确失败并回滚；不伪造默认权限。旧进程需停止后统一切换。角色 PK、FK、CHECK 和字段类型同时纳入 Swift readiness 与 SQL 门禁；缺约束的负向用例通过。
- 集成用例覆盖普通/混合两种模式：默认策略可发送，设置空成员策略和独立 admin 策略后拒绝，真实 housekeeping 删除两条回执后仍拒绝单条与预热后的批量发送；标记数仍为两行。模拟 schema 17、回执已清理的旧库，可由源历史恢复；缺口迁移回滚、成功回填、重复迁移拒绝、后续明确授权重新允许发送均通过。
- 初次编译因新 SQL 多行字符串缩进失败，修正后 **5 tests / 1 suite** 通过。扩大到批量路径、跨 owner inbox 权限和恢复、schema 7/8 迁移链、housekeeping、reaction 与 snapshot 后，最终 **20 tests / 3 suites** 通过。三份日志及十份最终源文件指纹见 [权限保留证据](../../../docs/reviews/verification-records.md#20260906-group-policy-retention)。使用专用 56440 的 primary/owner2 数据库和 `swift test --disable-build-manifest-caching --disable-automatic-resolution --jobs 4`；详细 filter 保存在 manifest。
- 所有测试会话已确认终态；两个数据库均无测试 schema，PostgreSQL 正常停止。diff、协议文档和 schema relation coverage 检查通过。迁移发布与回退限制见 [权限保留合同](../group-policy-retention.md)。没有部署、Linux/负载/真实 TLS 验收，本批未新跑 ClientKit/App；protocol 23、SQLite 165+5 对象未改。
- B06 仍需客户端群控制 reducer、快照负状态与版本、历史和 staging 迁移；其余 47 项范围不变。状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 公告与角色权限的服务端快照顺序

- 上一轮属于已验证进展。本轮推进客户端恢复的服务端前置合同：公告和权限的旧 payload 已有独立 revision，可兼容地修正权威快照，无需把缺失的 source room sequence 伪造成个人 cursor。
- 新增 `V2GroupPolicySnapshotEffect`，校验 UUID、正 revision、权限集合和公告字节上限。权限顺序无关；拒绝重复/未知权限、owner 策略、布尔/溢出 revision、非法源序号。相同旧事实可以补充后来引入的 room sequence；两份都明确携带该字段时必须相同。
- `PostgresV2UserProjectionWorker` 分别按 room 公告和 room/role 权限比较 revision。旧版本不覆盖当前状态，同版本异来源或异事实失败并回滚本次 checkpoint；空权限、空公告 replacement 保留版本。大小写 UUID 快照键不创建第二个对象；未改允许提交空公告的用户命令。
- PostgreSQL 用例用真实命令生成两版公告、成员权限从非空到空及独立 admin 权限，按源序号倒序 plan/deliver/project。随后注入不带 source room sequence 的空公告、迟到旧公告与旧权限，验证三个对象不退回；同版本冲突失败且 checkpoint 保持 8。覆盖已有小写 UUID key 的继续更新。
- 首轮编译发现测试辅助解析方法为 private；调整后第二轮因手工追加日志未同步分配个人流高水位，worker 未消费迟到夹具，产生 5 个断言失败。修正夹具的序号分配，并未改变生产调度合同。最终 **24 tests / 4 suites** 通过，包含策略边界、真实快照、原有权限 GC、批量发送、跨 owner inbox、迁移链、reaction 和 snapshot 回归。三份日志与十份最终源码指纹见 [策略快照证据](../../../docs/reviews/verification-records.md#20260906-group-policy-snapshots)。
- 所有测试会话已确认终态，专用 56440 的两个数据库均无测试 schema，PostgreSQL 已停止。diff、协议文档、schema relation coverage 检查通过。PostgreSQL 18 / protocol 23 / SQLite 165+5 未改，未部署；本批未新跑 ClientKit/App/Linux/负载/真实 TLS。
- 继续保留完整 B06 范围：客户端 reducer、旧本地完整基线恢复、置顶源历史、成员移除/角色版本和全局保留/代次边界未完成。代码复核确认 token 缺失只会从服务端设备 ACK 继续，不能将清 token 当成完整快照请求；该前置条件已写入群控制合同。47 项状态仍为 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。

## 2026-09-06：B06 显式个人快照重建

- protocol 从 23 升至 **24**，SyncPull 增加 require_snapshot。ClientKit wire、已认证 gateway、SyncService、当前 user owner 路由和 PostgreSQL store 已接通；生成物使用仓库 protoc 脚本生成并通过重生成比较。
- SQLite 新增 v2_sync_rebuild_requests，recordSnapshotRebuildIntent 为追加迁移，只创建持久意图表，不自动重建。requestSnapshotRebuild 幂等，保留 live bank/cursor/outbox，响应丢失、进程重启和取消 reset 不清除意图。请求期间普通 batch 不能提交；快照 ACK 后原子切换时清除。普通代次仍须相邻，仅显式恢复允许服务器高于旧本地库多代。内部表排除全量 UI 通知。主 schema **166**、搜索 **5**。
- 服务端复用既有 reset stager/builder/capability 流程，待处理请求复用相同 snapshot/generation；显式重建不校验旧 token，基线下限为 max(retention floor, device ACK)，已确认游标仍在窗口内也会重建。空账户按无非零个人序列的条件补零 checkpoint。PostgreSQL schema **18** 不变。
- 新客户端测试覆盖旧库迁移、重启、丢响应、跨代恢复、取消、导入/激活、outbox 不丢失和 wire 编码。真实 SQL 测试覆盖非空/空账户、普通缺 token 续拉对照、preparing/pending 复用、发布、重复 ACK、新代次继续及撤销设备；gateway 与 routed store 验证标志、认证身份和 owner 转发。
- ClientKit 初始编译失败为测试把 UInt32 envelope protocol version 传给 UInt8 frame version 参数；修正后第二轮仅 schema migration/count/fingerprint 三项契约预期失败，按实际迁移结构更新。最终 **305 tests / 52 suites** 全通过。服务端首轮 **8 / 3** 通过，加入 gateway 转发及扩大策略/GC/跨 owner 回归后 **56 / 6** 通过。App 在 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名下 **170 / 17** 通过。
- 失败与成功日志、命令、最终源码 SHA-256 见[个人基线恢复证据](../../../docs/reviews/verification-records.md#20260906-personal-snapshot-rebuild)。协议生成物、协议文档、schema relation coverage 和 git diff 检查通过。所有测试进程终态已确认，专用双库 schema 清理后停止 PostgreSQL。
- 新增[个人基线恢复合同](../personal-snapshot-rebuild.md)。尚未接入群 reducer 升级触发，未恢复已丢失历史；可以复用满足下限的已有快照，不保证每次重新计算最新 artifact。个人快照不能代替独立 room_log/hybrid 基线，B03 也未关闭。未部署，未执行真实 App-gateway 链路、Linux 或负载验收。47 项状态仍为 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。

## 2026-09-06：B06 客户端公告效果与旧库升级

- 上一轮显式个人基线恢复属于已验证进展，本轮沿原 47 项修复目标继续群控制消费者。核对发现角色权限还存在空集合读取回退默认权限、缺少各角色 revision 的问题；其旧库恢复需单独处理，本轮先完成公告全路径。
- 新增 V2LocalAnnouncementEffect，在边界验证 UUID room/actor、正 Int64 revision、非负时间、4096 UTF-8 字节上限和可选正源序号。规范摘要绑定解析后的领域内容；房间入口校验 payload room 与 envelope room，显式 room_sequence 也须匹配。旧 payload 缺字段时保存 NULL，不能拿个人游标代替。
- 公告表与新 v2_announcement_effects 同事务保存来源、revision、SHA-256 及可选源序号。个人流、前台预览、持久房间流和 snapshot shadow 共用 reducer；旧版本不覆盖，同身份异内容/同版本异事实回滚，NULL 源序号可补齐但不能随后改写。空公告保留负状态与版本。
- 追加 orderAnnouncementEffects 迁移，主库 **167** 个对象，搜索库 **5**。旧表规范化 room ID，保留正文/revision/时间，不信任原 room_sequence；从现存个人和房间日志回填来源，只为仍存续的公告处理事件，避免退群后残留日志恢复已删除投影。没有日志的旧来源保留未知，不声称已还原。旧暂存与已准备快照丢掉 staging/import 后从同一 artifact 重导入，live bank/outbox/pending reset 保留。
- 公告和 receipts 随快照原子切换，只保留新基线可证明的 room/revision 范围；混合房间仍依照新快照的授权保留独立日志状态。效果表归入内部元数据，不触发全量 UI 刷新。移除旧的未使用公告 DTO。
- 初次测试追加因工作目录错误未写入，首轮只跑既有 **305 项 / 52 套件**，三项失败均为 schema migration/count/fingerprint 预期；按实际新库结构更新。新测试加入后的 **309 项**首轮仅 UUID 边界失败：Core 通用 RoomID 接受非 UUID 字符串，现公告边界显式校验并与服务端合同一致。之后 309 项全通过；额外补充迁移不恢复已清除公告及房间 envelope 校验后，最终 **309 tests / 52 suites** 再次全通过。
- App 在 iPhone 17 / iOS 26.2、IMApp Debug、仅 IMAppTests、关闭签名下 **170 tests / 17 suites** 全通过。五份失败/成功日志、命令与最终七份源码 SHA-256 见[公告效果证据](../../../docs/reviews/verification-records.md#20260906-announcement-effects)。所有测试会话终态已确认，diff、协议文档、schema relation coverage 检查通过；此次未启动 PostgreSQL，未更改服务端/协议。
- 新增[公告效果合同](../announcement-effect-contract.md)，更新群管理合同及问题总表。protocol **24**、PostgreSQL schema **18** 不变。未部署，未做真实 App-gateway 网络、Linux、负载或无障碍人工验收。公告历史 sourceEventID 缺证据仍有限制；客户端各角色显式空策略与迁移、置顶负状态、成员离开/重入及完整保留/代次合同继续开放。B06 状态不变，47 项仍为 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。

## 2026-09-06：B06 当前角色权限基线与 owner 复核

- 上一轮公告跨流、迁移和快照修复属于已验证进展。本轮继续客户端空权限问题的恢复前置条件：旧库缺少各角色 revision，而个人快照不替换独立房间日志状态，入群历史过滤也不能保证得到完整当前策略；不能把缺历史解释为默认权限。
- 新增 Core 的 V2GroupRolePolicyBaseline，固定包含 admin/member 两套完整有效权限、permissionRevision、membershipRevision 与 roomSequence。它表示观察完整策略的读取点，不伪装成两类角色同版本发生的原始事件。空集合保留 deny-all 语义，permissionRevision 为正、membershipRevision 和 roomSequence 为非负，全部限定 Int64 范围，room 必须为 UUID。
- 新增 PostgresV2GroupRolePolicyBaselineStore，一条 SQL 从同一 MVCC snapshot 读取 group room、当前成员资格、room 版本、持久显式策略标记及权限行。非当前成员/不存在的群拒绝，有 marker 无权限行返回空集合，两者皆无才用默认值；不依赖幂等回执或过滤后的历史。设备认证仍由上层负责。
- 新增 V2RoutedGroupRolePolicyBaselineStore：公共构造器只接收控制库并创建不缓存的 PostgreSQL router，避免把两次缓存命中当作 owner 校验。读取前后比较实际 owner/epoch，拒绝不匹配的 room 和路由变化，不尝试 fallback；内部 router 注入供测试使用。
- Core 首轮 82 项通过，但真实 PostgreSQL 两种模式均暴露模型误把初始 membershipRevision=0 判为非法；根据 rooms 的实际 schema 修正，最终 Core **82 tests / 25 suites** 全通过。服务端首轮 **9 / 3** 失败两项；修正后扩展 **29 / 6** 只剩混合模式并发提交失败。诊断轮保留真实结果：revision 7 返回 rateLimited(retryAfterSeconds:3)，新增并发写入耗尽原测试夹具窗口。仅将这一夹具的 profile/room/shard command window 从 10 扩至 20，生产准入逻辑未改。
- 最终真实 SQL 在普通/混合模式分别验证默认、显式空、非空、GC 后相同基线、schema 17→18 迁移后相同基线、授权拒绝、退群与重入；四次真实策略提交与 32 次基线读取并发，检查 revision 与权限集合始终匹配。另在读取后实际插入控制库新 epoch，断言拒绝旧结果。路由单测验证选址、原 actor 传递、epoch 变化及无 fallback。最终 **29 tests / 6 suites** 全通过，包含原快照、权限保留与选定跨 owner 转发回归，非服务端全套。
- 六份运行日志、命令及源码 SHA-256 见[权限基线证据](../../../docs/reviews/verification-records.md#20260906-policy-baseline)。所有会话已确认终态，双库无 im_v2 schema，专用 56440 PostgreSQL 已停止；diff、协议文档、schema relation coverage 通过。
- 新增[权限基线合同](../group-policy-baseline-contract.md)，明确后续网关认证请求、客户端持久恢复、membership/账号生命周期栅栏、各角色 reducer 与全局 expectedRevision 的接入要求。本轮 protocol **24**、PostgreSQL schema **18**、SQLite **167/5** 不变；没有部署，没有新增 App/ClientKit、真实网络、Linux、负载或完整 owner 迁移验收。基线读取尚未接入网关或客户端，不能宣称空权限缺陷已经关闭。47 项仍为 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 权限基线协议与认证网关接线

- protocol 从 24 升至 **25**，新增帧命令 107/108 和基线请求/响应。响应强制包含 admin/member 两项，即使策略为空也明确携带；三个版本/序号保留领域数值边界。两端 protobuf 和版本生成物由仓库脚本生成并通过重生成比对。
- gateway 使用已认证身份读取，非法 room UUID 在存储前拒绝；interactiveRead 准入、成本 2 和固定监控标签已接入。当前成员撤销、房间不存在、owner 变化及配置/持久化错误分别映射为 FORBIDDEN、NOT_FOUND、可重试 ROOM_OWNER_CHANGED 与 UNAVAILABLE。生产入口为每个配置的群 owner 构造读取 store，并使用控制库上的无缓存路由复核；必需依赖没有静默 fallback。
- ClientKit 新增基线传输协议与 fetch 实现，校验房间、恰好两个角色、重复/未知权限、数值溢出、响应关联及协商版本。通用 requestEnvelope 从只检查 request ID 改为同时检查 envelope 与 frame 版本。该 transport 的配置版本同时用于帧和 envelope；生产 App 配置 current，不是 transport 无条件覆盖为生成的当前版本。
- 新回归覆盖空策略、合法零 membership revision、13 类错误响应、重试元数据、非法请求不发包，以及 gateway 认证前/撤销后拒绝、真实身份转发、错误映射和读准入。ClientKit 首轮 **312 项 / 53 套件，14 issues** 和服务端首轮 **72 项 / 8 套件，1 issue** 均源于新测试配置 frame/version 为 1 却期望 protocol 25；修正测试配置后通过，保留初始日志。
- 最终 Core **82 tests / 25 suites**、ClientKit **312 / 53**、服务端定向回归 **72 / 8**、编解码及监控 **14 / 2** 全通过；App 在 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名下 **170 / 17** 全通过。九份运行日志、命令与三十份最终源码 SHA-256 见[协议接线证据](../../../docs/reviews/verification-records.md#20260906-policy-wire)。服务端包含真实双库 SQL 回归，不是全套或真实 TLS E2E；生产入口编译通过。
- 所有测试会话终态已确认；专用 56440 两个数据库均无 im_v2 schema，PostgreSQL 已正常停止。diff、协议文档、schema relation coverage 和生成物检查通过。PostgreSQL **18** 与 SQLite **167/5** 未变，未部署，未执行 Linux、负载或无障碍人工验收。
- fetch 尚不写 SQLite，也不清除恢复意图或更改待发命令；客户端持久恢复、各角色 reducer/迁移、置顶负状态、成员离开/重入和完整保留/代次边界仍开放。问题总表仍为 **47 项：10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**，B06 继续实施中。


## 2026-09-06：B06 客户端角色权限独立排序与空状态

- 上一轮权限基线协议接线属于已验证进展。本轮核对到客户端原来无条件先删后写同一角色，房间全局 MAX revision 不能阻止乱序覆盖；显式空集合没有行，读取时会回退默认权限。
- 新增 V2LocalRolePolicyEffect，在边界校验 UUID、admin/member、唯一已知权限集合、正 Int64 revision、可选正源序号和可选非负时间。规范摘要忽略权限排列和 JSON 格式；房间入口校验 room/envelope，个人 sequence 不再冒充源序号。
- v2_group_role_policies 以 room/role 保存完整集合、独立版本和来源，空集合有明确行；v2_role_policy_effects 保存持久摘要。四条消费路径共用 reducer，旧版本不覆盖；同版本/同身份不同事实回滚，不同角色独立排序，全局 revision 继续供命令 expectedRevision 使用。源序号可从 NULL 补齐，不能之后改写。
- 追加 orderRolePolicyEffects 迁移，移除旧正权限行表，将其观察到的值与版本转换为完整集合；旧 source/room_sequence 保持未知。不存在的角色不再返回默认授权，也不从可能残缺或已清除房间的历史日志猜测当前策略。旧 staging/prepared snapshot 重新导入，保留 live bank、outbox、pending reset。主 schema **168**、搜索 **5**，指纹 **0x337f64a4788a624a**。
- 快照保留合法范围内的效果记录，同一来源在新快照中被改成不同版本或事实时拒绝准备；source sequence 的已知值可以补齐 receipts。仍获授权的混合群按角色比较 live/shadow，保留更高版本和房间全局命令 revision，避免房间游标领先于回退后的权限状态。内部效果表不触发全量 UI 刷新。
- 首轮既有 **312 项 / 53 套件**只有三项 schema 契约预期失败，按实际结构更新。一次在仓库根执行 swift test 因没有 Package.swift 失败；正确目录新增测试编译轮发现两个测试 API 名称错误，改用已有 beginReset 与 cursor.pendingReset。之后 **316 / 53** 通过；再补快照来源冲突回归，最终 **317 tests / 53 suites** 全通过。App 在 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名下 **170 tests / 17 suites** 全通过。
- 六份日志和最终七份源码 SHA-256 见[角色效果证据](../../../docs/reviews/verification-records.md#20260906-role-policy-effects)。测试覆盖两种跨流顺序、持久房间日志、乱序/空集合、独立角色、重启、非法字段/房间、普通及混合快照、两种 staging 阶段迁移和 outbox 保留。所有会话已确认终态；diff、协议文档、schema relation coverage 通过。本批未启动 PostgreSQL、未修改协议/服务端、未部署，未做真实网络、Linux、负载或无障碍人工验收。
- 新增[角色效果合同](../role-policy-effect-contract.md)，更新问题总表和当前 schema 文档。仍需完整基线的持久恢复 worker、账号/设备及 membership 栅栏、基线观察点下限、缺失角色主动获取，以及置顶、成员角色和完整 receipts 保留/清理合同。现有 App 对缺失角色禁用保存，恢复接线前该角色尚不可编辑。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 权限基线持久请求与本地事务栅栏

- 上一轮角色效果排序和迁移属于已验证进展。本轮实现当前态基线在 ClientKit 的持久恢复存储，保持原 47 项完整修复范围。
- V2RolePolicyRecoveryRequest 由 store 创建，持久绑定 room、request ID、账号、安装标识、成员 revision/sourceEventID 和同步 generation。同一栅栏下重复请求复用身份，重启保留；发现接口每批 1–100 个房间，默认 32，刷新陈旧栅栏并清理有限数量的无授权请求。未绑定账号和 reset 状态不能启动恢复。
- completeRolePolicyBaseline 在事务中重查全部本地栅栏及持久请求；退群、重新加入、授权撤销、账号/安装变化、代次切换后的响应不能改权限或清除新请求。本人退群的 room/user UUID 先规范化，修复小写服务端 ID 无法命中本地账户比较的问题。远端 room 和 membership 下限也必须匹配。
- v2_group_role_policy_baselines 保存完整策略观察点，不制造 sourceEventID 或各角色事件版本。较新的角色事实优先；基线覆盖的旧事件只保留 receipt，不覆盖当前值；同版本策略/事实冲突以及观察点版本或源序号不一致拒绝。比已保存观察点更旧的响应返回 false，恢复意图继续保留。观察点只选择真实可比较读取，不拼接不同读取的元数据。
- 请求位于 snapshot bank 外；观察点只为 incoming/live 成员版本和来源一致且仍获授权的房间保留，覆盖范围内的 receipts 同步保留。旧请求在 reset 期间被拒绝、换代后不能写入，发现接口可更新请求身份。移除房间不保留其观察点。
- 追加 recordRolePolicyRecovery 迁移，主 schema **170**、搜索 **5**，主库指纹 **0xfda1ba89465de725**。两张新表不触碰待发命令；旧 staging/prepared snapshot 重新导入，live bank/outbox/pending reset 保留。内部请求表不触发全量 UI 刷新。
- 一次根目录 swift test 调用因没有 Package.swift 失败。正确目录首轮 **317 项 / 53 套件**仅三项 schema 预期失败，按实际结构更新；新测试轮 **321 / 53** 通过，增加受控迁移后 **322 / 53** 通过；最后补充基线与已观察同版本角色冲突、以及更高版本完成恢复的断言，最终 **322 tests / 53 suites** 全通过。App 在 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名下 **170 tests / 17 suites** 全通过。
- 六份日志、命令与八份最终源码 SHA-256 见[恢复存储证据](../../../docs/reviews/verification-records.md#20260906-policy-recovery-store)。所有测试会话终态已确认，diff、协议文档、schema relation coverage 通过；本批未启动 PostgreSQL，未新跑 Core/server，未执行真实网络、Linux、负载、部署或无障碍人工验收。
- 新增[恢复存储合同](../role-policy-recovery-store-contract.md)。自动发现/重试 runner、网络失败与 FORBIDDEN 分类、认证设备/连接取消生命周期及 App 调用仍未接入；本地请求 token 不是服务端授权证明。缺失角色的自动获取、置顶、成员角色、完整 receipts 保留和广义退出生命周期仍开放。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 自动权限恢复与 App 生命周期接线

- 上一轮持久恢复存储属于已验证进展。本轮加入 scheduleRolePolicyRecovery 追加迁移，保存 attempt_count、next_attempt_at、pending/paused 状态和到期索引，旧请求身份/本地栅栏保持不变。主 schema **171**、搜索 **5**，主库指纹 **0x87a3b2175e9448e3**。
- V2RolePolicyRecoveryRunner 默认每批 16 个房间，复用已有 V2CommandRetryScheduler 和 GRDB ValueObservation：先订阅再查到期时间，发现新房间与 reset 完成可自动唤醒。网络失败按 1–60 秒退避并尊重服务端更长 retryAfter，重启不提前执行；单个失败房间不阻塞其他房间。
- 非重试响应与非法基线进入 paused，避免无限请求；resumeRolePolicyBaseline 以新身份显式重试。FORBIDDEN/NOT_FOUND 处理、暂停和重试也在存储事务中核对当前请求及账号/安装/成员/代次栅栏，失败尝试计数参与身份比较，旧尝试不能影响替代请求。取消不写成失败或权限撤销。
- V2ClientRuntime 在初始认证/同步/优先命令完成后启动独立恢复 loop；显式 stop 取消并等待，后台失败也取消。App 每个连接创建新 runner，避免被旧取消任务占用。执行器和存储入口检查取消；忽略取消的测试传输返回迟到结果仍不写入。
- App 会话刷新同时读取权限投影；专用读取 generation 阻止旧显式读取覆盖新恢复结果。权限弹层未知时禁用编辑和保存，第一次恢复时初始化草稿；草稿保留开始编辑时的版本，新投影到来不静默改 expectedRevision，用户可选择重新载入。
- 首轮 **322 项 / 53 套件**仅三项 schema 契约预期失败，按实际新结构更新。新增 runner/runtime 回归后 **326 / 53** 通过；补旧请求表迁移后最终 **327 tests / 53 suites** 全通过。App 在 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名下 **171 tests / 17 suites** 全通过，新增权限读取交错回归。
- 四份日志、命令与十四份最终源码 SHA-256 见[执行器证据](../../../docs/reviews/verification-records.md#20260906-policy-runner)。所有测试会话终态已确认，diff、协议文档、schema relation coverage 通过；protocol **25**、PostgreSQL **18** 未变。本批未启动 PostgreSQL、未新跑 Core/server、未部署，未做真实网络、Linux、负载、权限弹层点击 E2E 或无障碍人工验收。
- 新增[执行器合同](../role-policy-recovery-runner-contract.md)。暂停状态尚缺 App 反馈和显式重试入口，当前只有存储 resume API；自动恢复的真实 App–TLS Gateway 链路仍待验收。置顶/成员角色、完整 receipts 保留与组合验收继续开放，B06 仍实施中。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**。


## 2026-09-06：B06 权限恢复状态与显式重试入口

- ClientKit 新增原子策略/恢复状态读取，在同一次 SQLite read snapshot 中返回当前策略与不可读取、等待同步、需要基线、排队、暂停或就绪状态。旧成员/账号/代次栅栏显示需要恢复；无账户或无授权时不返回策略。排队和暂停保留已观察到的权限及显式空集合。
- 恢复请求表现在属于可见会话详情状态，其插入、延后、暂停和删除仅发普通 conversationDetails 刷新，不触发会话列表或紧急全量刷新。
- App 使用必需的 V2GroupRolePolicyAccessing 能力读取状态与持久显式重试；生产调用已有 resumeRolePolicyBaseline，网络仍由执行器负责。缺失能力显示不可读取；只有需要基线或暂停允许重试，提交期间拒绝重复请求。
- 权限弹层增加分状态文案、“请求同步权限”按钮及无障碍标签/提示和稳定标识。失败保留当前状态并允许再试；提示状态无法确认，不误称持久意图必定未保存。授权撤销或选中角色消失清除旧草稿；新投影不静默更新既有编辑 expectedRevision。
- 读取 generation 同样保护重试返回；新状态已到达时，旧重试随后失败不会覆盖它或留下错误提示。当前失败在恢复阶段改变时清除。新增交错回归实际验证以上行为。
- ClientKit 既有 **327 / 53** 与新增回归后的 **329 tests / 53 suites** 均通过。App 初轮 **174 / 17**、补能力缺失后的 **175 / 17**、补失败交错后的最终 **176 tests / 17 suites** 全通过；环境为 iPhone 17 / iOS 26.2、Debug、仅 IMAppTests、关闭签名。本批没有失败测试运行。
- 五份运行日志、命令与十份最终源码 SHA-256 见[状态与重试证据](../../../docs/reviews/verification-records.md#20260906-policy-recovery-ui)。测试会话均已结束，最终 App 日志含 TEST SUCCEEDED。diff、协议文档、schema relation coverage、五份日志和十份源码哈希检查通过，问题表确认 47 个唯一编号。protocol **25**、PostgreSQL **18**、SQLite **171/5** 未变；未启动 PostgreSQL、未新跑 Core/server、未部署。
- 新增[状态与重试合同](../role-policy-recovery-ui-contract.md)。Store 与 SQLite 测试不等于权限弹层点击 E2E、真实 App–TLS Gateway、VoiceOver、最大 Dynamic Type 或 RTL 人工验收，这些仍未执行。置顶、成员角色、历史负事实、完整 receipts 保留/GC 和组合边界继续开放。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**，B06 仍实施中。


## 2026-09-06：B06 置顶快照负状态与源版本比较

- 上一轮权限恢复交互属于已验证进展。本轮继续 B06，确认服务端 unpin 会删除当前投影，而 ClientKit 将个人游标保存为置顶源版本。先实现服务端置顶快照顺序及负状态保留，保留完整后续客户端/历史恢复范围。
- 新增 V2PinnedMessageSnapshotEffect，校验 UUID、事件类型、布尔值、非负时间及可选正 Int64 源 room sequence。工作器按源版本比较，旧事实不覆盖新事实；当前身份内容/版本冲突和相同版本不同来源拒绝，重复不增加投影版本。取消置顶保留当前负事实，实际构建的快照携带该状态。
- 查询有限的 UUID 大小写键候选并沿用已有键，防止新建第二个当前对象。关联核对发现客户端逐字比较快照键和正文，会误拒绝等价 UUID；现只规范化 group capability 的 UUID 段，kind/role 保持精确，不修改原始键、正文、摘要或非群管理快照合同。
- 缺源序号的旧正文继续接受但不伪造版本，不能覆盖已知源版本；两条未知旧来源仍保留兼容的到达顺序，真实历史顺序尚未恢复。已丢失的旧 unpin 不能从本批新比较规则重建，后续还需权威恢复和 writer/worker 一致切换；客户端置顶 reducer 仍待实现。
- 首次 PostgreSQL 启动受沙箱共享内存限制，SwiftPM 也受默认 Clang 缓存写入限制；获准使用独立临时库和构建环境后继续。首轮编译发现 EventID.uuidValue 可空，改为显式 UUID guard。之后 **11 项 / 4 套件**一例失败：测试预期工作器拒绝变更来源，但数据库现有不可变 effect 约束在日志写入阶段已提前拒绝。修正测试预期，并让夹具序列分配与日志写入同事务，验证拒绝后没有游标缺口。
- 最终服务端定向 **19 tests / 4 suites** 全通过；包含实际源提交、逆序 fanout、日志移除后重复、旧负事实、混合 UUID 键、快照 build/manifest/page/ACK、同版本冲突回滚，以及原策略保留/源版本、reaction、schema 和快照合同回归。不是服务端全套。ClientKit **331 tests / 53 suites**、iPhone 17 / iOS 26.2 Debug IMAppTests **176 tests / 17 suites** 全通过，App 关闭签名。
- 六份运行日志、命令与六份最终源码哈希见[置顶快照证据](../../../docs/reviews/verification-records.md#20260906-pin-snapshots)。所有测试会话终态已确认，两临时库均无 im_v2 schema，专用 PostgreSQL 已停止。diff、协议文档和 schema relation coverage 检查通过。
- 新增[置顶快照合同](../pin-snapshot-contract.md)，更新问题表。protocol **25**、PostgreSQL **18**、SQLite **171/5** 未变。没有部署，没有真实 App–TLS、Linux、负载、无障碍人工或旧置顶历史迁移验收。成员退出/重入、撤回与置顶组合、客户端四路 reducer、完整 receipts 保留/GC 仍开放。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**，B06 仍实施中。


## 2026-09-06：B06 客户端置顶效果、旧库迁移与快照保留

- 上一轮服务端置顶快照及 UUID 键修复属于已验证进展。本轮实现 ClientKit 的 V2LocalPinnedMessageEffect，个人同步、房间预览、持久房间日志和 snapshot shadow 共用处理；源序号取正文或可信房间 envelope，拒绝二者冲突，不再使用个人游标。
- 新增 v2_pin_effects，以 sourceEventID/room 保存 message、规范摘要和可选源序号；claim、物化值和游标同事务。相同来源改内容/对象/源序号或同对象同源版本不同来源拒绝，重复不回退。取消置顶保留 false 行及版本。未知 receipt 后续补齐源序号时重新比较，不能一见已有 receipt 就跳过。
- 追加 orderPinnedMessageEffects 迁移，主库 **172** 个对象、搜索 **5**，主库指纹 **0xdd0136fa348a4c95**。旧 room/message UUID 规范化，保留值与时间，把不可信个人游标置为 NULL；从仍保留的个人/房间日志回填证据，仅对仍有投影的对象生效，不恢复已清理数据。staging/prepared snapshot 从同一 artifact 重导入，live、pending reset、outbox 保留。
- 普通快照保留覆盖范围内的 receipts；仍获授权的 hybrid 房间比较 live/shadow 源版本，保留较新事实。新快照来源与 live receipt 冲突时拒绝，即使旧消息不在新 bank。保留的同来源 receipt 可补齐快照缺失的源序号。移除对象不带旧 receipts，本人退群清理包括新表；内部摘要表不触发全量 UI 刷新。
- 两次合并编辑/测试命令误从仓库根调用 swift test，均因无 Package.swift 结束，没有测试运行，日志保留。正确目录首轮 **331 / 53**仅三项 schema 预期失败，按实际新库更新。新增用例一轮因观察器类型名错误未编译；修正后 **337 / 53**仅重复投递夹具触发现有同步日志唯一约束，改为先清理旧日志、保留 receipt 再投递，以验证独立摘要保护。
- 最终 ClientKit **339 tests / 53 suites** 全通过，覆盖两种跨流顺序、重启、不同消息独立排序、来源冲突、旧 receipt 补序号、非法数值/UUID/envelope、普通/hybrid 快照、来源重用、元数据保留/移除、两种暂存阶段迁移与本人退群。App 在 iPhone 17 / iOS 26.2 Debug、仅 IMAppTests、关闭签名下 **176 tests / 17 suites** 全通过。
- 七份失败/成功日志、命令和七份最终源码哈希见[置顶效果证据](../../../docs/reviews/verification-records.md#20260906-pin-effects)。所有测试会话终态已确认；diff、协议文档及 schema relation coverage 通过。本批未启动 PostgreSQL，未新跑 Core/server，protocol **25** 与 PostgreSQL **18** 未变。
- 新增[置顶效果合同](../pin-effect-contract.md)，更新问题表。两条都缺源序号的旧事实仍不能证明真实顺序，已经丢失的旧取消事实、置顶权威基线、writer/worker 一致切换、成员角色、迟到授权/重新入群与撤回组合、完整 receipts 保留/GC 继续开放。没有部署或真实 App–TLS、Linux、负载、无障碍人工验收。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**，B06 仍实施中。


## 2026-09-06：B06 服务端成员角色快照排序

- 上一轮客户端置顶效果与迁移属于已验证进展。本轮确认服务端 group.member_role_changed 仍按到达顺序替换快照，没有比较事件已有的 membership_revision。
- V2GroupPolicySnapshotEffect 扩展为解析目标成员角色，以 membership_revision 为版本，room/target 为对象键；不读取角色 payload 的普通 revision 作为排序依据。UUID、admin/member、正 Int64 版本、可选源序号/时间均校验。owner 角色变更拒绝，与 Core 命令及生产写入一致。
- 工作器按目标成员复用组策略投影事务，较旧角色不能覆盖较新角色；普通 member 是明确当前值。重复当前 source 先验证事实与版本，不因低版本分支跳过来源冲突；同版本不同来源拒绝。UUID 大小写候选查询延续旧物理键，重复当前对象拒绝。
- 新增真实 PostgreSQL 测试：两名成员三次角色变更经逆序 planner/fanout 投递，检查各自当前状态；追加无源序号旧事件不覆盖新版本；实际构建、读取和 ACK 快照后，同版本冲突仍回滚并保留 checkpoint。类型回归验证目标、版本选择、非法角色、数值与字段边界。
- 本批 **22 tests / 4 suites** 全通过，没有失败测试运行；还包括已有置顶、公告、权限保留/源版本、reaction、schema 和快照定向回归，不是服务端全套。日志、命令与四份最终源码哈希见[成员角色快照证据](../../../docs/reviews/verification-records.md#20260906-member-role-snapshots)。
- 测试会话终态已确认，两临时库均无 im_v2 schema，专用 PostgreSQL 正常停止；diff、协议文档、schema relation coverage 通过。protocol **25**、PostgreSQL **18**、SQLite **172/5** 未变；未新跑 Core/ClientKit/App，未部署，未做真实 App–TLS、Linux、负载或无障碍人工验收。
- 新增[成员角色快照合同](../member-role-snapshot-contract.md)。现有 remove 会删除角色并丢失版本屏障，迟到 role 和较旧 remove/较新重入仍未闭环；不能用全局最近 membership 事件替代逐成员事实。下一步仍需持久 add/remove 负状态、客户端统一处理、历史恢复与完整授权代次/保留合同。47 项状态保持 **10 已验证、9 实施中、3 已实现待验证、2 待外部验收、23 未开始**，B06 继续实施中。


## 2026-09-06：B27 消息编辑、撤回与 reaction 的 owner 事务栅栏

- 在已完成普通成员栅栏的基础上，复现消息变更同类问题。修复前真实双库六个场景触发 22 个断言失败：所选 epoch 与 owner 不一致仍发生业务提交，包含消息/操作回执和房间序号。
- 新增三类必传 ownerRoute 的内部存储能力，路由 wrapper 保留完整 route，单库/同物理库也核查注册表与 epoch。Gateway 两种组装分支均接入；编辑继续在 owner 事务外读取 control 身份。
- 事务取得 operation advisory lock 后锁定 room，核对 shard/owner_epoch，再允许重放或当前授权/准入和写入。旧 owner 的成功回执也不能绕过栅栏。网关现有 UNAVAILABLE 保持 retryable=true，无协议/schema 变更。
- 首轮 4 项 / 2 套件通过；工具返回在上下文切换时丢失，已核实终态测试日志和进程结束，不虚构该次 exit code。最终可追踪会话退出 0，**87 项测试 / 7 套件**通过：六类 owner 并发/旧缓存/错库/锁等待场景，三类网关映射及既有消息、成员、邀请、审批、恢复和历史迁移回归。
- 五份日志、两个检查/清理脚本、11 份最终源码哈希和六份修复前哈希见[本批证据](../../../docs/reviews/verification-records.md#20260906-message-mutation-owner)。三个临时库均无 schema/其他连接，本批创建的 control 库已删除，专用 56440 PostgreSQL 已停止。
- 新增[消息变更栅栏合同](../message-mutation-owner-fence-contract.md)，更新问题表/方案及成员合同的剩余范围。增加一次短查询，重放也需 room 锁，未进行吞吐压测。完整迁移必须先 fence 旧 owner；发送/批量/fast append、其他房间命令、读取和后台工作仍需统一。PostgreSQL 25、protocol 25、SQLite 173/5 不变。47 项当前为 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**，B27 保持实施中。


## 2026-09-06：B27 公告、置顶、权限与成员角色的 owner 栅栏

- 复现四类群管理命令同样丢弃所选 epoch、跳过同库路由并在锁房间之前重放回执的问题。修复前真实双库八个参数场景均提交到旧 owner，32 个断言检查操作回执、完整 room 状态和序号而失败。
- 新增必传 ownerRoute 的群管理存储能力。四个路由入口保留完整 route，Gateway 单库及多 owner 两个组装分支均使用新能力，复用已有连接池。操作 advisory lock 后复用统一 room owner 栅栏，先校验再重放或执行当前业务授权/准入；self-role 提前返回也不能绕过。
- 首轮 **5 项测试 / 3 套件**通过，最终 **93 项测试 / 7 套件**通过，均可追踪会话退出 0。包含普通群/大群、四类命令、十次并发一次提交、旧缓存及同库多 shard、错误/未知 owner、self-role、回执等待 room 锁时 epoch 变化和四类 Gateway UNAVAILABLE 映射；还覆盖公告/置顶/角色投影、空权限保留、已有成员/消息栅栏、三库邀请/审批/恢复及历史迁移链。
- 最终运行触发依赖重编译，核实 Swift 6.3.3 和活跃编译进程后等待原会话完成，没有重启测试或把缺少新日志当作终止。五份日志、两个脚本、八份最终源码和四份修复前哈希见[本批证据](../../../docs/reviews/verification-records.md#20260906-group-capability-owner)。
- 更新[群管理栅栏合同](../group-capability-owner-fence-contract.md)、当前问题表、方案及前两批合同的剩余范围。迁移须先 fence 旧 owner；moderation、已读回执、通用发送/批量/fast append、读取/后台任务及完整历史复制/切换/恢复仍开放。新增短查询及回执 room 锁未做吞吐压测，未做实际 TLS/App/生产迁移验收。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变。47 项保持 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**；B27 继续实施中。


## 2026-09-06：B27 普通及可信 moderation 的 owner 栅栏

- 普通屏蔽/禁言/移除，以及可信屏蔽/冻结/解冻，都通过四个底层事务在 room 锁前重放本地回执，没有所选 owner 校验。Gateway 单库与内容审核服务共用的存储也绕过路由。
- 首次负向回归的十个场景实际写入，两个解冻场景因夹具仅设置 frozen_at、缺少 frozen_by_user_id 触发 rooms_check，共 52 issues；单独保留该诊断日志。修正夹具且生产实现不变后，十二个真实双库场景均实际提交旧 owner 业务/审计，60 issues，退出 1。
- 新增 V2OwnerValidatedModerationStore，普通和可信安全两个入口必传 ownerRoute；四个事务在 operation advisory lock 后、旧回执之前复用 room owner 栅栏。Gateway 两个组装分支和内容审核的可信服务均使用路由 wrapper。同库多 shard 也保留 epoch，普通与可信权限入口保持独立。
- 首轮 **6 项 / 4 套件**通过，包含十二个双库场景、三类 Gateway UNAVAILABLE 映射和审核重试/暂停的两个参数场景。所有私有 selector 调用方已改用完整 route，随后删除无人调用的同库跳过路由入口。
- 最终 **113 项测试 / 8 套件**通过、退出 0，覆盖新 owner 栅栏、无 owner profile 与非成员安全主体、十次并发只写一份业务/审计、旧缓存/错库/未知 shard/等锁 epoch 变化、审核失败不误 resolve，以及既有 moderation/内容审核、其他房间变更、投影、三库邀请/审批/恢复和七条历史迁移链。
- 六份原始日志、三个运行/检查/清理脚本、十份最终源码哈希及两组修复前哈希见[本批证据](../../../docs/reviews/verification-records.md#20260906-moderation-owner)。新增[moderation 栅栏合同](../moderation-owner-fence-contract.md)，更新问题表/方案及此前 owner 合同的剩余范围。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变，无新 schema 迁移或生产部署。owner 校验增加短查询及回执 room 锁，未做吞吐压测；审核 job 全量迁移、进程故障和实际 TLS/App 仍未验收。已读回执、通用发送/批量/fast append、读取和其他后台任务的统一 owner 检查、完整历史复制/切换/恢复仍开放。
- 47 项保持 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**；B27 和完整修复目标继续开放。


## 2026-09-06：B27 群已读回执与读者候选 owner 栅栏

- 复现单条、批量和读者列表只选物理 store、不验证 route epoch 的问题。普通群/大群六个真实双库场景共 10 个失败断言：单条/批量实际写入旧 owner，读者查询接受过期 owner。
- 新增每行必传 route 的群回执 owner 能力；同物理库合批也保留各房间 shard/epoch。带栅栏单条复用批量实现，共用原有 operation/cursor advisory locks。之后按 room UUID 排序取得共享锁，按加锁返回的实际 owner 计算每行布尔准入，缺失行不因随后创建而放行。
- 集合 SQL 保留批量单调 UPSERT，owner 错误行不进入 eligible，返回状态也先于回执重放/冲突判定；同批合法行正常提交。prepared record statement 升至 v2，无 schema 变化。候选每页先取共享锁验 owner，再查消息/成员/候选，结束 owner 事务后由 control 过滤身份/隐私。
- Gateway 单库和多 owner 都接入；写入与读者列表 ownerChanged 映射 UNAVAILABLE/retryable。首轮 **7 项 / 3 套件**通过。扩展测试夹具缺少一个 try 导致编译失败、没有测试运行，日志独立保留；修正后 **8 项 / 3 套件**通过。
- 最终日志确认 **126 项测试 / 11 套件**通过；原终端返回在上下文切换后不可恢复，证据清单将进程退出码记为未知。覆盖六种 owner 场景、混合正确/过期/错误 shard/缺失房间/成员/序号的逐行结果、20 次单条/批量同 operation 竞争只提交一次、同库 route 传递、无 owner profile 的 control 隐私过滤、两个房间的 32 轮消息/回执并发（有/无 owner 栅栏两种路径均无新增 deadlock），以及既有网关、其他房间变更、投影、三库邀请审批恢复和历史迁移链。
- 七份日志、三个运行/检查/清理脚本、十份最终与四份修复前源码哈希见[本批证据](../../../docs/reviews/verification-records.md#20260906-read-receipt-owner)。更新[群回执合同](../read-receipt-owner-fence-contract.md)、问题总表和方案。每个物理批次多一次共享锁查询，尚未做新的吞吐/延迟验收。
- 私聊 notGroup 分类虽然已验证 owner，后续 reciprocal projection 仍为既有 control/user 事务，其跨库迁移交接尚未闭环。通用发送/批量/fast append、其他读取与后台任务、完整历史复制/切换/故障恢复仍开放，不宣称所有已读回执迁移已完成。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变。47 项保持 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**；B27 和完整修复目标继续开放。


## 2026-09-06：B27 普通消息发送 owner 事务栅栏

- 修复前真实双库三个场景均提交了旧 owner 消息：普通群/大群单条各一条，大群批量两条，1 项测试 / 6 issues、退出 1。初次夹具遗漏 ID factory 的 try 未运行测试，日志独立保留。
- 新增必传 route 的单条/集合发送能力；PostgreSQL 用每次调用的私有值副本保存约束，缓存、额度 actor 和 workload database 不被重建。同房间矛盾约束拒绝，没有抹掉 epoch 的默认方法。
- 普通单条、私聊标准/快速/内部热房间、大群 SQL/fallback 六处事务入口均在 operation locks 后取有序 NO KEY UPDATE owner 锁，覆盖回执重放与业务提交。大群仍使用原集合 SQL；来源/目标转发锁顺序保持不变。owner 错误回滚整个物理发送批次，网关返回 UNAVAILABLE/retryable。
- 删除同物理库绕过路由的入口，同库合批保留每个逻辑 shard/epoch。核对 Gateway 时发现共享房间依赖只登记 group shard，补齐全部 roomShardStorage，包括独立命名的 direct shard；本地依然共享原缓存与额度 actor。单条 direct/group 路由测试和组装源代码检查覆盖该接线，未作真实 TLS 启动验收。
- 首轮 4 项 / 2 套件中的 9 issues 来自旧缓存夹具实际使用实时路由；改用真实缓存后通过。扩展 7 项 / 3 套件只余一项旧指标断言，因新增重放使后续缓存探测变冷；明确重新预热后通过。69 项 / 4 套件扩展中新增冷/暖批量 owner 回滚、credit 归还均通过，四个阶段计数断言尚写死旧的两次调用；按新增拒绝请求更新为三次，保持后续 preflight/persistence 计数为两次。
- 接线补充前 **161 项 / 13 套件**通过；最终组装后 **162 项测试 / 13 套件**通过、退出 0，包含真实缓存 fast append、混合 epoch 冷/暖批量、额度归还、旧缓存新写/重放、错库/未知 shard、等锁 owner 更新、两房间发送/回执 32 轮并发，以及既有消息变更/邀请/审批恢复和七条历史 schema 迁移链。
- 九份日志、三个运行/检查/清理脚本、十份最终源码哈希、三份修复前生产哈希及接线补充前 main 哈希见[证据清单](../../../docs/reviews/verification-records.md#20260906-send-owner)。新增[发送 owner 合同](../send-message-owner-fence-contract.md)，同步问题表、方案和既有 owner 合同。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变。发送的 control 身份/策略边界、后台转发导入/来源读取、其他 worker、post-commit 投影交接及完整复制/核验/切换/故障恢复仍开放。未做新的负载、Linux/container、TLS/App/设备或生产部署验收。
- 三个临时 schema 和其他连接归零，临时控制库删除，专用 56440 PostgreSQL 停止。47 项保持 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**，B27 与完整修复目标继续开放。


## 2026-09-06：B04/B27 后台转发导入 owner 栅栏

- 发现目标新 inbox 检查 epoch 后未持锁、accepted 重试先返回旧 message receipt、最终 completed 更新没有 owner 锁三处竞争。首次新增测试的条件可选闭包触发 Swift 无法生成诊断，拆为显式 if/else 后负向运行；生产实现保持原样。
- 修复前真实双库 **3 项测试 / 9 个参数或独立场景、18 issues**、退出 1：新 inbox 在旧 owner 插入，两种群模式的 accepted 恢复与三种私聊投递模式在后处理期间 owner 变化后均错误发布终态。该诊断日志完整保留。
- 新绑定在配额锁和重复绑定检查后持 FOR SHARE 到 inbox/media mapping 插入完成；已有 immutable binding 先返回，避免反向锁住已有 inbox。接受路径保持 inbox → message operation → room，owner 检查移到回执重放之前；最后完成事务在 inbox 后取 NO KEY UPDATE owner 锁，再提交 completed。
- 明确区分 accepted 活跃工作与 completed/rejected 不可变终态。旧 owner 上 accepted 抛 ownerChanged 并保留 pending finalization；已完成的事实仍可跨后续 epoch 重读。相同 owner 的退群、目标副本撤回、部署文字上限缩小依然可以恢复原回执，不重复消息。
- 首轮 **7 项集成测试 / 1 套件**通过，包含 19 个后台投递场景。新增真实 endpoint/worker 场景证明旧 accepted 不写源 receipt、不完成 job，未终态 export 占用保留；恢复后只完成一条目标消息。媒体 owner、并发导入、终态证据等相邻测试通过。
- 最终 **176 项测试 / 14 套件**通过、退出 0，包含媒体复制/租约、后台运行时、operator、发送与此前各房间变更栅栏、三库邀请/审批/恢复和历史 schema 迁移链。源码在首轮与最终运行之间未改变。
- 六份日志、三个运行/检查/清理脚本、七份最终源码哈希与两份修复前生产哈希见[证据清单](../../../docs/reviews/verification-records.md#20260906-forward-import-owner)。新增[后台导入 owner 合同](../forward-import-owner-fence-contract.md)，修正历史合同中 accepted 可跨 epoch 继续恢复的表述，更新问题表和方案。
- post-commit 用户投影与目标完成标记仍是不同事务，不能据本批声称撤销已经发生的投影或完成所有迁移交接。前台同库转发仍有独立路由快捷分支；原 envelope 与活跃工作迁移承接、完整复制/核验/切换/故障恢复、全局内容封禁和终态清理仍开放。测试恢复临时库 epoch 只用于同 owner 重试验证，不是生产迁移策略。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变；三库临时 schema 和其他连接清零、临时控制库删除、专用 56440 PostgreSQL 停止。未做生产 TLS/App、Linux/container 或新的负载验收。47 项保持 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**，完整修复目标继续开放。


## 2026-09-06：B04/B27 前台同库转发的两端 owner 栅栏

- 旧的 singlePhysicalOwner 分支完全绕过目录；混合拓扑中的同库片段也丢弃来源/目标 epoch。修复前真实双库 1 项测试 / 2 个场景共 6 issues，均错误接受转发并创建操作记录。生产文件负向哈希保留。
- 新增必需实现的 owner-aware 转发和接受能力，Gateway 两种组装都传来源/目标 route。目录完成后仍为全同库请求保留一次来源集合查询及原有界目标并发；混合拓扑保留逐目标与连续同库来源片段，跨库 export/inbox 不变。
- 来源批量读取在事务中取 SHARE；重放/结果修复、client ID 创建、消息接受和结果补记各在自身事务内取完整且按 UUID 排序的房间 UPDATE 锁，验证 shard/epoch 后处理。普通发送的目标-only 能力拒绝 forwardedFrom，不能以单端校验代替转发能力。
- 首次修复构建报告局部查询函数捕获缺少 @Sendable；补齐并保留日志，未把编译失败计作通过。最终源码在回归运行期间不变。
- 最终 **184 项测试 / 14 套件**通过、退出 0。新增来源/目标初始过期、真实旧缓存新写/重放、错误 shard/库、等锁期间更新 owner；接受前/接受后两端变化四场景证明保留稳定 client ID、未错误补记结果，当前 owner 恢复和八次并发重试只保留一条目标消息。既有 16 路反向转发增加显式 owner 模式；来源受众、媒体、顺序/并发及历史撤回后重放通过。
- 既有发送冷/暖批量、群能力/成员/消息/moderation/回执栅栏，后台转发媒体、worker、运行时、三库邀请与七条历史 schema 迁移链均通过。日志、运行/检查/清理脚本及源码哈希见[证据清单](../../../docs/reviews/verification-records.md#20260906-local-forward-owner)。新增[前台转发合同](../foreground-forward-owner-fence-contract.md)，同步当前总表、方案与历史合同；纠正总表 B29 的旧协议号为 25。
- 本批不关闭 B04/B27：仍需完整房间历史复制/核验/切换/故障恢复、活跃操作/export/inbox 承接、post-commit 用户投影交接、其他读取/worker、control 身份/策略隔离、全局内容封禁和终态清理。未做新负载、真实 TLS/App、Linux 或生产发布验收。
- PostgreSQL 25、protocol 25、SQLite 173/5 不变。47 项仍为 **12 已验证、13 实施中、3 已实现待验证、2 待外部验收、17 未开始**；完整修复目标保持开放。

本批收尾：三库临时 schema 和其他连接清零，临时控制库已删除，专用 56440 PostgreSQL 已停止；五份日志、三份脚本、八份最终源码哈希和四份修复前生产源码哈希已归档。


## 2026-09-06：B05 完整输入密码哈希与认证提交

- 上轮前台转发修复已完成并留证，本轮按清单转入 B05。原 HTTP 输入接受 12–1024 UTF-8 字节和 NUL，底层 bcrypt 只使用前缀；修复前 2 项测试 / 6 参数场景共 9 issues、退出 1。最初从 monorepo 根目录执行 swift test 未找到 Package.swift，仅为命令路径错误；另行保留 invocation 日志后从 Server 包运行真实负向回归。
- 固定官方 Argon2 20190702 提交 62358ba2123abd17fccf2a108a301d4b52c01a7c，14 个 upstream 文件保持原样，归档许可证及逐文件哈希。可移植 C reference 实现关闭内部线程，Swift 独立双线程池约束整体资源。未新增主机系统库要求。
- 新 hash 为标准 Argon2id v19 PHC，64 MiB/t=3/p=1、16 字节随机盐、32 字节结果。输入显式传 UTF-8 长度，拒绝 NUL、不 trim/归一化/截断。严格参数/规范编码校验阻止任意内存、迭代或并行度；未识别或旧 bcrypt 使用固定同成本 dummy 后拒绝，旧值不变且无自动 rehash。
- 应用最多 2 次 KDF、无等待队列，满额 no-store 503/Retry-After:1；活跃 C 工作取消后仍占执行位，停机先停止准入再排空。注册与验证不持有 DB 连接做 KDF。Account 主程序生命周期已接线，删除废弃 dummy bcrypt 配置与 htpasswd 生成依赖；既有本地 secrets 无需重建，只移除废弃键。
- 密码计算后，成功认证事务取得失败窗口 advisory lock 和凭据 SHARE 锁，复核最初 user/完整 PHC 值及账号状态，再原子清理失败窗口和写审计。计算期间改密的旧结果不能发账户断言或覆盖新 hash；审计写入失败不提前清除失败窗口。
- 首轮 18 项 / 2 套件通过。扩展 34 项运行发现 4 issues：固定 dummy 盐误为 17 字节，严格策略拒绝后导致旧/未知账号 503 和直接存储夹具失败；改为明确 16 字节并保留失败日志。
- 最终 **39 项测试 / 7 套件**通过、退出 0。覆盖官方 v19 Argon2id 向量、71/72/73/1024、NUL、跨字节 Unicode、空白和规范化差异、随机盐、畸形/超预算参数、取消/饱和/停机、真实 PostgreSQL HTTP 注册登录、旧凭据限制、并发替换、审计故障回滚，以及设备轮换/重复 HTTP/终止与账号禁用。
- 真实 32 请求突发为 2 次派生、30 次立即 busy，随后正常哈希/验证恢复；本地 Debug 此阶段总计 1.596 秒，不宣称生产吞吐或 Linux 峰值 RSS。当前参数符合既有方案的候选 p=1 配置，未冒充 RFC 推荐的完整 p=4 组合。
- schema 25、protocol 25、SQLite 173/5 不变。当前绿地输入/存储/认证合同下 B05 已验证；真实旧账号可信恢复/提示、生产 Passkey、Linux/container 和多副本负载继续按发布缺口跟踪。完整修复目标未完成。
- 问题状态更新为 **13 已验证、13 实施中、3 已实现待验证、2 待外部验收、16 未开始**，仍有 34 项未完全关闭。详见[密码合同](../password-hash-contract.md)与[证据清单](../../../docs/reviews/verification-records.md#20260906-password-hash)。

本批收尾：两个临时 schema 和其他连接清零，专用 56440 PostgreSQL 停止；七份运行日志、三份脚本、十三份最终源码哈希、三份修复前生产哈希与十四份上游文件哈希已归档。

## 2026-09-07：B08 仅撤销凭据存储和兑换

- 独立 256 位凭据、规范编码、诊断脱敏；服务端只存 SHA-256 摘要，绑定账号、设备和原会话时间。
- 固定绝对期限加 10 分钟收尾；取得账号锁后检查当前时间及绑定，复用原子设备撤销并补齐已撤销设备清理。
- 实际验证：Core 93/30、服务端单元 16/2、PostgreSQL 20/1，独立 26→27 迁移及 schema 安全门禁正反向通过。初次格式长度断言、Swift SQL 缩进、SQL 括号及迁移种子失败均留证；未计为成功。
- 仍未在登录/刷新中交付 capability，HTTP/ClientKit/App 仍待实现；未重跑真实 App/TLS 全链路。本批保持 B08 实施中，完整 47 项目标未完成。
- [合同](../device-revocation-capability-storage-contract.md)；[证据](../../../docs/reviews/verification-records.md#20260907-revocation-capability-storage)。

## 2026-09-07：B08 撤销 HTTP 和独立客户端传输

- Account 注册 POST /v2/device-credentials/revoke，trusted-edge 与持久地址限流先于兑换；请求仅接受 capability/operationID，拒绝目标字段和超限 body。
- ClientKit 不依赖当前账号认证；固定旧 capability/operationID 重试，分别处理 revoked/expired/invalid/conflict，保留限流提示和取消。
- 服务端单元 20/4、真实 PostgreSQL pipeline 4/1 通过；客户端报告 421/66，416 实际执行，5 在线跳过。初始响应头类型、测试宏嵌套及内存 body 大小保护失败均留证。
- 未执行本批 App/HTTPS socket 验收；登录响应交付与持久退出补偿尚未接线。B08 保持实施中。
- [合同](../device-revocation-capability-http-contract.md)；[证据](../../../docs/reviews/verification-records.md#20260907-revocation-capability-http)。

## 2026-09-07：B08 原子交付撤销凭据

- schema 28 注册事务同时保存独立证明、摘要绑定和加密重放；迁移终止已发过凭据的旧会话，不补造 capability。
- 刷新保持原证明和期限，ClientKit 同一 Keychain record 必需保存完整能力；改变证明的响应被拒绝并保留原 pending record。
- ClientKit 423 报告/418 实际/5 在线跳过，App 193 报告/192 实际/1 在线跳过；服务端 10/2、真实 PostgreSQL 21/1、迁移正反向通过。
- 完整真实链路：HTTPS 5/2、UI 2、headless 1/1，DB 15|5|0|0|5。新增 capability 定向 HTTPS 5/2，204×3、409×1、401×1，DB 7|3|0|0|3。完整 UI 运行在增加定向测试之前，生产实现相同。
- 保留旧假响应缺字段导致的 3 项失败，以及编辑 guard 未通过后的前置 HTTPS 运行；不把前置运行算作新 capability socket 验证。自建资源已清理。
- App 持久退出交接与离线补偿尚未接通，B08 仍实施中。
- [合同](../atomic-revocation-credential-issue-contract.md)；[证据](../../../docs/reviews/verification-records.md#20260907-atomic-revocation-issue)。

## 2026-09-07：B08 凭据删除前的持久交接

- 原凭据保存稳定撤销 ID，独立 Keychain 队列成功后才删除；冷启动完成交接，新登录保留旧任务，串行实际 IO 防止旧删除影响新账号。
- 队列不含 access/refresh，保存旧证明/身份、重试时间与暂停状态；最多 256 项，冲突/损坏/不可写失败保留，完整任务 CAS 防止迟到完成覆盖更新。
- 定向 28/3 通过；最终 ClientKit 432 报告/427 实际/5 在线跳过（67 套件，4.998 秒），App 194 报告/193 实际/1 在线跳过（20 套件，4.932 秒）通过。
- 真实签名模拟器 Keychain 验证两个 item、保护等级、删除失败恢复、原 ID 重用、换号隔离及清理；不代表物理设备锁屏或任意指令处强杀验收。
- 保留首轮沙箱构建缓存失败、测试 ID 构造编译失败、无签名 App 宿主 Keychain -34018 失败。修正测试构造并改用正常签名宿主后回归通过，无生产权限绕过。
- 未新跑 PostgreSQL/HTTPS/UI/headless。App 旧 Push 网络清理仍会阻塞断网退出，独立联网 runner 尚未实现；B08 和完整 47 项目标仍开放，16 已验证、31 待完成。
- [合同](../device-revocation-handoff-contract.md)；[证据](../../../docs/reviews/verification-records.md#20260907-revocation-handoff)。

## 2026-09-07：B08 独立执行器与不依赖网络的本地退出

- 撤销 runner 使用旧 capability/operation，持久退避/暂停及完整任务 CAS；订阅通知后查询，不轮询空 Keychain。后台取消保留 flight 所有权，新账号无需等待。
- App 已移除退出前 Push HTTP，关闭本地工作后持久交接；真实过期凭据退出及重建 App 仍 signedOut、任务保留、测试域清理通过。
- ClientKit 439 报告/434 实际/5 在线跳过（68 套件，5.465 秒），App 195 报告/194 实际/1 在线跳过（20 套件，4.910 秒）。定向 16/2 通过。保留 runner 括号编译错误和 App 依赖创建顺序编译错误，均已修正。
- 真实 HTTPS/PostgreSQL 5/2（2.947 秒）：服务端提交后丢弃客户端解码结果，新 owner 用原操作重放，兑换 204×4、401×1、409×1，DB 7|3|0|0|3；自建资源已清理。
- 未新跑完整 UI/Gateway/headless 或真机 OS 后台/锁屏；暂停反馈/恢复入口及完整生命周期交互仍开放。B08 不关闭；47 项状态保持 16 已验证、31 开放。
- [合同](../device-revocation-runner-contract.md)；[证据](../../../docs/reviews/verification-records.md#20260907-revocation-runner)。

## 2026-09-07：B08 聚合状态与显式恢复

- 聚合流仅含 empty/pending/paused，原子订阅初始快照并合并通知。恢复保留 intent/op/attempts、不改普通退避，失败保留原任务；App 无变化重试也重建观察。
- 根界面显示等待、暂停或不可读取，重试单飞；退出文案与本地交接对齐。无障碍字号折叠说明，保留系统按钮、换行、leading 和本地化 API。
- ClientKit 442 报告/437 实际/5 跳过（69 套件，5.274 秒）；App 196 报告/195 实际/1 跳过（20 套件，4.708 秒），含真实 App/Keychain 暂停恢复和另一登录保护。
- 两项最终 UI 点击/审计和截图通过（6.347/6.806 秒）。初期启动参数未在截图显示最大字号/RTL，不能算对应证据；改用 DEBUG 显式环境后核实字号/镜像，并折叠说明、验证登录可触达。保留全部过程日志。
- 未新跑在线 HTTPS/PostgreSQL/Gateway/headless；不证明真机 VoiceOver、全语言翻译、系统后台或任意指令处强杀。其他旧启动参数测试需独立核实。B08 仍实施中，16 已验证、31 开放。
- [合同](../device-revocation-status-contract.md)，[证据](../../../docs/reviews/verification-records.md#20260907-revocation-status)。

## 2026-09-07：B08 签发取消与活动凭据替换

- 四个前置 await 返回后检查取消，已进入的操作保存允许完成并保留。URLSession 取消不再误报网络故障。原实现反例分别产生 14 和 1 个失败断言。
- 新登录替换不同账号/设备时，活动旧凭据也先保存撤销标记、入队再替换；队列失败不覆盖。原实现反例产生 4 个失败断言。
- 最终 ClientKit 444 报告/439 实际/5 跳过（70 套件，5.497 秒）；App 196 报告/195 实际/1 跳过（20 套件，5.168 秒）。真实 HTTPS/PostgreSQL 5/2（2.708 秒），DB 7|3|0|0|3，资源已清理；在线运行早于最后取消错误映射分支，最终离线回归覆盖该分支。
- 已发出请求的迟到或完全丢失响应仍无跨进程结果交接，不能靠一次内存清理回调宣称完成。未新跑 UI/Gateway/headless/真机。B08 保持实施中，16 已验证、31 开放。
- [合同](../credential-issuance-boundaries-contract.md)，[证据](../../../docs/reviews/verification-records.md#20260907-issuance-boundaries)。


## 2026-09-07：B08 已收到签发结果的持久交接

- HTTP issuer 必须注入结果恢复存储；返回登录凭据前写入仅含撤销能力的 Keychain 中间记录。正常接管最后清除，取消/epoch 失效先检查实际持久所有权，再完成接管或转交独立撤销队列。
- App 冷启动对照真实凭据恢复；abandoned 交接失败可由前台/手动重试继续，既有撤销操作、尝试次数、暂停和退避不重置。凭据保存结果不确定的 awaitingAdoption 记录仍需冷启动核对。
- ClientKit 452 报告/447 实际/5 在线跳过（71 套件，5.940 秒）；App 197 报告/196 实际/1 在线跳过（20 套件，4.913 秒），含真实模拟器 Keychain 与重新创建 App 的两种接管状态。xcresult 首次导出受沙箱文件权限限制，随后授权导出成功；测试本身通过。
- 最后在线夹具改用生产恢复 actor 与内存持久适配器，真实 HTTPS/PostgreSQL 5/2（2.648 秒）验证返回前有记录、正常完成后移除且无误撤销。DB 7|3|0|0|3，能力兑换 204×4、401×1、409×1；自建临时资源已独立核实移除。
- 未收到响应、首次中间记录落盘失败、任意 SDK 并行共享注册身份及真正逐指令强杀仍不能据此宣称全部恢复。未新跑 UI/Gateway/headless/真机。B08 保持实施中；47 项状态为 16 已验证、31 开放。
- [合同](../received-credential-recovery-contract.md)，[证据](../../../docs/reviews/verification-records.md#20260907-issued-result-recovery)。


## 2026-09-07：B08 注册取消的服务端仲裁

- 新独立用途证明绑定 device/operation/issue-before，服务端只保存带用途域的摘要。新可取消注册入口先取得证明锁，再取得账号/设备锁；未签发取消留墓碑，已签发取消原子终止设备、access/refresh、Push 和事件。
- 截止在设备行锁取得后判断；真实持锁等待并推进测试时钟，验证不能越过签发截止或误在已结束会话上提交撤销。换秘密/设备/操作/截止不能取消或重放原会话，首次绑定和最终撤销故障均整体回滚。
- PostgreSQL 28→29 迁移保留既有凭据、不补造历史证明；启动检查验证精确约束及唯一绑定索引。七条旧迁移链追加新迁移，原有17项及新增4项真实数据库回归，共21项/1套件（28.843秒）通过，包含7个新增参数场景。
- Core 95项/31套件（0.006秒）通过；原有凭据与撤销HTTP单元10项/2套件（0.009秒）通过。首次服务端编译过滤器没有匹配测试，仅作为编译记录，不计入测试证据。
- 原HTTP/App尚未使用新域入口；下一步强制HTTP签发证明、增加受保护的取消路由并接通请求前持久化和恢复队列。新增表尚未启用GC，保留合同与真机/系统中断继续开放。B08保持实施中，仍16项已验证、31项开放。
- [合同](../registration-cancellation-contract.md)，[证据](../../../docs/reviews/verification-records.md#20260907-registration-cancellation)。

- 本批补充现有真实 HTTPS/原生账号服务回归 5项/2套件（2.743秒），DB 7|3|0|0|3；当前仍走原HTTP入口，只证明schema-29未破坏已有链路。各自独立数据库及证书根目录均已核实移除。未新跑App UI/Gateway/headless/真机。


## 2026-09-07：B08 注册取消 HTTP 与客户端传输

- 新取消路由接入账号服务生产组装与地址限流，只接受严格四字段 JSON、上限1KiB；不接受userID或普通账号令牌作为取消权限。客户端只携带原证明，保留取消/网络失败/限流，区分204完成与410期限结束。
- ClientKit完整回归458报告/453实际/5在线跳过，72套件（5.039秒）；服务端HTTP单元13项/3套件（0.010秒）。新增数据库测试的限流密钥初始化标签错误已修正，保留首次失败编译日志。
- 真实PostgreSQL22项/1套件（29.356秒）通过，覆盖可信边界、实际限流、取消先到后的签发拒绝、签发后HTTP撤销及503整体回滚；原有仲裁和迁移回归保留。
- 真实HTTPS5项/2套件（2.685秒），取消204×2、410×1、400×1；提交后丢弃客户端结果，用原证明重放，数据库取消总数/绑定账号/取消数1|0|1，设备计数7|3|0|0|3。在线夹具补充在完整离线回归之后，生产代码未变；不是物理断包或跨进程持久队列证据。
- HTTP签发仍未强制证明，App还没有请求前保存及独立取消队列。未新跑App/UI/Gateway/headless/真机；自建数据库与证书已清理。B08保持实施中；全部47项仍16已验证、31开放。
- [合同](../registration-cancellation-http-contract.md)，[证据](../../../docs/reviews/verification-records.md#20260907-registration-cancellation-http)。


最新补充（2026-09-07，B08 签发证明绑定）：[请求前持久化与强制 HTTP 绑定](../proof-bound-issuance-contract.md)已实现，注册 ledger 升为 format 2；缺少或不匹配确认会先交接收到的撤销能力再拒绝登录，旧记录保留档案，过期尝试保留证明并换用新身份。客户端 **462 项报告 / 457 项实际执行**、接口 **14 项**、真实 PostgreSQL **22 项**、App **197 项报告 / 196 项实际执行**通过；最终真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过。数据库设备/撤销/残留访问/残留刷新/事件为 **16|7|0|0|7**，取消记录总数/绑定/取消为 **17|16|2**；独立补偿允许多个操作指向同一已撤销设备，事件仍不重复。脚本调用同步补齐证明，Compose 栈脚本只做语法及共用工具离线检查。初始解码错误、旧 UI 夹具和旧统计假设的失败均留档；最终专用资源已移除。见[证据](../../../docs/reviews/verification-records.md#20260907-proof-bound-issuance)。自动取消执行器、冷启动请求前证明归属、旧会话清理和真机系统中断仍开放；47 项仍为 **16 已验证、31 开放**，B08 不关闭。


最新补充（2026-09-07，B08 遗弃注册自动取消）：[执行器与冷启动归属](../registration-cancellation-runner-contract.md)已接入 App。format 3 原子迁移旧证明并保存尝试次数、退避和暂停，冷启动只把未被当前持久凭据接管的 pending 入队；前台观察自动执行，后台取消并等待实际请求结束，清理反馈和手动重试覆盖两类队列。客户端 **472 项报告 / 467 项实际执行**、签名 App **199 项报告 / 198 项实际执行**通过；真实 Keychain 验证归属及暂停反馈。真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过，验证签发和取消响应相继丢失后仍使用原证明重试。数据库 **16|7|0|0|7**，取消记录 **17|16|2**，取消 HTTP 204 四次但记录不重复；专用资源已清理。见[证据](../../../docs/reviews/verification-records.md#20260907-registration-cancellation-runner)。旧会话/legacy 档案清理、真实强杀/锁屏/系统后台和记录 GC 仍开放；B08 保持实施中，全部 47 项仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 实际进程中断）：[真实 App 两次终止后恢复](../registration-process-interruption-contract.md)已通过。HTTPS 代理在服务端签发/取消分别提交后保留响应，受控终止专用模拟器里的 App；第二次重启从真实 Keychain 使用原证明重放，并完成新设备登录。原设备单独核对 **2|1|1|1|0|0**（账号设备数/原设备撤销/证明取消记录/事件/有效 access/有效 refresh）；没有重复事件。同期修复命令行证明将 DeviceID 误编码为字符串的问题，真实凭据准备脚本的签发、鉴权和取消通过。最终 **5 项原生 HTTPS、3 项 App UI、1 项独立后台入口**通过，全库 **19|9|0|0|9**、取消记录 **20|19|4**。见[证据](../../../docs/reviews/verification-records.md#20260907-registration-process-interruption)。这是 simctl 受控进程终止，不等同于 SIGKILL/OS jetsam/真机锁屏；legacy 清理及其他检查点仍开放。47 项仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 旧档案服务端仲裁）：[账号范围的持久取消](../legacy-registration-arbitration-contract.md)已实现，PostgreSQL 更新为 **30**。取消与签发共用账号/注册锁，原子撤销已签发会话并拒绝同账号迟到签发；其他账号不受旧 ID 阻断。真实 PostgreSQL **26 项 / 1 套件（32.416 秒）**通过，覆盖新增四项隔离、回滚、并发和配额测试及七条历史迁移链；29→30 保留凭据、约束正反向门禁通过。HTTP 单元 **14 项 / 3 套件（0.011 秒）**、原生 HTTPS **5 项 / 2 套件（2.729 秒）**通过，数据库 **8|4|0|0|4**，注册取消记录 **9|8|2**。首次新增测试未清理 schema，导致后续测试初始化失败；修正成功/失败清理后全组通过，失败日志保留，早先回滚通过的过早进度说明已纠正。三个专用资源根目录已独立确认移除。见[证据](../../../docs/reviews/verification-records.md#20260907-legacy-registration-arbitration)。尚未提供 legacy HTTP 入口或 ClientKit/App 清理接线，启用前必须停止旧签发进程；本批未新跑 App/UI/Gateway/headless/真机。47 项仍 **16 已验证、31 开放**，B08 不关闭。


最新补充（2026-09-07，B08 旧档案 HTTP）：[账号证明与受保护清理入口](../legacy-registration-http-contract.md)已接入生产 Account 组装及地址限流。严格四字段、UUID、新旧设备不同及证明边界先于域调用；真实 HMAC 验证与 18 项接口测试 / 4 套件（0.012 秒）通过。真实 HTTPS 基线 5 项 / 2 套件（2.691 秒）通过，新增扩展使用真实密码因子验证 503 整体回滚、204 幂等、同一证明新设备签发、迟到签发 403、另一账号隔离 404 及容量 507/原操作 204；仅记录目标计数，不保存密码或令牌。扩展在基线统计后执行，另增 3 个设备、1 条撤销事件和 256 条账号范围取消记录（254 条为配额种子）。相邻 PostgreSQL 与七条历史迁移链共 26 项 / 1 套件（30.563 秒）通过，三个专用资源根目录已独立核实移除。首轮扩展把既有签发 403 错写为 401，修正预期后完整通过，失败日志保留。见[证据](../../../docs/reviews/verification-records.md#20260907-legacy-registration-http)。ClientKit/App 的旧档案 CAS 与登录接线尚未完成，本批未新跑 App/UI/Gateway/headless/真机；schema 30、protocol 27、SQLite 173/5 不变，仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 旧档案客户端恢复）：[ClientKit/App 登录接线](../legacy-registration-client-recovery-contract.md)已实现，同一次账号因子先清理、完整本地确认后再签发。失败保留，完整注册尝试和旧档案 CAS 防止迟到确认；一个恢复专用位置解决 256 条旧档案满额时无法创建清理尝试的问题。最终 ClientKit 480 项报告 / 474 项实际 / 6 项在线跳过（76 套件，6.167 秒），签名 App 200 项报告 / 199 项实际 / 1 项在线跳过（21 套件，5.143 秒）通过。真实 HTTPS 5 项 / 2 套件（2.714 秒）、新增旧档案恢复 1 项 / 1 套件（1.556 秒）、App UI 2 项（64.579 秒）、后台入口 1 项（1.323 秒）通过。数据库 18|8|0|0|8，注册取消记录 19|18|2，无旧有效凭据残留或重复事件。三套件并行触发两个密码 worker 的 503，首次分组仍带入第三套件；最终拆为独立文件顺序运行，两轮失败留档。三个临时根目录和一个模拟器已独立核实移除。见[证据](../../../docs/reviews/verification-records.md#20260907-legacy-registration-client)。真实 HTTPS 的 owner 重建使用内存持久适配器，真实 Keychain 单独验收；不替代实际 App legacy 跨进程、旧二进制升级或真机锁屏/系统后台验收。B08 仍实施中，全部47项保持 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 实际 App 旧档案恢复）：[跨进程清理检查点](../legacy-registration-app-process-contract.md)已通过。真实签发的旧设备/原操作以 format 1 写入隔离 Keychain，清理提交后代理不转发响应并受控终止 App；不带种子参数的重启从真实档案重放，新证明绑定新设备，登录后再次冷恢复仍保持新会话。目标数据库核对 **2|1|1|1|0|0|0|1**，旧设备只有一条取消记录和撤销事件，无有效 access/refresh；首次准备设备未签发且已持久取消。真实 HTTPS **5 项（2.717 秒）**、App UI **3 项（104.240 秒）**及后台入口 **1 项（1.289 秒）**通过，全库 **18|8|0|0|8**、注册取消记录 **20|18|3**。签名 App 全量 **201 项报告 / 200 项实际 / 1 项跳过**通过（22 套件，5.063 秒），新增测试验证夹具要求隔离域、拒绝覆盖、清理不影响未加测试域的 Keychain。专用数据库根与模拟器已独立核实移除。见[证据](../../../docs/reviews/verification-records.md#20260907-legacy-app-process)。这验证受控 simctl 终止和明确构造的旧格式数据，不是旧二进制升级、SIGKILL/OS jetsam、掉电或真机锁屏验收；其他检查点、永久冲突与 GC 仍开放。全部47项保持 **16 已验证、31 开放**。


最新补充（2026-09-07，B01 服务端时钟）：[账号证明与 Gateway 时钟边界](../server-clock-integer-boundaries.md)已补检查；独立进程复现 NaN 转 Int64 fatal error 后，新增非有限值、有效期相加越界和不可用编码截止的拒绝。Hello 在状态变更前检查，心跳覆盖异步准入后再次失效并释放请求关联；凭据接口将时钟故障返回为空正文、不缓存的 503，修复前错误 401 的三条失败断言留档。最终服务端 **57 项 / 7 套件（6.387 秒）**、真实 HTTPS **5 项 / 2 套件（2.734 秒）**、App UI **2 项（64.268 秒）**、独立后台入口 **1 项（1.298 秒）**通过。数据库 **16|7|0|0|7**、注册取消记录 **17|16|2**，专用数据库根与模拟器已独立核实移除。见[证据](../../../docs/reviews/verification-records.md#20260907-server-clock-boundaries)。这不是远端可控时间戳攻击的证明；其余恢复 DTO、计数和时间消费者继续审计，B01 仍实施中，全部47项保持 **16 已验证、31 开放**。

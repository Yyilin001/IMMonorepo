# 服务端验收问题修复 · 2026-10-22

状态：已发现的代码、脚本和夹具问题已修复，本地复验完成；生产专项仍有未验证项。原始失败记录保留于 [首次验收报告](server-functional-acceptance-2026-10-22.md)，不以本文件覆盖或删除历史失败证据。

本次不提供历史兼容层。生产授权、持久化、容量与租约围栏保持严格；夹具必须满足当前合同，不能用放宽生产检查使测试通过。

## 修复内容与已取得证据

| 问题 | 修复 | 实际验证 |
| --- | --- | --- |
| Supervisor 在取消后的关闭路径中提前报告 incompleteShutdown | PlacementControlRuntime 在关闭准入后持有并等待独立排空任务；保留原截止时间及失败语义 | 取消关闭调用方的原生 mTLS 生命周期回归通过；真实 Linux Supervisor 重启、Host 强杀接管和 generation replacement 全部通过 |
| 默认 Linux 测试栈 PostgreSQL 资源和 Account 启动窗口不足 | 测试脚本显式配置 PostgreSQL 512 PID/3 GiB、Account 120 秒健康检查启动期 | 使用修改后的默认脚本运行完整业务冒烟、忙碌发送 SIGTERM、跨入口禁号，均通过；这些是本地测试预算，不是生产容量结论 |
| Actor 序列化门禁命中部署 JSON | 将离线信任授权配置编排移入 ActorApplication，工具和测试依赖随之调整 | Actor 序列化和服务端边界门禁通过；授权编排七组场景通过，无新增规则豁免 |
| 逻辑恢复脚本引用已退役表 | 使用当前个人事件审计事实，比较完整审计行、表计数和当前 schema 合同 | 实际 Docker PostgreSQL dump/restore 通过 |
| Protobuf 生成物不一致 | 按仓库生成器重新生成公共及 Actor 生成物 | 两套生成一致性检查通过；Linux 七个服务/探针产品构建通过 |
| 合同索引遗漏文档 | 登记 11 份文档，并保留当前合同与历史证据分类 | 文档结构与链接检查通过 |
| TCP 夹具错误使用每房间 Host incarnation、旧地址编码 | 同 Host 的房间复用 incarnation，使用正式 Protobuf 地址解码，安装真实设备投递会话 | TCP 与 mention 定向 10 项通过 |
| 回执、容量、自退出测试使用旧预期 | 区分 activationChanged 与 ownerChanged、使用 roomCapacityExhausted、明确允许成员自己退出 | 查询/回执/成员定向 13 项通过 |
| 发送/转发/媒体夹具缺少真实策略授权与资源状态 | 经过真实 Policy Owner、精确 activation token；媒体走创建、完成、发布、扫描生命周期 | 额外故障/跨 Owner 等 20 项通过 |
| 原生串行执行下的并发测试等待错误 SQL 条件 | 保留首个 SQL 屏障，使用实际 Host 命令准入数观察排队 | 邀请竞争及编辑权限竞争共 25 组参数场景通过 |
| 提交后强杀测试错误重建整个 placement 控制面 | 同一持久控制面下替换物理 Host incarnation | 两组提交后真实子进程强杀场景通过，activation epoch 严格增长 |
| 十万成员建群统计引用退役表 | 检查退役表不存在，保留十万成员、发现事件及回执断言 | 显式开启建群测试通过，Debug 实测约 565.9 秒，不作为生产延迟 SLO |
| 十万成员发送夹具只有成员关系、没有账户事实 | 补齐十万份账户资料，继续经过真实策略授权；新增成员/消息/事件计数断言 | 新二进制显式开启测试通过，十万成员普通发送及 mention 均通过，计数断言通过 |

Core 回归已通过：Swift Testing 177 项、XCTest 5 项。不同定向测试之间可能重叠，不能将上表数字相加作为独立覆盖数。

## 真实进程证据

证据根目录：`/Users/yyl/.codex/virtual-actor-builds/`。

| 运行 | 结果文件 | 核对的事实 |
| --- | --- | --- |
| 独立 VM 强杀 | `remediation-20261022-native-crash/result.json` | passed、crashTakeoverVerified、generationReplacementVerified、generationRetentionVerified、supervisorRestartResumed 均为 true；网络失联未授予所有权；消息行数为 1 |
| 忙碌发送 SIGTERM | `remediation-20261022-busy-runs/run-0364c95a85c2408395afa747b544e65a/result.json` | Actor 退出码 0；epoch 从 2 到 3；原 Gateway 保留；重放 message ID 与原消息相同 |
| 跨入口账户禁用 | `remediation-20261022-cross-entry-runs/run-9c35ea40ca48448c98b9799810407538/result.json` | 原 Gateway 与 Actor Host 保留；既有连接发送和读取均拒绝；禁用后无新增消息 |

临时强杀 VM 已删除，原 `imv2-tests` VM 已恢复停止，Docker context 已恢复 `default`。数据库集成任务全部结束，各运行器已清理其数据库；数据库目录查询确认没有本轮 `imv2_extra_` 测试库残留。

## 尚未闭环

- 完整服务端命令已结束，退出码 0，七个目标的框架汇总共 2,307 项。不过存在 115 个显式跳过项，比首次验收多 73 项：本轮运行器遗漏了资源及 Host 专用数据库配置。随后对对应文件补跑，77 项测试通过，逐项匹配确认全部 73 个新增跳过项都有通过证据；没有用跳过代替通过。两个容量用例在默认运行中提前返回，单独显式开启的建群与发送均已通过。
- 新增双方并发好友申请、旧置顶重放后当前基线、路径型存储句柄拒绝场景已通过，共 3 项测试、10 组参数场景。
- 生成部署配置的 5 项测试通过；信任授权工具原生输出、运行时加载、集群成员变更等另外 5 项测试通过。
- 文件句柄矩阵验证应用输入边界，不能据此宣称已验证拥有本地目录写权限者制造符号链接的场景。
- 原验收项中的好友申请撤回、清空公告及普通 HTTPS 发送，应按实际枚举、输入合同和路由装配核定支持范围，不能将未实现入口算作通过。
- 真实 APNs、生产扫描器/对象存储/CDN、目标负载与 P95/P99、长稳态、WAL/PITR 和 RPO/RTO 尚无本轮证据；本地功能修复不替代这些生产验证。

已结束的 48 份日志、结果及核对记录归档于 `/Users/yyl/.codex/verification/imv2-server-remediation-20261022/`，`terminal-evidence-manifest.json` 保存文件大小与 SHA-256。该清单标记为本地修复验证已结束、外部验收仍开放，不包含部署私钥。

运行器及过程检查点保留于 `/tmp/imv2-remediation-20261022/`。失败的首次补跑日志也已归档：其原因为缺少第二数据库或资源库未预装 schema；补齐配置后重跑通过，不隐藏这些执行失败。

## 修复后逐项结论

原验收范围保持不变；“本地自动化通过”不等于生产发布通过。所有日志引用相对于上述修复证据归档目录。

本地自动化通过: 106 / 范围差异: 3 / 部分通过: 5 / 未验证: 2；共 116 项。

| 编号 | 功能 | 原验收范围 | 修复后状态 | 实际证据与限制 |
| --- | --- | --- | --- | --- |
| A01 | 密码注册 | 注册并发和身份唯一性 | 本地自动化通过 | “Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-full-tests.log:3594`)<br>“password registration writes a privacy-minimized audit fact atomically” (`server-full-tests.log:3630`) |
| A02 | 密码登录 | 错误密码、未知和禁用账户 | 本地自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-full-tests.log:2874`)<br>“Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-full-tests.log:3594`) |
| A03 | 密码输入边界 | 12/1024 字节、NUL 和字符原样保存 | 本地自动化通过 | “password fallback preserves all accepted UTF-8 bytes” (`server-full-tests.log:7649`)<br>“password fallback rejects embedded NUL before persistence” (`server-full-tests.log:7655`) |
| A04 | 密码安全存储 | Argon2id 验证记录和脱敏 | 本地自动化通过 | “Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-full-tests.log:3594`)<br>“password transport depends on a store capability and never passes plaintext to persistence” (`server-full-tests.log:7691`) |
| A05 | 登录限流与锁定 | 跨副本预算和锁定窗口 | 本地自动化通过 | “password fallback failure limits persist across account-service instances” (`server-full-tests.log:3628`)<br>“password attempt cleanup is bounded and preserves live windows, locks and rollback clocks” (`server-full-tests.log:4150`) |
| A06 | 密码计算过载 | KDF 容量及取消 | 本地自动化通过 | “saturated password work returns no-store 503 with a bounded retry” (`server-full-tests.log:7661`)<br>“real KDF burst sheds excess work and remains usable afterward” (`server-full-tests.log:7702`) |
| A07 | 修改密码 | 新旧认证状态及并发 | 本地自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-full-tests.log:2874`) |
| A08 | 离线恢复码 | 一次性兑换和会话失效 | 本地自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-full-tests.log:2874`) |
| A09 | 账户入口保护 | 可信入口和重复地址头 | 本地自动化通过 | “account routes reject a direct caller without the edge proof” (`server-full-tests.log:7666`)<br>“running edge requests reject duplicate fields and do not reuse another request's identity” (`server-full-tests.log:7682`) |
| A10 | 客户端地址限流 | 共享预算和地址隐私 | 本地自动化通过 | “account edge limits only an authenticated Caddy-derived client address” (`server-full-tests.log:7670`)<br>“account-edge limiter preserves an allowed route's client status” (`server-full-tests.log:7673`) |
| A11 | 设备凭据签发 | 断言有效期及身份绑定 | 本地自动化通过 | “new device issuance enforces active and durable account budgets” (`server-full-tests.log:4118`)<br>“trusted device registration and refresh rotation are durable, replayable, and revoke on reuse” (`server-full-tests.log:4122`) |
| A12 | 签发重试与取消 | 响应丢失及取消竞争 | 本地自动化通过 | “registration cancellation proof has a distinct purpose and redacted diagnostics” (`core-tests.log:629`)<br>“registration cancellation HTTP commits the proof fence and rejects unsafe requests before storage” (`server-full-tests.log:3367`) |
| A13 | 凭据刷新 | 轮换、重复使用和并发 | 本地自动化通过 | “revoke-only capability survives rotation, isolates sessions and commits atomically” (`server-full-tests.log:3388`)<br>“absolute device expiry bounds rotations, replay, authentication and Push eligibility” (`server-full-tests.log:4120`) |
| A14 | 会话绝对期限 | 刷新、Push 和资源不越过期限 | 本地自动化通过 | “absolute device expiry bounds rotations, replay, authentication and Push eligibility” (`server-full-tests.log:4120`) |
| A15 | 设备会话列表 | 本人设备分页 | 本地自动化通过 | “device sessions paginate metadata and revoke remote installations with bounded SQL” (`server-full-tests.log:4126`)<br>“Session inventory clocks reject unsafe queries and preserve normal pagination” (`server-full-tests.log:4279`) |
| A16 | 本机退出撤销 | 专属撤销凭据隔离和重放 | 本地自动化通过 | “revoke-only capability survives rotation, isolates sessions and commits atomically” (`server-full-tests.log:3388`) |
| A17 | 远程设备撤销 | 基线、目标范围、原操作恢复 | 本地自动化通过 | “device sessions paginate metadata and revoke remote installations with bounded SQL” (`server-full-tests.log:4126`) |
| A18 | 撤销实时生效 | 多 Gateway 连接及排队帧失权 | 本地自动化通过 | “bootstrap order, duplicate ids and device revocation fail closed” (`core-tests.log:661`)<br>“readiness rejects any loss of the revocation commit-order fence” (`server-full-tests.log:1790`) |
| A19 | 账户禁用 | 签发、会话、业务和审计 | 本地自动化通过 | “Account disable validates required revision changes without suppressing inactive-profile results” (`server-full-tests.log:2335`)<br>“Account disable returns its database commit timestamp consistently on first response and replay” (`server-full-tests.log:2337`) |
| B01 | 精确身份发现 | 发现证明和设备绑定 | 本地自动化通过 | “exact handle lookup requires device credentials and returns no-store profile facts” (`server-full-tests.log:9589`)<br>“unknown and hidden identities share the same not-found response” (`server-full-tests.log:9592`) |
| B02 | 本人资料更新 | 字段更新和版本 | 本地自动化通过 | “profile field patches keep unchanged, removal and replacement distinct” (`core-tests.log:739`)<br>“Directory profile propagation copies the exact persisted update timestamp” (`server-full-tests.log:3443`) |
| B03 | 资料操作恢复 | 提交与关闭串行化 | 本地自动化通过 | “profile receipt bindings cannot confuse actors or payloads after Codable roundtrip” (`core-tests.log:725`)<br>“Profile patches retain unrelated fields and replay the original receipt after later commits” (`server-full-tests.log:3445`) |
| B04 | 资料读取授权 | 上下文和缓存授权 | 本地自动化通过 | “group presentation binds viewer, resource generation and independent byte/display deadlines” (`core-tests.log:772`)<br>“presentation leases are viewer/context scoped and cannot exceed five minutes or overflow” (`core-tests.log:664`) |
| B05 | 好友申请 | 重复及双方并发申请 | 本地自动化通过 | coverage-gaps-recheck-tests.log：双方冻结相同关系版本并发申请，单一 pending、冲突回执及后续接受后原结果重放通过。 “Concurrent relationship and block retries retain one transition at the final policy revision” (`server-full-tests.log:3112`)<br>“relationship and block mutations are durable, private, and synchronize both sides” (`server-full-tests.log:3889`) |
| B06 | 好友关系流转 | 接受、拒绝、撤销、删除 | 范围差异 | 当前枚举支持 request/accept/reject/remove；没有独立 cancel 动作。已实现操作通过，不将原“撤销申请”范围算作已实现。 “relationship and block mutations are durable, private, and synchronize both sides” (`server-full-tests.log:3889`)<br>“social mutations require policy owners and replay their committed result without legacy authorization” (`server-full-tests.log:4197`) |
| B07 | 屏蔽与解除 | 消息和关系准入 | 本地自动化通过 | “confirmed replies omit stranger dependencies while current blocks still deny” (`server-full-tests.log:2022`)<br>“direct forward imports enforce control blocks and preserve terminal replay” (`server-full-tests.log:2345`) |
| B08 | 联系人同步 | 个人关系投影及重连 | 本地自动化通过 | 关系投影/跨用户分片证据及 tcp-recheck.log 的重连恢复通过。 “direct and social sync records shadow to a forwarding user shard with their source sequence” (`server-full-tests.log:4148`) |
| B09 | 账户与会话偏好 | 幂等、版本及同步 | 本地自动化通过 | “Room-owned preferences retain original receipts, close atomically and fence stale intents” (`server-full-tests.log:2284`)<br>“Concurrent direct preference retries retain one policy transition and committed timestamp” (`server-full-tests.log:3128`) |
| B10 | 在线状态隐私 | 长期隐私和瞬时抑制 | 本地自动化通过 | “merged presence admission enforces concurrent user limits, expired replacement and privacy” (`server-full-tests.log:3883`)<br>“Presence responses validate the selected lease while preserving offline and hidden states” (`server-full-tests.log:4219`) |
| C01 | 创建和打开私聊 | 用户对唯一性及重试 | 本地自动化通过 | “Concurrent direct room opens serialize operation identity and reuse the original room timestamp” (`server-full-tests.log:3120`)<br>“Direct room creation validates persisted pair and profile timestamps” (`server-full-tests.log:4240`) |
| C02 | 私聊准入 | 身份、屏蔽、容量和原子性 | 本地自动化通过 | “plain durable direct send rejects a third member without publishing provisional writes” (`server-full-tests.log:2069`)<br>“Direct room and preference timestamps are rejected before durable writes” (`server-full-tests.log:3324`) |
| C03 | 陌生人消息 | 窗口配额和接收偏好 | 本地自动化通过 | “full cohort preserves first producers, reciprocal replies and cumulative stranger quota” (`server-full-tests.log:2006`)<br>“confirmed replies omit stranger dependencies while current blocks still deny” (`server-full-tests.log:2022`) |
| C04 | 创建群聊 | 初始成员、房间和跨库恢复 | 本地自动化通过 | capacity-tests.log、extra-recheck-tests.log 对应原失败场景复验通过。  “Group creation proof and owner facts share the committed millisecond time” (`server-full-tests.log:3160`)<br>“Group creation rejects invalid clocks before writes and replays permanent proof without a fresh clock” (`server-full-tests.log:3322`) |
| C05 | 增加成员 | 授权、容量和版本 | 本地自动化通过 | tcp-recheck.log、contract-recheck.log 对应原失败场景复验通过。  “canonicalizes the initial membership order” (`core-tests.log:748`)<br>“originalConfirmationAndMembershipAreFrozen()” (`core-tests.log:697`) |
| C06 | 移除与退出 | 角色约束及即时失权 | 本地自动化通过 | contract-recheck.log、tcp-recheck.log 对应原失败场景复验通过。  “member removal installs its committed cut without a postcommit database read” (`server-full-tests.log:1336`)<br>“membership removal preserves self-exit and management boundaries” (`server-full-tests.log:3898`) |
| C07 | 退出后重入 | 历史可见性 | 本地自动化通过 | “forward requires the current content version audience after rejoin” (`server-full-tests.log:3266`)<br>“room-log edit replacement bridges rejoin without exposing absent revisions” (`server-full-tests.log:3533`) |
| C08 | 成员目录 | 稳定分页和读取权限 | 本地自动化通过 | “one SQL returns membership, routes and generation; empty and filtered pages retain exact scan position” (`server-full-tests.log:29`)<br>“cold, hot, sparse and broad memberships use actual bounded directory/state reads” (`server-full-tests.log:1780`) |
| C09 | 角色与权限 | 角色版本及权限基线 | 本地自动化通过 | “role policy is version-fenced and cannot mutate owner authority” (`core-tests.log:643`)<br>“membership identity, actor role, cursor, role baseline and user-room topology survive” (`server-full-tests.log:5398`) |
| C10 | 禁言与冻结 | 并发提交权限 | 本地自动化通过 | ordering-tests.log 对应原失败场景复验通过。  “only room owner or admin can moderate and mute expiry must be future” (`core-tests.log:716`)<br>“mute authorization rejects nonfinite clocks and expiry” (`core-tests.log:700`) |
| C11 | 群公告 | 版本、清除、幂等和权限 | 范围差异 | 公告 body 非可选且拒绝空白；发布、更新、幂等和权限通过，原“清除公告”不属于当前成功操作。 “announcement and role changes reject unsafe shapes” (`core-tests.log:650`)<br>“group capabilities fence the selected owner before writes and operation replay” (`server-full-tests.log:3811`) |
| C12 | 消息置顶 | 逆序、取消及快照 | 本地自动化通过 | coverage-gaps-recheck-tests.log：取消置顶后重放原置顶回执，当前 pinnedBaseline 仍为取消且保留新序号。 “group capabilities fence the selected owner before writes and operation replay” (`server-full-tests.log:3811`) |
| C13 | 群头像 | 资源绑定、恢复和授权 | 本地自动化通过 | “home derives from authenticated actor for avatars and the explicit room for attachments” (`core-tests.log:686`)<br>“only the current structural owner can bind an eligible room avatar” (`omitted-coverage-recheck-tests.log:126`) |
| C14 | 成员操作恢复 | Owner 围栏及原结果 | 本地自动化通过 | “typed membership preserves selected owner epochs and original receipts” (`server-full-tests.log:3823`)<br>“never serves a stale membership epoch or an unknown sequence gap” (`server-full-tests.log:6177`) |
| D01 | 创建邀请 | 稳定身份、期限和链接 | 本地自动化通过 | “twenty exhausted invitation links no longer occupy creation quota” (`server-full-tests.log:2906`)<br>“Invite creation clocks retain recoverable work and preserve published bindings” (`server-full-tests.log:3662`) |
| D02 | 邀请失效 | 次数、到期和撤销 | 本地自动化通过 | “Invite response states and existing-member submissions agree with the persisted expiry” (`server-full-tests.log:4657`) |
| D03 | 提交入群申请 | 重复申请和配额 | 本地自动化通过 | “different rooms and invites share one atomic applicant limit” (`server-full-tests.log:64`)<br>“same applicant cannot overbook the last local quota slot across different invites” (`server-full-tests.log:2892`) |
| D04 | 全局申请配额 | 跨 Owner 并发 | 本地自动化通过 | “different rooms and invites share one atomic applicant limit” (`server-full-tests.log:64`)<br>“same applicant cannot overbook the last local quota slot across different invites” (`server-full-tests.log:2892`) |
| D05 | 申请分页与取消 | 稳定分页和终态竞争 | 本地自动化通过 | “pending request cursors survive review and deletion across PostgreSQL timestamp ranges” (`server-full-tests.log:2904`)<br>“applicant cancellation preserves decisions, releases quota, and serializes with approval” (`server-full-tests.log:3879`) |
| D06 | 批准与拒绝 | 权限及成员配额原子提交 | 本地自动化通过 | ordering-tests.log 对应原失败场景复验通过。  “join request exposes a resume operation only while approval is in progress” (`core-tests.log:733`)<br>“approval rolls back every owner effect at each late failure and replays the committed decision” (`server-full-tests.log:2886`) |
| D07 | 邀请故障恢复 | 目录补偿和 Owner 路由 | 本地自动化通过 | “Invite creation clocks retain recoverable work and preserve published bindings” (`server-full-tests.log:3662`)<br>“invite directory survives owner response loss and finalize failure across databases” (`server-full-tests.log:3831`) |
| E01 | 基础发送 | ACK、持久消息和回执 | 本地自动化通过 | “durable send batch isolates invalid content and preserves neighbouring receipts” (`server-full-tests.log:2063`)<br>“current durable group turns preserve sequence, completion and readable projection” (`server-full-tests.log:3851`) |
| E02 | 双通道发送 | 跨 TCP/HTTPS 同身份重试 | 范围差异 | 当前未挂载普通消息 HTTPS 发送入口；TCP 发送与恢复已验证，不能宣称双通道普通发送通过。 |
| E03 | 发送结果未知 | 提交结果恢复 | 本地自动化通过 | extra-recheck-tests.log、commit-crash-tests.log 对应原失败场景复验通过。  “send execution v1 recovers committed results and leaves absent identities retryable” (`server-full-tests.log:2272`)<br>“native sender rejects stale data owners and recovers the durable result” (`server-full-tests.log:2317`) |
| E04 | 幂等身份冲突 | 重复和冲突载荷 | 本地自动化通过 | “batch rollback recomputes fingerprint conflicts and retains committed conflicts” (`server-full-tests.log:2083`)<br>“send completion retains original fingerprint and metadata after content mutation/deletion” (`server-full-tests.log:2911`) |
| E05 | 消息顺序 | 并发持久顺序 | 本地自动化通过 | “User sequence exhaustion preserves committed sends and recoverable private hints” (`server-full-tests.log:3147`)<br>“current durable group turns preserve sequence, completion and readable projection” (`server-full-tests.log:3851`) |
| E06 | 输入与引用校验 | 非法消息和资源引用 | 本地自动化通过 | “durable send batch isolates invalid content and preserves neighbouring receipts” (`server-full-tests.log:2063`)<br>“message media downloads validate room ownership and control-plane device authority” (`server-full-tests.log:3250`) |
| E07 | 回复与 mention | 引用可见性和提示 | 本地自动化通过 | tcp-recheck.log 对应原失败场景复验通过。  “message references require accepted and current content audiences” (`server-full-tests.log:3531`) |
| E08 | 编辑消息 | 作者、提交权限和并发 | 本地自动化通过 | ordering-tests.log 对应原失败场景复验通过。  “send and edit share current room publication authorization” (`server-full-tests.log:3928`) |
| E09 | 编辑可见性 | 历史授权及完整替换 | 本地自动化通过 | “edits keep durable identity and reject empty or oversized replacements” (`core-tests.log:734`)<br>“room-log edit replacement bridges rejoin without exposing absent revisions” (`server-full-tests.log:3533`) |
| E10 | 作者撤回 | 身份、重放及墓碑 | 本地自动化通过 | “long withdrawn tails report the production summary execution plan” (`server-full-tests.log:1322`)<br>“withdrawalResult(revision:sequence:)” (`core-tests.log:752`) |
| E11 | 表情回应 | 集合、授权和幂等 | 本地自动化通过 | “reaction input is normalized and set operations retain independent IDs” (`core-tests.log:753`)<br>“reaction original outcomes fence inverse intents and survive receipt rollback” (`server-full-tests.log:2055`) |
| E12 | 转发 | 源目标授权和部分失败恢复 | 本地自动化通过 | extra-recheck-tests.log 对应原失败场景复验通过。  “Ordinary and forwarded room-log messages match independent Python SHA-256 vectors” (`core-tests.log:729`)<br>“multi-forward remains bounded and preserves per-pair intent” (`core-tests.log:654`) |
| E13 | 已读回执 | 单调、并发、权限和恢复 | 本地自动化通过 | contract-recheck.log 对应原失败场景复验通过。  “read receipt is monotonic user state and never creates delivery work” (`server-full-tests.log:3936`)<br>“Read receipt preference revisions advance independently of time and preserve replay at exhaustion” (`server-full-tests.log:4236`) |
| E14 | 特殊账户策略 | 已开放账户类型策略 | 本地自动化通过 | “special account audit rejects stale data owners before replay or new audit writes” (`server-full-tests.log:2310`) |
| F01 | 房间历史增量 | 可见内容、分页和游标 | 本地自动化通过 | “actual room-log SQL bounds scans at first and middle pages despite sparse message-row storage” (`server-full-tests.log:2846`)<br>“room pulls intersect original and mutation visibility and advance hidden tails” (`server-full-tests.log:3544`) |
| F02 | 不可见事件扫描 | 扫描位置和不泄漏 | 本地自动化通过 | “room pulls intersect original and mutation visibility and advance hidden tails” (`server-full-tests.log:3544`) |
| F03 | 个人事件同步 | 有序、幂等及缺口恢复 | 本地自动化通过 | “Personal event operator replay is audited, bounded and fences previous leases” (`server-full-tests.log:3648`)<br>“direct imports recover a failed completion transaction without duplicating personal events” (`server-full-tests.log:3772`) |
| F04 | 房间目录与摘要 | 授权、分页和摘要游标隔离 | 本地自动化通过 | “summary restores only authorized content revisions across membership gaps” (`server-full-tests.log:323`)<br>“state and visible-summary batches scale with nonempty rooms” (`server-full-tests.log:1328`) |
| F05 | 多设备一致性 | 离线恢复和未订阅正文 | 本地自动化通过 | tcp-recheck.log 对应原失败场景复验通过。  “startup rejects device progress storage without its cursor constraint” (`server-full-tests.log:35`)<br>“device progress persists independently and out-of-order reports cannot regress” (`server-full-tests.log:37`) |
| F06 | 实时投递与补偿 | 丢提示、重连及 Relay 重建 | 本地自动化通过 | tcp-recheck.log、native-crash-result.json 对应原失败场景复验通过。  “coverage invalidation between Ready approval and write confirmation retains its boundary” (`server-full-tests.log:5151`)<br>“authentication starts owned coverage without waiting for temporary Owner admission or route recovery” (`server-full-tests.log:5206`) |
| F07 | 设备房间确认 | 设备绑定和撤销围栏 | 本地自动化通过 | “startup rejects device progress storage without its cursor constraint” (`server-full-tests.log:35`)<br>“device progress persists independently and out-of-order reports cannot regress” (`server-full-tests.log:37`) |
| F08 | Snapshot 创建与分页 | 固定基线和有界分页 | 本地自动化通过 | “snapshot and log page each issue one statement with no transaction controls” (`server-full-tests.log:1876`)<br>“snapshotAndPageDoNotWaitForRoomWriteFence()” (`server-full-tests.log:1884`) |
| F09 | Snapshot ACK | 设备隔离和激活 | 本地自动化通过 | “staleSnapshotAcknowledgementCannotAdvanceCursor()” (`core-tests.log:684`)<br>“matchingSnapshotAcknowledgementMovesOnlyThePendingGeneration()” (`core-tests.log:685`) |
| F10 | 快照与增量衔接 | 并发变化下无缺口 | 本地自动化通过 | “snapshot V3 resumes page-by-page, publishes immediately, and GC preserves active baselines” (`server-full-tests.log:4144`)<br>“matchingSnapshotAcknowledgementMovesOnlyThePendingGeneration()” (`core-tests.log:685`) |
| F11 | 日志裁剪 | 保留边界和慢设备恢复 | 本地自动化通过 | “summary edit audiences survive actual room-log retention” (`server-full-tests.log:2300`)<br>“retention bounds batches across rooms and tied sequences while preserving protected bodies” (`server-full-tests.log:2302`) |
| F12 | 权限与角色基线 | 空集合、逆序和重入 | 本地自动化通过 | “complete effective policies preserve explicit empty sets and zero room sequence” (`core-tests.log:693`)<br>“membership identity, actor role, cursor, role baseline and user-room topology survive” (`server-full-tests.log:5398`) |
| F13 | 账户成员覆盖 | 共享初始化和定向刷新 | 本地自动化通过 | tcp-recheck.log 对应原失败场景复验通过。  “committed membership joins and exits update account routes without another directory scan” (`server-full-tests.log:2143`)<br>“revocation history overflow retires coverage and releases all Owner references” (`server-full-tests.log:5145`) |
| F14 | 大群授权分段 | 不完整授权拒绝和边界 | 本地自动化通过 | “baseline gaps and repeated members never authorize a device” (`server-full-tests.log:6708`)<br>“segmented group authorization stays closed until the final page” (`server-full-tests.log:6713`) |
| G01 | 上传授权 | 身份、用途及大小 | 本地自动化通过 | “home derives from authenticated actor for avatars and the explicit room for attachments” (`core-tests.log:686`)<br>“current upload targets preserve identity, validate adapters and recheck authority after signing” (`omitted-coverage-recheck-tests.log:367`) |
| G02 | 上传传输 | 中断、重复和非法长度 | 本地自动化通过 | “ready requires a completed upload and a bind deadline; cancelled sessions cannot masquerade as ready” (`core-tests.log:678`)<br>“upload decoding cannot bypass size, MIME, checksum or negotiated mode validation” (`core-tests.log:698`) |
| G03 | 上传恢复与关闭 | 原操作结果和取消竞争 | 本地自动化通过 | “ready requires a completed upload and a bind deadline; cancelled sessions cannot masquerade as ready” (`core-tests.log:678`)<br>“Media responses retain the database deadline on first issue and upload replay” (`server-full-tests.log:3083`) |
| G04 | 消息资源绑定 | 合法资源和消息原子性 | 本地自动化通过 | “media becomes referenceable only after a successful scan” (`core-tests.log:618`)<br>“an attachment-only message retains its opaque references” (`core-tests.log:608`) |
| G05 | 下载授权 | 当前及历史权限 | 本地自动化通过 | extra-recheck-tests.log 对应原失败场景复验通过。  “message media downloads validate room ownership and control-plane device authority” (`server-full-tests.log:3250`)<br>“room-log media grants revalidate historical content and provider completion” (`server-full-tests.log:3485`) |
| G06 | 文件读取边界 | 流式、路径和中断 | 部分通过 | coverage-gaps-recheck-tests.log：7 种路径句柄在读、写、检查、删除入口均拒绝。流式/中断证据通过；未验证本地目录写权限者制造的符号链接场景。 “signed HTTPS targets transfer exact bytes through the Vapor object edge” (`server-full-tests.log:9457`)<br>“running media edge flushes a buffered upload and streams back exact bytes” (`server-full-tests.log:9460`) |
| G07 | 跨 home 导入 | 保留、提交和释放恢复 | 本地自动化通过 | extra-recheck-tests.log、omitted-coverage-recheck-tests.log 对应原失败场景复验通过。  “cross-home import retains authorized source context and cannot reuse the source identity” (`core-tests.log:689`)<br>“import, truncate and deployment changes invalidate directory tokens” (`server-full-tests.log:1864`) |
| G08 | 资料与头像资源 | 上下文及缓存 lease | 本地自动化通过 | “group presentation binds viewer, resource generation and independent byte/display deadlines” (`core-tests.log:772`)<br>“presentation leases are viewer/context scoped and cannot exceed five minutes or overflow” (`core-tests.log:664`) |
| G09 | 衍生资源 | 结果绑定和失败恢复 | 本地自动化通过 | “isolatedAvatarProcessorProducesFixedMetadataFreePNGs()” (`server-full-tests.log:8391`) |
| G10 | 媒体扫描 | 正常、病毒及供应商失败 | 部分通过 | 本地扫描状态机、恶意样本及失败恢复通过；真实生产扫描供应商未验证。 “media becomes referenceable only after a successful scan” (`core-tests.log:618`)<br>“Scan publication and retry require an unexpired claim at SQL precision” (`server-full-tests.log:3214`) |
| G11 | 内容审核 | 持久任务和有序处置 | 本地自动化通过 | “Content review retry limits preserve decisions, pause policy and claim fencing” (`server-full-tests.log:2995`)<br>“Content review clocks preserve leases, retry recovery and durable decisions” (`server-full-tests.log:3668`) |
| G12 | 审核开关 | 禁用及已有任务边界 | 本地自动化通过 | “disabled content review creates no job for message acceptance or editing” (`server-full-tests.log:3732`) |
| G13 | 资源清理 | 有效引用保护和崩溃恢复 | 本地自动化通过 | “Media maintenance validates clocks and preserves scan, purge and retention state” (`server-full-tests.log:3689`)<br>“a signed local target stores, scans, downloads and purges opaque media bytes” (`server-full-tests.log:7283`) |
| H01 | Push 端点 | 设备绑定和加密 | 本地自动化通过 | “Push endpoint clock failures preserve state and completed version replays” (`server-full-tests.log:3693`)<br>“Push endpoint encryption is device-bound and late rejection cannot disable a fresh registration” (`server-full-tests.log:4406`) |
| H02 | Push 意图版本 | 逆序、退出及重试 | 本地自动化通过 | “versioned Push intent survives reordering, replay, session changes and APNs rejection” (`server-full-tests.log:4404`) |
| H03 | Push 发送与重试 | 供应商失败、载荷和重试 | 部分通过 | tcp-recheck.log 的 mention 场景及默认套件 Push 重试通过；真实 APNs 未验证。 “Push wake clock failures preserve admission and recover without double spending” (`server-full-tests.log:3698`)<br>“Push wake retries reclaim expired leases without double-spending admission” (`server-full-tests.log:4389`) |
| H04 | TLS 与协议协商 | 版本及能力协商 | 本地自动化通过 | “hello negotiation authentication and correlated request lifecycle” (`core-tests.log:644`)<br>“a frame round-trips across arbitrary TLS byte boundaries” (`core-tests.log:638`) |
| H05 | 连接认证 | 身份、过期及未认证拒绝 | 本地自动化通过 | “hello negotiation authentication and correlated request lifecycle” (`core-tests.log:644`)<br>“Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-full-tests.log:3594`) |
| H06 | 帧与解码边界 | 分片、超限和非法编码 | 本地自动化通过 | “a decoded frame does not leave a nonzero-index buffer for the next frame” (`core-tests.log:630`)<br>“v45SendCanUseBoundedLargeFrameWhileOrdinaryFrameStaysSmall()” (`core-tests.log:771`) |
| H07 | 准入与背压 | 连接、队列和慢写出 | 本地自动化通过 | “encoded demand bytes and total connection admission reject before starting readers” (`server-full-tests.log:5548`)<br>“offers return while authority is suspended; duplicate authors and queue limits remain bounded” (`server-full-tests.log:5554`) |
| H08 | 超时与心跳 | 绝对认证期限和空闲 | 本地自动化通过 | “authenticated heartbeats and business dispatch never repeat credential authentication” (`server-full-tests.log:6942`)<br>“authenticated suspended requests neither expire nor retain a disconnected registration” (`server-full-tests.log:7567`) |
| H09 | HTTP 边界 | 输入、超限和响应安全 | 本地自动化通过 | “transfer methods are derived and HTTPS plans reject credentialed URLs and duplicate headers” (`core-tests.log:675`)<br>“account forward HTTP recovers original target proof across worker restart and closes only unexported pairs” (`server-full-tests.log:2027`) |
| I01 | Room Actor 路由 | 冷启动、远端和并发激活 | 本地自动化通过 | extra-recheck-tests.log、native-crash-result.json 对应原失败场景复验通过。  “configured owner fence locks the full reverse-ordered room set and rejects route or kind drift” (`server-full-tests.log:2319`)<br>“configured single-room fence preserves data owner, route, kind and scope errors” (`server-full-tests.log:2321`) |
| I02 | 租约与围栏 | 旧 Owner、接管及晚到请求 | 本地自动化通过 | contract-recheck.log、commit-crash-tests.log 对应原失败场景复验通过。  “the maximum epoch can renew but cannot overflow on expiry or takeover” (`server-full-tests.log:112`)<br>“target import holds its room fence through receive and completion before takeover” (`omitted-coverage-recheck-tests.log:377`) |
| I03 | 集群身份 | 证书、签名和重放 | 本地自动化通过 | deployment-config-tests.log、deployment-optins-recheck.log；序列化门禁通过 对应原失败场景复验通过。  “concurrent copies of a signed, MAC or local call dispatch exactly once” (`server-full-tests.log:10216`)<br>“signed PB authenticates transmitted bytes independently of field order” (`server-full-tests.log:10225`) |
| I04 | 静态用户分片 | 归属、epoch 及跨库幂等 | 本地自动化通过 | “snapshot reset authorizes against control plane for an independent user shard” (`server-full-tests.log:4142`)<br>“direct and social sync records shadow to a forwarding user shard with their source sequence” (`server-full-tests.log:4148`) |
| I05 | 数据库事务故障 | 回滚、结果未知和持久恢复 | 本地自动化通过 | extra-recheck-tests.log、commit-crash-tests.log 对应原失败场景复验通过。  “Actor forwarding rejects retired activations and recovers a committed pair after response loss” (`server-full-tests.log:3600`)<br>“physical target inbox atomically accepts exports and recovers post-commit failure” (`server-full-tests.log:3752`) |
| I06 | 持久任务重试 | 退避、预算及重启 | 本地自动化通过 | “Content review retry limits preserve decisions, pause policy and claim fencing” (`server-full-tests.log:2995`)<br>“Durable replay audit clocks preserve not-paused results at database bounds” (`server-full-tests.log:3653`) |
| I07 | 运维重放 | 单目标、授权和原子审计 | 本地自动化通过 | “forward operator replay is atomic, idempotent, owner fenced and preserves media identity” (`server-full-tests.log:3254`)<br>“Personal event operator replay is audited, bounded and fences previous leases” (`server-full-tests.log:3648`) |
| I08 | 数据库工作隔离 | 独立准入和资源预算 | 本地自动化通过 | extra-recheck-tests.log、omitted-coverage-recheck-tests.log 对应原失败场景复验通过。  “physical connection shutdown waits for actual execution and loan return” (`server-full-tests.log:4761`)<br>“a retained executor cannot execute SQL after its physical loan has returned” (`server-full-tests.log:4771`) |
| I09 | 启动检查 | 必需配置、schema 和依赖 | 本地自动化通过 | application-busy-result.json、application-cross-entry-result.json：修改后的默认 Linux 脚本启动及完整业务冒烟通过。 “startup rejects device progress storage without its cursor constraint” (`server-full-tests.log:35`)<br>“startup rejects a disabled routing invalidation trigger” (`server-full-tests.log:1868`) |
| I10 | 优雅关闭 | 在途工作、排空及超时 | 本地自动化通过 | shutdown-recheck-tests.log、application-busy-result.json、native-crash-result.json：取消后的排空、忙碌 SIGTERM、Supervisor 重启通过。 “current snapshot loads and actual transactions retain capacity through cancellation and shutdown” (`server-full-tests.log:104`)<br>“cancelled callers and shutdown join an actual mutation through COMMIT” (`server-full-tests.log:164`) |
| I11 | 崩溃恢复 | 进程强杀及已确认事实 | 本地自动化通过 | commit-crash-tests.log、native-crash-result.json：实际 SIGKILL 后原结果恢复，接管 epoch 增长，无重复消息；generation replacement/retention 通过。 “a content policy violation resumes its staged finding after a crash following authoritative redaction” (`server-full-tests.log:3738`)<br>“startup removes crash-stale upload fragments without touching committed or active files” (`server-full-tests.log:7287`) |
| I12 | 指标与日志 | 低基数、可定位及脱敏 | 本地自动化通过 | “durable-work metrics query aggregate backlog without exposing routes or identifiers” (`server-full-tests.log:4108`)<br>“personal queue metrics distinguish lease expiry, backoff, pause and completed work” (`server-full-tests.log:4823`) |
| I13 | 空库建库与恢复 | 初始化、漂移和备份恢复 | 部分通过 | logical-restore.log：当前 schema 和完整审计行 dump/restore 通过；WAL/PITR 未验证。 “current-state mutations commit and replay without retired room-holder schema” (`server-full-tests.log:160`)<br>“schema readiness fails before serving without password failure state” (`server-full-tests.log:3632`) |
| I14 | 容量与延迟 | 目标负载和延迟阈值 | 部分通过 | capacity-tests.log 的十万成员建群通过；capacity-send-recheck-tests.log 的十万成员发送通过。目标在线负载、吞吐、P95/P99 尚未实测批准。 |
| I15 | 长稳态 | 持续资源、队列和存储增长 | 未验证 | 未执行约定目标负载与时长的长稳态；功能回归耗时不作为 soak 证据。 |
| I16 | 生产供应商与灾备 | 真实供应商、轮换及 RPO/RTO | 未验证 | 缺少本轮真实生产供应商、密钥轮换、WAL/PITR、跨环境恢复与 RPO/RTO 证据。 |

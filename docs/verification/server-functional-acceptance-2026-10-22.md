# 服务端功能验收结果 · 2026-10-22

**结论：本次验收未全通过，不能据此批准上线。** 本表保留原方案的 116 个编号，区分实际通过、失败、覆盖不足和范围差异。测试失败不一定是业务实现缺陷：下文明确区分测试夹具阻断、合同预期冲突与真实进程验证失败。

基线提交：`1f904b2c55f73b43df8e2996e768c33ab4707966`。环境为本机 macOS arm64、Apple Swift 6.4、PostgreSQL 16.13，另使用隔离 Colima Linux 运行真实服务进程。协议按当前源码 v48 核对。未访问生产环境。

唯一代码改动为 `IMV2Server/Tests/IMV2ServerTests/TCPAccountClusterRouter.swift:52`：测试夹具从 JSON 解码改为生产实际采用的 `V2ActorProtobuf.decode`。生产代码未修改。首次完整运行使用修正前的测试二进制；修正后的定向复验单独保留，未覆盖首次失败记录。

证据归档：`/Users/yyl/.codex/verification/imv2-server-20261022/`。表内 `文件名:行号` 均指该目录；`manifest.json` 保存基线文件哈希和执行结果，`row-results.json` 保存逐项对应测试及源码位置。真实 Linux 服务结果保留于 `/Users/yyl/.codex/virtual-actor-builds/acceptance-20261022-*/`。

## 执行汇总

| 执行 | 结果 | 证据 |
| --- | --- | --- |
| Core | 通过：Swift Testing 177 项，XCTest 5 项 | `core-tests.log` |
| 完整服务端套件 | 框架汇总 2,306 项：2,249 通过、15 失败、42 跳过；退出码 1 | `server-tests.log`；通过计数中有 2 项未开十万成员开关而直接返回，已从逐项通过证据排除 |
| 显式开启 Actor/PostgreSQL 故障测试 | 20 项：14 通过、6 失败；测试退出码 1 | `extra-tests.log`、`extra-result.json` |
| 十万成员边界 | 2 项均未通过；退出码 1 | `capacity-boundaries.log`；建群 560.896 秒后在统计断言阶段失败，发送 1.232 秒后配置校验失败；Debug 耗时不作为生产 SLO |
| 地址解码夹具修正后复验 | 12 项：8 通过、4 失败；退出码 1 | `actor-fixture-rerun.log` |
| 邀请/编辑/回执/mention 独立复验 | 4 项均再次失败；退出码 1 | `failure-rechecks.log` |
| 回执重放独立复验 | 1 项再次失败；退出码 1 | `receipt-recheck.log` |
| 成员意图独立复验 | 2 项：1 通过、1 再次失败；退出码 1 | `membership-recheck.log` |
| 独立数据库协议、单语句写入及 Host 生命周期补验 | 7 项：6 通过、1 失败；测试退出码 1 | `extra-late-tests.log`、`extra-late-result.json`；前四个新增场景均执行，Host 生命周期错误分类再次失败 |

不同运行包含复验和重叠场景，**不能把各行测试数直接相加当作独立覆盖量**。issue 数也不是缺陷数：TCP 重试循环会反复记录同一失败断言。测试框架汇总与本次证据分类分别保留。


主套件的 42 个显式跳过项不能计为通过；另有两个十万成员测试在未设开关时直接返回，本次单独开启补跑。崩溃测试的子进程入口由父测试调用，不可仅按子入口的跳过状态判断父场景未执行。保留的未覆盖条件见 `remaining-skips.json`。

## 真实服务链路

| 验证 | 结果 | 证据及边界 |
| --- | --- | --- |
| 默认 Linux 服务栈启动 | 未通过 | PostgreSQL 原 128 进程/1 GiB 预算下先出现 fork 失败，后出现进程被杀；只提高数据库预算后又受 Account 健康检查启动窗口影响 |
| 临时调整预算后的完整冒烟 | 通过 | 数据库设为 512 进程、3 GiB，Account 健康检查增加 120 秒启动宽限；注册、设备签发、TLS 私聊收发、密码限流、Push 端点增删、禁号、指标、昵称、邀请审批、媒体发送和签名下载通过 |
| 忙碌发送期间 SIGTERM | 通过 | 提交后 Host 退出，退出码 0；新 incarnation 接管、epoch 增长，原 Gateway 重放获得同一消息结果 |
| 跨入口账户禁用 | 通过 | 原 Gateway/Host 保持运行，旧连接发送和读取均拒绝，没有新增消息 |
| 独立 VM 强杀恢复 | 未通过 | 中间的网络失联不授予所有权、未知结果发送持久化断言通过；整体失败于 `replace supervised Host generation`，原因 `supervisor did not drain control and durable resources`，`crashTakeoverVerified=false` |

通过的临时服务栈配置未写回仓库，不能抹去默认配置失败。普通冒烟结果为 `acceptance-20261022-ready-runs/run-a363493a5e7a4b9aace93de2bd85b1bd/result.json`；忙碌关闭为 `acceptance-20261022-busy-runs/run-8a870452c32a4d03a2532481072bb440/result.json`；跨入口禁用为 `acceptance-20261022-disable-runs/run-45b6a189df604337be2980c1368d3223/result.json`；强杀结果为 `acceptance-20261022-native-crash/result.json`。这些相对目录均位于上述 `virtual-actor-builds` 下。

## 主要未通过项

| 关联编号 | 观察结果 | 判断与证据 |
| --- | --- | --- |
| F05、F06、F13 | TCP 启动覆盖、TLS 覆盖重建及旧 activation 投递仍失败；出现 stale、订阅计数不符和 corruptPersistence | 地址解码修正后仍复现，不能判为旧 JSON 夹具的同一问题。`actor-fixture-rerun.log`：12 项中 8 通过、4 失败 |
| I11 | 已提交发送的强杀分支重建后，activation epoch 未满足严格递增断言 | `actor-fixture-rerun.log:681`；另有独立 Supervisor 强杀脚本整体失败，两个证据分别保留 |
| C05、D06 | 最后邀请名额竞争未达到数据库锁屏障，并出现 unavailable 回滚 | `failure-rechecks.log`；不削弱锁顺序断言来取得通过 |
| C10、E08 | 编辑/策略提交顺序的 24 个参数组合中，12 个 blocked 断言失败 | `failure-rechecks.log`；不能确认这些竞争条件下的提交授权顺序 |
| E13、I02 | 回执批次与回执重放实际返回 activationChanged，预期 ownerChanged | `failure-rechecks.log`、`receipt-recheck.log`；属于错误分类不一致，未观测到越权写入 |
| C06 | self-remove 构造被允许，但测试要求 invalidIntent | `membership-recheck.log`；当前 Core 明确允许 remove 自己以支持退出，需修正合同/测试预期的一致性 |
| E03、E07、E12、G05、G07、H03、I05 | mention、D5 跨 Owner 导入/媒体可见性、房间发送 COMMIT ACK 丢失及配对保留测试缺少 message policy execution | `extra-tests.log`、`failure-rechecks.log`；在业务目标断言前被配置校验阻断，不能用普通路径通过替代这些故障场景 |
| I01、I08 | Host 生命周期返回 roomCapacityExhausted，测试预期 overloaded | `extra-tests.log`、`extra-late-tests.log`；容量错误分类合同不一致 |
| C04、I14 | 十万成员建群在返回后的统计查询访问退役 group_room_operations 表；十万成员发送缺少消息策略配置 | `capacity-boundaries.log`、`capacity-postgres-errors.log`；两项都未完成验收，不能把前者直接称为已证实的建群业务失败 |
| I09、I10、I11 | 默认服务栈资源/启动窗口不足；Supervisor TERM 退出检查失败 | 见“真实服务链路”；临时调整配置后的通过不代表仓库默认配置已修复 |

旧 JSON Actor 地址解码夹具修正后，“committed membership joins and exits…”和“a durable send automatically reaches both recipient devices…”均已通过定向复验。其他未通过项没有修改生产实现或放宽断言。首次失败、修正后的失败和通过结果全部保留。


## 基础检查与恢复

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| schema 空库初始化与漂移检查 | 通过 | 独立数据库 |
| 当前 schema 的逻辑恢复补验 | 通过 | pg_dump 到另一空库，完整审计行与表数量一致，结构合同通过 |
| 仓库原逻辑恢复脚本 | 未通过 | 使用退役 `room_outbox`，在当前约束下插入失败，未进入恢复阶段 |
| 服务端模块边界、PostgreSQL vendor、schema 关系覆盖 | 通过 | 静态门禁 |
| 配置样例、本地环境合同 | 通过 | 环境变量校验 |
| Actor 序列化边界 | 未通过 | 部署配置中的 JSONDecoder 被门禁命中；需协调规则和配置边界，未据此证明运行时 RPC 使用 JSON |
| 公共 Protobuf 生成一致性 | 未通过 | 首个差异为 ClientKit highWatermark 注释；脚本提前退出，不能宣称后续生成文件均一致 |
| Actor Protobuf 生成一致性 | 未通过 | FoundationEssentials、nonisolated 等生成输出差异 |
| Prometheus 规则 | 通过 | Docker 可用后复验通过 |
| 文档链接 | 通过 | 引用检查 |
| 文档结构 | 未通过 | 11 份已有文档未登记到合同索引 |

## 116 项验收表

“自动化通过”只表示本次列出的本地自动化场景通过，不代表穷尽所有组合或生产环境通过。“部分通过”表示有通过证据但原范围仍有明确缺口。“未通过”包含断言失败、夹具阻断或实际服务验证失败，具体原因在同一行说明。

自动化通过: 80 / 部分通过: 9 / 未通过: 24 / 范围差异: 1 / 未验证: 2

| 编号 | 功能 | 原方案验收范围 | 结果 | 执行证据与限制 |
| --- | --- | --- | --- | --- |
| A01 | 密码注册 | 注册并发和身份唯一性 | 自动化通过 | “Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-tests.log:8849`)<br>“password registration writes a privacy-minimized audit fact atomically” (`server-tests.log:8885`) |
| A02 | 密码登录 | 错误密码、未知和禁用账户 | 自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-tests.log:8087`)<br>“Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-tests.log:8849`) |
| A03 | 密码输入边界 | 12/1024 字节、NUL 和字符原样保存 | 自动化通过 | “password fallback preserves all accepted UTF-8 bytes” (`server-tests.log:87083`)<br>“password fallback rejects embedded NUL before persistence” (`server-tests.log:87089`) |
| A04 | 密码安全存储 | Argon2id 验证记录和脱敏 | 自动化通过 | “Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-tests.log:8849`)<br>“password transport depends on a store capability and never passes plaintext to persistence” (`server-tests.log:87125`) |
| A05 | 登录限流与锁定 | 跨副本预算和锁定窗口 | 自动化通过 | “password fallback failure limits persist across account-service instances” (`server-tests.log:8883`)<br>“password attempt cleanup is bounded and preserves live windows, locks and rollback clocks” (`server-tests.log:9407`) |
| A06 | 密码计算过载 | KDF 容量及取消 | 自动化通过 | “saturated password work returns no-store 503 with a bounded retry” (`server-tests.log:87095`)<br>“real KDF burst sheds excess work and remains usable afterward” (`server-tests.log:87136`) |
| A07 | 修改密码 | 新旧认证状态及并发 | 自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-tests.log:8087`) |
| A08 | 离线恢复码 | 一次性兑换和会话失效 | 自动化通过 | “password lifecycle revokes sessions, rejects stale assertions and consumes recovery once” (`server-tests.log:8087`) |
| A09 | 账户入口保护 | 可信入口和重复地址头 | 自动化通过 | “account routes reject a direct caller without the edge proof” (`server-tests.log:87100`)<br>“running edge requests reject duplicate fields and do not reuse another request's identity” (`server-tests.log:87116`) |
| A10 | 客户端地址限流 | 共享预算和地址隐私 | 自动化通过 | “account edge limits only an authenticated Caddy-derived client address” (`server-tests.log:87104`)<br>“account-edge limiter preserves an allowed route's client status” (`server-tests.log:87107`) |
| A11 | 设备凭据签发 | 断言有效期及身份绑定 | 自动化通过 | “new device issuance enforces active and durable account budgets” (`server-tests.log:9375`)<br>“trusted device registration and refresh rotation are durable, replayable, and revoke on reuse” (`server-tests.log:9379`) |
| A12 | 签发重试与取消 | 响应丢失及取消竞争 | 自动化通过 | “registration cancellation proof has a distinct purpose and redacted diagnostics” (`core-tests.log:691`)<br>“registration cancellation HTTP commits the proof fence and rejects unsafe requests before storage” (`server-tests.log:8586`) |
| A13 | 凭据刷新 | 轮换、重复使用和并发 | 自动化通过 | “revoke-only capability survives rotation, isolates sessions and commits atomically” (`server-tests.log:8607`)<br>“absolute device expiry bounds rotations, replay, authentication and Push eligibility” (`server-tests.log:9377`) |
| A14 | 会话绝对期限 | 刷新、Push 和资源不越过期限 | 自动化通过 | “absolute device expiry bounds rotations, replay, authentication and Push eligibility” (`server-tests.log:9377`) |
| A15 | 设备会话列表 | 本人设备分页 | 自动化通过 | “device sessions paginate metadata and revoke remote installations with bounded SQL” (`server-tests.log:9383`)<br>“Session inventory clocks reject unsafe queries and preserve normal pagination” (`server-tests.log:9536`) |
| A16 | 本机退出撤销 | 专属撤销凭据隔离和重放 | 自动化通过 | “revoke-only capability survives rotation, isolates sessions and commits atomically” (`server-tests.log:8607`) |
| A17 | 远程设备撤销 | 基线、目标范围、原操作恢复 | 自动化通过 | “device sessions paginate metadata and revoke remote installations with bounded SQL” (`server-tests.log:9383`) |
| A18 | 撤销实时生效 | 多 Gateway 连接及排队帧失权 | 自动化通过 | “bootstrap order, duplicate ids and device revocation fail closed” (`core-tests.log:581`)<br>“readiness rejects any loss of the revocation commit-order fence” (`server-tests.log:7039`) |
| A19 | 账户禁用 | 签发、会话、业务和审计 | 自动化通过 | “Account disable validates required revision changes without suppressing inactive-profile results” (`server-tests.log:7548`)<br>“Account disable returns its database commit timestamp consistently on first response and replay” (`server-tests.log:7550`) |
| B01 | 精确身份发现 | 发现证明和设备绑定 | 自动化通过 | “exact handle lookup requires device credentials and returns no-store profile facts” (`server-tests.log:89298`)<br>“unknown and hidden identities share the same not-found response” (`server-tests.log:89301`) |
| B02 | 本人资料更新 | 字段更新和版本 | 自动化通过 | “profile field patches keep unchanged, removal and replacement distinct” (`core-tests.log:611`)<br>“Directory profile propagation copies the exact persisted update timestamp” (`server-tests.log:8698`) |
| B03 | 资料操作恢复 | 提交与关闭串行化 | 自动化通过 | “profile receipt bindings cannot confuse actors or payloads after Codable roundtrip” (`core-tests.log:632`)<br>“Profile patches retain unrelated fields and replay the original receipt after later commits” (`server-tests.log:8700`) |
| B04 | 资料读取授权 | 上下文和缓存授权 | 自动化通过 | “group presentation binds viewer, resource generation and independent byte/display deadlines” (`core-tests.log:613`)<br>“presentation leases are viewer/context scoped and cannot exceed five minutes or overflow” (`core-tests.log:658`) |
| B05 | 好友申请 | 重复及双方并发申请 | 部分通过 | 已验证好友申请持久化和同操作并发重试；未取得双方不同操作同时申请的专门执行证据。；“Concurrent relationship and block retries retain one transition at the final policy revision” (`server-tests.log:8331`)<br>“relationship and block mutations are durable, private, and synchronize both sides” (`server-tests.log:9146`) |
| B06 | 好友关系流转 | 接受、拒绝、撤销、删除 | 部分通过 | 已验证申请、接受、屏蔽/解除及关系变更；未取得拒绝、撤销所有终态组合的独立证据。；“relationship and block mutations are durable, private, and synchronize both sides” (`server-tests.log:9146`)<br>“social mutations require policy owners and replay their committed result without legacy authorization” (`server-tests.log:9454`) |
| B07 | 屏蔽与解除 | 消息和关系准入 | 自动化通过 | “confirmed replies omit stranger dependencies while current blocks still deny” (`server-tests.log:7271`)<br>“direct forward imports enforce control blocks and preserve terminal replay” (`server-tests.log:7558`) |
| B08 | 联系人同步 | 个人关系投影及重连 | 部分通过 | 联系人投影与跨用户分片同步通过；完整重连覆盖受 F06 的账户 TCP 失败影响。；“direct and social sync records shadow to a forwarding user shard with their source sequence” (`server-tests.log:9405`) |
| B09 | 账户与会话偏好 | 幂等、版本及同步 | 自动化通过 | “Room-owned preferences retain original receipts, close atomically and fence stale intents” (`server-tests.log:7497`)<br>“Concurrent direct preference retries retain one policy transition and committed timestamp” (`server-tests.log:8347`) |
| B10 | 在线状态隐私 | 长期隐私和瞬时抑制 | 自动化通过 | “merged presence admission enforces concurrent user limits, expired replacement and privacy” (`server-tests.log:9140`)<br>“Presence responses validate the selected lease while preserving offline and hidden states” (`server-tests.log:9476`) |
| C01 | 创建和打开私聊 | 用户对唯一性及重试 | 自动化通过 | “Concurrent direct room opens serialize operation identity and reuse the original room timestamp” (`server-tests.log:8339`)<br>“Direct room creation validates persisted pair and profile timestamps” (`server-tests.log:9497`) |
| C02 | 私聊准入 | 身份、屏蔽、容量和原子性 | 自动化通过 | “plain durable direct send rejects a third member without publishing provisional writes” (`server-tests.log:7318`)<br>“Direct room and preference timestamps are rejected before durable writes” (`server-tests.log:8543`) |
| C03 | 陌生人消息 | 窗口配额和接收偏好 | 自动化通过 | “full cohort preserves first producers, reciprocal replies and cumulative stranger quota” (`server-tests.log:7255`)<br>“confirmed replies omit stranger dependencies while current blocks still deny” (`server-tests.log:7271`) |
| C04 | 创建群聊 | 初始成员、房间和跨库恢复 | 未通过 | 常规建群通过；显式十万成员建群在返回后统计阶段查询退役 im_v2.group_room_operations 表而失败，未完成全部断言。；“Group creation proof and owner facts share the committed millisecond time” (`server-tests.log:8379`)<br>“Group creation rejects invalid clocks before writes and replays permanent proof without a fresh clock” (`server-tests.log:8541`) |
| C05 | 增加成员 | 授权、容量和版本 | 未通过 | 邀请最后名额竞争未达到预期数据库锁屏障，并出现 unavailable 回滚；独立复验结果另列。；“canonicalizes the initial membership order” (`core-tests.log:578`)<br>“originalConfirmationAndMembershipAreFrozen()” (`core-tests.log:602`) |
| C06 | 移除与退出 | 角色约束及即时失权 | 未通过 | self-remove 构造被实现允许（用于退出），测试却要求 invalidIntent；合同与测试预期冲突。成员退出/管理边界的数据库测试另有通过证据。；“member removal installs its committed cut without a postcommit database read” (`server-tests.log:6557`)<br>“membership removal preserves self-exit and management boundaries” (`server-tests.log:9155`) |
| C07 | 退出后重入 | 历史可见性 | 自动化通过 | “forward requires the current content version audience after rejoin” (`server-tests.log:8485`)<br>“room-log edit replacement bridges rejoin without exposing absent revisions” (`server-tests.log:8788`) |
| C08 | 成员目录 | 稳定分页和读取权限 | 自动化通过 | “one SQL returns membership, routes and generation; empty and filtered pages retain exact scan position” (`server-tests.log:5250`)<br>“cold, hot, sparse and broad memberships use actual bounded directory/state reads” (`server-tests.log:7029`) |
| C09 | 角色与权限 | 角色版本及权限基线 | 自动化通过 | “role policy is version-fenced and cannot mutate owner authority” (`core-tests.log:631`)<br>“membership identity, actor role, cursor, role baseline and user-room topology survive” (`server-tests.log:84825`) |
| C10 | 禁言与冻结 | 并发提交权限 | 未通过 | 编辑与策略并发的 24 个参数场景有 12 个 blocked 断言失败；授权提交顺序不能判通过。；“only room owner or admin can moderate and mute expiry must be future” (`core-tests.log:633`)<br>“mute authorization rejects nonfinite clocks and expiry” (`core-tests.log:721`) |
| C11 | 群公告 | 版本、清除、幂等和权限 | 部分通过 | 已验证公告等群能力的 Owner 围栏与重放；未取得覆盖公告清除全部组合的独立证据。；“announcement and role changes reject unsafe shapes” (`core-tests.log:627`)<br>“group capabilities fence the selected owner before writes and operation replay” (`server-tests.log:9066`) |
| C12 | 消息置顶 | 逆序、取消及快照 | 部分通过 | 已验证置顶写入的 Owner 围栏及重放；未取得取消置顶、逆序与快照全部组合的独立证据。；“group capabilities fence the selected owner before writes and operation replay” (`server-tests.log:9066`) |
| C13 | 群头像 | 资源绑定、恢复和授权 | 自动化通过 | “home derives from authenticated actor for avatars and the explicit room for attachments” (`core-tests.log:666`)<br>“only the current structural owner can bind an eligible room avatar” (`server-tests.log:87788`) |
| C14 | 成员操作恢复 | Owner 围栏及原结果 | 自动化通过 | “typed membership preserves selected owner epochs and original receipts” (`server-tests.log:9078`)<br>“never serves a stale membership epoch or an unknown sequence gap” (`server-tests.log:85606`) |
| D01 | 创建邀请 | 稳定身份、期限和链接 | 自动化通过 | “twenty exhausted invitation links no longer occupy creation quota” (`server-tests.log:8125`)<br>“Invite creation clocks retain recoverable work and preserve published bindings” (`server-tests.log:8917`) |
| D02 | 邀请失效 | 次数、到期和撤销 | 自动化通过 | “Invite response states and existing-member submissions agree with the persisted expiry” (`server-tests.log:9915`) |
| D03 | 提交入群申请 | 重复申请和配额 | 自动化通过 | “different rooms and invites share one atomic applicant limit” (`server-tests.log:5285`)<br>“same applicant cannot overbook the last local quota slot across different invites” (`server-tests.log:8111`) |
| D04 | 全局申请配额 | 跨 Owner 并发 | 自动化通过 | “different rooms and invites share one atomic applicant limit” (`server-tests.log:5285`)<br>“same applicant cannot overbook the last local quota slot across different invites” (`server-tests.log:8111`) |
| D05 | 申请分页与取消 | 稳定分页和终态竞争 | 自动化通过 | “pending request cursors survive review and deletion across PostgreSQL timestamp ranges” (`server-tests.log:8123`)<br>“applicant cancellation preserves decisions, releases quota, and serializes with approval” (`server-tests.log:9134`) |
| D06 | 批准与拒绝 | 权限及成员配额原子提交 | 未通过 | 邀请最后名额竞争未达到预期数据库锁屏障，并出现 unavailable 回滚；独立复验结果另列。；“join request exposes a resume operation only while approval is in progress” (`core-tests.log:600`)<br>“approval rolls back every owner effect at each late failure and replays the committed decision” (`server-tests.log:8099`) |
| D07 | 邀请故障恢复 | 目录补偿和 Owner 路由 | 自动化通过 | “Invite creation clocks retain recoverable work and preserve published bindings” (`server-tests.log:8917`)<br>“invite directory survives owner response loss and finalize failure across databases” (`server-tests.log:9086`) |
| E01 | 基础发送 | ACK、持久消息和回执 | 自动化通过 | “durable send batch isolates invalid content and preserves neighbouring receipts” (`server-tests.log:7312`)<br>“current durable group turns preserve sequence, completion and readable projection” (`server-tests.log:9106`) |
| E02 | 双通道发送 | 跨 TCP/HTTPS 同身份重试 | 范围差异 | 未找到普通消息 HTTPS 发送路由；现有 HTTPS 为编辑、撤回等操作。不能宣称跨 TCP/HTTPS 普通发送重试已验证。 |
| E03 | 发送结果未知 | 提交结果恢复 | 未通过 | 普通独立事务 ACK 丢失恢复通过；房间发送 ACK 丢失用例因缺少 message policy execution 配置失败，故障场景覆盖不完整。；“send execution v1 recovers committed results and leaves absent identities retryable” (`server-tests.log:7491`)<br>“native sender rejects stale data owners and recovers the durable result” (`server-tests.log:7530`) |
| E04 | 幂等身份冲突 | 重复和冲突载荷 | 自动化通过 | “batch rollback recomputes fingerprint conflicts and retains committed conflicts” (`server-tests.log:7332`)<br>“send completion retains original fingerprint and metadata after content mutation/deletion” (`server-tests.log:8130`) |
| E05 | 消息顺序 | 并发持久顺序 | 自动化通过 | “User sequence exhaustion preserves committed sends and recoverable private hints” (`server-tests.log:8366`)<br>“current durable group turns preserve sequence, completion and readable projection” (`server-tests.log:9106`) |
| E06 | 输入与引用校验 | 非法消息和资源引用 | 自动化通过 | “durable send batch isolates invalid content and preserves neighbouring receipts” (`server-tests.log:7312`)<br>“message media downloads validate room ownership and control-plane device authority” (`server-tests.log:8469`) |
| E07 | 回复与 mention | 引用可见性和提示 | 未通过 | mention 推送用例因缺少 message policy execution 配置而未进入业务断言；真实 APNs 发送也未验证。；“message references require accepted and current content audiences” (`server-tests.log:8786`) |
| E08 | 编辑消息 | 作者、提交权限和并发 | 未通过 | 编辑与策略并发的 24 个参数场景有 12 个 blocked 断言失败；授权提交顺序不能判通过。；“send and edit share current room publication authorization” (`server-tests.log:9185`) |
| E09 | 编辑可见性 | 历史授权及完整替换 | 自动化通过 | “edits keep durable identity and reject empty or oversized replacements” (`core-tests.log:639`)<br>“room-log edit replacement bridges rejoin without exposing absent revisions” (`server-tests.log:8788`) |
| E10 | 作者撤回 | 身份、重放及墓碑 | 自动化通过 | “withdrawalResult(revision:sequence:)” (`core-tests.log:625`)<br>“long withdrawn tails report the production summary execution plan” (`server-tests.log:6543`) |
| E11 | 表情回应 | 集合、授权和幂等 | 自动化通过 | “reaction input is normalized and set operations retain independent IDs” (`core-tests.log:585`)<br>“reaction original outcomes fence inverse intents and survive receipt rollback” (`server-tests.log:7304`) |
| E12 | 转发 | 源目标授权和部分失败恢复 | 未通过 | 普通转发/跨库用例有通过证据；额外开启的 D5 跨 Owner 导出导入围栏用例被缺失消息策略配置阻断。；“Ordinary and forwarded room-log messages match independent Python SHA-256 vectors” (`core-tests.log:648`)<br>“multi-forward remains bounded and preserves per-pair intent” (`core-tests.log:665`) |
| E13 | 已读回执 | 单调、并发、权限和恢复 | 未通过 | 两个回执测试实际返回 activationChanged，预期 ownerChanged；错误分类不一致，未观测到越权写入。；“read receipt is monotonic user state and never creates delivery work” (`server-tests.log:9193`)<br>“Read receipt preference revisions advance independently of time and preserve replay at exhaustion” (`server-tests.log:9493`) |
| E14 | 特殊账户策略 | 已开放账户类型策略 | 自动化通过 | “special account audit rejects stale data owners before replay or new audit writes” (`server-tests.log:7523`) |
| F01 | 房间历史增量 | 可见内容、分页和游标 | 自动化通过 | “actual room-log SQL bounds scans at first and middle pages despite sparse message-row storage” (`server-tests.log:8059`)<br>“room pulls intersect original and mutation visibility and advance hidden tails” (`server-tests.log:8799`) |
| F02 | 不可见事件扫描 | 扫描位置和不泄漏 | 自动化通过 | “room pulls intersect original and mutation visibility and advance hidden tails” (`server-tests.log:8799`) |
| F03 | 个人事件同步 | 有序、幂等及缺口恢复 | 自动化通过 | “Personal event operator replay is audited, bounded and fences previous leases” (`server-tests.log:8903`)<br>“direct imports recover a failed completion transaction without duplicating personal events” (`server-tests.log:9027`) |
| F04 | 房间目录与摘要 | 授权、分页和摘要游标隔离 | 自动化通过 | “summary restores only authorized content revisions across membership gaps” (`server-tests.log:5544`)<br>“state and visible-summary batches scale with nonempty rooms” (`server-tests.log:6549`) |
| F05 | 多设备一致性 | 离线恢复和未订阅正文 | 未通过 | 账户 TCP 覆盖存在 stale、订阅数量不符及等待失败；旧 JSON 地址解码夹具已修正，定向复验单独保留。；“startup rejects device progress storage without its cursor constraint” (`server-tests.log:5256`)<br>“device progress persists independently and out-of-order reports cannot regress” (`server-tests.log:5258`) |
| F06 | 实时投递与补偿 | 丢提示、重连及 Relay 重建 | 未通过 | 账户 TCP 覆盖存在 stale、订阅数量不符及等待失败；旧 JSON 地址解码夹具已修正，定向复验单独保留。；“coverage invalidation between Ready approval and write confirmation retains its boundary” (`server-tests.log:84600`)<br>“authentication starts owned coverage without waiting for temporary Owner admission or route recovery” (`server-tests.log:84655`) |
| F07 | 设备房间确认 | 设备绑定和撤销围栏 | 自动化通过 | “startup rejects device progress storage without its cursor constraint” (`server-tests.log:5256`)<br>“device progress persists independently and out-of-order reports cannot regress” (`server-tests.log:5258`) |
| F08 | Snapshot 创建与分页 | 固定基线和有界分页 | 自动化通过 | “snapshot and log page each issue one statement with no transaction controls” (`server-tests.log:7125`)<br>“snapshotAndPageDoNotWaitForRoomWriteFence()” (`server-tests.log:7133`) |
| F09 | Snapshot ACK | 设备隔离和激活 | 自动化通过 | “staleSnapshotAcknowledgementCannotAdvanceCursor()” (`core-tests.log:610`)<br>“matchingSnapshotAcknowledgementMovesOnlyThePendingGeneration()” (`core-tests.log:617`) |
| F10 | 快照与增量衔接 | 并发变化下无缺口 | 自动化通过 | “matchingSnapshotAcknowledgementMovesOnlyThePendingGeneration()” (`core-tests.log:617`)<br>“snapshot V3 resumes page-by-page, publishes immediately, and GC preserves active baselines” (`server-tests.log:9401`) |
| F11 | 日志裁剪 | 保留边界和慢设备恢复 | 自动化通过 | “summary edit audiences survive actual room-log retention” (`server-tests.log:7513`)<br>“retention bounds batches across rooms and tied sequences while preserving protected bodies” (`server-tests.log:7515`) |
| F12 | 权限与角色基线 | 空集合、逆序和重入 | 自动化通过 | “complete effective policies preserve explicit empty sets and zero room sequence” (`core-tests.log:587`)<br>“membership identity, actor role, cursor, role baseline and user-room topology survive” (`server-tests.log:84825`) |
| F13 | 账户成员覆盖 | 共享初始化和定向刷新 | 未通过 | 账户 TCP 覆盖存在 stale、订阅数量不符及等待失败；旧 JSON 地址解码夹具已修正，定向复验单独保留。；“committed membership joins and exits update account routes without another directory scan” (`actor-fixture-rerun.log:556`)<br>“revocation history overflow retires coverage and releases all Owner references” (`server-tests.log:84594`) |
| F14 | 大群授权分段 | 不完整授权拒绝和边界 | 自动化通过 | “baseline gaps and repeated members never authorize a device” (`server-tests.log:86137`)<br>“segmented group authorization stays closed until the final page” (`server-tests.log:86142`) |
| G01 | 上传授权 | 身份、用途及大小 | 自动化通过 | “home derives from authenticated actor for avatars and the explicit room for attachments” (`core-tests.log:666`)<br>“current upload targets preserve identity, validate adapters and recheck authority after signing” (`server-tests.log:88091`) |
| G02 | 上传传输 | 中断、重复和非法长度 | 自动化通过 | “ready requires a completed upload and a bind deadline; cancelled sessions cannot masquerade as ready” (`core-tests.log:667`)<br>“upload decoding cannot bypass size, MIME, checksum or negotiated mode validation” (`core-tests.log:681`) |
| G03 | 上传恢复与关闭 | 原操作结果和取消竞争 | 自动化通过 | “ready requires a completed upload and a bind deadline; cancelled sessions cannot masquerade as ready” (`core-tests.log:667`)<br>“Media responses retain the database deadline on first issue and upload replay” (`server-tests.log:8302`) |
| G04 | 消息资源绑定 | 合法资源和消息原子性 | 自动化通过 | “media becomes referenceable only after a successful scan” (`core-tests.log:715`)<br>“an attachment-only message retains its opaque references” (`core-tests.log:717`) |
| G05 | 下载授权 | 当前及历史权限 | 未通过 | 真实签名下载及历史权限用例通过；D5 媒体可见性读取轮次围栏补验因缺少消息策略配置失败。；“message media downloads validate room ownership and control-plane device authority” (`server-tests.log:8469`)<br>“room-log media grants revalidate historical content and provider completion” (`server-tests.log:8740`) |
| G06 | 文件读取边界 | 流式、路径和中断 | 部分通过 | 真实本地流式字节、无效签名和中断上传已有证据；未执行独立路径穿越/符号链接攻击矩阵。；“signed HTTPS targets transfer exact bytes through the Vapor object edge” (`server-tests.log:89166`)<br>“running media edge flushes a buffered upload and streams back exact bytes” (`server-tests.log:89169`) |
| G07 | 跨 home 导入 | 保留、提交和释放恢复 | 未通过 | 普通转发/跨库用例有通过证据；额外开启的 D5 跨 Owner 导出导入围栏用例被缺失消息策略配置阻断。；“cross-home import retains authorized source context and cannot reuse the source identity” (`core-tests.log:707`)<br>“import, truncate and deployment changes invalidate directory tokens” (`server-tests.log:7113`) |
| G08 | 资料与头像资源 | 上下文及缓存 lease | 自动化通过 | “group presentation binds viewer, resource generation and independent byte/display deadlines” (`core-tests.log:613`)<br>“presentation leases are viewer/context scoped and cannot exceed five minutes or overflow” (`core-tests.log:658`) |
| G09 | 衍生资源 | 结果绑定和失败恢复 | 自动化通过 | “isolatedAvatarProcessorProducesFixedMetadataFreePNGs()” (`server-tests.log:88076`) |
| G10 | 媒体扫描 | 正常、病毒及供应商失败 | 部分通过 | 本地扫描状态机及失败恢复测试；未接入真实病毒扫描供应商。；“media becomes referenceable only after a successful scan” (`core-tests.log:715`)<br>“Scan publication and retry require an unexpired claim at SQL precision” (`server-tests.log:8433`) |
| G11 | 内容审核 | 持久任务和有序处置 | 自动化通过 | “Content review retry limits preserve decisions, pause policy and claim fencing” (`server-tests.log:8214`)<br>“Content review clocks preserve leases, retry recovery and durable decisions” (`server-tests.log:8923`) |
| G12 | 审核开关 | 禁用及已有任务边界 | 自动化通过 | “disabled content review creates no job for message acceptance or editing” (`server-tests.log:8987`) |
| G13 | 资源清理 | 有效引用保护和崩溃恢复 | 自动化通过 | “Media maintenance validates clocks and preserves scan, purge and retention state” (`server-tests.log:8944`)<br>“a signed local target stores, scans, downloads and purges opaque media bytes” (`server-tests.log:86717`) |
| H01 | Push 端点 | 设备绑定和加密 | 自动化通过 | “Push endpoint clock failures preserve state and completed version replays” (`server-tests.log:8948`)<br>“Push endpoint encryption is device-bound and late rejection cannot disable a fresh registration” (`server-tests.log:9669`) |
| H02 | Push 意图版本 | 逆序、退出及重试 | 自动化通过 | “versioned Push intent survives reordering, replay, session changes and APNs rejection” (`server-tests.log:9667`) |
| H03 | Push 发送与重试 | 供应商失败、载荷和重试 | 未通过 | mention 推送用例因缺少 message policy execution 配置而未进入业务断言；真实 APNs 发送也未验证。；“Push wake clock failures preserve admission and recover without double spending” (`server-tests.log:8953`)<br>“Push wake retries reclaim expired leases without double-spending admission” (`server-tests.log:9652`) |
| H04 | TLS 与协议协商 | 版本及能力协商 | 自动化通过 | “hello negotiation authentication and correlated request lifecycle” (`core-tests.log:577`)<br>“a frame round-trips across arbitrary TLS byte boundaries” (`core-tests.log:730`) |
| H05 | 连接认证 | 身份、过期及未认证拒绝 | 自动化通过 | “hello negotiation authentication and correlated request lifecycle” (`core-tests.log:577`)<br>“Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement” (`server-tests.log:8849`) |
| H06 | 帧与解码边界 | 分片、超限和非法编码 | 自动化通过 | “v45SendCanUseBoundedLargeFrameWhileOrdinaryFrameStaysSmall()” (`core-tests.log:690`)<br>“a decoded frame does not leave a nonzero-index buffer for the next frame” (`core-tests.log:725`) |
| H07 | 准入与背压 | 连接、队列和慢写出 | 自动化通过 | “encoded demand bytes and total connection admission reject before starting readers” (`server-tests.log:84977`)<br>“offers return while authority is suspended; duplicate authors and queue limits remain bounded” (`server-tests.log:84983`) |
| H08 | 超时与心跳 | 绝对认证期限和空闲 | 自动化通过 | “authenticated heartbeats and business dispatch never repeat credential authentication” (`server-tests.log:86371`)<br>“authenticated suspended requests neither expire nor retain a disconnected registration” (`server-tests.log:87001`) |
| H09 | HTTP 边界 | 输入、超限和响应安全 | 自动化通过 | “transfer methods are derived and HTTPS plans reject credentialed URLs and duplicate headers” (`core-tests.log:693`)<br>“account forward HTTP recovers original target proof across worker restart and closes only unexported pairs” (`server-tests.log:7276`) |
| I01 | Room Actor 路由 | 冷启动、远端和并发激活 | 未通过 | Host 生命周期补验实际返回 roomCapacityExhausted，预期 overloaded；配对保留测试还被缺少消息策略配置阻断。；“configured owner fence locks the full reverse-ordered room set and rejects route or kind drift” (`server-tests.log:7532`)<br>“configured single-room fence preserves data owner, route, kind and scope errors” (`server-tests.log:7534`) |
| I02 | 租约与围栏 | 旧 Owner、接管及晚到请求 | 未通过 | 两个回执测试实际返回 activationChanged，预期 ownerChanged；错误分类不一致，未观测到越权写入。；“the maximum epoch can renew but cannot overflow on expiry or takeover” (`server-tests.log:5333`)<br>“target import holds its room fence through receive and completion before takeover” (`server-tests.log:88240`) |
| I03 | 集群身份 | 证书、签名和重放 | 部分通过 | 集群认证测试有通过证据，但 Actor 序列化静态门禁仍失败（部署 JSON 被规则命中），需协调规则与配置边界。；“concurrent copies of a signed, MAC or local call dispatch exactly once” (`server-tests.log:89925`)<br>“signed PB authenticates transmitted bytes independently of field order” (`server-tests.log:89934`) |
| I04 | 静态用户分片 | 归属、epoch 及跨库幂等 | 自动化通过 | “snapshot reset authorizes against control plane for an independent user shard” (`server-tests.log:9399`)<br>“direct and social sync records shadow to a forwarding user shard with their source sequence” (`server-tests.log:9405`) |
| I05 | 数据库事务故障 | 回滚、结果未知和持久恢复 | 未通过 | 普通独立事务 ACK 丢失恢复通过；房间发送 ACK 丢失用例因缺少 message policy execution 配置失败，故障场景覆盖不完整。；“Actor forwarding rejects retired activations and recovers a committed pair after response loss” (`server-tests.log:8855`)<br>“physical target inbox atomically accepts exports and recovers post-commit failure” (`server-tests.log:9007`) |
| I06 | 持久任务重试 | 退避、预算及重启 | 自动化通过 | “Content review retry limits preserve decisions, pause policy and claim fencing” (`server-tests.log:8214`)<br>“Durable replay audit clocks preserve not-paused results at database bounds” (`server-tests.log:8908`) |
| I07 | 运维重放 | 单目标、授权和原子审计 | 自动化通过 | “forward operator replay is atomic, idempotent, owner fenced and preserves media identity” (`server-tests.log:8473`)<br>“Personal event operator replay is audited, bounded and fences previous leases” (`server-tests.log:8903`) |
| I08 | 数据库工作隔离 | 独立准入和资源预算 | 未通过 | Host 生命周期补验实际返回 roomCapacityExhausted，预期 overloaded；配对保留测试还被缺少消息策略配置阻断。；“physical connection shutdown waits for actual execution and loan return” (`server-tests.log:10019`)<br>“a retained executor cannot execute SQL after its physical loan has returned” (`server-tests.log:10029`) |
| I09 | 启动检查 | 必需配置、schema 和依赖 | 未通过 | 默认 Linux 冒烟配置启动失败：PostgreSQL 进程/内存预算及 Account 健康启动窗口不足；临时增配后通过，仓库默认配置未修复。；“startup rejects device progress storage without its cursor constraint” (`server-tests.log:5256`)<br>“startup rejects a disabled routing invalidation trigger” (`server-tests.log:7117`) |
| I10 | 优雅关闭 | 在途工作、排空及超时 | 未通过 | 忙碌 Host 的 SIGTERM、持久提交及重启重放通过；独立强杀脚本中的 Supervisor TERM 退出检查失败。；“current snapshot loads and actual transactions retain capacity through cancellation and shutdown” (`server-tests.log:5325`)<br>“cancelled callers and shutdown join an actual mutation through COMMIT” (`server-tests.log:5385`) |
| I11 | 崩溃恢复 | 进程强杀及已确认事实 | 未通过 | 独立 VM 强杀验证整体失败于 replace supervised Host generation；不得以中间持久化断言或优雅关闭替代完整强杀恢复通过。；“a content policy violation resumes its staged finding after a crash following authoritative redaction” (`server-tests.log:8993`)<br>“startup removes crash-stale upload fragments without touching committed or active files” (`server-tests.log:86721`) |
| I12 | 指标与日志 | 低基数、可定位及脱敏 | 自动化通过 | “durable-work metrics query aggregate backlog without exposing routes or identifiers” (`server-tests.log:9365`)<br>“personal queue metrics distinguish lease expiry, backoff, pause and completed work” (`server-tests.log:10081`) |
| I13 | 空库建库与恢复 | 初始化、漂移和备份恢复 | 部分通过 | 空库/漂移和当前 schema 的审计数据 pg_dump 恢复补验通过；仓库原恢复脚本仍引用退役 room_outbox 而失败，未验证 PITR。；“current-state mutations commit and replay without retired room-holder schema” (`server-tests.log:5381`)<br>“schema readiness fails before serving without password failure state” (`server-tests.log:8887`) |
| I14 | 容量与延迟 | 目标负载和延迟阈值 | 未通过 | 两个十万成员补验均失败：建群统计查询退役表；发送缺少消息策略配置。未执行目标在线负载、吞吐和 P95/P99 延迟 SLO。 |
| I15 | 长稳态 | 持续资源、队列和存储增长 | 未验证 | 未执行约定时长的长稳态测试；功能套件运行时长不能代替持续负载下的内存、队列和存储增长验证。 |
| I16 | 生产供应商与灾备 | 真实供应商、轮换及 RPO/RTO | 未验证 | 没有生产 APNs、扫描器、对象存储/CDN 凭据与灾备目标；未验证真实供应商、密钥轮换、跨环境恢复或 RPO/RTO。 |


## 后续验收条件

先处理上面的失败与测试合同冲突并复验对应场景，再确定目标并发、吞吐、P95/P99 延迟和持续运行时长。生产供应商联调需要实际 APNs、扫描器、对象存储/CDN 配置；灾备需要指定恢复环境和 RPO/RTO。当前逻辑恢复补验不覆盖 WAL/PITR、跨区域切换或生产密钥轮换。

清理已确认：本次创建的数据库无残留；原 imv2-tests VM 已停止；新建的强杀测试 VM 已删除；Docker context 恢复 default。详见 `cleanup-result.json`。

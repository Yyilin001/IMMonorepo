# V2 当前实现与发布证据

最后审阅：2026-09-06
适用范围：当前 `IMV2Core`、`IMV2ClientKit`、`IMV2Server`、`IMApp` 与 `IMV2` 工具链。

本文件只登记当前合同和可重复证据，不保留开发时间线。仓库内实现与本机测试通过不等于
生产发布批准；需要真实凭据、设备、供应商、容量或运维环境的项目单列为外部风险。

## 证据等级

| 状态 | 含义 |
| --- | --- |
| 仓库内已实现 | 当前运行路径存在，且由相应层级的自动化验证覆盖 |
| 本机集成已验证 | 使用一次性数据库、容器、Simulator 或本地 TLS 栈验证；不外推到生产 |
| 外部未闭环 | 仍需要部署平台、真实凭据/设备、供应商、容量报告或人工审批 |

## 当前兼容与 Schema 政策

- 项目尚未上线；只支持仓库明确提供并由回归覆盖的受控迁移，不自动兼容任意旧协议、数据库、`.env.local` 或测试替身。
- wire contract 为 protobuf protocol 27；生成物必须与
  [`Protocol/im_realtime/v2/im_v2.proto`](../../Protocol/im_realtime/v2/im_v2.proto) 一致。
  房间 continuation 表示已认证扫描到的序号，可越过不可见尾部；旧客户端严格相等校验不兼容，见[读取与游标合同](../../docs/reviews/message-mutation-read-contract.md)。
  新编辑携带接受身份与显式完整状态以跨越合法版本缺口，见[完整编辑合同](../../docs/reviews/message-edit-replacement-contract.md)。
- PostgreSQL 新环境从空数据库执行 [`IMV2/sql/schema.sql`](../sql/schema.sql)。当前结构为
  `im-v2-current-30`；这是唯一新环境建库合同。仅撤销凭据已随注册事务原子交付、与 access/refresh 同项保存，刷新保持原证明与期限，见[原子签发合同](../../docs/reviews/atomic-revocation-credential-issue-contract.md)。真实 HTTPS/App 链路已验证；[独立持久退出交接](../../docs/reviews/device-revocation-handoff-contract.md)已接入，原凭据删除前保留撤销任务，[独立执行器与本地退出](../../docs/reviews/device-revocation-runner-contract.md)已接通前台重试，[暂停反馈与恢复](../../docs/reviews/device-revocation-status-contract.md)已完成，完整生命周期交互验收仍待完成。设备会话保存默认 30 天绝对截止，刷新、认证及 Push/媒体授权不能越过期限；见[期限合同](../../docs/reviews/device-session-absolute-expiry-contract.md)。群角色的显式策略标记独立于可清理的操作回执。
  受控压测环境的既有 current-2 数据库可按 migration regression 覆盖的 expand 顺序在线更新，
  readiness 会拒绝缺少当前完整性合同的结构。schema 17 到 18 的群权限迁移要求停止旧进程，
  不支持混合版本运行；步骤、历史缺口处理和回退限制见[权限保留合同](../../docs/reviews/group-policy-retention.md)。
  schema 19→20 为群申请增加审核人＋决策操作唯一约束；新审批将成员、配额、事件、outbox 和
  申请记账放入一次事务。审批引用的成员操作回执已增加清理保留；旧 approving 的 D05 现有 owner 审计恢复已验证，B27 owner 路由仍开放，见
  [原子审批合同](../../docs/reviews/atomic-group-approval-contract.md)。
  普通成员变更在单库/分库组装中均保留 owner route/epoch，在回执重放前于事务内检查；其他房间写入与完整迁移仍开放，见[成员栅栏合同](../../docs/reviews/room-membership-owner-fence-contract.md)。
  schema 24→25 增加历史邀请目录的分页导入审计及 owner 全状态索引，独立 operator 原子导入/回滚并复核路由，见[导入合同](../../docs/reviews/group-invite-directory-import-contract.md)。
  历史 owner 已提交链接的创建重试沿用原 ID/时间补目录，拒绝已有矛盾绑定，见[兼容合同](../../docs/reviews/group-invite-legacy-binding-contract.md)。
  schema 23→24 为 prepared 邀请目录添加持久恢复队列；Account 已接入有界认领、退避与暂停，原创建时间和本次判断时间分开，见[创建恢复合同](../../docs/reviews/group-invite-creation-recovery-contract.md)。
  schema 22→23 移除邀请/申请到 owner 身份表的四个外键；Account 已按持久 owner/epoch 路由，control 身份读取与 owner 事务分开，完整迁移与全局申请配额仍开放，见[owner 合同](../../docs/reviews/group-invitation-owner-routing-contract.md)。
  schema 21→22 增加 control 邀请 token 目录与稳定创建 intent，回填同库旧链接；后续 owner 接线见上文，见[目录合同](../../docs/reviews/group-invite-directory-contract.md)。
  schema 20→21 增加旧审批恢复审计、成员操作阻断及分批索引，独立 operator 入口已验证；
  [恢复合同](../../docs/reviews/group-approval-recovery-contract.md)要求完整成员历史，在线 owner 迁移仍待验收。
  schema 18→19 新增 Push 会话与意图版本存储，迁移也要求停止旧写进程；Account HTTP 与 ClientKit 版本传输已接通，持久意图存储已加入 SQLite；自动执行器及 App 开关/退出接线已验证，真实网络和账号生命周期组合仍开放，见[Push 意图合同](../../docs/reviews/push-intent-contract.md)及[HTTP 合同](../../docs/reviews/push-intent-http-contract.md)、[本地持久状态合同](../../docs/reviews/push-intent-local-contract.md)、[自动执行器合同](../../docs/reviews/push-intent-reconciler-contract.md)、[App 合同](../../docs/reviews/push-intent-app-contract.md)及[认证隔离合同](../../docs/reviews/push-intent-auth-contract.md)。
- ClientKit 主 SQLite 与派生搜索库分别有当前建库入口，主库还提供已验证的受控迁移。
  消息、reaction、公告、角色权限、置顶效果及恢复调度迁移见修复记录；当前 schema contract 测试固定 173/5 个对象指纹。
  protocol 27 包含显式个人快照重建和当前角色权限基线读取；SQLite 持久保存个人重建意图，
  角色权限已迁移为独立版本和显式空集合，恢复请求、完整观察点及本地栅栏已持久化；自动 runner 和 App 生命周期已接通，暂停反馈及显式重试入口已接通，真实链路及人工交互验收仍待完成，详见[状态与重试合同](../../docs/reviews/role-policy-recovery-ui-contract.md)、[执行器合同](../../docs/reviews/role-policy-recovery-runner-contract.md)、[恢复存储合同](../../docs/reviews/role-policy-recovery-store-contract.md)、[角色效果合同](../../docs/reviews/role-policy-effect-contract.md)、[个人基线恢复合同](../../docs/reviews/personal-snapshot-rebuild.md)及[权限基线合同](../../docs/reviews/group-policy-baseline-contract.md)。
- 服务端置顶快照已按已知源序号排序并保留取消状态；客户端快照键已兼容等价 UUID 拼写。客户端置顶四路 reducer、持久摘要与受控迁移已实现，缺序号旧历史权威恢复和统一发布切换仍待完成，见[置顶快照合同](../../docs/reviews/pin-snapshot-contract.md)及[客户端效果合同](../../docs/reviews/pin-effect-contract.md)。
- 服务端成员角色快照已按目标成员版本比较并通过真实逆序分发/快照回归；逐成员离开/重入的持久状态和客户端统一消费仍待完成，见[成员角色快照合同](../../docs/reviews/member-role-snapshot-contract.md)。
- 本地 `.env.local` 必须是脚本生成的当前 12 键私有文件；缺键、多键、旧键、弱值或陈旧
  PostgreSQL volume 都会失败并要求显式重建，不会静默修补。

## 当前能力矩阵

| 能力 | 当前实现 | 证据等级 | 仍需外部闭环 |
| --- | --- | --- | --- |
| TLS gateway 与协议 | TLS 1.3、protocol 27 协商、帧/深度/队列/请求上限、原子设备会话认证、心跳与关闭 | 仓库内已实现；package 和本地 gateway 回归 | 生产证书轮换、入口拓扑与故障演练 |
| 账户与设备凭据 | 独立 account service、密码 cost-12、跨副本限流、设备绑定 assertion、刷新/撤销/账号禁用 | 本机集成已验证 | WebAuthn RP verifier、challenge/counter store、生产 trusted-proxy 与审计审批 |
| 公开身份与联系人 | required account kind、精确 handle 查询、资料更新、关系/屏蔽、按上下文资料读取、active roster 公开身份 | 仓库内已实现；HTTP/SQLite/PostgreSQL/iOS 测试 | 真机离线、多语言与人工无障碍验收 |
| 私聊与普通群 | 幂等命令、事务准入；私聊可选 logical room-log：普通 accepted event 由 message-row 承载并与其他 room event 合并读取；revision-fenced fast append、有序原子微批与批量 credit；普通群仍走 outbox/planner/lease/inbox/user sync | PostgreSQL 集成回归；R29 单 Gateway 50k 在线、500–5,000 msg/s 限定写入验证 | 显式 room-log 恢复拉取、混合消息、多 Gateway、故障和长稳态报告 |
| 大群 Hybrid | 创建时固定 delivery mode；5,001...100,000 成员普通消息写 room log，显式 mention 才可靠 fan-out；客户端 cursor pull | 仓库内与 opt-in scale-shape 回归 | NATS 安全、持续负载、故障与设备可见延迟报告 |
| 群管理、邀请与审核 | 成员 seek pagination、角色权限、禁言、审计移除、公告、置顶、内容审核 lease 与受控 replay；审批式邀请链接、QR、撤销/次数/有效期、待审批分页与可恢复批准 | 仓库内已实现；域/HTTP/schema/Simulator 回归 | 真实双端邀请 E2E、链接滥用、生产密钥轮换、审核 provider、operator 访问与保留政策 |
| Sync 与 Snapshot V3 | per-user projection/checkpoint、statement-level checkpoint/effect capture、有界 artifact page、ACK-before-activate、独立 busy-drain compaction、retained floor、撤销设备清理 | 本机 PostgreSQL/ClientKit 故障回归 | 生产 replay window、存储阈值与长周期运行证据 |
| ClientKit 本地状态 | Keychain 设备会话、安装绑定、当前 SQLite schema、持久化 outbox、搜索派生库、有界历史定位、事件授权与 delivery mode 分离；群邀请只经认证 no-store HTTPS 传输 | 本机 ClientKit 全量及 iOS 聚焦回归 | 受保护数据、重启和真机 Keychain 发布验收 |
| 媒体 | 设备绑定上传/下载 grant、扫描/审核/清理 outbox；本地流式文件 provider 与 EICAR 夹具 | 本机集成已验证 | 生产对象存储、扫描器、CDN、multipart abort 与滥用测试 |
| Push 与实时提示 | 加密 APNs endpoint、generic wake；schema 19 条件意图存储；NATS 只作为可丢失提示，PostgreSQL/cursor 保持正确性 | 版本意图 HTTP/客户端传输、持久状态、自动执行器及 App 设置/退出接线已验证 | B16 真实网络与账号生命周期组合验收、真实 APNs、NATS TLS/NKey、broker 指标与 soak/failover |
| 用户分片 | 持久化 route/epoch、copy/verify、forwarding、cutover、rollback、target-first retry 与 source cleanup | 双 PostgreSQL 本机集成已验证 | 独立权限部署、网络分区、长时间 forwarding 与操作员演练 |
| 可观测与运维 | 低基数 metrics、paused work 告警、loopback operator、非破坏性 PostgreSQL 前后快照差值、host-local exporter、逻辑恢复 drill | 本机脚本与测试覆盖 | Alertmanager receiver、bastion/mTLS、WAL/PITR、RPO/RTO 演练 |
| iOS App | SwiftUI 状态、认证/同步、联系人、会话、群管理、邀请链接/QR/扫码/审批、媒体、Push 设置、离线 outbox；Swift 6 严格并发 | Simulator 构建、unit/UI 与本机双安装入口 | 真机签名、邀请双端、相机权限、APNs、完整 VoiceOver/Reduce Motion/对比度与发布验收 |

## 唯一本地总门禁

GitHub Actions 额度耗尽时，不降低验证范围；使用同一受版本控制的本地入口：

```sh
bash scripts/verify_v2.sh
```

该入口依次执行：

1. Core、ClientKit、Server package 测试；
2. protobuf、当前环境契约、PostgreSQL clean bootstrap/pg_dump drift、schema readiness、
   runtime env 与 Prometheus 检查；
3. 两个独立 PostgreSQL 实例上的完整 Server integration；
4. iOS generic Simulator build、App unit tests 与 signed-out UI tests。

可单独运行的诊断入口：

```sh
bash scripts/test_v2_postgres_schema_bootstrap.sh
bash scripts/run_v2_postgres_integration.sh
bash IMV2/scripts/test_v2_postgres_logical_restore.sh
bash IMV2/scripts/test_v2_local_environment_contract.sh
```

高成本容量回归为显式 opt-in，见
[`standard-100k.md`](09-capacity/standard-100k.md)。不得用普通 package 通过替代容量报告。

当前最新的实测证据是
[`R34 私聊 room-log 50,000 在线共享帧 A/B`](09-capacity/direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md)：
限定的单 Gateway 普通私聊写入、实时 payload 与 hint-triggered room-log 恢复路径完成 5,000 msg/s，
2,475,000 条发送全部 ACK。该场景没有独立固定的显式 room-log pull QPS，也未覆盖混合消息、
长时间 soak 或多 Gateway，所以不能据此批准完整高活跃 IM、100k 或生产 SLO。

## 当前实施路线

1. 选定生产部署平台，交付 account/gateway/operator/metrics 的最小权限部署、secret manager、
   TLS 轮换、数据库备份与回滚演练。
2. 完成生产 WebAuthn、对象存储/扫描器、APNs 和 Alertmanager 接入。
3. 在批准的普通聊天与热点群工作负载上测量 PostgreSQL/WAL、队列年龄、sync lag、连接池和
   拒绝行为，据此批准或下调 admission profile。
4. 完成 WAL/PITR、RPO/RTO、gateway/worker/database kill 与 NATS 分区演练。
5. 在单 store 首发稳定后，再批准多 store 分片迁移的生产启用。

开放风险及关闭条件以
[`residual-risk-register.md`](10-operations/residual-risk-register.md) 为准。

B18 本地历史定位已完成 1k/100k 数据量、同键活动、取消/刷新及真实 SwiftUI 滚动验收，见[定位合同](../../docs/reviews/timeline-location-contract.md)。此结果不扩大上文服务端容量结论。

邀请申请的单库申请人配额已增加事务互斥并通过真实并发回归；跨 owner 全局 reservation 与终态释放仍开放，见[配额合同](../../docs/reviews/invitation-applicant-quota-contract.md)。

已补[签发取消与活动旧凭据替换](../../docs/reviews/credential-issuance-boundaries-contract.md)及[已收到结果的持久交接](../../docs/reviews/received-credential-recovery-contract.md)：返回前保存撤销能力，冷启动识别正常接管并恢复废弃结果，转交不重置已有任务。完全丢失签发响应及真机系统中断验收仍开放。

最新补充（B08 注册取消仲裁）：新增请求前可持有的独立取消证明、服务端取消记录，以及与签发共用事务的绑定；取消先到阻止签发，签发先到则原子撤销。锁后期限检查、证明四字段隔离、两侧回滚和旧迁移链共 21 项真实 PostgreSQL 测试通过，Core 95 项、原有 HTTP 单元 10 项通过。PostgreSQL 升至 29，见[合同](../../docs/reviews/registration-cancellation-contract.md)。HTTP/App 尚未切换到新证明，完全丢失响应的端到端恢复仍开放，B08 及全部 47 项状态不变。

最新补充（B08 取消 HTTP）：账号服务已挂载受 trusted-edge 和地址限流保护的注册取消路由，ClientKit 增加不依赖登录凭据的传输。ClientKit 453 项实际执行（5 跳过）、HTTP 单元 13 项、真实 PostgreSQL 22 项通过；真实 HTTPS 5 项验证取消提交后丢弃客户端结果、原证明重放仍只有一条取消记录。见[HTTP 合同](../../docs/reviews/registration-cancellation-http-contract.md)及[证据](../../docs/reviews/evidence/20260907-registration-cancellation-http/manifest.json)。HTTP 签发强制证明与 App 请求前持久化/独立取消队列仍开放，16 项已验证、31 项开放不变。


最新补充（2026-09-07，B08 签发证明绑定）：[请求前持久化与强制 HTTP 绑定](../../docs/reviews/proof-bound-issuance-contract.md)已实现，注册 ledger 升为 format 2；缺少或不匹配确认会先交接收到的撤销能力再拒绝登录，旧记录保留档案，过期尝试保留证明并换用新身份。客户端 **462 项报告 / 457 项实际执行**、接口 **14 项**、真实 PostgreSQL **22 项**、App **197 项报告 / 196 项实际执行**通过；最终真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过。数据库设备/撤销/残留访问/残留刷新/事件为 **16|7|0|0|7**，取消记录总数/绑定/取消为 **17|16|2**；独立补偿允许多个操作指向同一已撤销设备，事件仍不重复。脚本调用同步补齐证明，Compose 栈脚本只做语法及共用工具离线检查。初始解码错误、旧 UI 夹具和旧统计假设的失败均留档；最终专用资源已移除。见[证据](../../docs/reviews/evidence/20260907-proof-bound-issuance/manifest.json)。自动取消执行器、冷启动请求前证明归属、旧会话清理和真机系统中断仍开放；47 项仍为 **16 已验证、31 开放**，B08 不关闭。


最新补充（2026-09-07，B08 遗弃注册自动取消）：[执行器与冷启动归属](../../docs/reviews/registration-cancellation-runner-contract.md)已接入 App。format 3 原子迁移旧证明并保存尝试次数、退避和暂停，冷启动只把未被当前持久凭据接管的 pending 入队；前台观察自动执行，后台取消并等待实际请求结束，清理反馈和手动重试覆盖两类队列。客户端 **472 项报告 / 467 项实际执行**、签名 App **199 项报告 / 198 项实际执行**通过；真实 Keychain 验证归属及暂停反馈。真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过，验证签发和取消响应相继丢失后仍使用原证明重试。数据库 **16|7|0|0|7**，取消记录 **17|16|2**，取消 HTTP 204 四次但记录不重复；专用资源已清理。见[证据](../../docs/reviews/evidence/20260907-registration-cancellation-runner/manifest.json)。旧会话/legacy 档案清理、真实强杀/锁屏/系统后台和记录 GC 仍开放；B08 保持实施中，全部 47 项仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 实际进程中断）：[真实 App 两次终止后恢复](../../docs/reviews/registration-process-interruption-contract.md)已通过。HTTPS 代理在服务端签发/取消分别提交后保留响应，受控终止专用模拟器里的 App；第二次重启从真实 Keychain 使用原证明重放，并完成新设备登录。原设备单独核对 **2|1|1|1|0|0**（账号设备数/原设备撤销/证明取消记录/事件/有效 access/有效 refresh）；没有重复事件。同期修复命令行证明将 DeviceID 误编码为字符串的问题，真实凭据准备脚本的签发、鉴权和取消通过。最终 **5 项原生 HTTPS、3 项 App UI、1 项独立后台入口**通过，全库 **19|9|0|0|9**、取消记录 **20|19|4**。见[证据](../../docs/reviews/evidence/20260907-registration-process-interruption/manifest.json)。这是 simctl 受控进程终止，不等同于 SIGKILL/OS jetsam/真机锁屏；legacy 清理及其他检查点仍开放。47 项仍 **16 已验证、31 开放**。


2026-09-07，B08 旧注册档案：新增[服务端取消仲裁](../../docs/reviews/legacy-registration-arbitration-contract.md)，以重新验证的账号权限限定清理范围；账号/注册锁内持久取消、原子撤销并拒绝同账号迟到签发。每账号上限 256 条，29→30 保留既有凭据且不推断历史取消。启用前必须停止全部旧签发进程。HTTP、ClientKit 与 App 的 legacy 清理尚未接线，记录 GC 及完整系统生命周期验收仍开放。


2026-09-07，B08 已接通[旧注册清理 HTTP](../../docs/reviews/legacy-registration-http-contract.md)：生产账号入口校验新设备绑定的短期账号证明，加入可信边缘和持久地址限流。18 项接口、26 项 PostgreSQL、5 项真实 HTTPS 基线与新增真实密码/清理扩展通过；ClientKit/App 旧档案恢复仍待接线。


2026-09-07，B08 [客户端旧档案恢复](../../docs/reviews/legacy-registration-client-recovery-contract.md)已加入 App 登录：复用一次账号因子完成旧注册清理及新凭据签发。原注册尝试和完整档案 CAS 防止迟到确认覆盖，错误与容量反馈保留记录；最多一个额外位置供满额旧档案恢复。真实 Keychain 与 ClientKit/HTTPS 分层验收通过，实际 App legacy 交互/进程中断与真机边界仍开放。


2026-09-07，B08 [实际 App 旧档案跨进程恢复](../../docs/reviews/legacy-registration-app-process-contract.md)已通过：真实 Keychain、清理响应前受控终止、新证明重放、新登录及再次冷恢复，服务端目标无有效凭据残留或重复事件。DEBUG 种子及清理只作用于隔离测试域，拒绝覆盖已有档案。真机、其他检查点和永久冲突/GC 仍开放。


最新补充（2026-09-07，B01 服务端时钟）：[账号证明与 Gateway 时钟边界](../../docs/reviews/server-clock-integer-boundaries.md)已补检查；独立进程复现 NaN 转 Int64 fatal error 后，新增非有限值、有效期相加越界和不可用编码截止的拒绝。Hello 在状态变更前检查，心跳覆盖异步准入后再次失效并释放请求关联；凭据接口将时钟故障返回为空正文、不缓存的 503，修复前错误 401 的三条失败断言留档。最终服务端 **57 项 / 7 套件（6.387 秒）**、真实 HTTPS **5 项 / 2 套件（2.734 秒）**、App UI **2 项（64.268 秒）**、独立后台入口 **1 项（1.298 秒）**通过。数据库 **16|7|0|0|7**、注册取消记录 **17|16|2**，专用数据库根与模拟器已独立核实移除。见[证据](../../docs/reviews/evidence/20260907-server-clock-boundaries/manifest.json)。这不是远端可控时间戳攻击的证明；其余恢复 DTO、计数和时间消费者继续审计，B01 仍实施中，全部47项保持 **16 已验证、31 开放**。

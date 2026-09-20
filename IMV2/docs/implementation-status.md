# V2 当前实现与发布证据

最后审阅：2026-09-06
适用范围：当前 `IMV2Core`、`IMV2ClientKit`、`IMV2Server`、`IMApp` 与 `IMV2` 工具链。

本文件只登记当前合同和可重复证据，不保留开发时间线。仓库内实现与本机测试通过不等于
生产发布批准；需要真实凭据、设备、供应商、容量或运维环境的项目单列为外部风险。

> 本文件回答"现在有哪些能力、证据到什么等级"。**哪个文件是当前合同**见
> [V2 文档索引](../../docs/reviews/README.md)；**哪些问题还没关闭**见
> [问题状态表](../../docs/reviews/status.md)；整改期的逐批记录已移入
> [历史时间线](../../docs/reviews/archive/2026-09-05-remediation-timeline.md)，
> 不要再把过程记录追加回本文件。

## 证据等级

| 状态 | 含义 |
| --- | --- |
| 仓库内已实现 | 当前运行路径存在，且由相应层级的自动化验证覆盖 |
| 本机集成已验证 | 使用一次性数据库、容器、Simulator 或本地 TLS 栈验证；不外推到生产 |
| 外部未闭环 | 仍需要部署平台、真实凭据/设备、供应商、容量报告或人工审批 |

## 当前兼容与 Schema 政策

- 项目尚未上线；服务端仅以当前协议、当前 schema 和全新数据库为基线，不提供历史兼容或在线数据迁移。
- wire contract 为 protobuf protocol 30；生成物必须与
  [`Protocol/im_realtime/v2/im_v2.proto`](../../Protocol/im_realtime/v2/im_v2.proto) 一致。
  房间 continuation 表示已认证扫描到的序号，可越过不可见尾部；旧客户端严格相等校验不兼容，见[读取与游标合同](../../docs/reviews/message-mutation-read-contract.md)。
  私聊与群聊的公共内容统一以房间日志为权威副本，不再提供 fanout 兼容模式；个人事件流保存个人状态与单侧提示。
  新编辑携带接受身份与显式完整状态以跨越合法版本缺口，见[完整编辑合同](../../docs/reviews/message-edit-replacement-contract.md)。
- PostgreSQL 新环境从空数据库执行 [`IMV2/sql/schema.sql`](../sql/schema.sql)。当前结构为
  `im-v2-current-51`；这是唯一新环境建库合同。仅撤销凭据已随注册事务原子交付、与 access/refresh 同项保存，刷新保持原证明与期限，见[原子签发合同](../../docs/reviews/atomic-revocation-credential-issue-contract.md)。真实 HTTPS/App 链路已验证；[独立持久退出交接](../../docs/reviews/device-revocation-handoff-contract.md)已接入，原凭据删除前保留撤销任务，[独立执行器与本地退出](../../docs/reviews/device-revocation-runner-contract.md)已接通前台重试，[暂停反馈与恢复](../../docs/reviews/device-revocation-status-contract.md)已完成，完整生命周期交互验收仍待完成。设备会话保存默认 30 天绝对截止，刷新、认证及 Push/媒体授权不能越过期限；见[期限合同](../../docs/reviews/device-session-absolute-expiry-contract.md)。群角色的显式策略标记独立于可清理的操作回执。
  readiness 拒绝不符合当前结构的数据库；旧压测库须重建，不提供在线升级。
  schema 19→20 为群申请增加审核人＋决策操作唯一约束；新审批将成员、配额、事件、outbox 和
  申请记账放入一次事务。审批引用的成员操作回执已增加清理保留；旧 approving 及其恢复服务已删除，B27 owner 路由仍开放，见
  [原子审批合同](../../docs/reviews/atomic-group-approval-contract.md)。
  普通成员变更在单库/分库组装中均保留 owner route/epoch，在回执重放前于事务内检查；其他房间写入的原缺陷验收仍开放，见[成员栅栏合同](../../docs/reviews/room-membership-owner-fence-contract.md)。
  历史邀请目录分页导入已移除，不再提供旧数据回填入口。
  当前 owner 已提交链接的创建重试沿用原 ID/时间补目录，拒绝已有矛盾绑定，见[创建重试合同](../../docs/reviews/group-invite-legacy-binding-contract.md)。
  schema 23→24 为 prepared 邀请目录添加持久恢复队列；Account 已接入有界认领、退避与暂停，原创建时间和本次判断时间分开，见[创建恢复合同](../../docs/reviews/group-invite-creation-recovery-contract.md)。
  schema 22→23 移除邀请/申请到 owner 身份表的四个外键；Account 已按持久 owner/epoch 路由，control 身份读取与 owner 事务分开，全局申请配额另行验收，见[owner 合同](../../docs/reviews/group-invitation-owner-routing-contract.md)。
  schema 21→22 增加 control 邀请 token 目录与稳定创建 intent；后续 owner 接线见上文，见[目录合同](../../docs/reviews/group-invite-directory-contract.md)。
  schema 51 移除旧审批恢复、历史邀请导入和旧注册取消的四张专用表。
  当前 schema 包含 Push 会话与意图版本存储；Account HTTP 与 ClientKit 版本传输已接通，持久意图存储已加入 SQLite；自动执行器及 App 开关/退出接线已验证，真实网络和账号生命周期组合仍开放，见[Push 意图合同](../../docs/reviews/push-intent-contract.md)及[HTTP 合同](../../docs/reviews/push-intent-http-contract.md)、[本地持久状态合同](../../docs/reviews/push-intent-local-contract.md)、[自动执行器合同](../../docs/reviews/push-intent-reconciler-contract.md)、[App 合同](../../docs/reviews/push-intent-app-contract.md)及[认证隔离合同](../../docs/reviews/push-intent-auth-contract.md)。
- ClientKit 主 SQLite 与派生搜索库分别有当前建库入口，主库还提供已验证的受控迁移。
  消息、reaction、公告、角色权限、置顶效果及恢复调度迁移见修复记录；当前 schema contract 测试固定 173/5 个对象指纹。
  protocol 30 包含显式个人快照重建和当前角色权限基线读取；SQLite 持久保存个人重建意图，
  角色权限已迁移为独立版本和显式空集合，恢复请求、完整观察点及本地栅栏已持久化；自动 runner 和 App 生命周期已接通，暂停反馈及显式重试入口已接通，真实链路及人工交互验收仍待完成，详见[状态与重试合同](../../docs/reviews/role-policy-recovery-ui-contract.md)、[执行器合同](../../docs/reviews/role-policy-recovery-runner-contract.md)、[恢复存储合同](../../docs/reviews/role-policy-recovery-store-contract.md)、[角色效果合同](../../docs/reviews/role-policy-effect-contract.md)、[个人基线恢复合同](../../docs/reviews/personal-snapshot-rebuild.md)及[权限基线合同](../../docs/reviews/group-policy-baseline-contract.md)。
- 服务端置顶快照已按已知源序号排序并保留取消状态；客户端快照键已兼容等价 UUID 拼写。客户端置顶四路 reducer、持久摘要与受控迁移已实现，缺序号旧历史权威恢复和统一发布切换仍待完成，见[置顶快照合同](../../docs/reviews/pin-snapshot-contract.md)及[客户端效果合同](../../docs/reviews/pin-effect-contract.md)。
- 服务端成员角色快照已按目标成员版本比较并通过真实逆序分发/快照回归；逐成员离开/重入的持久状态和客户端统一消费仍待完成，见[成员角色快照合同](../../docs/reviews/member-role-snapshot-contract.md)。
- 会话列表由客户端 SQLite 按有效活动时间排序后分页。服务端提供 UserRoomDirectoryList/Page、RoomSyncStateBatch/Result、RoomLatestVisibleBatch/Result 和账号级房间变更通知；旧 RoomSummaryList/Page 与活动排行恢复入口已删除。
  客户端 V2RoomRecoveryRunner/Engine 管理持久化恢复待办；重连、通知覆盖失效及低频完整性核对触发目录扫描，在线变化按房间合并处理。摘要不推进正文游标，后台执行有预算且不宣告完整追平。
  房间日志内的显式 mention 使用推送提示，正文仍从日志恢复，不产生逐成员公共消息持久投递。当前实现与剩余验收见[会话同步验收状态](../../docs/reviews/client-owned-conversation-sync-acceptance.md)。
- 本地 `.env.local` 必须是脚本生成的当前 12 键私有文件；缺键、多键、旧键、弱值或陈旧
  PostgreSQL volume 都会失败并要求显式重建，不会静默修补。

## 当前能力矩阵

| 能力 | 当前实现 | 证据等级 | 仍需外部闭环 |
| --- | --- | --- | --- |
| TLS gateway 与协议 | TLS 1.3、protocol 30 协商、帧/深度/队列/请求上限、原子设备会话认证、心跳与关闭 | 仓库内已实现；package 和本地 gateway 回归 | 生产证书轮换、入口拓扑与故障演练 |
| 账户与设备凭据 | 独立 account service、密码 cost-12、跨副本限流、设备绑定 assertion、刷新/撤销/账号禁用 | 本机集成已验证 | WebAuthn RP verifier、challenge/counter store、生产 trusted-proxy 与审计审批 |
| 公开身份与联系人 | required account kind、精确 handle 查询、资料更新、关系/屏蔽、按上下文资料读取、active roster 公开身份 | 仓库内已实现；HTTP/SQLite/PostgreSQL/iOS 测试 | 真机离线、多语言与人工无障碍验收 |
| 私聊与普通群 | 公共内容统一房间日志；幂等命令、事务准入、按房间游标恢复；个人流承载个人状态 | PostgreSQL、ClientKit 与本机 TLS/App 分层证据见会话同步验收状态 | 全链路规模、故障与长稳态验收 |
| 大群房间日志 | 公共内容使用房间日志；账号级变化通知与有界详细订阅分离，mention 仅作推送提示 | 仓库内覆盖与缓冲区回归 | 持续负载、故障与设备可见延迟报告 |
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
5. 使用部署前确定的静态分片配置；在线数据迁移不纳入首版。

开放风险及关闭条件以
[`residual-risk-register.md`](10-operations/residual-risk-register.md) 为准。

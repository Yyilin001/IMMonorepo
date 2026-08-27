# V2 当前实现与发布证据

最后审阅：2026-08-27
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

- 项目尚未上线，不支持旧协议、旧 SQLite、旧 PostgreSQL volume、旧 `.env.local` 或旧测试替身。
- wire contract 为 protobuf protocol 19；生成物必须与
  [`Protocol/im_realtime/v2/im_v2.proto`](../../Protocol/im_realtime/v2/im_v2.proto) 一致。
- PostgreSQL 新环境从空数据库执行 [`IMV2/sql/schema.sql`](../sql/schema.sql)。当前结构为
  122 张表、300 个索引、8 个非内部 trigger、8 个 schema function；这是唯一建库合同。
  受控压测环境的既有 current-2 数据库可按 migration regression 覆盖的 expand 顺序在线更新，
  readiness 会拒绝缺少 statement-level Sync 或 fresh-direct 完整性合同的旧结构。
- ClientKit 主 SQLite 与派生搜索库分别只有一个当前建库入口；已有本地数据库不升级，
  由认证同步重建。schema contract 测试固定 161/5 个对象指纹并执行约束探针。
- 本地 `.env.local` 必须是脚本生成的当前 11 键私有文件；缺键、多键、旧键、弱值或陈旧
  PostgreSQL volume 都会失败并要求显式重建，不会静默修补。

## 当前能力矩阵

| 能力 | 当前实现 | 证据等级 | 仍需外部闭环 |
| --- | --- | --- | --- |
| TLS gateway 与协议 | TLS 1.3、protocol 19 协商、帧/深度/队列/请求上限、原子设备会话认证、心跳与关闭 | 仓库内已实现；package 和本地 gateway 回归 | 生产证书轮换、入口拓扑与故障演练 |
| 账户与设备凭据 | 独立 account service、密码 cost-12、跨副本限流、设备绑定 assertion、刷新/撤销/账号禁用 | 本机集成已验证 | WebAuthn RP verifier、challenge/counter store、生产 trusted-proxy 与审计审批 |
| 公开身份与联系人 | required account kind、精确 handle 查询、资料更新、关系/屏蔽、按上下文资料读取、active roster 公开身份 | 仓库内已实现；HTTP/SQLite/PostgreSQL/iOS 测试 | 真机离线、多语言与人工无障碍验收 |
| 私聊与普通群 | 幂等命令、事务准入；私聊可选 logical room-log：普通 accepted event 由 message-row 承载并与其他 room event 合并读取；revision-fenced fast append、有序原子微批与批量 credit；普通群仍走 outbox/planner/lease/inbox/user sync | PostgreSQL 集成回归；R29 单 Gateway 50k 在线、500–5,000 msg/s 限定写入验证 | 显式 room-log 恢复拉取、混合消息、多 Gateway、故障和长稳态报告 |
| 大群 Hybrid | 创建时固定 delivery mode；5,001...100,000 成员普通消息写 room log，显式 mention 才可靠 fan-out；客户端 cursor pull | 仓库内与 opt-in scale-shape 回归 | NATS 安全、持续负载、故障与设备可见延迟报告 |
| 群管理与审核 | 成员 seek pagination、角色权限、禁言、审计移除、公告、置顶、内容审核 lease 与受控 replay | 仓库内已实现 | 生产审核 provider、operator 访问与保留政策 |
| Sync 与 Snapshot V3 | per-user projection/checkpoint、statement-level checkpoint/effect capture、有界 artifact page、ACK-before-activate、独立 busy-drain compaction、retained floor、撤销设备清理 | 本机 PostgreSQL/ClientKit 故障回归 | 生产 replay window、存储阈值与长周期运行证据 |
| ClientKit 本地状态 | Keychain 设备会话、安装绑定、当前 SQLite schema、持久化 outbox、搜索派生库、事件授权与 delivery mode 分离 | 本机 198 项 ClientKit 回归及 iOS 聚焦回归 | 受保护数据、重启和真机 Keychain 发布验收 |
| 媒体 | 设备绑定上传/下载 grant、扫描/审核/清理 outbox；本地流式文件 provider 与 EICAR 夹具 | 本机集成已验证 | 生产对象存储、扫描器、CDN、multipart abort 与滥用测试 |
| Push 与实时提示 | 加密 APNs endpoint、generic wake；NATS 只作为可丢失提示，PostgreSQL/cursor 保持正确性 | 仓库内已实现，本地 broker 回归 | 真实 APNs、NATS TLS/NKey、broker 指标与 soak/failover |
| 用户分片 | 持久化 route/epoch、copy/verify、forwarding、cutover、rollback、target-first retry 与 source cleanup | 双 PostgreSQL 本机集成已验证 | 独立权限部署、网络分区、长时间 forwarding 与操作员演练 |
| 可观测与运维 | 低基数 metrics、paused work 告警、loopback operator、非破坏性 PostgreSQL 前后快照差值、host-local exporter、逻辑恢复 drill | 本机脚本与测试覆盖 | Alertmanager receiver、bastion/mTLS、WAL/PITR、RPO/RTO 演练 |
| iOS App | SwiftUI 状态、认证/同步、联系人、会话、群管理、媒体、Push 设置、离线 outbox；Swift 6 严格并发 | Simulator 构建、unit/UI 与本机双安装入口 | 真机签名、APNs、完整 VoiceOver/Reduce Motion/对比度与发布验收 |

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

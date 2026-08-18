# V2 ADR 登记册

最后审阅：2026-08-18
维护者：V2 架构负责人

本登记册对应架构规范第 11 节要求的初始 ADR 集合。`已接受`仅表示设计
方向已经确定；具体实现、本机自动化验证、压测和运行证据仍以
[`implementation-status.md`](implementation-status.md) 为准。

| 规范要求 | ADR | 状态 | 当前证据/阻塞 |
| --- | --- | --- | --- |
| Native TLS TCP 与客户端平台 | [ADR-003](00-foundation/ADR-003-native-tls-and-platforms.md) | 待批准 | TLS gateway 已实现；发布平台与证书策略未批准 |
| PostgreSQL 权威状态与事件模型 | [ADR-004](00-foundation/ADR-004-postgresql-authoritative-state.md) | 已接受 | V2 schema、PostgreSQL stores 与集成测试目标 |
| 命令幂等、outbox/inbox、至少一次 | [ADR-005](00-foundation/ADR-005-idempotency-outbox-inbox.md) | 已接受 | Core contracts、唯一约束、fan-out/sync stores |
| Room/user shard 路由与迁移 | [ADR-006](00-foundation/ADR-006-routing-and-migration.md) | 待批准 | capacity lease、持久化 logical router、epoch-CAS cutover、迁移阶段/retention lease 与 stale-route fenced handoff 已实现；双 PostgreSQL 集成已验证，生产分区/长周期 forwarding 与操作员演练待定 |
| sync cursor、snapshot reset、多设备 | [ADR-007](00-foundation/ADR-007-sync-cursor-and-snapshot.md) | 已接受 | Server sync、Client SQLite 与 snapshot tests |
| sync projection checkpoint、日志保留与 compaction | [ADR-013](00-foundation/ADR-013-sync-checkpoint-and-log-retention.md) | 已接受并实施 | Snapshot V3、statement-level checkpoint/effect capture、独立 busy-drain compactor、set-based shared-payload GC、低游标 reset 及分片 copy/fingerprint 已实施；生产 replay window/阈值仍需容量校准 |
| 消息投影正文单写与用户窄引用 | [ADR-014](00-foundation/ADR-014-shared-message-projection-state.md) | 已接受并实施 expand 阶段 | immutable shared state、双读写、bounded backfill、跨 shard copy、Snapshot/media join、GC/指标与在线 schema 变更已实现；生产灰度、真实数据审计和收益压测待执行 |
| 私聊权威受众直达投递 | [ADR-015](00-foundation/ADR-015-direct-preplanned-fanout.md) | 已接受并实施，可配置灰度 | exact-two/one-unit 数据库约束、不可变 delivery identity、同事务 plan/unit/deliveries、双副本 target-user 公平微批、route 回退与 poison 隔离已集成验证；真实环境 A/B 与长稳态证据待执行 |
| 私聊房间事件日志恢复 | [ADR-017](00-foundation/ADR-017-direct-room-event-log.md) | 已接受，受运行时开关保护 | `room_log` 将 `message.accepted` 的可靠源收敛为 canonical `room_events`；客户端按 revision-fenced room cursor 恢复，在线提示仅为水线。编辑、撤回、reaction 尚未切换，真实环境 A/B 与长稳态证据待执行 |
| 单节点数据库工作负载隔离与投影批处理 | [ADR-016](09-capacity/ADR-016-single-node-runtime-workload-isolation.md) | 已接受并实施，可独立回滚 | 五类 pool 预算、foreground/Sync 短队列、Projection 并行与 accepted 批量 SQL、Sync hint 合并、Sync 往返压缩和运行压力指标已实现；真实环境对照压测待执行 |
| 移动前后台与 Push wake | [ADR-008](00-foundation/ADR-008-mobile-lifecycle-and-push.md) | 待批准 | durable wake/预算、APNs provider、加密端点与 iOS 明确开关已实现；资格/活动策略与真实 APNs 发布证据待定 |
| Auth、设备撤销、本地存储、媒体授权、日志脱敏 | [ADR-009](00-foundation/ADR-009-auth-local-storage-and-redaction.md) | 部分待批准 | auth/keychain 已实现；媒体授权待 ADR-002 |
| 容量、fenced admission、Push 预算、PITR/DR | [ADR-010](09-capacity/ADR-010-capacity-and-disaster-recovery.md) | 待批准 | admission lease 基元存在；目标、演练和报告缺失 |
| Passkey 优先、密码兜底与设备绑定账户断言 | [ADR-011](00-foundation/ADR-011-account-factor-policy.md) | 已接受 | 客户端 AuthenticationServices / HTTP 适配与 bcrypt fallback 已实现；生产 WebAuthn RP verifier 与一次性挑战存储待接入 |
| 公开身份、联系人发现与目录边界 | [ADR-012](00-foundation/ADR-012-public-identity-and-discovery.md) | 已接受并完成当前首发范围 | 独立公开 `@handle`、认证精确查询、账号级限流、注册原子 profile 创建和本人显示名修改已经落地；有界群成员目录返回公开资料并在 App 展示。direct room 创建会向双方写入仅含对端公开资料的同步基线，snapshot reset 由 active direct pair 重建该有界投影；显示名修改经独立 durable outbox 按接收者预算增量投递，使用 checkpoint、幂等键和迁移 shadow forwarding。剩余门槛是真机多设备/离线 E2E、删除与 handle 改名策略，以及资料传播容量阈值；群成员资料仍按需读取，不做 roster fan-out。 |

额外 ADR：

- [ADR-000：绿地重构边界](00-foundation/ADR-000-greenfield-cutover.md)（已接受）
- [ADR-001：审核与追溯处理](05-domain/ADR-001-moderation-policy.md)（已接受常规聊天基线）
- [ADR-002：关系、媒体与提及](05-domain/ADR-002-social-media-mention-policy.md)（已接受常规聊天基线）

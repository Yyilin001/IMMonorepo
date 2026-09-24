# V2 ADR 登记册

最后审阅：2026-09-03
维护者：V2 架构负责人

本登记册对应架构规范第 11 节要求的初始 ADR 集合。`已接受`仅表示设计
方向已经确定；具体实现、本机自动化验证、压测和运行证据仍以
[`implementation-status.md`](implementation-status.md) 为准。

| 规范要求 | ADR | 状态 | 当前证据/阻塞 |
| --- | --- | --- | --- |
| Native TLS TCP 与客户端平台 | [ADR-003](00-foundation/ADR-003-native-tls-and-platforms.md) | 待批准 | TLS gateway 已实现；发布平台与证书策略未批准 |
| PostgreSQL 权威状态与事件模型 | [ADR-004](00-foundation/ADR-004-postgresql-authoritative-state.md) | 已接受 | V2 schema、PostgreSQL stores 与集成测试目标 |
| 命令幂等、outbox/inbox、至少一次 | [ADR-005](00-foundation/ADR-005-idempotency-outbox-inbox.md) | 已接受 | Core contracts、唯一约束、fan-out/sync stores |
| Room/user shard 路由与迁移 | [ADR-006](00-foundation/ADR-006-routing-and-migration.md) | 路由待批准；在线迁移已删除 | 部署前配置固定的逻辑桶到物理库映射，room owner/epoch 在存储事务内校验；copy/verify、双写、cutover、rollback 与迁移运维入口已于 2026-09-20 删除，仅支持全新建库 |
| sync cursor、snapshot reset、多设备 | [ADR-007](00-foundation/ADR-007-sync-cursor-and-snapshot.md) | 已接受 | Server sync、Client SQLite 与 snapshot tests |
| sync projection checkpoint、日志保留与 compaction | [ADR-013](00-foundation/ADR-013-sync-checkpoint-and-log-retention.md) | 已接受并实施 | Snapshot V3、statement-level checkpoint/effect capture、独立 busy-drain compactor、set-based shared-payload GC、低游标 reset 及分片 copy/fingerprint 已实施；生产 replay window/阈值仍需容量校准 |
| 消息投影正文单写与用户窄引用 | [ADR-014](00-foundation/ADR-014-shared-message-projection-state.md) | 已被替代 | 公共消息统一由房间日志恢复；expand/dual/backfill/shared/contract 流程及相关 SQL 已删除，ADR 仅保留历史背景 |
| 私聊权威受众直达投递 | [ADR-015](00-foundation/ADR-015-direct-preplanned-fanout.md) | 已被替代 | planner/preplanned/fanout 模式及 `IM_V2_DIRECT_FANOUT_MODE` 已删除，私聊统一走房间日志（ADR-017）；ADR 仅保留历史背景 |
| 私聊房间事件日志恢复 | [ADR-017](00-foundation/ADR-017-direct-room-event-log.md) | 已接受，受运行时开关保护 | `room_log` 提供统一 logical room-event cursor；普通私聊 accepted event 可由带显式 storage fence 的 `messages` 行承载，其他事件仍使用 `room_events`，读取端合并两者。R29 已完成单 Gateway 50k 在线、500–5,000 msg/s 的限定写入证据；显式 room-log pull、多 Gateway、混合消息和 soak 尚未闭环。详见 [R29 report](09-capacity/direct-room-log-50000-gradient-r29-2026-08-27.md) |
| 有序私聊 room-log 原子微批 | [ADR-018](00-foundation/ADR-018-ordered-direct-room-log-microbatch.md) | 已接受并实施，受运行时开关保护 | PostgreSQL set-based batch CTE、锁内连续 sequence、bounded fairness/hot-room batch、revision-fenced fast cache 与每 micro-batch 一次的 credit actor 交互均已落地。R29 限定场景无拒绝完成 5,000 msg/s；不得以循环单条事务冒充批量化，也不得把未覆盖 pull 的结果外推为完整 IM 容量。 |
| 单节点数据库工作负载隔离与投影批处理 | [ADR-016](09-capacity/ADR-016-single-node-runtime-workload-isolation.md) | 已接受并实施，可独立回滚 | 五类 pool 预算、foreground/Sync 短队列、Projection 并行与 accepted 批量 SQL、Sync hint 合并、Sync 往返压缩和运行压力指标已实现；真实环境对照压测待执行 |
| 移动前后台与 Push wake | [ADR-008](00-foundation/ADR-008-mobile-lifecycle-and-push.md) | 待批准 | durable wake/预算、APNs provider、加密端点与 iOS 明确开关已实现；资格/活动策略与真实 APNs 发布证据待定 |
| Auth、设备撤销、本地存储、媒体授权、日志脱敏 | [ADR-009](00-foundation/ADR-009-auth-local-storage-and-redaction.md) | 部分待批准 | auth/keychain 已实现；媒体授权待 ADR-002 |
| 容量、fenced admission、Push 预算、PITR/DR | [ADR-010](09-capacity/ADR-010-capacity-and-disaster-recovery.md) | 待批准 | admission lease 基元存在；目标、演练和报告缺失 |
| Passkey 优先、密码兜底与设备绑定账户断言 | [ADR-011](00-foundation/ADR-011-account-factor-policy.md) | 已接受 | 客户端 AuthenticationServices / HTTP 适配与 Argon2id fallback 与有界密码工作池已实现；生产 WebAuthn RP verifier 与一次性挑战存储待接入 |
| 公开身份、联系人发现与目录边界 | [ADR-012](00-foundation/ADR-012-public-identity-and-discovery.md) | 已接受并完成当前首发范围 | 独立公开 `@handle`、认证精确查询、账号级限流、注册原子 profile 创建和本人显示名修改已经落地；有界群成员目录返回公开资料并在 App 展示。direct room 创建会向双方写入仅含对端公开资料的同步基线，snapshot reset 由 active direct pair 重建该有界投影；显示名修改经独立 durable outbox 按接收者预算增量投递，使用 checkpoint、幂等键和迁移 shadow forwarding。剩余门槛是真机多设备/离线 E2E、删除与 handle 改名策略，以及资料传播容量阈值；群成员资料仍按需读取，不做 roster fan-out。 |
| 群邀请链接、二维码与入群审批 | [ADR-019](00-foundation/ADR-019-group-invitation-and-approval.md) | 已接受并完成仓库内实现 | 令牌明文不落库、有效期/次数/撤销、待审批分页、两阶段可恢复批准、复合群外键、HTTPS 客户端与 iOS QR/深链已实现；真实双端、滥用与密钥轮换演练待闭环 |

额外 ADR：

- [ADR-000：绿地重构边界](00-foundation/ADR-000-greenfield-cutover.md)（已接受）
- [ADR-001：审核与追溯处理](05-domain/ADR-001-moderation-policy.md)（已接受常规聊天基线）
- [ADR-002：关系、媒体与提及](05-domain/ADR-002-social-media-mention-policy.md)（已接受常规聊天基线）

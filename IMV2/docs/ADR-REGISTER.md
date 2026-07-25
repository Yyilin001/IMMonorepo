# V2 ADR 登记册

最后审阅：2026-07-25
维护者：V2 架构负责人

本登记册对应架构规范第 11 节要求的初始 ADR 集合。`已接受`仅表示设计
方向已经确定；具体实现、CI、压测和运行证据仍以
[`implementation-status.md`](implementation-status.md) 为准。

| 规范要求 | ADR | 状态 | 当前证据/阻塞 |
| --- | --- | --- | --- |
| Native TLS TCP 与客户端平台 | [ADR-003](00-foundation/ADR-003-native-tls-and-platforms.md) | 待批准 | TLS gateway 已实现；发布平台与证书策略未批准 |
| PostgreSQL 权威状态与事件模型 | [ADR-004](00-foundation/ADR-004-postgresql-authoritative-state.md) | 已接受 | V2 schema、PostgreSQL stores 与集成测试目标 |
| 命令幂等、outbox/inbox、至少一次 | [ADR-005](00-foundation/ADR-005-idempotency-outbox-inbox.md) | 已接受 | Core contracts、唯一约束、fan-out/sync stores |
| Room/user shard 路由与迁移 | [ADR-006](00-foundation/ADR-006-routing-and-migration.md) | 待批准 | capacity lease、持久化 logical router、epoch-CAS cutover、迁移阶段/retention lease 与 stale-route fenced handoff 已实现；跨存储迁移证据待定 |
| sync cursor、snapshot reset、多设备 | [ADR-007](00-foundation/ADR-007-sync-cursor-and-snapshot.md) | 已接受 | Server sync、Client SQLite 与 snapshot tests |
| 移动前后台与 Push wake | [ADR-008](00-foundation/ADR-008-mobile-lifecycle-and-push.md) | 待批准 | durable wake/预算、APNs provider、加密端点与 iOS 明确开关已实现；资格/活动策略与真实 APNs 发布证据待定 |
| Auth、设备撤销、本地存储、媒体授权、日志脱敏 | [ADR-009](00-foundation/ADR-009-auth-local-storage-and-redaction.md) | 部分待批准 | auth/keychain 已实现；媒体授权待 ADR-002 |
| 容量、fenced admission、Push 预算、PITR/DR | [ADR-010](09-capacity/ADR-010-capacity-and-disaster-recovery.md) | 待批准 | admission lease 基元存在；目标、演练和报告缺失 |
| Passkey 优先、密码兜底与设备绑定账户断言 | [ADR-011](00-foundation/ADR-011-account-factor-policy.md) | 已接受 | 客户端 AuthenticationServices / HTTP 适配与 bcrypt fallback 已实现；生产 WebAuthn RP verifier 与一次性挑战存储待接入 |
| 公开身份、联系人发现与目录边界 | [ADR-012](00-foundation/ADR-012-public-identity-and-discovery.md) | Accepted（第一阶段已实现） | 独立公开 `@handle`、认证精确查询、账号级限流、注册原子 profile 创建和本人显示名修改已经落地；联系人、资料同步投影、会话标题和群成员显示名仍待完成 |

额外 ADR：

- [ADR-000：绿地重构边界](00-foundation/ADR-000-greenfield-cutover.md)（已接受）
- [ADR-001：审核与追溯处理](05-domain/ADR-001-moderation-policy.md)（已接受常规聊天基线）
- [ADR-002：关系、媒体与提及](05-domain/ADR-002-social-media-mention-policy.md)（已接受常规聊天基线）

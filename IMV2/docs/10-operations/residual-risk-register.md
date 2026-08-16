# V2 开放风险登记表

最后审阅：2026-08-16

本表只保留当前仓库无法诚实关闭的外部风险。已完成的重构和历史缺陷由测试与 Git 记录证明，
不继续堆积在风险表中。任何“已实现”都不能替代下面的部署、设备、容量或审批证据。

| ID | 开放风险 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-001 | 尚未选定生产部署拓扑、secret manager、证书轮换、operator 入口与回滚流程 | gateway/account/operator/metrics 进程边界分离；严格环境校验；operator 仅允许 loopback | 预发布环境完成最小权限部署、secret/TLS 轮换、bastion 或 mTLS、上线与回滚演练 |
| R-002 | Passkey 只有客户端与传输边界，缺生产 WebAuthn RP verifier 和一次性 challenge/counter store | 本地栈明确只启用密码因子；设备 assertion 短期且绑定 device ID | 完成 verifier、origin/RP/counter/重放测试、安全评审和真机注册/登录 |
| R-003 | 本地文件 provider 与 EICAR 夹具不是生产对象存储或恶意内容防护 | 上传/下载 grant、扫描/审核/清理 outbox 均设备绑定、短期、流式且失败不可引用 | 接入生产对象存储、扫描器/CDN，完成 multipart abort、滥用、故障恢复与保留测试 |
| R-004 | 双安装与无障碍 E2E 仍依赖本机 Docker、Simulator 和本地 CA | 受版本控制脚本使用随机账号、隔离 Keychain/SQLite scope 并清理 | 在受保护 runner 和两台真机执行，补齐 VoiceOver、Reduce Motion、对比度、离线重连与发布签名证据 |
| R-005 | APNs 尚无真实凭据、Push-enabled profile 和生产失效-token/后台唤醒证据 | Push 默认关闭；payload 不含内容；PostgreSQL sync 始终恢复正确性 | 真实 APNs 环境完成 opt-in/out、token 轮换、后台预算、失效与断网测试 |
| R-006 | NATS 缺 TLS/NKey、broker 指标、重连/分区 soak；100k 缺批准的生产负载报告 | NATS 只提示，授权/完成/重试由 PostgreSQL/cursor 决定；所有 mailbox/ACK 有上限 | 完成认证、指标、故障/soak 与 [`standard-100k`](../09-capacity/standard-100k.md) 发布报告 |
| R-007 | 逻辑 dump/restore 不证明 WAL/PITR、跨区恢复或批准的 RPO/RTO | 一次性 PostgreSQL drill 验证 schema 与 durable facts 可逻辑恢复 | 配置备份/WAL archive，执行时间点、密钥、故障转移和写入中断演练并批准 RPO/RTO |
| R-008 | GitHub Actions 额度已耗尽，远端 workflow 当前不能提供执行结果 | `bash scripts/verify_v2.sh` 在本机覆盖 package、schema、双 PostgreSQL 与 iOS 门禁；不宣称云 CI 通过 | 恢复额度或受保护自托管 runner，并在干净 checkout 上运行同一受版本控制入口 |

## 维护规则

- 新风险必须写清当前隔离和可验证关闭条件，不能只写“后续处理”。
- 外部风险关闭时提交实际报告/日志位置，并更新
  [`implementation-status.md`](../implementation-status.md) 的证据等级。
- 不允许以降低授权、幂等、持久化、重试、隐私或容量 fence 来规避本表。

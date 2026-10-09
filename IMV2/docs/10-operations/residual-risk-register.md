# V2 开放风险登记表

最后审阅：2026-10-01（实时通道改为 Actor；其余风险沿用各自证据）

本表只保留当前仓库无法诚实关闭的外部风险。已完成的重构和历史缺陷由测试与 Git 记录证明，
不继续堆积在风险表中。任何“已实现”都不能替代下面的部署、设备、容量或审批证据。

| ID | 开放风险 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-001 | 尚未选定生产部署拓扑、secret manager、证书轮换、operator 入口与回滚流程 | gateway/account/operator/metrics 进程边界分离；严格环境校验；operator 仅允许 loopback | 预发布环境完成最小权限部署、secret/TLS 轮换、bastion 或 mTLS、上线与回滚演练 |
| R-002 | Passkey 只有客户端与传输边界，缺生产 WebAuthn RP verifier 和一次性 challenge/counter store | 本地栈明确只启用密码因子；设备 assertion 短期且绑定 device ID | 完成 verifier、origin/RP/counter/重放测试、安全评审和真机注册/登录 |
| R-003 | 本地文件 provider 与 EICAR 夹具不是生产对象存储或恶意内容防护 | 上传/下载 grant、扫描/审核/清理 outbox 均设备绑定、短期、流式且失败不可引用 | 接入生产对象存储、扫描器/CDN，完成 multipart abort、滥用、故障恢复与保留测试 |
| R-004 | 双安装与无障碍 E2E 仍依赖本机 Docker、Simulator 和本地 CA | 受版本控制脚本使用随机账号、隔离 Keychain/SQLite scope 并清理 | 在受保护 runner 和两台真机执行，补齐 VoiceOver、Reduce Motion、对比度、离线重连与发布签名证据 |
| R-005 | APNs 尚无真实凭据、Push-enabled profile 和生产失效-token/后台唤醒证据 | Push 默认关闭；payload 不含内容；PostgreSQL sync 始终恢复正确性 | 真实 APNs 环境完成 opt-in/out、token 轮换、后台预算、失效与断网测试 |
| R-006 | Actor 实时路由缺部署级登记/队列/RPC 指标与长期重连/分区 soak；100k 缺批准的生产负载报告 | mTLS、服务签名、物理租约及兴趣修订隔离；授权/完成/重试由 PostgreSQL/cursor 决定；mailbox/ACK 有上限 | 完成部署指标、长期故障/soak 与 [`standard-100k`](../09-capacity/standard-100k.md) 发布报告 |
| R-007 | 逻辑 dump/restore 不证明 WAL/PITR、跨区恢复或批准的 RPO/RTO | 一次性 PostgreSQL drill 验证 schema 与 durable facts 可逻辑恢复 | 配置备份/WAL archive，执行时间点、密钥、故障转移和写入中断演练并批准 RPO/RTO |
| R-008 | 最终代码缺少远端或干净 checkout 的同版统一门禁证据；当前 CI 额度状态未复核 | `bash scripts/verify_v2.sh` 提供受版本控制的本地统一门禁入口；历史分层通过不宣称云 CI 或当前版本全量通过 | 在可用的远端或受保护自托管 runner 的干净 checkout 上，对最终代码运行并留存同一门禁结果 |
| R-009 | R51 已通过 50k 在线、5,000 msg/s 五分钟 room-log/Sync soak，但 30 分钟 checkpoint 周期、混合消息、多 Gateway 和故障恢复仍未覆盖，不能外推为生产高活跃 IM 容量 | PostgreSQL/cursor 保持权威；ACK-after-commit；有界 queue/credit/cache；严格凭证目标预检与 profile 隔离；[R51 report](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/IMV2/docs/09-capacity/direct-room-log-50000-profile-isolation-r51-2026-08-28.md) 记录完整梯度、资源和未覆盖项 | 固定快照执行至少 30 分钟 5,000 msg/s 并跨完整 checkpoint；随后加入附件/回复/群聊、离线恢复、多设备/热点、两 Gateway 和 kill/failover，以客户端延迟、零 gap/丢失及资源余量批准 SLO |
| R-010 | ARM64 Linux Gateway 曾在 50k 压力下于 `libdispatch` worker 内发生一次 SIGSEGV；R51 四轮与五分钟 soak 未复现，但缺原始 core/application frame，尚不能证明根因或宣称已根除 | signal source 改为进程级持有且退出前不取消；listener 启用 `SO_REUSEADDR`；R51 单轮 50k 在线约 13 分钟且无容器重启 | 使用当前 binary 完成数小时 50k soak、受控 SIGTERM/kill/restart 和 core dump 采集；零崩溃后再关闭，若复现则以 core/符号化栈定位并跟踪对应 Swift/libdispatch 修复 |

## 维护规则

- 新风险必须写清当前隔离和可验证关闭条件，不能只写“后续处理”。
- 外部风险关闭时提交实际报告/日志位置，并更新
  [`implementation-status.md`](../implementation-status.md) 的证据等级。
- 不允许以降低授权、幂等、持久化、重试、隐私或容量 fence 来规避本表。

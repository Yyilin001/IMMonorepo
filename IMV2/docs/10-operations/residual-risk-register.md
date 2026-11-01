# V2 开放风险登记表

最后审阅：2026-11-01（更新资源扫描、OSS/永久发送记录容量、本地文件读取边界与 Passkey 范围；其余风险沿用各自证据）

本表只保留当前仓库无法诚实关闭的外部风险。已完成的重构和历史缺陷由测试与 Git 记录证明，
不继续堆积在风险表中。任何“已实现”都不能替代下面的部署、设备、容量或审批证据。

| ID | 开放风险 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-001 | 尚未选定生产部署拓扑、secret manager、证书轮换、operator 入口与回滚流程 | gateway/account/operator/metrics 进程边界分离；严格环境校验；operator 仅允许 loopback | 预发布环境完成最小权限部署、secret/TLS 轮换、bastion 或 mTLS、上线与回滚演练 |
| R-002 | 后续启用 Passkey 的前置缺口：只有客户端与传输边界，缺生产 WebAuthn RP verifier 和一次性 challenge/counter store；不作为当前密码与恢复码交付的发布门槛 | App 隐藏 Passkey 入口且未声明关联域；当前账户服务使用密码与恢复码，设备 assertion 短期且绑定 device ID | 仅在决定启用 Passkey 后，完成 verifier、origin/RP/counter/重放测试、安全评审和真机注册/登录；当前不宣称支持 |
| R-003 | OSS 和 ClamAV 适配已实现；隔离 macOS/Linux 真实引擎已有证据，当前生产容器组装、签名更新、资源预算与 CDN 仍需验收 | 生产资源模式强制 ClamAV；启动检查干净/EICAR 样本，扫描错误不放行；官方 Linux arm64 包通过签名验证，真实引擎的干净/EICAR 与缺失签名检查通过，见[Linux 扫描证据](../../../docs/verification/resource-scanner-clamav-linux-20261101.json)及[资源扫描配置](../../../docs/proposals/aliyun-oss-integration.md#资源扫描配置) | 目标生产容器的安装、签名更新/失效恢复、并发与临时磁盘预算、CDN、multipart abort、滥用、故障恢复与保留测试 |
| R-004 | 双安装与无障碍 E2E 仍依赖本机 Docker、Simulator 和本地 CA | 受版本控制脚本使用随机账号、隔离 Keychain/SQLite scope 并清理 | 在受保护 runner 和两台真机执行，补齐 VoiceOver、Reduce Motion、对比度、离线重连与发布签名证据 |
| R-005 | APNs 尚无真实凭据、Push-enabled profile 和生产失效-token/后台唤醒证据 | Push 默认关闭；payload 不含内容；PostgreSQL sync 始终恢复正确性 | 真实 APNs 环境完成 opt-in/out、token 轮换、后台预算、失效与断网测试 |
| R-006 | Actor 实时路由缺部署级登记/队列/RPC 指标与长期重连/分区 soak；100k 缺批准的生产负载报告 | mTLS、服务签名、物理租约及兴趣修订隔离；授权/完成/重试由 PostgreSQL/cursor 决定；mailbox/ACK 有上限 | 完成部署指标、长期故障/soak 与 [`standard-100k`](../09-capacity/standard-100k.md) 发布报告 |
| R-007 | 生产规模、跨区恢复、密钥恢复与批准的 RPO/RTO 仍缺部署证据 | 本机逻辑恢复与[物理备份/WAL 时间点恢复](../09-capacity/ADR-010-capacity-and-disaster-recovery.md#当前可重复的恢复证据)已验证 schema、目标前后记录边界和恢复后写入；临时实例清理完毕 | 配置生产归档，执行跨环境、密钥、故障转移和写入中断演练并批准 RPO/RTO |
| R-008 | 最终代码缺少远端或干净 checkout 的同版统一门禁证据；当前 CI 额度状态未复核 | `bash scripts/verify_v2.sh` 提供受版本控制的本地统一门禁入口；历史分层通过不宣称云 CI 或当前版本全量通过 | 在可用的远端或受保护自托管 runner 的干净 checkout 上，对最终代码运行并留存同一门禁结果 |
| R-009 | R51 已通过 50k 在线、5,000 msg/s 五分钟 room-log/Sync soak，但 30 分钟 checkpoint 周期、混合消息、多 Gateway 和故障恢复仍未覆盖，不能外推为生产高活跃 IM 容量 | PostgreSQL/cursor 保持权威；ACK-after-commit；有界 queue/credit/cache；严格凭证目标预检与 profile 隔离；[R51 report](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/IMV2/docs/09-capacity/direct-room-log-50000-profile-isolation-r51-2026-08-28.md) 记录完整梯度、资源和未覆盖项 | 固定快照执行至少 30 分钟 5,000 msg/s 并跨完整 checkpoint；随后加入附件/回复/群聊、离线恢复、多设备/热点、两 Gateway 和 kill/failover，以客户端延迟、零 gap/丢失及资源余量批准 SLO |
| R-010 | ARM64 Linux Gateway 曾在 50k 压力下于 `libdispatch` worker 内发生一次 SIGSEGV；R51 四轮与五分钟 soak 未复现，但缺原始 core/application frame，尚不能证明根因或宣称已根除 | signal source 改为进程级持有且退出前不取消；listener 启用 `SO_REUSEADDR`；R51 单轮 50k 在线约 13 分钟且无容器重启 | 使用当前 binary 完成数小时 50k soak、受控 SIGTERM/kill/restart 和 core dump 采集；零崩溃后再关闭，若复现则以 core/符号化栈定位并跟踪对应 Swift/libdispatch 修复 |
| R-011 | OSS 的上传和最终对象 tombstone 永久保留，部署对象数量、增长与费用尚无实际容量基线 | [只读容量盘点](../../../docs/proposals/aliyun-oss-integration.md#永久对象的容量盘点与保留) 按物理 prefix 统计并核验标记，提供数量阈值、请求预算、费用输入和跨次增长；部分扫描不返回通过，禁止清理 tombstone | 为全部实际绑定留存完整盘点、账单单价和增长基线，配置容量预警及超限处置；任何 GC 另需证明所有旧写入能力与在途提交均已关闭且旧身份仍被持久拒绝 |
| R-012 | 本地文件读取边界仍依赖可信根目录祖先、挂载和服务账号；生产卷权限与文件不可变性仍待部署审计 | 授权后的读取固定文件描述符，拒绝链接和非普通文件；每块最多 64 KiB；macOS 与隔离 Linux ext4 的目录替换、已打开流、并发发布及删除围栏检查通过，范围见[本地读取边界](local-filesystem-media-test.md#本地文件读取边界) | 在实际服务账号下审计挂载及目录权限，证明没有不可信卷写入者；验收并发容量与进程崩溃恢复；若需共享可写卷，另行完成写入边界设计与验收 |
| R-013 | 永久发送成功记录缺生产每日增长、磁盘余量和批准的保留预算 | [容量观测与保留处置](observability.md#永久发送成功记录的容量与保留) 提供私有指标、只读 SQL、总量告警及隔离存储样本；统计未知不冒充零，继续禁止删除成功事实 | 为每个实际物理库及 WAL 集群留存可比较的每日基线并批准容量阈值、扩容和超限流程；归档/GC 另需证明旧身份与在途提交均被强制关闭，且结果恢复等依赖仍成立 |

## 维护规则

- 新风险必须写清当前隔离和可验证关闭条件，不能只写“后续处理”。
- 外部风险关闭时提交实际报告/日志位置，并更新
  [`implementation-status.md`](../implementation-status.md) 的证据等级。
- 不允许以降低授权、幂等、持久化、重试、隐私或容量 fence 来规避本表。

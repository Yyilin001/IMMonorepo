# IM V2 实现审计与实施路线图

审计日期：2026-08-13
审计基线：`codex/message-search` 分支的当前 V2-only 工作树。
结论：**架构方向可行，核心正确性边界已有较好实现；当前不具备生产发布条件。**

本文是实施优先级与验收计划，不替代 [implementation status](implementation-status.md) 的逐项证据登记。

## 1. 当前判断

### 已经做对的部分

- V2 以 PostgreSQL 为业务事实源：命令幂等结果、room event、room outbox、fan-out plan 和准入事实在同一事务落库。
- 投递没有把实时连接或 broker 当作真相。planner、delivery、用户 sync log 和 consumer inbox 都有 durable 记录、lease、checkpoint 与去重键。
- 客户端以 Keychain 设备凭证、独立 SQLite 投影和命令 outbox 为边界；UI 不把一次网络响应当作最终消息状态。
- 群成员变更、撤回、编辑、reaction、receipt、moderation、陌生人消息限制都已按版本/fence/幂等操作建模，而非分散在 UI 逻辑中。
- 分片路由与用户迁移具备控制面、epoch CAS、copy/verify、forwarding、回滚窗口等正确性设计，并已有两 PostgreSQL store 的局部故障回归。

这些设计决定使后续工作应以“补齐真实运行证据和外部适配器”为主，而不是推翻 durable 数据路径。

### 当前不可发布的原因

| 优先级 | 问题 | 影响 | 发布门槛 |
| --- | --- | --- | --- |
| P0 | 没有 V2 生产部署拓扑、secret 管理、入口暴露和回滚方案 | 无法安全部署 gateway、account、operator、metrics | 建立 IaC/部署清单、环境分层、上线/回滚 runbook |
| P0 | Passkey 只有客户端/传输边界；未部署审计级 WebAuthn RP verifier、challenge/counter 存储 | 主认证路径不可用 | WebAuthn 端到端真机与攻击/重放测试通过 |
| P0 | 本机文件系统 provider/EICAR 扫描夹具已验证媒体合同，但缺生产 provider、扫描器与对象存储 | 附件功能不能作为生产能力交付 | 真实 provider、扫描隔离、失败恢复、滥用测试通过 |
| P0 | 100k 仅证明单 plan 的 durable 正确性；没有真实并发、SLO、拓扑或故障报告 | 不能宣称支持 10 万人群或高频群 | 经过批准的工作负载、阈值和报告 |
| P1 | NATS 已有连接复用、动态订阅、PONG 确认和断线 replay，但仍是 best-effort 延迟层 | 缺少 TLS/NKey、broker 指标与生产故障注入证据 | 补齐传输认证、可观测性与 soak/failover 验证；持久状态继续以 PostgreSQL 为准 |
| P1 | APNs、Alertmanager、PITR/灾备、operator bastion/mTLS 未部署验证 | 恢复与告警链不完整 | 真实凭据、演练记录和批准的 RPO/RTO |

## 2. 设计与实现风险

### 2.1 Durable fan-out 正确，但需要运行容量基线

现有 room outbox → plan → delivery → user sync log 路径是合理的。它以 `paused` 代替静默跳过，并将单条 replay 限制在独立 operator 面，这是应当保留的底线。

风险在于运行参数仍是配置，不是容量结论：100ms polling、planner/delivery concurrency、page size、retry budget、数据库连接池与 shard 数之间没有联合压测。任何一个参数单独“看起来合理”都不能推出高频群安全。

**建议**：先为“小群常规聊天”和“热点大群”各确定一份批准的工作负载；分别测量写入 p95/p99、outbox age、delivery backlog、sync lag、PostgreSQL CPU/IO/连接数与 paused 数。将 admission 阈值由结果反推，不要固定使用示例环境变量。

### 2.2 NATS 当前只能当作可关闭的延迟优化

fan-out plan hint 的失败仍被故意吞掉，以保证不影响 durable 路径。Hybrid room wake 与 presence/typing 已使用每个 gateway 一条复用 Core NATS 连接、动态订阅本机活跃作用域并在重连时重放；连接和 broker `PING`/`PONG` 确认有两秒上限。订阅取消与握手/确认的竞态会执行补偿 `UNSUB`，pending ACK、payload mailbox 与前台 distinct-room mailbox 均有硬上限。

因此当前默认的 PostgreSQL polling/cursor pull 仍是正确性选择。静默 broker、真实 subscriber 和取消竞态回归证明故障不会阻塞 durable publication 或永久留下已取消兴趣；若要用于热点群，仍需完成 NATS TLS/NKey、broker 重启/网络分区 soak、连接/发布/消费 lag 指标与容量报告。即使完成，也不能让 NATS 决定授权、完成或用户可见状态。

### 2.3 认证与账户服务是首个外部安全阻塞点

设备凭证刷新、注销与 Keychain 边界设计良好；当前可部署的账户因子却只有密码 fallback。WebAuthn 的 challenge 生命周期、RP ID/origin 校验、签名 counter、credential 注册、撤销与审计未形成生产闭环。

**建议**：把账户服务作为独立安全项目完成，而不是继续在 gateway 内追加路由。完成第三方审计或至少安全评审后，再将 Passkey 设为默认入口；密码 fallback 已有跨副本、按 account handle 持久化的失败窗口与锁定，并已把注册、成功和已执行 bcrypt 的失败结果与相应状态同事务审计（不保留 handle、密码、verifier 或转发 IP）。账户服务现已在 HTTPS edge proof 之后对每个有效 edge-derived client address 执行跨副本固定窗口预算，数据库只保留独立 HMAC key 的派生值并会有界清理过期窗口。已实现的单账号禁用会以独立 operator 凭据原子撤销全部设备凭据、阻断旧断言再签发并发出 gateway 撤销事件；仍必须批准生产 trusted-proxy/DDoS 拓扑、审计访问/保留、恢复政策，以及禁用操作的 bastion/mTLS 审批和演练。

### 2.4 媒体与 Push 不能按“接口已存在”计入产品完成度

媒体上传/下载授权、scan outbox、retention 和 Push wake 的领域边界已经存在。本机文件系统 provider 与 EICAR 无害扫描夹具已经验证上传、扫描、下载和清理合同，但它们不等同于对象存储或恶意内容防护；生产对象存储、扫描器、APNs 凭据、活动策略与后台重启策略仍未证明。尤其是上传 provider target 只应在内存中短暂出现、扫描失败必须保持不可引用、Push 不得含内容，这些不变量需要由真实 provider 集成测试验证。

### 2.5 分片迁移设计复杂，应推迟到单 store 稳定后演练

路由、shadow forwarding、copy/verify、rollback 与 cross-store delivery 已有实现，方向正确但运行复杂度很高。尚没有独立数据库部署、权限隔离、网络分区、长时间 forwarding 或实际操作员流程证据。

**建议**：第一阶段生产只启用一个逻辑 bucket/单 PostgreSQL store；保留迁移代码和 runbook，但不将多 store 作为首发依赖。单 store 稳定后再用演练环境推进迁移能力。

### 2.6 Snapshot V3 与日志 compaction 已关闭历史线性增长风险

本轮实现审计已把会话首页、联系人首页与申请、设备会话、消息时间线/搜索/收藏、群名单与建群、资料批量读取、
媒体 worker、Push、隐私回执撤回、Snapshot V3 和 housekeeping 改成 keyset 分页、集合 SQL、
有界并发或可恢复 lease；关闭回执不再在用户请求事务中枚举全部私聊。分片迁移指纹也会
从正确的源/目标 schema 分页流式计算，不再把完整 sync history 二次拼成内存数组。
其中会话首页不再先读全量房间、身份和状态再排序，而是由 SQLite 触发器维护
`(is_archived, is_pinned, last_activity, room_id)` 物化顺序，并只批量 hydration 当前 50 行。
联系人页同样按 accepted/incoming/outgoing 作用域走复合索引和 50 行稳定 keyset；资料 hydration
不越过当前页，申请精确计数只在首个收到申请页执行一次，翻页不再重复全作用域统计；
联系人名称/handle 的包含搜索改为维护单字与双字 character-gram 的本地 FTS5 索引，查询不再
执行 `%query%` 全表扫描，并由 profile insert/update/delete trigger 保持一致。

原先“分页读取后在应用层折叠完整历史”的 reset 已被替换。服务端现在持续维护每用户
application-MVCC projection 和连续 checkpoint，在固定 base sequence 上按 projection key 构建
持久化小页；客户端逐页写 shadow，并使用 server ACK-before-local-activate 状态机。构建、编码、
解码和页面事务均有硬上限，失败/过期 generation 回退与 ACK 后崩溃恢复已有故障注入。因此
reset 的进程内内存不再随 `user_sync_log` 历史长度增长。

`user_sync_log` 已不再作为永久幂等数据库：consumer inbox 保存 fan-out 原分配 sequence，
`user_projection_effects` 保存小型控制投影结果，设备 reset watermark 来自单调 allocator。
新设备/低游标强制 snapshot 入场；retained floor 同时受连续 checkpoint、inclusive receipt/token、
最小 replay window 与迁移 fence 保护。有界 worker 先原子 reset 低 cursor，再分批删 log 前缀，
并只在最后一个引用消失后删除 shared payload。ADR-013 已实施，R-006 已关闭。

仍需产品级决策的是 R-007：operation ledger 与稳定 projection effect 的统一幂等保留窗口。
它不会造成 snapshot/请求进程内内存增长，且远小于消息历史，但磁盘仍随控制操作数增长；
当前以跨物理 user store 聚合的 estimate/relation bytes 和容量告警隔离，不能假装已经具备
引用安全的统一 TTL。

## 3. 推荐实施顺序

### 阶段 0：恢复可验证基线（P0，先完成）

1. [已完成，本机 2026-08-13] iPhone 17 Pro / iOS 26.5 已执行完整 `IMAppTests`（108 项）；通用 Simulator 构建保持为独立门禁。4 项登录/注册 `IMAppUITests` 已按显式关闭 Passkey 的产品配置通过，覆盖 password-only、最大辅助字体与 Arabic RTL。
2. [已完成，2026-08-12] GitHub Actions 的 iOS build、unit 和 UI jobs 固定为 `macos-26`、Xcode 26.2、iPhone 17 / iOS 26.2，并调用与本机相同的受版本控制脚本；远端执行结果仍需由 CI 自身提供，不能由本机结果替代。
3. [已完成，2026-08-12] `implementation-status.md` 记录当前本机环境、命令、结果、限制和明确的生产排除项；这些证据仍不是生产发布批准。

**完成条件**：干净 checkout 上，本机指定模拟器、隔离 PostgreSQL 与本地账号栈可重复成功，并保持 GitHub Actions 的 Swift/PostgreSQL 与 iOS 构建检查通过。

### 阶段 1：首发安全与最小部署（P0）

1. 选择生产部署平台并交付 V2-only IaC/Compose/Kubernetes 清单；account、gateway、operator、metrics 分别最小权限部署。
2. 接入 secret manager、TLS 证书轮换、数据库 migration runner、备份/WAL 策略和只读 metrics scrape。
3. 完成 WebAuthn verifier 与 one-time challenge/counter store；为密码 fallback 批准生产 trusted-proxy/DDoS 边界、审计访问/保留和恢复策略，并完成账号禁用的 bastion/mTLS 审批演练。
4. 将 operator 放在 bastion 或 mTLS proxy 后，完成一次 paused replay 演练和审计留存验证。

**完成条件**：预发布环境无 localhost/开发密钥，能执行注册、设备凭证、重连、replay、撤销和回滚演练。

### 阶段 2：可售卖的普通聊天（P0/P1）

1. 完成真实对象存储、扫描 provider、provider cleanup 与媒体滥用/失败回归。
2. 完成真实 APNs 凭据、Push-enabled profile、用户开关、失效 token 和后台 sync 真机回归。
3. 已新增同账号双安装回归入口：`IMApp/Scripts/verify_local_account_multi_device_e2e.sh` 在两台指定模拟器上注册同一账号的两个独立 Keychain/SQLite scope，覆盖设备清单、消息投影、编辑、撤回、陌生人消息与群已读设置、用户级群已读持久化、离线 outbox 重连、前后台恢复及单设备 snapshot reset。reset 只能经 loopback operator 的专用 bearer 调用，并以操作 UUID 幂等。仍需在已连接的两台真机执行同一套回归，并补录 reaction 与 APNs 结果。
4. [ADR-012](00-foundation/ADR-012-public-identity-and-discovery.md) 的 direct-profile
   同步投影、会话标题和群成员显示名已实现：direct room 创建与 snapshot reset
   只携带对端的有界公开资料，显示名更新通过独立 outbox 按接收者预算增量投递。
   密码登录页与双安装普通聊天的已登录会话列表/消息详情均已纳入模拟器无障碍自动审计
   （元素、命中区域、描述、动态字体、裁切和 traits）；注册页的提交节点仍会触发 Xcode `.dynamicType`
   类别的模拟器误报，但密码注册页已在最大辅助字体和 Arabic RTL 下独立断言四个必填项与提交入口均可触达，并执行其余语义/布局审计。消息编辑/撤回已提供 VoiceOver 自定义操作；聊天和设置页的异步结果会主动播报。密码登录/注册页及双安装真实聊天/设置页已在最大辅助字体和 Arabic RTL
   profile 下完成自动审计；该 profile 会临时启用两台指定模拟器的系统高对比度和最大辅助字号、以 Arabic RTL 启动，并在退出时恢复原设置。当前仍需人工完成 VoiceOver、减少动态效果和其他语言/页面的 RTL 验收；账户菜单到陌生人消息
   接收设置和公开身份资料页的真实路由、关键控件可定位/可操作及返回路径已由双安装回归覆盖。消息详情
   输入区的普通对比度审计已纳入双安装回归并通过。本阶段剩余的是两台真机的离线/重连
   E2E 和人工产品验收。群成员资料继续
   仅通过按需目录读取，不能扩展成 roster fan-out。

**完成条件**：普通私聊与中小群在预发布环境有可重复的真机 E2E 套件和故障恢复记录。

### 阶段 3：热点群与容量（P1）

1. 先决定是否需要 NATS。若不需要，优化并测量 durable polling；若需要，完成完整 hint adapter 与 broker 运行面。
2. 建立目标拓扑下的负载生成、数据库观测、故障注入和结果归档。
3. 分别验证 100k 成员冷写、持续高频写、成员变更、离线 catch-up、worker/broker/DB 故障与恢复。
4. 根据实测设置 admission、worker、connection pool 和告警阈值；给每个 profile 分配明确 SLO。

**完成条件**：有日期、commit、拓扑、数据集、阈值、图表与 go/no-go 结论的容量报告；此后才可以对外声明容量。

### 阶段 4：多 store 与灾备（P2）

1. 在独立数据库上演练 copy/verify/forwarding/cutover/rollback/cleanup；验证跨网络故障和 operator 权限边界。
2. 执行 WAL/PITR、密钥恢复、区域故障、告警失效和长时间 durable backlog 演练。
3. 仅在阶段 3 的单 store 容量瓶颈确实出现后，启用多 store 迁移能力。

## 4. 统一发布门禁

| 门禁 | 必须证据 |
| --- | --- |
| 构建与测试 | 本机隔离 Core/Server/ClientKit 回归通过；iOS 指定模拟器的 Debug 全量测试、通用 Simulator `build-for-testing` 与本机账户 E2E 均已通过；真机测试仍须在设备可用时执行 |
| 安全 | WebAuthn/密码策略评审、secret 管理、TLS、rate limit、operator 最小权限与审计 |
| 正确性 | PostgreSQL durable recovery、双设备同步、媒体扫描失败、Push 失效、replay 演练 |
| 运维 | 指标、Alertmanager receiver、runbook、备份恢复、on-call ownership |
| 产品 | 普通聊天、群管理、陌生人设置、附件、无障碍与错误体验验收 |
| 容量 | 对应 profile 的真实压测和故障报告；100k 不得由配置或单元测试替代 |

## 5. 下一步建议

阶段 0 已完成。若当前仅处理本机可验证事项，优先完成 iOS 的人工无障碍验收：VoiceOver 阅读/焦点顺序、
减少动态效果和其他语言/页面的 RTL；随后补足两台模拟器下的异常网络、应用前后台切换和
本地数据恢复场景。生产平台、密钥管理、公网入口和容量结论均不属于这一轮范围，不能用本地 Compose 或
开发证书替代。

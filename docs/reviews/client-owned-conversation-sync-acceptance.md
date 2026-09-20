# 会话同步当前验收状态

目标：按 [实施方案](client-owned-conversation-sync-plan.md) 完整落地，不保留历史兼容路径。**目标尚未完成。** 局部通过不等于整项完成。

本页只保留当前结论。过程、失败及旧版本结果见 [证据记录](client-owned-conversation-sync-evidence-2026-09-13.md)，规模数据见 [规模验收结果](client-owned-conversation-sync-scale-results.md)。历史“运行中”“待执行”不是当前状态。

## 当前执行与最近结果

前台 App 自动重连专项现已整轮通过：`/tmp/imv2-governance-reconnect-20260919-02-driver.log` 退出 0。三次代理断线后唯一正文均由 App 自动恢复，129 房间恢复和跨 Gateway 在线更新通过；App 3 passed、0 failed、1 未启用的后台待发专项 skipped。数据库终验为 `13|3|0|0|3`，恢复账号独立核对为两台设备、零撤销；三次重连未增加注册。专用模拟器及临时服务、数据库、证书已清理。本次为 Swift 6.4 / iOS 27 模拟器，不能外推为 iOS 26、真机或后台期限验收。

原第六轮退出 1 的直接原因已定位为驱动漏计 scoped App 的额外登录设备。修复补计且增加账号级严格数量检查，保留原失败历史；没有放宽凭据撤销、设备事件或三次断线断言。本次先修复强杀测试跨并发返回 GRDB Row 的编译错误，改为闭包内读取可传递值，62 个真实 SIGKILL 参数复验通过。复现命令、首轮编译失败与最终证据见[治理恢复专项](verification-records.md#20260919-governance-recovery)。

安装窗口新增后的服务端全量已退出 0：`/tmp/imv2-server-full-install-windows.log`，1089 测试/159 套件、1410.597 秒。真实 PostgreSQL、NATS 订阅安装与 broker 重启专项实际执行，无 skipped 记录。临时数据库前缀 imv2_acceptance_0f584a537ca64707 已查询无残留，独立 NATS PID 30289 正常退出。该结果覆盖当前服务端源码及新增安装测试；该 Server 全量与本页单列的 App 自动重连专项分别计证，不合并为最终同版全量门禁。

普通群/大群订阅前后四窗口联合专项通过：`/tmp/imv2-postgres-nats-all-install-windows.log` 退出 0，2 测试/2 套件、3.929 秒，真实消息测试四参数通过。标准群订阅前场景等待生产 dispatcher 完成真实 NATS 发布，再通过同一连接的独立房间确认消息建立顺序屏障；大群走生产持久化 relay。订阅前发布未收到通知，完成订阅后通过生产状态读取和事件补拉取得正确水位与单条 installation-body 正文；订阅后、安装返回前发布收到正确通知。临时数据库前缀 imv2_acceptance_c1d92e4ea9f94737 已查询无残留，独立 NATS PID 28109 正常退出。此项覆盖服务端真实数据库和 broker，不包含 App/TLS 或客户端 SQLite 收敛；Server 全量 1086 项早于这些测试新增。

真实 NATS 网关字节流专项也已验证第 129 个房间通知可早于目录响应到达，目录响应回调在安装屏障释放前未触发（`/tmp/imv2-real-nats-install-window.log`，2 测试通过）。该专项状态/目录为夹具；与上面的 PostgreSQL 专项是分开执行的证据，尚不等同真实 App 整链路。早期安装窗口测试及失败修正过程保留在证据记录。

网关字节流安装交错专项通过：`/tmp/imv2-gateway-install-window.log` 退出 0，1 测试、2 参数、0.009 秒。新增参数暂停末页首个 broker interest.activate，确认仅前 100 个房间完成安装；暂停期间向目录第 129 个房间投递变化，收到正确 epoch/sequence/room 的通知，再释放安装并完成目录响应和关闭清理。使用生产 byte stream/registry/account service，受控 broker 与状态读取夹具；不包含真实 NATS、PostgreSQL 提交或客户端正文收敛，不能替代完整安装窗口验收。生产代码未修改；Server 全量 1086 项记录早于这一测试参数新增。

千房间双 Gateway/NATS 第二轮整轮通过：`/tmp/imv2-tls-recovery-scale-1000-online-v2-driver.log` 退出 0，输出 `/tmp/imv2-tls-recovery-scale-1000-online-20260914-02`。App 3 passed / 0 failed / 1 未请求可选项 skipped；HTTP/数据库终验通过，专用模拟器 BE43C962-8E48-40F1-83E1-D1BFA78C79A8 已删除。首轮正文恢复 97.834473 秒、重连 2.294513625 秒，第二轮无正文请求；目录第 129 房间跨 Gateway 在线更新通过，无详细订阅或手动补拉。首轮注册 networkFailure 未复现但仍未归因，不用这次成功抹去失败历史。

状态读取归属复核修复后的 Server 全量已退出 0：`/tmp/imv2-server-full-route-revalidation.log`，1086 tests / 158 suites，1552.964 秒。临时数据库前缀 `imv2_acceptance_50566e7e123c438b` 已查询确认无残留。该结果替代修复前 1084 项记录作为当前 Server 全量证据；仍不替代独立 App/TLS 迁移等尚未完成场景。

千房间跨 Gateway 第一轮已终态退出 1：`/tmp/imv2-tls-recovery-scale-1000-online-driver.log`。App 2 passed / 1 failed / 1 skipped；失败为 testGatewayDeviceRevocationReturnsToLoginAndSurvivesRelaunch 的首次注册 networkFailure，根因未明。房间专项本身通过：首轮 97.908226625 秒、重连 2.549822916 秒；第 129 个房间在线与跨 Gateway 标记均通过，刷新 0 次，第二轮无正文请求。整轮 HTTP/数据库终验未执行，不能计为全部通过。专用模拟器 9749B403-1F6B-4275-AFFF-8A39B1593427 已由驱动删除。

快照旧表回收新增提交前/后 SIGKILL 验证通过：`/tmp/imv2-snapshot-cleanup-crash-v2.log` 退出 0，31 类场景、62 参数，9.960 秒。非空快照先完成激活，再单独在生产清理事务提交边界强杀；重开 SQLite 后，提交前保留旧表、提交后旧表清空，当前消息和已确认游标保持一致，重复清理安全。DDL 不提供普通行变更回调，因此该场景在事务外安装 observer，只观察接下来的清理事务。仍不替代系统后台期限或真实 TLS 快照重置验收。

有页数上限的恢复取消后续跑已通过：`/tmp/imv2-bounded-recovery-cancel-resume.log`，1 测试、2.434 秒。已提交目录待办后，在下一次目录请求处取消 runner，确认 CancellationError、引擎 idle、正文游标仍为 0、待办仍为 1；新 runner 在 4 页预算内恢复两个房间至游标 5 并清空待办。此测试使用受控传输和真实 SQLite，正文页为空，不等同系统后台期限耗尽或非空消息恢复。 当前客户端全量 `/tmp/imv2-client-full-cancel-resume.log` 已退出 0：621 tests / 105 suites，85.660 秒；包括本次取消续跑与成员授予边界；该全量未启用强杀、真实账户及持久规模等条件专项，不将其跳过计为通过。此前 60 个强杀参数来自独立专项，并非本轮全量执行。

状态读取路由竞态已确认并修复：读取旧 owner 后切换路由，原实现会返回旧 state/unavailable；`/tmp/imv2-state-route-race-before.log` 两个 moved 参数失败。修复为每个分片读完后用权威路由复核，归属变化保持 retry，并忽略非请求路由项。`/tmp/imv2-state-route-race-fixed.log` 四参数通过；真实 PostgreSQL 与命令边界联合回归 `/tmp/imv2-state-route-postgres-regression.log` 退出0，5测试/3套件0.814秒，数据库前缀imv2_acceptance_5784d5eb6e674d8b已清理。此项为受控竞态+真实数据库正常/故障回归，不等同真实控制面迁移与App整链路。当前 Server 全量终态见本节开头，修复前 1084 项记录保留为历史。


分片故障专项已同时覆盖状态与摘要：`/tmp/imv2-routed-recovery-summary-fault.log` 退出0，1测试0.733秒；两个真实独立数据库，故障侧状态/摘要均为 retry，健康侧保持可读，恢复后两类读取均成功。临时数据库前缀 imv2_acceptance_234aa7d775504f6a 已确认无残留。当时发现的状态读后归属复核差异已由上述受控测试确认并修复。


独立数据库路由读取故障专项 `/tmp/imv2-routed-recovery-postgres-fault.log` 退出0，1测试0.765秒：两个独立临时 PostgreSQL 数据库，暂时重命名第二库成员表造成真实 SQL 查询失败；健康分片继续返回 state，故障分片返回 retry，恢复表后两侧返回 state。使用真实路由聚合与存储，固定路由测试夹具；不是网关/App 故障、网络断连或迁移验收，也不证明多服务器并发。数据库前缀 imv2_acceptance_cd63097f2c1a43e3 已查询确认无残留。


当前 headless Push 专项整轮通过：`/tmp/imv2-headless-recovery-grant-driver.log` 退出0，输出 `/tmp/imv2-headless-recovery-grant-20260914-01`。显式启用 `V2HeadlessPushIntegrationTests` 后 1 passed、0 failed、0 skipped；直接调用生产 App delegate，验证真实 Keychain 凭据恢复、HTTPS/TLS/SQLite、重复回调及设备撤销，HTTP/数据库终验通过。专用模拟器 796220FF-C014-408D-A671-CE2E104F1847、进程、数据库、证书均清理完成。此证据补齐当前 App 全量中未启用的该专项，但不是系统实际 APNs 冷启动投递或后台期限耗尽，也不证明非空多房间后台收敛。


当前 App 全量 `/tmp/imv2-app-personal-grant-full.xcresult`：240 passed、0 failed、1 skipped（未启用的真实 headless Push 冷启动专项，不计为通过），包含修复后的共享 ClientKit；按结果摘要计测试数量，动态参数运行数不额外累计。专用模拟器 EB498F12-C9CF-4DFF-A821-BFC073A7594A 已清理。成员授予隔离专项 `/tmp/imv2-personal-grant-boundaries.log` 退出0：20个测试，含无扫描/旧安装绑定/其他成员三种不入队分支；个人流水位仍推进且正文游标不越过0。


修复后的当前验证已完成：ClientKit `/tmp/imv2-client-full-personal-grant.log` 已退出 0（619 tests / 105 suites，58.509 秒，含当时50个强杀参数）；新增个人授予强杀后专项52参数通过，生产实现未再修改；真实 App/TLS 第十轮 `/tmp/imv2-tls-recovery-membership-129-v10-driver.log` 退出0，输出 `/tmp/imv2-tls-recovery-membership-129-20260914-10`，三个成员阶段及 HTTP/数据库终验通过，专用模拟器 43EFBA68-B7D5-4EB8-A4F0-4971D8B3684C、服务、数据库、证书均清理完成。


已确认并修复新的自身成员加入漏调度：目录结束后，个人流水授予成员资格却未创建恢复任务，固定顺序测试原实现 5 条断言失败；修复后 19 个持久化测试通过。新授予与待办同事务写入，旧修订、快照影子导入和无有效扫描不触发该路径。补充重放断言后 ClientKit 全量通过，真实链路第十轮通过；此前 App 绿色记录早于此生产修改，不再视作当前版本全量。第九轮真实场景通过，但此前 connectionClosed 仍不宣称已归因。


强杀专项最新为 31 类场景、62 个实际提交前后参数：`/tmp/imv2-snapshot-cleanup-crash-v2.log` 退出 0（9.960 秒）。目录空过滤页与含新房间的终页强杀通过，游标/完成标记/待办原子提交，重启继续且旧页拒绝重放；首次扫描插入和扫描替换的提交前后强杀通过，旧 scope 拒绝写入且待办保留；摘要任务的新需求、已有请求身份及退避保留已通过；独立完成待办在提交前后崩溃均保留正文和游标，重启可继续清理，重复完成返回 false。父进程 crashChild 的跳过不计为额外通过。覆盖与缺口见 [事务边界审计](client-owned-conversation-sync-transaction-audit.md)，尚不代表全部持久事务及真实后台期限完成。

成员竞态第二轮整轮通过：`/tmp/imv2-tls-recovery-membership-129-v2-driver.log` 退出 0，输出 `/tmp/imv2-tls-recovery-membership-129-20260914-02`。真实旧状态响应延迟期间，经第二 Gateway 移除成员、发送缺席消息、重新加入并发送，最终 live、正文/游标一致且缺席消息不可见；App 3 passed、0 failed、1 未请求可选项 skipped，HTTP/数据库终验通过（设备观测 `13|3|0|0|3`）。专用模拟器 037F42C5-9109-4BE0-A369-C6C719CEC688、服务、临时数据库与证书均已清理。第一轮因漏算新增群主设备失败的历史保留在证据页。此项不替代加入已扫描区间或迁移、分片失效验收。

目录终页之后加入场景第三轮整轮通过：`/tmp/imv2-tls-recovery-membership-129-v3-driver.log` 退出 0，输出 `/tmp/imv2-tls-recovery-membership-129-20260914-03`。`IMAppRoomRecoveryDirectoryJoinTests.swift` 取到真实、不含目标房间的终页后才执行加入及发送，再返回原响应；无周期核对或显式重连的正常 runner 恢复至 live，正文/游标一致、缺席消息不可见。两个成员场景标记均通过，App 3 passed、0 failed、1 未请求可选项 skipped，HTTP/数据库终验通过；专用模拟器 0A79379E-7708-4303-A559-1826259235C7、服务、数据库和证书已清理。复用已知房间，因此不等同首次加入从未见过的房间；第二轮证据不包含此新增阶段。

首次未知房间加入第七轮通过：真实群主创建仅自身参与的群，用户本地消息及访问状态为空，真实目录终页捕获后首次加入并发送；原目录页不包含目标房间，最终 live、游标 4、权限有效、待办清空，加入前消息不可见。输出 `/tmp/imv2-tls-recovery-membership-129-20260914-07`，三个成员标记均通过，HTTP/数据库终验通过，模拟器 E6B054CF-BE87-4C33-9DF5-89EFAFB85EBF 和全部临时资源清理完成。此证据不消除已知房间第 4/5 轮间歇性失败，稳定性仍待确认。

第八轮 `/tmp/imv2-tls-recovery-membership-129-v8-driver.log` 同样整轮通过并清理完成，但两次成功均含每 20ms 的额外数据库诊断读，可能扰动时序。第九轮去掉循环中的额外读取，改在 runner 失败后读取现场，保留原成功判定和 120 秒期限；`/tmp/imv2-tls-recovery-membership-129-v9-driver.log` 整轮通过，原间歇性失败尚未解释。

修复前 ClientKit 全量 `/tmp/imv2-client-full-50-crash.log` 退出 0：618 个测试、105 个套件，73.051 秒；包含 50 个真实强杀参数。参数数量不额外加到 Swift Testing 的测试函数总数。

**完整 App 慢 TLS 第八轮通过。** `/tmp/imv2-tls-recovery-slow-129-v8-driver.log` 退出 0，输出 `/tmp/imv2-tls-recovery-slow-129-20260913-08`。129 个实际覆盖房间轮换提交 5928 条消息后，主 Gateway 的 required_notification_write_timeout 增加一次，idle_timeout 为零；恢复转发、显式重连后，每个房间的完整正文集合、原有消息数和游标一致。App 3 passed、0 failed、1 未请求可选项 skipped，HTTP/数据库终验通过；专用模拟器 29D300FE-7538-4A4D-AD5A-7DA079F53FF8、服务进程和临时数据库均已清理。

此场景仅提高隔离命令预算，并将隔离 Gateway 空闲期限延长到压力期限之后；生产关闭策略未改。TCP 接收缓冲实际可增长到 526720 字节，不能把 4096 设置值当作持续内核上界。通过证据是实际写超时关闭及恢复后的数据核对。测试显式编排重连，不能扩大为生产 App 生命周期自动重连证明，也不证明整套资源的硬上界。

**路由复核修复前的 Server 全量通过：1084 个测试、156 个套件，1622.528 秒。该记录不能作为当前最终门禁。** `/tmp/imv2-server-full-after-query-optimization-20260914.log` 覆盖本轮查询优化、关闭原因、慢 TLS、查询成本及重复成员保护。成员竞态第一轮与第二轮状态见上。

**查询优化真实 PostgreSQL 回归通过。** `/tmp/imv2-recovery-query-cost-native-v3.log` 退出 0，4 项/2 套件，包括 1000/10000 目录规模、授权与分页。四类成员、四个并发用户的 16 条生产 SQL 均无 rooms/room_memberships 全表扫描；目录暖计划约 0.070–0.084 ms，状态约 0.113–0.126 ms。仅限此 10000 房间、无正文负载的数据集，不是线上 SLO。`/tmp/imv2-recovery-duplicate-membership.log` 验证重复有效修订仍报 corruptPersistence，临时数据库清理已核实。

转发器可重复 TLS 回归 `/tmp/imv2-relay-tls-regression.log` 通过，验证可信证书、暂停后读取超时、恢复后 262144 字节一致及线程/套接字清理。此前七轮完整场景失败及修正过程完整保留于证据记录，不覆盖或删除。

## 已通过的主要验证

- **规模与在线**：0、50、129、1000、10000 房间两轮恢复有真实通过记录。129 与 1000 房间跨 Gateway/NATS 在线通过。万房间最新首次 1014.733 秒、第二轮 23.387 秒，首轮完整计量覆盖自然令牌到期后的刷新和重连，第二轮无正文请求。
- **真实故障与交错**：129 房间 broker 停止、覆盖失效、重启后恢复通过；最后通知在 TLS 消费边界被丢弃后由周期核对补齐；监听前、目录响应、旧状态响应三个真实跨 Gateway 交错通过。尚不覆盖服务端安装监听内部窗口。
- **持久化**：十七类事务提交前后共 34 个真实 SIGKILL 参数通过，包含快照各阶段、重置、队列入队/重试、目录重扫及 unavailable 清理。不能扩大为所有事务和真实后台期限均覆盖。
- **慢 TLS 传输层**：真实 TLS 写阻塞及明确关闭原因专项通过，日志 `/tmp/imv2-real-slow-tls-v4.log`。该专项使用认证替身，不替代当前完整 App/数据库验收。

## 全量门禁的版本边界

| 门禁 | 最近已验证结果 | 范围限制 |
| --- | --- | --- |
| Core | 125 项/41 套件；`/tmp/imv2-core-final-current-20260913.log` | 最终统一收尾仍按最新源码核对 |
| ClientKit | 621 项/105 套件；`/tmp/imv2-client-full-cancel-resume.log` | 此轮未启用强杀等条件专项；62 个强杀参数由独立专项验证，且新增清理场景晚于此全量 |
| App | 240 passed、0 failed、1 opt-in skipped；`/tmp/imv2-app-final-current-20260913.xcresult` | 早于最新 E2E 专项；跳过项不算通过 |
| Server | 1089 项/159 套件；`/tmp/imv2-server-full-install-windows.log` | 包含新增安装时序、真实 PostgreSQL 和 NATS 专项；不替代 App 跨组件组合 |
| 协议与库结构 | 协议文档、schema 关系、生成物比对、原生建库/导出恢复/漂移检查通过 | 不替代最终所有改动后的统一门禁 |

## 逐项验收矩阵

| 方案条目 | 已有证据及范围 | 尚缺的完成证据 |
| --- | --- | --- |
| 1. 0/50/129/1000/10000 房间及超过 128 的在线覆盖 | 五档恢复通过；129/1000 房间跨 Gateway 在线通过；万房间完整跨重连计量及资源范围已汇总至规模结果文档 | 1000 当前双 Gateway 在线已通过；仍不扩展为大历史缺口或长期偏斜负载 |
| 2. 冷热分布、分页与查询扫描成本 | 四类成员、四个并发用户和 10000 房间的 16 条实际生产 SQL/执行计划通过，并据此消除 rooms/member 全表扫描；摘要索引与写成本专项通过 | 非空正文冷热负载、实际物理分片并发和整套资源成本 |
| 3. 监听安装、扫描与通知缺失时的一致性 | 129 房间真实跨 Gateway 的监听前、目录响应和旧状态响应交错通过；TLS 消费边界丢弃最后通知后周期核对恢复 | 服务端真实数据库/NATS 四窗口已通过；仍需 App/TLS 与客户端落库的组合覆盖及其他故障边界 |
| 4. 扫描中成员变化、迁移、分片不可用 | 真实双 Gateway 扫描中退出重入及缺席消息不可见整轮通过；分层成员栅栏、拓扑、owner 与状态测试；新增前台/后台在状态/正文响应返回前提交本人撤销的 4 场景通过，见[运行器交错](verification-records.md#20260920-membership-inflight-runner)；撤销后重入的旧响应拒绝、新待办保留及新资格恢复另有[两场景证据](verification-records.md#20260920-rejoin-inflight-runner)，并补[非空正文交错](verification-records.md#20260920-rejoin-content-flight) | 真正跨组件的加入已扫描区间、房间/用户迁移及单分片失效组合 |
| 5. 事务强杀、预算与旧任务晚到 | 三十一种场景提交前后共 62 个真实 SIGKILL 参数，含成员撤销、快照、重置、队列、目录重扫和 unavailable 清理；公平队列与旧任务保护测试 | 其余持久队列提交边界覆盖审计；真实后台期限组合 |
| 6. 快照重置、裁剪与首次安装 | 分层快照/裁剪；摘要不推进正文游标的强杀证据 | 快照、裁剪、首次安装与实际实时投递并发的跨层验收 |
| 7. 实时/恢复并发、多设备已读与旧状态 | 真实 SQLite 非空消息三种到达顺序均幂等且保留新目标；状态比较检查 | 真实网络并发、跨设备已读和旧状态延迟组合 |
| 8. 有效活动规则与多设备排序 | 本地 reducer、撤回/摘要/单侧提示分层检查；单侧提示实际 App 证据 | 撤回、编辑、失败发送、单侧提示与多设备排序组合 |
| 9. 慢消费者、NATS 故障、Gateway/账号切换 | 双 Gateway broker 故障、慢 TLS 显式重连及前台 App 三次断线自动重连整轮通过；明确关闭原因和缓冲区溢出专项通过 | 账号切换、后台生命周期与资源上界；前台三次断线自动重连已通过，不代表全部生命周期 |
| 10. 当前全量和部署合同 | 历史全量、生成物、schema 及真实 PostgreSQL 记录见下 | 所有最后改动后的 Server/Core/ClientKit/App 和协议/schema/配置最终统一门禁 |

## 接下来的执行顺序

1. 当前 Server 全量及真实成员退出重入已通过；完整 App 慢 TLS 场景已通过，保留其显式重连和资源测量边界。
2. 服务端安装监听内部四窗口已通过；继续补齐 App/TLS 安装竞态、成员/拓扑变化和多设备组合，分层结果不能替代整链路。
3. 补齐冷热偏斜和并发用户的实际查询成本。万房间完整计量与静默尾通知整轮已完成，不重复列为待执行。
4. 对照上表补齐全部证据，最后执行所有当前版本门禁。不得把测试入口存在、构建通过或局部绿色替代对应行为要求。

## 观测边界

规模流量是 protobuf 逻辑请求/响应字节，不含 TLS 开销、认证及非请求通知。资源每秒采样，仅含主 Gateway 和测试宿主，不是整套系统或瞬时峰值；并行编译期间的数据不作为隔离性能 SLO。万房间最新两者 RSS 峰值为 54.61/284.97 MiB。1000 当前双 Gateway 结果已补齐主 Gateway/测试宿主采样：各 99 样本，峰值 42.375/279.25 MiB，零采样错误；旧记录缺少采样不记作零。

本地列表行可读不等于 UI 首帧渲染。真实账号恢复测试使用生产认证、TLS 和 SQLite，但测试宿主的凭据 actor 不证明 Keychain 冷启动；后者由独立 App 生命周期测试覆盖。

当前未发现需要用户输入才能继续的阻塞。全部十项要求保留，最终逐项审计通过后才能结束目标。

本页整理后文档链接与结构门禁通过：`/tmp/imv2-acceptance-consolidated-links.log`、`/tmp/imv2-acceptance-consolidated-structure.log`。完整旧文本保留在证据文档，未删除历史失败记录。

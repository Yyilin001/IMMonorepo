# 服务端消息链路第二轮修复方案（2026-09-30）

## 目标与依据

以当前 `sendOperation` 入口为准，修复批次集成后的锁顺序、控制授权、共享分片锁持有时间、微批观测和后台投递问题。保留持久化意图、精确操作指纹、不可变回执、激活围栏、逐条业务拒绝与提交后发布。没有将旧追加探针的吞吐数字当作当前入口证据。

依据：

- [PostgreSQL 16 锁与死锁](https://www.postgresql.org/docs/16/explicit-locking.html)：事务级锁到事务结束才释放；所有调用路径必须采用一致的完整锁顺序。只对操作 ID 排序不足以保护中间穿插的房间锁。
- [PostgreSQL 16 超时](https://www.postgresql.org/docs/16/runtime-config-client.html)：语句/锁超时限制单次等待；不能作为修正跨事务依赖环的替代。
- [Swift 结构化并发](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)：任务组在退出前排空子任务，取消采用协作传播，并发规模必须有界。
- [PostgreSQL 16 统计](https://www.postgresql.org/docs/16/monitoring-stats.html)：容量采用统计估计和 relation size，避免在消息或 metrics 请求中执行全表 COUNT。

## 1. 统一操作锁顺序

原批次每次 `lock(operation)` 同时锁房间，形成操作 A → 房间 → 操作 B；授权恢复为操作 B → 房间，存在等待环。改为先获取整批唯一、有序的操作锁，再一次获取当前房间/激活围栏。标量发送和结果恢复沿用同一键名和顺序。

回归场景必须覆盖持有后续操作锁的并发授权恢复，不以正常两条消息成功替代锁顺序验证。

## 2. 控制授权先于 Owner 事务

批次开启 Owner 事务前准备必要的控制授权；Owner 事务内只能消费绑定精确命令、代次和 owner 的授权证明，不再为后续消息重新进入控制策略锁。已完成操作依旧优先重放，不因当前权限或期限变化替换原回执。授权预留成功但 Owner 回滚时，保留持久义务由精确 owner proof 恢复结算。

准备与事务入口之间发生撤销时，owner 的 aborted proof 必须阻止迟到接受。整批授权错误应保留逐操作结果边界，不把一个发送者的业务权限失败变成其他发送者的终态拒绝。授权准备失败和事务提交不确定必须分别映射。

## 3. 分片额度在整批尾部结算

原标量尾部更新在共享批次里成为第一条消息之后的长锁。批次改为在不持有共享分片计数器锁时处理各项正文和回执，在末尾对累积增量执行精确条件更新。累计量必须参与每条消息的容量判断；savepoint 回滚不能保留该条的增量。

末尾竞争或租约变化导致条件失败时，回滚整个批次正文 savepoint：重新读取原有回执，所有本轮接受结果（包括同批重复操作的重放）返回可重试提示。没有领域副作用的业务拒绝按原指纹和 resolvedAt 重新持久化；单聊策略拒绝重新经过领域接受路径，在同一外层事务内恢复私有时间线、发送能力和授权证明，再写执行回执。指纹冲突根据回滚后仍存在的执行、领域或控制侧身份重新判断；恢复时若命令变成新的接受候选，回滚该项写入并返回本批次准入失败提示，不能绕过尾部额度检查。不能返回已经回滚的接受或拒绝证明。禁止在持有 Owner 连接时再向同池额度 Actor 借用另一连接。旧快路径仅可在这些不变量成立后复用，不强行把旧 API 作为新入口的性能保证。

提交前回执查询、操作锁和回执写入使用同一持久化键校验。整批 room/account/operation 必须先通过 UUID 校验，之后才查询回执或预留控制授权；Core/HTTP/Gateway 接受的其他合法 opaque ID 在此返回 `invalidRequest`，不能进入强制解包。

### 批次业务错误隔离

逐条接受遇到回复目标不存在、附件不可用或非法引用集合时，在该项 savepoint 内回滚正文，持久化 `invalidContent` 拒绝回执及迟到追加围栏；提及授权失败持久化 `permissionDenied`。有效相邻消息继续参与尾部额度结算，已有回执优先重放，同操作重复请求返回原终态。批次尾部准入失败后仍原子恢复这些拒绝回执。回执写入、共享配置或数据库故障继续向外传播，消息执行器不得把一个逃逸的批次异常复制为所有操作的业务错误。

真实 PostgreSQL 回归覆盖单聊/群聊的回复、提及、附件六个场景，混合永久回执重放、拒绝项前后的有效发送和同批重复拒绝；核对消息顺序、实际分片用量与提交后通知。额外覆盖尾部准入回滚后的拒绝重建、拒绝回执写入失败时所有尚未提交的写入原子回滚，以及共享容量配置故障向外传播。回归位于 `PostgresV2MessageSendOperationBatchIsolationTests.swift`。

## 4. 当前入口的微批与观测

只有 durable `sendOperation` 在房间 lane 内收集，窗口以首条原始准入时间加配置 `batchWait` 计算，取请求 deadline 的较早者。已有等待不能重新获得窗口；取消、租约丢失和头部变化后重新检查；批次仍受数量、字节与屏障限制。旧普通 send 的窗口继续由物理 owner batcher 负责，避免双重等待。

每个物理 owner 增加独立 durable 指标：提交命令数、批次数、singleton/largest batch、在途批次、committed/rolled_back/unknown 结果及执行耗时。指标经现有 runtime pressure 出口导出，不含房间/用户标签，也不混入旧跨房间原子追加指标。committed 统计成功提交的轮次及其命令数，包含重放、业务拒绝和可重试提示，不能当作新增消息数。

## 5. 用户状态投递按用户有界并发

跨用户并发，同用户未完成事件按源顺序执行；每轮只领取可立即进入工作槽的事件，避免先领取大批 30 秒租约再排队。领取 SQL 排除同用户更早的 pending/leased 行，并有支持该条件的索引。暂停记录沿用既有人工 replay 语义，不改变原有错误隔离策略。

默认每个工作窗口最多 8 个用户，窗口结束后继续领取，直到达到本轮 limit。结构化任务组排空子任务；project、acknowledge、retry 和错误分类沿用持久恢复边界。取消不把未确认结果标记为成功，租约过期/失效后停止本轮，避免立即重领放大慢目标重试。schema 升为 current64，索引变化已同步当前契约及 readiness 检查。

## 6. 永久回执的容量治理

当前协议承诺永久重放与迟到操作围栏，不能通过 TTL 删除操作身份来限制台账增长。台账行数线性增长是该协议的存储下限，本轮不虚构已经根除这一点。

落地只读 `IMV2/sql/diagnostics/operation-ledger-capacity.sql`，一次查询固定台账的估计行数、heap/index/TOAST 总量与 ANALYZE 时间，不扫描业务行、不输出用户身份。运维应保存不同日期的结果，按真实每日新增量、总存储容量和恢复窗口预测耗尽时间，不能用空数据库样本估计每条生产记录的大小。

若容量要求需要冷热分离，后续协议必须实现：固定操作身份的 hot/cold 路由；cold 保留完整指纹、终态和原 resolvedAt；恢复与迟到追加始终访问两层；迁移有校验、双读和故障恢复；负面墓碑不能先于路由/证明发布删除。只压缩重复载荷可降低常数成本，但不消除永久身份增长。该协议涉及外部存储和运行部署，本轮没有自动迁移生产台账。

## 验证与完成标准

仅运行相关 Actor lane、durable send/授权/分片准入、投递 worker、metrics 和当前 schema/readiness 定向检查。事务测试使用新建可丢弃 PostgreSQL 数据库；不运行全套、不启动大型历史压测。

需核对生产装配接通实际新 API、数据库错误和提交未知边界、并发时序测试确实覆盖等待环/尾部锁、schema contract 一致、metrics 对当前 durable 入口实际计数。性能结果仅报告实际测量，正确性测试不等于吞吐或 P95/P99 改善。

## 实际结果

生产装配中 `V2RoomServerActivation` 调用 durable `sendBatch`；批次正文调用 `acceptForOperationBatch`，累计成功 reservation 后只在尾部调用一次 `reserveShardAdmissionBatch`。控制授权按最多 128 项分组预留，再绑定每条命令自己的 grant，避免逐项反复完成整批授权。指标按物理 owner 聚合，由现有 metrics 路由导出。

本机 PostgreSQL 16 临时数据库验证：Swift 构建通过；服务端 17 个定向测试和 Actor lane 20 个测试通过，共 37 个。覆盖 direct/group 永久回执、剩余 1 条额度的双消息批次、尾部条件失败后的 `[A,A,expired]` 回滚与拒绝重建、实际 Actor 入口指标、用户事件队首隔离/事务回滚/丢失确认恢复、worker 有界并发/取消/租约过期和 metrics 渲染。schema bootstrap、漂移/readiness 契约检查通过；容量诊断返回全部 7 张预期台账；`git diff --check` 通过。

新增三项真实 PostgreSQL 边界回归通过：持有第二个操作锁并由 `pg_blocking_pids` 确认批次等待后，另一事务仍可取得 room 行锁；控制侧账号策略锁阻塞授权预留时，同操作 `closeIfAbsent` 仍能先提交；messages 插入触发器确认第一条 owner 正文写入时两条授权意图均已提交。前两项直接覆盖操作锁/房间锁与控制锁/Owner 操作锁的交叉顺序，第三项覆盖后续授权不再插入 Owner 正文执行中。

输入校验与回滚恢复回归：真实 PostgreSQL 16 下 10 个定向测试、14 个参数化用例通过。新增覆盖 HTTP/Gateway 解码后的非 UUID 操作/账号 ID、非法项位于有效项之后时不预留控制授权；限流和租约变化时完整恢复单聊拒绝及重复请求；断言私有时间线、outbox、发送能力和 denied 授权证明一致；恢复写入失败时所有 Owner 事实与回执原子回滚；无持久身份的临时指纹冲突改为 deferred，原有执行回执或控制意图支持的冲突继续保留。原有额度、授权锁顺序和永久回执测试同时通过，`git diff --check` 通过。此次没有新增吞吐或延迟测量。

该组定向回归可用同一临时 PostgreSQL 环境执行：

```sh
PGHOST=127.0.0.1 PGPORT=<temporary-port> PGUSER=<temporary-role> \
  bash scripts/test_v2_server_native_postgres.sh --filter \
  'PostgresV2RoomWriteStoreIntegrationTests/(durableSend.*|permanentMessageSendReceipts)'
```

可复现命令：

```sh
# 指向专用临时 PostgreSQL；脚本自行创建和删除五个测试数据库。
PGHOST=127.0.0.1 PGPORT=<temporary-port> PGUSER=<temporary-role> \
  bash scripts/test_v2_server_native_postgres.sh --filter \
  'V2RoomTurnLaneTests|V2SendOperationBatchMetricsTests|V2UserStateEventWorkerTests|V2VaporMetricsRoutesTests/rendersRuntimePressureMetrics|PostgresV2UserStateEventTests/(claimsOneStreamHeadPerUser|recoversLostAcknowledgement|sourceTransactionAtomicity)|PostgresV2RoomWriteStoreIntegrationTests/(permanentMessageSendReceipts|durableSendBatch.*|actorFactoryRestoresSendAndQueries)'
PGHOST=127.0.0.1 PGPORT=<temporary-port> PGUSER=<temporary-role> \
  IMV2_SCHEMA_BOOTSTRAP_NATIVE=1 bash scripts/test_v2_postgres_schema_bootstrap.sh
```

此次未运行完整测试套件或大型压测。仍保留的约束：批次内正文 SQL 是逐项标量路径，尚未复用旧 set-based 快追加；用户工作窗口排空后才填充下一窗口；永久身份台账仍线性增长。当前证据证明相关正确性与装配，不能据此宣称吞吐或 P95/P99 已达到生产容量目标。current64 仍遵循项目的新库合同，不提供 current63 的在线迁移；现存旧库会被 readiness 拒绝。

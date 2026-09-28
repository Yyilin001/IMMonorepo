# B07：跨批次公平性与实际网络重试

本批修复有限批次之间的 lane 轮转，并补充真实 SQLite、protobuf、Network.framework 与 runtime 生命周期组合验证。B07 保持“已实现待验证”：实际 App scene 进入后台、系统挂起再恢复仍需独立验收。

## 当前执行所有权

下方 B07 lane 与 TCP outbox 验证记录描述历史批次。当前已退休业务写接口不再经这些 lane 重放：App 先保存领域意图，准备阶段冻结 command，账户 `V2OperationWorkDispatcher` 按持久 action/attempt/due 执行领域操作。消息发送新增 TCP 优先、HTTPS 可独立提交及恢复的路由，仍由同一个 dispatcher 管理原身份；见[双通道实施记录](message-send-dual-transport.md)。其余 HTTP 领域操作继续按原合同提交和恢复。资源与特殊安全恢复由各自账户活动拥有；页面取消只解除观察。TLS 承载同步、查询、握手、瞬时控制及新协商的消息发送/恢复操作，presence suppression 控制不会进入持久重试。

HTTP leaf 通过共享 scheduler 准入，重试标记、服务 Retry-After 冷却与诊断保持有界；认证刷新不会为业务写自动创建新 ID。当前整批迁移仍待集中验证，下方历史网络测试不证明新领域合同、完整 App scene 或真实后台传输已验收。

## 本批发现并修复的问题

`V2FairDurableCommandScheduler.flush` 原来每次从首个 lane 开始。三个 lane 持续有工作而每批预算为 1 或 2 时，后面的 lane 永远没有执行机会；预算为 4 时也会反复偏向第一条 lane。旧测试只检查单个批次，未覆盖跨批次位置。

当时 App 注册 13 条 lane，批次预算为 256，因此没有证据表明它当前会触发上述完全饥饿。但公开调度器允许任何正预算；保持跨批次轮转才能兑现它的公平性合同，也避免预算调整引入故障。

修复后 actor 保存下一条 lane 的索引，并在执行 lane 前推进。每批结束时保留进度；空闲 lane 不消耗工作预算；所有 lane 一轮均无进展则退出。单飞和生命周期取消机制保持原有所有权。时间、空间复杂度不增加量级。

## 验证覆盖

- 反向证据：修复前预算 1、2、4 的三个跨批次场景均失败；修复后顺序符合持续轮转，原有忙 lane/空闲 lane 场景仍通过。
- 组合测试使用实际 `NWListener`/`NWConnection`、生产 frame adapter 与 `V2ProtobufSyncTransport`，服务端为可控 protobuf peer。
- 发送与编辑各一个真实 outbox engine，共用单条连接、实际 SQLite 和 GRDB observation；每批仅允许一个工作项，启动批次后必须由 runtime 自己继续调度另一个 lane。
- peer 对每个命令第一次返回可重试错误及 1 秒期限，第二次返回成功。安静连接无额外 hint 或人工 flush，两个 lane 都自动持久化成功。
- worker 空闲后再次入队，观察数据库通知唤醒；两个命令写入重试时间后停止 runtime。推进测试墙钟 60 秒，确认停止期间没有网络尝试或调度摘要读取。
- 用另一 SQLite pool 重开同一文件，重新创建两个 engine 和 runtime，建立第二条实际网络连接，逾期命令自动完成。四个原始 operation/client message ID 各恰好收到两次请求，共 8 次；无换 ID 重建命令。
- 测试停止所有 runtime、listener/socket，并删除本用例 UUID 目录。

这里直接执行的是生产 `V2ClientRuntime` 的启动、停止和 retry loop 所有权。测试 activity 省略无关的初始同步、heartbeat、订阅等工作；不能由此声称完整 App scene 或服务端业务授权已验收。使用 loopback TCP 验证回调和传输，不代表 TLS 证书/部署验收。推进测试墙钟并重建 runtime 也不等于实际 iOS 挂起。

## 证据与剩余验收

精确测试数量、日志与源文件哈希见 [manifest](../../docs/reviews/verification-records.md#20260906-durable-retry-network)。相关套件可用 `client-run.sh --filter 'V2NetworkCommandRetryTests|V2CommandRetrySchedulerTests|V2FairDurableCommandSchedulerTests|V2TLSFrameConnectionLifecycleTests|V2ClientRuntimeTests'` 复现。

下一步需在真实 App 生命周期下，保留待重试命令进入后台并恢复，确认调度重建、多个实际注册 lane 的最终状态与离线无忙等。当前 App 单元回归只作为依赖构建和行为回归，不能替代该验收。

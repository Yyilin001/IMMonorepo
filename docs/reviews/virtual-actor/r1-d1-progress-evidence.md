# 激活栅栏与消息存储实施证据

本页记录 R1 与 D1 的局部实现，不代表所有生产入口已改走 Virtual Actor。业务基线仍是 main 的 `f1cdd78d6a21bf0ae23da627c0710c65115236aa`。

## 持久 authority

`PostgresV2RoomActivationStore` 在实际 owner 数据库保存完整 activation token。释放保留递增 epoch。获取、续租、释放以及业务栅栏按房间 UUID 排序，先锁 rooms，再锁 activation 行，最后用 `clock_timestamp()` 验证完整 token 和有效期。旧事务已持有栅栏时，可以先提交；新 epoch 一旦提交，旧 token 不能再提交写入。

canonical schema、readiness 和 bootstrap drift 检查均包含 activation 表。R1 的真实 Linux Swift 6.4 Release 首轮 5 项测试通过；后续 Debug 7 项通过，最终增量重跑 7 项通过。bootstrap/drift 脚本退出 0。日志保存在 `/Users/yyl/.codex/virtual-actor-builds/r1/` 的 `linux-test.log`、`linux-debug-test.log`、`linux-final-test.log`、`schema-bootstrap-final.log`。任务专用数据库资源已由 R1 worker 清理。

SQL 的 lock/statement/idle-in-transaction 超时不能代替整个事务的总期限。总期限与取消、晚到 COMMIT、共享 batcher 的通知仍需在最终执行器组合中验证。

## 消息写入

`V2RoomActivationWriteScope` 是已获得 turn 的不可变 token 集合；它不做寻址，不获取另一个 turn。发送、编辑、撤回、表态存储可绑定该 scope；对应 SQL 在操作锁之后、幂等重放之前校验 full token。旧初始化路径目前保留供迁移，生产组合根尚未切换。

发送的 warm fast path 在业务事务之前预取额度。房间额度的 key 加入完整 activation token，独立 refill 事务先验证该 token；继任 token 不复用旧余额。共享 shard 额度仍按 shard 聚合。事务体已返回但 COMMIT 未获确认时，异常保持 outcomeUnknown，相关额度只丢弃本地句柄，不退回可用余额。提交后结果转换或控制面 ACK 失败也不能变成业务回滚。

原生 Swift 6.4、jobs=2、独立 PostgreSQL 16 容器上实际运行：

```sh
# 两个专用 disposable 数据库 URL 由测试环境注入。
swift test --package-path IMV2Server --disable-automatic-resolution -j 2 \
  --filter 'activationFencedSendAndReplay|activationRoomCreditIsolation|activationMessageMutation|V2RoomTransactionAttemptTests'
```

`/tmp/imv2-va-d1-final-tests.log`：退出 0，6 项测试通过，其中 mutation 测试包含 edit/withdraw/reaction 三个参数场景。真实 SQL 覆盖旧 token 的新发送及重放拒绝、继任 token 恢复原回执、三种 mutation 的重放栅栏、跨 epoch 房间额度隔离、重复退款不生效。三项 transaction/scope 单元测试独立覆盖 COMMIT 阶段不确定性分类与未授予 authority 拒绝。

`V2RoomMessagingExecutor` 已提供 concrete send/edit/withdraw/reaction 执行接口，准备发送时保留服务器生成的 ID、时刻和 token；typed domain error 通过闭合集合传输。共享发送 batcher、具体 RoomExecutor 与 special-account audit 的后续实现/真实 SQL 结果见[组合进展](i1-composition-progress-evidence.md)；远端业务链路与 App 接线仍待完成，不能将局部 executor 测试当成性能验收结果。

随后用相同真实数据库环境运行 `PostgresV2RoomActivationTests|V2RoomActivationHostTests|V2ActorMessaging|V2RoomTransactionAttemptTests` 及上述三个消息 SQL 测试，退出 0：Server 21 项、Host 19 项、Contracts 2 项通过。mutation 三个场景现经 concrete executor 执行；新增闭集错误往返与基础设施错误不降格测试。R1 新增 deferred COMMIT trigger 故障注入：事务体成功、COMMIT 报错时返回 typed lease outcomeUnknown，不发布 ready；注入本身会回滚，不能冒充“已提交但 ACK 丢失”的网络证据。日志：`/Users/yyl/.codex/virtual-actor-builds/d1/current-native-postgres-tests.log`。

## 其他已执行检查

- `/tmp/imv2-va-integrated-runtime-tests.log`：3 项 transaction/scope 单元测试及 36 项 Host/lane/pair 测试通过；Host 使用 fake lease store，不是真实集群验收。
- `/tmp/imv2-va-d1-postgres-tests.log`：两项真实消息/额度 SQL 测试、6 项 creation/invitation mapper、2 项对应 contract、7 项 signed session 测试通过。
- 传输解析前的帧上限、真实 mTLS 超限头与 Linux 双进程探针见 [P0 有界传输证据](p0-bounded-transport-evidence.md)。

G2 的双 host 接管、G3 的真实远端业务调用、G4 全部 writers、G5 故障和性能 gate 均未完成。

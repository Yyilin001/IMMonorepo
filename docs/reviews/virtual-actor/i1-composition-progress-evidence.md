# Room Actor 组合与真实数据库阶段证据

本页记录已经执行的局部验证。生产 App 切换、真实远端业务调用和 G2–G5 尚未验收。基线是 `f1cdd78d6a21bf0ae23da627c0710c65115236aa`，不使用原工作目录的 Distributed Actor 实验。

## 具体执行器与恢复

`b06c9f3` 接入 `V2RoomServerActivationFactory`、owner resolver/lease-store adapter，以及发送、消息修改、房间管理、查询、回执、邀请、特殊账号审计的实际数据库 handler。每个物理 owner 共享池和 batcher，每次激活恢复 handler 并验证持久 token；没有把成员或策略快照当作永久权威。Server 依赖 Runtime，Runtime/Cluster 不依赖 Server。

实际命令使用两个独立 disposable PostgreSQL 16 数据库，原生 Swift 6.4、jobs=2：

```sh
swift test --package-path IMV2Server --disable-automatic-resolution -j 2 \
  --filter 'actorFactoryRestoresSendAndQueries|actorCreationDraftReadiness|V2ActorAuthenticationTests'
```

`/tmp/imv2-va-factory-final.log`，退出 0：Server 2 项、认证 8 项通过。Host + 真实 SQL 验证发送、恢复状态查询、非成员日志拒绝、退休、新 incarnation/更大 epoch 恢复同一 clientMessageID，仅存在一条消息。该测试在同一进程内直接调用 Host，不是 Cluster 远端业务证据。认证测试包含普通网关不能伪造邀请 control grant、协调服务可以提交，以及直接 `.create` 不能绕过 control intent。

测试使用当前创建合同的正数 membership revision；通用历史写入 fixture 的零 revision 不能用作房间恢复测试的有效初始状态。

`V2ActorGrantedSendBatchAdapter.retire(token)` 的 Factory close 接线已加入上述提交，随后与 D6 统一入口另行编译验证；不把此前通过的测试误记为该新增一行的验证。

## 合批与旧 token

`33107986` 合入有界 activation 追踪、未知 SQL 结果隔离、同房间 scalar/partition fallback 保序及真实数据库测试。数据库测试发现 large-group PostgreSQL 优化支路仅在配置 ownerRoutes 时调用 fence，导致只有 activationScope 的调用绕过校验；`0e8307d` 修复该条件。

子代理在独立 PostgreSQL 16 的两个数据库执行 `--filter actorGranted`：4/4、退出 0。覆盖同房间 3 次发送一个原子批、同 owner 两个房间一个原子批、旧 token 混入时整个批次零写入，以及 COMMIT 阶段错误时后继请求不再使用该 token 执行。独立 batcher 10/10、既有 send service 27/27 通过。deferred COMMIT trigger 实际使事务回滚；它证明不确定结果的隔离路径，不能证明“提交成功但响应丢失”。

## 控制面创建与审计

`daa6c13` 将 canonical schema 升至 `im-v2-current-53`。控制库中的 group creation draft 不再外键引用本地 `rooms`，允许房间建在另一 owner 数据库；完成状态仍要求非空 roomID。readiness 和 schema drift 检查会拒绝重新引入该本地外键。`/tmp/imv2-va-cross-owner-schema.log` 的全新 bootstrap、导出/恢复与 drift 检查退出 0；Factory suite 也实际验证 readiness 拒绝错误外键。

`cb67b0b` 的特殊账号审计，在操作锁后、重放或写入前验证完整 token。真实 PostgreSQL `activationSpecialAccountAudit` 1/1 通过，日志 `/tmp/imv2-va-audit-postgres.log`：发送后记录审计，旧 token 的审计重放被拒，继任 token 恢复同一审计且没有重复操作行。该用例没有独立验证旧 token 的全新审计请求。

D6 的独立维护与压缩竞态证据见 [后台维护验证](d6-maintenance-evidence.md)。转发所有阶段的 scoped import hook 已提交 `8ed6f7f`，跨库实际执行仍由 D5 的专项验证补齐。

## 后续集成回归

- `9183524` 将 D6 维护能力加入总 Request/Response、Factory 和独立 `roomMaintenance` 服务权限。`/tmp/imv2-va-client-maintenance-integration.log` 退出 0：Gateway/batcher/maintenance suites 共报告 77 项、认证 9 项通过。该次没有 PostgreSQL 环境变量，maintenance SQL 用例入口跳过数据库部分，不能计作数据库验证；数据库证据仍以 D6 专项页为准。
- `9361e47` 清理 recovery batcher 已完成/取消的用户定时器键，改用不可复用的 UUID 识别晚到回调；标量已读旧 token 从每行 store error 恢复为 Runtime stale-activation failure，批量逐行结果合同不变。`/tmp/imv2-va-receipt-stale-timers-postgres.log` 的真实数据库 query/receipt suite 7/7、退出 0。
- `84d9ded` 增加发送/编辑/撤回/表态的逻辑 RoomRef 门面。`/tmp/imv2-va-clients-lifecycle.log` 的新门面与定时器生命周期测试 3/3、退出 0。
- 集成上述 batcher、Factory close/retire 与 D6 dispatch 后，使用实际两个 PostgreSQL 数据库运行 `--skip-build --filter 'actorGranted|actorFactoryRestoresSendAndQueries|actorCreationDraftReadiness'`：`/tmp/imv2-va-factory-granted-current.log` 6/6、退出 0。

文档链接、结构检查与 `check_v2_virtual_actor_inventory.py` 已通过。新的生产路由仍在接线，这些结果不关闭 G2–G5。

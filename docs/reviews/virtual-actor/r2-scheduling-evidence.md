# R2 FIFO 与双房间预约证据

基于固定 main 的隔离分支实施。本文只记录调度器与协调器的实际验证；没有将 fake executor 视为 PostgreSQL fence 或跨进程通过证据。

## 实现边界

- `V2RoomTurnLane<Request, Response>` 从已计入节点/房间预算的不可变请求字节解码 typed request，单消费者持有一个跨 await 的未决 turn。
- 连续 send 共用有界微批；其他命令、查询与 reservation 都是屏障。传给 DB batcher 的是原始单次 batch deadline，不能重新等一个完整窗口。
- 排队取消/超时确定未派发；执行中的取消只结束 caller 等待，继续持有 turn 和额度直至真实事务回执。事务结果未知时拒绝后续工作，保留额度到数据库隔离后的退休。
- Reservation 共用计数/字节上限，另受 host-wide concurrency 上限约束。所有参与房间确认 dispatch 后协调器才运行 SQL。已授予预约到期不会恢复同 epoch 服务。
- `V2RoomReservationCoordinator` 每次只处理一个 source-target pair，去重后按 RoomID 排序；明确未执行的失败安全释放，未知 SQL 通知全部参与者。普通 turn 的 TaskLocal scope 禁止同步进入协调器。
- 确定 SQL 已提交但通知丢失，调用者仍获得确定结果；失联 holder 保持关闭，等待有界预约到期并退休。不会因为通知失败把已经提交的结果改为回滚。

## 实际执行

宿主 macOS Swift 6.4，独立集成 worktree，jobs=2：

    swift test --disable-automatic-resolution --package-path IMV2Server --jobs 2 \
      --filter 'V2RoomTurnLaneTests|V2RoomCommandBudgetTests'

退出 0，12 项 lane + 4 项 budget 测试通过。覆盖 await 不重叠、send/barrier/send 次序、排队与执行取消、超时区别、未知结果保留容量、drain、新旧预约身份、预约超时以及节点预约上限。日志：`/tmp/imv2-va-r2-reservation-tests.log`。

    swift test --disable-automatic-resolution --package-path IMV2Server --jobs 2 \
      --filter 'V2RoomReservationCoordinatorTests|V2RoomTurnLaneTests|V2ActorAdministration|V2ActorMessaging'

退出 0，运行时 18 项、Server mapper 8 项、Messaging contract 2 项通过。新增 6 项协调器测试使用阶段 gate：对向 pair、source=target、第二个预约失败、dispatch ACK 丢失、未知事务传播、完成通知丢失与禁止嵌套 turn。日志：`/tmp/imv2-va-r2-coordination-tests.log`。集成同时修复 D1/D2 重复定义的 admission failure，抽到共享类型与 mapper。

## 后续 gate

Hosting/Lifecycle、真实共享 SQL batcher、全部 domain executor、远端预约消息与重放防护尚未在此证据中验收。G2–G5 仍需真实进程、数据库故障、全部 writer 接线及相对性能测量；这里的容量默认值不是生产吞吐承诺。

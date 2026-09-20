# 房间日志当前版本运行验收：2026-09-13

当前回执与个人事件改造后的 Release 实测。服务端1022项全量通过后构建当前网关和负载工具；每轮独立临时数据库，20在线连接，800条消息，固定种子42。此结果证明本次有界场景，不代表容量上限或旧模式性能比较。测试期间同一主机还运行App验收，延迟与资源数据不用于严格性能对比。

## 固定负载

三轮均确认800条计划、发送、ACK与数据库消息一致，零失败/跳过/队列溢出或丢弃；300次个人同步全部返回，20客户端房间游标与数据库水位一致，个人日志公共message记录为0。

| 房间 | 消息p50/p95/p99 ms | 房间页p50/p95/p99 ms | 用户表插入/更新/删除增量 | WAL字节 |
| --- | --- | --- | --- | --- |
| 私聊10对 | 7/11/15 | 1/5/9 | 2606/2766/40 | 2588336 |
| 20人标准群 | 7/11/13 | 1/4/12 | 3812/2420/16 | 3291776 |
| 100000人大群 | 7/11/12 | 1/4/11 | 3859/2461/54 | 3726824 |

WAL是实例口径，用户表增量包含后台工作，均不能精确归因于消息正文。群只有20人在线，夹具未注入群个人发现事件。

## 强制重启恢复

- 私聊：确认800条ACK后SIGKILL网关，使用原数据库重启；20客户端从零游标恢复1600条房间记录，最终水位一致。
- 100000人大群：确认800条ACK后SIGKILL网关，使用原数据库重启；20客户端从零游标恢复16000条房间记录，最终水位一致。

该重启发生在已确认提交之后，不是发送中途宕机；与个人事件事务/丢ACK重放专项联合评估，不能将此结果替代单侧提示UI验收。每轮最后正常关闭网关，检查无排空超时，删除自身测试库和临时凭据。

## 证据

- load / 0：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-ckyt2uu0`
- load / 20：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-jaj6gl2j`
- load / 100000：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-2188lqkx`
- restart / 0：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-ekm47tol`
- restart / 100000：`/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-suqwy8u4`

构建日志：`/tmp/imv2-current-release-build.log`；调度日志：`/tmp/imv2-current-release-acceptance.log`。

- IMV2ServerApp SHA-256：`e3fde8825dbb591ed0effa6511fbb0266cc17d9f876423718f0e5c29d1f2004a`
- IMV2GatewayLoadGenerator SHA-256：`3a843e2f206710b054d229ec40590ba4cfb33a207c0ee8c02598b9ef20ec34af`

## Final personal-event and App acceptance

The current Release personal-event probe deliberately rejected source acknowledgements until all 40 target receipts committed. After SIGKILL, fault removal and restart against the same database, all 40 source events were acknowledged. The complete receipt, user-log and sequence snapshots remained identical. Normal shutdown and owned-resource cleanup passed.

Evidence: `/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-0asg1pzg/personal-restart-verification.json`: committedBeforeKill=40, unacknowledgedBeforeKill=40, allAcknowledgedAfterRestart=true, originalReceiptsLogsAndSequencesUnchanged=true. Runner log: `/tmp/imv2-personal-ack-restart-v2.log`.

The full real-account/TLS/App v5 acceptance passed: three UI tests passed, one existing environment-conditional test skipped, zero failures; the separate headless-wake test passed. The private-hint test checks independent sender/receiver SQLite stores, sender-only visibility, reconnect, the actual conversation UI and App cold restore. Final persistence counts were 16 devices, 4 revoked devices, zero valid access/refresh tokens for revoked devices, and 4 revocation events. HTTP and process exit checks passed.

Evidence directory: `/tmp/imv2-current-private-hint-acceptance-v5`, including app-summary.json, headless-summary.json, http-summary.json and cleanup.log. The dedicated simulator was removed; owned services and PostgreSQL stopped; temporary databases, certificates and keys were removed.

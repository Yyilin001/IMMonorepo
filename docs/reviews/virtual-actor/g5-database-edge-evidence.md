# #17 Host 到 control / owner 数据库的独立断链

真实 Linux Release 探针在源码 `20f798e4263fcc75f3f6820bd1e80417d844bc33` 通过。入口为 `IMV2/scripts/test_v2_virtual_actor_database_edges.py` 和 `VirtualActorBusinessProbe database-edge-host|database-edge-client`，实际组合 `V2RoomActorApplication`、生产 Server factory、PostgreSQL lease/fence 和带 mTLS 的 DistributedCluster。两个 Host、一个 caller、三个独立 PostgreSQL 16 实例分别承担 control、owner-a、owner-b；每个进程到每个数据库的链路使用独立 Docker 网络。

证据目录为 `/Users/yyl/.codex/virtual-actor-builds/database-edges-20f798e4-run02`。`result.json` 的 `passed` 为 true、`cleanupErrors` 为空；三个进程的 `*-stopped.json` 与容器退出码均确认正常排空。构建元数据在 `/Users/yyl/.codex/virtual-actor-builds/database-edge-release-20f798e4/result.json`，Release 产品 SHA-256 为 `b2dd09da1b6575e0522811d4e5dfbf7ccd3701a7e80254660a1b81c646b38ec1`，Swift 6.4 Jammy 镜像固定为 `sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6`。

先经真实 RoomRef 在两房间发送消息并编辑到 revision 2，证明两个 Host 的 control/owner SQL 路径都已使用。故障注入移除 Host A 的一个数据库网络，同时仅终止该链路已观测到的 PostgreSQL backend，使既有 TCP 连接及时显现断开；不会停止数据库或 Actor 进程。注入前后检查网络集合，断开的目标 IP 的 TCP 访问超时，Actor 网络和其他数据库网络保持原状。Host A 用真实 SQL 确认另一条数据库链路可用，Host B 则确认自己的 control 和 owner SQL 都可用。

| 阶段 | 实际断言与结果 |
| --- | --- |
| 只断 Host A → control | A 的新编辑返回 deadline failure，B 的新编辑成功；独立 owner SQL 持续 35 秒确认 A 的固定 edit operation 无记录、消息 revision 仍为 2。A 在超过一个默认 30 秒租约周期后仍持有相同 Host/incarnation/epoch 1 的有效租约，证明 owner 续租不依赖 control 连接。 |
| control 恢复 | 原操作 ID 重放与再次重放都得到 revision 3，SQL 只有一条编辑操作。物理 Host/incarnation 未变；生产执行器对底层 driver 错误保守归类为 outcomeUnknown，待旧调用结束后退役并以 epoch 2 恢复。此安全退役不是 control 故障期间无法续租。 |
| 只断 Host A → owner-a | 等 owner-a 的 PostgreSQL `clock_timestamp()` 确认 lease 过期，A 的新发送返回 unavailable，B 的发送成功；独立 owner-a SQL 再持续 35 秒确认该固定 clientMessageID 的消息和 completion 都为零。 |
| owner 恢复 | 同一 clientMessageID 重放两次得到同一 messageID；owner-a 与 owner-b 对应新操作的消息和 completion 各一条，各库最终消息总数为 2。A 的 epoch 从 control 恢复后的 2 进一步升到 3；Host/incarnation 保持不变。 |

运行期间持续验证三个进程的容器身份、StartedAt 和存活状态，故障没有重启进程。探针只接受预期的 unavailable/deadline/lease 等 RoomCallFailure 或明确的业务 unavailable；权限、请求格式、过载和其他异常不会被当作故障通过。恢复重试保留原操作 ID，并有总时间上限。

第一次 `51928dd1` 运行已完成 control 断链期间的续租、健康 B 编辑与零持久效果检查，但测试错误要求恢复后 epoch 仍为 1。检查 `v2RoomDomainCompletion` 的保守 driver-error 语义后，测试改为保留断链期间同 epoch 的续租断言、允许恢复时安全退役，并以恢复后的 epoch 作为下一次 owner 故障的严格基线；未修改生产实现。第一次结果保存在 `database-edges-51928dd1-run01`，不是通过证据。

可在对应干净源码和已验证 Release 产品下复跑：

```sh
python3 IMV2/scripts/test_v2_virtual_actor_database_edges.py \
  --docker-context YOUR_DISPOSABLE_CONTEXT \
  --release-dir /absolute/path/to/products \
  --build-result /absolute/path/to/result.json \
  --artifact-dir /absolute/path/to/new-evidence-directory
```

这是完整 Actor 组合下的 **Host 到特定数据库链路隔离**。它不重启 PostgreSQL、不注入 COMMIT ACK 丢失，也不宣称 Host B 接管 Host A 的 shard（本探针故意按 shard 固定放置）。数据库重启/批量查询部分 owner 失败由容量 fault 场景另验；锁等待和真实成功 COMMIT 丢 ACK 保留[原事务证据](i1-composition-progress-evidence.md)，Actor 网络分区及另一 Host 接管保留 [G6 证据](g6-multihost-evidence.md)。

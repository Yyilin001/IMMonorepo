> 2026-10-06 最新实现：权限读取已改为不带租约的版本化内存快照，变更主动推送；本文件中的周期续租、失效后重拉和冷加载调度描述属于此前实现。见 [完整改造与验证](policy-versioned-memory-snapshot-implementation.zh-CN.md)。

# 发送权限改为节点共享内存读取（2026-10-06）

本轮针对“每次发送仍向 Policy Owner 获取状态”的问题修改实现。消息、房间持久化事务继续使用原链路；权限事实按账号、双方关系、陌生人设置共享缓存，避免每个房间复制权限，也避免每条消息重复 RPC。

## 已落地的路径

```text
首次使用 scope → 冷加载调度 → 本地或远端 Policy Owner → 节点共享缓存
后续发送 → 节点缓存 → 组合本次发送快照 → 房间事务
策略修改 → 业务数据库事务 COMMIT → Owner 内存发布
         → 各配置节点对应 scope 失效 → 修改成功响应
         → 下一次使用该 scope 加载新事实
后台维护 → 活跃 scope 在有效期到期前续租 → 更新缓存中的有效期限
```

`GatewayPolicyAssembly` 每个宿主创建一个 `V2NodePolicyStateCache`，同节点的所有物理分片和房间共享。`PostgresV2RemotePolicyOwners` 的内存探测和普通状态读取优先读此缓存。命中时不解析远端路由、不创建 Cluster Client、不获取 SQL 资源。

私聊仍组合发送者账号、接收者账号、双方关系，非好友再增加接收者的陌生人设置；每条消息仍做业务判断。缓存的是事实，非永久授权结论。

## 更新及并发边界

- `PostgresV2PolicyOwnerDirectory.changeExecution` 等待真实 COMMIT 和 Owner 内存发布后调用失效通知，再返回业务结果。
- `V2PolicyCacheInvalidationPublisher` 先失效本节点，再通过已认证 RPC 通知配置中的其他 Gateway 宿主。目标包含不承担 Policy 分区的房间宿主。
- RPC 复用已有宿主端点，服务身份须具备 `policyMutation` 权限；请求绑定目标端点，回复由现有认证交换校验。
- 同一 scope 的并发首次加载共享实际任务。失效发生于加载期间时，旧任务保留到实际响应结算，但该 scope 的旧结果不得发布或返回成有效授权。同一批次中未失效的其他 scope 仍可发布，依赖它们的房间不必跟随重试。
- 调用方取消不会取消共享加载，也不会提前释放实际加载容量。
- 通知失败发生在数据库提交之后，返回 `outcomeUnknown`，不能宣称回滚；原操作身份仍可重试。持久化 policy outbox 再次通知失效后才标记发布成功。
- 失效仅作用于事实缓存，没有增加房间排空流程。此前已取得有效发送快照的操作仍沿用原执行语义，不提供严格撤销所有已准备消息的截止保证。

## 缓存与续租边界

缓存最多 32,768 个 scope，最多 128 个实际加载任务，按读取顺序淘汰。淘汰后下一次使用重新加载；“首次加载一次”指缓存有效且未淘汰期间，不是无限持有。

每秒扫描一次，近期 60 秒被发送读取过的状态，在剩余有效期不足 10 秒时进入后台续租。每轮最多 512 个 scope、每批最多 4 个 scope、最多 4 个并行批次。后台读取不延长状态的活跃使用时间，闲置状态停止续租。

Owner 默认有效期仍为 30 秒。新增 refresh 请求允许在到期前更新所有权；Owner 身份、epoch、revision 匹配时复用已提交事实，不重新查询账号、关系或设置表。因此所有权 RPC/SQL 成本转移到后台维护，没有消除它们。

后台续租失败时，只允许尚未过期的事实继续被读取；状态真正过期后热探测返回 miss，由原有有界冷加载补救，不继续使用过期授权。故障、续租不足或容量淘汰仍可能产生前台冷加载。

## 本地验证

最终重新构建当前工作树，构建成功（40.32 秒）。分组串行使用独立 PostgreSQL 25462 中两个一次性数据库，避免不同测试套件同时重建同一 schema；TCP 使用测试专用 Cluster 节点。

- `V2NodePolicyStateCacheTests` 和 `PostgresV2RemotePolicyOwnershipTests`：11 项测试通过（2.573 秒）。包含 8 项缓存测试及 wire/TCP/提前续租测试，旧注册模式与当前模式均覆盖。验证 10,000 次热读取只加载一次、并发加载合并、调用取消保留实际容量、旧响应不回填、同批未失效 scope 独立完成、过期拒绝、后台续租以及淘汰。TCP 测试在错误远端响应期间执行 100 轮缓存读取，确认请求计数不增长；真实拉黑、设置修改和封禁通过提交后 publisher 发送 TCP 失效通知。隐藏全部六张权限事实表后，提前续租仍成功，证明未重新查询这些表。
- 房间回归：`currentPolicyServiceSendAndReplay`、`currentPolicyMutationDoesNotWaitForRoom`、`policyMutationCommittedMemoryPublication`、`currentPolicyMutationSupersedesCapturedColdResult`、`warmRoomPolicyMutationIsolation` 共 5 项通过（18.565 秒）。覆盖提交前后内存状态、失败提交、旧冷结果、消息执行与回执重放，以及拉黑/解除好友/设置/封禁的房间行为。
- 两组测试实际进程 exit=0，数据库随后停止，25462 确认无响应；变更文件格式检查通过。

日志：`/tmp/imv2-node-policy-cache-complete-native.log`、`/tmp/imv2-node-policy-cache-complete-room.log`。

实现阶段未执行容量测试。随后按用户要求执行 R24：权限探测平均耗时降低约 99.8%，同六份负载报告消息 p95 降低约 26.5%–31.8%，但仍在约 20 秒失败，未达标。详情见 [节点缓存修改后性能报告](performance-policy-node-cache-10000-online-1000msg-20261006.md)。

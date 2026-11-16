# 项目自定义 Distributed Actor 运行时

本分支直接替换 Apple `DistributedCluster`。生产装配、测试夹具和探针均使用 `IMActorSystem`；不提供旧协议、旧 ActorID 或旧 Receptionist 的兼容层。Swift 原生 `distributed actor` 语法保留。

## 模块和调用路径

- `IMActorWire`：固定帧头、二进制值协议、物理 ActorID、长度上限与解码。
- `IMActorTransport`：SwiftNIO TCP、TLS 1.3 双向证书验证、连接复用、流量分类、credit、截止时间、取消与关闭。
- `IMActorSystem`：实现公开 `DistributedActorSystem` 协议，保存弱 Actor 注册表，处理调用/结果、显式服务目录及节点可达性。
- `IMV2ActorCluster`：业务签名、会话 MAC、授权、Raft、房间引用缓存和调度继续由项目控制。底层连接状态不是授权或 ownership 事实。

远端调用路径为：编译器生成调用 → 显式方法表 → 二进制参数 → NIO 帧 → 服务端方法表 → 编译器生成的目标执行入口。方法名和 Swift 类型名不随每次调用发送。注册时用仅记录调用的远端代理捕获编译器目标字符串，不执行 Actor 方法，不依赖私有运行时符号。

`Protocol/actor-rpc.json` 固定 16 个方法的编号与通道；`generate_actor_rpc.py` 生成注册代码。握手 digest 包含协议方法编号、目标字符串、通道、参数/结果类型编号和错误类型编号。不同表或不同编译目标被拒绝；此版本要求所有节点部署同一协议构建，未承诺跨编译器二进制兼容。

修改 wire type 的布局或固定帧语义时，必须提升 `IMFrame.version`；仅修改 Swift 编码实现不会自动改变协议 digest。CI 同时检查方法表生成结果，并执行无数据库的双进程 TLS smoke。

物理身份为节点逻辑名、进程启动 UUID、进程内递增 ActorID。地址只作路由提示。调用前检查握手节点的启动 UUID，重启后的同地址不会接收旧引用调用。本地调用仍走 Swift 本地 Actor 路径；业务激活、数据 ownerEpoch 和幂等约束不放进传输层。

## 帧、资源与执行语义

帧为 4 字节长度前缀、32 字节固定头、二进制 body。头含 magic、版本、kind、callID、actorID、methodID、剩余毫秒预算。接收长度头后立即验证上限，累计缓冲也受限。签名包 body 原样写入，无运行时 JSON/base64 包裹；业务原有 PB 和 MAC 保持。

每个 endpoint、每种流量类别复用一条出站连接，建连任务合并；失败后有 100–300ms 随机冷却。没有后台无限重连，也不自动重试业务调用，后续尝试由业务发现/请求触发。默认上限：256 个物理连接、每连接 256 个在途请求、8 MiB 请求 credit、节点 4096 个执行任务、64 MiB 出站请求、64 MiB 执行请求、64 MiB 已编码回复、64 MiB 待写预算。连接等待者也有全局数量上限。

执行准入按实际请求字节计费，直到方法返回才释放；回复利用 `IMWireValue.wireByteCount` 在编码前按精确大小申请独立额度，编码完成后校验长度，交给写队列后释放。该额度约束运行时编码缓冲，不约束业务方法自身分配的对象。普通 RPC、控制和 bulk 分别使用出站/执行/回复/写预算的 1/2、1/4、1/4，并始终受全局上限约束。小控制请求不再因允许 8 MiB 回复而被压到单并发。节点业务配置的帧上限为 `max(maximumRequestBytes, maximumReplyBytes) + 65,536`；运行时通用默认值为 2 MiB。

- **control**：目录查询、会话建立、placement 普通请求和 Raft 投票/append。
- **rpc**：房间普通调用、Gateway 实时投递、业务 RPC。
- **bulk**：Raft snapshot chunk 与批量 recovery。快照切块和校验沿用现有 Raft 实现。

方法表同时在接收端检查方法对应通道。出站调用、接收端执行及建连等待者的数量也分别保留通道额度：control 与 bulk 各为 `maximumExecutingCalls / 4` 向下取整，RPC 使用其余名额，三者总和等于原全局上限，不相互借用；配置至少为 4。取消的建连等待者仍持有本通道名额，直到共享建连实际结束。这样小报文也不能耗尽其他通道的数量额度。三个通道仍共享节点最大连接数与 EventLoop；不宣称任意故障下控制请求完全无等待。

调用表和定时状态受每连接 EventLoop 管理；发送侧用截止时间堆及一个最近到期定时器。截止预算覆盖建连/握手等待；一个等待者取消不会取消其他等待者共用的建连。入站执行任务拥有自己的可取消定时器。取消、超时或断线会结算调用者，但**只有 Actor 方法实际返回才释放执行额度和接收 credit**。超时不能证明远端事务未提交，原业务 `outcomeUnknown` 与幂等恢复继续生效。

TLS 出站完整验证证书链与服务端 DNS 名；入站要求客户端证书并验证其链，不对未知客户端执行 DNS 名检查。具体服务身份和权限继续由签名请求及 trust roster 验证。

写入按 32 帧、64 KiB 或下一轮 EventLoop 批量 flush；控制帧可立即 flush。写缓冲、执行任务及队列均受限，达到上限返回 overload 或关闭失去写入能力的连接；不增加无限等待队列。这里减少了通用框架封装与 flush 次数，仍存在结果编码及帧合并拷贝，不称为零拷贝。

关闭停止接纳并发送 drain，等待已经接纳的出站调用、接收端执行、建连等待者和写入结算，再关闭连接/EventLoop，避免本机没有执行任务时提前切断尚未返回的远端调用。并发关闭共享同一次 drain。`IMActorSystemSettings.shutdownTimeout` 必须为正，默认 10 秒；超时报告 deadlineExceeded 并保留资源所有权，可在操作返回后再次关闭。

## 发现、退役与观测

`publish` 只登记本机活对象；`lookup(key, at: endpoint)` 显式查询配置中的节点，没有 Gossip、集群全量目录复制或持久成员资格。业务层继续验证签名发现响应、roster、membership revision 和对端身份。目录每系统最多 256 个 key，每 key 最多 16 个 Actor。

可达性通过最新完整快照投递，包含断线 revision，消费者即使合并了短暂断线/重连也会退役旧投递会话。最多保存 512 个节点；旧失联记录可以淘汰。心跳每 5 秒一次，30 秒无入站活动断开；这只是故障提示，不夺取 Raft ownership。

`peerEvents` 的结束通知在状态锁外发出，包括关闭后新建的订阅，避免 `AsyncStream.onTermination` 同步回调再次获取同一互斥锁而崩溃。

Actor 释放广播退休通知，调用仍以未知 Actor/旧 incarnation 为最终依据；退休通知不是可靠持久消息。显式 watcher 有数量上限，业务重发现仍负责恢复。

`IMActorSystem.transportMetrics` 及 RoomCluster 节点的同名只读快照提供连接、建连等待、出站调用/字节、执行数/请求字节、回复编码字节、待写字节、已接纳、全局拒绝及已完成计数。`rejected` 仅统计节点执行准入拒绝，不能当作所有 RPC 失败总数；未新增 HTTP 指标端点。

启动进程时设置 `IM_ACTOR_RUNTIME_DEBUG=1` 可查看连接关闭、目录查询及签名通告失败原因；默认关闭，正式压测不启用。Linux 的 `TCP_NODELAY` 使用 NIO `tcpOption`，不能使用默认 `SOL_SOCKET` 层的 `socketOption`（在 Linux 上选项号 1 对应 `SO_DEBUG`）。

## 切换与验证

从旧运行时切换时，先排空旧进程，再部署全部新节点并重新发现引用。切换沿用数据库业务 schema、TLS 证书、服务身份和 trust roster。

最小复核命令：

```sh
python3 IMV2Server/Protocol/generate_actor_rpc.py --check
swift build --package-path IMV2Server -j 4
swift test --package-path IMV2Server -j 4 --filter 'IMWireTests|IMRuntimeLifecycleTests|V2ActorBinaryArgumentTests|V2RemoteCallDeadlineTests|V2InvocationReplyShutdownTests|V2RoomClusterDiscoveryTests|V2RoomClusterBridgeTests|V2RoomSubscriptionNetworkTests'
python3 IMV2Server/Tests/IMActorRuntimeProbe/run-smoke.py IMV2Server/.build/debug/IMActorRuntimeProbe
```

验证范围和开放问题见[运行时索引](README.md#尚未闭环)。

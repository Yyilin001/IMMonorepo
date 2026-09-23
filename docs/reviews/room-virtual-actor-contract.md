# 房间 Virtual Actor 当前合同

业务入口通过逻辑 RoomID 调用房间能力。`IMV2ActorRuntime` 负责定位、激活、恢复、顺序执行和回收；PostgreSQL 决定房间归属、写入资格和持久完成结果。当前实现的故障与容量验收状态见[执行证据](virtual-actor/README.md)，本合同不宣告尚未完成的 G5 通过。领域授权、幂等和保留政策继续服从[现有业务合同](README.md)。

## 模块与调用边界

| 模块 | 当前职责 |
| --- | --- |
| `IMV2ActorContracts` | 有界 wire DTO、逻辑身份、完整 activation token、调用结果及资源配置 |
| `IMV2ActorRuntime` | `V2RoomDirectory` / `V2RoomRef`、Host 生命周期、FIFO turn、命令许可及双房间 reservation |
| `IMV2ActorCluster` | 固定版本 DistributedCluster、已认证的物理 endpoint、mTLS、服务签名与发现 |
| `IMV2Server` | 保留领域请求/结果的 typed clients、Server factory/executor、PostgreSQL lease 与 transaction fence |
| `IMV2ActorApplication` | 身份/信任配置、节点启动、依赖组装与有序关闭 |

业务代码使用 `V2RoomRefMessagingClient`、`V2RoomRefQueryClient` 等领域门面；只需提供原请求中的 RoomID 和稳定 operation ID。底层 `directory.room(roomID).call(...)` 消费 Contracts DTO，物理 shard、Host 地址和 activation epoch 由基础设施处理。领域层不接收 DistributedActor ID，也不保存物理 endpoint。

Gateway 的房间命令、Account 的群昵称/邀请/消息媒体授权，以及房间维护写入均接入这些能力。用户同步、账号禁用、工作流认领、媒体 provider 复制和派生投影保留自己的持久权限边界；它们不因携带 RoomID 就变成房间权威写入。各入口和合法例外见[写者台账](virtual-actor/writer-ledger.md)。

## 定位、恢复与写入资格

1. Directory 根据持久 route 查数据 owner；租约记录位于该 owner 的实际数据库。数据 ownerEpoch 与 activationEpoch 独立。
2. 有效租约优先于集群 membership。只有没有有效租约时，具备该 owner 访问权限和容量的 Host 才竞争 acquire。
3. 同 Host 的首次访问共享恢复；跨 Host 以数据库锁与递增 epoch 决胜。Factory 完成恢复并重新验证资格后才发布 ready。
4. token 包含房间、data owner、activation epoch 和 Host incarnation。每次进程启动产生新 incarnation，迟到续租、释放和清理必须匹配完整 token。
5. 每个业务 SQL 事务在实际 owner 库获取 fence 锁，检查完整 token 和拿锁后的数据库时间，并持锁到 commit/rollback。新 epoch 获准后旧 epoch 不得再提交房间事实。

未知 RoomID 返回不存在；普通 resolve 不会隐式创建空房间。创建协调器先固定持久意图和 RoomID，再通过封闭 bootstrap 完成房间数据及目录，随后进入普通激活。

房间 Actor 保存有界运行状态，不把内存当消息或完成结果的权威。Directory 位置缓存、Host 资格及业务提示缓存均有容量、过期和代次检查；暖缓存不能绕过持久授权和事务 fence。

Directory 的只读位置 lookup 每跳最多等待 3 秒，已有更短截止优先。旧物理地址无响应后重新读取权威租约；超时不证明租约失效，也不允许抢占有效租约。激活、业务写和未知结果核对保留各自原有期限，已经派发的底层 RPC 仍追踪到实际完成。

## 顺序、微批与失败语义

Swift actor 的隔离不能保证跨 await 的完整业务串行。Runtime 显式维护 admission 次序和单个未决 turn；只有队首连续兼容 send 可以合批，管理变更、查询和 reservation 形成相应屏障。

同物理 owner 的房间共享 send、receipt、recovery batcher 和数据库预算。Runtime 的收集窗口与物理 batcher 沿用同一 ingress/截止时间，不叠加完整等待窗口。send 共享事务保持整批回滚合同，receipt 保持逐项结果合同。SQL 准入发生在实际 Host/批次边界，远端 Gateway 等待 RPC 时不占用 owner 数据库许可。

双房间同库写按规范 RoomID 顺序取得 reservation，再进入同一 scoped SQL 事务；跨 owner 的转发使用既有持久工作流、稳定源/目标身份及目标导入能力。信用补充在业务 fence 之外完成有界预留，不能持业务锁等待另一个连接 refill。信用和本地已接受状态绑定完整 token，Host 关闭时清理再释放身份额度。

`notAccepted` 表示已知未被接受；业务拒绝保持原领域结果。请求可能已进入持久执行或 COMMIT 回执丢失时保留 `outcomeUnknown`，停止旧 activation 的后续执行。重试使用原 operation ID 查询持久结果，不能重新生成业务身份，也不能把客户端取消当作未提交证明。

## 生命周期和关闭

Host 管理 absent、acquiring、restoring、ready、draining、uncertain、stopped 状态。激活等待者、恢复并发、房间/节点请求数与字节、reservation、位置缓存及 owner batch 状态都有有限预算。一个等待者取消不取消其他等待者共享的恢复。

idle 回收先关闭 admission，排空队列、在途 turn、reservation 和本房间 batch 状态，再关闭 executor、条件释放租约和注销 endpoint。旧实例的迟到清理不影响后继 token。租约续租独立于业务 FIFO；排空超时仍保留运行资源和租约责任，不能提前销毁共享数据库连接池。

应用关闭先停止入口/worker，再排空 Directory 与 Cluster/Host，最后释放数据库与线程资源。`V2RoomActorApplication.stop` 返回未完成时，上层不得把底层依赖当作已经安全关闭。

## 部署身份

Gateway 和 Account 必须配置 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE`。JSON 引用每个进程自己的 Ed25519 签名密钥、TLS 私钥/证书、私有 CA 和明确的 service/host/shard 信任映射；不能用集群加入成功代替授权。传输使用 TLS 1.3，证书 DNS 名及服务签名同时校验。

同进程调用可使用托管 Node 私有注入的本地入口，其身份绑定该次 Host incarnation、物理 endpoint 和 generation。首次会话仍验证签名 Hello/Grant；随后使用不可序列化、调用方不能构造的 Host capability，省去每次调用的签名、验签和 JSON 解码。权限、principal、session 期限、重放、shard、完整 activation token、调用期限及真实完成追踪仍与远端共用检查。请求和响应按原 JSON 编码规则各测量一次字节数，调用方与 Host 分别检查自身上限；远端继续使用签名包。旧入口关闭后拒绝新请求，已派发请求在真正完成前仍占用排空责任。

Gateway 根据配置中的 hostID 选择托管房间或仅调用远端房间；Account 强制 caller-only。承担房间维护/审核 worker 的 caller 需要显式相应服务权限。Operator 继续独立工作流控制，不创建空置 Host。

本地/测试配置生成示例：

```sh
python3 IMV2/scripts/prepare_v2_room_actor_configuration.py \
  --output-dir /tmp/imv2-room-topology \
  --host actor-host=actor-host:7337 \
  --caller gateway=gateway:7337 --worker-caller gateway \
  --caller account=account:7338 --shards rooms-primary \
  --mount-root /run/im-v2-room-actor
```

每个容器只挂载自己的 node 子目录。CA 私钥不挂入服务，已有输出目录不会被覆盖。默认本地启动脚本会创建并保留自己的 Host/caller 身份；此生成器的自签 CA 用于隔离验证，正式部署通过现有 secret provisioning 提供材料。

新库使用 `im-v2-current-53` canonical schema；不提供混合 schema 或历史在线迁移。所有重建和故障脚本只针对显式可丢弃实例。

## 观测与验证

私有 metrics 入口导出 `im_v2_room_actor_*` 固定维度指标：本地 active/pending/restoring/retiring rooms、激活等待者、命令许可当前数/字节及进程峰值、reservation，以及 Directory 的缓存/解析状态。outstanding 包括排队、执行和等待核对的命令，不能解释成纯等待队列；caller-only 节点省略 Host 指标，缺少观测不能当作零。send/receipt 的既有 batch 指标汇总实际物理 owner。

[验证证据](virtual-actor/README.md)区分真实 PostgreSQL、独立进程与 Linux 应用栈。故障入口与具体断言见[故障验证说明](virtual-actor/v1-fault-harness.md)；相对性能配置与尚未完成的测量见[基线协议](virtual-actor/v1-baseline-protocol.md)。

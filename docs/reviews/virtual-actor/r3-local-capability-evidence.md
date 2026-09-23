# R3 同进程 Room Actor capability：实现与验证证据

初版实现基线为 `b23c341e`，其最终源码提交为 `81f67996bc1bca8ee1639454fbc91d72792f47c5`。生产实现从 `c2214c1c` 到 `81f67996` 没有变化；这段提交之间仅补充和收紧测试。初版改动限于 `IMV2ActorCluster`，共 6 个实现文件和 3 个测试文件，未改 manifest、业务执行器、Directory 路由或 SQL fence。后续仅限本机的缓存调用改动单独记录于文末。

| 实现文件 | 边界 |
| --- | --- |
| `IMV2Server/Sources/IMV2ActorCluster/Authentication/V2ActorLocalPayload.swift` | 不可由调用者指定 byte count 的类型化、sorted-key JSON 长度测量；请求和回执各编码一次。 |
| `IMV2Server/Sources/IMV2ActorCluster/Authentication/V2ActorSessionAuthenticator.swift` | 本地 capability 仅在签名 Hello 验证及 session admission 后发行；绑定 authenticator issuer、session、service、caller incarnation、Host identity 和 Node generation。本地调用复用远端的 principal/permission、replay、session expiry 和 deadline 校验。 |
| `IMV2Server/Sources/IMV2ActorCluster/Authentication/V2ActorTrust.swift` | 本地回执复用 session/sequence/attempt/Host correlation，另校验 caller 自身 reply byte 上限。远端签名回执验证保持原路径。 |
| `IMV2Server/Sources/IMV2ActorCluster/Hosting/V2RoomClusterEndpoint.swift` | 本地和远端调用共用 shard、service shard access、bound token、Host 身份及业务 dispatch；Host 独立检查 request/reply byte 上限。 |
| `IMV2Server/Sources/IMV2ActorCluster/Lifecycle/V2RoomClusterNode.swift` | Node 私有创建只属于当次 Host incarnation、endpoint 和随机 generation 的 local port；停止时撤销。 |
| `IMV2Server/Sources/IMV2ActorCluster/Transport/V2RoomClusterClient.swift` | 仅 exact descriptor 匹配且已取得 capability 时走本地路径；首次 Hello/Grant 仍签名并验证。本地跳过逐 RPC 签验及解码，但沿用 `boundedDispatch` 的超时、取消后真实完成跟踪和 unknown 映射；远端仍走 `SignedPacket`。 |

`V2ActorLocalCapability` 不实现 `Codable`，构造器仅限发行它的 authenticator 文件；`V2RoomLocalPort` 的构造器仅限 Node 文件。它们均非 Cluster membership 所授予的权限。Host 和 caller 分别执行各自的请求与回执大小限制；Host 在业务 dispatch 后发现回执过大时，caller 得到 `outcomeUnknown`，不会误报回滚或未接纳。

测试文件：

- `IMV2Server/Tests/IMV2ActorClusterTests/V2ActorAuthenticationTests.swift`：坏签名 Hello、跨 issuer capability、共享权限/replay/expiry、canonical 请求大小和回执绑定。
- `IMV2Server/Tests/IMV2ActorClusterTests/V2RoomClusterBridgeTests.swift`：本地入站的 generation、shard、bound-token 门禁，并保留原签名包路径测试。
- `IMV2Server/Tests/IMV2ActorClusterTests/V2RoomLocalCapabilityIntegrationTests.swift`：真实 Node/ClusterSystem TLS fixture 的本地激活与调用、caller/Host 双侧 request 限额、Host reply 限额、超时后的在途任务与 stop/drain、旧 descriptor 在途完成及新 incarnation 拒绝。fixture 在成功或失败时打开执行屏障、等待 Node 停止并删除临时证书。

原生验证使用独立缓存，无 PG 或 Docker。`IMV2Server/Package.resolved` SHA-256 为 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`，验证期间未变。

```sh
swift test --package-path IMV2Server \
  --scratch-path /Users/yyl/.codex/virtual-actor-builds/p0/credit-fence-native/.build \
  --disable-automatic-resolution -j 2 --no-parallel \
  --filter 'V2ActorAuthenticationTests|V2RoomClusterBridgeTests|V2RoomLocalCapabilityIntegrationTests'
```

在 `210b698d` 上，上述命令退出码 0，**27 tests / 3 suites passed**；完整日志为 `/Users/yyl/.codex/virtual-actor-builds/local-capability-native/targeted-210b698d.log`。最终 `81f67996` 将替换 Host 的断言收紧为实际观察到的 `V2ActorAuthenticationError.wrongRecipient`，并仅重跑受影响的 suite：

```sh
swift test --package-path IMV2Server \
  --scratch-path /Users/yyl/.codex/virtual-actor-builds/p0/credit-fence-native/.build \
  --disable-automatic-resolution -j 2 --no-parallel \
  --filter 'V2RoomLocalCapabilityIntegrationTests'
```

该命令退出码 0，**6 tests / 1 suite passed**；日志为 `/Users/yyl/.codex/virtual-actor-builds/local-capability-native/local-81f67996.log`。诊断单项的实际错误类型和值保存在 `replacement-diagnostic.log`（同一日志目录）。两次通过属于不同提交和不同测试范围，不能合称最终提交的一次 27 项运行。

首轮 `targeted-c2214c1c.log` 保留了 25 项中的 5 个 fixture 失败：4 项 runtime 容量关系配置无效，1 项测试 byte 上限小于普通编码请求；修正的是测试夹具，不是生产限额。中间的 `targeted-cf8acccf.log`、`targeted-6b62da91.log` 保留了替换拒绝错误类型与在途断言观测方式的修正过程。以上日志均位于 `/Users/yyl/.codex/virtual-actor-builds/local-capability-native/`。

随后，冻结源码 `d56232592b05c94d6e933534a985159ec14ff673` 的[一次完整 Linux required run](g5-linux-regression-evidence.md)执行了 ActorCluster **32 tests / 5 suites**，其中本文件的 Node-minted local capability suite 六项均实际 started/passed。该 run 的 suite/cleanup 退出 0；原 metadata 的 parser 误报与原日志的独立重校验见链接记录。`c2214c1c` 的七产品 Linux Release 构建也已通过，且与 `d5623259` 的业务源码、Package/lock 与 SQL 路径零差异；构建来源和核对范围亦见链接记录。这些是正确性及构建证据，不是新鲜 hot 性能候选通过；正式相对性能仍待独立验收。

之后 `c2214c1c` 的[正式 hot 125/s 对比](g5-hot-performance-regression.md)完成 main 01 与 candidate 02：两次 runner 的业务和 formal-eligibility 检查通过，候选 52,500 ACK 与持久效果一致、零业务错误，SQL 24.109013 calls/ACK 低于冻结 24.775092；但 Gateway CPU 2.318060773 ms/ACK 超过冻结 2.13304732，外层 assessor 失败并停止后四轮。相比先前 `fdf6838e` 候选的 2.762828 ms/ACK 约降 16.1%，不能据此认定本 capability 解释了全部降幅或已通过性能门禁。[新的候选独立 CPU 采样](g5-hot-cpu-profile-evidence.md#later-c2214c1c-candidate-only-diagnostic)已完成，显示 JSON、SQL/NIO 和少量正则调用栈，但短窗口、未解析样本及缺少同期 main 对照使其无法完整归因超额 CPU；上面的 Linux 正确性结论不变。

## 仅限本机的缓存调用

后续优化针对已缓存房间每次调用仍执行 `lookup` 和 `invoke` 两次 RPC 的路径。`RoomRef.call` 仅对只读请求，或有稳定操作 ID 的持久幂等请求，尝试复用已确认的本机缓存。公开 `resolve`、预约和 grouped read 仍要求物理确认；远端及默认 transport 也保持原 lookup 路径。每次共享寻址任务仍读取 authoritative owner，优化不缓存 owner 数据库判断。

Directory 沿用原 Pending 队列、single-flight、房间/节点等待者限额、并发 resolution 限额、绝对期限及 quiesce 跟踪。共享 Pending 的严格确认要求只能提升，严格等待者取消后也不会降低；本机条件查询暂停后及完成等待者前都复核缓存与严格要求。未确认结果只带私有来源标记返回给本次调用，不作为新定位结果写入公共缓存。

Cluster 的本机条件要求当前 descriptor 与私有 local port 精确匹配，会话在有效期及安全余量内，capability 的 Host、generation、session、service、caller incarnation 全部匹配，并且存在该 token 的物理引用。`invokeCachedLocally` 在入口及被跟踪的实际 dispatch 前再次检查这些条件；失效时明确返回尚未接纳，不允许改走远端签名包。实际执行继续通过原 authenticated payload、双侧 byte 上限、session/replay/principal、Host readiness/token/epoch 和 SQL fence。首次签名 Hello/Grant 及远端认证路径保持原实现。

重定位与未知结果处理仍调用原 `retryAction`，保留同一请求、操作 ID 和绝对期限；不扩大自动重试集合。生产改动仅位于 `V2RoomDirectory.swift` 和 `V2RoomClusterClient.swift`。实现提交为 `c6da9aba18e0f0bb320cd6ddf558793442be6367`，集成为 `e4adc7ce87c61e4b078a38151d21dcac69b938d0`；两者的 Server source/tests、manifest 和 lockfile 零差异。

最终原生验证命令在 `IMV2Server` 下执行：

```sh
swift test -j 2 --no-parallel --disable-automatic-resolution \
  --build-path /Users/yyl/.codex/virtual-actor-builds/p0/credit-fence-native/.build \
  --filter 'IMV2ActorRuntimeTests|IMV2ActorClusterTests'
```

退出码 0，Runtime **58 tests / 5 suites**、Cluster **35 tests / 5 suites** 全部通过。完整日志 `/Users/yyl/.codex/virtual-actor-builds/p0/local-cached-invoke/runtime-cluster-full-final.log` 的 SHA-256 为 `002b3e4c3a5bfc2b4adafc1c8055d97a84aab649a7be4ec58c29d73c8b154537`。Directory 的 16 项及 local capability 的 9 项均独立核对到 started/passed，不是只依赖总计。依赖锁仍为 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`，被测提交工作树干净。

新增证据覆盖暖调用省略 lookup、公开 resolve/grouped read 仍确认、严格等待者取消不降级、predicate 暂停期间缓存替换、相同操作重定位、hinted unknown 的稳定 ID 重试及 no-auto-retry 的严格确认与不重放。真实 Node/Cluster fixture 覆盖 TTL 过期后重新认证定位、物理引用逐出后 lookup 恢复，以及本机 predicate 返回 true 后替换 descriptor 的竞态：首次本机派发只接受 `notAccepted(unavailable)` 或 `notAccepted(staleActivation)`，Host 执行零次，原 retry 路径重新读取 owner。local-only 超时调用继续被 drain 跟踪；远端 caller 明确拒绝本机 hint。

前面的编译错误日志和 `runtime-cluster-full-2.log` 保留。后者 Runtime 58 项通过、Cluster 35 项中 1 项断言失败：旧 descriptor 已删除时原前置 guard 返回 `notAccepted(unavailable)`，测试最初只接受 `staleActivation`。修正仅扩大到这两个确定未接纳的原有错误，仍拒绝 unknown；最终全套运行通过。此次未改持久层、未新增 PG 测试，也未用原生结果替代 Linux 验证。

干净 detached 候选 `fb8a10478895f4b2d616f4bf7eb11eed51a84824` 位于 `/Users/yyl/.codex/worktrees/virtual-actor-candidate-cached-local/IMMonorepo`；其 Server source/tests、manifest 和 lock 与上述被测实现一致。七产品 Linux Release 构建全部通过，产物记录 `/Users/yyl/.codex/virtual-actor-builds/candidate-release-cached-local-fb8a1047/result.json` 报 `passed=true`、`exitCode=0`，SHA-256 `7363560d26783b94aa4eb4398a24731ef312a51b461bd1742d209429fb86705b`。固定 Swift 6.4 Jammy 镜像及依赖锁不变，七个 ELF 与记录哈希独立核对一致；Gateway ELF SHA-256 为 `6e336cd3860777977789fa960770907e5b52efeda52e1ad154857ce091a5900d`。构建脚本 `build-candidate-cached-local-fb8a1047.py` 的 SHA-256 为 `8193f18c6496e97d2f954379b22101c64570ae99b163821f4956b09221a90a23`，均在同一外部 builds 目录，构建容器已移除。

新鲜 hot 驱动 `run-hot-cached-local-campaign.py` 的 SHA-256 为 `df98f5d34da76c2b0a042396a84ae288655f31a83e6fcb20820827992c4ac64d`；输入检查通过后，正式 `main/candidate/candidate/main/main/candidate` 对比已开始。原 freeze、common loader、harness、100 连接、125 send/s、120/300/60 秒阶段及逐轮失败即停均保持不变。当前尚无这版候选的正式性能结果；最终完整 Linux required run 和其他四类负载亦未执行，不能由 Release 构建推断它们通过。

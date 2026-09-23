# R3 同进程 Room Actor capability：实现与验证证据

实现基线为 `b23c341e`，本分支最终源码提交为 `81f67996bc1bca8ee1639454fbc91d72792f47c5`。生产实现从 `c2214c1c` 到 `81f67996` 没有变化；后续提交仅补充和收紧测试。改动限于 `IMV2ActorCluster`，共 6 个实现文件和 3 个测试文件，未改 manifest、业务执行器、Directory 路由或 SQL fence。

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

本记录不代表 Linux 完整 gate 或新鲜 hot 性能候选通过；两者仍需在最终冻结源码上另行执行和记录。

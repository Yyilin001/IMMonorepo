# B08/B09 认证生命周期实施合同

后续状态更新：B09 已完成[真实 App 与 TLS Gateway 认证终止验收](app-gateway-authentication-termination.md)，修复握手拒绝退化为 EOF 的实际缺陷，现标为已验证。下文保留本批当时的范围与未覆盖记录；B08 完整退出/换号仍开放。

本记录覆盖当前进程内凭据所有权修复。完整退出 checkpoint、跨重启 epoch、服务端专用撤销 capability 与真实账号服务/冷启动组合验收尚未完成；不能把下列测试当作 B08/B09 已关闭。

## 已实施的边界

- `V2AuthSessionEpoch` 是不含凭据的进程内 owner UUID + generation。它不同于服务端 session epoch，也不是持久化的退出记录。开始新的账号认证意图或终止/失效旧工作会改变 generation。
- `beginEstablishment` 在 account provider 网络请求之前预留本次意图。后开始的认证或 logout fence 会让旧 provider 结果失效。`establish(..., ifCurrent:)` 才可提交该意图的凭据；bootstrap 在 provider 返回、finalizer 返回及打开主库之后核对代次。
- `credentialIO` 将真实 Keychain/store 的 load/save/delete 串行排队。旧 save 已经进入存储时不会因检查代次而被魔法撤销：它先结束，然后新 save/delete 执行；旧操作结束后也不能更新新会话的内存状态。只在 await 前后比较 generation 不足以保证磁盘最终顺序，因此不能移除这条实际 IO 顺序。
- 本地 restore/load 单飞，refresh 保持原持久 operation ID 和单飞。网络请求不持有全局凭据 IO 队列；单个调用者取消不会取消所有共享刷新调用者。
- coherentCredentials 在 await refresh 后再核对 epoch。TLS credentials 带进程内 epoch，成功结果不接受已经换号的凭据归属；终止拒绝要求匹配对应 epoch 和实际被拒绝的 access token。存在进行中的 refresh 或 token 已更新时，旧握手拒绝不删除后继凭据。
- terminal deletion 开始后立即清空可用的内存凭据；若 Keychain 锁定导致删除失败，内存保持 pendingTerminalDeletion。解锁后只重试删除，不重新读取并使用已经被终止的旧凭据。这个标记目前仅在进程内，不能替代持久退出 checkpoint。
- App 先持久化现有 pending logout intent，再 invalidateOutstandingWork，使迟到 account provider/refresh 不能复活旧认证。当前正常网络删除及 Keychain 删除顺序仍属于旧退出流程，需要后续补充网络期限和专用撤销能力。

## 仍需完成

1. 将现有布尔 pending-credential-deletion 升级为绑定旧 user/device/session epoch、阶段和独立撤销能力的持久检查点；严格区分本地完成和远端撤销未确认。当前进程内 generation 不提供跨重启保证。
2. 退出网络路径必须有总截止时间，离线不能无限阻塞重新登录。服务端提供仅可撤销旧 session 的 capability，按既定方案覆盖该 session 的剩余寿命，并在撤销事务同时失效 Push 资格。不能无限保留普通 access/refresh token，也不能使用新 B 的凭据补偿旧 A 的撤销。
3. 认证状态快照和 App Router 观察已接入（见下节）；仍需带真实账号服务的路由/退出/冷启动组合验收，并审查不经 refresh 的 HTTP 终止拒绝入口，不能以观察器单元测试代替所有端到端路径。
4. 账号 provider/finalizer、Keychain、数据库 scope 和媒体任务需要完整生命周期协作。当前 bootstrap 能拒绝迟到返回，但在最后一次检查之前已打开的旧数据库对象及 finalizer 的持久操作仍需按完整账号 epoch 管理，不能简单按 userID 关闭后来会话。
5. 真实 kill/relaunch、每个 logout 检查点处锁屏/终止、A→B→A、离线撤销和 token 轮换仍要端到端验证。现有可控 actor/store 测试证明进程内次序，不代表真实 Keychain 进程终止边界已覆盖。

## 本轮验证

- `V2AuthSessionEpochTests`：旧 load、pending refresh save、successor save、delete 四种实际 store await 被挂起时，新登录最终留在磁盘；旧请求返回 sessionInvalidated，重新创建 auth owner 读取到新账号。
- 覆盖并发 restore 一次实际读取、terminal delete 暂不可用后只重试删除、后开始的账号意图胜出、logout fence 拒绝迟到建立、旧 TLS 拒绝不删除新账号，以及同账号刷新后的旧 token 拒绝不删除新 token。
- `V2ClientSessionBootstrapperTests` 通过真实 bootstrap 路径挂起 A provider，先完成 B 登录，再释放 A；B 的凭据及 scoped store 保持不变。
- 最终客户端 271 tests / 47 suites 通过，日志 `/private/tmp/im-remediation-auth-epoch-client-verified.log`。App iPhone 17 / iOS 26.2 全量 129 tests / 12 suites 通过，日志 `/private/tmp/im-remediation-auth-epoch-app-verified.log`。
- `git diff --check` 与当前协议文档门禁通过。没有修改服务端认证协议或部署配置，B08/B09 继续实施中。

## 已接入的 B09 认证状态观察

- `V2AuthSessionSnapshot` 提供无凭据的完整状态：active、ending、ended。每个 stream 绑定一个不可变 epoch，bufferingNewest(1)；结束时保留该 epoch 最终值并结束 stream，新账号状态不会覆盖尚未消费的旧终止值。迟到订阅可得到已结束/待删除/已替换状态，不会永远停在 ending。
- 普通状态变化发布给该 epoch 的订阅者。terminal deletion 完成后发送 authenticationRequired；Keychain 删除暂不可用发送 credentialDeletionPending；账号替换发送 superseded。新的 epoch 不能通过旧事件删掉当前凭据。
- App `V2AuthenticationStateObserver` 拥有一个订阅任务和 observation UUID，重新绑定时取消旧任务；已经排队的旧结果不能调用新处理器。独立 HTTP/后台操作所触发的 refresh 终止也会到达该观察器，不再仅依赖 realtime connect 的 catch。
- App 激活时用真实 coherent credentials 中的 epoch 绑定观察器。路由处理先占有退出 gate、推进 UI 尝试代次并隐藏旧账号视图，再停止 runtime/indexer、关闭捕获的 store。authenticationRequired/superseded 只结束旧本地展示，不再次删除“当前”凭据；protectedDataUnavailable 进入解锁恢复；terminal deletion pending 记录现有退出标记后进入待删除状态。
- `requireAuthenticatedEpoch` 供 restore/激活对已结论的旧 epoch 做错误分类；命令终止操作仍用更严格的 current epoch/token 检查。主库打开期间凭据失效映射 authenticationRequired；临时凭据不可用保持独立分类。App 在会话首次刷新之后再次检查 UI 代次，避免已结束的激活继续启动 Push/实时工作。

## 观察接线后的验证

- ClientKit 验证慢消费者跨新登录仍得到旧 epoch 的终止值、晚订阅得到已完成的删除待恢复状态，以及主库打开期间发生 revocation 仍返回 authenticationRequired。
- App 新 suite 4 项直接驱动真实 V2AuthSession 与生产观察器：非 realtime 刷新终止、临时 Keychain 错误与恢复、旧观察任务排队后替换、终止删除失败的独立路由变化。
- 最终客户端 274 tests / 47 suites，日志 `/private/tmp/im-remediation-auth-observation-client-final.log`；App iPhone 17 / iOS 26.2 全量 133 tests / 13 suites，日志 `/private/tmp/im-remediation-auth-observation-app-final.log`。
- B09 状态为“已实现待验证”：上述证据覆盖生产观察组件、接线编译和现有回归，尚不是带真实账户服务的完整 App restore/logout/kill/relaunch 验收。B08 的持久 checkpoint、远端专用撤销和离线期限继续实施中。

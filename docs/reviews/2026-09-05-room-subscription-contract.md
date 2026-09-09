# B17 房间订阅实施合同

目标是[47 项修复方案](2026-09-05-system-remediation-plan.md)中的完整 B17：页面不离开也能在新连接恢复实时更新、多 scene 共用订阅、旧取消不撤销新意图、退群/关页面后收敛。本文记录已接入的 App/runtime 路径及验证边界；真机网络切换和生产证书另由 E01/E04 验收。

## 当前组件

- `V2RoomSubscriptionCoordinator` 由账号/runtime 拥有，保存 room → consumer UUID → channel set。channel 为 roomEvents、typing、presence，实际 wire 订阅取存活 token 的并集。默认最多 128 个 room、512 个 consumer；最后一个 token 离开才撤订。onTermination 和显式 release 使用同一个 token，重复释放无效果。
- 每代运行拥有唯一内部 run UUID，并接收实际 TLS connection UUID。新 run 会取消、等待旧 run 排空，再启动单一 group hint consumer、activity consumer、reconcile worker 和全局 refresh clock。desired tokens 留存；confirmed subscriptions、typing、presence、wake 都在连接切换时清空。
- reconcile 顺序串行，失败保留意图并使用单个 retry clock，默认 1 秒；默认 30 秒全局 clock 请求授权复核并刷新 room recovery ID，不建立每房间的周期 timer。初次 room subscribe 从传入的 durable/preview cursor 发起，返回 high watermark 和新的 recovery ID，让消费者补拉订阅间隙。
- 本地授权失效使 desired wire set 为空，进行取消；server FORBIDDEN 暂停该 room 的意图，并清空瞬态显示。`authorityDidChange()` 由个人同步完成后调用以重新评估权限；普通 wake 不自动解除 server revoked。退出的 consumer 条目和已经清空的 room 会释放。
- 每个 consumer 收到不可变 `V2RoomSubscriptionSnapshot`，包含 connection ID、offline/reconciling/subscribed/revoked、recovery ID、按 channels 过滤的 room wake、presence、typing。使用 bufferingNewest(1)，且相同 snapshot 不重复发布；完整替换值保证慢 consumer 漏掉中间 offline 更新后，仍能凭新代快照清除旧 lease。typing 状态最多 64 个用户，发布时清理过期条目，presence 过期不再发布。
- room live hints 优先合并有界连续 payload。长期保留的 snapshot 与尚未消费的 socket buffer 不同：合并因旧 metadata/满 batch 丢失正文时，snapshot 保留最新 batch；消费者仍须检查 durable cursor，发现缺口再拉取。不引入第二套内容投影，也不把 hint 当 durable cursor。

## 请求代次必须在 socket 边界验证

只在 coordinator 发起 `unsubscribe` 前比较 run ID 不够：在跨 actor await 后，实际 request 仍可能到达替换后的 socket。因此 TLS 握手结果现在带可选 connection UUID（真实 TLS 必有，既有纯单元 fake 默认为 nil）。`V2ConnectionRequestScope` 通过 TaskLocal 将该 UUID 传到已有 domain transport actor，保留原共享 request ID 分配器；TLS 在注册请求与等待提示的边界核对它。旧 scope 返回 connectionClosed，不把请求放到新 socket，也不关闭新 socket。

不要为每个 scene 或每次 reconnect 随意创建新的 `V2ProtobufSyncTransport` 实例来绑定连接：每个实例都会从自己的初始 request ID 开始，可能与当前普通命令 transport 冲突。共享 domain transport + wire 时的代次核对是当前选定的实现。

## 已接入的 App 路径

1. runtime 在实际认证与初始同步完成后，将 session.connectionID 传给 owned roomSubscriptionTask。停止、后台或任一循环失败均取消任务；coordinator 新 run 排空旧 run 后重建订阅。生产 composition 传入 localStore 授权和 durable/preview cursor，个人同步完成后调用 authorityDidChange。
2. activity 页面拥有独立 token，消费完整替换快照。connection ID/offline/revoked 变化清空旧 typing/presence lease，presence 另有严格 expiresAt。页面结束释放自己的 token；最后一个同 channel consumer 离开后才撤销共享 wire subscription。
3. 群页面通过 view-owned `V2ScopedActiveRoomSynchronizer` 保留现有 live payload 加速、100 ms metadata grace、cursor gap 检查和 durable fallback。取消一次 nextWake 仅取消该 waiter，不终止 lease stream；关闭页面才取消并排空 snapshot pump 和释放 token。
4. 生产移除每页面的 30 秒周期 timer，使用 coordinator 单一 refresh clock 和 recovery ID；100 ms grace 是仅在 metadata 恢复时建立的有限等待。新 recovery ID 剥离旧 live payload，使周期修复真正进入补拉；新 payload 在 grace 内到达且符合游标连续性时仍可加速。
5. 本地权限暂缺/退群时保留页面意图，暂停同步；权威恢复后重新订阅和唤醒。旧代 wake 在进入原落盘适配器前拒绝，原适配器继续检查授权与 cursor。B03/B06 的 mutation 历史受众及双流事务一致性仍分别开放。
6. 发送方 typing 捕获当前 consumer token 和 connection ID；coordinator 校验 token、已确认 channel 和连接身份，再通过 TaskLocal 传到 socket 注册边界。重连取消旧续租，不主动重放输入状态；下一次实际输入建立新续租。该接口没有把 typing 变成持久消息或重试队列。

## 已有验证范围

- 两 scene 仅订阅一次，第一 token 释放不撤订，最后 token 释放才取消。
- 页面 token 保留时，顺序与重叠的新旧 run 都重建订阅、清空旧 typing/presence，并产生新的 recovery ID。
- subscribe 瞬态失败后，无新 hint 也会重试。
- 本地 membership 授权失效后取消 room/typing，权限恢复后重新订阅。
- 旧 token 重复释放不影响替换 token。
- 实际 TLS actor 的旧 TaskLocal connection scope 不能向新 socket 注册 request 或抢占提示 consumer，新代普通 request 仍成功。

初次组件测试触发 Swift 独占访问运行时检查：同一 optional-chain 字典写入表达式在右侧再次读取了 `rooms`。已改为先计算局部 wake/typing 值，再写回；重新执行该范围通过。没有通过关闭独占检查、改变 Swift 模式或放宽测试来绕过错误。

## App 接入后的验证

- 客户端全量 249 tests / 44 suites；日志 `/private/tmp/im-remediation-subscription-client-verified.log`。
- App 全量 129 tests / 12 suites；日志 `/private/tmp/im-remediation-subscription-app-verified.log`，iPhone 17 / iOS 26.2 模拟器。
- App 实际覆盖页面不退出重连、同房间两个页面及另一房间分发、关闭一个页面不影响另一个、grace 超时取消后继续收到 live payload、周期恢复补拉、退群/rejoin 保留意图、旧 payload 代次拒绝、重连清除瞬态并允许新输入。
- 客户端补充迟到 subscribe ACK 与关闭/替换/reconnect 交错、长期 metadata snapshot 不吞后续 payload、旧 typing consumer/connection ID 拒绝，以及 runtime 实际连接身份与 owned task 取消断言。
- 此处验证是本机 App composition/状态机、客户端 actor 和已有真实 TLS wire scope 边界证据；没有把模拟器或回环网络当作签名真机、生产证书、APNs 或长期多节点负载验收。

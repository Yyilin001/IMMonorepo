# D03：后台有界同步、取消及系统回调

D03 保持实施中。本批已将已登录 App 的 Push handler 从完整 runtime 改为专用后台同步；当前仍需实际 Push/真机期限、锁屏、网络悬挂及冷启动组合验收。D02 的共享 delegate 入口与有界恢复现已接入，见[共享启动合同](shared-app-restoration-contract.md)；真实带凭据无 scene Push 仍未验收，不能由此声明系统冷启动 Push 已验证。

## 同步所有权

原来的 `V2SyncEngine` actor 在 pull、SQLite apply、ACK 和 reset 的 await 之间允许重入，仅靠 actor 声明不能证明完整周期串行。现在 `V2SyncOperationGate` 持有完整操作的许可，同一 engine 默认拥有一个 gate；App 的前台/后台个人同步 engine 显式共享它。

排队调用可独立取消，取消只移除自己的 continuation。当前操作继续执行；交出许可后才允许下一个周期读取 cursor 和发送 pull。取消与许可交接竞争时，取得许可的一方先检查取消并释放。持续追赶在页之间释放许可；reset 的完整导入与激活持有同一许可，防另一路个人同步穿插。

测试使用真实 SQLite、两个 engine、明确挂起的首个 pull，以及队列状态确认第二个调用已经排队。取消排队调用后，第一个仍完成；后续调用读取它提交的 token，再按顺序 ACK。每次 pull 返回后、进入本地 apply/reset 前还会检查取消。反向移除此检查后，已取消的迟到 pull 确实推进了 SQLite cursor；恢复后同测试通过。

## 认证等待

后台截止不能无限等待共享刷新。`V2SharedOperation` 只有一个 owner task，各等待方使用可取消 continuation；离开等待不取消共享刷新或 load。认证 session 仍负责完成、保存与代次校验。

load 的清理由 owner 完成时执行，不能因一个等待方取消就清除正在运行的 load、让另一个调用方重复发起。测试确认一个取消的刷新等待在网络仍挂起时就返回，随后同一次 rotation 继续完成并保存，只有一个刷新请求。认证 epoch、HTTP 并发刷新与 coordinator 既有回归也通过。

## 后台工作与结果

`V2BackgroundSyncRunner` 拥有与前台不同的 TLS connection/coordinator。默认工作截止为 25 秒，认证等待、握手、增量页和 ACK 共享一个 ContinuousClock 截止；并发 Push 合并为同一操作。截止、前台恢复或退出时取消本次任务、关闭专用连接并等待排空，不能关闭前台 socket。

默认总预算 4 页。App 每页最多请求 100 条，个人流先使用最多 2 页，剩余预算交给 room-log 有限轮转，避免热个人流耗尽全部预算。room-log 仍按持久目录进度继续；两路都在同一个时间截止内。后台不启动 heartbeat、outbox、索引、媒体或 policy recovery 等完整 runtime 循环。

`synchronizeIncrementally(maximumPages:)` 在页数耗尽时保留已提交 cursor。遇到 reset 会持久化意图并返回，不下载 manifest/page、不执行 snapshot ACK/激活，重型恢复留前台。

`newData` 只在本次操作成功报告新增持久记录时返回。空页不算新增。房间 store 新增原子提交报告，在同一 SQLite 事务内统计实际插入的事件；精确重放返回 0，避免把收到的数组长度误当成提交数量。并发重复页验证恰好得到 1 和 0。发生错误或取消时不依据猜测报告新增；已进入事务的原子提交不能被假定为可撤销。

## App 生命周期

Push handler 调用后台 runner 并映射结果，不再启动完整 runtime 或刷新整个会话列表。数据库观察继续通知可见页面。进入前台时停止并排空后台 owner 后再启动前台 runtime；退出时先停止后台工作，再关闭本地 store。

认证终止已由 coordinator 通知认证 owner，现有观察者负责 UI/退出清理；Push handler 不再额外 await 一次完整 signOut，以免超出同步预算后又追加网络或磁盘工作。旧的共享前台 runtime 停止判定 helper 及其纯布尔测试已移除，改由独立连接所有权与排空测试验证。

## 验证边界与剩余工作

测试覆盖 4+2 页续传、reset 延后、空页、迟到取消、排队取消、后台超时关闭并排空、超时不取消前台 owner、停止后重启、两种事件流共用 4 页，以及真实 SQLite 精确提交计数。完整客户端与 App 单元回归和既有真实认证/冷启动 UI 回归用于检查集成后的回归风险，精确日志与源文件哈希见 [manifest](evidence/20260906-bounded-incremental-sync/manifest.json)。

25 秒是工作截止，当前收尾依赖受拥有连接的取消和任务排空；尚未证明在真机所有情形下都能于额外 5 秒内结束。真实 APNs、系统挂起/首次解锁前、实际网络悬挂与长事务、前后台交错下的 completion 时间仍需测量。现有真实认证 UI 用例没有注入 Push，不能充当这些验收。无可见 scene 的会话恢复仍按 D02 跟踪。

## 真实网络期限补验

真实 `NWConnection` 回环测试分别挂起 TLS 协商、Hello、认证、SyncPull 和 SyncAck，使用 1 秒工作预算，断言返回总耗时小于 5 秒、对端连接已关闭且凭据仍保留。TLS 场景使用生产 TLS 配置，TCP 对端接收 ClientHello 后不回应；它不验证证书成功握手。其余四个阶段用 TCP 隔离协议阶段，经过生产字节适配器、协调器、protobuf 传输及真实 SQLite。恢复服务端响应后重新连接并完成同步；ACK 超时保留 applied=1、acknowledged=0，重连后 acknowledged=1，精确重放不报告新增。

此轮定向 1 项参数化测试 / 5 个场景通过（1.104 秒）；客户端完整回归报告 406 项 / 63 套件（4.501 秒），其中实际执行 402 项、4 项在线测试按既有条件跳过。本轮只新增测试，未改生产实现，也未重新运行 App 单元或真实 App UI；此前 App 结果只作为历史证据。日志、运行脚本与源码哈希见[网络期限证据](evidence/20260906-background-network-deadlines/manifest.json)。

以上补齐本机网络挂起的验证；实际 Push、真机锁屏、首次解锁、长事务和前后台交错时的系统回调仍未验收。D03 保持实施中。

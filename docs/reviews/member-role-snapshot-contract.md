# B06 成员角色与恢复版本

更新：2026-09-19。B06 保持实施中。本页区分当前房间日志实现与原先的个人公共投影路径。

## 当前事实来源

公共成员变化和角色变化写入房间日志；只有受影响用户收到个人 membership 状态。`V2UserStateEventKind` 不包含 group_capability，服务端个人投影工作器拒绝公共角色内容。因此旧 fanout 逆序分发回归只能作为历史证据，不能作为当前双流生产合同。

客户端本人资格由 `v2_room_membership_states` 保存修订、来源和撤销状态，成员事件来源和修订由 `v2_member_effects` 保存，`v2_group_member_roles` 按 room/user 保存最新派生角色。本人退出时清理房间投影；重新授予会安排持久恢复。其他成员的角色不能使用本人的资格版本或房间最后一次资料修订作为其版本。

## 已修复：较新本人状态与较早成员移除

个人流可能先送达较新的本人加入/重入状态，随后房间日志补拉较早但仍可授权读取的成员历史。原实现先比较房间资料修订，较早的 membership 记录直接返回，连带跳过其他成员角色的删除；管理员角色残留且重开数据库后仍存在。

`applyMembershipAwareRoomProjection` 现在先核对本人资格，再独立应用目标成员的移除效果，最后决定是否更新房间资料：

- 只删除该 room/target 且 `membership_revision <= 移除修订` 的角色行。
- 较新的目标角色保留，不能被较旧的 remove 清除。
- 较新的本人/房间资料不回退，但不再阻止目标成员角色的删除。
- 上述第一阶段修复没有增加表；后续持久版本实现仍保持成员效果、房间事件与游标同事务。

## 角色载荷与身份边界

成员角色载荷的房间和成员 UUID 在校验后以规范形式保存。不能校验强类型后继续使用原始字符串作为 SQLite 键，否则大小写差异会绕过删除匹配，或使快照按房间关联时漏掉角色。

房间日志中的角色事件必须匹配外层房间，显式 `room_sequence` 必须匹配外层序号；载荷没有序号时使用已校验的房间信封。修订与显式序号必须为正 Int64 范围。角色变更只允许 admin/member，与服务端不允许改为 owner 的合同一致。

同目标较低修订不覆盖较高修订；同修订不同角色或不同已知来源房间序号被拒绝，整页事务回滚、角色和游标保持原值。相同内容的重复记录不改写原序号。来源身份与撤销事实由下面的持久成员记录补齐；这仍不等同完整裁剪与重入基线已验收。

## 证据与剩余范围

[V2MemberRoleRecoveryTests](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2MemberRoleRecoveryTests.swift) 覆盖本人资料较新/较旧与目标角色较新/较旧的四种组合，执行真实房间页落库、个人快照导入/激活、关闭及重开。修复前角色删除和重开两处断言失败；修复后连同本人资格、快照及持久恢复专项共 26 项 / 3 套件通过。详情见[移除证据](verification-records.md#20260919-member-role-profile)。角色身份补充覆盖大小写混合、跨房间、来源序号、非法角色和同版本冲突，修复前18处断言失败，修复后连同相邻恢复与快照专项共29项/3套件通过，见[身份边界证据](verification-records.md#20260919-member-role-identity)。

## 持久成员记录与快照合并

本地 SQLite 新增 `v2_member_effects`，以来源事件为主键，同时约束 room/user/revision 唯一；保存 add/remove/role、可选角色、规范摘要及可选来源房间序号。摘要绑定规范房间、目标成员、修订、动作/角色、发起者和来源时间，不把个人游标、快照观察者状态或房间展示资料当成成员版本。

- 三种事件共用 reducer。逐成员最高修订决定当前角色；remove 和 add 均清除较旧角色（重新加入不继承先前管理员身份），更高修订的角色可重新建立。
- 较旧事件保留来源证据但不回退显示状态；同修订另一来源、同来源不同摘要或不同已知房间序号使事务失败。
- 房间日志的 membership 也核对外层房间和显式房间序号；个人序号不充当来源房间序号。`projection_sequence` 仅保留既有角色投影缺省序号，不用于来源身份比较。
- 个人快照切换保留仍授权房间的成员来源历史，先拒绝来源冲突，再合并记录、补齐已知房间序号，并从逐成员最高版本重建角色。快照中的旧角色不能覆盖已知移除。
- 本人被移除时，清除该房间的成员来源与角色；独立的本人资格撤销记录继续保留。新表进入快照影子库、原子切换和清理列表。

新表属于当前全新数据库基线，没有新增旧 schema 迁移，也没有修改 PostgreSQL schema 或协议。规范表结构检查增加来源记录字段约束。专项与进程中断证据见[持久版本记录](verification-records.md#20260919-member-ledger)。

## 当前成员名录与页面失效

当前 App 成员列表和发起者管理角色来自 `V2RealtimeGroupMemberDirectory` → `listRoomMembers` → `V2RoutedRoomMembershipDirectoryStore`。服务端按当前成员修订读取权威成员关系，每页重复返回发起者角色，游标绑定房间和修订；此查询不依赖房间事件仍被保留。`v2_group_member_roles` 不是完整成员名录，不能把房间日志投影当作首次安装后的全量名单，也不应因此为每台设备新增全量名录扇出。

本轮修复 `V2ConversationDetailStore.loadGroupMembers`：

- 主动刷新、已确认成员版本/角色变化、FORBIDDEN/NOT_FOUND 后，立即一起清空名单、发起者角色、成员修订和分页状态；重读失败不再保留过期管理能力。
- 普通分页网络失败未证明旧页失效，可保留已加载页供重试。
- 请求执行期间的刷新意图由原请求任务串行处理，旧响应不发布；重复分页请求仍合并，不增加并行请求。
- 拒绝重复成员和不推进的游标，避免部分更新和无进展分页。控制库过滤隐藏资料后允许空页带新的后续游标；上一轮将所有带游标空页判无效的假设已纠正。

10项 App 成员目录/变更专项通过，包括6种失效/网络参数及3种异常分页参数，见[页面证据](verification-records.md#20260919-member-directory)。这是注入读取器的 App 状态测试，不等同生产名录裁剪或跨分片实测。

成员名录由房间 Actor 提供：[房间查询执行器](../../IMV2Server/Sources/IMV2ServerInfrastructure/Room/Queries/V2ActorRoomQueryExecutor.swift)在激活围栏读事务内调用 [`PostgresV2RoomMembershipDirectoryStore.list`](../../IMV2Server/Sources/IMV2ServerInfrastructure/PostgresV2RoomMembershipDirectoryStore.swift)，房间归属由激活租约保证。

2026-09-24：此前由控制面目录选 owner、从控制库批量读取公开身份、再复核 shard/epoch 的成员名录路由实现（`V2RoutedRoomMembershipDirectoryStore` 及 owner 候选分页 API）在生产中已无调用路径，已删除。

[三库专项](verification-records.md#20260919-member-directory-routing)覆盖旧 owner 仍有副本、控制库资料与 owner 旧资料不一致、空日志且裁剪下界为100、迁移后旧游标拒绝、撤销、重新加入以及资料读取期间撤销。9项服务端/数据库测试与11项 App 状态测试通过。这是受控归属切换与读取验证，不是运行中完整 owner 数据搬迁或首次安装 App 整链验收。

B06 仍开放：已知成员事件的持久版本和来源冲突已覆盖；权威名录已不依赖旧角色日志；首次安装/裁剪后的 App 整链、运行中完整 owner 迁移、本人重入跨代次组合、来源历史的保留/清理和容量仍需闭环。本地受控载荷乱序/冲突测试不代表服务端实际产生这种顺序；含公共角色的快照仅验证解析器与保留逻辑的边界，不恢复旧个人公共投影作为生产合同。

本轮已执行相关 App 状态与真实 PostgreSQL 名录专项，未执行 App/TLS 整链、真机或负载验收。历史服务端角色快照回归见[原记录](verification-records.md#20260906-member-role-snapshots)。


## 恢复响应在途时本人撤销

新增确定性交错测试在状态响应或正文页返回之前，经真实个人流 reducer 提交本人 remove（修订 2），随后交付旧资格状态（修订 1）或旧正文页。
前台 run 与后台 runBounded 均收到 staleMembership 并停止；被撤销房间的同步状态、摘要和待办保持清空，正文游标没有前进，成员修订 2 的撤销记录保留。
4 个场景及 25 项运行器回归通过，见[证据](verification-records.md#20260920-membership-inflight-runner)。
该证据使用真实 SQLite 和可控传输替身，未覆盖真实网络响应排序、撤销后的重入或完整 owner 迁移，不关闭 B03/B06/D08。


## 在途恢复遇到撤销后重入

新增状态/正文两个边界的运行器场景：旧资格修订 1 的请求等待返回时，个人流在同一批依次提交 remove（修订 2）与 add（修订 3），生成新 request_revision。
旧响应返回 staleMembership、引擎停止，正文游标仍零；新的成员记录和待办请求修订保留。
随后模拟新连接通知流，目录/状态/摘要替身返回修订 3，有限预算内游标追到 5，持久状态修订为 3，队列清空。
26 项运行器测试通过，见[重入证据](verification-records.md#20260920-rejoin-inflight-runner)。
这里是同一个个人流 generation 的资格修订交错，正文页为空；不覆盖重置代次、缺席期间非空消息可见性、真实 TLS/App 或 owner 迁移。


## 重入交错的非空正文补充

上一节两种在途响应边界现各增加非空正文参数，与原空页参数合计 4 场景。
传输替身先捕获旧资格响应的序号 1 消息，再提交本人撤销/重入并将后续可见响应换为序号 5 的另一条消息；捕获的旧正文响应仍按原内容返回。
旧响应被拒绝后，事件表与消息投影均为空、游标为零；重连恢复后只存在新消息及其一条事件，旧消息不出现，状态修订 3、游标 5、新待办完成。
26 项运行器回归通过，见[非空正文证据](verification-records.md#20260920-rejoin-content-flight)。
这补充客户端对旧响应的拒绝与新响应的落库行为；服务端成员区间过滤由替身预设，不是服务端缺席消息可见性验收，重置代次/真实网络/App/迁移仍开放。


## 正文响应绑定请求捕获的资格

新发现并修复：如果本人退群/重入后，另一个调用已写入修订 3 的有效恢复状态，旧修订 1 的正文响应原先会借用当前状态通过校验，旧消息实际落库。
`requireRoomRecoveryPageAuthorization` 现要求任务已有捕获状态，当前 ownerEpoch/viewerMembershipRevision 与捕获值一致，个人成员栅栏也与捕获值完全一致，然后复核当前资格。
正文任务必须在提交状态后重新读取、再发出请求（运行引擎已有此顺序）。无捕获状态不能提交正文；测试中旧的直接调用方式已同步修正。
不要求 head/read 进度或 request_revision 完全相同，保留同资格下的新通知和并发正文推进；新资格待办不会被旧响应删除。

新增复现使用真实个人流 remove/add，预先提交新状态后交付旧的非空页：修改前 4 个断言失败，修改后旧消息和游标均不落库，新资格空页可继续提交。
另有未捕获状态、owner 变化、仅成员修订变化的拒绝，以及仅 head 前进仍允许的 4 场景。64 项恢复持久化/运行器/整数专项通过，见[证据](verification-records.md#20260920-recovery-body-authorization-fence)。
本轮没有真实 owner 搬迁或 TLS/设备验收，不关闭 B03/B06/D08。


## 重入后旧摘要的独立校验

对上一节真实 remove/add、新状态先提交的复现场景，补充带恢复任务及不带恢复任务的摘要提交入口。
旧摘要携带修订 1 和非空消息预览，在修订 3 的状态下被 latestVisibleIsCurrent 拒绝：缓存未创建，requires_summary 仍为 1。
新资格的空摘要提交后，再交付旧摘要仍被拒绝，新摘要保持不变；旧正文拒绝与新资格正文提交继续通过。
23 项持久化测试通过，见[摘要证据](verification-records.md#20260920-rejoin-summary-fence)。摘要已有自己的响应修订校验，本轮未改生产逻辑；不把正文修复结论直接外推到摘要路径。


## 正文恢复的个人流代次栅栏

即使成员资格/owner 不变，旧正文请求也不能借用快照重置后的任务。新增真实 beginReset/import/prepare/activate 流程复现：generation 1 的旧正文在 generation 2 激活后原先仍能写入公告和游标，并删除待办。
恢复任务现在在读取时捕获个人流 generation，正文提交事务先复核当前代次，不一致抛 staleScope；没有新增持久化字段或 schema。
旧响应拒绝后公告不存在、正文游标零、原 request_revision 的任务保留；重新读取任务捕获 generation 2 后，同一有效公告页可以提交，游标到 20。
66 项定向测试通过，见[证据](verification-records.md#20260920-recovery-body-generation)。本轮覆盖正文入口，其他异步结果的跨代次处理仍需按入口核对，不作为完整重置/实时/App 验收。


## 所有带恢复任务结果的共同代次检查

正文之外，旧状态/不可用结果/重试/完成操作原先只校验 scope；scope 可在快照重置后保持不变，因此旧响应能更新、删除或延后新代次待办。
`requireRoomRecoveryWorkScope` 现在统一复核账户/scan 与捕获的个人流 generation，接入状态提交、不可用提交、重试、完成、服务计数、正文及携带 work 的摘要提交。
摘要请求自身的 generation 校验保留；即使错误地把新摘要请求与旧 work 组合，也会被拒绝。
真实快照激活后六入口均拒绝旧任务，新代次重新读取任务仍可提交公告页；65 项定向回归和六入口补测通过，见[证据](verification-records.md#20260920-recovery-results-generation)。
没有 schema 变更；不代表不携带 work 的其他协议入口或真实 App/TLS 整链已验收。


## 目录响应绑定扫描轮次与个人流代次

目录原先只核对 scope、游标和拓扑；同一 scope 重扫后首页游标仍为 nil，旧首页可推进新轮次。个人流代次变化也未参与目录提交校验。
V2RoomRecoveryScan 现捕获 directory_round 和个人流 generation，目录提交必须携带请求前的扫描信息；引擎在网络请求前读取，再原样交给提交入口。
提交事务复核轮次、代次、请求游标和当前游标，失败抛 stalePage，不写待办或推进目录。数据库结构不变。
两种旧请求复现、65 项恢复回归、真实快照激活七入口参数和目录四事务前后共 8 个 SIGKILL 参数通过，见[证据](verification-records.md#20260920-directory-flight-fence)。
这关闭了已复现的目录旧轮次/旧代次误提交触发点，不代替整个 B03 的网络/迁移组合验收。

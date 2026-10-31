# 作者资料随消息分发实施计划

状态：本次作者资料分发的本地实施与验收已完成。服务端和客户端按新协议配套修改，不提供旧协议兼容层。生产开关默认关闭，未部署或验收生产 CDN。

## 当前验收状态（2026-10-31）

下文保留各阶段的历史记录；当前判断以本表及最近一次运行记录为准。

| 范围 | 当前证据与结论 |
| --- | --- |
| 内部资料 RPC 固定编码与认证 | 最新 ActorContracts 58 项、TCP/认证 35 项通过；百人响应编码/解码合计约 0.57 ms |
| 批量授权与一致快照 | 最新 153 项、15 套件真实 PostgreSQL 组合通过，覆盖控制/房间权限、归属变化、快照、截止与撤权；release-24 冷房间 SQL 228 次、20,574 行、执行累计 153.464 毫秒 |
| 调度与写入恢复 | 待处理截止下界、实际读取槽位与重试时点、控制查询等待及原输出有界重试均已纳入上述回归；接收端因果截止另有 7 项通过，重试不延长许可 |
| 万人冷资料 | **最新 release-24 通过**：12 个真实 ClientKit 进程、4 个网关、一万用户，资料 HTTP 尝试及响应均为零，公共源 4 次读取/4 行；这是修复后的单轮完整通过。release-23/22 各一次补查等历史失败保留在下文，不归为通过 |
| 万人后续阶段 | release-24 的热消息、120 秒连续许可、无消息改名、换头像及一万次实际字节校验全部通过，后续未新增资料 HTTP；12 个客户端退出码均为零，所有拥有的服务及 PostgreSQL 已清理 |
| 真实故障与慢连接 | 200 用户、4 网关、4 个暂停中继；实际资料锁等待、12 次控制读取失败与 2 次通道不可写延后同时被记录。196 个健康用户在故障期间收到正文，释放后 200 用户恢复资料及后续头像字节；零资料 HTTP，全部请求/服务/线程清理，release-05 退出 0 |
| ClientKit 常规回归 | 最近全量 1,483 项通过；之后的原子页面激活等修改另有 82 项、6 套件聚焦回归、7 项因果截止回归和上述万人长测 |
| Linux | 最新源码的七产品 Release 构建、哈希/动态依赖及真实图片 worker 均通过，覆盖排队下界、错误分类和原输出重试；运行证据为 `20261031T125906Z-e5d907e9`，不代表 Linux 业务端到端或生产部署 |
| App | 最近全目标 512 项中仅剩一项已确认的基线下载设置断言差异；相关聚焦 38 项通过，未修改无关默认设置 |
| 交付边界 | 十项本地完成条件已核对；生产 CDN 鉴权/缓存、跨地域网络和部署未执行。App 全目标保留一项已确认的无关基线断言差异，不能声称全仓测试全绿 |

功能默认关闭。以下最新组件、真实万人、故障组合、Linux 与工程门禁共同支持本次本地交付；不代表已部署或开启生产流量。

## 完成条件

1. 实时消息、历史分页、断线补拉统一携带按作者去重的资料补充；持久消息仍只保存发送者身份。
2. 客户端实际应用资料后确认；服务端在读取前按已确认版本和有效授权去重，缺失可批量补齐。
3. 公共基础资料共享缓存和同键读取合并；接收者、设备、双向拉黑及房间权限独立批量检查，不为每个接收者调用完整资料服务。
4. 资料修改与 outbox 原子提交；可见作者订阅在无新消息时也能更新，订阅快照与增量之间不能丢变化。
5. 内容、可见性、群昵称、私人备注及权限上下文版本分别处理；拒绝状态防止晚到响应恢复失效展示。
6. 客户端统一资料仓库，备注不跨账号、群昵称不跨群，页面离开停止订阅；图片内容身份与临时 URL 分离。
7. 展示期限与下载期限分开；URL 轮换不重复下载，权限期限不因缓存延长。
8. 资料故障不阻塞消息主链路；队列、并发、订阅、字节预算有界，续期抖动、背压和恢复受测。
9. 清理被替代的旧协议及重复传播路径；安全失效必须由新机制承接。
10. 完成协议、权限竞态、断线恢复、冷缓存、万人连接及相关工程门禁，明确实测范围。

## 实施顺序

- 第一阶段：接收者应用确认协议、严格连接/页面绑定及确认竞态测试。
- 第二阶段：共享基础资料、批量授权、读取前版本去重及容量调度。
- 第三阶段：版本化变更传播、可见作者订阅和缺口恢复。
- 第四阶段：客户端主动补齐收敛、缓存/展示期限和 App 接线。
- 第五阶段：旧路径清理、完整回归、负载测试和合同/状态文档核对。

阶段完成不等于整体完成。数据库读取次数、客户端请求次数和头像回源次数分别测量；一万个接收者的权限关系和图片传输不能被缓存消除。

## 公开资料依据与目标设计

检索日期：2026-10-30；2026-10-31 复核下列官方资料。公开规范用于选择协议形态，不构成本项目的性能验收证据。

- [Telegram Updates](https://core.telegram.org/constructor/updates) 与
  [messages.messages](https://core.telegram.org/constructor/messages.messages) 将消息/更新与所涉及的
  users、chats 辅助表一起返回。可以借鉴“正文引用身份、响应附带展示资料”的分层。
- [Matrix 成员懒加载](https://spec.matrix.org/latest/client-server-api/#lazy-loading-room-members)
  按 timeline、历史分页及上下文响应中的发送者附带成员状态，允许省略未变化的已发送状态。
  可以借鉴按实际使用者加载、跨响应去重；本项目进一步要求客户端实际应用确认。
- [CloudFront 签名 URL](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html)
  将访问期限和边缘授权放在下载请求上。可以借鉴稳定对象身份与临时访问凭据分离；
  本项目当前只有本地分发验证，不能据此声称已经接入或验证了生产 CDN。
- [腾讯云消息昵称与头像](https://www.tencentcloud.com/document/product/1047/39894)
  明确说明发送消息时附带最新昵称和头像资料，并指出每次收消息都主动查询资料会给客户端
  和后端造成压力。其历史消息保存资料的具体方式不直接作为本项目的持久化设计。
- [XMPP 头像协议](https://xmpp.org/extensions/xep-0084.html) 将变更元数据与图片数据分开，
  接收者可复用缓存中的图片；本项目借鉴这种分离，不引入 XMPP 协议。
- [AWS 缓存经验](https://aws.amazon.com/builders-library/caching-challenges-and-strategies/)
  讨论冷缓存和同键请求合并；[CloudFront 请求合并](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html)
  进一步说明不同缓存键不会合并。因此生产适配器需要实际验证鉴权与内容缓存键的分离。

### 消息与展示资料

持久消息只保存 `senderUserID` 等消息事实，不保存会随时间变化的显示昵称、头像 URL 或
私人备注。实时消息、房间日志历史页与断线补拉、最新可见消息恢复共用资料补充管线，按完整
`(userID, context)` 键去重。个人 `syncPull` 与个人快照只承载个人状态；其恢复所需的公共消息
仍由房间日志及最新可见消息接口提供，不向个人流增加公共正文或另建作者补充路径。
资料通过同一连接的独立临时帧发送；消息写入和正文投递不等待
资料查询、签名或图片下载。当前各入口的实际覆盖仍须逐项审计，不能由群历史测试代替。

补充字段包含公开名称与内容版本、可见性版本、当前上下文的群昵称及其版本、当前接收账号
的备注及其版本、稳定头像描述，以及绑定账号/设备/上下文的展示许可。头像描述包含
`mediaID/variantID/version/checksum/byteCount`；可选下载计划包含 URL、请求头与下载截止。
清空昵称或头像必须有明确的新版本，不能用缺字段表达“没有变化”。

聊天界面默认展示当前获准的资料，因此修改昵称或头像会更新旧消息的展示。若未来需要
审计“发送时叫什么”，应另定义不可变审计字段和访问规则，不能从展示缓存推断。

### 变更、订阅与缓存

资料修改、版本推进与 outbox 写入在同一事务提交。每个网关独立消费有序变更，维护
“作者到正在观察它的连接”索引；订阅先登记再读取，版本下限淘汰跨越变化的旧读取。
变化无须等待下一条消息。离线或未观察该作者的用户在重新进入页面、补拉或续期时取得
当前资料；不向完整群名册持续广播每次资料修改。

客户端一个账号只拥有一个资料接收/兴趣协调器，页面和可见行引用同一仓库。公开资料按
用户缓存，群昵称按群和用户隔离，私人备注按当前账号和目标隔离；许可必须保留完整上下文。
服务端共享的仅是按版本不可变的公开内容，权限仍分别检查接收者、设备、关系、双向拉黑
及房间事实。已确认且许可仍有效、变更源追平的可见键才允许在读取前省略；确认缓存不足
可以降低去重率，不能错误扩大权限。

头像字节按稳定内容身份缓存，URL 轮换不改变缓存键。下载计划到期可刷新计划；展示许可
到期必须重新核权。页面退出、账号切换或明确拒绝立即撤销展示；本地已有文件不能延长
授权，旧解码结果也不能借用后来续期的截止。网络故障不清空仍在有效期内的昵称。

生产边缘层必须先验证访问凭据，再允许命中共享字节缓存；只共享内容相同的不可变对象，
不共享接收者的资料响应或权限结果。单独使用有期限的签名 URL 不等于关系变化后立即撤权。
若要求变更提交后快速拒绝已有凭据，适配器还须接入权限版本或撤销检查，并测量传播上限；
只提供离线签名验证的适配器必须明确其有效期内的撤销窗口，不能承诺立即生效。

### 万人群的负载模型

设 `N` 是本次实际在线接收者，`V` 是正在展示该作者的接收者，`U` 是不同作者数，`B` 是
授权查询批次大小。应分别测量以下负载，不能统称为“资料请求”：

| 层次 | 目标行为 |
| --- | --- |
| 正文及必要资料下发 | 最坏仍有 `O(N)` 份连接投递，这是多人接收消息的成本 |
| 客户端资料 HTTP | 正常收到补充且许可有效时为 0；仅缺失/恢复/续期走合并、限流与抖动后的批量回退 |
| 公共资料源读取 | 按版本共享缓存和同键读取合并；一次冷突发随不同作者和缓存节点数增长，不随全部接收者线性回源 |
| 接收者权限 | 仍有 `O(N)` 份权限事实需要判断，集合查询将往返约束为按批次增长；不能共享别人的授权结果 |
| 无消息时的资料变化 | 只刷新当前兴趣集合中的 `V` 个接收者，并保留丢确认或拒绝准入后的恢复义务 |
| 头像字节 | 只对实际可见且本地未命中的内容下载；最坏仍有 `V` 次边缘请求，边缘命中降低源站读取，不能消除终端流量 |

队列、任务槽、输出字节、确认缓存与可见兴趣均设置全局和连接级上限。慢连接不能使读取
无限超前；过载时正文继续，资料延迟或回退。续期使用随机提前量和有界退避，页面退出
停止需求。容量验收必须包含冷启动、持续消息、无消息变化、慢连接、断线恢复、权限撤销
及长时间续期；只建立一万条连接或通过内存索引测试都不足以验收。

### 无历史兼容性的交付方式

服务端、协议生成物、ClientKit、App 和规范 schema 一起切换到同一新基线，不维护旧协议
解析、双写、旧 URL 身份或旧资料传播的兼容分支。移除旧路径前先验证其权限失效职责已由
新机制承接。功能开关用于验收控制；开启前必须完成本文全部完成条件及对应实测。

## 第一阶段验证记录

2026-10-30 工作树：接收确认按[独立合同](../reviews/author-presentation-receipt-contract.md)落地。
Core 作者资料测试 4 项通过；ClientKit 聚焦串行测试 72 项通过；Server 聚焦串行测试
57 项通过。覆盖确认序号/作者集合、已安装与暂存资料、旧页面、TCP 编解码、提前确认与
失败写入、Gateway 身份及载荷边界。协议生成物一致性、模块边界、Actor 序列化边界、
文档结构及链接检查通过。尚未执行这一完整改造的数据库、App 和万人端到端容量验收。

复现：

```sh
swift test --package-path IMV2Core --filter AuthorPresentation
swift test --disable-automatic-resolution --package-path IMV2ClientKit --no-parallel --filter 'V2AuthorPresentation|V2ProfilePresentationIngest|V2ProfileVisiblePage|V2TCPFramePolicy|V2ProtobufFrameCodec'
swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel --filter 'V2AuthorPresentation|V2ProtobufFrameCodec'
bash scripts/check_v2_protobuf_generated.sh
python3 scripts/check_v2_server_boundaries.py
python3 scripts/check_actor_serialization_boundaries.py
bash scripts/check_v2_document_structure.sh
bash scripts/check_v2_document_links.sh
```

## 第二阶段验证记录

第二阶段的批量读取和共享内容部分按[批量读取合同](../reviews/author-presentation-read-contract.md)
实施。2026-10-30 使用独立原生 PostgreSQL 实例及脚本创建的七个一次性数据库，75 项聚焦
测试、10 个 suite 全部通过，无跳过项。测试后脚本删除其创建的数据库，临时实例已停止。
另补充共享批次中一个页面替换且复用 nonce 的生命周期回归。读取前去重、变更订阅及容量
调整仍待完成，不能把本阶段当作完整方案验收。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2ProfileControlBatch|V2ResourceProfilePresentation|V2ProfilePresentationFanout|V2PublicProfileSnapshotCache|V2AuthorPresentation'
swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel --filter V2AuthorPresentationBatchDispatchTests
```

## 第三阶段当前进度

前台房间页面的可见作者集合已按[集合合同](../reviews/author-presentation-interest-contract.md)
接通：protocol 50 的 135/136 帧、128 键完整替换、独立可见性观察流、25 ms 滚动合并、
非空请求正常准入与空集合清理、服务端反向索引。新索引在资料读取前登记；这尚未包含
所有权限和个性化资料来源。公共资料的持久变更子阶段现已接通，详见下文。

2026-10-30，Core 聚焦 5 项、ClientKit 聚焦 54 项、Server 聚焦 63 项通过。包含真实
编解码及 Gateway 接线、取消时非协作请求、页面/房间/stream 隔离、乱序替换、去重和
128 键准入。10,000 个内存连接的反向索引边界测试通过（本机此次 1.84 秒）；此数值
不代表真实网络、数据库或头像分发容量。协议生成物、模块/Actor 边界和文档门禁通过。

```sh
swift test --package-path IMV2Core --filter AuthorPresentation
swift test --disable-automatic-resolution --package-path IMV2ClientKit --no-parallel --filter 'V2AuthorPresentation|V2ProfileVisiblePage|V2TCPFramePolicy|V2ProtobufFrameCodec'
swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel --filter 'V2AuthorPresentation|V2ProtobufFrameCodec'
```

### 持久公共资料变更子阶段

公共资料发布序号在 schema 73 引入；当前 schema 为 `im-v2-current-76`。复用资料修改事务中的 outbox，增加按提交顺序发布
的序号和每网关独立游标；保留期缺口触发可见作者重读。原子更新 head 的锁仅影响资料
修改，不进入消息提交事务。Dispatcher 先登记可见作者再读取，变化提升最低版本并
废弃旧读；发送与应用确认共同完成刷新，队列拒绝和丢确认不会删除待刷新义务。
排队中的未确认普通消息补充也不能吞掉来源事件。具体时序、界限与生命周期见
[可见作者集合合同](../reviews/author-presentation-interest-contract.md)。

2026-10-30，真实原生 PostgreSQL 聚焦运行 90 项、11 个 suite 通过，无跳过项；覆盖
真实资料修改/幂等重放、提交锁等待、回滚、两个独立游标、128 条分页、保留期缺口与
启动闸门漂移。随后补充发送确认竞态和队列拒绝恢复，受影响 Server 27 项、4 个 suite
通过；客户端 66 项、5 个 suite 通过。另运行资料修改与头像绑定的真实 PostgreSQL
回归 17 项、3 个 suite，包含参数化场景，全部通过。上述范围有重叠，不合计为独立
用例数量。规范 schema 的新建、导出恢复、触发器漂移和目录合同检查通过，协议生成物、
模块/Actor 边界、文档结构和链接检查通过。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'PostgresV2AuthorProfileChange|V2AuthorProfileChange|V2AuthorPresentation|V2ProfileControlBatch|V2ResourceProfilePresentation'
swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter 'V2AuthorProfileChangeDelivery|V2AuthorPresentationDispatcher|V2AuthorPresentationRuntime|V2AuthorPresentationBatchDispatch'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --no-parallel --filter 'V2ProfilePresentationIngest|V2AuthorPresentation|V2ProfileVisiblePage'
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2ResourceProfileBindingPostgres|ownProfile|publicIdentityName|publicIdentityConcurrent|PostgresV2AuthorProfileChange'
IMV2_SCHEMA_BOOTSTRAP_NATIVE=1 PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_postgres_schema_bootstrap.sh
```

### 私人备注、双向关系与在线群昵称子阶段

Schema 74 使用共享 `author_presentation_change_head` 为公共资料及私人备注/关系/拉黑
变更排序。三类控制变更在原事务提交阶段登记，日志只携带身份和版本；备注只刷新所属
账号的设备，关系和双向拉黑分别重新核权。控制日志保留与 housekeeping 共用有界预算，
清理后仍通过 head 检测缺口。群昵称接入 Room Owner 已提交事件和有界 ingress，按群、
作者和独立版本刷新；队列溢出保留固定大小的重读义务。

2026-10-30，真实原生 PostgreSQL 聚焦运行 102 项、13 个 suite 全部通过，无跳过项。
覆盖真实备注更新/清空/幂等、deferred 发布/回滚、公共与控制变更提交顺序、保留期清理、
两向拉黑/关系生产入口、群昵称事件原子性，以及 Gateway 无新消息昵称通知、跨群隔离、
旧读取淘汰、队列溢出和实际消费者关闭。Schema 74 新建/导出恢复/漂移检查也已通过。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'PostgresV2AuthorProfileChange|V2AuthorProfileChange|V2AuthorPresentation|V2ControlHousekeepingBudget|V2ProfileControlBatch|V2GroupNicknameEventPostgres|PostgresV2PresentationRecovery|relationshipAndBlockLifecycle|socialOperationConcurrentReplay|currentSocialOperationRequiresPolicyOwner'
```

### 房间变化与缺口重读子阶段

房间投递在有序 lane 真正接受新数据、完成 socket 授权投影后触发资料观察；重放不重复
通知。完整授权基线、成员 grant/revoke、授权失效、正文缺口 head、授权序列缺口和成员/
角色权限事件已接入。房间到连接索引限制刷新范围；正在读取的旧结果失效，各内容版本
下限保留。房间重读与昵称和消息提示共用有界入口，溢出保留恢复义务，正文继续投递。

2026-10-30，配有真实原生 PostgreSQL 的聚焦复跑：Server 226 项、24 个 suite；服务端
App 组装 4 项、1 个 suite；Actor Cluster 10 项、2 个 suite 全部通过，无跳过项。包含
原有房间授权/投递回归、跨节点投递，以及新增无正文接收者的事件观察、重放去重、513
人分段基线、授权缺口、跨群重读、旧读淘汰和共享预算。模块/Actor 边界、文档结构、链接
及 diff 空白检查通过。以上测试范围与前述阶段有重叠，不合计为独立用例。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2Author|V2GatewayRoomSubscription|V2RoomSubscription|V2RoomDeliverySession'
```

### 带版本拒绝与恢复子阶段

Protocol 51 的许可与拒绝都携带控制域提交序号及房间成员/权限修订。控制查询读取关系
和两向拉黑的持久计数，三轮核验同时覆盖许可与拒绝，拦住状态恢复原样的 ABA 竞态。
客户端合并独立权限版本下限，忽略较旧拒绝；恢复可以只推进权限，无需修改公开资料或
重开页面。跨页面等待和暂存候选也保留完整下限。拒绝记录有 2,000 条上限，超限通过
页面因果栅栏恢复，不能靠淘汰条目复活旧授权。

Schema 75 增加待审核申请变化与房间权限修订的事务绑定：取消后重新申请也可恢复资料，
提交、删除、幂等、无关字段更新和回滚受测。带真实 PostgreSQL 的聚焦回归 131 项、17 个
suite 通过，无跳过项；Core 26 项、6 个 suite、ClientKit 85 项、8 个 suite 通过。
另运行真实入群事务、配额、取消/审批竞争回归，10 个测试通过；该次未启用的 D4 用例
已在两个独立 Actor 数据库中单独补跑通过，无跳过项。原生测试脚本现为这两个 Actor
数据库分配独立临时库并负责清理。Schema 75 新建/导出恢复/漂移、Protocol 51 生成物、
模块/Actor 边界、文档结构和链接检查通过。上述测试范围有重叠，不合计为独立用例。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2ResourceProfilePresentation|V2ProfileControlBatch|V2ProfilePresentationFanout|V2Author|V2ActorRoomMediaAuthorization|V2RoomMediaAuthorization|PostgresV2AuthorProfileChange|V2GroupInvitation|V2GroupJoin'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ProfilePresentation|V2AuthorPresentation|V2HTTPProfilePresentation|V2HTTPGroupNickname|V2ProfileVisiblePage'
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'invitationApproval|invitationApplicant|invitationCancellation|groupJoinReserved|groupJoinGlobal|invitationCursorSurvivesAnchorChange|v2RoomActorInvitationRecoveryAndDecisionRace'
```

### 短许可计时与读取前去重子阶段

Protocol 52 用服务端页面的实际单调经过时间校正客户端因果期限，仍扣除初次上行和本次
下行/排队等待，不要求墙钟同步。应用确认必须带实际保留条目的最短剩余期限；服务端以
准备时刻为锚点取更早截止，延迟或重复确认不能延长期限。这修正了原先统一扣除 30 秒
导致真实短 Room Owner 证明无法形成去重提示的问题，没有延长原授权或 owner 期限。

仍可见、已确认、许可有效且没有待刷新变化的作者，现在可以在读取前省略。变更源确认
追平后只维持 1 秒的省略窗口，已知积压、错误、缺口或停滞会停用省略；待处理队列也在
真正开始读取前重新检查。非可见作者或未确认资料继续正常核权。更改内容或权限立即
撤销提示，并保留原先直到应用确认才结束的刷新义务。

2026-10-30，Core 聚焦 21 项、8 个 suite，ClientKit 86 项、8 个 suite，以及真实 PostgreSQL
Server 113 项、12 个 suite 通过，无跳过项。随后对来源已知积压期间停用省略和确认字段
转发补充检查，Server 32 项、2 个 suite 和 ClientKit 49 项、3 个 suite 通过。这些范围有
重叠，不合计用例数。覆盖 20 秒旧页面上的新 5 秒许可、网络停滞、未来服务端年龄拒绝、
确认期限/原许可双重上界、重复确认、可见资料连续 10 次提示不增加读取，以及资料变化、
来源失败/停滞后的恢复。Protocol 52 生成物、模块/Actor 边界检查通过。

```sh
swift test --package-path IMV2Core --jobs 4 --filter 'AuthorPresentation|PresentationAuthority|Profile'
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2AuthorPresentation|V2AuthorProfileChange|V2ResourceProfilePresentation|V2ProfilePresentationFanout|V2ProfileControlBatch|PostgresV2AuthorProfileChange'
```

### 头像内容、展示许可与下载计划分离子阶段

Protocol 53 的头像描述增加必填 byteCount，下载计划改为可选。计划的大小、摘要必须与
稳定内容匹配；没有计划仍可表达当前头像。服务端签名失败保留内容描述与独立昵称许可，
并继续最终权限复核；资料去重提示不再随下载链接提前失效。旧 wire 描述不兼容。

个人和群头像仓库现在生成绑定页面与授权代次的 `V2AvatarReadGrant`，App 无公开构造器。
资源缓存先检查展示权限，再复用已校验字节；只有缓存未命中才要求有效下载计划。计划
过期保留内容身份，URL 轮换不改变字节缓存键。旧文件句柄每次借用都复核当前权限，
异步核验后再次检查账号代次与内容身份。UI 解码后还需核权，失效图片不能随有效昵称
一起返回；旧解码的截止不会被并发续期延长。

2026-10-30：Core 26 项、9 个 suite 通过；ClientKit 112 项、7 个 suite 通过，随后新增
最长展示期限与仓库 grant 失效断言的受影响复跑 39 项、2 个 suite 通过。真实 PostgreSQL
97 项、10 个 suite 通过，无跳过项，包含签名故障、签名期间权限变化、群头像和资源迁移。
iOS 27 独立模拟器 App 聚焦 28 项、3 个 suite 通过，覆盖实际图片缓存、页面/账号边界与
解码文件租约；随后群头像 2 项、1 个 suite 的参数化复跑验证了有/无下载计划及失效边界。
各次运行有重叠，不合计独立测试数量。Protocol 53 生成物、模块/Actor
边界、文档结构与链接检查通过。

```sh
swift test --package-path IMV2Core --jobs 4 --filter 'Avatar|Profile|AuthorPresentation'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ResourceDownloadCache|V2ProfilePresentation|V2GroupAvatarPresentation|V2HTTPGroupAvatarPresentation|V2AuthorPresentationReceiver'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ProfilePresentationIngest|V2GroupAvatarPresentationRepository'
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2ResourceProfilePresentation|V2ResourceGroupAvatar|V2ResourceMigration|V2AuthorPresentation|V2ProfilePresentationFanout'
xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -destination 'platform=iOS Simulator,name=IM Avatar Authority 20261030' -skipPackageUpdates -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -only-testing:IMAppTests/V2ProfileAvatarPipelineTests -only-testing:IMAppTests/V2GroupAvatarPipelineTests -only-testing:IMAppTests/V2MediaFileLeaseTests
```

### 缺失头像字节的下载计划恢复子阶段

客户端已接通个人和群头像 `refreshAvatarReadGrant`，复用既有有界鉴权队列、同键请求合并
与取消/关闭所有权，不新增绕过资料授权的图片续签端点。刷新失败保留原有展示许可及其
截止；明确拒绝和认证失效会撤权。单键随机间隔抑制刷新风暴，已换过的计划可以复用，
但“计划刚过期被移除”不能误判为刷新完成。内容比较也包含字节数，群头像比较完整内容
身份，不因 URL 轮换触发图片失效。

App 在缺少元数据、下载计划或字节入口拒绝旧凭证时最多主动刷新一次；一次可见加载在
正常授权到期前最多再进行四次延迟图片尝试，尊重退避、抖动和限流。图片重试时间独立于
展示截止，等待期间不清空仍获准展示的昵称。成功下载后复用已有文件，不重复查询资料。

2026-10-30：ClientKit 137 项、8 个 suite 聚焦回归通过；随后增加关闭、过期和下载期间
链接到期的边界并复跑 42 项、2 个 suite 通过。iOS 27 独立模拟器 31 项、4 个 suite 通过，
包含个人/群头像冷缓存、元数据缺失、持续未签出链接、CDN 拒绝凭证、网络恢复、缓存复用
和重试预算，参数化场景均通过。第一次模拟器启动失败已确认进程终止，显式启动并核验
模拟器后完成复跑。最后按真实下载层的错误类型补齐 HTTP 404 与凭证拒绝恢复，个人头像
18 项、1 个 suite 复跑通过。各次测试有重叠，不合计独立用例数；本子阶段未改变服务端或 wire。

```sh
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ProfilePresentation|V2GroupAvatarPresentation|V2ResourceDownloadCache|V2AuthorPresentation'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ProfilePresentationIngest|V2GroupAvatarPresentationRepository'
xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -destination 'platform=iOS Simulator,name=IM Avatar Renewal 20261030' -skipPackageUpdates -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -only-testing:IMAppTests/V2ProfileAvatarPipelineTests -only-testing:IMAppTests/V2GroupAvatarPipelineTests -only-testing:IMAppTests/V2AvatarRetryScheduleTests -only-testing:IMAppTests/V2MediaFileLeaseTests
```

接下来：完整失效边界、列表多上下文订阅、展示许可续期的容量与全局预算收敛。原完成条件仍全部保留；新路径默认关闭，尚未
完成 App 全量相关回归、Linux 及真实万人连接验收，也未删除原安全失效路径。

### 多上下文账本与多页面仓库子阶段

服务端的可见兴趣、刷新任务、版本下限、读任务及 ACK 交付账本改为完整资料键，用户反向
索引仅用于查找连接；群昵称失效显式限定房间上下文。输出预算也计入完整键的保留成本。
Core 提供统一的分批选择规则，客户端和 Dispatcher 共同使用；每个接收者的单次读取仍
最多 8 个授权上下文，整体兴趣集合不受该单批限制。128 个混合成员、审批、私聊和关系键
的真实仓库请求测试验证全部完成、不遗漏、不重复，且每批通过实际 HTTP 请求合同校验。

ClientKit 仓库可将一次接收绑定多个既有页面；逐页面授予和撤销许可，候选资料记录尚未
领取的页面。关闭一个页面不使另一个页面停止接收；第二个页面领取相同资料不使已有头像
读取失效。新增页面必须使用新 nonce，解绑后也不能扩大旧 nonce 的页面集合或重放已替换
的 nonce。新到的资料仍会隔离较早 HTTP 任务，候选资料提升不会被误当成新的服务端观察。

2026-10-30：Core 9 项、4 个 suite，ClientKit 82 项、7 个 suite，服务端 79 项、8 个 suite
通过。新增用例覆盖多页面候选共享、逐页面退出、后出现的行、加入页面及解绑后的 nonce
重用拒绝；既有 ACK 竞态、变更刷新、权限隔离和内存万人索引测试回归通过。本子阶段没有
修改数据库、Protocol 53 或 App 接线，没有执行真实万人连接或新的模拟器验收。

```sh
swift test --package-path IMV2Core --jobs 4 --filter 'ProfilePresentationBatchSelection|AuthorPresentation'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2ProfilePresentationMultiContextBatch|V2ProfilePresentationRepository|V2ProfilePresentationIngest|V2ProfileVisiblePage|V2AuthorPresentation'
swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter 'V2AuthorPresentation|V2AuthorProfileChangeDelivery|V2AuthorRoomChangeIngress'
```

该子阶段结束时 wire 和协调器仍只接通单个房间页面；下面的 Protocol 54 及连接级
多页面子阶段继续解除这一限制。逐键鉴权及独立群事件订阅保留，新路径默认关闭，
完整完成条件没有缩减。

### Protocol 54 多上下文传输子阶段

作者资料改用独立 Start/Started（137/138）启动，移除群事件订阅中的作者 nonce，原字段
编号保留为 reserved。启动可以没有消息房间，最多指定 8 个消息房间；启动不证明房间或
资料访问资格。兴趣、ACK 和 delta 改为完整资料键，单帧支持同一用户的多个授权上下文。
接收者、设备、原始单调期限、序号、实际应用 ACK 及帧/任务预算继续保留；没有旧 wire
解码兼容层。普通房间订阅和退订不再结束作者视图，页面所有者发送独立 End 负责清理。

Gateway 在启动回执写入后激活视图；可选通道的注册容量不足时返回可重试的
`AUTHOR_PRESENTATION_UNAVAILABLE`，不会谎报已启动，也不会关闭正常消息连接。列表键
使用现有资料鉴权读取端口，单连接跨上下文读取分批遵守 8 个权限上下文上限。服务端
记录私聊目标读取解析出的实际权限房间，使后续房间权限变化也能重读该完整键；这项
房间映射随兴趣移除清理，不把同一用户的关系名片合并为私聊权限。

2026-10-30：Core 11 项、5 个 suite，ClientKit 82 项、6 个 suite，服务端 84 项、10 个
suite 通过。包括跨上下文精确 ACK/刷新、群昵称失效仅命中指定上下文、无消息房间的列表视图、
24 个房间上下文的分批、私聊权限房间索引、畸形 context/启动回执、容量不足、旧 nonce
清理、同 socket 合帧时序、NIO 拥塞及实际写入许可围栏。protobuf 生成校验、模块边界、
Actor 序列化和文档门禁通过；iOS Simulator 通用目标的 App 编译通过。本轮没有运行新的
App UI/设备测试或真实万人连接验收。

```sh
swift test --package-path IMV2Core --jobs 4 --filter 'AuthorPresentation|ProfilePresentationBatchSelection'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2AuthorPresentation|V2ProfileVisiblePage|V2ProfilePresentationIngest|V2TCPFramePolicy'
swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter 'V2AuthorPresentation|V2AuthorProfileChangeDelivery|V2AuthorRoomChangeIngress'
bash scripts/check_v2_protobuf_generated.sh
xcodebuild build -project IMApp/IMApp.xcodeproj -scheme IMApp -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/im-author-avatar-dd -skipPackageUpdates -disableAutomaticPackageResolution -jobs 4 CODE_SIGNING_ALLOWED=NO
```

本子阶段完成独立 Start 与完整上下文传输；下一节记录连接级所有者及列表页接线。
完整失效、续期/总容量、旧路径清理、Linux 和真实万人连接验收仍未完成，功能保持默认关闭。

### 连接级多页面所有权子阶段

连接级协调器现在合并列表、聊天和其他可见页面，最多 16 个页面、8 个消息房间；同一
连接只有一组接收、应用确认、兴趣发布和续期任务。列表无需普通房间订阅，聊天继续持有
独立的房间租约。新页面加入生成新 nonce，现有页面只转移原截止内的许可；新页面不借用
旧授权。离开一页立即撤销该页作者许可，并等待旧请求实际结束，其余页的有效许可保留。

账号连接及权限代次变化废弃旧绑定，包括仅通过重新协调发现的成员权限变化。独立资料
启动被拒绝不再撤销普通房间订阅，旧的房间作者专属代次与拒绝接口已移除。后台清理覆盖
列表与聊天页；清理任务仍持有实际 I/O，前台新准入须等待清理完成，close 后立即拒绝准入。

账号统一限制 128 个完整资料键、512 个行引用。跨页面相同键共享键名额；实际可见行
优先于离屏快照的缓存引用，缓存满时回收没有实际可见行的最早缓存键，避免列表快照占满
聊天页的名额。超出全部实际可见行预算仍显式拒绝；不截断已准入的集合，不延长展示期限。

2026-10-30：ClientKit 107 项、8 个 suite 通过；随后修正普通房间撤权/恢复快照时序，
受影响的房间与资料协调器 33 项、2 个 suite 复跑通过。iOS 27 独立模拟器 App 25 项、
2 个 suite 通过。覆盖列表单独启动、跨页面/跨房间合并、独立上下文、准入上限、迟到 ACK/
资料/Retry-After、非协作请求清理、重连与权限 ABA、单页退出隔离、可回收缓存引用及实际
SwiftUI 后台/前台切换。测试范围重叠，不合计为独立用例数量。首轮测试发现的清理完成后
准入自旋、关闭期间准入等待及重复撤权快照已修正；以上是修正后的结果。
模块边界、Actor 序列化、文档结构/链接及 diff 空白检查通过；本轮临时模拟器已关闭并删除。

```sh
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2AuthorPresentation|V2ProfileVisiblePage|V2ProfilePresentationIngest|V2RoomSubscriptionCoordinator|V2ProfilePresentationRepository|V2ProfilePresentationMultiContextBatch'
swift test --disable-automatic-resolution --package-path IMV2ClientKit --jobs 4 --no-parallel --filter 'V2AuthorPresentationPageCoordinator|V2RoomSubscriptionCoordinator'
xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -destination 'platform=iOS Simulator,name=IM Author Multipage 20261030' -derivedDataPath /tmp/im-author-avatar-dd -skipPackageUpdates -disableAutomaticPackageResolution -parallel-testing-enabled NO -collect-test-diagnostics never -jobs 4 CODE_SIGNING_ALLOWED=NO -only-testing:IMAppTests/V2ProfileAvatarPipelineTests -only-testing:IMAppTests/V2RoomSubscriptionAppTests
```

后续仍按文首十项完成条件继续：全入口失效检查、展示续期连续性和容量调优、已替代旧路径
清理、Linux 与完整相关回归、真实 10,000 网络连接的持续负载及数据库/头像分发验收。内存连接测试
不替代真实网络测试，功能保持默认关闭。

### 续期后的头像解码期限

个人与群头像管线现在记录本次文件读取实际使用的许可截止，最终展示再检查当前资料和
页面代次。原资料在刷新期间到期后，新许可读取的新图片仍能展示；旧解码结果不能借用
并发续期取得的新截止。图片失效不清除独立有效的昵称，返回期限分别取当前资料和实际
图片读取许可的上界。2026-10-30，独立 iOS 27 模拟器的个人/群头像 25 项、2 个 suite
通过（`/tmp/im-author-renewal54-app-final2.log`，11.132 秒）；测试创建的模拟器已删除。

### 真实 TLS 万人连接与输出背压

新增显式启用的 `V2AuthorPresentationNetworkBenchmarkTests`。一万个本机真实 TLS 客户端
完成协议协商、认证、独立页面/兴趣登记、资料解码应用和 wire ACK；使用实际 Gateway、
NIO 写出、Dispatcher、共享公开资料缓存及变更消费者。认证、接收者授权事实、历史消息
与变更源是确定性夹具，头像为空，不涉及真实 SQL、云存储或 CDN，不是生产端到端容量证明。

初轮只能完成 1,463 份首次确认。修正后，待处理任务默认上限从 1,024 降为 128 键，
读取/排队输出/写出合计最多涉及 200 个接收者，排空到 100 个才补读，单批最多 100 项。
返回的批次在等待输出空间时继续占用读取槽，并保留原截止和取消语义；每轮重试合并调度，
尚未进入队列的需求不再被错误施加一秒读取失败冷却。实际读取与写出仍各最多 4 个任务，
输出仍限 256 KiB，工作期限仍为 500 ms。确认缓存默认 16 MiB；它是有界去重优化，不是权限源。
输出保留成本只计算一次，复用已校验的候选 delta，页面/身份核验集中到 Gateway frame
准备阶段，移除相邻层重复的 JSON 校验。

2026-10-30，本机 Debug 构建一次完整万人测试通过：

| 指标 | 实测 |
| --- | --- |
| TLS 连接与认证 | 10,000 / 10,000，建立并认证 6.71 秒 |
| 首次资料应用并收到确认回执 | 10,000 / 10,000，10.67 秒 |
| 随后历史页响应 | 10,000 / 10,000 |
| 这轮历史拉取新增资料读取 | 0 |
| 无新消息的第二版资料确认 | 10,000 / 10,000，8.62 秒 |
| 公开内容源读取 | 两个版本合计 2 批 |
| 接收者读取输入 / 批次 | 20,300 / 554；是夹具端口计数，不是 SQL 计数 |
| 队列拒绝 / 过期计数 | 9,135 / 692，兴趣恢复最终覆盖全部接收者 |

本轮页面兴趣提交用了 0.88 秒。以上时间不承诺生产延迟；尚未测量持续续期、长名称及头像
描述下的去重容量、多作者/多节点、慢连接混合、真实数据库权限读取和图片回源。测试末态
预算断言不代表峰值采样；有界读超前、输出等待取消和非协作写者的资源所有权另由聚焦回归
验证。测试关闭了其创建的所有连接、监听端口和 runtime。日志：
`/tmp/im-author-network10000-fair.log`。

随后 Server 作者通道聚焦回归 87 项、10 个 suite 通过，无跳过项，覆盖读取超前、返回批次
等待输出期间的关闭、队列恢复不误加失败冷却、Gateway 页面绑定及原有权限/确认竞态。
日志：`/tmp/im-author-capacity-regression.log`。模块边界、Actor 序列化边界、文档结构/链接
及 diff 空白检查通过。以上范围与各子阶段有重叠，不合计为独立测试总数。

```sh
IMV2_RUN_AUTHOR_NETWORK_BENCHMARK=1 IMV2_AUTHOR_NETWORK_CONNECTIONS=10000 swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter V2AuthorPresentationNetworkBenchmarkTests
```

完整完成条件继续保留；本次 `groupEventPull` 压测不证明最新可见消息恢复、所有消息事件
形态、持续续期或生产数据库和头像字节链路的容量。功能默认关闭。

### 消息恢复入口与完整编辑结果

2026-10-30，按当前协议和持久化约束核对正文入口。个人投影 worker 明确拒绝 `message`、
`message_reaction`、`group_capability` 和 `moderation`；个人快照从个人投影版本生成，
公共消息恢复仍走房间日志。最新可见消息回复只建立展示快照，不推进房间日志游标。

| 入口 | 本阶段处理与证据 |
| --- | --- |
| 实时私聊、群聊 | Owner 正文投递后提取作者；接受事件及完整编辑事件均覆盖，撤销成员权限后不再提交正文或资料工作 |
| 普通及预编码 `groupEventPull` | 保留有界原始事件采样；仅返回完整编辑事件、未返回原接受事件时，也补充原发送者 |
| `roomLatestVisibleBatch` | 只对当前选中的消息房间提取作者；先核对请求/返回房间集合与快照合同，正文成功写出后才提交提示 |
| 个人 `syncPull`、`snapshotPagePull` | 不新增公共消息或作者补充路径；真实 PostgreSQL 拒绝测试证明公共投影暂停且检查点不推进 |

完整编辑提示复用 `V2MessageEditReplacement` 校验：字段缺失、房间/序号/修订/正文不符或
替换状态损坏时不生成提示；不回退到编辑操作者或额外头部中的发送者。共享采样仍受原来的
事件数、作者数和字节上限约束。最新可见恢复验证 100 个响应房间中位于末尾的 8 个选中房间，
同一作者在不同房间保留独立上下文；处理或写出期间更换页面后，旧回复不触发资料读取。

最终原生 PostgreSQL 聚焦运行 54 项、6 个 suite 通过（16.082 秒），包含实时私聊/群聊与
接受/编辑的四种组合、完整替换的十三种有效/损坏形态、普通/预编码分页，以及最新可见恢复
的准入和迟到响应。个人流拒绝测试的四种公共投影均实际执行，无跳过。测试脚本清理九个
独立临时数据库，随后关闭本轮启动的 PostgreSQL 实例。前一轮纯组件运行 53 项、5 个 suite
通过；模块边界、Actor 序列化边界、文档结构/链接和差异空白检查通过。

```sh
PGHOST=127.0.0.1 PGPORT=55449 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh --filter 'V2AuthorPresentationGatewayTests|V2AuthorPresentationIngressTests|V2RoomLatestVisible|rejectsPublicProjection'
```

日志：`/tmp/im-author-entrypoint-postgres-02.log`、`/tmp/im-author-entrypoint-gateway-01.log`。
上述验证不代替完整编辑持久化或 App UI 的全量回归。客户端个人同步与快照中尚有公共消息
投影分支，旧路径清理阶段仍须审查；不能因此重新向个人流加入公共正文。持续续期、富资料
万人容量、完整数据库/头像字节链路及 Linux 门禁继续保留在整体验收范围内。

### 富资料确认缓存容量

真实 TLS 压测增加可选 `IMV2_AUTHOR_NETWORK_RICH_METADATA=1`：79 字节公开昵称、稳定头像
描述、20 KiB 预期文件大小和带 256 字节模拟凭据的短期下载计划。接收端校验并安装描述后
确认；实际不下载图片，授权与资料变更仍为夹具，不能据此声称完成 SQL 或 CDN 容量验收。

初次一万连接运行虽然全部收到资料和变更，但失败于热历史读取：每条确认记录保留完整
资料比较值，富资料单键计费 2,690 字节，16 MiB 全局上限只能保留部分连接。热历史因此
新增 1,968 次接收者资料读取。不能将这轮“全部送达”算作去重容量通过。

修正为仅保存 SHA-256 内容摘要及公开资料、群昵称、备注三个版本字段；摘要包括独立可见性
版本、完整权限观察版本及稳定头像描述（含长度），排除临时 URL 和展示许可的时间。相同
内容在许可续期或 URL 轮换时保持一致；名称、清空状态、权限或头像任一稳定字段变化时仍
须交付。它只用于已应用资料的压缩，不参与授权。计费同时增加固定记录和字典的保守预算，
一键确认记录变为 944 字节，不随昵称或头像描述长度增长，未提高 16 MiB 上限。

2026-10-30，相关 84 项、6 个 suite 回归通过（3.074 秒），包含 16 种独立内容/权限变化、
续期和 URL 轮换、富资料计费，以及确认、批量调度、Gateway 和变更恢复的既有回归。
同配置一万 TLS 连接复跑通过（28.443 秒）：首次和变更后均 10,000 份应用确认，10,000 次
热历史响应，公开内容源两次批读取，热历史新增资料读取为 0。首次交付 10.741 秒，变更
交付 8.694 秒；确认计费 9,440,000 字节。正文以外的排队拒绝 9,237 次、过期作业 585 次
由可见兴趣重试恢复，不能据此声称不存在排队或重试。

```sh
IMV2_RUN_AUTHOR_NETWORK_BENCHMARK=1 IMV2_AUTHOR_NETWORK_CONNECTIONS=10000 IMV2_AUTHOR_NETWORK_RICH_METADATA=1 swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter V2AuthorPresentationNetworkBenchmarkTests
```

日志：`/tmp/im-author-network-rich10000-01.log`（失败）、
`/tmp/im-author-network-rich10000-compact.log`（修正后通过）、
`/tmp/im-author-fingerprint-regression-01.log`。

同一富资料配置随后增加三轮页面替换续期（每轮间隔 24 秒），每轮重新开始并提交可见兴趣；
协议接收夹具保留原有效展示值，检查新值到达前没有越过原展示截止，并使用单调递增请求
标识隔离迟到确认。每轮再次完成 10,000 个资料确认和 10,000 个热历史响应，新增资料读取
均为 0。整轮 91.727 秒通过，初始读取及三轮重新核权累计 50,999 个接收者读取、1,531 个
批次，公共内容源仍为两个版本的两次加载；不能将续期所需核权算作重复历史读取。

运行中每 200 ms 采样一次，记录固定大小的各项最大值：待处理 71 键 / 32,944 字节，
输出 200,595 字节，确认记录 9,440,000 字节，读取和写入各 4 槽。这是观测到的采样最大值，
不是进程 RSS 或每次状态变化的分配追踪；硬上限另由持有读写者的聚焦测试验证。排队拒绝
36,754 次、过期作业 2,636 次均由有界兴趣刷新恢复。本轮不包含多个作者、多个网关、混合
慢连接、真正的 ClientKit 页面协调器、SQL 权限读取或图片字节下载，不能推广成这些范围
的验收。App 续期与解码竞态证据仍见前述独立阶段。

```sh
IMV2_RUN_AUTHOR_NETWORK_BENCHMARK=1 IMV2_AUTHOR_NETWORK_CONNECTIONS=10000 IMV2_AUTHOR_NETWORK_RICH_METADATA=1 IMV2_AUTHOR_NETWORK_RENEWALS=3 swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter V2AuthorPresentationNetworkBenchmarkTests
```

日志：`/tmp/im-author-network-renew10000-01.log`。最终相关回归 97 项、12 个 suite 通过
（5.037 秒），无跳过；包括上下文/线协议、可见兴趣、运行时、缓存及前述分发回归。
日志：`/tmp/im-author-entry-capacity-final.log`。整体验收仍未完成，功能默认关闭。

### 当前源码的 Linux 编译与加载检查

2026-10-30，以固定 Swift 6.4.0/glibc x86_64 SDK 对当前源码构建全部七个服务端程序，
279.608 秒通过；构建前后源码哈希一致，七个产物均通过 ELF、加载段及剥离完整性核对。
产物目录为 `build/native-linux-release/runs/20261030T154039Z-cd68f4c7`，其 `manifest.json`
记录 `verified-linux-release`、七个程序和空 `sourceDrift`。此状态本身只证明构建，
不代表服务端业务链路已在 Linux 上验收。

随后将同一产物打包到本地 Linux amd64 镜像，通过 `verify_v2_linux_release.py` 在无网络的
临时容器中检查产物哈希、固定 SDK 运行库和全部七个程序的动态依赖，并实际运行图像 worker：
640×480 源图生成 320×240 与 640×480 两档预览，结果写入同目录的 `runtime-verification.json`，
状态为 `passed-linux-loader-and-worker`，`serviceEndToEndTest` 为 `false`。临时容器由验证器
清理，本轮镜像标签已删除；本轮启动的测试 VM 在验证后关闭。

```sh
python3 scripts/build_v2_linux_release.py --jobs 4
python3 scripts/verify_v2_linux_release.py build/native-linux-release/runs/20261030T154039Z-cd68f4c7 --docker-context colima-imv2-x86 --runtime-image im-author-linux-20261030:cd68f4c7
```

第二条命令需要先按[原生 Linux 构建指南](../guides/native-linux-release.md)重新打包该产物，
因为本轮验证镜像已清理。日志：`/tmp/im-author-linux-release-20261030.log`、
`/tmp/im-author-linux-image-build.log`、`/tmp/im-author-linux-runtime-verification.log`。
该检查不覆盖 Linux 上的数据库、Actor 网络、真实万人连接或资源分发业务全链路；这些
范围不能用加载器和 worker 验证替代。

## 多作者容量、调度与编解码增量

2026-10-31，真实 TLS 压测新增 `IMV2_AUTHOR_NETWORK_AUTHORS=1...8`，默认仍为 1。
每个接收者必须安装并确认全部作者，才计入首次完成；资料变化只推进第一名作者，其他
作者保持原版本。测试分别累计接收者读取和资料键读取，检查头像身份、历史作者集合、
页面代次以及每次实际应用确认。不可变内容源按实际加载键计数，避免把合批次数误称为
作者读取次数。该测试仍使用身份、权限、消息和变更来源夹具，不包含 SQL 或头像字节。

一千连接、四个作者、丰富元数据及一次续期先通过（28.696 秒）。扩大到一万连接、两个
作者时，原 16 MiB 确认预算耗尽，虽然资料全部送达，热历史仍新增 956 次接收者读取。
日志为 `/tmp/im-author-network-multi10000-01.log`。按一万连接、每连接八个作者及当前每键
944 字节的保守计费，完整记忆约需 72 MiB，因此默认预算调整为 96 MiB，配置硬上限为
128 MiB。单连接兴趣仍上限 128 键；预算不足只降低去重率，不能跳过授权或丢失拒绝。
小预算回归验证未记忆作者会再次发送，拒绝结果仍覆盖全部作者。调整预算后的双作者
复跑热历史新增读取为 0，确认计费 18,880,000 字节。这些是状态预算，不是进程 RSS。

多作者也暴露了调度和编码开销：仅靠每 100 ms 的变更轮询重试，128 个待处理键形成了
约每秒 1,280 键的准入上限。现在读取/写入/确认推进时会按空闲容量补充可见需求；每次
扫描有界，原待处理、读取、写入和输出字节上限保留，来源轮询继续承担恢复职责。新增
一键队列测试验证不调用轮询也能推进被拒绝准入的可见作者。原权限竞态测试改为允许及时
重读，同时继续断言旧读取被丢弃、版本下限生效以及其他房间不被刷新。

正常批次先整体检查大小，不再逐作者重复编码所有前缀；超大能力仍生成有界部分结果。
同一读取批次最多暂存 100 个完整内容比较结果，复用指纹及计费计算；复用前比较公开资料、
权限版本、群昵称、私人备注和稳定头像事实，不共享接收者许可。16 类字段变化、跨账号
备注隔离、URL 轮换和批次内存上限均有回归。CPU 诊断采样
`/tmp/im-author-eight-cpu.sample` 进一步确认重复 JSON 编码开销；Core 现在复用构造时已经
完成大小检查的不可变编码字节，相等性只比较协议字段。客户端 inbox 将已解码值交给原
接收状态机，保留连接、页面、序号和单调期限校验，不再重复解码同一帧。

当前源码的 Core 聚焦 18 项 / 7 个 suite、ClientKit 聚焦 99 项 / 7 个 suite、服务端聚焦
101 项 / 12 个 suite 全部通过。日志分别为 `/tmp/im-author-multi-core-01.log`、
`/tmp/im-author-multi-client-01.log`、`/tmp/im-author-multi-dispatch-regression-05.log`。
此前八作者万人复跑仍曾因初始同步耗时接近页面期限而在随后的变更阶段超时；失败记录
保留于 `/tmp/im-author-network-eight10000-01.log` 与 `-02.log`，不能列为容量通过证据。

编解码调整后的八作者万人场景首次通过（`/tmp/im-author-network-eight10000-03.log`，
60.264 秒）：首次全部应用 20.903 秒，单作者变更全部确认 6.892 秒，一次页面续期及其热
历史 21.785 秒；首次与续期后的热历史额外读取均为 0。累计接收者读取 31,200 次、键读取
172,068 次、批量读取 2,954 次；不可变源实际加载 9 个作者版本键。确认预算计费峰值
75,520,000 字节，200 ms 采样的待处理峰值 128 键 / 59,392 字节、输出 222,232 字节，
读写各最多 4。初次准入拒绝及重试拒绝共 109,562 次，过期作业 339 次，由可见兴趣恢复。
这是同一台机器上的 Debug 客户端与服务端测试，初始延迟仍高、页面期限余量较小；不能
据此声称生产性能达标，也不能用预算采样替代实际进程内存测量。

随后同一源码完成八作者、万人连接、连续三轮页面续期（105.477 秒通过）：首次全部应用
19.794 秒，变更确认 6.878 秒，各轮续期及热历史为 20.922 / 21.777 / 21.533 秒。每轮
10,000 个连接均确认全部八个作者并完成历史读取，四次热历史的额外资料读取全部为 0；
旧展示许可在续期开始及收到新资料时仍有效。累计 52,328 次接收者读取、333,724 个键读取、
5,784 个读取批次，不可变源仍只加载 9 个版本键。200 ms 采样预算峰值与上一轮一致；
准入拒绝 202,495 次、过期作业 643 次最终由兴趣刷新恢复。压测页面由测试客户端驱动，
尚未替代真实 ClientKit 页面协调器的容量及抖动验收。

```sh
IMV2_RUN_AUTHOR_NETWORK_BENCHMARK=1 IMV2_AUTHOR_NETWORK_CONNECTIONS=10000 IMV2_AUTHOR_NETWORK_AUTHORS=8 IMV2_AUTHOR_NETWORK_RICH_METADATA=1 IMV2_AUTHOR_NETWORK_RENEWALS=3 swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel --filter V2AuthorPresentationNetworkBenchmarkTests
```

日志为 `/tmp/im-author-network-eight10000-renew3.log`。所有本轮测试句柄均已收集退出结果，
测试自行关闭 TLS 连接、监听器、runtime 与 event loop；本轮未启动 PostgreSQL、VM 或模拟器。

本轮改动后的 Linux 构建/运行与 App 完整回归仍需执行，上一节产物不覆盖这次源码。
多网关、混合慢连接、真实 SQL 与头像字节的万人链路、旧路径清理和整体验收继续保留，
功能默认关闭。

## 个人同步与房间日志边界收敛

2026-10-31，客户端个人增量和个人快照入口统一拒绝 `message`、`message_reaction`、
`group_capability`、`moderation` 四类公共投影，与服务端个人投影 worker 的边界一致。
个人快照不再接受公共消息或群能力项；激活时仍验证并保留当前有权访问的本地房间日志、
效果记录、资源索引和搜索重建任务。不能通过把旧测试夹具重新接回生产入口恢复兼容性。

个人快照补齐 `own_read_watermark` 实体键处理，与服务端小写 UUID 合同一致；测试覆盖
大小写载荷、激活前不可见及重启后保留。资源目录 POST 查询登记为独立授权读取，补齐
目录客户端和对象下载请求构造器的网络入口登记。33 项 / 8 个 suite 聚焦回归通过
（10.238 秒，`/tmp/im-personal-boundary-migration-04.log`）。

公共消息的附件、转发、收藏关联、时间线、会话摘要、群容量类型、成员角色及管理状态
测试改用显式房间日志；个人同步确认、响应丢失和快照恢复测试使用个人备注失效记录。
成员记录的版本损坏继续验证增量事务回滚；历史传输位置的损坏在本地快照保留阶段验证，
不再构造已废弃的个人流公共重投。个人重置保留独立房间游标，冲突重放不能恢复已移除成员。

全量诊断还暴露群头像自动恢复的真实时间精度问题：Foundation Date 经 Unix 秒存储往返
可能向上舍入约 0.1 微秒，导致 SQL 已选出的到期记录又被引擎或认领逻辑拒绝。固定舍入
边界的两个恢复结果在修复前稳定失败（`/tmp/im-avatar-retry-precision-red.log`）；两处
比较现统一使用持久化的 Unix 秒域。恢复、冷却期限、成员历史、管理状态及上述同步场景
44 项 / 5 个 suite 通过（17.720 秒，`/tmp/im-personal-boundary-migration-08.log`）。

中间测试的编译错误、旧夹具及断言修正记录保留于 `migration-05`、`-06`、`-07` 日志，
不能列为通过结果。此前 ClientKit 全量诊断为 1,465 项 / 224 个 suite、318 个 issue；
其中大量 SyncEngine 测试仍使用被移除的公共个人流和公共个人快照合同。随后整包复查
运行 1,467 项 / 224 个 suite（200.613 秒，`/tmp/im-personal-boundary-client-full-02.log`），
仍有 54 个测试、240 个 issue，全部位于 `V2SyncEngineTests`；其他 suite 未报告失败。
该结果是继续迁移夹具前的诊断，不能称为整包通过。整包回归与旧路径清理尚未完成。
随后迁移消息页原子回滚、整数边界、个人重置保留撤回/反应、可用性驱动同步与重启重放，
12 项聚焦通过（1.890 秒，`/tmp/im-personal-boundary-migration-10.log`）。又迁移撤回后
会话摘要回退、撤回清除反应、管理员删除和编辑等六个场景。当前 SyncEngine 整个 suite
复查 145 项（61.869 秒，`/tmp/im-personal-boundary-sync-full-03.log`），上述新增迁移均
通过，剩余 36 个测试、213 个 issue；主要为旧跨流效果与公共快照夹具。逐测试诊断清单
保留于 `/tmp/im-personal-boundary-sync-remaining.json`，后续必须继续迁移并核查错误，
不能降低生产入口的拒绝规则以使旧夹具通过。全部已启动测试句柄均已收集终态。

前述万人测试的 SQL、真实页面协调器、
多网关、慢连接及头像字节验证缺口继续保留，功能仍默认关闭。

## 房间来源校验与恢复回归收敛

继续按单一房间日志基线迁移测试，没有恢复个人流或个人快照接收公共消息的能力。
个人快照仅导入成员资格等个人状态；消息、反应、公告、角色权限和置顶状态来自房间日志，
在激活个人快照时保留仍获准房间的本地内容。测试显式构造本地 staging 表损坏时，
从本地表复制后再注入错误，不把公共状态伪装成快照网络输入。

这轮发现并修复的生产边界如下：

- 已接受消息的正文序号必须匹配房间日志外层；禁言、冻结和解冻同时验证房间与序号。
- 房间入口统一检查正文房间，防止反应等事件推进 A 房间游标却写入 B 房间投影。
  只属于查看者的 `timeline_activity` 继续走个人流，房间日志拒绝该类型。
- 公告、角色权限和置顶效果的来源位置必须确定。正文省略序号时使用已验证的房间外层；
  正文提供序号时必须一致。去除这些增量 reducer 的空序号补全兼容分支，重复来源不能改变位置。
- 操作恢复指标测试改为等待可观察的完成结果并设置时间上限，避免固定 `Task.yield()`
  次数用尽后提前停止 dispatcher，造成与实际业务断言无关的取消竞态。

验证过程和范围：

- `/tmp/im-room-envelope-red.log` 复现消息及三类 moderation 的正文/外层不一致；
  `/tmp/im-room-envelope-green-04.log` 又暴露公告和角色权限保存空来源序号的问题。
- 修复后 `/tmp/im-room-envelope-green-05.log`：96 个测试、12 个套件通过，17.341 秒。
- `/tmp/im-personal-boundary-sync-migrate-11.log`：10 个同步恢复测试通过，3.180 秒。
- `/tmp/im-personal-boundary-sync-migrate-12.log`：7 个测试中仅旧的角色行数量断言失败；
  新夹具按房间顺序接收第 8 版角色事实，合法保留该行，断言已改为验证保存版本确为 8。
- `/tmp/im-room-reaction-envelope-red.log`：反应跨房间的新增用例真实失败，
  说明原入口未拒绝正文房间不一致；统一房间校验随后补齐。
- `/tmp/im-personal-boundary-sync-full-04.log`：147 个测试、2 个套件运行 106.533 秒，
  剩余 10 个测试、36 个 issue，均来自尚未迁移的公共快照或置顶跨流夹具。
  当次逐测试清单在 `/tmp/im-personal-boundary-sync-remaining-04.json`。
- 随后迁移全部剩余夹具，删除公共消息快照构造器及未知序号置顶兼容路径；撤回重放、
  标准/大群置顶保留、导入期间新房间事件和撤权清理继续经过实际持久化入口验证。
  `/tmp/im-personal-boundary-sync-full-05.log` 运行 147 个测试、2 个套件，112.504 秒，
  只剩成员角色测试以小写字符串查询规范 UUID 的一处断言失败；已改为使用 `UserID`
  的规范值。这个中间结果仍不列为全量通过。

随后收集 ClientKit 全包回归终态：`/tmp/im-personal-boundary-client-full-03.log`，
1,469 个测试、225 个套件全部通过，253.532 秒。公共个人流/快照夹具迁移及房间来源校验
已经通过本轮完整 ClientKit 回归；该结果不替代 App、Linux 及多网关/真实数据库/头像字节的最终验收。

## 多网关运行时与真实慢连接

2026-10-31，扩展同一个 TLS 容量测试，增加显式开关
`IMV2_RUN_AUTHOR_MULTI_GATEWAY_BENCHMARK=1`。每个节点拥有独立 runtime、dispatcher、
资料缓存、连接注册表、监听 socket 和 event loop；共享的只有确定性资料/变更源。
客户端先完成全部连接，再集中发布可见作者。建连最多同时保留 128 个未完成握手，
这不是建连风暴或内核 accept 队列容量测试。

慢连接在应用初始资料后暂停实际 socket 读取，并发送 8 个有界历史请求。每个响应约
48 KB，经真实 Gateway、协议编码和 TLS 写出。测试必须观察所有目标 server channel
不可写才推进资料版本；没有把延迟 ACK 或替换 send 回调视作 TCP 背压证据。
慢连接阻塞期间，其他连接仍须完成第二版资料与新的历史页请求；恢复读取后所有连接
必须应用第二版及随后第三版资料。每个节点还分别核对暖历史零额外资料读取、独立变更
消费、公共内容源加载次数和队列/任务/字节采样上限。

本轮实际结果：

| 场景 | 结果 |
| --- | --- |
| 2 个节点、40 个连接、8 个作者、4 个真实阻塞 socket | 通过，1.693 秒；日志 `/tmp/im-author-multi-gateway-smoke-02.log` |
| 2 个节点、10,000 个连接、8 个作者、100 个真实阻塞 socket | 通过，29.600 秒；日志 `/tmp/im-author-multi-gateway-10000-02.log` |
| 同样万人配置，增加阻塞期间 9,900 个正常连接的历史页读取 | 通过，32.221 秒；日志 `/tmp/im-author-multi-gateway-10000-03.log` |

最后一轮初始资料全部应用用时 13.539 秒；100 个 socket 保持不可写时，其余 9,900 个
连接在 3.867 秒内全部完成资料更新与历史读取。恢复 socket 读取后，全部第二版确认
用时 1.135 秒，第三版也全部确认。每个节点仅加载 10 份公共作者版本（8 个初始版本及
2 个新版本），暖历史没有额外资料读取。

每个节点采样峰值：pending 128 键 / 59,392 字节，输出分别为 209,020 / 222,224 字节，
确认提示各 37,760,000 字节，读取与写出任务各不超过 4。两节点分别记录 26,379 / 27,097
次准入拒绝和 2,393 / 1,795 次到期工作，最终所有可见需求均恢复。采样不是未采到峰值的
分配证明；硬边界继续由生产准入及其专项测试约束。

中间失败保留：`smoke-01` 的单个历史响应未建立预期背压，后改为有界突发并要求实际
不可写；`10000-01` 在建连阶段收到连接重置，之后将建立连接与资料突发分开，未把该次
结果算作资料分发通过。每次容量运行实际执行一个受开关选择的测试，另一个容量模式跳过。

提取共享变更源后，原单网关模式另以 200 个连接、8 个作者及一次页面续期复查通过，
25.023 秒（`/tmp/im-author-single-renew-regression-01.log`）。续期后 200 个连接全部应用并
完成历史读取，暖历史额外资料读取为 0，公共源仅加载 9 个版本；这项是夹具重构回归，
不新增容量承诺。

以上节点运行在同一测试进程，身份/权限/持久变更仍为夹具；没有真实 SQL、真实 ClientKit
页面协调器或头像字节下载。不能据此宣称多进程部署、建连风暴、生产 CDN 或完整万人链路
已经验收。原完成条件继续保留，功能默认关闭。

```sh
IMV2_RUN_AUTHOR_MULTI_GATEWAY_BENCHMARK=1 IMV2_AUTHOR_NETWORK_CONNECTIONS=10000 IMV2_AUTHOR_NETWORK_GATEWAYS=2 IMV2_AUTHOR_NETWORK_SLOW_PER_GATEWAY=50 IMV2_AUTHOR_NETWORK_AUTHORS=8 swift test --disable-automatic-resolution --package-path IMV2Server --jobs 4 --no-parallel --filter V2AuthorPresentationNetworkBenchmarkTests
```

## App 全目标回归与基线差异

2026-10-31，在本轮独立创建的 iPhone 17 / iOS 27.0 模拟器运行整个 `IMAppTests` target。
第一次执行 512 个测试、65 个套件，71.524 秒，24 个 issue：公共消息仍从个人流写入的
旧夹具、无签名测试主机的 Keychain `-34018`，以及下载设置的默认类别断言。
证据为 `/tmp/im-author-full-app-01.log` 和 `/tmp/im-author-full-app-01.xcresult`。

四个 App 测试文件现显式通过房间日志准备公共消息，私人时间线活动和收藏继续通过
个人同步流提交。覆盖离线启动、过期凭据本地恢复、收藏/转发标签、混合深历史定位及
撤回的立即通知；没有恢复被移除的公共个人流入口。

随后使用本地模拟器签名（`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`）重跑整个
target，512 个测试、65 个套件，70.253 秒，只剩 1 个 issue。上述受影响场景、头像和
页面接线、真实 Keychain 测试均通过；没有修改工程的签名配置或 entitlements。
证据为 `/tmp/im-author-full-app-02.log` 和 `/tmp/im-author-full-app-02.xcresult`。

剩余失败是 `V2ResourceManagementStoreTests.downloadNetworkSettingsPersistAndFailedSaveLeavesConfirmedValues`：
默认自动下载类别为 `[]`，仅启用视频后得到 `[.video]`，旧断言却要求 `[.image, .video]`。
`git show HEAD` 同时确认生产默认值和该断言已存在于提交基线，两个文件均未因本轮工作修改。
按“不顺手修复无关测试”的约束保留此差异，不能把本次 App 全目标结果写成全部通过。
本轮独立模拟器在收集终态后关闭并删除；用户其他模拟器未操作。

## 当前客户端 schema 与资料导入清理

2026-10-31，移除 `V2LocalProfileDisplayJournal.load` 从无上下文 `v2_profile_views`
自动导入展示值的兼容分支、仅供该分支使用的构造器和导入标记表。恢复现在是纯读取，
展示事实只能来自已接受的上下文资料；清空后不会从其他资料表重新出现。已有新格式的
展示事实仍能重启恢复，拒绝、隐藏和晚到旧响应的栅栏继续保留。

主 SQLite schema 收敛到一次 `createCurrentV2Schema`：本地展示表与触发器直接建入，
图片尺寸列及完整约束直接定义在原件表中，不再追加三个升级 migration。没有给旧库
增加修复、回填或静默重建路径。真实建表检查得到 282 个 schema 对象，已审查新 DDL
并更新指纹；资源 schema 参考库使用同一份建表定义。

聚焦回归 65 项、8 个套件通过（6.061 秒，`/tmp/im-author-canonical-client-02.log`）。
覆盖作者页面/接收/协议、展示恢复与撤权、资源索引、新 schema、尺寸持久化与冻结发送。
尺寸约束直接使用 SQLite 验证单边 NULL、零值、边长及像素总量越界；异常资源 schema
重开必须拒绝，同时保留已有原件选择和摘要。首轮仅有旧指纹断言失败，读取实际 schema
确认差异后更新；未改变行为断言来绕过失败。

App 使用独立 iPhone 17 / iOS 27.0 模拟器、本地测试签名执行个人/群头像管线、离线
启动和会话展示四个套件：38 项通过，12.391 秒。证据为
`/tmp/im-author-canonical-app-01.log` 与 `/tmp/im-author-canonical-app-01.xcresult`。
该模拟器已关闭并删除；没有修改 App 工程签名设置。此聚焦复验不改变上节记录的
全 target 原有下载设置断言差异。

清理后 ClientKit 全量串行回归 1,469 项、225 个套件通过，280.110 秒，日志为
`/tmp/im-author-canonical-client-full-01.log`。随后重新构建当前原生服务端与客户端，使用
独立 PostgreSQL、两个 Actor 进程、HTTPS 资源入口和 TLS Gateway 复验，资源与作者必需
用例通过；实际执行 3 个 test 声明，其中账户偏好含 4 个参数场景，其余 11 个声明未启用。
实际套件耗时 11.069 秒，包含真实头像上传、处理、作者投递、字节读取及拉黑后拒绝，
数据库确认 1 个 ready 头像、2 个变体、1 条拉黑关系。

证据目录为 `/tmp/im-author-live-current-20261031-02`：`summary.json` 的
`clientExitCode=0`、`requiredTestPassed=true`，`owned-cleanup.json` 确认全部自有进程退出、
进程组排空、PostgreSQL 停止且失败数为 0。此复验未启用群头像、资源中心及 App UI 的
可选场景，也不代替真实万人 SQL/头像负载验收。

## 最新服务端 Linux 复核

2026-10-31，以固定 Swift 6.4.0/glibc x86_64 SDK 重新构建全部七个部署程序，
254.080 秒通过。产物目录为 `build/native-linux-release/runs/20261030T183500Z-a8315c7f`，
manifest 状态为 `verified-linux-release`，`sourceDrift` 为空。这份证据对应安全失效分离前的
服务端源码；分离后的最新构建见下方本轮记录。

同一产物在 Linux amd64 镜像内完成独立运行验证：七个可执行文件哈希、SDK 运行库和
动态依赖全部符合，真实 640×480 PNG 经 worker 生成 320×240 与 640×480 两档预览。
`runtime-verification.json` 状态为 `passed-linux-loader-and-worker`，网络关闭，
`serviceEndToEndTest` 为 `false`。不将加载与图片 worker 验证扩展为 Linux 数据库、
Actor 网络或万人业务链路验收。

日志：`/tmp/im-author-linux-release-20261031.log`、`/tmp/im-author-linux-image-20261031.log`、
`/tmp/im-author-linux-runtime-20261031.log`。复现：

```sh
python3 scripts/build_v2_linux_release.py --jobs 4
python3 scripts/verify_v2_linux_release.py build/native-linux-release/runs/20261030T183500Z-a8315c7f --docker-context colima-imv2-x86 --runtime-image im-author-linux-20261031:a8315c7f
```

验证命令前须按[构建指南](../guides/native-linux-release.md)将该产物重新打包为对应本地镜像。
验证产生的容器和本轮镜像已清理，本轮启动的 `imv2-x86` VM 已恢复停止状态；
清理日志为 `/tmp/im-author-linux-cleanup-20261031.log`。

## 普通资料广播退役与安全失效分离

2026-10-31，canonical schema 更新为 `im-v2-current-76`。公共发布表只保留发布序号、
来源事件、作者、资料版本和创建时刻；普通改名及头像绑定不再创建逐接收者工作。
各网关继续通过独立游标消费该日志，按当前可见作者重新核权和分发。发布日志按保留期
清理，不依赖消费者 claim/completed；过期缺口仍由现有 head 检测并重读可见集合。

新增 `profile_security_invalidation_outbox`，仅允许 hidden/suspended/deleted。
账号停用事务同时提交资料状态、公共变更和安全任务，任一写入失败都回滚。
[V2ProfileSecurityInvalidationWorker](../../IMV2Server/Sources/IMV2ServerInfrastructure/V2ProfileSecurityInvalidationWorker.swift)
取代旧 worker，仅向已有私聊对端写入 `profile_invalidation`；保留租约、分页预算、
投递后检查点、当前用户分片路由和幂等重放，不再复制名称或写入普通资料变更投影。
首次私聊身份的 `direct_room_profile` 仍由原房间建立流程生成，不属于此普通更新广播。

App 同步结束后的 `refreshPendingInvalidations` 调用及该仓库 API 已删除。持久安全失效
继续在本地事务中清理展示事实；新的资料请求由显式上下文需求发起。联系人主动补全保留，
不再因为同步活动而扫描不可见目标并自动请求。监控改为资料安全失效积压，控制面维护
将公共日志和已完成安全任务分别分配预算；未完成安全任务不随公共日志过期删除。

本轮验证包括：普通改名不创建安全任务/个人日志，真实停用后的失效投递和中断恢复，
两条 outbox 任一写入失败的整事务回滚，投递到迁移后的当前用户分片，计数/时间边界，
公共日志清理不删除未完成安全任务，以及 canonical schema 的字段、约束和索引漂移拒绝。
聚焦真实 PostgreSQL 回归 35 项、4 个套件通过（67.203 秒）；另补跑真实持久工作指标与
资料修订上界 2 项、1 个套件（其中修订上界含 12 个参数场景），10.590 秒通过。
日志为 `/tmp/im-author-security-pg-03.log` 和 `/tmp/im-author-security-metrics-01.log`。
首轮新增漂移场景暴露启动校验缺口，补齐后已复验通过；第二轮剩余的跨分片重放断言
仍多算已删除的普通资料投影，改为与重放前实际记录数量比较后通过，未放宽幂等要求。

ClientKit 资料相关 15 项、3 个套件通过（2.094 秒，`/tmp/im-author-security-client-01.log`）。
App 在独立 iPhone 17 / iOS 27.0 模拟器运行个人/群头像、离线启动与会话展示 38 项、
4 个套件通过（12.313 秒），证据为 `/tmp/im-author-security-app-01.log` 和同名 `.xcresult`。
本轮模拟器已删除，独立 PostgreSQL 的九个测试库及 schema probe 已清理，实例已停止；
`/tmp/im-author-security-pg-cleanup.json` 保存清理结果。

Schema 76 空库新建、导出恢复、字段/约束/函数漂移与就绪覆盖检查通过，日志为
`/tmp/im-author-security-schema-01.log`。关系 176、索引 376 与实际创建目录一致。
当前源码七个 Linux 部署程序重新构建通过（41.646 秒），产物目录为
`build/native-linux-release/runs/20261030T190754Z-5cf435eb`，`sourceDrift=[]`。
该批产物的 Linux loader/worker 复验已在下一节完成，不继承前一批产物的运行验收。
前一轮 `20261030T190312Z-62756f31` 因构建期间修正服务端测试文件被漂移检查拒绝，
状态为 failed，不作为发布证据。

当前原生服务链路复验 `/tmp/im-author-security-live-01` 通过：实际执行 3 个 test 声明，
其中账户偏好含 4 个参数场景，其余 11 个可选声明跳过；11.457 秒。真实头像上传、处理、
作者补充、字节下载与拉黑拒绝通过，`requiredTestPassed=true`，自有服务/进程组和数据库
全部退出。普通修改的零私有广播与停用失效的精确行为以本节真实 PostgreSQL 用例为证，
不将这个小规模真实链路称作万人验收。

扩展真实链路 `/tmp/im-author-security-live-extended-02` 也通过：14 个声明中实际执行
12 个（账户偏好含 4 个参数场景），只跳过大昵称目录与慢上传，套件耗时 24.189 秒。
包含真实 Operator 停用/幂等重放、关闭已经认证的 TLS 连接、HTTP 会话退出及再次登录
与 TLS 认证拒绝；群头像上传/移除、群操作和关系恢复也执行通过。摘要确认
`clientExitCode=0`、`requiredTestPassed=true`、`groupAvatarPassed=true`，全部自有进程组
和 PostgreSQL 已清理。首轮扩展运行在 Operator 启动前失败，原因是验收脚本仍删除其
Actor 配置；脚本现生成独立 Operator caller 身份并接入当前策略 owner，不借用账号或
网关进程的身份。没有修改 Operator 的生产授权逻辑。

协议生成物、模块/Actor 序列化边界、文档结构/链接与 diff 空白检查通过。静态 Actor
文件清单仍有三个提交基线已经不存在的引用：`V2RoomActivationLeaseStore.swift`、
`PostgresV2RoomActivationStore.swift`、`PostgresV2RoomActivationTests.swift`；本轮只更新了
资料 worker 的重命名，没有改动这三个引用或其对应代码，不能把该清单门禁记为通过。

客户端失效载荷的可选状态/active 默认解码及对应乱序、快照问题已在下一节处理。
万人真实 SQL、头像分发与真实 ClientKit 协调器的组合容量仍未完成。

## 客户端安全失效版本与快照恢复

2026-10-31：删除失效载荷的可选状态和 `active` 默认值，客户端解析与 canonical SQLite
约束只接受 `hidden`、`suspended`、`deleted`。非法或缺失状态不能推进同步游标。

先在真实 SQLite 上复现了三个问题（`/tmp/im-author-client-security-repro-01.log`）：
迟到的旧失效删除了较新的私聊身份；没有 unscoped profile 缓存时，较新的展示名称仍被
触发器删除；快照换表未执行触发器，激活后仍可读到失效前的名称。

修正后安全版本下限持续保存，不因新资料、不可用结果或缓存清理而丢失。活动资料必须
严格高于该下限；迟到的身份投影不能越过下限恢复房间访问。本地展示行保存整数资料修订，
实时失效只删除不高于下限的行。展示读取关联当前失效表，在同一个读取事务中处理快照
原子切换，因此无需在 ACK 后扫描清理。准备快照时保留已有的更高安全下限，工作仍在
ACK 前完成；准备与激活之间接受的较新展示不会被旧快照失效遮蔽。

规范 SQLite 仍为 282 个 schema 对象；核对真实新建 DDL 后，当前指纹更新为
`0x3b50fc2200c895b6`。没有追加兼容迁移、旧载荷回退或自动资料补查。
聚焦回归 25 项、5 个套件通过（3.404 秒，`/tmp/im-author-client-security-03.log`），
包含非法协议、乱序、快照、真实存储类型异常和新 schema 约束。
另补充了快照准备后新读取、空快照保留下限及重启后拒绝旧响应的回归。ClientKit 完整
常规套件报告 1475 项、226 个套件通过（283.857 秒，
`/tmp/im-author-client-security-full-01.log`）；需要显式环境的真实服务测试不由本次常规
运行替代，其独立运行证据仍见上一节。

App 聚焦回归 38 项、4 个套件通过（12.428 秒），证据为
`/tmp/im-author-client-security-app-01.log` 与同名 `.xcresult`。独立 iPhone 17 / iOS 27.0
模拟器已关闭并删除，`/tmp/im-author-client-security-app-cleanup.json` 确认实例不存在。

该轮七个 Linux 部署程序的镜像内哈希、运行库和 loader 检查通过；图片 worker 在禁网
容器内实际把 640×480 PNG 处理为 320×240、640×480 两档，输出尺寸验证通过。
对应产物 `build/native-linux-release/runs/20261030T190754Z-5cf435eb` 的
`runtime-verification.json` 状态为 `passed-linux-loader-and-worker`；日志为
`/tmp/im-author-security-linux-runtime-03.log`。这是产物运行验证，`serviceEndToEndTest=false`，
不替代服务端真实链路或万人容量验收。

本轮验收容器已退出、临时镜像已删除，原先停止的 `imv2-x86` 虚拟机已恢复停止状态；
`/tmp/im-author-security-linux-runtime-cleanup-03.json` 保存清理结果。文档结构、链接和
diff 空白检查通过。未修改用户在 `V2RootView.swift` 的既有改动。

## 真实 ClientKit 冷启动与容量分层证据

2026-10-31：新增 `verify_v2_live_resource_authors.py --author-capacity N`，使用自建
PostgreSQL、真实 Account/Gateway/Actor 进程、TLS 1.3 与 ClientKit 的资料仓库、房间及
页面协调器。只有初始成员/设备/令牌人口由隔离 fixture 填充，连接之后走生产认证、
SQL 授权、消息历史、资料变更与签名字节下载；不把账户注册吞吐计入此验收。
PostgreSQL `pg_stat_statements` 分开计量公共资料源行和控制授权批次，客户端单独计量
发起的 HTTP 查询。取消请求的代理响应可能晚到，不能把晚到响应误算作下一阶段的新请求。

首次 32 人运行发现页面等待作者推送时，普通 32 ms 合并窗口已经发出 HTTP 查询。
资料仓库现给声明等待作者通道的需求一个固定的 2 秒加最多 500 ms 抖动期限；页面协调器
在等待房间订阅前登记该意图。推送成功直接满足需求；未收到推送仍按期限回退，续期和
重连不重置期限。独立页面的普通查询及明确刷新下载计划可以提前合批，不等待这段期限。
相关三项回归覆盖推送胜出、通道缺失和普通查询抢占；不是通过删除 HTTP 计数来获得零请求。

| 实际参加者 | 冷资料阶段 | 冷阶段资料 HTTP | 公共源读取行 | 后续结果 |
| --- | --- | --- | --- | --- |
| 100 | 0.217 秒 | 0 | 1 | 全部收到消息/历史；无新消息改名全部更新；100 次独立授权下载通过 |
| 1,000 | 1.209 秒 | 0 | 1 | 全部收到消息/历史；无新消息改名全部更新；1,000 次独立授权下载通过 |

对应证据目录为 `/tmp/im-author-real-capacity-100-01` 和
`/tmp/im-author-real-capacity-1000-01`。冷阶段不含之前的连接认证时间；热消息阶段没有
新增客户端资料 HTTP 或公共资料源行，改名阶段各增加一行公共资料源读取。头像使用
64×64 PNG 验证实际下载和解码，不代表真实图片大小的带宽或 CDN 验收。

两次 10,000 人尝试均在连接建立阶段超时，未进入资料冷阶段。随后三次 2,000 人诊断
在同一位置复现，证据为 `/tmp/im-author-real-capacity-2000-01` 至 `-03`：最后一批
1,376 个连接开始 TLS，其中 1,375 个完成 TLS、Hello 和认证，余下一个在 TLS 就绪前超时。
第三次运行证书校验最大约 50 ms，PostgreSQL 认证累计执行约几十毫秒，采样中的认证
后初始化已完成，数据库等待队列没有积压。固定 IPv4 并保留 localhost 的 TLS 名称和
证书校验也未改变结果。当前证据尚不能区分客户端 Network.framework 大量连接行为、
系统传输与服务器握手之间的根因，不能据此宣布服务端或客户端容量上限。

验收器现在持续保存脱敏的阶段计数、SQL 执行量/等待及网关运行指标；不记录令牌、
签名 URL、用户身份或帧载荷。上述所有自建服务、进程组和 PostgreSQL 都已清理。
万人真实资料分发、多进程 Gateway、故障恢复及慢连接的组合验收仍未完成，默认开关保持关闭。

当前 ClientKit 完整常规回归报告 1,479 项、227 个套件通过（260.218 秒，
`/tmp/im-author-capacity-client-full-01.log`）；显式启用的真实服务套件在此常规运行中跳过，
实际容量结果以上面的独立运行记录为准。App 聚焦 38 项、4 个套件通过（12.439 秒，
`/tmp/im-author-capacity-app-01.log` 及同名 `.xcresult`）；自建模拟器已删除，清理证据为
`/tmp/im-author-capacity-app-cleanup.json`。未修改用户的 `V2RootView.swift` 既有改动。

### 多客户端进程与真实冷启动请求放大

后续加入 `--author-client-processes P`：先编译一次 Swift Testing bundle，再用独立
测试进程各自持有不重叠的用户、设备和 TLS 连接。所有进程观察同一房间、同一作者，
由隔离 fixture 对认证、冷资料、热消息、无消息改名和字节下载设置全局阶段屏障；
不把多个互不相关的小群测试相加。实际服务端仍只有一个 Gateway 进程。

64 人 / 2 进程通过（`/tmp/im-author-capacity-64-p2-03`）：冷资料约 0.39 秒、
资料 HTTP 为 0、公共源一行，后续消息、改名及 64 次授权头像下载通过。
2,000 人 / 4 进程可在约 10 秒完成真实认证，因而越过了此前单客户端进程的握手停顿。
但 `/tmp/im-author-capacity-2000-p4-02` 的功能通过不能作为容量通过：冷资料约 13 秒，
实际产生 1,973 次客户端资料 HTTP。新增 `cold.httpAttempts == 0` 的严格验收断言后，
`-03` 和 `-04` 都明确失败；热消息阶段无额外 HTTP 不能掩盖冷阶段放大。

验收 fixture 的 TLS 握手已移到各连接工作线程，避免串行 accept 在 HTTP 回退突发时
制造额外握手故障；证书验证和 TLS 1.3 要求保留。新增仅含固定聚合数值的内部
`/metrics/authors`，观察积压、在读批次、投递、过期及拒绝，不触发资料查询或输出身份。
指标路由 6 项回归通过（`/tmp/im-author-capacity-metrics-01.log`）。

`-04` 暴露真实预算传递缺口：投递任务预算为 500 毫秒，底层资料服务却重新取得 10 秒。
先以两种调用截止时间的回归复现（`/tmp/im-author-capacity-deadline-red-01.log`），再让
调用方截止时间贯穿批量资料服务、控制读取和房间权限读取；过期请求在准入前拒绝。
相关 32 项、4 个套件通过（2.179 秒，`/tmp/im-author-capacity-deadline-green-01.log`）。
修复后的 `-05` 仍未通过真实 2,000 人冷启动，出现 HTTP 回退和 `staleResponse`，不能
宣称预算修复解决了容量问题。上述运行均已清理自建进程组和 PostgreSQL。

以上容量运行使用 Debug 构建。验收器新增显式 `--configuration release`，同时选择服务端
与 ClientKit 的优化构建并记录到证据摘要；不改变预算或冷阶段零 HTTP 断言。
新的指标和预算传递代码尚未经过 Linux 产物重建，上文 Linux 记录仅对应此前代码状态。

Release 服务端使用优化构建；ClientKit 测试同样保留优化，并显式启用 `-enable-testing`
以使用既有内部测试 fixture。64 人 / 4 进程完整通过（1.989 秒，
`/tmp/im-author-capacity-64-p4-release-01`），冷资料 HTTP 为 0，公共源一行，64 次下载完成。
2,000 人 / 4 进程的两次 Release 运行冷阶段均约 1.2 秒、HTTP 为 0、公共源一行；
消息/历史和无消息改名也完成。证据为 `/tmp/im-author-capacity-2000-p4-release-02` 和 `-03`。

这两次运行仍不是完整通过：`-02` 在 900 秒测试总期限内只完成 1,106 次头像下载，
随后超时；`-03` 增加聚合下载代理耗时，观察到已抵达代理的请求快速完成，主要等待发生在
抵达代理前。为比较客户端进程拓扑而主动中断 `-03`，不把中断当作通过，也不扩大超时。
这部分结果不能支持服务端字节容量上限或客户端根因的结论。各运行的自建进程组与
PostgreSQL 已清理，完整万人验收仍未完成。

后续源代码审计找到了期限混用：原生房间 pin 把请求截止与授权证明到期合成一个时间，
将 500 毫秒传播修复后，成功下发的资料也只剩不到 500 毫秒许可。无消息时页面约每 25 秒
重新订阅，下载前对有效快照的等待因此不能代表 HTTP 服务端吞吐。
`/tmp/im-author-pin-budget-red-01.log` 通过真实 Host 的原生 pin 复现两者完全相等。
现在 pin 明确返回工作截止和授权有效期；SQL 使用工作截止，证明仍受已捕获节点资格与
30 秒上限限制，返回前的退休校验、取消和排空保持不变。反向回归还验证授权未到期时，
超时工作仍必须失败。相关 67 项、6 个套件通过（`/tmp/im-author-pin-budget-green-01.log`）。

真实数据库扩大回归还发现旧 cohort 测试期待无版本 `.notVisible`，已改为核对空目标、
空昵称、正确房间/接收者及权限版本；并在一秒工作预算下验证证明保留独立有效期。
权限事实测试复用既有无合批等待入口，避免把 5 毫秒调度窗口混入权限语义断言；生产
合批预算未变，其取消、过载和真实 SQL 合批测试仍独立执行。
修正后的 52 项、6 个套件通过（9.267 秒，`/tmp/im-author-pin-budget-postgres-02/tests.log`）；
九个隔离数据库已删除，自建 PostgreSQL 已停止，清理结果保存在该目录的 `cleanup.json`。
模块边界、Actor 序列化边界、文档结构/链接检查通过；虚拟 Actor 文件清单仍报告此前已知的
三个缺失路径，未据此宣称所有工程门禁通过。

期限分离后，`/tmp/im-author-capacity-2000-p4-release-04` 完整通过：同一房间、同一 Gateway、
2,000 个真实用户/设备分布在四个 ClientKit 进程，四份测试均成功退出，约 16.5 秒完成全部阶段。
各进程冷资料阶段约 1.21–1.67 秒、客户端资料 HTTP 为 0、公共源一行、控制查询 112 批；热消息和历史
不新增资料 HTTP 或公共源行。无新消息改名全部更新，公共源再读一行；2,000 次独立授权头像
下载、内容校验与解码全部完成。全程资料 HTTP 为 0，完成字节阶段时控制查询为 199 批，
包含后续排空工作的最终摘要为 214 批。
自建客户端、服务进程组和 PostgreSQL 已清理。该结果是 2,000 人单 Gateway 的本地 Release
证据，仍不能代替万人、多 Gateway 进程、故障/慢连接组合与生产 CDN 验收。

随后 `/tmp/im-author-capacity-10000-p10-release-01` 建立并认证全部 10,000 个真实连接，
但单 Gateway 冷资料阶段失败，未进入热消息或头像下载验收。七个留下失败计数的客户端
进程已报告合计 6,221 次资料 HTTP 尝试（不是全体精确总数），代理记录 2,666 个已完成
资料响应，并出现 `.overloaded`。自建进程组与 PostgreSQL 均已清理；默认开关继续关闭。
后续按原方案验证多 Gateway 进程分担，不以延长客户端等待或放宽冷资料断言替代容量工作。

验收器新增 `--author-gateway-processes`，启动独立 Gateway/Actor 进程及各自 TLS、节点配置和
指标 listener；客户端进程分配记录在 `capacity-topology.json`。各节点共享同一个真实群及
PostgreSQL 权威数据，逐节点指标保留并聚合，不以同进程多个 Runtime 冒充多个网关。
`/tmp/im-author-capacity-128-p4-g2-release-01` 的 128 人 / 四个客户端进程 / 两个 Gateway
完整通过：冷资料 HTTP 为 0、公共源两行；热消息不新增资料 HTTP 或公共源行；无消息改名
公共源再读两行，128 次授权头像下载通过。所有自建进程组及 PostgreSQL 已清理。

`/tmp/im-author-capacity-10000-p12-g4-release-01` 随后使用十二个 ClientKit 进程和四个独立
Gateway/Actor 进程，全部 10,000 个用户完成真实认证，每个网关 2,500 个连接。冷资料阶段仍
因 `.overloaded` 失败；十一份失败计数合计至少 2,079 次客户端资料 HTTP 尝试，代理只记录
154 个已完成响应（133 个 200、21 个 429），二者统计口径不同，不能互相替代。最终数据库
统计为公共源五行、控制查询 428 批。只有认证阶段完成全局屏障，热消息、无消息变化及
头像字节阶段均未验收。76.3 秒的聚合采样仍有全部连接，显示 8 个在读批次、8,604 次拒绝
和 1,073 个过期任务；这些数据不足以断言是数据库、CPU 调度或短授权期限的单一根因。
所有自建客户端、服务进程组和 PostgreSQL 已清理。四网关小规模通过不能替代这次失败；
默认开关仍关闭，完整万人容量条件继续未满足。

后续为资料读取增加固定基数的阶段耗时、失败和结果计数，并在容量进程退出前抓取一次
仍存活网关的最终指标，避免两秒内的冷突发落在五秒采样间隔中。指标仅记录聚合值，不含
身份、请求、URL 或错误文本；15 项诊断及相关服务回归通过。
`/tmp/im-author-capacity-10000-p12-g4-release-02` 再次使用同一万人/十二客户端进程/四网关
拓扑，仍在冷资料阶段失败。十二份客户端失败计数共报告至少 9,361 次 HTTP 尝试；最终
网关指标记录房间授权过载 1,914 次、超时 2,397 次，三轮控制读取分别失败 29、47、4 次。
这支持继续检查房间调用并发和控制读取预算，不支持将故障归因于单一数据库查询。
此轮清理先报告 Darwin 进程组 EPERM，随后独立检查所有自建 PID 和 PGID 均已消失，
结果保存为 `cleanup-followup.json`；原失败记录没有改写，PostgreSQL 已停止。

房间权限读取原先每批一次启动最多 100 个 RPC，多网关读取窗口可同时汇聚到同一房间。
新增暂停实际调用的回归先复现全部调用并行和取消时已启动过多请求，记录为
`/tmp/im-author-room-window-red-01.log`。现在每批保留完整 100 个接收者，但最多同时执行
16 个房间调用，实际完成后补入下一项；取消或原截止时间到达后不再启动剩余 I/O。
500 毫秒投递预算、客户端冷阶段零 HTTP 断言与房间权限规则均未放宽。
24 项、4 个套件通过（`/tmp/im-author-room-window-green-01.log`）；真实 PostgreSQL
56 项、7 个套件通过（9.466 秒，`/tmp/im-author-room-window-postgres-01/tests.log`），
九个隔离数据库已删除，自建实例及临时目录已清理。此并发窗口仍需真实容量复测证明效果。

另确认多节点资格证明最多约 20 秒，而客户端仅按 30 秒视图截止续期，会遗漏更早到期的
展示许可。两秒许可的回归先失败（`/tmp/im-author-short-grant-red-01.log`）。现在仅将
已应用并确认的资料许可截止用于提前续订；未观察的短期候选不能触发整个账号视图重启。
每个视图只拥有一个可提前的睡眠任务，取消时等待它结束；原许可不延长，旧接收及停止
请求仍须排空。客户端 48 项、3 个套件通过（24.784 秒，
`/tmp/im-author-short-grant-green-02.log`），覆盖短许可、未确认候选、页面切换、取消和可见范围。

容量验收器另增加可选 `--author-renewal-seconds 35..120` 阶段。默认关闭，既有冷/热/改名/字节
流程不变。开启后每个真实客户端在热消息后每 100 毫秒读取自己的展示快照，要求新许可在
上一次观察的许可到期前已可见，并持续保留相同身份与头像内容；结束时最初许可必须已经
过期，且每个客户端至少观察到一次有效期限推进。随后全局屏障核对没有额外资料 HTTP 或
公共资料回源。该判定会对严重延迟的观察者保守报错；它不把测试结束时恢复可见当作全程
可见的证据。`/tmp/im-author-renewal-128-p4-g2-release-01` 已通过：128 个真实用户、四个
ClientKit 进程、两个独立 Gateway，持续 35 秒，每个用户都观察到重叠续期许可。冷阶段
公共源两行、资料 HTTP 为零；热消息及续期均不增加公共源行或资料 HTTP。之后无消息
改名再读两行，128 次独立授权头像下载通过；四份测试均约 37.6 秒内完成。所有自建进程组
和 PostgreSQL 已清理。这是较小集群的持续续期证据，不是万人持续负载验收。

限制房间调用窗口后的万人复测 `/tmp/im-author-capacity-10000-p12-g4-release-03` 仍在冷资料
阶段失败。十二份客户端报告合计至少 7,708 次 HTTP 尝试；最终公共源五行、控制查询 294 批、
已完成资料 HTTP 171 次。房间过载从上一轮 1,914 降为零，房间超时为 753；三轮控制读取
分别失败 20/40/3 次，工作过期 1,400 次，构造 presentation 3,079 项（不等于成功投递或确认）。
只有认证屏障完成，不能宣称万人容量通过。进程清理再次短暂遇到 Darwin EPERM；独立复核
所有自建 PID/PGID 均已消失，原始失败与 `cleanup-followup.json` 一并保留。

验收器据此修正清理竞态：对已拥有进程组的 EPERM 继续有界等待，用独立进程快照确认
消失；仍存活的不可访问信号组在预算耗尽后必须失败，不能伪报排空。回归先复现两个失败，
修正后清理和容量屏障共五项通过（`/tmp/im-author-cleanup-green-01.log`）。

控制读取另发现重复合批等待：Dispatcher 已提交多个接收者时，未满 100 键的现成批次仍
等待新一轮合批。空闲 SQL 槽位下，五毫秒合批窗口即可复现限流失败
（`/tmp/im-author-partial-batch-red-02.log`）。现在多接收者批次立即进入执行调度，单接收者
调用仍可合并；槽位、排队五毫秒上限和调用方原截止均不变。控制读取诊断另区分整批
截止超时、准入限流、取消和其他错误，原错误不被替换。26 项、4 个套件通过
（`/tmp/im-author-partial-batch-green-01.log`）；真实 PostgreSQL 57 项、7 个套件通过
（9.175 秒，`/tmp/im-author-partial-batch-postgres-01/tests.log`），九个隔离数据库、自建
PostgreSQL 和临时目录均已清理。

随后 `/tmp/im-author-capacity-10000-p12-g4-release-04` 的万人 / 十二客户端进程 / 四网关复测
仍在冷阶段失败，十二份失败报告合计至少 6,917 次资料 HTTP 尝试。初次控制读取失败降到
1/121，最终控制复核 41/116、投递前控制复核 2/75 仍失败；新增分类记录截止超时 20 次、
准入限流 8 次、取消 16 次、其他控制错误零。房间过载仍为零，但房间超时 763 次、房间
事实变化 284 次、工作过期 1,101 次；不能仅凭这些聚合数据判断取消与事实变化是首发原因
还是失败后的连带结果。公共源五行、控制查询 368 批、已完成资料 HTTP 281 次；只有认证
屏障完成。所有自建客户端、服务进程组和 PostgreSQL 已清理，清理无失败。重复合批等待
已得到修正，但万人冷启动容量仍未通过，默认开关继续关闭。

验收器新增可选 `--author-avatar-replacement`：在无新消息改名完成后，由作者通过真实上传、
处理和资料修改 API 绑定不同颜色的新头像；各接收者必须观察到新的 mediaID 和 checksum，
且保持昵称不变，再实际下载并校验新资源。该阶段单独统计额外资料 HTTP 和公共源行，
可与持续续期组合。协调夹具只交换已发布资源的身份，不替代任何权限检查或资料响应。
默认、续期、换头像及二者组合的屏障顺序，以及作者发布约束、节点最大耗时汇总和清理竞态
共七项 Python 测试通过（`/tmp/im-author-avatar-fixture-02.log`）。
多节点耗时最大值取各节点最大值，计数及总耗时仍求和；去除标签后的不同直方图桶不再
错误地相加。历史容量结果继续以保留的逐节点原始指标为分析依据。

`/tmp/im-author-avatar-renewal-128-p4-g2-release-01` 已完成组合验证：128 个用户、四个
ClientKit 进程、两个独立 Gateway，35 秒内每个用户持续观察有效且内容一致的头像资料，
新许可在旧许可到期前被观察到。之后无新消息改名、再换成不同内容的头像，所有用户均
收到新 mediaID/checksum 并完成新头像字节的独立授权下载、校验与解码。冷资料公共源
两行；续期和热消息不增加公共源行；改名和换头像各再读两行，全程资料 HTTP 为零。
四份测试均约 38.1 秒内完成，自建客户端、服务进程组、PostgreSQL 均已清理。该结果证明
较小多网关集群中的组合行为，万人冷启动、持续大负载及故障组合仍未完成验收。

## 跨接收者房间 RPC 合批

万人冷启动失败后继续沿实际放大路径修正：控制域已按接收者合批，但房间授权仍按观察者
各发一次调用，并发窗口只限制同时在途数量。新增 100 名真实输入接收者的服务层回归，要求
初次和交付前房间核权各一次调用；原实现未满足两次调用断言，记录为
`/tmp/im-author-room-rpc-cohort-red-01.log`。编译成功后测试明确失败，不是构建失败。

当前改为同一房间的检查项通过 `profileVisibilityCohort` 一次传输，单批仍最多 100 个目标，
跨房间最多 16 个实际调用。内部 Actor 会话版本改为 2，批量入口只接受同时持有
`userRoomCalls` 和 `roomCoordination` 的服务 principal；单人调用继续绑定用户 principal。
不接受版本 1 会话，不增加旧节点回退。部署配置生成器已为 Gateway 配置这两项能力。

请求沿原有 RoomRef、Host 和 turn lane 执行，不绕过恢复、排队、截止、退休或取消栅栏。
一个 cohort 是一个命令信封，轮次仍累计所有目标及保守模型驻留成本；Factory 可将相邻单人
和多观察者资料请求展开为同一权限查询，再精确拆回原信封。拒绝也是带版本的空证明，
端口检查数量、顺序、原用户/上下文/目标及共同房间观察，不能借用另一接收者结果。
控制域的三轮核权和房间的两轮复核保持不变。

新增 `room_rpc` 固定阶段指标记录实际端口调用数和耗时，房间失败结果仍按受影响的
观察者/上下文计数。该改造的数据库、真实网络与容量验证尚在进行，默认开关继续关闭；
此前万人失败记录不因调用数量优化而改判通过。

首轮聚焦回归发现两处问题：无任何权限的测试 peer 在握手时已被拒绝，无法检验调用级
权限拒绝，现改用无关的维护能力；100 人 cohort 的反射内存计费超过既有 64 KiB lane
预算，现按明确存储字段保守计费，保留输入上限和原预算，不以扩大队列规避问题。
同一 SQL 观察的证明到期也统一计算一次，避免逐接收者换算时产生不同截止。

修正后的 `/tmp/im-author-room-rpc-cohort-green-02.log` 四个目标分别报告
17/24/6/33 项测试通过，覆盖 100 人的两次服务调用、真实 TCP、回复身份/顺序/版本、
内存及编码边界和取消排空。扩展回归 `/tmp/im-author-room-rpc-cohort-postgres-02/tests.log`
报告服务端 60 项、8 个 suite（其中 D5 专用媒体库测试跳过），Actor 集群全部 231 项、
37 个 suite 通过。跳过项随后在独立空库补跑，
`/tmp/im-author-room-rpc-cohort-d5-02/tests.log` 一项通过；两个临时 PostgreSQL 均已停止，
自建数据库和目录已清理。真实 PostgreSQL 覆盖 100 目标的单人、多观察者及混合信封
仅一次数据库准入、接收者隔离、成员变更和旧 owner 拒绝。服务端模块、Actor 序列化、
文档结构与链接门禁通过。万人复测使用当前 release 产物，结果另行记录；默认开关仍关闭。

同时复核库存门禁此前报告的三条缺失路径：它们均已在既有提交 `0bd67fd2` 退役，
对应旧 SQL 激活租约合同、存储和测试。所有权清单现按既有 `retiredPath/replacedBy`
格式指向现行 placement 合同、Host 生命周期、数据库恢复和对应测试，未修改门禁脚本。
`check_v2_virtual_actor_inventory.py` 通过：382 个活动文件、30 个 writer ID、44 个静态
来源声明、36 行能力目录及 231 个 DTO；这只修复静态清单，不代表运行时验收完成。

万人复测 `/tmp/im-author-capacity-10000-p12-g4-release-05` 已实际运行并失败，未改变容量
断言或原请求预算。12 个 ClientKit 进程、4 个 Gateway 的 10,000 名真实用户全部完成
冷资料屏障，各客户端记录约 4.5–4.7 秒（含全局屏障等待）；累计 2,039 次资料 HTTP 尝试、
409 次已完成 HTTP、公共资料源 5 行、控制查询 665 批，未满足零额外查询和最多 4 行的
冷阶段要求。后续热消息/历史阶段全部通过，未增加资料 HTTP 或公共源读取。持续续期中
一个客户端在第 103.8 秒报告缺少仍有效的展示快照，验收器停止其他客户端；35 秒续期
屏障、无消息改名、换头像及图片下载阶段未完成，不得从小规模通过推断这些阶段通过。

冷阶段后的运行采样记录 339 次实际房间 RPC、866 个过期工作及 8,563 次拒绝准入；
整个运行最终房间 RPC 为 2,946 次。调用数量已按批次下降，但上述数据还不能将冷启动
延迟或续期空档单独归因于某一层。现继续增加固定基数的调度、组帧、写出耗时及客户端
实际许可剩余时间诊断，以区分未准入需求、队列/执行等待和短许可。所有自建进程组与
PostgreSQL 已清理，两个清理报告均无失败。运行使用支持 TLS 1.3 的 bundled Python；
系统 Python 的 LibreSSL 预检失败发生在创建服务之前，其记录单独保留。

调度诊断的 33 项、4 个 suite 回归通过（`/tmp/im-author-dispatch-timing-01.log`），
包括原队列/慢写入/关闭边界以及非协作写入结束前不计完成耗时。Runtime 合并资料服务
和 Dispatcher 的固定阶段快照，指标抓取不触发读取。客户端容量夹具只增加收到许可的
剩余秒数最小/最大值及短于 1/5 秒的聚合计数；没有改变页面启动、续期、失败断言或预算。

万人诊断复测 `/tmp/im-author-capacity-10000-p12-g4-release-06` 仍为失败：全部冷资料约
4.6–4.7 秒完成，但有 2,504 次资料 HTTP 尝试、417 次完成响应、公共源五行、控制域
663 批。冷阶段收到许可的剩余时间为约 18.41–19.90 秒，没有短于五秒的许可。首次
冷阶段后采样记录 322 次房间 RPC、902 个过期工作和 8,693 次拒绝准入；组帧平均
0.088 ms、实际写出平均 0.838 ms，已准入排队平均 83.28 ms，初次/交付前房间核权
平均 37.33/39.29 ms。该采样含极少量后续热阶段活动，不能当作纯冷阶段精确计数。

此次 10,000 名用户均通过热消息、35 秒连续有效许可观察、无新消息改名和换头像屏障；
这些阶段没有新增资料 HTTP，改名与换头像分别新增四行公共源读取。此前 release-05 的
续期空档没有在本次复现，不代表故障已定位或稳定性完成验收。图片下载阶段出现
`NSURLError -1004`，代理同时报告 `EADDRNOTAVAIL`；全量字节屏障未完成。所有自建
进程组和 PostgreSQL 均已清理，清理失败数为零。

后续将验收 HTTPS 代理改为每个下游连接拥有一条顺序复用的上游 HTTP 连接，结束时关闭，
请求失败不自动重放。这样减少本机每次下载新建连接的端口消耗，不改变生产接口、授权
或容量断言。九项 Python 回归通过（`/tmp/im-author-upstream-reuse-01.log`），其中真实
本地 HTTP 测试确认四次 POST 复用同一连接且请求体/响应完整，失败 POST 只发送一次。
容量夹具的 URLSession 异常改为只输出错误码，避免测试框架打印带能力凭据的下载 URL。

另外修复客户端可重试错误过早撤销展示许可的问题。回归先在原行为下出现三处明确断言
失败（`/tmp/im-author-retry-grant-red-02.log`；首轮编译错误另记，不视为行为证据）。
可重试服务错误、请求超时或本地暂时过载保留原许可截止；明确拒绝、失效连接/页面以及
不可信响应仍撤销，重试不能延长旧许可。修正后 60 项、四个 suite 通过
（`/tmp/im-author-retry-grant-green-01.log`），包含到期早于重试、成功续期、明确拒绝、
页面退出、接收/应用确认和持久权限失效。该独立缺陷不被当作 release-05 续期失败的
已证实原因。新一轮完整容量复测结果另记，默认开关继续关闭。

`/tmp/im-author-capacity-10000-p12-g4-release-07` 已终止且仍失败。10,000 名用户完成冷资料、
热消息及 35 秒连续续期；冷阶段 3,096 次资料 HTTP 尝试、516 次响应、五行公共源读取和
695 批控制查询，热阶段和续期均无新增资料 HTTP。随后无新消息改名阶段超时；资料修改
接口返回成功，四个 Gateway 的公共源各新增一行，但尚不能证明所有页面应用了新资料。
全程控制查询达到 17,205 批，显示失败期间仍有大量重复工作；具体滞留环节仍须定位。
换头像和字节阶段未进入，因此本次没有验证代理连接复用在万人下载下的效果，也没有
复现上一轮的下载端口错误。自建客户端/服务进程组及 PostgreSQL 均已清理，清理失败数为零。

该次运行在约第 117 秒仍有 10,000 条传输连接，第 122 秒降到 9,831 条，至第 168 秒为
7,524 条，下降发生在客户端报告改名超时及集中清理之前。因此改名失败还涉及连接流失，
不能直接判定为变更广播丢失；原采样没有保留关闭原因，无法事后确定。验收器现记录
传输合同中十种固定关闭原因的聚合计数，不保存账号、连接身份或任意标签。
十项 Python 回归通过（`/tmp/im-author-capacity-closure-diagnostics-01.log`），包含未知原因
和附带用户标签的序列被丢弃。新诊断尚未获得下一轮真实运行数据。

修复后的 ClientKit 默认全量回归已完成（`/tmp/im-author-clientkit-full-20261031-01.log`）：
测试框架报告 1,483 项、227 个 suite 通过，耗时 279.645 秒，进程退出码为零。
需显式启用真实服务的套件/用例按默认配置跳过，不能将该结果代替上述独立万人验收。
文档结构、链接与 `git diff --check` 通过；未改动用户已有的 `V2RootView.swift` 修改。

`/tmp/im-author-capacity-10000-p12-g4-release-08` 使用新增关闭原因采样完成了全部阶段屏障。
10,000 名用户均完成热消息、35 秒连续续期、无新消息改名、换头像及新头像字节校验；
字节接口成功次数恰为 10,000，改名和换头像分别增加四行公共源读取，后续阶段没有新增
资料 HTTP。字节阶段采样仍有 10,000 条传输连接，除启动探测的四次对端关闭外无其他
关闭原因；每个上游 HTTP 连接复用的代理修正在此次真实下载中得到验证。
整体依旧失败：冷资料约 4.89 秒完成，有 3,278 次资料 HTTP 尝试、540 次完成响应、
五行公共源和 710 批控制查询，未达到冷阶段零额外查询要求。先完成测试的客户端因冷
阶段断言返回失败后，验收器停止剩余客户端；全量字节屏障此前已完成。自建客户端、
服务进程组和 PostgreSQL 均已清理，清理失败数为零。release-07 的中途连接流失本次未
复现，仍不能声称已定位；下一轮将连续续期观察扩展到既有夹具允许的 120 秒。

`/tmp/im-author-capacity-10000-p12-g4-release-09` 将续期保持扩展到 120 秒，仍失败。
冷资料约 4.95 秒完成，3,272 次资料 HTTP 尝试、539 次响应、五行公共源和 677 批控制
查询。约第 173 秒的采样仍有 10,000 条连接且无异常关闭；随后多个客户端报告有效
快照缺失，结束本地任务后才出现对端关闭计数。因此本次首先观察到的是许可连续性失败，
不是服务端连接关闭。续期屏障、改名、换头像和字节阶段均未完成。自建进程组与数据库
全部清理，清理失败数为零。运行中额外保存了只含聚合数的 SQL 诊断：截至该采样，房间
资料查询 2,064 次、PostgreSQL 执行共 2,517.71 ms；控制查询 4,732 次、共 10,075.25 ms。
这些执行时间不包括客户端排队、连接借用、网络、解码或其他事务语句，不能据此单独定位。

续期时序的静态检查发现，实际 18–20 秒的房间许可会把配置的 4–6 秒随机提前量压到
四分之一剩余时间，丢失大部分抖动范围。现改为至多提前剩余时间的一半：正常许可保留
完整 4–6 秒范围，短许可仍先保留至少一半可用时间，绝不延长原授权。回归先出现五处
断言失败（`/tmp/im-author-renewal-jitter-red-01.log`），修改后相关 62 项、四个 suite
通过（`/tmp/im-author-renewal-jitter-green-01.log`）。这项修正尚待万人持续负载复验，
不能把它直接认定为本次连续性失败的唯一根因。

房间资料查询还去掉了一次重复的事务超时设置：原 `scope.require` 已经在锁定持久归属
之前执行相同设置，调用方再执行一次没有增加约束。保留 Host pin、原预算、归属锁、
权限 SQL 和交付前复核。真实 PostgreSQL 回归已通过：
`/tmp/im-author-room-timeout-postgres-01/tests.log` 报告 11 项、五个 suite，覆盖百目标
单人/cohort/混合轮次、成员与归属改变、D5 媒体围栏、事务截止及连接超时默认/覆盖。
没有跳过项，独立 PostgreSQL 与临时目录已清理。模块与 Actor 序列化门禁通过。

`/tmp/im-author-capacity-10000-p12-g4-release-10-profile` 完成全部阶段屏障，但整体仍因冷阶段
失败。冷资料约 4.37 秒完成，1,667 次资料 HTTP 尝试、344 次响应、五行公共源和 642 批
控制查询。后续 10,000 名用户均通过热消息、120 秒连续许可观察、无新消息改名、换头像
及实际字节校验；后续阶段没有新增资料 HTTP，改名和换头像各增加四行公共源读取。
最后一次运行采样仍有 10,000 条连接，关闭计数仅包含四次启动探测。此次长续期通过覆盖
了抖动修正，但不能单凭一次通过排除之前的间歇失败。自建进程组与 PostgreSQL 全部清理，
清理失败数为零。

本轮在约第 76 秒对一个自建 Gateway 做了一秒 CPU 采样，因此属于诊断运行，后续还需
无采样复验。采样主要显示等待，通用 Protobuf 编解码各仅一个栈样本，不足以认定其为热点。
首次冷阶段后聚合统计中，初次/交付前房间核权平均 34.18/33.41 ms，已准入排队平均
78.99 ms，组帧平均 0.09 ms，实际写出平均 0.78 ms；这些数值含少量随后热阶段活动。

为区分 RPC 本地开销，新增可显式启用的百观察者微基准。修改前的 release 结果
（`/tmp/im-author-profile-codec-benchmark-01-results.log`，每项 200 次、先预热十次）为：
请求编码/解码 0.485/0.653 ms，响应编码/解码 2.032/2.556 ms，响应反射式内存计费
2.108 ms；请求显式计费约 0.00076 ms。这是单进程局部测量，不直接等同于压力测试
中的 RPC 时间。现将资料集合请求和证明接入固定 Protobuf 字段，并为证明增加显式
保守内存计费；原预算、权限复核与客户端等待时间保持不变。实现的验证结果另记。

固定字段实现的 ActorContracts 全量 release 测试通过：58 项、15 个 suite，包含新增
资料协议边界与显式启用的微基准（`/tmp/im-author-profile-codec-contracts-02.log`）。
相同输入和迭代次数下，请求编码/解码为 0.0334/0.1135 ms，响应编码/解码为
0.1707/0.3974 ms，响应计费为 0.00179 ms；单份响应由 90,608 字节降至 35,904 字节。
显式计费仍保守计入全部字段，百人模型费用由 211,896 变为 218,328 字节，没有通过减少
预算计费获得性能结果。真实 TCP、数据库接线及新一轮容量结果仍待独立验证。
初次微基准构建在目标包完成后主动终止了无关测试模块的构建（退出 130），随后直接使用
安装的 Swift Testing runner 运行目标测试包成功；这不算一次服务端全量构建通过。

随后真实 TCP 与认证回归通过（`/tmp/im-author-profile-codec-tcp-01.log`）：35 项、三个
suite，包含 100 个独立观察者经一次认证 TCP 调用往返、允许与拒绝的目标分离，以及
签名/本地路径上多人调用必须同时持有两种服务权限。协议生成物一致性、模块/Actor
序列化边界、静态归属清单及差异格式检查通过。新一轮无 CPU 采样的万人实测使用
`/tmp/im-author-capacity-10000-p12-g4-release-11`；终态见下文。

release-11 无 CPU 采样的万人实测仍因冷阶段失败：客户端 0 记录约 4.35 秒，1,617 次
资料 HTTP 尝试、321 次响应、五行公共源与 652 批控制查询。后续全部 10,000 名用户
通过热消息、120 秒连续许可、无新消息改名、换头像及实际图片校验；这些阶段无新增
资料 HTTP，改名和换头像各新增四行公共源。最后采样仍有 10,000 条连接，关闭计数仅
含四次启动探测。全部阶段屏障完成后，客户端因早先的冷断言退出失败，验收器停止剩余
客户端；所有自建进程组及 PostgreSQL 已清理，清理失败数为零。

首个冷阶段后采样中，初次/交付前房间核权平均约 30.50/29.45 ms，准入队列平均
74.01 ms；初次控制读取最大 169.67 ms，并记录 1,084 个过期工作。局部编码优化成立，
但端到端延迟仍包含显著等待及超时，尚未达到冷阶段零额外请求条件。继续定位首次批次
的控制/房间读取与调度，不通过延长客户端回退时间或减弱容量断言消除失败。

本轮固定编码后的 Linux 复核完成：七个部署程序于 252.205 秒构建通过，产物目录
`build/native-linux-release/runs/20261031T064148Z-8d956933` 的 manifest 为
`verified-linux-release`，`sourceDrift` 为空。随后 Linux amd64 镜像内独立验证七个
程序的哈希、运行库和加载依赖，并用真实 640×480 PNG 生成两档预览；
`runtime-verification.json` 为 `passed-linux-loader-and-worker`，网络关闭，
`serviceEndToEndTest` 为 `false`。日志为 `/tmp/im-author-linux-release-20261031-codec-01.log`、
`/tmp/im-author-linux-codec-image-01.log` 和 `/tmp/im-author-linux-codec-runtime-01.log`。
验证容器已由脚本清理，临时镜像已删除，原先停止的 `imv2-x86` 已恢复停止，Docker
默认 context 仍为 `default`；清理报告 `/tmp/im-author-linux-codec-cleanup-01.json` 全部成功。

## 房间读取与回复检查诊断（2026-10-31）

新增显式启用的 `V2RoomProfileCohortPostgresTests.profileCohortReadCosts`，使用真实原生
Host 生命周期、独立 PostgreSQL 和当前 schema。50 个观察者各有两个目标，拆为 100 个
单目标请求，其中 46 个允许、54 个拒绝；不是生产万人全允许场景的替代。各阶段预热十次、
测量一百次，输出平均值、分位数和计数，不输出账号、房间或授权数据。

基线 `/tmp/im-author-room-benchmark-postgres-01/tests.log`：适配层平均 3.241 ms，包含
调用端校验后 4.601 ms；单独对 snapshots/results 做 JSON 大小检查分别为 1.213/1.372 ms。
`query-costs.json` 的 227 次资料主查询平均执行 0.134 ms，不包含事务设置、所有者锁、
驱动解码及队列。这些局部数字不能直接从万人 RPC 均值中相减来推算精确排队耗时。
该 suite 三项测试（生产组合测试含三个参数场景）全部通过，无跳过；临时 PostgreSQL
已停止，私有数据目录已删除，清理报告为成功。首次 release 测试目标构建用时 813.20 秒。

据此将回复源端及调用端的大小检查改为当前固定 Protobuf 回复信封的实际编码大小，
继续限制为 256 KiB。SQL 输入和查询行的 JSON 限制、运行时驻留模型预算、所有者围栏、
逐观察者核权、交付前复核和客户端回退等待均不变。该检查现在约束实际内部线路表示，
由于计量对象改变，旧 JSON 长度与当前 Protobuf 长度的边界不等价；权限和结构校验
并未放宽。另补充超限回复拒绝场景。

修改后的 release 测试目标构建通过（620.31 秒）。真实 PostgreSQL 与调用端回归共
19 项、三个 suite 全部通过，无跳过，覆盖超限、多观察者错序、双向屏蔽、设备撤销，
以及签名期间资料、群昵称和成员变化；日志 `/tmp/im-author-room-benchmark-postgres-02/tests.log`。
同轮完整读取加校验平均 2.443 ms，但适配层阶段出现 121.28 ms 的最大抖动（均值
5.716 ms），因此没有将这一均值作为稳定性能结果。随后独立复测
`/tmp/im-author-room-benchmark-postgres-03/tests.log`：适配层平均 2.051 ms、p95 2.263 ms；
包含调用端校验后平均 2.279 ms、p95 2.327 ms、最大 2.378 ms。固定 Protobuf 大小检查
平均 0.130 ms，回复 33,456 字节。该次 221 条主查询平均 0.139 ms。两次临时 PostgreSQL
均已停止，私有目录已删除，清理报告均成功。上述结果只证明本机单批收益。

改动后的端到端复测为 `/tmp/im-author-capacity-10000-p12-g4-release-12`，使用 12 个真实
ClientKit 进程、四个网关、120 秒连续续期和头像替换，不启用 CPU 采样。生产四产品构建
均通过；整轮终态仍失败，原因是冷启动存在 414 次资料 HTTP 尝试、134 次响应（上一轮
为 1,617/321），五行公共源与 564 批控制查询。客户端 0 的冷阶段含屏障耗时约 3.875 秒，
首次 HTTP 在页面突发后 2.149 秒；不能把请求减少解释为零回退验收通过。

全部 10,000 名用户随后通过热消息、120 秒连续许可、无消息改名、头像替换和真实图片
长度/摘要/解码验证，后续资料 HTTP 为零；改名与头像变化各新增四行公共源，最终
成功字节下载为 10,000。203.07 秒采样仍有 10,000 条连接；最终采样时客户端已经结束，
出现正常 peer disconnect，其他九类连接关闭原因均为零。十二个客户端因冷阶段断言
均退出 1，所有七个阶段屏障完成。客户端进程组、服务进程组和 PostgreSQL 均清理成功，
两份 cleanup 报告的失败数为零。

冷阶段后的首个样本记录房间 RPC 平均 23.724 ms（上一轮 29.805 ms），初次/交付前
房间核权约 24.269/23.455 ms，分发排队约 63.868 ms；初次控制读取最大仍达
171.811 ms，并有 928 个过期工作计数。过期计数包含整批看门狗，不等于独立失败用户数。
新增房间指标确认同一个实际 Owner 正在处理其他业务调用；该样本已跨越阶段边界，
不能据此把调用全部归因为冷启动订阅。诊断摘要为该目录的 `capacity-cold-room-costs.json`。
后续需要精确区分订阅、历史读取和资料读取的阶段成本及排队，不能通过延长客户端
回退时间或提高生产资源上限消除失败。Linux 新改动复核、故障/慢连接组合和完整交付
审计继续保留，功能仍默认关闭。

容量采样同时增加有限、无标签的房间 Actor 排队和调用指标，只保存各节点观测，
不将不同节点的峰值相加冒充同时发生的全局峰值。固定指标过滤及既有清理/阶段/HTTP
连接复用测试共十项通过，日志 `/tmp/im-author-room-pressure-monitor-tests-01.log`。

## 阶段边界与房间执行诊断（2026-10-31）

之前五秒采样跨过冷启动与热消息历史读取，不能把样本中的所有房间业务调用归为冷启动
竞争。容量夹具现在只在全部客户端完成当前阶段、尚未释放下一阶段时抓取四个节点的
固定指标；节点读取使用有界并行，并记录包含 SQL 统计在内的采集耗时。观测只进入本地
证据文件，不重复发送给每个客户端。采集失败标记不完整，不用零冒充成功；既有客户端
阶段耗时仍包含屏障，不能用它冒充纯资料分发延迟。阶段观察、清理与连接复用共 12 项
Python 测试通过，另通过语法检查与 diff 检查。

新增 SQL 聚合记录房间资料主查询的次数、返回行数和总执行时间，不记录 SQL 文本、
用户、房间或凭据。当前生产设置未变的复测为
`/tmp/im-author-capacity-10000-p12-g4-release-13`：12 个 ClientKit 进程、四个网关、
10,000 名用户、120 秒连续续期及头像替换。冷阶段为 1,191 次 HTTP 尝试、256 次响应、
五行公共源、619 批控制查询；客户端 0 含屏障耗时约 4.266 秒，首次 HTTP 为 2.239 秒。
这不是容量验收通过，零回退与最多四行公共源两个断言均不满足。相对 release-12 的
414 次尝试存在运行间波动，不能只挑更好的一轮作为当前性能结论。

七个阶段全部到达 10,000 名用户，后续无新增资料 HTTP；无消息改名和头像替换分别
增加四行公共源，字节阶段完成 10,000 份长度、摘要和解码校验。十二个客户端中九个因
冷阶段断言退出 1，另外三个在其余进程报失败后的清理期间收到 SIGTERM；阶段屏障已
完成，但不能报告十二个进程都正常退出。服务进程组、客户端进程组与 PostgreSQL
均清理成功，两份 cleanup 报告失败数为零。

`capacity-phase-costs.json` 从边界快照计算的证据如下：

- 七次观测均完整；耗时约 29.6–49.6 毫秒。
- 冷阶段房间业务调用 347 次，资料 RPC 同为 347 次；随后热消息/历史阶段额外出现
  10,001 次业务调用，没有新增资料 RPC。因此此前怀疑的订阅/历史调用竞争不能解释
  这次冷阶段尾部，未据此更改房间订阅失效语义。
- 冷阶段资料 RPC 平均 28.856 毫秒；初次/交付前房间核权平均 30.982/27.109 毫秒，
  分发排队平均 71.098 毫秒。
- PostgreSQL 房间资料主查询 316 次、21,907 行，总执行 734.090 毫秒，平均约
  2.323 毫秒。与 RPC 的差距包含排队、事务和所有者核验、驱动处理及编码等，不能
  直接全部归为 Actor 排队，也不能用之前小规模本地基准的耗时替代。

据此新增由实际物理 owner 持有的固定计时器，分别观察房间 lane 等待、包含数据库准入
的读取，以及准入后实际执行；逻辑 shard 别名不重复累计，不保留高基数标识。已有
`/metrics/authors` 合并这些观测，读取指标不触发业务查询。真实 lane/cohort 测试与指标
路由测试增加相应断言；统一 release 构建与实际数据库/指标回归已通过，详见下文。
客户端等待、资源上限、核权次序与现有安全失效路径均未调整。

构建期间另用独立 PostgreSQL 和规范 schema，对从实际适配器提取的 SQL 做执行计划
检查。10,000 条成员记录、100 个不同观察者和同一目标；新建统计与 ANALYZE 后均
发现原查询对成员表各扫描 10,000 行两次。证据目录为
`/tmp/im-author-room-plan-01`。相关成员查找的候选查询改用复合索引逐个访问，两个
成员查找均为 100 次单行索引命中，不再扫描完整群名册，见
`/tmp/im-author-room-plan-02`。两次私有 PostgreSQL 均停止，临时目录均删除。此时有
Swift 编译并行，记录的局部耗时不是稳定性能基准，只将访问计划与行数作为修改依据。

已将该查找方式应用于实际资料 SQL，每个观察者/目标最多保留两条有效成员代次，
确保重复有效成员仍触发结果行数校验失败；未用单行截断掩盖损坏状态。新增真实数据库
参数化回归，分别覆盖观察者和目标：退出再加入选择当前代次，三条同时有效时拒绝。
首次诊断构建已为这一有证据的 SQL 修改主动中断（退出 130、所属进程组排空），随后
开始统一构建；不是因观察超时重启。
另用实际源码提取的 SQL 验证 100 项请求的成员代次语义：正常退出再加入均返回 100 行；
观察者出现重叠有效代次时返回 101 行，目标出现重叠时返回 202 行，均保留外层精确
行数拒绝条件。证据 `/tmp/im-author-room-plan-03/semantics.json`，私有 PostgreSQL 和
临时目录均已清理；这项 SQL 检查不代替上面的真实服务回归。
统一 release 测试产品构建通过，用时 688.66 秒，日志
`/tmp/im-author-owner-timing-build-02.log`。随后实际 PostgreSQL、调用端、签名期间权限竞态
及指标路由回归共 23 项、四个 suite 全部通过，无跳过，用时 1.918 秒，日志
`/tmp/im-author-owner-timing-postgres-01/tests.log`。包括观察者/目标成员代次的两个参数、
实际 owner lane 的三个生产组合参数，以及每个物理 owner 的计时合并断言。
私有 PostgreSQL 已停止、数据目录已删除，cleanup 报告全部成功。

同轮小群微基准读取加校验平均 2.488 ms、p95 2.604 ms，未显示相对之前 2.279 ms 的收益；
本次 SQL 修改依据是万人群执行计划中的整群扫描，不能声称它提高了所有规模的性能。
生产端到端复测为 `/tmp/im-author-capacity-10000-p12-g4-release-14`，仍使用 12 个真实
ClientKit 进程、四个网关、120 秒连续续期及头像替换，无 CPU 采样；终态见下文。
冷启动、故障组合、Linux 更新和最终交付审计仍未完成。

release-14 已退出失败。四个生产程序构建通过；全部 10,000 名用户完成冷资料与热消息，
冷阶段 73 次资料 HTTP 尝试、38 次响应、五行公共源、523 批控制查询；客户端 0 含屏障
耗时 3.863 秒，首次 HTTP 为 2.222 秒。热阶段没有新增资料 HTTP 或公共源读取。
随后在 120 秒连续观察中出现展示许可空档，测试在续期阶段终止，未进入改名、头像替换
及字节阶段；不能沿用上一轮结果宣称本轮后续通过。七个客户端退出 1，另外五个在清理
期间收到 SIGTERM。服务与客户端进程组均排空，PostgreSQL 停止，两份 cleanup 均为零失败。

阶段边界的 `capacity-phase-costs.json` 确认冷阶段主 SQL 307 次、20,825 行、共
144.311 ms，均值约 0.470 ms；上一轮为 2.323 ms。冷房间 RPC 325 次，平均 19.249 ms；
物理 owner 的 307 次轮次平均排队 6.094 ms、包含准入的读取 5.582 ms、实际执行
5.577 ms。RPC 与 owner 轮次数不同，因为部分信封被合批，不能简单相减推算单项成本。
分发排队平均 60.091 ms，173 次初次控制读取中十次失败。最后一个运行样本仍有 10,000
条连接，除四次启动探测外没有断开；控制读取共记录 903 次过载、15 次截止、四次取消。
这些计数指出续期需要继续检查控制读取与调度，尚不足以把空档归因于单一故障。

当前进一步修改 Dispatcher 的批次填充：在每批之前补入有限数量的待刷新项，扫描窗口
覆盖现有 200 个活动接收者和待处理容量，最多 1,000 项；保留原准入键数、字节、读写
任务槽及输出预算。一旦最早可执行请求到达合并时间，同批包含已经入队的新请求，避免
把旧尾批先单独发出。未延长请求、授权或客户端回退截止。新增真实调度器的 250 个可见
接收者测试，验证有界延期需求连续组成 100/100/50 批，并逐接收者确认。聚焦回归结果见
下文；这不等于已验证的万人性能修复。

批次填充版原生 release 测试产品构建通过（781.34 秒），新增 250 人测试通过（0.048 秒）。
更广回归随后在 `V2AuthorProfileChangeDeliveryTests.nicknameRoomScope` 的测试适配器
`fixtureBatch` 崩溃；该轮不是测试通过。独立筛选再次复现同一崩溃。调试器定位为两个
并行结果整理时，索引 1 不存在；当前任务并未取消。因此撤回最初的取消假设，并主动
中断其尚未完成的测试构建（父进程退出 130，遗留的自建编译子进程单独停止并确认退出）。

独立小程序在本机 Apple Swift 6.4 中复现：优化构建的 `(Int, Result<Int, Error>)`
任务组结果只留下索引 0，未优化构建完成 1,000 轮；改用具名 Sendable 结构体的优化构建
也完成 1,000 轮。改用显式下标循环或 `group.next()` 而保持元组均不能消除复现。这将
问题缩小到该环境的优化构建与元组任务结果组合，不声称已确定 Swift 编译器内部根因。
证据为 `/tmp/im-author-fixture-group-{repro,struct,indices,next}.swift` 和
`/tmp/im-author-dispatch-fill-nickname-debug-03.log`。测试适配器现用具名结构体保留索引与
结果，未取消缺项校验；生产资料读取不经过此适配器。

修正后的 release 测试产品构建通过（490.45 秒），日志
`/tmp/im-author-dispatch-fill-build-03.log`。之前稳定崩溃的昵称变更用例单独通过，随后
68 项、八个 suite 的调度器/批次/兴趣/上下文/取消关闭/变更传播/控制批处理回归全部
通过（4.285 秒，无跳过），日志 `/tmp/im-author-dispatch-fill-tests-02.log`；新增的
250 人测试通过，实际批次为 100/100/50。客户端资料投影的现有 release 产物另运行
六项回归通过（1.410 秒），覆盖百项读取、不可用授权、SQLite 与取消排空，日志
`/tmp/im-author-profile-projection-release-audit-01.log`。本轮没有修改客户端生产代码。

批次填充后的万人复测目录为 `/tmp/im-author-capacity-10000-p12-g4-release-15`，继续原来的
12 客户端进程、四网关、120 秒续期和头像替换条件，增加只读的数值 CPU/RSS 观测，
用于区分服务端与同机压测客户端开销。该轮终态记录如下。

release-15 四个生产产品构建通过，整轮退出 1。冷阶段为 12 次资料 HTTP 尝试、十次响应、
五行公共源与 379 批控制查询；上一轮分别为 73、38、五和 523。客户端 0 含屏障耗时
3.698 秒，它自身未发起 HTTP；12 次是所有客户端的合计。全部七个屏障到达 10,000 人，
随后热消息、120 秒连续许可、无新消息改名、头像替换与 10,000 份图片长度/摘要/解码
校验完成。冷阶段之后无新增资料 HTTP，改名和头像替换各新增四行公共源。十个客户端
因冷阶段断言退出 1，两个在清理期间收到 SIGTERM；服务和客户端进程组及 PostgreSQL
全部清理成功，两份 cleanup 均为零失败，CPU 观察器正常退出。

七次阶段观测完整，采集开销约 30.0–45.2 ms。冷房间 SQL 233 次、20,993 行、共
133.792 ms；房间 RPC 245 次（上轮 325），平均 23.984 ms（上轮 19.249）。物理 owner
轮次平均排队 6.496 ms、读取 6.391 ms。批次更满减少了往返，但单次调用平均耗时并未
下降。初次控制读取由 173 次降至 127 次，其中四次失败；交付控制还有一次失败，房间
RPC 有一次失败。仍需定位这些少量失败与延期恢复，不能延长客户端回退时间来掩盖它们。
冷阶段结果计数进一步区分为三次控制截止、一次控制过载和一次控制取消；房间失败按
接收者计为 100 项，对应上面的一次批量 RPC 失败，不能误报为 100 次 RPC。四节点分发
排队的生命周期最大值中，最大约 501 ms，包含已过期工作；写出等待最大约 175 ms。
下一步应检查临近截止的旧请求与新补入请求共用最早批次截止时的失败范围，以及延期
恢复的时点；这些数据尚不能单独证明混合批次是失败根因。

CPU 观察器只保留数值，不读取命令参数、消息、资料或凭据。机器有 14 个逻辑 CPU；
认证结束附近的五秒区间里，12 个客户端合计接近 9.75 个 CPU，主机观测合计接近
13.66 个 CPU，区间跨越认证尾部，不能当作纯冷资料阶段负载。观察器启动后 85–175 秒的
18 个样本中，四个 Gateway 合计平均约 1.42 个 CPU、峰值约 3.03；客户端合计平均约
3.17、峰值约 4.25。各自峰值不代表同时发生，主机总计还包含数据库和其他进程；短命
进程可能漏计。这说明同机压测客户端开销不可忽略，但不能据此将所有失败归因为主机
CPU，也不能把这些数字外推为生产硬件容量。证据为 `capacity-host-costs.jsonl` 与
`capacity-host-costs-summary.json`。整体仍未验收，默认开关保持关闭。

Linux 复核产物为 `build/native-linux-release/runs/20261031T081942Z-65c761f6`：七产品
构建合计 238.930 秒，manifest 为 `verified-linux-release`，构建时 `sourceDrift` 为空。
随后 Linux amd64 容器在无网络环境中验证七个程序的哈希与动态依赖，并实际生成两档
PNG；`runtime-verification.json` 为 `passed-linux-loader-and-worker`，业务端到端标记
仍为 `false`。临时镜像已删除，`imv2-x86` 已恢复停止，默认 Docker context 保持 `default`，
清理报告 `/tmp/im-author-linux-dispatch-fill-cleanup-01.json` 全部成功。之后的上述修改仅
涉及测试夹具，生产源文件未变；不将此次 Linux 加载验证当作万人稳定性通过。

## 接收者独立截止的复现与修复（2026-10-31）

新增测试直接调用 Dispatcher 与资料服务：一个接收者较早过期，另一个仍有原始预算。
旧实现的 Dispatcher 在最早截止取消整个读取任务，有效接收者也未收到结果；服务层在
部分输入已经过期、以及初次读取期间部分输入过期时都抛出整批 `deadlineExceeded`。
红测试两项、三个参数场景共四个断言/错误，日志
`/tmp/im-author-recipient-deadline-red-tests-01.log`。对应 release 构建通过，耗时 734.97 秒。
这证明了失败扩大的机制，但尚不能单独证明它解释 release-15 的全部 HTTP 回退。

修复覆盖 Dispatcher、资料服务和控制查询合并器：共享 I/O 使用本批有效调用方中最晚的
原始截止，每个接收者的预算不变；三轮控制读取前后分别筛掉过期项，保持结果原序和
身份绑定；没有有效接收者的房间上下文不再复核，最终输出仍逐接收者检查原始截止。
Dispatcher 的读取 watchdog 不再因较早同伴到期而取消整个批次；所有接收者退休/过期、
最终截止和 shutdown 仍取消工作，槽位始终保留至实际 I/O 结束。过期计数去重且排除
已消费结果。处理截止不改变展示许可的有效期；队列、并发、500 毫秒投递预算及客户端
回退时间均未调整。

修复后 release 构建通过（625.08 秒），四项期限测试含十二个参数场景通过（1.160 秒）。
覆盖开始前、初次/最终/交付控制读取期间过期，以及关系名片和房间权限两种上下文；
另检查共享控制 SQL 的独立截止、后续查询成员与最终账号/设备绑定。新增的三个测试
连续重复十轮全部通过，证据 `/tmp/im-author-recipient-deadline-repeat-01/result.json`。

真实 PostgreSQL 组合回归执行 99 项、12 个套件，唯一失败是慢写测试将三个接收者固定
计为三个 `dispatchTask`，而实际合法合批为两次；三个接收者的读取、写出背压和其他
权限回归通过。已为该测试记录真实批次并与诊断计数核对，保留接收者数量、背压和排空
断言，正在重建复验。第一次组合日志为
`/tmp/im-author-recipient-deadline-postgres-01/tests.log`，私有 PostgreSQL 和目录清理成功。
万人复测、最新 Linux 构建及完整组合验收仍未完成，功能默认关闭。

复核发现多房间调用还有十六路并发窗口，已组装的房间请求可能在排队时越过自身截止。
因此补充各权限上下文的原始截止，实际发起 RPC 前再次过滤，并将 RPC 截止收紧到本
房间仍有效上下文的最晚截止；其他房间的长预算不能让过期房间开始新调用。新增回归
用十八个房间占满十六路窗口，等待其中十七个接收者到期后释放首波调用，要求之后只
能补发仍有效的房间、过期接收者均失败且不突破原并发窗口。

为纳入这一必要边界，`green-build-02` 在编译中主动中断（退出 130），不是观察超时；
已核实其构建与派生进程终止，未干预其他项目进程。最新构建
`/tmp/im-author-recipient-deadline-green-build-03.log` 随后通过（636.14 秒）。
`/tmp/im-author-recipient-deadline-postgres-02/tests.log` 的 100 项、12 个套件全部通过
（7.867 秒，无跳过），覆盖新增房间排队截止和修正后的实际批次指标；cleanup 中
PostgreSQL 停止、私有目录清理和测试退出状态全部成功。排队截止与慢写指标两个测试
另连续重复十轮通过，证据 `/tmp/im-author-room-deadline-repeat-01/result.json`。

随后启动 `/tmp/im-author-capacity-10000-p12-g4-release-16`，继续四 Gateway、十二个真实
ClientKit 进程、一万用户设备、120 秒续期和头像替换条件；启动前未见存活的 Swift
编译、测试或本项目服务进程。数值 CPU/RSS 观察器仍按上一轮方式记录，容量运行期间
不并行运行本任务的构建或其他负载测试。

该轮终态失败（driver 退出 1）。一万用户均完成冷资料和热消息阶段；冷阶段发起 665 次
资料 HTTP、收到 193 次响应，公共资料源五批五行，控制读取 466 批。冷房间 SQL 为
278 次、21,359 行、共 146.017 ms；房间 RPC 257 次、平均 21.664 ms。热消息阶段没有
新增资料 HTTP 或公共资料源读取。随后十二个客户端进程都在连续许可检查的
`V2LiveAuthorCapacityTests.swift:549` 报告 `cachedSnapshot` 为空；这表示每个进程至少
观察到一个失效展示，不代表同一时刻全部一万人的许可均失效。未完成 120 秒续期，也
未到达无消息改名、换头像或字节校验，不能沿用 release-15 的通过结论。

客户端进程 3 的有界阶段计数显示：初次资料在页面突发后的 0.719–2.418 秒到达，
第二轮兴趣在约 18.187 秒前均已获接收；失败时累计 1,117 次 presentation，超过初次
836 次但仍未覆盖该进程全部 833 个接收者的新一轮许可。首次 HTTP 在约 2.108 秒发生。
最后一个运行采样（约 96.7 秒）记录 412 个 pending key、八个读取批次、4,967 个累计
过期 job；此前稳定采样的累计过期数为 620。以上计数支持继续检查续期的排队和批次
利用率，但尚不能确定全部空档由哪一个阶段造成，更不能据此放宽原始截止或验收断言。

数值 CPU 观察中，约 90.8/95.8 秒样本的主机观测 CPU 分别约 3.79/5.27 核，四个
Gateway 合计约 0.29/1.08 核，客户端约 1.80/1.94 核；五秒采样可能遗漏短时峰值，
不能证明故障期间所有调度均有余量，也不足以把失败归因为持续整机 CPU 饱和。
进程 3 的细节只作定位线索，不外推为全部客户端的分位数。

`owned-cleanup.json` 中服务进程、进程组和 PostgreSQL 均已排空；
`capacity-client-cleanup.json` 中客户端进程组也已排空，两份 cleanup 均为零失败。
CPU 观察器退出 0。截止隔离的组件正确性证据保留，万人冷启动及续期仍未验收，功能
默认关闭；最新生产源文件尚需重新完成 Linux 验证。

## 未开始读取的排队恢复（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-17` 沿用 release-16 的生产源文件、四 Gateway、
十二客户端进程及一万用户设备条件。冷阶段 132 次资料 HTTP 尝试、61 次响应、公共源
五批五行，控制读取 400 批；冷房间 SQL 252 次、21,234 行、165.022 ms，房间 RPC
241 次、平均 24.515 ms，分发队列过期 56 次。七个阶段均达一万人；热消息、120 秒
连续许可、无消息改名、头像替换及一万次实际图片读取完成，后续没有新增资料 HTTP。
改名和头像替换分别增加四行公共源读取。冷阶段两个原有断言仍失败，driver 退出 1，
不得将后续阶段通过当作整体通过。服务、客户端进程组及 PostgreSQL 均清理成功。

本轮另采了三个网关稳态栈，采样以线程等待为主，未定位故障热区。最初的自动采样器
依赖只在运行结束才落盘的 `capacity-phases.json`，没有捕捉第一轮续期；其唯一采样发生
在收尾阶段。这些栈不支持排除 CPU 或调度问题，也不作为基准性能证据。

读取调度代码时发现一个可独立复现的恢复缺陷：延期准入时就把可见作者的 `retryAt`
设为一秒之后，之后即使该项一直未调用依赖、只在待处理队列中到期，也不能在容量
释放后立即重新准入。新增回归先用非协作读取占住槽位，填满队列，使可见作者延期
准入，再等待其排队到期；释放槽位后在正常恢复轮询下仍没有发生该作者的首次读取。
旧实现红测试两处断言失败，日志 `/tmp/im-author-queue-expiry-red-debug-tests-01.log`；
对应 Debug 构建通过，耗时 133.29 秒。

修复把依赖重试间隔的起点移到领取读取槽位时。排队键和活跃键继续阻止重复准入，
尚未读取的过期项可以在容量释放后重试；已经发起读取的失败或未确认结果继续保留
一秒间隔。没有延长原始 500 毫秒任务截止、客户端补查等待、展示资格或任何队列上限。

修复后 Debug 构建通过（38.50 秒），58 项、6 个套件通过（5.816 秒）。新回归分别
覆盖拒绝展示和临时失败返回，并在实际读取后继续轮询，确认不会形成紧循环；连续
十轮通过，证据 `/tmp/im-author-queue-expiry-repeat-01/result.json`。真实 PostgreSQL
组合回归 `/tmp/im-author-queue-expiry-postgres-debug-01/tests.log` 的 101 项、12 个套件
通过（10.902 秒，无跳过），私有数据库和目录清理成功。这是组件正确性证据；新生产
源文件的万人效果、Linux 构建以及整体故障组合验收仍待完成。

## 控制查询的合批与容量等待（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-18` 在前述未读取任务恢复修复后，仍按四个
Gateway、十二个客户端进程、一万人、120 秒续期及头像替换运行。七个阶段均达一万人；
冷阶段有 50 次资料 HTTP 尝试、26 次响应、五行公共源读取及 387 批控制查询，整体
退出 1。热消息、120 秒许可续期、无消息改名、头像替换和一万次真实图片字节校验完成，
后续未新增资料 HTTP；改名、换头像各增加四行公共源读取。服务、客户端进程组及私有
PostgreSQL 清理均成功。不同轮次存在明显波动，不把 132 次降至 50 次归因于单项修复。

冷阶段出现一次 `controlOverloaded`，续期结束累计 694 次。代码检查发现控制查询把
默认 3 毫秒合批窗口与最多 5 毫秒执行容量等待绑在一起；已准入请求即使还有调用预算，
仅因 SQL 槽位短暂占用也会返回一秒限流。新增两个用例分别验证槽位约 20 毫秒后释放
仍能执行，以及调用者自己的 20 毫秒截止优先。旧实现均提前返回限流，红测试两项失败，
日志 `/tmp/im-author-control-queue-red-debug-tests-01.log`。该测试证明组件缺陷，不足以
单独证明它是万人冷启动回退的全部原因。

修复将执行容量等待上限设为 100 毫秒，合批窗口仍为默认 3 毫秒、最多 5 毫秒；原始
调用截止仍取优先值，Dispatcher 的 500 毫秒总预算不变。四个实际 SQL 槽位、400 个
待处理键、256 KiB 待处理字节和取消后排空实际工作保持不变。已有多接收者批次仍可
直接执行，无需额外合批等待。对应边界写入批量读取合同。

Debug 构建通过（37.68 秒）；真实 PostgreSQL 组合的 103 项、12 个套件全部通过
（11.116 秒，无跳过），证据 `/tmp/im-author-control-queue-postgres-debug-01/tests.log`。
两项新增截止用例连续十轮通过，证据 `/tmp/im-author-control-queue-repeat-01/result.json`。
私有数据库停止和临时目录删除成功。新生产源文件尚待万人及 Linux 验证，功能默认关闭。

## 控制查询容量等待的万人复测（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-19` 四个 Release 服务构建通过
（190.57 / 40.39 / 19.04 / 0.81 秒），真实 ClientKit 增量构建通过（0.52 秒）。
沿用一万用户、十二客户端进程、四 Gateway、120 秒连续许可及头像替换条件。全部七个
阶段完成；冷启动仍有 2,190 次资料 HTTP 尝试、323 次响应，公共源五批五行，控制查询
497 批。各客户端报告冷阶段约 2.88–3.19 秒，首个 HTTP 在页面突发后约 2.11 秒。
此轮整体退出 1，不满足原有零 HTTP 条件。

所有阶段的控制查询限流计数为零，冷阶段三轮控制查询各 121 次，均没有失败；均值分别
为 11.702 / 10.732 / 9.322 毫秒。冷房间 RPC 242 次、均值 38.265 毫秒；房间 owner
排队 284 次、均值 22.008 毫秒，执行均值 6.815 毫秒。对应资料 SQL 284 次、21,529 行，
数据库执行累计 155.748 毫秒。owner 执行计时累计约 1.935 秒，包含事务与应用侧等待，
不能直接解释为 CPU 时间。分发队列 10,792 项、均值 76.154 毫秒，其中 289 项过期；
冷阶段累计 670 个过期任务。由此不能把控制限流消失等同于端到端容量问题解决，也不能
仅按不同轮次的 HTTP 数量断言因果。

热消息、120 秒连续许可、无消息改名、头像替换均未新增资料 HTTP。改名和头像替换各
增加四行公共源读取，一万次真实图片下载、摘要及解码检查完成。整个运行采样保留
10,000 个连接，后续累计过期任务为 1,002。十二个客户端中十一个退出 1，一个在收尾时
收到 SIGTERM；服务进程、全部客户端进程组与 PostgreSQL 均排空，两份 cleanup 零失败。
数值 CPU 观察器正常退出。最新源码的 Linux 和真实故障/慢连接组合仍未完成。

诊断轮 `/tmp/im-author-capacity-10000-p12-g4-release-20-profile` 在所有客户端完成认证
屏障后延迟 250 毫秒，对四个自有 Gateway 各采样三秒，四个 sample 均退出 0。
采样覆盖实际冷分发，包含 Dispatcher、控制读取、SQL 编解码和房间事务执行，未形成
足以归因的单一 CPU 热点；线程等待占多数并不等于不存在调度等待。诊断轮在冷屏障前
有两个客户端返回资料仓库 `.overloaded`，driver 退出 1，其余客户端在清理时收到
SIGTERM。服务、客户端进程组及 PostgreSQL 全部排空，cleanup 零失败。此轮有分析器
开销，只作定位证据，不与无分析器的容量轮次直接比较，也不作为验收通过证据。

## 房间资料改用一致快照读取（2026-10-31）

沿着 release-19 的房间执行计时检查，发现资料只读路径仍执行 BEGIN、超时设置、持久
归属行锁和 COMMIT。项目的房间订阅源已经使用 `v2WithRoomSnapshotConnection`，以
单条 SELECT 同时读取并验证持久数据归属及业务快照；资料检查可以复用这一已存在的
物理连接生命周期，而不需要阻塞在未提交写入的房间行锁后。

新增 PostgreSQL 参数化回归先保持一个未提交写入：更新成员版本和退出状态，另一种
情况还推进数据归属 epoch。资料读取应在 200 毫秒预算内看到完整旧快照，写入提交后
再读取则必须看见退出或拒绝旧 owner。旧实现两个参数均因行锁耗尽预算，红测试
`/tmp/im-author-room-snapshot-red-postgres-01/tests.log` 两处失败，私有 PostgreSQL
清理成功；对应 Debug 构建通过（114.22 秒）。

新实现由同一条 SELECT 返回 shard/owner epoch、成员版本、权限和群昵称，并逐行
核对调用令牌。取消、绝对截止和物理 SQL 排空仍由原有连接借用机制负责，原生 pin 在
返回前再次核验生命周期。没有复用其他接收者授权，也未延长 Dispatcher 截止或扩大
并发、队列、输出预算。既有百目标回归进一步确认一次查询、零事务控制语句。

Debug 构建通过（39.61 秒）。`/tmp/im-author-room-snapshot-green-postgres-01/tests.log`
真实 PostgreSQL 组合 108 项、13 套件通过（13.054 秒，无跳过），包含共用单语句读取
机制的截止排空、退休后拒绝及并发写入测试。数据库停止和私有目录删除成功。模块边界、
Actor 序列化及差异格式检查通过，用户的 `V2RootView.swift` 仍保持 0 增加 / 7 删除。

同一 Debug 微基准的 adapter 均值为 7.701 毫秒，前轮为 7.731 毫秒，不能据此声称
单次执行更快。并发写入的两个参数用例在独立 PostgreSQL 中连续十轮通过，证据
`/tmp/im-author-room-snapshot-repeat-01/result.json`，各轮数据库均清理成功。目前验证
的是减少语句及消除写锁等待；新源码的万人效果和 Linux 构建仍待验证。完整十项交付
条件保持不变，功能默认关闭。

## 单条快照读取的万人复测（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-21` 沿用四网关、十二客户端进程、一万
用户、120 秒连续许可和头像替换；不带栈分析器。四个 Release 服务构建通过
（209.40 / 42.01 / 20.39 / 0.77 秒），ClientKit 增量构建通过（0.47 秒）。七阶段均达
一万人，冷启动 49 次资料 HTTP 尝试、41 次响应、五批五行公共源读取，控制查询 386 批。
原有两个冷断言仍失败，driver 退出 1；不能称为容量验收通过。

冷房间 RPC 238 次、均值 15.135 毫秒，一次失败；owner 排队 252 次、均值
2.939 毫秒，实际执行均值 4.203 毫秒。资料 SQL 252 次、21,027 行，数据库执行累计
134.682 毫秒。三轮控制查询各 119 次，均无失败；控制查询限流为零。分发队列
10,766 项、均值 62.044 毫秒，184 项排队过期，冷阶段累计 664 个过期任务。一次
房间 RPC 失败影响一个百人 cohort，当前 `roomFailure=100` 只表明未归入既有 deadline/
overload 分类，不能据此确定底层异常。部分节点首次控制读取最大耗时约 177–188
毫秒，仍需定位突发期间的等待；没有延长原始 500 毫秒预算。

热消息、120 秒连续许可、无消息改名、头像替换及一万次真实图片读取全部完成，均未
新增资料 HTTP，后续过期任务计数仍为 664；改名和换头像各增加四行公共源读取。
十一份客户端退出 1，一份在收尾收到 SIGTERM；全部服务进程、客户端进程组和私有
PostgreSQL 清理成功，两份 cleanup 零失败，CPU 观察器退出 0。房间计时改善是本轮
观测值，不能忽略各轮冷启动波动或推断稳定性已达标。最新源码随后进入 Linux 七产品
重建，故障/慢连接组合与最终逐项交付审计仍待完成。

## 最新 Linux 产物验证（2026-10-31）

`build/native-linux-release/runs/20261031T112458Z-2f8dced5` 使用固定 Swift 6.4.0、
glibc SDK 和四个构建任务完成七产品构建；各产品构建时间合计 218.702 秒，manifest 为
`verified-linux-release`，构建后及交付记录时的源码差异均为空。覆盖当前的接收者截止
隔离、两项队列修复和房间单条快照读取，取代前面只覆盖较早源文件的 Linux 状态。

隔离 Linux amd64 容器核验七个产物与资源哈希、SDK 运行库哈希和动态依赖，并用实际
图片 worker 生成 320×240 与 640×480 两档 PNG。`runtime-verification.json` 为
`passed-linux-loader-and-worker`；容器无网络，此结果不代表数据库、鉴权、消息及资料
分发的 Linux 业务端到端测试。

`/tmp/im-author-linux-room-snapshot-01/cleanup.json` 确认本轮临时镜像已删除、原先
停止的 `imv2-x86` 验证虚拟机恢复停止、Docker context 仍为 `default`，验证退出 0。
没有发布或开启功能流量。原有万人冷启动、真实故障/慢连接组合及最终审计要求保持不变。

## 饱和队列调度与房间失败定位（2026-10-31）

检查 release-21 的突发等待后，发现 Dispatcher 在读取/输出容量已满时，仍为每个新
兴趣和每次完成回调扫描待处理队列两次。现在保存排队截止的保守下界；后续新增键
缩短截止时立即降低下界，过期时扫描并重算，队列空时清除。移除项留下的偏早唤醒
最多带来一次多余扫描，不能延迟任何请求的过期。原有 500 毫秒预算、读取/写入槽位、
200 接收者窗口、待处理键及输出字节上限均未变化。

新增参数化回归在读取槽位被非协作任务占用时，先排入正常期限的请求，再排入更早
截止请求；另一参数在已排队连接新增键以缩短截止。两者均须按更早截止清理，正常
请求在槽位释放后交付，过期请求不能调用 reader 或迟到交付。Debug 构建通过
（121.99 秒）；真实 PostgreSQL 109 项、13 套件通过（13.201 秒）。构建完成前误启动
的一轮旧测试产物不计入本次验证；只有包含新增用例的上述运行有效。

另将笼统房间失败拆为取消、归属变化、依赖不可用和请求拒绝的固定类别，保留既有
截止、容量和未知失败分类。所有类别仍返回可重试结果，不转化为权限拒绝；指标没有
身份或原始错误正文。17 个 Actor 错误参数及本地 CancellationError 用例均通过百接收者
批次验证独立结果和计数。对应 Debug 构建通过（41.29 秒）；含 HTTP 指标路由的最终
真实 PostgreSQL 组合 119 项、14 套件通过（14.053 秒，无跳过），证据
`/tmp/im-author-room-failure-postgres-01/tests.log`。两轮数据库均成功停止和清除。

此处仅确认调度不变量及诊断分类；不能据此认定万人冷补查已经解决。下一轮须在同样
四网关、一万连接、120 秒持续许可及头像替换条件下验证。Linux 新增源文件尚待重建。

## 饱和队列优化的万人复测与客户端启动窗口（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-22` 四个服务 Release 构建通过
（201.28 / 40.65 / 17.77 / 0.75 秒），ClientKit 构建通过（0.50 秒）。同样的一万用户、
十二客户端进程、四网关完成七阶段。冷资料仍有 1 次 HTTP 尝试及响应，公共源五批五行，
控制查询 362 批，房间资料 SQL 223 次、20,390 行、执行累计 118.636 毫秒。
原有冷阶段断言仍失败；不能把仅一次补查写成零请求通过。

冷阶段两次房间 RPC 失败均归为截止，对应 200 个接收者上下文；没有取消、归属变化、
依赖不可用或未分类失败。排队过期 28 项、累计过期工作 267 项，后台恢复完成后未增加
HTTP。120 秒连续许可、无消息改名、换头像和一万次字节下载均完成；改名与换头像各
增加四行公共源读取。九个客户端退出 1，三个收尾收到 SIGTERM；服务、客户端进程组
及数据库全部清理，零清理失败。此轮整体退出 1，CPU 观察器退出 0。

唯一一次 HTTP 来自 process 0，在页面突发后约 63 毫秒开始，早于正常 2.1–2.5 秒回退。
代码检查发现页面激活可以先暴露给资料读取，协调器另一个任务才调用
`expectAuthorDelivery`；如果这一启动间隔超过普通 32 毫秒合批窗口，就会先发 HTTP。
新增回归刻意不启动协调器，旧行为三项断言失败，证据
`/tmp/im-author-page-admission-red-01.log`（构建 26.43 秒、测试 0.131 秒）。

页面激活现在可显式选择 `.authorStream`，在同一仓库操作中登记接收意图，再把令牌
交给调用者。App 有作者协调器时及真实 ClientKit 容量夹具均使用此入口；普通 HTTP
调用保留原有行为。该意图不授予展示权限，不延长需求创建时的有限回退截止；缺失流
仍按原期限回退。协调器既有登记和清理继续覆盖后续运行、取消及重新连接。

Debug 构建 12.91 秒，82 项、6 套件 ClientKit 聚焦回归通过（42.561 秒），覆盖新启动
窗口、缺失流回退、多页面、过期、补充应用和安全失效，证据
`/tmp/im-author-page-admission-green-01.log`。App 的 38 项、4 套件相关回归通过（12.257 秒），证据
`/tmp/im-author-page-admission-app-01/tests.xcresult`；本轮创建的 iPhone 17 / iOS 27.0
模拟器已关闭并删除。修复后的万人复测尚待完成；此修复只针对已复现的启动窗口，
不能解释此前所有负载波动。

## 原子页面激活的万人复测（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-23` 使用相同的一万用户、四网关、十二
客户端进程、120 秒连续许可及头像替换。服务增量构建通过（1.93 / 2.09 / 1.88 /
0.64 秒）；真实 ClientKit Release 测试产物重建通过（284.06 秒）。七阶段全部完成。
冷启动仍有 1 次 HTTP 尝试和响应，公共源仍为五行，原有两个断言失败。

本次唯一 HTTP 来自 process 8，页面突发后约 2.228 秒，符合原有回退时间；没有再观察到
上一轮 63 毫秒的提前请求。因此启动窗口修复已被独立回归验证，但这轮不能称为万人零
补查通过。冷阶段观察到资料写入暂时被拒绝，正在检查已准备输出的恢复方式；尚无逐项
关联证据证明该次 HTTP 必然由某一次写入失败造成。

热消息、120 秒连续许可、无消息改名、换头像及一万次字节读取均完成，后续未新增
资料 HTTP；改名、换头像各增加四行公共源读取。十一客户端退出 1，一个收尾收到
SIGTERM；全部服务、客户端进程组及私有 PostgreSQL 排空，零清理失败，CPU 观察器
退出 0。整体仍退出 1，功能默认关闭。

## 复用暂时拥塞的已准备输出（2026-10-31）

写入结果现在区分 `enqueued`、`temporarilyUnavailable` 和 `discarded`。NIO 仅在连接
仍活跃、未入队任何字节但有正文/响应积压或不可写时返回暂时拥塞；失效许可、关闭或
无效上下文直接丢弃。Dispatcher 在原有有界输出队列中保留原编码、序号、许可时间和
500 毫秒截止，最多按 10 / 20 / 40 / 80 毫秒延后四次。等待不占写入任务槽，健康连接
可以通过；原输出字节与活跃键继续计费，不重新读取资料或扩大队列。通道层没有另建队列。

新增回归让第一个连接持续忙碌，直到健康连接完成发送。旧行为未能恢复忙碌连接，
`/tmp/im-author-output-retry-red-tests-01.log` 一项失败（构建 120.12 秒，测试 3.016 秒）。
修复后验证两连接都交付，实际授权读取仍只有两份，重试字节与原截止完全相同；另一个
参数化用例验证原截止和页面离开都清除保留输出，不能迟到交付。

第一次组合回归中两个既有真实 NIO 用例仍等待额外授权读取，因新实现复用原输出而失败。
用例改为直接验证：套接字恢复可写但正文尚未排空时，资料重试仍不得抢先；正文排空后
自动发出原资料，授权读取保持一次。没有删除正文优先断言，并增加失败时的夹具清理。
两次增量构建分别 48.20 与 32.37 秒；最终真实 PostgreSQL 153 项、15 套件全部通过
（14.555 秒，无跳过），证据 `/tmp/im-author-output-retry-postgres-02/tests.log`，数据库
已停止及清除。接收端因果截止 7 项另通过（0.009 秒），确认准备后的排队/传输时间仍
被扣除，重试不会延长展示或下载许可。

`write_deferred` 只记录已安排的重试，不代表新授权读取或客户端已接收。新生产改动
尚待万人和 Linux 验证；真实故障/慢连接组合及最终审计仍未完成，功能默认关闭。

## 原输出重试后的万人验收（2026-10-31）

`/tmp/im-author-capacity-10000-p12-g4-release-24` 保持一万真实用户、十二 ClientKit 进程、
四网关、120 秒连续许可和头像替换。七阶段全部完成，所有客户端及驱动退出 0。
冷阶段资料 HTTP 尝试/响应均为 0，公共源读取 4 次/4 行，控制批次 360；房间快照
SQL 228 次、20,574 行，数据库实际执行累计 153.464 毫秒。进程 0 记录的冷阶段
耗时 2.260 秒包含全局屏障等待，不作为单客户端资料延迟。

热消息和 120 秒续期没有新增公共源读取或资料 HTTP；改名、换头像各增加 4 行公共源。
最终成功头像字节读取为 10,000，公共源累计 12 行，资料 HTTP 累计仍为 0。续期中有
有限工作过期与恢复，不能把零 HTTP 表述为内部没有重试或故障；最终四节点
`write_deferred` 合计 9 次，也不是九份新的授权读取。

`capacity-phases.json` 保留各阶段边界，`capacity-runtime-samples.jsonl` 保留五秒采样；
不能将后者跨阶段的计数归到冷阶段。`owned-cleanup.json` 与
`capacity-client-cleanup.json` 确认所有服务/客户端进程组排空、PostgreSQL 停止及零清理
失败；十二个客户端退出码均为 0，CPU 观察器也退出 0。本轮是最新修复后的一次完整
通过，不能据此覆盖未执行的故障组合或生产部署验证。

## 真实故障与慢连接组合

此项夹具通过 `--author-faults` 独立运行，最新 release-05 通过；以下保留首次准备和失败
记录，不能将已有内存/模拟授权网络基准或失败轮次计为通过。独立模式保留正常冷/热断言，并在热阶段后加入：

- 每个网关挑选少量真实 TLS 客户端，在字节读取边界暂停消费，以有界历史响应填充
  套接字缓冲；只暂停资料应用或 ACK 不算 TCP 背压。已有
  `im_v2_room_subscription_head_delivery_total{stage="socketNotWritable"}` 和
  `im_v2_gateway_foreground_nonwritable_deferrals_total` 指标可证明服务端通道实际不可写，无需为测试改变生产写入行为。
- 仅在夹具自建 PostgreSQL 中短时锁住 `im_v2.user_contact_aliases`，让资料控制查询
  真实等待/超时；用固定上限和 finally 释放，避免锁公共账号身份表而混入登录故障。
  同时经生产消息入口发送消息，验证正常接收者能确认、收到提示并补拉正文。
- 故障释放后，正常与慢客户端均须取得最新资料；保留旧许可原截止，拒绝迟到旧版本，
  校验队列/并发/字节上限和实际清理。明确记录允许故障回退的计数，不能把这项结果
  替代无故障万人冷启动的零 HTTP 条件。

TCP 中继只转发加密字节，双向总缓存不超过 128 KiB，暂停最多 10 秒自动恢复；服务端
方向暂停时仍允许客户端请求上行。四项真实回环测试通过，另有十四项夹具/清理测试
通过，覆盖只有真实资料失败、实际套接字不可写及仍持有数据库锁时才接受消息进展
证据。健康阶段明确只计每进程除慢连接外的用户，不能把尚未收消息的慢连接计入。
这些夹具验证与下文 release-05 的真实业务边界验证分别记录。

故障运行 `release-01` 未通过编译，原因为 Testing 宏处理键路径谓词，已改为闭包；
`release-02` 构建通过（220.82 秒），200 用户冷/热通过且资料 HTTP 为零，但故障阶段
超时。资料查询实际失败已记录，原夹具只采集末端通知的不可写计数，未观察到背压证据，
因此整轮失败。补充采集既有正文写入层的不可写延后计数后重跑，未修改生产传输行为。
前两轮拥有的服务与 PostgreSQL 均已清理；失败运行不能计入组合通过证据。
`release-03` 增加正文层观测后仍超时，两个不可写指标都为零，资料失败已发生；因此
明确是尚未产生所要求的通道背压，而非已通过但未采到证据。随后夹具把慢连接的
历史请求由 64 增至 192（低于生产连接的 256 请求上限），并发送 4,000 字节随机正文，
在不改生产预算的条件下填充真实发送缓冲。该轮的进程、锁和 PostgreSQL 亦已清理。
`release-04` 真实发生数据库锁等待和三次通道不可写延后，记录十次资料控制失败，
196 个健康用户在锁仍持有时完成消息与历史。释放后施压任务返回明确可重试
`RATE_LIMITED`，旧夹具将其作为失败，因此尚未完成全员恢复。调整仅影响施压结果
分类：逐项计数成功响应和带 1..60 秒退避的可重试限流，不重放，被取消或其他错误
仍失败；必须排空全部 192 个请求，并继续要求全部 200 用户收到最新资料。
该轮服务、客户端、锁和数据库均已清理。

## 故障组合通过记录（2026-10-31）

`/tmp/im-author-faults-p4-g4-release-05` 的 Release 构建 190.73 秒；四个独立 ClientKit
进程各有 50 个真实用户，四项进程内测试均通过（13.129～13.352 秒），驱动退出 0。
四个慢用户经过只转发 TLS 字节的独立中继。数据库事务实际持有 aliases 表排他锁
10 秒；证据时点有 12 次资料控制读取失败，节点 0、2 各观察到一次正文写入因实际
通道不可写而延后，另外两个节点没有记录不可写，不能声称四条通道都发生了同样背压。

作者从生产入口提交的新消息已接受，196 个健康用户在数据库锁仍被持有时收到对应
提示并拉到正文；屏障只计这些已完成用户。释放中继并等待锁事务结束后，四条慢连接
和全部 200 用户均取得最新资料，继续完成无消息改名、头像替换及 200 次图片校验。
九个阶段的资料 HTTP 尝试/响应始终为零；公共源累计 16 行，分别对应四个内容版本。

施压共 768 个历史请求，327 个取得完整页，441 个收到明确可重试、带一秒退避的
`RATE_LIMITED`；限流不是成功页，没有自动重放，全部请求均排空。故障证据时每网关
读取槽均为 2，队列/输出等被采集值均在原预算内；保护上限另由组件测试覆盖，离散
采样不冒充进程峰值测量。四个中继最大缓存分别为 16,384 / 31,048 / 16,384 / 65,536
字节，均低于 128 KiB；清理后线程全部结束、无中继错误，锁事务完成且无错误。

`capacity-faults.json` 保留真实锁、背压、读取失败和预算证据；`capacity-phases.json`
保留阶段人数和统计；两个 cleanup 文件确认四客户端退出 0、全部服务进程组排空、
PostgreSQL 停止及零清理失败。此结果覆盖本地真实客户端/数据库/网关故障组合，不
替代生产 CDN 或跨地域网络验收。

## 最新 Linux 构建与运行验证（2026-10-31）

`build/native-linux-release/runs/20261031T125906Z-e5d907e9` 对最新生产源码生成七个
Linux x86_64 Release 产品，构建累计 216.548 秒，manifest 为
`verified-linux-release`，源码漂移为空。覆盖本次排队截止下界、房间错误分类与原输出
重试，不再借用此前只覆盖部分修复的 Linux 结果。

`runtime-verification.json` 为 `passed-linux-loader-and-worker`，七产品哈希匹配且
动态依赖均可解析；实际图片 worker 在禁网容器中把 640×480 PNG 生成 320×240 和
640×480 两档产物。该项明确 `serviceEndToEndTest=false`，不能当作 Linux 业务全链路。
`/tmp/im-author-linux-final-01/cleanup.json` 确认只删除本轮镜像、关闭本轮启动的
`imv2-x86` VM，Docker 默认 context 保持 `default`，验证退出 0。

最终 Protocol 54 与 Actor protobuf 生成一致性、协议文档、schema readiness 表覆盖、
服务模块边界（零迁移例外）、Actor 序列化边界、文档结构/链接及差异空白门禁通过。
Python 夹具 18 项通过。未修改用户已有的 `V2RootView.swift` 七行删除；没有提交、
部署、开启生产流量或修正无关 App 下载设置基线断言。

## 完成条件逐项核对（2026-10-31，本地范围完成）

以下按本文原有十项条件核对，不以某个套件的通过替代整项要求。

| 条件 | 实现与覆盖证据 | 当前判断 |
| --- | --- | --- |
| 1. 实时、历史和恢复入口 | `V2AuthorPresentationGatewayTests` 覆盖群/私聊原消息与完整编辑、已准备历史响应和最新可见消息；个人同步拒绝公共正文。真实群消息/历史由 release-24 覆盖，私聊及编辑另见此前 54 项真实 PostgreSQL 回归 | 已有组件与真实边界证据；不声称生产全链路 |
| 2. 实际应用确认与省略 | `V2AuthorPresentationContextTests`、`V2AuthorProfileChangeDeliveryTests` 覆盖早到 ACK、失败写入、旧 view、变更期间旧 writer；新原子激活由 82 项客户端回归覆盖；release-24 冷/热资料 HTTP 为零 | 已验证 |
| 3. 公共内容共享与独立授权 | 不可变版本缓存与同键合并，控制域和房间域分别批量查询；最新 153 项真实 PostgreSQL 回归保持权限、签发期间撤权、房间归属与期限检查；release-24 冷公共源为每网关一行，权限查询仍按接收者执行 | 已验证 |
| 4. 原子变更与无消息更新 | `PostgresV2AuthorProfileChangeTests` 覆盖回滚、提交顺序、独立网关游标和保留缺口；`V2AuthorProfileChangeDeliveryTests` 覆盖初读/写入竞态和刷新义务；release-24 全员无消息改名及换头像通过 | 已验证 |
| 5. 版本和拒绝边界 | 独立公共、群昵称、备注、关系和双向拉黑下限；`independentVersionFloors`、`bilateralControlVersions` 及客户端权限拒绝/跨上下文测试覆盖旧响应不能恢复授权 | 已验证 |
| 6. 统一仓库与页面生命周期 | 账号共享协调器、完整 context、页面 nonce 与行引用；82 项 ClientKit、38 项 App 聚焦回归覆盖多页面、后台、结束、换账号和实际任务排空 | 已验证；未把无关 App 基线失败改为通过 |
| 7. 内容身份与两个期限 | 稳定媒体/变体/摘要身份复用图片，展示和下载许可独立；接收端 7 项因果期限回归、既有头像管线回归与 release-24 实际图片校验 | 已验证 |
| 8. 隔离、有界和恢复 | 153 项服务端回归覆盖实际槽位、正文优先、原输出重试、期限与清理；release-24 120 秒续期通过。release-05 进一步验证真实数据库故障、慢 TLS 连接和健康用户进展同时发生，以及全员恢复 | 已验证 |
| 9. 当前协议及旧路径退役 | Protocol 54、Actor session 2、Schema 76；旧普通私聊资料传播已删除，安全失效由专用 worker 承接；协议文档、schema readiness、服务模块与 Actor 边界检查通过 | 已核对，不提供旧版本混跑 |
| 10. 完整门禁及交付边界 | 最新组件、App、万人及清理结果见顶部；当前源码七个 Linux 产品、动态依赖和真实图片 worker 已通过；故障组合 release-05 已通过；最终工程门禁通过 | 本地范围已完成；生产边界见下文 |

生产 CDN 鉴权、边缘缓存命中率及部署不在本次本地实施交付中；没有接触或声称完成这些
外部操作。功能默认关闭。资源系统 9 月记录中的其他运营商、扩展传输和真机事项也不因
本次作者分发测试通过而自动变成已交付。

## 补充公开资料

- [腾讯云消息昵称与头像](https://www.tencentcloud.com/document/product/1047/39894)：消息附带资料，避免每条消息主动查询。
- [XMPP 头像协议](https://xmpp.org/extensions/xep-0084.html)：元数据与图片数据分开。
- [AWS 缓存工程经验](https://aws.amazon.com/builders-library/caching-challenges-and-strategies/)：并发合并和冷缓存故障边界。

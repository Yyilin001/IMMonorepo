# 应用级弱网实施任务与验收计划

日期：2026-09-27。状态：按当前工作区重新规划；基础网络、资料、偏好、名字编辑、离线入口和前台资源已有实现；完整应用仍未完成整体验收。

完整设计见[应用级弱网架构](application-weak-network-design.md)。本计划以当前代码为起点，不要求旧客户端、旧 schema、旧 DTO 或草案数据兼容。分阶段是为了逐条验证，不是让新旧运行模式长期并存。

## 当前整批收口边界

以下区分当前源码交付与最终验证，后文早期 protocol37/current59 等检查点是施工历史，不代表当前工作区已验证。

| 工作项 | 当前状态 | 进入最终验收前仍需完成 |
| --- | --- | --- |
| 普通持久业务 | Core32 kind 已映射30个App公共handler及2个专属资源引擎；旧App命令lane退役 | 最新组合编译、受影响夹具迁移和故障回归 |
| 私聊、审核、邀请 | 新原身份/回执/恢复已接Core、Server、Client和既有App入口；审核保留SDK能力 | 原proof、owner竞争、目录/配额、secret生命周期联合验证 |
| 四项隐私与在线发布 | 本地收紧、独立权威版本缓存、真实typing/readReceipt/presence叶子已接；后台连接保持presence抑制 | 撤权、快照低版本、连接重建与锁屏结果统一验证 |
| Push与设备列表 | Push使用账号executor/scheduler；设备列表明确403收回内容和操作资格 | 最新组合编译与真实错误路径回归 |
| 远程设备撤销 | 专属Keychain原ID journal、完整有界目标基线、永久proof/query-close、App核对和账号activity已接；旧remote入口退役 | 集中编译及原ID恢复、期限、冻结目标、迟到分页和关闭竞争回归 |
| 部署与协议 | 当前生产检查点protocol44/current63；邀请稳定HMAC key模板及正式探针依赖已补 | 设备撤销新schema合并后统一空库bootstrap、readiness和协议门禁 |
| 平台与容量 | 保留W5及第9节完整范围，没有由源码存在推定完成 | 真机后台、实际provider能力、故障矩阵及容量报告仍需实际证据 |

执行顺序：收口当前生产接线与已退役接口引用 → 集中完成组合构建 → 按第9节做统一回归与证据登记。远程撤销、当前schema及装配已有源码，仍待最新组合验证。除阻塞实现的必要诊断外，不恢复按小改动反复测试的节奏。不因当前缺少平台或容量证据而把完整目标缩减为“能编译”。

## 1. 交付关系

```text
W0 合同/清单/故障夹具
  → W1 HTTP执行与账户调度基础
    → W2 个人资料完整纵向链路
      → W3 全量持久命令与领域恢复
      → W4 查询/同步/启动体验
      → W5 分片/Range/后台能力
        → W6 全量装配与最终验收
```

W3/W4/W5 的部分实现不相互依赖，但必须共享 W0/W1 定义的状态、许可和错误协议；不得各自再创建网络重试框架。本计划不预设团队人数或未经验证的工期。

每项交付均包括：运行时代码、生产装配、受影响测试、schema/readiness/协议生成物（如涉及）、对应当前合同、可复现证据。仅添加一个未被 App 构造的工具类型不算完成。

### 1.1 从当前工作区开始的实施顺序

W0–W6 是完整能力分组，下面是实际施工顺序。先收敛当前改动，避免继续堆积无法构建的半条链路。

| 批次 | 范围与文件落点 | 必须交付的闭环 | 前置 |
| --- | --- | --- | --- |
| A 当前检查点 | Core/Server/ClientKit/App、生成协议与当前 schema | 以协议 37/current59 为已验证起点；群管理新表后重测 SQLite 快照，服务端新增表同步更新 schema/readiness；跑最新组合及全量构建 | 当前工作区 |
| B 消息链路 | messages/withdrawals/edits/reactions/readReceipts + forwardPlans | 原消息身份复用、未知恢复、同消息变更串行、已读 max、转发父子计划；每迁一组删除旧 lane/调度字段 | A |
| C 社交与群管理 | membership/memberMutes/moderatedMemberRemovals/groupCapabilities/social/groupCreation；邀请、审批、群头像与设置 | 当前权限与短期确认、owner-aware execute/query/close、跨库 outbox、明确 processing；删除旧执行入口 | A；公共接口与 B 一致 |
| D 全页面读取 | QueryCoordinator、各 Repository、App 页面状态与可见域订阅 | 冷启动只读、在线升级、失败留内容、独立 stale/error、generation/revision/lease 三重校验；正文不等待头像 | A |
| E 资源完成 | resource journal/TransferEngine、DurableConversationSendService、provider adapter、后台桥接 | 现有 multipart/Range 回归；删除剩余固定扫描；后台系统 task 对账和真实供应商验证；共享暂存容量 | A；后台以服务端 capability 为前置 |
| F 入口收敛与治理 | endpoint registry、Push/设备/认证专属策略、metrics、服务端准入 | HTTP/Gateway/App 三向清单完整，无绕过 executor 或重复 owner；重试放大和恢复洪峰测量 | B–E |
| G 交付验收 | 故障夹具、CI、空库启动、部署说明 | 全量构建、协议/schema 门禁、端到端故障矩阵、真机后台、容量报告；删除替代代码 | B–F |

B/C/D/E 可以按文件所有权分工；Core/schema 和 App 装配分别由固定集成人收口。每批按“合同 → 权威存储 → 客户端持久化 → 生产 UI → 故障测试”交付。规划不要求本轮启动并行实施，也不据部分测试推断全量通过。

当前检查点之后，优先关闭以下具体缺口，再以 B–G 完成全量范围：

| 优先级 | 缺口 | 交付条件 |
| --- | --- | --- |
| P0 | 已读原回执与当前水位证明必须分离 | 已修正原回执优先并通过真实 PostgreSQL 退群/清理测试；纳入最新组合回归 |
| P0 | 消息新执行链路联合验收 | send/edit/withdraw 原结果、期限、关闭竞争与事务回滚已定向验证；完成客户端/App 夹具迁移与全量回归 |
| P0 | 调度异常恢复的整批验证 | 当前源码已有 activity failed 状态、App accountWorkPaused 展示与 resumeAccountWork 显式重建并排空旧账号任务；仍须统一验证存储失败、迟到结果和原预算不重置 |
| P1 | 公共额度尚不能证明全链路容量 | 所有未冻结意图、原操作、资源暂存均计入；每房间上限与清理事务实测 |
| P1 | 独立持久控制预留联合验证 | 已读归档恢复使用同work控制类别的64项/1MiB独立额度；再次提交必须原子转普通额度，失败保留控制记录。须验证普通满额仍可核对、控制满额事务回滚、重启及禁止借槽submit；scheduler等待者额度另算 |
| P1 | 终态/归档生命周期待统一验证 | 源码已保留依赖/文件与未知记录；已读currentUnavailable可转独立256条/1MiB归档，原ID恢复先query、本地阅读位置保留；需验证事务回滚、容量与重启恢复 |
| P1 | 前台续传不等于后台完成 | W5.5–W5.7、真实设备锁屏/重启/强退和实际 provider 证据齐全 |

这些是实施入口，不是将其他领域降为可选。库存式“类型已存在”检查必须补充生产调用链与故障证据。

### 1.1.1 最新施工检查点与依赖修正

主设计第 2.4–2.6 节是本次复核后的起点。下面列出各项实际状态与后续交付；每个检查点必须能够独立构建和评审。

| 顺序 | 具体交付 | 完成证据 |
| --- | --- | --- |
| A0 工作区收口 | protocol37/current59 已有检查点；新增群管理表、Server store 和步骤 metrics 未完整接线 | 最新版本全量编译、空库 bootstrap/readiness、协议/schema 门禁；不能引用修改前测试代替 |
| B1 转发部署验收 | 账户 HTTP、owner-aware port、父 manifest、worker、逐子恢复与 App 已接线，有专项证据 | 补真实跨进程 accountBaseURL 链路，部分成功丢响应、worker 重启、owner 迁移；保留当前专项回归 |
| E1 资源准入验收 | 上传/导入 32 个活跃额度与所有 preparation/replacement 事务 helper 已实现并专项验证 | 保留 31+2 回滚、重放、未知占额和两连接竞争回归；补平台暂存峰值，不重复建设准入层 |
| C1 群成员与管理 | membership、mute、removal、capability 分别完成短期确认、权限重验、原回执恢复及 UI | 撤权、期限、execute/close 两种顺序均通过；每组删除旧 lane/计数/循环 |
| C2 社交与创建 | social、groupCreation、邀请/审批按真实领域拆分；跨库工作持久 outbox | 重复申请/创建与响应丢失无重复实体；processing 不显示完成；原回执不被当前关系替代 |
| F1 入口与特殊流程 | 可执行 registry、认证/Push/设备专属预算与独立作用域，清除绕过入口 | 未登记、错 origin、空账号、旧 activation 被拒绝；生产实际构造通过；取消排空与刷新无死锁 |
| D/E/G 完整验收 | 页面读取、终态清理、资源 provider/真机、故障与容量验证 | 按第 9 节分别记录开发门禁、平台联调、部署容量证据 |

普通持久操作、专属认证/资源、读取三个执行领域不得各自复制全局网络重试层。并行实施可以按服务端权威、客户端持久执行、HTTP/读取/资源拆分；共享 Core 合同先定稿，schema 与 App composition root 由明确集成人负责。按用户最新要求，生产业务先整批收口，测试夹具迁移、组合构建和回归随后集中执行；仅提前处理确实阻碍实现的问题。

旧路径删除验收要求：实际生产构造没有旧 engine/lane；旧 API 无调用；旧表/索引/状态字段不再出现在当前建库定义；相应旧测试改验新合同，而非简单删除覆盖。安全的业务投影、资源引用、同步游标和原回执继续保留。

### 1.2 备注与群昵称的具体纵向合同

- 备注：`GET/PUT /v2/profile-presentations/contact-aliases/{target}`；昵称：`GET/PUT /v2/profile-presentations/groups/{room}/nickname`；各自在同路径下 `POST operations/recover`。
- GET 返回本人可编辑字段的 typed snapshot，包含 actor、scope、可空 value/revision；它不是目标公开资料的展示 lease。当前关系/成员资格仍由服务端检查。
- PUT 的不可变 command 包含 actor/scope/operationID、expectedRevision、规范化目标值、firstSubmissionDeadline；回执校验身份、指纹、目标值及提交 revision。nil 基线表示此前没有该字段记录，不能表示“忽略版本”。
- 备注/昵称在保存时按编辑器已观察基线立即冻结 command，与公共 work 同事务入库；不在队首自动替换 expectedRevision。未知结果先 query；close 与 execute 同锁。后继不会越过未知前序。冲突后显式刷新仅更新基线并保留输入，用户重新应用才建立新 operation。
- 页面分开展示当前确认值与本地待同步值；清空名称也是带 revision 的写入，不能删除版本后让旧操作重新生效。
- 备注/昵称立即冻结，因此由公共 work 容量直接统计；资料/偏好等存在未冻结意图的领域仍须纳入共享容量。Server 终态表、readiness 和一次性 PostgreSQL 测试与路由同批落地。

### 1.3 剩余命令逐组设计与删除项

以下是下一步实施合同，不表示各 lane 已完成。每个 adapter 须交付 submit/recover、验证回执、落库和 UI 状态五个部分；业务类型可以共享代码，但不能共享错误的权限或顺序语义。

| 现有 lane | 目标顺序与完成条件 | 专项验收 |
| --- | --- | --- |
| messages | send(room)；复用 clientMessageID 与原发送完成事实；附件 Ready 后提交 | 服务端提交后丢 ACK、重启仍只有一条消息；本地入队失败不出现已保存 |
| withdrawals / edits | mutation(message)；保留原消息所有权、可编辑时限和 revision；未知前序不得越过 | 编辑 A 未知时编辑 B 不覆盖；撤回与编辑竞争返回确定领域结果 |
| reactions | actor/message/reaction；明确目标状态，可合并未冻结后继 | 添加/移除乱序及多设备竞争；未知操作不修改 payload |
| readReceipts | actor/room；合法可见 watermark 取 max，无普通内容命令首次窗口 | 乱序回执不倒退；退群或不可见 sequence 不借 max 越权 |
| forwardPlans | 父计划与有界子发送；每个子身份固定，父完成取决于全部子结果 | 部分成功后重启只恢复未终结子项，不整批生成新 ID |
| membership | room/target；成员资格/角色/当前 owner 检查 | 退群成功但响应丢失，之后仍能读自己的最小回执 |
| memberMutes / moderatedMemberRemovals | room/target/管理动作；短期在线确认，提交时重验权限 | 管理员失权、owner 切换、重复执行、关闭竞争 |
| groupCapabilities | 按字段/实体 revision 分流，不能用一个通用 toggle | 公告、权限、置顶等各有策略；收紧隐私与放宽权限分开 |
| social | 按 user-pair 或本人设置字段分流；关系状态机保留 | 拉黑与申请竞争、旧回包、关系结束后原操作核对 |
| groupCreation | 原创建身份；群 ID/创建阶段由权威回执给出，processing 非成功 | 已创建未回包不会创建第二个群；跨域后续工作由 outbox 恢复 |

已读回执已接入公共执行；发送、编辑、撤回、reaction 及转发已替换旧执行入口。当前 App 旧 lane 与 SDK redactions 待发执行已退役；公共 dispatcher 已注册私聊、审核、邀请等独立入口，最新组合仍待统一回归。邀请/入群审批、群头像、Push 与设备安全入口不一定属于原 12 条 lane，必须单独覆盖。群头像和资源依赖沿用专属合同；Push/认证专属 intent 不复制进第二套普通 journal。

#### C1 禁言与移除成员的施工拆分

| 次序 | 落点 | 完成条件 |
| --- | --- | --- |
| 1 | Core `MemberAdministrationOperation`、Server `PostgresV2MemberAdministrationStore` | 已有类型/store 编译检查；补当前 schema/readiness、目标成员代次、原回执与权限检查顺序，真实 PostgreSQL 事务回滚与关闭竞争测试 |
| 2 | RoomRef、账户 HTTP composition root、route registry | admission/submit/recover 三入口真正可达；提交重验权限和 CAS；账户服务不绕过 owner 直接写房间 |
| 3 | ClientKit `V2MemberAdministrationWork` 与准备服务 | 已有 draft/store/client；补固定确认窗口、跨 activation 处置、原子冻结、观察流、公共 dispatcher，重启不续期 |
| 4 | App 群管理 Store/Service/View 与 Runtime | stale 禁新动作、原操作独立核对、明确重新确认；离页不撤销持久操作；UI 只从持久事实显示完成 |
| 5 | 旧 lane/API/表字段及 Gateway 分派 | 新纵向通过后删除 mute/remove 旧执行；旧无 admission 请求明确拒绝且不调用领域写入；测试改验拒绝而非删除覆盖 |
| 6 | SQLite/PostgreSQL、Core/ClientKit/Server/App 回归 | 满额、磁盘失败、失权、成员离群再加入、截止前后、提交与关闭竞争、提交成功后丢响应、重启及 owner 切换逐项有证据 |

同目录 revision 的无关变化也触发重新确认；先接受这个保守冲突策略。冻结前重新确认与已发原操作核对是不同动作，不共用一个“重试”按钮。此批闭环后才按相同工作包推进 membership/groupCapabilities，随后 social/groupCreation；不会因两条管理 lane 完成而宣布 W3 完成。

每组删除清单：AppRuntime 中相应 flush lane、页面直接 flush、旧 nextAttempt/claim/attempt 字段、旧轮询入口，以及已被原回执替代的短期幂等台账。保留业务投影、原消息身份、领域资源引用与必要 owner fence。删除前通过静态调用搜索和生产构造测试证明新入口完整，不做双写过渡开关。

### 1.4 可交付工作包

每包以一个领域组为单位，交付下列可检查产物：

1. Core：身份、规范化 payload、指纹 golden vectors、终态证明、首次期限与 replay 规则。
2. Server：权威 owner 路由、事务内 execute/query/close、不可变回执、持久 outbox；当前 schema/readiness 同改。
3. ClientKit：原子入队、claim 恢复、同 key 顺序、有界预算、旧失败回包围栏及明确存储失败。
4. App：pending/confirming/needsAttention/conflict/committed 状态、继续核对/关闭/重新应用入口，离页不取消已保存工作。
5. 验证：真实 SQLite、一次性 PostgreSQL、两端 codec、App 注入与故障测试；删除旧路径并更新当前合同。

准备任务也必须有业务截止：例如资料头像等待不能越过资料首次窗口继续冻结；超期关闭 preparation，保留可恢复草稿/源文件，释放资源引用按明确生命周期处理。业务截止与资源自身预算分别管理。

### 1.5 发布门槛与范围控制

第一道门槛是“当前版本从空库启动 + 同版本恢复 + 相关构建全部通过”。无历史兼容不等于允许当前版本崩溃后丢任务，也不等于可以自动删除开发库。schema 改动只给出显式重建说明与一次性测试夹具。

第二道门槛是“每个业务入口都有成功、未知、确定拒绝和用户处置闭环”。只有基础组件或文档中有登记、App 未接线的能力不能计入。

第三道门槛是“真实平台/供应商能力与文案一致”。后台未验证时只广告前台恢复；分片 provider 未完成时明确整文件重传。完整方案仍须关闭这些缺口，不能把降级声明当作永久完成证明。

本规划不承诺未经估算的日历工期。以以上七批的构建和故障证据作为检查点；若排期受限，应明确缩小发布能力范围，保留完整方案的未完成项。

发布采用单一当前版本：停止旧版本写入入口，部署一致的 schema/readiness、Server 与 App，协议不匹配明确拒绝。先在独立空库/临时账号验证，再执行经明确安排的环境切换。回滚以整套匹配的应用、协议、schema 和数据快照为单位，不能让旧二进制连接新 schema。此处是部署设计，不授权本轮删除或重建任何开发数据。

## 2. W0：合同、全量清单与基线

### 修改落点

- [IMV2Core](../../IMV2Core/Sources/IMV2Core)：新增 operation 身份/结果/恢复合同、确定性指纹编码、策略强类型。
- [协议](../../Protocol/im_realtime/v2/im_v2.proto)：登记修改后的 command/result/recovery shape；同次更新 protocol version 与两端生成代码。
- [schema.sql](../../IMV2/sql/schema.sql)、[V2LocalSchema](../../IMV2ClientKit/Sources/IMV2ClientKit/V2LocalSchema.swift)：画出目标字段/约束与去除项，先完成实际 schema diff。
- [V2SchemaReadiness](../../IMV2Server/Sources/IMV2Server/V2SchemaReadiness.swift)：为新增表、索引、函数及不变量登记 readiness。

### 必须产出的端点登记清单

对 `V2Vapor*Routes`、Gateway 命令分发和所有 App service 调用交叉盘点，建立测试可读的穷尽注册，而不是只列 URL。每项必须登记：

```text
kind / HTTP或protobuf入口 / 生产装配调用方
执行权威与路由 / 持久payload及回执 / operation key
query或command或transfer / 敏感性 / 离线行为
orderingKey / revision / 首次受理窗口 / 合并规则
retry预算 / recovery入口 / 终态证明 / 资源上限
本地读模型更新方式 / 失效标签 / 对应测试
```

必须覆盖消息及变更、read receipt、conversation/group capabilities、social、group creation、forward plans、个人资料、contact aliases、group nicknames、group avatar、invitation/join/decision、live activity preference、Push、认证/设备/安全及资源操作。尚未上线的 passkey 服务端能力不因本任务被声明可用。

### 验收

- 同一语义 payload 不因 JSON 字段顺序/token/attempt 改变指纹；expectedRevision 或业务字段改变必然冲突。
- terminal receipt 与普通错误分开，unresolved 不能构造为未执行证明。
- 每个生产 command 都有登记；unknown kind/非法字段组合不能进入执行器。
- 记录现有首屏读取、黑洞请求、命令突发和上传中断的基线，不预填测量结果。

## 3. W1：HTTP 执行、工作准入和运行时

### 修改落点

| 现有文件/区域 | 动作 |
| --- | --- |
| [V2SecureURLSession](../../IMV2ClientKit/Sources/IMV2ClientKit/V2SecureURLSession.swift) | 保留安全配置，扩展 metrics delegate、按任务取消与有界响应收集 |
| [V2SessionHTTPAuthorization](../../IMV2ClientKit/Sources/IMV2ClientKit/V2SessionHTTPAuthorization.swift) | 保留 epoch/token 栅栏；提供刷新结果给语义执行器，清楚区分普通 401 与会话终止 |
| [V2HTTPAuthTransport](../../IMV2ClientKit/Sources/IMV2ClientKit/V2HTTPAuthTransport.swift) 及 HTTP clients | 归一化状态码、错误码、Retry-After、协议失败；不再压成无信息 networkFailure |
| ClientKit 新 Networking 区域 | V2HTTPExecutor、V2AccountWorkScheduler、V2QueryCoordinator、V2QualityObserver、V2NetworkMetrics |
| [V2AppStore](../../IMApp/IMApp/V2/V2AppStore.swift) 与 [V2AppRealtimeRuntime](../../IMApp/IMApp/V2/V2AppRealtimeRuntime.swift) | 新 V2AccountRuntime 装配；网络恢复所有权移出 UI；HTTP/TCP 独立可用 |
| [V2ClientSessionBootstrapper](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ClientSessionBootstrapper.swift) 与 [V2AccountLocalStoreOwner](../../IMV2ClientKit/Sources/IMV2ClientKit/V2AccountLocalStoreOwner.swift) | 本地只读恢复与在线认证激活分开；Keychain/安装/退出标记仍是开启本地投影的前提 |
| [V2ClientRuntime](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ClientRuntime.swift) | 连接就绪与追赶分开，及时启动心跳/reader，等待者取消不取消整个账户运行时 |

调度器先支持 query 与一个独立测试 command lane；W2/W3 将实际业务全部接入。不能在底层包装库和调度器各重试一层。

### 验收

- 30 个同代 401 只有一轮 refresh；新 token 建立后旧 401 不清凭据。
- 认证尝试总次数有界；一次性证明请求不被自动重放。
- 所有普通槽被慢请求占用时，认证保留通道仍可用；刷新等待不造成 permit 死锁。
- 叶子请求只领取一次 permit；复合领域步骤不持槽等待自己的子请求，异常/取消只释放一次。
- 同 key 串行、不同 key 并行；底层未停止不提前释放物理槽。
- Retry-After 秒数/日期/溢出/负数和 UI 截止测试；不给错误 code 建立错误的终态。
- API 可用而 TCP 黑洞时，资料读取和结果核对正常获得预算。
- 账号切换/后台取消后的回调不能写新账号 DB；连接 generation 既有测试保持成立。
- access token 过期且离线冷启动，可展示允许保留的本地投影；已退出/撤权/Keychain 锁定时不能走此入口。

## 4. W2：个人资料与头像意图

这是第一条真实纵向样板，覆盖 HTTP、上传依赖、版本冲突、未知结果、页面生命周期与服务端事务。

### 修改落点

- [V2PublicIdentitySettingsUI](../../IMApp/IMApp/V2/V2PublicIdentitySettingsUI.swift)：store 只维护编辑草稿、观察保存 intent；生成 operation 的逻辑移到持久化 Service。
- [V2HTTPOwnProfileClient](../../IMV2ClientKit/Sources/IMV2ClientKit/V2HTTPOwnProfileClient.swift)：字段 patch、原回执/当前快照分离、recover/close，统一错误。
- 新 `V2ProfileIntent`/`V2ProfileIntentEngine`/GRDB payload：原子保存意图、附件引用及公共 work；同 profile 顺序。
- [V2VaporProfileUpdateRoutes](../../IMV2Server/Sources/IMV2ServerHTTP/V2VaporProfileUpdateRoutes.swift)、[PostgresV2ProfileUpdateStore](../../IMV2Server/Sources/IMV2Server/PostgresV2ProfileUpdateStore.swift)：提交与关闭共享锁，写不可变原回执和确定终态；保持资源绑定/GC 事务。
- 现有 resource journal：个人头像消费者加入文件保护/释放谓词，不能仅在消息和群头像完成时判断文件可删。

### UI 完成状态

保存后立即回到可操作页面，显示「已保存，等待同步」「正在上传」「正在确认结果」「已保存到服务器」或「需要处理」。离开页面只取消观察；账户运行时继续合法任务。冲突保留编辑草稿并展示服务端值，用户决定重新应用；不能通过 load 覆盖用户尚未保存的输入。

### 验收

- 服务端提交后丢回包，重启恢复同 operation；profile revision/传播 outbox 只增加一次。
- A 成功、B 后来成功、重放 A：A 回执仍指向自己的 revision，UI 保留 B 的较新值。
- 改昵称不会把另一个设备的新头像改回旧头像。
- 上传 Ready 后资料提交未知，源文件不会被早删；query/close 与 late submit 两种竞争顺序均正确。
- 保存本地事务失败不显示已保存、不丢草稿；页面取消不清除已入库意图。
- App 离线退出再登录同一账号仍能恢复；登录另一账号看不到也不能执行原意图。

## 5. W3：全部持久命令收敛

### 消息纵向的当前检查点与剩余验收

发送、编辑、撤回已接公共 work、强类型首次截止、原回执及 query/close，旧生产执行入口已删除。reaction 已增加本人单 key 基线、expectedReactionRevision、首次截止与永久回执，并接入公共执行；不能从聚合反应列表推断本人的 revision。服务端事务沿用 RoomRef activation fence，提交、查询、关闭共享原操作锁。

剩余工作是收敛最新测试夹具与 schema 快照，验证 App 装配、同 key 后继顺序、全量回归和真实故障链路；批量转发的父子计划仍需独立完成。历史专项通过不能作为 protocol36/current58 整体验收。

### 本地存储与执行

改造 [GRDBV2LocalCommandStore](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalCommandStore.swift)、[GRDBV2CommandRetrySchedule](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2CommandRetrySchedule.swift) 和各 `V2*Outbox`：

- 公共执行状态/claim/计数/nextActionAt 同源，领域 engine 改为单步执行器。
- 所有剩余旧 lane 及独立业务入口全部接调度；HTTP profile/群头像/邀请/备注/群昵称等写入也登记。
- UI 直接调用 outbox.flushOnce 的入口改为「入队 + 请求调度 + 观察指定 identity」；不能沿旧入口绕过准入。
- 增加 submission_started，并将未知从 rejected 中剥离；过期改为首次未发送过期或结果核对。
- 删除 `expireStalePendingCommands` 的通用失败语义和固定 1 秒 fallback；保留领域特定的必要清理/暂停行为。
- 容量检查与入队原子；同 key head-of-line 判定、依赖 DAG、未冻结合并与后继 intent 都持久化。

### 服务端领域覆盖

| 分组 | 需覆盖的结果与恢复 |
| --- | --- |
| 消息 | 原接受 receipt、MEDIA_UNAVAILABLE 后核对、主动 close、永久关闭后的显式替代 |
| 编辑/撤回/reaction/read receipt | 原 revision/watermark、明确冲突、权限失效后的最小结果核对 |
| 会话/收藏/个人设置 | 目标字段 revision，避免退避中的旧操作晚到覆盖新值 |
| 社交/成员/群权限 | 原关系/成员/权限结果；确定拒绝与准入错误分离；不重新应用已完成管理操作 |
| 建群/邀请/入群/审批 | 保留现有多阶段仲裁；processing 与终态分开；查不到不表示取消成功 |
| 批量转发 | 保留父/子操作与逐项完成；已完成部分不重复；未发起部分可取消，已发部分核对 |
| 群头像/昵称/备注 | 统一执行元数据；原有 lease、关闭 proof、资源 GC fence 继续成立 |

使用现有 owner-aware 服务与 store，不让 Account HTTP 绕过房间 Actor 直接写 room 数据库。跨库场景必须测试真实独立 PostgreSQL 库，而非只在同库换逻辑 ID。

### 验收

- A → B 同 key；A 超时/退避，B 不越过 A。前序关闭后才允许替代身份。
- 未发送 true→false 合并，已发送 true→false 保留两个身份并最终按声明规则收敛。
- claim 领取后崩溃计数不回退；旧 attempt 失败不得覆盖成功；同 ID 不同 payload 确定冲突。
- 用户取消等待、关闭原操作、业务撤销三种行为分别测试。
- 满 2,000 项/32 MiB 拒绝新业务，已有任务和必要核对继续存在。
- 30 天之外/时钟跳变不把未知成功改失败；已过首次截止的未受理命令不能迟到执行。
- 把关闭和提交竞争顺序随机化，任何序列都不同时存在 committed 与 closed。

## 6. W4：读取、授权展示与同步

### 修改落点

- [V2ProfileRepository](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProfileRepository.swift) 与新增 own-profile snapshot：缓存用途/保留合同、版本保护、失效。
- [V2ProfilePresentationRepository](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProfilePresentationRepository.swift)、[V2GroupAvatarPresentationRepository](../../IMV2ClientKit/Sources/IMV2ClientKit/V2GroupAvatarPresentationRepository.swift)：保留合并/lease/activation，在网络发起处接 shared permit。
- [V2RoomRecoveryRunner](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoomRecoveryRunner.swift)、[V2SyncEngine](../../IMV2ClientKit/Sources/IMV2ClientKit/V2SyncEngine.swift)：可见域优先、有界页面、独立启动，不改变数据+cursor 原子提交。
- App 会话/联系人/本人资料/成员目录/搜索 stores：已有内容刷新失败保留，草稿独立，局部错误，稳定 queryGeneration。

### 验收

- 初次失败/空结果/已有内容刷新失败/展示资格过期四种状态可区分。
- 多订阅共享读取，单个取消不影响其他人；authority 查询不误用 cache-only 结果。
- A 搜索/刷新晚于 B 返回，A 不能替换 B；写入 revision 12 后副本 11 不回退。
- 缓存图片存在但 lease 过期/撤权仍不可显示；过期查询不跨账号/activation 复用。
- Snapshot reset 保留 work、草稿和资源引用；数据与 cursor 任一提交点崩溃都可恢复。
- 冷启动本地列表显示不等待 TCP；后台历史追赶不挡当前发送和头像小控制请求。

## 7. W5：资源恢复与后台适配

### 分步交付

| 子任务 | 实施内容 | 完成证据 |
| --- | --- | --- |
| W5.1 | `V2ResourceUploadControlling` 扩展有界 part target/status/finalize；provider adapter 返回实际能力 | 本地参考 multipart adapter 合同与重复 part/finalize 组件测试 |
| W5.2 | [V2HTTPResourceUploadClient](../../IMV2ClientKit/Sources/IMV2ClientKit/V2HTTPResourceUploadClient.swift)、[V2ResourceTransferEngine](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ResourceTransferEngine.swift) + part journal | 中断/重启只上传缺失 part；签名过期不丢进度；服务端原生 part 状态为权威 |
| W5.3 | [V2MediaTransfer](../../IMV2ClientKit/Sources/IMV2ClientKit/V2MediaTransfer.swift) + download journal + local Range adapter | 206/200/416、换版本、摘要失败、落盘中断与最终 rename 恢复 |
| W5.4 | [V2DurableConversationSendService](../../IMApp/IMApp/V2/V2DurableConversationSendService.swift) 拆出短步骤、事件唤醒和独立状态查询 | 无每 5 秒全量扫描；慢上传不挡群头像核对；所有直接重试入口经 scheduler |
| W5.5 | 新后台 coordinator、AppDelegate 事件桥接、专用暂存保护策略 | task 映射/孤儿恢复/晚回调/登出隔离组件测试；平台实测另列 |
| W5.6 | Server 狭义后台对象授权、逐计划资格、撤销与 provider 限制 | 不延长普通 presentation/activation lease；过期/撤销/越界 part 均拒绝 |
| W5.7 | 现存系统任务计入 scheduler、锁屏结果交接和暂存容量 | 前后台无重复 owner；无完成回包按原 session 核对；锁屏不死等业务库 |

不以开通外部云账号作为本地开发前提。先通过现有可注入 ports 与本地参考适配器证明协议，再按实际供应商能力配置；不声称任意供应商已支持。

后台功能按 server capability 生效。当前 120 秒展示 lease 不直接改为长时后台资格。只支持 foreground 的目标仍可完成前台断点恢复；在 UI/诊断中如实报告能力。

后台实施依赖顺序为 W5.6 合同冻结 → W5.5 任务桥接与 W5.7 调度/存储 → 真机验证。不能先把 capability 设为 true 再补授权边界。

### 验收补充

- 资源 Ready、业务 committed 与 UI 投影收敛是三个不同节点。
- finalization 与 cancel 竞争、提交与 GC 竞争、共享文件新增引用与释放竞争均有测试。
- 磁盘满/文件丢失不得一直归为网络重试；进入可处理暂停，禁止丢原操作身份。
- 后台上传用文件源；系统任务创建与映射两侧崩溃都可恢复；签名过期不可绕过授权。
- 同一账户重启恢复，跨账户不可见；正在播放/外部分享的借用文件不能被缓存淘汰。

## 8. W6：最终收敛与删除清单

下列替代路径须在生产装配中消失；保留测试 fixture 不代表可以保留双运行模式。

- AppStore 自有指数重连循环 → 账户 runtime 重连调度。
- `V2FairDurableCommandScheduler` 的逐条等待总循环 → 公共并发 scheduler；文件可删除或改为新实现，不保留两套入口。
- 各 outbox 的固定重试算法/重复调度状态 → 公共 policy/work；领域特有结果逻辑保留。
- 个人资料页面临时 operationID 与上传后直接 PUT → durable profile intent。
- 固定五秒资源恢复扫描及占槽轮询 → 持久 nextActionAt + DB wake + 单步执行。
- “未知 = rejected”与“超过幂等窗口 = 已失败” → execution certainty + scheduling status。
- 未经策略声明直接 URLSession 的业务调用 → 明确注册的 HTTPExecutor/资源 adapter；认证和系统底层桥接保留专用入口。
- 无主 actor/Task、无上限新队列、第二份操作状态、没装配的抽象与临时开关 → 删除。

更新现有当前合同索引、系统地图与实现状态，只声明实际实现和实际运行结果。后续把本提案标为已实施/被哪份合同接管，避免另起一条追加历史时间线。

## 9. 故障矩阵与证明等级

| 编号 | 故障/交错 | 必须成立 |
| --- | --- | --- |
| F01 | 入队事务失败/磁盘满 | 不报保存成功；草稿仍可见 |
| F02 | 标记发送后、真正发送前崩溃 | 同身份核对/恢复，无新 ID |
| F03 | 服务端提交后丢响应 | 副作用一次，能查原回执 |
| F04 | 成功响应后本地写库失败 | 保持未知，可再次核对 |
| F05 | close 和迟到 execute 两种锁序竞争 | 恰有一个最终事实，不出现关闭后执行 |
| F06 | 旧失败/旧 token/旧 socket 回调晚到 | 不回退终态、不删除新凭据、不关新连接 |
| F07 | A 退出、B 登录、A 回包；A→B→A | DB、文件、展示和 task 映射隔离；同账号合法恢复 |
| F08 | 同 key A 退避，B 到期；跨 key C 到期 | B 不越序，C 可推进 |
| F09 | 多设备并发修改/expectedRevision 冲突 | 终结原操作后明确重基线/提示，不盲目复用 ID |
| F10 | query unresolved/404/403、原请求仍在途 | 不推断没执行，不创建替代 |
| F11 | 过期、时钟前后跳、Retry-After 超 UI deadline | 不提前重试、不延长授权、不停止必要核对 |
| F12 | 30 个 401、刷新响应丢失、Keychain 锁定 | 单飞原 refresh operation，临时失败不登出 |
| F13 | 本地列表存在、所有网络请求失败 | 内容保留；受限展示按 lease 失效 |
| F14 | cursor 应用/ACK/快照激活边界崩溃 | 不跳增量、不清 outbox/草稿 |
| F15 | 上传 90% 中断/finalize 响应丢失 | 复用原会话和确认 part，无重复发布 |
| F16 | 下载 206/200/416/资源 generation 变化 | 不拼接错文件，通过完整性才发布 |
| F17 | owner 迁移、旧 worker 回包、控制/房间分库 | 旧 fence 不写新事实；恢复访问正确权威 |
| F18 | 单机 1k 客户端同刻恢复/客户端 2k backlog | 有界并发、无重试洪峰，关键工作有机会 |
| F19 | 慢上传/资源服务故障而 HTTP/TCP 正常 | 命令控制不被资源工作串行阻塞 |
| F20 | 系统挂起/强退/重启/锁屏/后台晚完成 | 不承诺无执行窗口时送达；下次允许时正确恢复 |

证明分三层记录：

1. **开发门禁**：纯模型与 fake-clock 单元、真实 GRDB/临时 PostgreSQL 组件集成、可控 Network.framework peer、模拟器组件测试。对每个核心状态机加入固定 seed 的随机事件测试，失败输出可复现序列。
2. **平台联调**：真实账户 HTTPS/TLS、iOS scene/Keychain、后台 URLSession、锁屏/强退；单列环境和证据，不被第一层替代。
3. **部署/容量**：真实 provider/CDN、跨故障域数据库、远程多 owner、恢复洪峰和生产指标。实验参数和容量必须附环境，不把配置值当测量结果。

按用户最新要求，F18 本次单机连接恢复验收规模调整为 1,000；不再以 10,000 连接作为本次交付门槛。客户端 2k backlog、公平调度、真实非空积压及原游标追赶要求保持。F18 的客户端调度部分可在开发门禁完成，单机连接恢复另列容量证据；交付报告必须分别列实现完成度、已通过层级与未验证能力。既有 10k 尝试保留为历史记录，不改写成 1k 通过，也不据单机结果宣称部署容量。

现有 Gateway load generator 已补[显式同步恢复模式](../../IMV2/docs/09-capacity/gateway-recovery-burst-driver.md)：可让最多10k连接各自参与同一启动屏障，保留断线前游标，记录实际启动分布、认证结果及权威目标追赶。此模式尚未运行验收；不覆盖App持久工作调度，也不能把连接成功或无积压恢复计为完整F18通过。

## 10. 仓库验证入口

规划核验使用文档和差异检查；基础组件测试不能代替各阶段验收。下列构建/测试是实施时按受影响范围执行的现有入口。

```sh
# 集中收口时的文档/合同检查
bash scripts/check_v2_document_links.sh
bash scripts/check_v2_document_structure.sh
git diff --check

# ClientKit：先按脚本支持的参数选择专项，最终跑相关完整产品
bash scripts/run_v2_clientkit_native_tests.sh

# App 构建与组件/交互回归
bash IMApp/Scripts/verify_generic_simulator_build.sh
bash IMApp/Scripts/verify_unit_tests.sh
bash IMApp/Scripts/verify_ui_tests.sh

# 协议/schema 变化
bash scripts/check_v2_protobuf_generated.sh
python3 scripts/check_v2_protocol_documentation.py
bash scripts/check_v2_schema_readiness_tables.sh
bash scripts/test_v2_postgres_schema_bootstrap.sh

# 服务端与一次性数据库组件集成
bash scripts/run_v2_swift_tests.sh
bash scripts/run_v2_postgres_integration.sh
```

最终执行时按以下去重原则组织一个回归批次，不能把上面所有入口无区别连续运行：

- `run_v2_swift_tests.sh` 已包含 Core、ClientKit、Server 三套及多个门禁；若选择按包分别执行，则不再追加此聚合脚本重跑同一批代码。
- Server 的 PostgreSQL 集成脚本会执行整个 Server 测试包。准备好明确一次性的数据库后集中运行，避免先跑无数据库的整包再重复整包；不同schema安装用例保持串行。
- App 的 generic build 脚本实际执行 `build-for-testing`，包含测试target。需要仅检查生产装配时使用 `xcodebuild build`；统一夹具迁移完成后再构建/运行测试target。相同源码和配置可复用构建产物，不为每个业务入口重建。
- 测试期间仅修复实际失败并重跑受影响范围；相关检查已通过且没有新增源码变化时，不重复整包。未执行的平台、供应商或容量项目单独登记，不能用模拟器/单元结果代替。

验证前阅读脚本实际参数与工具链要求；只能使用明确一次性的测试库，不能把开发库作为重置目标。ClientKit 已有 retry/scheduler/network-generation/profile/resource suites，应扩展它们验证新合同，而非新增只镜像实现的重复测试。破坏性单一合同变更必须同步重写旧预期。

## 11. 交付完成检查

- App 实际入口覆盖所有登记业务；不存在保存语义只在内存的关键写入。
- 发送/查询/关闭身份和回执可跨进程核验，state/claim/时间/版本的竞争矩阵通过。
- 全部命令来源经过同一个账户工作准入，HTTP 和 TCP 能独立恢复。
- 普通内容离线可用，受限展示和敏感权限不因缓存被绕过。
- 资源真实续传、签名恢复、Ready 依赖与文件生命周期完成；后台能力如实声明。
- 本地/服务器存储、队列、等待者、网络尝试和响应体均有硬界限。
- 当前 schema/协议从空环境启动和同版本重启恢复均通过；不验收旧版迁移。
- 发布报告包含实际执行命令、结果、环境、未执行矩阵和容量限制；不以无失败日志冒充已验证。

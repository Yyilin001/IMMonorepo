# 仅保留房间日志：实施与验收记录

> 本文保留房间日志切换阶段的实施证据。下文 NATS、旧调度配置与测试数量属于该阶段；当前消息发送见[现行合同](message-send-contract.md)，当前实时投递见[Relay 实现](room-subscription-relay-implementation.zh-CN.md)。

状态：2026-09-13 的历史实施记录。文中的阶段性“当前”、迁移能力、类型名和测试数字均以当时版本为准；当前合同见[系统总览](../current-system-map.md)与[实现状态](../../IMV2/docs/implementation-status.md)。

目标：公共消息和公共房间变更统一写入房间日志，移除逐用户正文扇出；个人状态与单侧提示使用独立的可靠用户事件流。项目尚未上线，按用户明确要求以全新数据库和新版客户端为基线，不承担旧数据、旧协议或旧客户端兼容。实现及验收已完成。

## 设计边界

公共事件在房间内分配序号，客户端按授权范围补拉；在线推送负责降低延迟，断线恢复依赖持久日志。消息、编辑、撤回、反应、公告、角色及群权限变化均不为每个成员复制正文。

个人事件与源操作在同一事务写入个人 outbox，再路由至目标用户归属库。目标库在一个事务中完成身份去重、用户序号分配、日志写入和 receipt 写入。目标已提交而源端确认失败时，用相同身份重试，不重复分配序号。

单侧系统提示使用个人 `timeline_activity`，目标明确为一个用户；客户端通过 `timeline_sequence` 将提示放入该用户的会话时间线。提示不占用公共房间消息的接收者集合。产品上的系统提示与模型请求中的 system prompt 是不同概念，此方案处理聊天时间线提示。

成员加入、移除与重入分别保留本用户的 membership revision。移除通知走个人流，不能依赖已被撤销的房间读取权限；迟到的较旧事件不能恢复授权。这是新模型自身需要的乱序保护，不是历史版本兼容。

当时的方案曾要求用户跨分片迁移时复制 receipt、保持序号和路由围栏。当前运行时已删除在线 copy/verify、cutover 与 rollback，仅支持部署前确定的静态归属和全新数据库。

## 完成标准

- [x] 公共发送及所有公共变更只写房间日志；当前类型与持久化不再含扇出计划依赖。
- [x] 会话发现、加入、退出、移除和权限撤销使用独立个人事件。
- [x] 个人事件跨分片可重试、可去重；确认丢失和进程重启不造成重复。
- [x] 删除 `fanoutPlan`、`targetRule` 及其准入、完成回执和协议耦合；保留新版请求的正常幂等重试。
- [x] 群容量类别与投递模型分离，保留 5,000 / 100,000 人上限。
- [x] ClientKit 和 App 统一所有授权房间的补拉、摘要与未读，不再按旧模式选择预览路径。
- [x] 单侧 `timeline_activity`、顺序、持久化和断线恢复通过验证。
- [x] 删除旧 worker、专用表、共享扇出载荷、配置、协议字段和监控。
- [x] 个人暂停事件可定位、修复后重放；积压数量与最老待办年龄可观测。
- [x] 全新 schema、当前协议、部署示例与文档一致；完整测试和运行时启动/关闭通过。
- [x] 写放大、补拉延迟及断线、重启、权限恢复完成实际验收。

## 最终验收（2026-09-13）

服务端完整 1022 项、136 套件通过，最终汇总 `/tmp/imv2-room-log-final-receipt-summary.json` 的 exitCode=0、partial=false。ClientKit 完整 564 项、98 套件通过，App 233 项、36 套件通过。完整回归包含公共变更、权限历史、个人事件跨库路由、迁移、幂等、暂停重放及指标；之后新增的隐私并发围栏测试在关闭读者/查看者两个参数下通过，生产代码没有变化。

真实 Release 个人确认丢失探针通过：强杀前 40 条目标事件已提交、源端均未确认；原库重启后全部确认，receipt、日志和序号快照完全不变。完整账户/TLS/App 验收 v5 通过：3 项 UI 通过、1 项既有环境条件跳过、0 失败，另 1 项后台唤醒通过。单侧提示覆盖双方独立 SQLite、重连、聊天页及 App 冷启动。最终设备/撤销/令牌持久化严格检查通过，临时服务、数据库、凭据和专用模拟器已清理。

schema 35 新库初始化、转储恢复、漂移与非空库拒绝通过。Core 完整 119 项、39 套件通过（`/tmp/imv2-no-budget-core-tests.log`）。最终文档结构、链接、运行环境示例、readiness 表覆盖、当前协议文档与差异格式检查全部通过。当前 Release 三轮固定负载和两轮重启通过；性能结论限于有界场景，详见[当前版本运行验收](room-log-current-runtime-2026-09-13.md)。最终真实验收日志 `/tmp/imv2-current-private-hint-acceptance-v5.log`，个人确认丢失日志 `/tmp/imv2-personal-ack-restart-v2.log`。

以下为按时间追加的过程记录。“运行中”“尚未完成”和各批次测试数量只描述当时状态，最终状态以本节和完成清单为准。

## 过程记录：已实施与验证

以下是已验证批次的结果，不代表整个清理完成。后续删除类型、表或协议字段后，需要重新执行受影响验证。

| 范围 | 当前实现 | 已有证据 |
| --- | --- | --- |
| 个人事件基础 | 独立 kind 白名单、源 outbox、目标 receipt；租约恢复、瞬时重试、身份冲突暂停 | 基础 29 项相关测试、路由与迁移补充 12 项测试通过 |
| 个人路由与运行时 | 源归属提交与目标镜像保持同一路由围栏；专用连接池计入总预算；每个房间归属库运行派发任务 | 服务端构建及包含路由、连接预算的 56 项回归通过 |
| 建群 | 初始成员的个人 room 事件与建群同事务提交；不创建旧计划 | 真实 100,000 成员建群写入 100,000 条发现待办，无旧计划；本机单次约 1.55 秒，仅说明规模形态 |
| 成员与管理移除 | 公共成员事件加受影响用户的个人 membership 待办；命令准入 | 与公共变更合并的 30 项测试、3 个 suite 通过，含审批回滚、时间精度、去重与路由恢复 |
| 公共变更 | 编辑、撤回、反应、群能力和管理操作不再创建计划；已删除 V2RoomEventDeliveryMode | 上述真实数据库回归通过；其余旧计划断言尚需整理 |
| 原始发送 | 删除集合式逐用户扇出和群零目标计划；普通、批量和快速追加统一房间日志 | 配置与真实数据库发送组合 46 项测试、2 个 suite 通过；保留首次单聊个人资料与发送权限事件 |
| 客户端恢复与权限 | 授权房间统一持久游标；本用户成员修订独立存储，快照保留撤销证据 | 完整 ClientKit 串行 570 项测试、97 个 suite 通过；服务端权限相关 14 项真实数据库测试通过 |
| 旧模式选择配置 | 删除网关单聊和群投递选择、相关构造参数及活动部署示例中的两项开关 | 服务端构建、环境示例和文档门禁通过 |
| 旧流水线运行时 | 已删除旧规划、逐用户投递、完成额度释放和共享扇出载荷回填的装配与任务生命周期 | 服务端构建通过（21.55 秒），文档链接、结构和环境示例门禁通过；底层旧类型、配置和表仍需删除 |

## 原定实施顺序与文件边界（已完成）

1. **拆除服务端旧流水线。** 从 `IMV2ServerApp/main.swift` 移除旧任务后，删除仅供旧模式使用的 planner、relay、delivery、completion、NATS plan hint 和 payload backfill 实现及专用测试。清理运行配置、资源预算、健康检查和指标中对应依赖。保留房间 wake、推送、转发、媒体、审核和个人待办。
2. **简化领域类型与协议。** 清理 Core 接受结果、write set、准入及各 Store 操作记录中的 plan ID 和目标规则，结果以命令身份、事件身份和房间序号表示接受成功。同步修改当前协议生成物与客户端。直接使用新版幂等编码，不引入历史指纹版本分支。
3. **分离群容量。** 将 `standardFanout` / `largeGroupHybrid` 中的产品规模含义变成独立容量类别，保留原有上限与校验；所有类别使用同一房间日志模型。
4. **清理数据库。** 以全新 schema 为准删除旧计划、目标、投递、完成和共享扇出载荷专用表、索引、外键与字段；同步 readiness、schema contract、SQL 初始化和测试夹具。逐项确认实际引用，避免误删仍用于房间消息版本、媒体或个人状态的数据。
5. **统一客户端与 App。** 删除投递模式判断、无用预览引擎和协议能力字段；清理仅用于旧通讯模式升级的数据库迁移分支及测试。保留新数据库初始化、当前快照重置、成员乱序处理和断线补拉。
6. **补齐新个人事件运维。** 增加暂停事件诊断与重放、积压和年龄指标；验证冲突不能自动覆盖原事件，重放不能创建新身份。
7. **完成整体验收。** 更新当前部署模板和文档，运行 Core、Server、ClientKit、App 相关完整验证，使用可丢弃 PostgreSQL 验证新库启动、业务链路和关闭，再进行固定负载下的性能与故障验收。

## 旧扇出提示与调度器清理

已删除 `V2RoutedFanoutPipeline`、对应的跨 owner 完成释放调度器、`V2NATSFanoutPlanHintPublisher`、可选提示包装器及其专用测试。网关不再解析旧 `IM_V2_NATS_*` 扇出提示配置，环境示例同步清理。房间事件的 `IM_V2_GROUP_WAKE_NATS_*` 配置及超时边界测试继续保留，个人状态派发不依赖这些已删除类型。已先通过 49 项测试、4 个 suite；继续删除六项无运行时消费者的投递配置及部署示例后，44 项测试、4 个 suite 通过。相关测试保留房间唤醒超时、通用可靠重试和个人事件派发验证。

已进一步删除旧扇出专用自适应并发控制器及其专用测试，通用待办轮询退避继续服务个人派发和其他后台任务；4 项测试、2 个 suite 通过。运行时遗留的未使用旧流水线迁移实例也已清理。文档链接、结构、环境示例和差异格式检查通过。

## 消息接受类型解耦

已删除 Core 的 `V2FanoutPlanDraft` 和接受事务的 `fanoutPlan` 字段，`V2AcceptanceIdentifiers` 只保留消息与事件身份。Core reducer 改为命令准入，接受后不增加扇出占用；发送存储的普通和批量路径不再构造计划草稿，也不再依赖草稿中的零目标成本检查。

接受 ID 生成器只生成两个 UUIDv7，删除第三个计划身份的生成；保留时间范围校验、进程内时钟回拨保护、不同随机区间和并发唯一性验证。完整 Core 117 项测试、39 个 suite 通过。服务端编译及 33 项测试、3 个 suite 通过。真实 PostgreSQL 的 3 项参数化测试通过（6.686 秒），覆盖单聊／两类群的零公共扇出、重复请求、普通／owner 入口，以及修改消息后的继续追加。首次编译暴露的 20 处旧隐式身份构造调用已清理，没有增加兼容重载。

后续已删除发送命令及指纹的 targetRule，普通和转发统一为版本 3，解码不接受旧指纹版本；数据库约束及 readiness 同步只接受版本 3。发送批量分组、缓存资格判断也已清除 targetRule 门槛。独立字节编码计算的 SHA-256 向量与完整 Core 117 项测试通过；服务端构建和 30 项测试、2 个 suite 通过。真实 PostgreSQL 的 5 项测试通过（33.977 秒），包括 3 类房间发送、4 组拒绝回执、转发 ABA、3 组内容清理后重试，以及 39 组 schema 合同损坏检测。转发测试移除旧 schema 迁移分支，继续覆盖源版本 ABA 与幂等重试。

这尚未解除全部领域耦合：各公共变更结果中的 planID、通用准入中的旧扇出字段和旧存储实现仍需删除；其他历史迁移测试也需随新库基线统一清理。

## 共享扇出载荷回填删除

已删除无运行时消费者的 `PostgresV2FanoutPayloadReferenceBackfillWorker`，以及旧单聊流水线集成测试中模拟旧进程 body 载荷、校验物化回填的专用段落。没有删除当前房间日志存储和消息版本功能。公共变更的 plan ID 仍同时存在于服务协议、操作记录和旧流水线测试中，后续需成套拆除，不能只改返回值而遗留数据库必填列。

## 消息编辑计划身份删除

消息编辑已贯通删除计划身份：Core 结果不再包含 fanoutPlanID，编辑服务及 owner 路由不再接收 planID，标识工厂只生成事件 ID，操作记录不再读写 plan_id，全新 schema 删除该列及其唯一约束。幂等记录继续保留操作身份、原输入、事件身份、房间序号、内容修订和创建时间。

原编辑持久化测试改为检查编辑事件与规范消息、重试一致，以及零用户正文副本和零扇出计划。公共变更时间精度测试继续核对时间、序号和事件身份，不再要求返回计划身份。完整 Core 117 项测试通过；服务端构建和 60 项服务／网关测试通过。数据库首轮只有撤回与并发用例中的三处旧计划／outbox 数量断言失败，改为零旧流水线记录后，5 项真实 PostgreSQL 测试全部通过（31.163 秒），包括 30 组时间精度、5 组发布权限、编辑持久化与幂等、撤回拒绝迟到编辑以及并发历史一致性。撤回、反应、成员与管理变更的计划身份仍需分别贯通清理。

## 消息撤回计划身份删除

撤回服务、归属路由和操作结果已移除 plan ID，标识工厂只生成事件 ID。新库删除 message_withdrawal_operations.plan_id 及其唯一约束，重放直接使用原事件、消息修订、房间序号和创建时间。完整 Core 117 项测试通过。

反应添加、移除后再撤回的集成用例已改为验证房间事件顺序、规范状态和零用户正文副本，不再调用旧 planner/delivery 或注入旧个人正文流。撤回、编辑并发、30 组时间精度及网关／归属路由组合回归通过：67 项测试、3 个 suite，真实数据库组合用时 32.939 秒。反应自身的计划参数和字段仍待下一批删除。

## 消息反应计划身份删除

反应变更的服务、归属路由、结果类型和操作记录已移除计划身份，标识工厂只生成事件 ID，新库删除 message_reaction_operations.plan_id 及其唯一约束。成员变更的同名 change 接口未混改。Core 117 项测试通过；服务端、归属路由、网关及真实 PostgreSQL 组合 66 项测试、4 个 suite 通过（33.493 秒），包含 30 组时间精度和 6 组接受时成员权限。首次编译遗漏的一处通用变量名路由调用已移除旧参数，无兼容重载。

## 成员变更与审批计划身份删除

成员变更结果、服务、归属入口、事务内原语和邀请审批接口已移除计划身份；成员事件工厂只分配事件 ID。新库删除 room_membership_operations.plan_id 及唯一约束，审批恢复审计也删除计划列和关联空值要求，readiness 与 SQL schema contract 同步调整为 21 个审计字段。

个人成员事件仍与房间成员变更同事务提交，审批恢复继续以操作身份、原事件、成员修订和恢复围栏判断完成，保留审计不可变性。Core 117 项测试通过；服务、网关、归属及真实 PostgreSQL 组合 77 项测试、5 个 suite 通过（14.623 秒）。包含 6 组成员时间精度、2 组归属围栏、个人发现与幂等、4 组恢复审计、3 组证据保留、3 组审批回滚以及审批并发锁顺序验证。

## 管理操作计划身份删除

管理员与可信审核入口已移除计划参数，冻结、解冻、禁言、成员移除和内容撤除均只生成事件 ID；V2ModerationResult 不再携带 fanoutPlanID。新库删除 moderation_operations.plan_id 和唯一约束，幂等结果继续从操作记录读取，管理审计及媒体撤销逻辑保留。

原撤除、冻结、禁言测试已移除 planner/delivery 和个人正文快照假设，改为直接检查房间日志、规范状态、审计、权限效果和零公共扇出。成员移除继续验证个人事件派发。服务端构建通过；84 项组合回归首轮仅内容撤除测试的旧发送扇出准备步骤失败，已删除该三行旧流程。清理后 84 项测试、5 个 suite 全部通过（35.477 秒），包含 16 组管理时间精度、5 组重放时钟、12 组归属围栏，以及撤除、冻结、禁言和个人移除通知。

## 群能力操作计划身份删除

置顶、公告、角色权限和成员角色变更的服务、归属接口、存储与调用方已移除计划参数；标识工厂只生成事件 ID。新库删除四类操作表的 plan_id 和唯一约束。房间事件、操作幂等、版本冲突和权限行为保留。

集成测试改为验证房间日志的源版本与载荷一致性，并断言没有旧计划、旧 outbox 或个人公共副本。权限清理测试删除 schema-17 降级和历史升级链，保留真实幂等记录清理、权限持久化、并发读取、成员移除和重入。路由单元测试 3 项通过；67 项组合回归首轮发现旧计数断言及历史迁移测试残留，已修正；复跑 67 项测试、3 个 suite 全部通过（26.717 秒）。

## 建群计划身份删除

建群服务、直接/分片归属/分阶段入口、创建意图与数据库读写已移除 planID；标识工厂只生成房间和事件 ID。新库 group_room_creation_intents 删除 plan_id 及唯一约束。创建恢复仍校验操作、房间、事件、请求指纹、成员数量和归属代次，保留成员清单分页与首次个人发现事件。

建群服务和路由 10 项测试、2 个 suite 通过（0.046 秒）；真实 PostgreSQL 6 项测试通过（13.471 秒），覆盖初始已读位置、创建时间精度与非法时间、稳定创建意图、跨库归属重试以及个人房间发现。日志见 /tmp/imv2-group-creation-no-plan-tests.log 和 /tmp/imv2-group-creation-no-plan-postgres-tests.log。旧 worker、预算模型及协议模式字段等全局清理仍未完成。

## 旧扇出流水线与遥测删除

删除生产 V2FanoutPipeline、其专属测试以及旧 5,000 人跨库扇出性能测试；删除 fanoutProgress/fanoutFailure 事件、运行时日志分支和 Prometheus 扇出计数/耗时指标。网关指标的并发计数和隐私断言保留。原本地 planner 发布适配器仅暂存于测试目录，供尚待删除或改写的旧存储测试使用，生产代码不再提供该适配器。

本批 11 项测试、3 个 suite 全部通过（0.013 秒），日志 /tmp/imv2-remove-fanout-pipeline-tests.log。旧 planner/delivery/completion 存储和测试仍待整体清理，个人状态投影使用的共享代码须先拆出。

## 个人状态投影与旧扇出解耦

新增 PostgresV2UserProjectionStore，将个人状态的 projectAllocated 与保留原序号的 mirror 从旧扇出投影器移出，V2UserShardProjectionShadowForwarder 改用独立存储。持久化效果去重、序号冲突拒绝、序号溢出边界和 PostgreSQL 原始时间戳路径不变。V2LiveSyncNotifier 也移至独立文件。

相关时间与序号边界、真实分片镜像、个人 worker 和指标回归共 13 项测试、3 个 suite 通过（7.475 秒），日志 /tmp/imv2-personal-projection-extraction-tests.log。后续删除旧投递存储时，保留媒体授权与消息权限测试并改走房间日志；纯扇出恢复、分批性能测试随旧实现删除。

## 旧扇出集成测试删除

删除 16 个仅服务旧机制的集成测试，共 2,672 行：旧重试计数与时间/序号边界、直接预规划微批、计划分页及完成释放恢复、旧 relay 批处理、十万人逐用户投递、旧群消息并发扇出、过期租约恢复、旧路由 handoff、跨库扇出提交/故障和目标投影性能诊断。

消息权限、媒体授权、个人状态同步、房间日志、跨分片创建恢复等产品行为测试保留。删除后的测试编译及个人 worker/指标回归 10 项测试、2 个 suite 通过（0.014 秒），日志 /tmp/imv2-retired-fanout-test-removal.log。旧实现仍有混合测试引用，不能据此认定已完全删除。

## 本地媒体授权改为房间可见性

发现并修复本地媒体授权仍要求旧个人消息投影的问题。PostgresV2MediaVisibilityAuthorization 现在依赖规范 message_media_references、未撤回消息、有效接受凭据、当前/历史成员区间与当前正文修订可见性；媒体状态、引用撤销、有效设备、账号状态及头像路径保留。

媒体生命周期、传输会话和附件引用测试移除 planner/delivery/个人快照准备，并检查零公共个人副本。原共享/内联副本双测改为房间日志授权场景；provider-projection 场景改为真实附件引用撤销。非法时间、入群空档期编辑、缺失接受凭据、设备撤销/过期、账号停用、资料停用、兑换租约/过期与头像授权保留。4 项参数化回归全部通过（23.670 秒），日志 /tmp/imv2-room-log-media-authorization-tests.log。

## 跨分片媒体下载旧个人分支删除

V2RoutedMediaDownloadService 删除个人消息投影查询及 delivery_authority 分支，改为控制库校验设备/账号、房间归属库校验规范消息和附件引用；保留房间锁、归属代次、授权快照前后比较及提供方返回后复验。接口移除用户分片路由与存储注册依赖，AccountServer 不再为媒体下载构造用户位置列表。本地头像/媒体入口保留并改名 local。

跨分片测试删除旧模式切换与伪造个人消息版本，保留标准/大群成功、撤回、移除、晚加入、设备、归属、错误消息、提供方期间设备/引用撤销、取消和时钟边界；转发附件也不再伪造个人消息副本。3 项参数化回归全部通过（41.462 秒），其中跨分片下载覆盖 14 个场景，日志 /tmp/imv2-room-log-routed-media-tests.log。

## 接受事务测试改为房间日志

atomicallyPersistsAcceptanceWriteSet 移除旧 planner/delivery/completion、公共个人副本拉取及历史载荷重写/压缩准备。改为检查消息、房间事件、接受凭据各一条，房间正文一致、事件不可变，旧 outbox/计划/投递/共享副本/个人正文均为零。保留建群受众暂存配额与清理、离群后幂等重放、推送预算和准入租约更新；群权限操作 SQL 同步移除旧 plan_id。

接受事务测试通过（1.071 秒），日志 /tmp/imv2-room-log-acceptance-write-set-tests.log。

## 私信策略与群能力测试脱离旧投递

陌生人私信策略测试保留接收偏好、隐私回执传播重试、拒绝提示、并发限额、幂等冲突、会话发现、回复后解除限额及受众损坏回滚。删除旧 direct_preplanned 投递/完成释放，并改为零旧计划/副本断言；用户投影路由临时缺失时仍验证已建立会话的公共接受和房间日志读取。

删除三组旧群能力个人快照合并测试（角色、置顶、公告/权限，共 277 行），保留房间事件源版本、群权限清理后持久性等当前行为覆盖。联合回归中接受事务和群能力通过，私信损坏受众场景发现发送仍被接受；错误来自新路径缺少单聊双方成员完整性校验，正在修复并复跑。日志 /tmp/imv2-room-log-direct-policy-tests.log。

## 单聊成员完整性与重入编辑验证

私信损坏受众回归暴露：删除旧扇出枚举后，收件人成员关系损坏仍可能接受。现为标量、普通批量和快速单聊批量持久化增加有界检查：房间绑定双方必须恰好对应两条有效成员关系，最多读三条以检测额外成员；错误抛出并回滚原事务。当前实现增加一次集合式检查查询，性能测量与最终准入合并优化仍待验证。

原 replacementPersonalProjection 改为 roomLogEditReplacementAfterRejoin，直接验证老成员只见序号 1、3，缺席期间的编辑不可见，新成员不能读取旧消息，且不产生个人消息副本。真实事件样本改为 room-log.json，ClientKit 的 realOwnerReplacementFixture 同步只读取这份房间日志样本。

服务端 3 项回归通过（1.988 秒），日志 /tmp/imv2-room-log-membership-replacement-tests.log；样本目录 /tmp/imv2-room-log-replacement-fixture。ClientKit 使用真实 room-log.json 验证通过（0.054 秒），日志 /tmp/imv2-room-log-client-real-fixture-tests.log。

## 消息变更受众测试改为读取权限

messageMutationHistoricalAudience 不再规划或结算个人投递，改为编辑/撤回/反应事件对原有重入成员可见、对新加入成员不可见，并检查零计划和个人正文。原空受众结算测试改为 withdrawAfterAllOriginalMembersLeave，保留作者离群后撤回的规范事实及新成员无权读取的验证；删除仅测试旧扇出结算恢复的 messageAudienceSettlementRecovery。

四组联合回归全部通过（5.096 秒），日志 /tmp/imv2-room-log-audience-tests.log。

## 旧规划与投递运行时代码整块删除

删除 V2FanoutPlanner、PostgresV2FanoutPlanStore、V2OutboxRelay、PostgresV2RoomOutboxStore、V2FanoutDeliveryWorker、PostgresV2FanoutDeliveryStore、V2CrossStoreFanoutDelivery、V2FanoutCompletionReleaseWorker 及专属单元测试。暂存的本地发布测试适配器、内存旧 outbox、旧测试扩展与性能统计辅助类型一并删除。生产错误分类移除旧投递错误，配置删除未使用的 V2FanoutPayloadWriteMode。

删除 7 个仅用于旧投影/扇出重放的测试；个人时钟与序号耗尽测试改用 PostgresV2UserProjectionStore，跨分片个人设置测试用个人事件占用目标序号。积压指标测试保留撤销、资料传播、内容审核检查，旧扇出计数为零。

删除后服务端构建通过（19.75 秒），日志 /tmp/imv2-delete-fanout-runtime-build.log。个人序号、镜像、指标与错误分类共 13 项回归通过（3.844 秒），日志 /tmp/imv2-delete-fanout-runtime-tests.log。旧数据库表、指标字段和 Core 预算类型仍待清理，整体尚未完成。

## 个人事件暂停恢复替代旧扇出重放

运维目标删除 `room_outbox`、`fanout_delivery`，改为封闭的 `user_state_event`。单目标要求用户与有效个人事件类型，公共消息类型不被接受。恢复只清除旧租约、重置尝试次数并立即回到 pending，不写投递成功或用户序号；状态改变和审计同事务提交。按来源事件分批恢复保留稳定逐目标审计。

独立运维进程使用房间分片配置创建来源库重放存储。个人事件请求必须明确携带 `sourceShardID`；缺失、未知分片或非个人工作携带该字段均拒绝，不回退控制库。正常 worker 继续负责目标用户路由、投影及来源确认。操作文档与配置示例已更新；个人队列指标和告警接线见下一节。

数据库暂停恢复、旧租约隔离、批量边界、审计时钟和个人类型限制共 6 项回归通过（3.950 秒），日志 /tmp/imv2-user-state-operator-replay-tests.log。增加来源选择后，时钟测试夹具因未提供来源分片而失败；修正夹具并保留原有边界检查后，7 项联合回归通过（3.941 秒），日志 /tmp/imv2-user-state-operator-routing-fixed-tests.log。文档链接、结构、运行时环境示例和 diff 检查通过。

## 个人事件指标替换旧分发指标

删除持久化指标中的房间旧 outbox、扇出计划、投递、结算查询、快照字段和 Prometheus 输出。控制库指标不再查询这些旧表。个人事件使用独立 `PostgresV2UserStateEventMetricsSource`，运行时按房间来源数据库 URL 去重后采集（包括同库来源），计数相加、最老未完成年龄取最大。

指标区分 ready、leased、scheduled、paused：过期租约算 ready，未来退避算 scheduled，delivered 不进入积压和年龄；失败来源报告 unavailable，继续使用原有完整快照失败/超时处理。暂停和停滞告警改为 `IMV2PausedUserStateEvent`、`IMV2StalledUserStateEvent`，删除旧扇出告警和已无生产计数器的失败率告警。尚未完成实际部署的 receiver 配置与演练；本机没有 promtool，仅验证 YAML 解析、目标名称及指标一致性。

服务端构建通过（12.50 秒），日志 /tmp/imv2-personal-event-metrics-build-fixed.log。真实 PostgreSQL 队列状态、指标不可用、聚合缓存、输出和 HTTP 指标路由共 21 项回归通过（0.548 秒），日志 /tmp/imv2-personal-event-metrics-tests.log。文档链接、结构、环境示例和 diff 检查通过。旧 SQL 表、Core 扇出预算、客户端旧字段等全局清理仍未完成。

## 旧公共队列表与结算依赖删除

删除未被调用的 `V2MessageAudienceSettlement`，从 canonical bootstrap 移除 `fanout_plans`、`fanout_plan_targets`、`fanout_completion_units`、`fanout_deliveries`、`room_outbox` 五表，以及它们的索引、外键、触发器和三个专属函数。启动 readiness 不再要求旧投递契约。后台清理删除六个旧清理类别，事务内类别预算由 16 调整为 10，保留现有媒体、推送、资料、回执、凭证、在线租约和幂等保留规则。

公共发送测试直接验证旧表不存在。其余业务快照移除旧表，推送通过房间事件读取来源，消息变更统一验证房间日志；删除未被调用的旧投递性能辅助类型。十万成员验证移除终端零目标计划的预期，继续保留房间事件、成员发现和容量检查（本批未运行十万成员测试）。

可丢弃 probe 库的新建 schema 和 SQL contract 执行通过，日志 /tmp/imv2-retired-tables-bootstrap.log。服务端构建通过。公共发送、消息变更、推送重试、批量写入和清理 7 项参数化回归通过（32.523 秒），日志 /tmp/imv2-retired-tables-tests.log。完整启动 readiness 的成功与缺表拒绝测试通过（0.525 秒），日志 /tmp/imv2-retired-tables-readiness-tests.log。共享载荷和旧 consumer inbox 仍有读取/分片迁移依赖，尚未删除；全量验收仍未完成。

## 删除旧 consumer inbox 及其迁移路径

`consumer_inbox` 已没有业务写入者，剩余生产用途仅为旧用户分片迁移复制、指纹与清理。删除该表、主键和两个索引，移除 readiness 要求及迁移旧收据的代码。新的 `user_state_event_receipts` 继续复制、参与指纹、在目标重建和来源清理时按用户处理；现有个人操作 `user_projection_effects` 的幂等证据继续保留。

测试删除旧 inbox 夹具与断言，公共发送测试增加旧 inbox 不存在的验证。压缩测试继续验证个人 effect 的稳定序号，个人事件测试继续验证压缩后去重、租约隔离、复制、指纹与清理。迁移 runbook 改为新个人事件确认路径。

生产构建与新建 probe 库 SQL contract 通过，日志 /tmp/imv2-delete-consumer-inbox-build.log 和 /tmp/imv2-delete-consumer-inbox-bootstrap.log。测试字段列表残项修复后，个人事件、迁移时钟、跨库复制、压缩、公共发送和 readiness 共 18 项回归通过（18.443 秒），日志 /tmp/imv2-delete-consumer-inbox-fixed-tests.log。文档和 diff 检查通过。共享载荷仍有六个生产文件依赖，是下一批清理对象；整体目标仍未完成。

## 个人同步读取与快照不再投影公共内容

`PostgresV2SyncStore` 改为直接读取 `user_sync_log.payload`，不再连接共享扇出载荷和消息状态。个人快照工作器删除已接受消息批量路径、消息/反应/群设置/公共管理事件的投影，以及共享消息替换、版本合并辅助实现；工作器初始化不再接收消息存储模式或批量开关。成员关系、个人会话状态、单侧活动、收藏、关系、隐私和个人已读继续按个人日志投影。

误入个人流的公共种类记录 `public_content_in_personal_stream` 并直接暂停，失败事务不推进检查点、不创建公共快照版本。补上 `own_read_watermark` 的个人快照入口。缺失载荷恢复测试改为修复精确的个人日志载荷，不再向旧共享表补写正文。

构建通过；个人事件、公共种类拒绝、个人已读、毒事件隔离与重放、日志压缩、跨分片个人记录和建群发现共 18 项回归通过（8.171 秒），日志 /tmp/imv2-personal-only-projector-final-tests.log。中间两次编译为修正已识别的测试恢复方式和确定性暂停语义而主动终止，不是测试通过记录。文档、环境和 diff 检查通过。

共享表仍被迁移、压缩、GC 和 readiness 引用，尚未删除；旧个人消息快照的专属集成测试还需要成组删除或改为房间日志验证，未运行服务端全量测试。Core 预算、客户端旧字段、启动演练与性能实测仍待完成。

## 迁移与日志压缩移除共享载荷依赖

用户分片复制与指纹直接读取个人日志 payload，不再连接、复制或指纹化共享扇出载荷。目标重建与来源清理只删除对应用户的日志；消息状态复制暂时仅保留现有快照版本的引用。日志压缩删除共享载荷回收查询和报告字段，继续保持有界删除、活跃令牌与回执保护以及个人幂等证据保留。

迁移夹具改为内联个人事件，重复复制、微秒时间戳和来源清理覆盖继续保留。跨分片复制与压缩测试新增先删除测试库共享表的条件，验证流程无需旧表。第一轮 17 项测试中，仅跨分片夹具的旧零 effect 断言失败：个人活动事件会自动捕获两条幂等记录；已修正。最终 17 项测试、2 个套件通过（16.194 秒），日志 /tmp/imv2-personal-transfer-final-tests.log；其中跨分片复制和压缩在共享表不存在时通过。文档、环境示例和 diff 检查通过。共享表本身、消息状态 GC 和 readiness 的依赖尚未删除，整体目标仍未完成。

## 删除共享载荷表与个人日志存储模式

canonical bootstrap 删除 fanout_sync_payloads 表、主键、消息状态索引与外键；readiness 和消息状态 GC 不再查询该表。user_sync_log 删除 payload_storage 及双模式约束，payload 改为 NOT NULL，个人事件写入和幂等验证直接使用 payload。个人 effect 触发器不再判断旧存储模式。

删除两个旧公共消息批量快照专属测试；公共类型拒绝测试继续保留。其他夹具删除共享表写入和零行假设，公共发送改为验证旧表不存在。毒事件使用数组形式的非法个人载荷，继续覆盖时钟、失败隔离、暂停与修复。运行时消息状态物化测试去除旧共享载荷准备。

可丢弃 probe 库的新建 schema 和 SQL contract 通过，日志 /tmp/imv2-delete-shared-bootstrap.log；数据库目录核对确认共享表不存在、个人存储模式列不存在且 payload 必填。相关 26 项测试、2 个套件通过（25.967 秒），日志 /tmp/imv2-delete-shared-tests.log，覆盖个人事件、公共发送、并发投影、毒事件恢复、迁移、压缩、readiness 和消息状态时钟。文档、环境示例及 diff 检查通过。这不是全量验收；旧快照消息状态引用、回填和配置，以及历史 SQL/运维文档仍待清理。

## 个人快照直读并删除旧回填运行时

SnapshotArtifactBuilder 直接读取个人投影版本 payload，删除消息状态 JOIN 和 inline/prefer_shared/shared 读取分支。删除 PostgresV2MessageProjectionBackfillWorker、运行时任务创建/取消/等待，以及旧消息投影读写模式、已接受消息批量投影配置和环境示例。房间消息状态正文压缩、状态 GC 与保留期继续保留。

删除旧回填时钟、双写/共享收缩专属测试，保留个人快照恢复、分页、并发和保留窗口验证。删除 backfill/inline-payload 指标的字段、查询、聚合、输出和专属告警；个人快照运维手册替换旧 expand/contract 回填手册，系统地图和可观测性说明同步调整。历史 SQL 和个人投影表中的消息状态引用仍待进一步清理。

告警 YAML 解析、唯一名称与旧告警缺席检查通过；文档链接、结构、环境示例检查通过。个人快照、配置、指标输出及个人事件共 63 项测试、5 个套件通过（14.042 秒），日志 /tmp/imv2-personal-snapshot-direct-tests.log。真实 PostgreSQL 指标查询单独通过（0.495 秒），日志 /tmp/imv2-personal-snapshot-metrics-tests.log。整体目标仍未完成。

## 个人投影版本移除消息状态引用

canonical bootstrap 删除 user_projection_versions.message_state_id、复合外键和三个旧消息引用/回填索引，个人投影 payload 改为必填，房间范围校验不再允许消息引用绕过。用户分片复制和指纹直接保存个人载荷，不再复制不可变公共消息状态。消息状态 GC 不再检查个人版本引用，仍保留当前有效消息修订与安全宽限期。删除个人消息引用估算指标及其查询、聚合和输出。

迁移时间戳测试去除旧公共消息状态夹具，保留个人版本创建时间的微秒精度与重复复制校验。新增 roomStateGCWithoutPersonalReferences：验证有界删除旧孤立状态，同时保留当前消息修订和年轻状态。迁移时间戳夹具清理出现一项残留元组导致编译失败，已修正并复跑。最终 33 项测试、4 个套件通过（15.552 秒），日志 /tmp/imv2-delete-snapshot-state-final-tests.log；新库 SQL contract 通过，日志 /tmp/imv2-delete-snapshot-state-bootstrap.log。文档、配置和 diff 检查通过，整体尚未完成。运行时核对发现状态压缩/GC 仍按用户分片创建，下一批需改为按实际房间库去重创建，并核对状态容量指标来源。

## 消息状态维护与容量采集归房间库

消息状态正文压缩与 GC 从用户分片创建循环移出，按主库和配置的房间库 URL 去重后使用 maintenance 连接创建，继续使用既有任务取消与等待流程。用户投影、快照、版本 GC 和个人日志压缩仍按用户库运行。

新增 PostgresV2RoomMessageStateMetricsSource，采集房间状态行数估算、关系字节数及可压缩正文估算。用户分片指标移除这些查询和字段解码，聚合时同库不会重复计数。新增真实数据库测试验证房间容量只计一次，并在房间状态表删除后确认用户指标仍可用、房间指标报告 unavailable。最终 29 项测试、4 个套件通过（7.361 秒），日志 /tmp/imv2-room-owner-maintenance-tests.log，覆盖房间指标归属、个人队列、真实 SQL 查询和状态 GC。文档、环境示例及 diff 检查通过；完整启动/停机仍待验收，整体目标尚未完成。

## 已完成个人事件有界回收

新增 PostgresV2UserStateEventGCWorker，来源确认完成默认保留七天，使用 delivered_at 及完整事件键索引、SKIP LOCKED 和最多 1,024 条的批量删除。任务按实际房间库去重接入既有维护循环，取消与失败重试沿用生命周期；目标去重收据不删除。

新建 schema 和 SQL contract 通过，日志 /tmp/imv2-personal-event-gc-bootstrap.log。新增回归验证严格截止时间、每批上限、非终态和年轻已完成记录保留，以及来源回收加日志压缩后的原序号重放与旧租约隔离；最终 17 项测试、2 个套件通过（10.938 秒），日志 /tmp/imv2-personal-event-gc-tests.log；文档、环境示例及 diff 检查通过。下一步检查个人已读快照在乱序到达时的单调性，整体目标仍未完成。

## 已读快照按水位合并

核对真实发送和客户端解码后，修正个人已读测试曾使用的错误 read_timeline_sequence 字段。own_read_watermark 按实际 read_through_room_sequence 和 recorded_at_ms 解码，并验证 UUID、正整数范围和非负时间。服务端个人快照仅在水位更高或相同水位的时间更新时替换；旧事件正常推进同步检查点但不生成倒退版本。客户端原有 MAX 合并无需修改。

新增回归覆盖 42→7→42→100 的晚到/同水位记录，以及错误字段、零水位、布尔值和负时间。客户端 4 项既有回归通过（0.076 秒），日志 /tmp/imv2-client-read-watermark-tests.log；服务端 18 项测试、2 个套件通过（9.071 秒），日志 /tmp/imv2-monotonic-read-snapshot-tests.log；文档、环境示例及 diff 检查通过。整体目标仍未完成。

## 消息变更依赖接受凭据而非旧投递类型

V2MessageAcceptedDelivery 改为 V2MessageAcceptanceFact，仅保留接受事件、接受时成员修订和房间序号。删除 V2StoredMessageDeliveryAuthority 及个人投递值解码；编辑、撤回、反应和房间事件读取共用的索引查询不再读取 delivery_authority。完成记录的消息身份和序号一致性校验继续保留，编辑替换值仍冻结原始接受身份。

旧房间投递字段和群容量模式仍需跨层清理，本批尚未删除它们。消息变更、原始/当前成员可见性、重入编辑、接受凭据缺失拒绝及公共发送 6 项参数化回归通过（36.626 秒），日志 /tmp/imv2-message-acceptance-fact-tests.log；文档、环境示例及 diff 检查通过。整体目标仍未完成。

## 群容量等级取代旧投递模式

Core、服务端、ClientKit、App、协议及当前数据库结构统一使用 capacityClass / capacity_class。standard 上限为 5,000 人，large 上限为 100,000 人，两者公共消息均使用房间日志。旧 standard_fanout / large_group_hybrid 值不再被当前领域模型解码；协议生成物已重新生成并通过一致性检查。当前容量说明和运维文档同步更新，历史性能报告不冒充新链路实测。

Core 117 项测试通过；服务端本轮 34 项、4 个套件通过（9.973 秒）；客户端完整 570 项、97 个套件通过（45.261 秒），日志 /tmp/imv2-group-capacity-client-final-tests.log。客户端结构指纹变更已验证仅源于字段及枚举原始值替换，177 个结构对象未增加。App 模拟器构建与测试目标编译均通过（/tmp/imv2-group-capacity-app-test-build.log），未执行模拟器测试。新 PostgreSQL schema 与 contract、文档链接、文档结构、环境示例及 diff 检查通过。

接下来删除接受模型的 usesRoomEventLog 开关及旧投递标记；历史迁移与完整端到端、性能验收仍未完成。

## 接受结果删除房间日志开关

删除 V2AcceptedMessageDraft、V2AcceptedMessage 和 V2MessageAcceptanceReceipt 的 usesRoomEventLog 属性及构造参数。消息接受、标量完成记录、回执重放、实时事件草稿和缓存调用链不再选择个人公共消息路径；普通内容不满足加速条件时仍发送尽力通知，可靠恢复由房间日志承担。保留事件身份、成员修订、对端身份和缓存资格检查。完成回执暂存的 delivery_authority 只接受 room_log，其数据库列及房间资料的旧投递字段尚待跨层删除。

Core 全量 117 项通过；服务端本轮 118 项、5 个套件通过（5.886 秒），覆盖各类房间公共发送、幂等重试、精确时间回执、网关提示、实时缓存、唤醒与发送服务，日志 /tmp/imv2-remove-room-log-flag-server-tests.log。客户端完整 570 项、97 个套件通过（44.950 秒），日志 /tmp/imv2-remove-room-log-flag-client-tests.log。App 测试目标编译通过（/tmp/imv2-remove-room-log-flag-app-test-build.log），尚未运行模拟器测试。文档、环境配置与 diff 检查通过。整体目标继续进行，历史迁移、旧投递字段、预算模型及完整端到端与性能验收仍待完成。

## 本地投影数据库仅初始化当前结构

删除 GRDBV2LocalSyncStore 的 16 个历史升级注册以及公告、置顶、角色策略的三个专用回填函数；当前主库和搜索库分别保留一个初始化步骤。删除仅由历史置顶回填使用的 preserveUnknownValue 分支。检查发现成员状态表此前只由升级步骤补建，现已加入规范 V2LocalSchema，授权撤销和成员修订校验继续使用原表结构。

删除 9 项纯历史升级测试，并将转发 UUID、完成回执、推送意图和快照重启验证改为当前版本的正常 reopen；跨来源效果测试仅移除 legacy-upgrade 参数，不减少当前去重与冲突覆盖。数据库契约继续要求 177 个主库结构对象及原指纹 0x5724825a9622e4a7，证明当前持久结构未因删除升级代码而缺失或改变。

初次全量验证暴露缺失成员状态表；对比实际新旧测试库确认只差这一张表，修复后完整 561 项、97 个套件通过（36.152 秒），日志 /tmp/imv2-client-current-schema-only-final-tests.log。App 测试目标编译通过（/tmp/imv2-client-current-schema-app-final-test-build.log），文档与 diff 检查通过。未执行模拟器测试；服务端历史 SQL、旧投递字段、预算模型及完整端到端与性能验收仍待完成，整体目标未完成。

## 房间资料移除旧投递选择字段

删除 rooms.delivery_authority、SQLite 房间资料同名列，以及服务端 V2RoomDeliveryAuthority、客户端 V2ClientRoomDeliveryAuthority 和旧推导函数。群创建、成员变更、禁言资料载荷只携带身份、容量等级与成员修订；补拉资格依赖实际授权状态。服务端标量、批量和按位置解码的房间查询同步删列；成员修订与缓存权限校验保留。

新库 SQL contract 返回 true；在独立测试事务内临时加回旧房间列后返回 false，事务结束回滚后再次为 true（/tmp/imv2-remove-room-authority-bootstrap.log、/tmp/imv2-reject-room-authority-schema.log）。客户端初次全量仅旧指纹断言失败；实际结构逐项比对确认仅删除目标列，清理该列的旧 SQL 注释后主库指纹为 0x564f98dd8e5fcfaa，仍为 177 个结构对象。最终客户端 560 项、97 个套件通过（39.691 秒），日志 /tmp/imv2-remove-room-authority-client-final-tests.log；删除的 1 项是要求旧投递字段存在的过时契约测试。

服务端本轮 9 项参数化集成测试通过（26.592 秒），日志 /tmp/imv2-remove-room-authority-server-tests.log，覆盖新标准群补拉、两类群创建资料、公共发送、成员与禁言响应、跨房间及同房间批量追加和 readiness。测试文本替换误改的媒体状态断言已恢复为原始字符串比较，并通过语法检查；该恢复不改变本轮所选集成用例或生产代码。App 测试目标编译通过（/tmp/imv2-remove-room-authority-app-final-test-build.log），未执行模拟器测试。当前设计合同与运维说明同步清除旧房间开关和灰度回滚说明，保留原产品决定与验收范围。

发送完成台账的 delivery_authority 及其独立回执解码尚待删除；服务端历史 SQL、旧预算模型、完整端到端与性能验收仍未完成。

## 发送完成台账移除旧投递字段

删除 message_send_completions.delivery_authority 及其标量、列式追加和回执重放依赖。接受/拒绝联合查询同步移除对应占位列，保留消息身份、指纹、事件、房间与时间线序号、成员修订、对端身份及拒绝字段的一致性验证。房间与完成台账均由 readiness 和 SQL contract 拒绝旧投递列；当前生产代码只在这个拒绝检查中引用该字段。

原消息变更测试去掉虚构的个人/预规划模式参数及恒真分支，覆盖普通私聊、富文本、审核、标准群与大群的原始接受事实。新增两类旧字段存在时拒绝启动的实际数据库检查。完整选择的 10 项参数化回归通过（39.771 秒），日志 /tmp/imv2-remove-completion-authority-tests.log；覆盖源接受身份、缺失接受事实、已完成变更重放、内容变更/删除后的发送回执、时间边界、历史成员媒体权限、媒体下载授权、跨房间与同房间批量追加。本轮也重新编译并执行了此前恢复原始字符串比较的媒体状态断言。

新库初始化与 SQL contract 返回 true（/tmp/imv2-remove-completion-authority-bootstrap.log），文档、环境示例及 diff 检查通过。本轮无客户端修改；服务端全量、启动停机与端到端性能仍待验收。下一步删除历史 SQL 升级及其兼容测试、收敛旧准入预算，整体目标保持进行中。

## 服务端只保留当前建库结构

删除 59 份历史 SQL 及旧消息投影升级检查脚本。删除纯升级测试，把推送、转发恢复、操作员重放和历史成员内容授权测试改为直接使用当前结构；非零 owner epoch、故障恢复、精确版本授权和重复版本拒绝仍保留。运行时用户分片迁移继续保留。新的静态测试要求当前 schema 存在且不再携带历史升级 SQL。

本批服务端 23 项、3 个套件串行回归通过（34.367 秒，/tmp/imv2-fresh-schema-only-final-tests.log）。首次并行运行遇到另一套测试删除临时 schema 时引发的 PostgreSQL 系统目录 OID 冲突；单独复测与整批串行复测通过，未削弱生产检查。当前文档移除旧 SQL 部署步骤，历史 ADR 明确标记为已被替代。

初始化脚本更新当前结构数量为 145 个关系、338 个索引、23 个应用触发器和 22 个函数；由源文本格式比较改为独立数据库导出/恢复后的标准 DDL 比较，同时保留空库拒绝、当前契约、旧迁移表拒绝和非空库重复初始化拒绝。增加原生 PostgreSQL 模式，只创建并清理独立测试数据库；默认 Docker 项目也使用独立名称。

导出恢复实测发现 group_invite_import_shard_check 的 BETWEEN 表达式在恢复后展开，导致精确结构检查误拒绝；当前建库 SQL 改用等价的上下界比较，服务端和 SQL 校验同步更新。原生 PostgreSQL 16 初始化及导出恢复检查通过（/tmp/imv2-current-bootstrap-roundtrip.log）。更新后的服务端启动检查及当前结构来源共 2 项测试通过（/tmp/imv2-bootstrap-readiness-tests.log），文档、环境示例、表覆盖及 diff 检查通过。本机 Docker 未运行，Docker 分支未执行。预算模型、完整业务回归及性能验收仍待完成。

## 命令准入移除失效扇出入口

调用链检查确认生产调用均使用命令窗口准入。删除只剩旧测试调用的按成员/指定目标计费规则、扇出成本计算器、扇出预留与释放入口，以及完成单元状态机和 CompletionUnitID；不保留兼容别名。保留入口统一命名为 V2CommandAdmissionEvaluator，结果只携带租约身份、代际和更新后的窗口状态，不再携带零目标成本占位值。发送、编辑、撤回、反应、成员管理、建群及禁言调用同步更新。

准入不再要求废弃的目标预算窗口与配置相等。实际命令窗口耗尽、租约缺失或到期、成员超过容量及配置不匹配仍拒绝；成员数量不改变命令成本。原扇出完成测试删除，准入测试改为当前行为并补充零目标预算、精确租约截止时间、成员上限和 Int.max 窗口边界。Core 全量 119 项、39 个套件通过（/tmp/imv2-command-admission-core-tests.log）。

服务端重新编译后，发送、快速追加缓存和租约控制 34 项通过（/tmp/imv2-command-admission-server-tests.log）；PostgreSQL 房间与分片命令额度、禁言准入和并发租约初始化 4 项通过（/tmp/imv2-command-admission-postgres-tests.log）。文档和 diff 检查通过。

这一步尚未删除 RoomCapacityProfile、房间/分片状态和 PostgreSQL 中的旧预算字段；相关行解码、批量预留 SQL、租约刷新和测试夹具需要下一批一起收敛。FanoutPlanID 目前只剩测试局部变量引用，仍待删除。完整服务端与端到端性能验收未完成。

## 删除没有执行者的容量配置

删除 RoomCapacityProfile 中只被构造、不被运行路径读取的枚举分页、规划并发和投递并发三项配置；网关及账号服务不再读取对应的三个环境变量。环境示例、Compose 配置、必需变量检查和测试夹具同步删除。当前个人事件、房间维护等工作器各自的有效并发设置保留。删除 FanoutPlanID 及 12 个旧测试局部变量，未保留兼容别名。

Core 全量 119 项、39 个套件通过（/tmp/imv2-remove-unused-capacity-core.log），网关配置、账号配置及租约控制共 46 项、3 个套件通过（/tmp/imv2-remove-unused-capacity-server.log）；环境示例、文档和 diff 检查通过。剩余六个房间/分片持久预算列需要连同 Core 状态、按位置解码、INSERT 值列表、标量和 JSON 批量预留、窗口重置触发器及租约更新一起删除；命令窗口、租约身份与代际、到期检查和排序加锁继续保留。全目标尚未完成。

## 写入路径只提交命令预算

删除分片预留的三个恒零扇出增量及 JSON 字段，标量与批量 SQL 仅预留 command_window_used。租约身份/代际、截止时间、命令容量条件、按分片与档位排序的行锁及影响行数整批提交检查保留。4 项 PostgreSQL 验证通过（/tmp/imv2-command-only-shard-reservation.log），覆盖房间/分片额度、实时租约批量时间精度及重叠跨分片批次。

随后删除公共追加、建群、成员管理、禁言、群能力、编辑、撤回和反应路径中 72 处旧预算字段赋值。真实成员计数、命令窗口和租约绑定仍在原事务内更新。6 项参数化 PostgreSQL 回归通过（40.502 秒，/tmp/imv2-command-only-budget-writes.log），覆盖建群、成员变更、禁言、消息变更接受事实、分片额度及并发批次；文档与 diff 检查通过。持久列及读取/初始化部分尚待删除，不将本批写入收敛视为预算模型全部完成。

## 删除旧预算持久列和读取模型

RoomCapacityProfile 现在仅保留成员上限、命令窗口上限和重试提示；RoomAdmissionState 只携带成员数与命令窗口，ShardAdmissionState 只携带命令租约。删除 room_admission 和 shard_admission_pools 各六列：目标窗口上限/已用量、未完成目标上限/已用量、未完成计划上限/已用量。对应 CHECK、窗口重置、初始化 INSERT、查询列、CodingKeys、顺序行解码、JSON 记录集和数组绑定同步收敛；大群条件追加及批量追加数组按删除位置重新编号。

命令窗口上限仍由启动档位校验和事务条件保护；租约身份、代际、截止时间、外键级联换代及命令窗口重置保留。删除三个旧预算环境变量，压测准入池创建/补建/重置/档位重绑定及混合群夹具同步使用当前结构。历史受众结算与早期容量报告明确标记为历史资料。

Core 全量 119 项、39 个套件通过（/tmp/imv2-no-budget-core-tests.log）。服务端编译及配置/租约测试通过；首次未配置数据库的运行不作为 PostgreSQL 证据。显式连接独立测试 PostgreSQL 后，11 项参数化回归全部通过（43.717 秒，/tmp/imv2-no-budget-postgres-tests.log），覆盖两类群创建、成员/禁言、消息变更接受事实、标量/批量时间精度、并发租约初始化、续租换代、房间/分片额度和跨分片批次。没有通过跳过数据库用例宣称集成通过。

独立数据库的新库初始化、结构契约与导出恢复检查通过（/tmp/imv2-no-budget-bootstrap-final.log）。压测准入池 provision/reset/seed 的真实 SQL 在新建临时库执行通过并清理（/tmp/imv2-budget-script-probe.log）；混合群完整负载夹具、真实压测及 App 验收仍待执行。启动检查新增对两张预算表旧列的拒绝，验证覆盖两张表乘六个旧列。最终网关/账号配置与旧预算拒绝共 43 项、3 个套件通过（10.712 秒，/tmp/imv2-no-budget-final-readiness.log）；文档、环境示例、脚本语法及 diff 检查通过。

## 扩大最终验证范围

预算删列后重新执行客户端全量测试，560 项、97 个套件通过（6.804 秒，/tmp/imv2-room-log-final-client-tests.log）。首次构建遇到 SwiftPM 仍缓存已更名的旧源文件路径；刷新包构建计划后正常完成，没有恢复旧文件。

服务端完整测试已使用显式主/次 PostgreSQL 测试连接和可丢弃库标记启动，并关闭套件并行，日志 /tmp/imv2-room-log-full-server-tests.log。App 在独立创建的 iOS 26.2 iPhone 17 Pro 模拟器上执行测试，日志 /tmp/imv2-room-log-app-acceptance.log，结果包 /tmp/imv2-room-log-app-acceptance.xcresult。服务端全量仍在运行，尚不计为已通过。App 初次关闭签名的运行：6 项界面测试通过；233 项单元测试出现 11 个缺失 Keychain entitlement 的环境失败及 1 个旧前台预览断言。SDK 将 -34018 定义为 errSecMissingEntitlement，测试包无相应签名权限；保留日志并停止测试完成后的额外诊断收集。修正标准群权限测试的恢复来源为 durableRoomLog，并用模拟器临时签名重新执行全部 App 单元测试，233 项、36 个套件通过（12.830 秒，/tmp/imv2-room-log-app-signed-tests.log，结果包 /tmp/imv2-room-log-app-signed-tests.xcresult）。没有修改项目签名设置或放宽 Keychain 权限。App 运行层仍有已不可达的 foregroundPreview 分支，待继续清理。

## App 只选择持久房间日志

删除 V2ClientRoomEventDelivery 及 V2ClientGroupEventAccess.delivery，房间访问状态只表达授权。App 的单页补拉、订阅起点、实时批次和订阅协调器统一使用持久房间游标；移除 App 对前台预览引擎的构造、依赖及退订时清理内存游标的回调。存储和测试不再传入恒定的投递方式字段。

模拟器 App 全量单元测试 233 项、36 个套件通过（9.561 秒，/tmp/imv2-no-preview-selector-app.log）。客户端并行运行出现三个限时相关失败：两条五秒墙钟断言及一个调度等待超时；同一时间有 Xcode 编译与服务端数据库全量回归。保留日志 /tmp/imv2-no-preview-selector-client.log，串行全量复核 560 项、97 个套件通过（56.851 秒，/tmp/imv2-no-preview-selector-client-serial.log），三个限时失败未重现；未放宽超时或修改调度实现。旧预览引擎、存储预览 API 及仅测试使用的旧预览场景尚待删除，整体目标未完成。

## 删除内存预览引擎与协议

删除 V2ForegroundGroupEventPreviewEngine、V2LocalForegroundGroupEventPreviewStore 及 foregroundGroupEventPreviewStartSequence。分页覆盖只通过可靠引擎执行：可见与空页面都持久保存已扫描水位，重启后恢复相同游标，精确重放不重复，坏载荷不推进游标或改变消息。房间已应用序号查询 roomAppliedRoomSequence 属于当前功能，删除范围检查发现其被误带走后已恢复，未将它作为旧模式删除。

恢复独立序号查询后，客户端串行全量 560 项、97 个套件通过（60.868 秒，/tmp/imv2-remove-preview-engine-client-final.log），文档与 diff 检查通过。

存储中的 applyForegroundGroupEventPreviewPage 仍被旧跨来源测试直接调用，尚需把这些场景改写为当前持久日志/快照契约后删除；没有保留或新增 App 对预览模式的调用。服务端全量回归继续使用原进程，不因本批独立客户端修改而重启。

## 删除预览写入入口

删除 GRDBV2LocalSyncStore.applyForegroundGroupEventPreviewPage。旧测试改走真实 applyGroupEventPage；重复预览参数删除，持久日志的游标顺序和不可变记录检查不放宽。测试专用辅助方法只在输入页水位早于持久游标时明确断言 invalidRecordOrdering 且游标不变；其他页直接调用生产写入，不提供额外投影写入口。相同序号但不同内容的重放明确断言拒绝。

同步专项 121 项通过（24.285 秒，/tmp/imv2-remove-preview-write-third.log），覆盖完整编辑替换、快照、重放、公告、权限策略、置顶及跨来源效果。最初替换后的失败来自旧测试接受过期预览页或期待投影层错误；改为当前日志拒绝契约后通过，没有放宽生产校验。随后客户端串行全量 560 项、97 个套件通过（67.064 秒，/tmp/imv2-no-preview-full-client.log），App 测试目标构建通过（/tmp/imv2-no-preview-app-build.log），文档与 diff 检查通过。当前 ClientKit 和 App 的 Swift 源码已无旧预览引擎、协议、写入口、起始游标或投递方式枚举引用。

## 当前全量回归与最后兼容残留

服务端完整串行测试已经结束：1013 项、136 个套件全部通过（1529.703 秒，/tmp/imv2-room-log-full-server-tests.log）。该运行显式配置主、次 PostgreSQL 测试库，覆盖旧预算删除后的服务端代码。删除全部客户端预览入口后，App 在独立 iOS 26.2 模拟器使用临时签名运行 233 项、36 个套件全部通过（6.437 秒，/tmp/imv2-no-preview-final-runtime.log，结果包 /tmp/imv2-no-preview-final-runtime.xcresult）；测试后该模拟器已关闭。

继续审查发现启动检查仍允许 messages_direct_event_cursor_idx 替代当前 messages_message_row_sequences_match 约束。这是实际历史升级兼容，与未上线项目只支持当前结构的要求冲突。删除该替代分支，要求当前序号约束与现行游标索引同时有效；原接受旧结构测试改为先验证当前结构通过，再验证删除约束并创建旧索引后明确拒绝。该修改发生在上述全量服务端回归之后，专项真实 PostgreSQL 验证通过（1 项，0.552 秒，/tmp/imv2-current-cursor-readiness.log），此前全量结果不包含这一修改。

SQL 部署校验同步要求当前序号约束和索引。独立数据库初始化与导出恢复通过（/tmp/imv2-current-cursor-bootstrap.log）；另建临时库验证当前结构返回 true、删除序号约束并创建旧索引后返回 false，完成后清理该临时库（/tmp/imv2-current-cursor-sql-rejection.log）。

私聊额外查询确认承担配对双方恰好两个有效成员的完整性检查，当前快速追加 SQL 只校验发送者成员资格与配对身份，不能直接删除额外查询。合并校验、固定负载性能、完整端到端业务与启动停机验收仍未完成。

## 私聊快速追加合并成员校验

快速追加的具名 PostgreSQL 语句及 SQLKit 分支在 locked_pair 中检查当前修订下恰好两名成员，且均属于配对双方；最多读取三名成员即可判定额外成员。删除快速路径单独的 assertDirectMemberships 往返，具名语句版本更新为 v7。完整标量与普通批量路径的独立校验继续保留；快速条件不满足时整批事务回滚，再走完整路径判定。

真实数据库回归增加缓存命中后插入第三名成员的场景，验证快速尝试发生、回退次数增加、未提交快速消息、消息/事件/状态数量与房间序号不变。覆盖本地和 owner 路由两种入口。专项真实 PostgreSQL 回归 3 项（其中两项各包含本地/owner 两个参数用例）全部通过，2.442 秒（/tmp/imv2-inline-direct-membership-tests.log）；覆盖第三成员拒绝、缺失成员拒绝、策略失效、双向缓存、跨房间批量与回滚。补充房间/分片命令额度与重叠跨分片批次 3 项通过（1.375 秒，/tmp/imv2-inline-direct-credit-tests.log）。没有将少一次查询等同于已测得延迟改善。

## 原生网关启动与停机实测

在独立临时 PostgreSQL 数据库安装当前 schema 和测试用户路由，使用当前 Debug 网关二进制、临时自签名证书及随机 HMAC 密钥，TLS 和指标端口只监听 127.0.0.1。网关通过启动检查并成功监听；发送 SIGTERM 后正常退出（exit 0），确认收到停机信号并完成 broker/presence 关闭，未触发 drain 超时。日志无 warning/error/failed。结束后删除本次创建的数据库和临时私钥。证据：/tmp/imv2-gateway-lifecycle-probe.log 及 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-gateway-lifecycle-zsw6iodk/gateway.log。

该验证覆盖单进程空业务负载的启动与正常关闭，不覆盖在途消息排空、外部 NATS、多进程拓扑或固定负载性能。压测凭据工具的 3 项现有单元测试通过（/tmp/imv2-load-fixture-unit-tests.log）；仍需实际负载与端到端业务验收。

## 混合群压测夹具使用当前容量字段

准备真实负载时发现两份夹具 SQL 仍读写已经删除的 delivery_mode。provision_mixed_group_load_fixtures.sql 与 extend_mixed_group_load_fixtures_v1.sql 改为 capacity_class，使用 standard/large 当前值，不增加兼容列。保留发送者、有效账号、租约、重复房间和成员数检查。

独立临时库安装当前 schema，创建 100,000 个合成账号及八个房间分片的命令租约后，完整 provision 实测通过：4 个标准容量群、13 个大容量群、261,221 条成员关系。另在本次临时库构造扩展入口需要的九个缺失房间，执行 extension 恢复九个各 10,000 人的群并核对总成员数。测试后清理数据库（/tmp/imv2-mixed-fixture-probe.log）。这证明夹具能在当前结构运行，尚不代表消息性能验收通过。当前版本 Release 网关正在构建（/tmp/imv2-room-log-release-build.log），准备后续固定连接数、发送率和消息大小的 TLS 实测。

## 首轮 Release 负载发现准入超时崩溃

当前 Release 网关构建通过（184.98 秒，/tmp/imv2-room-log-release-build.log），当前 Release 压测客户端构建通过（25.17 秒，/tmp/imv2-room-log-loadgen-release-build.log）。独立数据库、20 个连接、每秒 40 条消息、20 秒目标窗口，开启个人同步与房间日志读取。20 个连接全部鉴权成功，但业务负载触发网关 SIGABRT，客户端连接损失保护终止测试；该运行不计为性能通过。数据与临时令牌、私钥均已清理，日志保留在 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-31t0n_zh，摘要 /tmp/imv2-room-log-load-probe.log。

系统崩溃报告 /Users/yyl/Library/Logs/DiagnosticReports/IMV2ServerApp-2026-09-13-012459.ips 将触发栈定位到 V2DatabaseWorkAdmissionController.enqueue 的 Task.sleep(for:) 特化，在 swift_task_dealloc 中报告 freed pointer was not the last allocation。当前工具链为 Apple Swift 6.3.3；其栈与 [Swift 官方问题 86204](https://github.com/swiftlang/swift/issues/86204) 的跨模块 Release 特化崩溃一致，这仍是待复测确认的原因判断。仅将该准入超时任务改为显式 ContinuousClock.sleep(until:)，保留原超时长度、取消捕获和弱引用生命周期。准入专项 9 项测试通过（0.112 秒，/tmp/imv2-admission-clock-tests.log），覆盖超时、取消与额度分配。Release 网关重新构建中（/tmp/imv2-admission-clock-release-build.log），随后必须复跑相同负载，不能由 Debug 测试替代。

## 同负载复测确认其他服务定时任务也受影响

单点修改后 Release 构建通过，但同样的 20 连接负载仍发生 SIGABRT。此次已出现成功的 group_event_pull 命令日志，新的崩溃报告定位到 V2LivePresenceRenewalBatcher.scheduleFlush(after:) 中同一 Task.sleep(for:) 特化，而不是已修改的准入位置。证据：/tmp/imv2-room-log-load-probe-clock-fixed.log、/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-_bvmx7yj，以及 /Users/yyl/Library/Logs/DiagnosticReports/IMV2ServerApp-2026-09-13-012910.ips。该次仍为失败，不计性能通过。

因此将服务端库、网关和账号服务中的同类调用统一使用 v2Sleep(for:)。该函数通过显式 ContinuousClock deadline 等待并传播取消；各调用点原来的时长、try/try?、错误处理、批量与重试逻辑保留。覆盖准入、在线状态续期、已读合批、消息合批、推送/转发超时、NATS 房间唤醒、维护轮询和停机等待；没有修改客户端或第三方依赖。服务端生产源码不再直接调用 Task.sleep(for:)。相关定时任务专项 49 项、7 个套件通过（0.869 秒，/tmp/imv2-continuous-sleep-tests.log）。所有 Release 产品正在重新构建（/tmp/imv2-continuous-sleep-release-build.log）；仍需原负载实测证明修复。

## 同条件 Release 负载恢复通过

统一时钟等待后，全部 Release 产品构建通过（112.24 秒，/tmp/imv2-continuous-sleep-release-build.log）。原来的 20 连接、40 条/秒、128 字节消息、20 秒目标窗口，在新的独立数据库复测通过：20/20 鉴权成功，819 条发送全部确认，零跳过、零业务失败、零连接丢失；网关正常处理 SIGTERM 并退出。此前两次 SIGABRT 在该轮未重现。证据目录：/var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-8v9ia8da；摘要 /tmp/imv2-room-log-load-probe-continuous-fixed.log。

消息确认延迟 p50/p95/p99 为 5/6/7 毫秒；收到的 818 个房间事件页对应延迟为 1/1/1 毫秒，合计读取 1626 条记录。发送了 819 次分页请求，停止负载时仍有一页未计入返回，故不把此数据作为完整追赶完成的证据。虽然传入 syncReads，实际报告 syncPullsSent=0，个人同步没有被该轮覆盖，后续必须单独验证。

数据库最终消息数 819，个人 user_sync_log 的 message 正文记录为 0。测量窗口内用户表累计插入/更新/删除增量为 1942/2607/32（含建房、个人状态、游标和后台工作，不是仅消息正文的成本）。实例 WAL 位置从 7/8C498918 到 7/8C696958，增量 2089024 字节；此为同机 PostgreSQL 实例口径，不能当作每条消息精确归因。网关 CPU 样本均值 6.32%、最高 14.8%，RSS 最高 35.28 MiB；CPU 是进程 ps 采样而不是独立后台线程计量。

这是一轮低负载链路与崩溃修复验证，不代表容量上限、相对旧模式的性能提升或完整故障恢复验收。接着按相同连接数与发送率分别验证标准群和大群。

## 标准群与 10 万人群的低负载实测

相同 Release 二进制、20 个在线连接、目标 40 条/秒、128 字节消息，分别在独立数据库预建 20 人标准群和 100,000 人大群。均完成运行、零业务失败和正常停机，个人日志的 message 正文记录均为 0。结果如下，均属于单机低负载样本：

| 房间 | 发送/确认/数据库消息数 | 确认 p50/p95/p99（毫秒） | 房间页返回/请求 | 网关 CPU 样本均值 | 网关 RSS 峰值 |
| --- | --- | --- | --- | --- | --- |
| 20 人标准群 | 804/803/803 | 5/5/6 | 803/803 | 6.94% | 33.33 MiB |
| 100,000 人大群 | 805/805/805 | 5/6/6 | 805/805 | 7.22% | 33.36 MiB |

标准群证据目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-pxuh9p1h，大群目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-k4jv593j。两轮测量窗口内用户表插入/更新/删除增量分别为 3098/2322/12 与 3229/2431/52；包含其他当前后台工作，不能精确归因于消息正文。

标准群停止时有一条已发请求未确认，现有普通负载入口直接关闭连接，因此不能把生成器 exit 0 当作所有请求均完成。下一轮使用既有场景模式，显式安排个人同步、停止发送后的房间补拉、消息排空和短暂保持。该场景已通过解析校验，正在执行（/tmp/imv2-room-log-recovery-load.log）。普通模式的前述数据保留原样，不用结束时在途尾流粉饰成功率，也不将这些低负载样本称为容量上限。

## 带显式个人同步和排空的私聊场景

25 秒场景（20 秒发送及并发读取、5 秒仅追赶、随后排空与 2 秒保持）在当前 Release 网关通过运行，证据目录 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-5rov59z_。785 条实际发送全部确认，数据库消息数 785；房间补拉 1338/1338 返回、读取 1570 条房间记录；个人同步 300/300 返回、读取 40 条个人状态记录，24 次同步确认。消息排空报告为 drained=true、queued=0、inFlight=0，业务失败为 0，个人流 message 正文记录仍为 0，网关正常关闭。

严格单设备并发模式跳过了 15 次计划发送（800 次计划、785 次实际发送），因此该轮只证明实际发出请求及同步链路完成，不能宣称完整施加了 40 条/秒。确认延迟 p50/p95/p99 为 9/12/15 毫秒，房间补拉为 1/5/11 毫秒；它包含额外同步压力，不能与无个人同步的上一轮直接作性能提升比较。后续需使用显式有界队列且检查最终排空，验证完整目标发送数，并继续群场景与故障恢复矩阵。

## 三类房间完整施加有界负载

私聊、20 人标准群、100,000 人大群各完成计划的 800 条消息，发送、确认与数据库消息数一致；零跳过、失败、队列溢出与丢弃，最终排空。每轮个人同步 300/300 返回，房间分页请求全部返回，个人流没有 message 正文记录。

详细参数、分位延迟、CPU/RSS、写入/WAL 口径、原始证据及未覆盖事项见[固定负载实测](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/archive/room-log-fixed-load-2026-09-13.md)。这补齐上一轮客户端跳过请求的缺口，但不代表容量上限或完整故障恢复验收完成。

## 逐客户端核对房间日志水位

压测工具新增断开前的只读游标快照，查询在各连接所属事件循环执行，记录 connectionIndex、roomID 与实际 appliedRoomSequence；缺失连接不会被填充为已完成。测试脚本在停止写入后读取数据库 room_sequence，要求 20 个连接覆盖完整、房间覆盖完整且每个游标与数据库水位相等，不写入或抬高客户端游标。

当前 Release 压测客户端构建通过（9.66 秒，/tmp/imv2-cursor-loadgen-build.log）。私聊、20 人标准群、100,000 人大群分别复跑有界场景，每轮 800 条计划消息全部确认，个人同步和房间分页请求全部返回，20 个连接的游标均等于数据库水位、差距为零。对应证据目录后缀为 imv2-room-log-load-kq6p2ha6、imv2-room-log-load-fa2zh2rl、imv2-room-log-load-pa9x3ygc，位于 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T；每个目录包含 room-heads.json 与 cursor-verification.json。

这证明压测客户端的应用游标追赶完成，不等同于 App 的本地持久化或界面恢复。正在进一步执行独立数据库中的 SIGKILL 网关重启与新客户端零游标历史恢复（/tmp/imv2-room-log-restart-direct.log）。

## 已确认私聊消息的真实进程重启恢复

20 个连接完成 800/800 条消息后，对测试网关发送 SIGKILL，保留数据库并以同一配置重新启动网关。启动另一批全新压测客户端，按零游标读取历史，不发送新消息。20/20 鉴权成功，570/570 次房间分页返回，200/200 次个人同步返回，读取 1600 条房间记录（800 条消息各由私聊双方读取），20 个客户端的实际应用游标全部等于对应 10 个房间的数据库水位；无业务失败、无缺失记录。结束后网关正常退出，临时数据库、凭据与私钥清理完成。

证据：/tmp/imv2-room-log-restart-direct.log，以及 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-wmpk_zti 下的原始负载报告、recovery-report.json、restart-verification.json 和进程日志。该测试证明已确认私聊消息在真实进程退出后的零游标恢复，不覆盖提交中途崩溃、App 本地存储或 UI、新设备账号注册流程与跨主机故障。

## 大群进程恢复与单侧提示本地持久化

100,000 人群复用同样的进程故障流程：800 条消息确认后 SIGKILL 网关，再启动新网关和 20 个零游标客户端。20 个客户端共恢复 16000 条房间记录，每个应用游标都等于数据库水位。证据：/tmp/imv2-room-log-restart-large.log 与 /var/folders/vz/w13kf0d57l55dt1696pkpj1r0000gn/T/imv2-room-log-load-m66n3d4k/restart-verification.json。该检查仍属于已确认提交后的恢复，不冒充提交中途故障。

扩展 privateTimelineActivityAndCapabilityAreApplied：公共消息通过实际 applyGroupEventPage 同时写入两个独立本地库，个人提示与发送权限仅写入目标库；重新打开目标数据库并重放公共页后，时间线顺序为公共消息 1、私人提示 2、公共消息 3，提示只有一条，房间游标为 3，禁发状态保留；另一库没有提示或私人发送权限。专项通过（1 项，0.099 秒，/tmp/imv2-private-activity-reopen-tests.log），没有修改生产投影校验。这证明 ClientKit 持久化与来源隔离，不等同于账号路由或 App UI 端到端。

为核对当前真实 App 启动/凭据恢复/同步链路，现有原生账号验收脚本已启用独立模拟器、真实 TLS 网关和无根视图 Push 入口测试，正在执行（/tmp/imv2-room-log-live-app-acceptance.log，证据目录 /tmp/imv2-room-log-live-app-acceptance）。脚本使用自建 PostgreSQL 集群和临时证书，仅给本次新建模拟器添加信任，结束时清理；结果尚未计为通过。

## 完成标准复核发现房间侧个人写入残留

静态检查已无 fanoutPlan、targetRule、旧投递类别及预览模式等生产引用，但逐调用链检查发现 PostgresV2RoomWriteStore.appendPrivateSyncRecord 仍直接在房间事务的连接上分配 user_sync_sequence 并写 user_sync_log；appendDirectSendingCapabilityIfChanged 与首次私聊资料的批量 CTE 也仍使用房间库个人序列。单侧提示调用位于 persistDirectMessageDenied。它们尚未统一进入 user_state_event_outbox，不能把旧名称消失当作个人事件架构全部落地。

当前 shadowIfForwarding 从控制连接的 user_projection_effects 读取源事实，再投影到用户归属库，不能据此证明独立房间库中新写入的个人事实可恢复。需要补独立房间/用户库的回归并收敛这些房间侧生产者；同库负载、客户端本地提示测试和已通过的个人事件 projector 故障测试均不能覆盖这个来源缺口。完整目标保持未完成。

## 真实 App 验收脚本的跳过项统计修正

首次原生验收的账号与网关启动成功，四个实际 HTTPS 授权用例全部通过，但 Swift Testing 汇总将一个禁用的退出测试计入 5 项、2 个套件；脚本硬编码期待 4 项、1 个套件，因此在创建模拟器前中止。失败记录保留在 /tmp/imv2-room-log-live-app-acceptance，所建环境已由脚本清理。

脚本改为逐项要求四个具名 HTTPS 用例各通过一次；启用 current-logout 时还要求其具名用例通过，不用 skipped 或汇总计数充当执行证据。正在使用新证据目录重新运行 App UI、真实网关及 headless Push 入口（/tmp/imv2-room-log-live-app-acceptance-v2.log），尚未计为通过。

## 单侧拒绝事件开始改为房间事务待办

persistDirectMessageDenied 的 timeline_activity 改为构造 V2UserStateEvent 并在原房间事务写 user_state_event_outbox，不再分配房间库 user_sync_sequence。该路径的发送权限变化也以同一事务的 outbox INSERT 与 direct_room_pairs 标记更新原子提交；载荷时间和原有变更判定保留。

对应回归要求拒绝源事件在房间库 user_sync_log 中为零、待办中包含提示与发送权限两项。显式配置独立次数据库后，将租约事件投影到该库的新用户 schema，验证两项序号只在目标分配、重复接收复用原序号、另一用户没有记录。测试辅助函数增加指定数据库能力；发现初次修改误影响另一辅助函数后，停止本次编译、修正再启动，未沿用中断结果。当前专项仍在编译执行（/tmp/imv2-denial-owner-outbox-tests-final.log），不能计为通过。

首次接受的私聊资料、发送权限批量路径和其他房间侧个人生产者仍待收敛；本批不是全部个人事件路径完成，也尚未证明混合新旧生产路径的最终顺序。

## 真实 App 基线验收已通过

修正脚本对跳过项的统计后，四个真实 HTTPS 授权用例逐项通过；专用模拟器的两个 App UI 用例通过（一个未选择用例跳过），headless Push 入口单独一项通过且无跳过。证据为 /tmp/imv2-room-log-live-app-acceptance-v2 下的 app-summary.json、headless-summary.json、HTTP 与网关采样、结果包和日志。清理日志确认所建服务进程、PostgreSQL 集群、模拟器与私钥已清理。

该验收运行的是单侧拒绝 outbox 改造前构建的账号服务和网关，证明当前 App 基线的真实认证恢复与无根视图同步入口；不能替代后续房间侧个人事件生产者改造的回归，也没有验证单侧提示 UI。

## 首次接受的个人事件生产端收敛中

单侧拒绝跨库专项已通过：1 项测试、1.165 秒，日志 /tmp/imv2-denial-owner-outbox-tests-final.log。房间侧只写可靠待办，目标用户库分配序号，重复接收复用序号。

首次接受消息的单条和批量 appendDirectPostAcceptanceProjections 已改为在原事务写 user_state_event_outbox；保留资料存在检查、插入数量检查和配对标记原子更新，不再在这些路径分配房间库个人序号。专项增加首次资料在房间库个人日志为零、目标用户库重复投递只有一条的检查，已通过（1 项、1.340 秒，/tmp/imv2-first-acceptance-owner-outbox-tests.log，进程退出码 0）。这覆盖该专项实际经过的接受与拒绝路径，不代表所有批量、资料传播和用户状态路径已完成回归。

乱序审查确认客户端发送权限当前依赖 updated_at 时间并拒绝较旧记录，同一毫秒的相反状态也会报错；服务端快照按到达序号替换。异步源事件不能依靠这一机制保证收敛。后续需要以房间事务内的权威时间线序号标记发送权限版本，并在客户端和服务端快照处理旧版本与相同版本冲突。该版本处理、建房资料生产端、无效同步转发回调和相关全量回归仍未完成。

私聊资料也需纳入乱序验收：客户端当前拒绝较低 revision，并在相同 revision 时要求 source_event_id 相同。首次资料待办与后续资料传播属于不同来源事件，相同资料版本或延迟旧版本不应阻断用户同步；必须保留同版本内容冲突检查，同时验证服务端快照不会回退。不能仅修正发送权限而遗漏资料。

## 发送权限版本收敛实现中

三个房间侧发送权限生产分支已增加 state_version，取本次接受消息或拒绝提示的房间时间线序号，不使用请求时间比较新旧。客户端当前 schema 增加正整数 state_version 列；客户端持久化和服务端快照按版本忽略旧状态，对相同版本的内容或时间冲突报错。新增测试覆盖乱序旧事件、相同版本重复、同毫秒的更高版本，以及冲突不覆盖已保存状态。

客户端首次运行中两个行为测试通过，schema 指纹按新增字段预期失败；检查真实新库 177 个对象后，更新主库指纹为 0xd4e7d466122a37cb。复验三项通过（0.074 秒，/tmp/imv2-capability-version-client-final.log）。服务端发送与快照专项两项通过（1.705 秒，/tmp/imv2-capability-version-server.log）。

批量 SQL 的 room_id 和 target_user_id 已统一输出 Foundation 使用的大写 UUID 文本，避免与单条路径生成不同快照实体键。发送专项新增待办 room_id 规范化断言，复验两项通过（1.708 秒，/tmp/imv2-capability-version-server-final.log，退出码 0）。资料版本收敛、建房资料生产端和转发清理继续待办。此处通过的是发送权限专项，不代替完整快照、运行时迁移、App 和全量测试的最终回归。

## 私聊资料异步版本处理实现中

客户端私聊资料投影与服务端快照已按 revision 忽略旧版本，相同版本允许不同源事件身份但要求资料内容一致；目标用户变化仍拒绝。客户端还检查同版本更新时间，避免把冲突冒充重试。

私聊资料只有公开身份，没有完整头像与可见性事实。新增专用缓存写入边界：已有更新或同版本的完整资料时保留它，不让迟到的房间资料清空同版本头像或覆盖更新状态。没有改变完整资料接口原有的版本校验规则。客户端测试预先保存 revision 10 的完整资料，再接收房间 revision 4、3、4，验证同步继续、房间被发现、完整资料不回退，并验证同版本冲突回滚；服务端测试覆盖不同源事件的旧版本、同版本与冲突。

资料缓存专项 9 项通过（0.362 秒，/tmp/imv2-direct-profile-order-client.log），服务端资料与权限快照专项 2 项通过（0.752 秒，/tmp/imv2-direct-profile-order-server.log）。客户端全量 562 项、97 套件通过（6.125 秒，/tmp/imv2-personal-order-full-client.log）。随后增强头像保留断言：预先保存实际头像，接收相同版本但没有头像字段的房间资料后完整视图不变，专项通过（0.049 秒，/tmp/imv2-direct-profile-avatar-client.log）；该增强仅改测试。

建房资料已改为在房间事务写 user_state_event_outbox，移除建房完成后的 direct_room_profile 同步转发调用；控制库的偏好设置转发仍保留。并发建房测试调整为验证房间库个人日志和序号为空、仅一条资料待办，重试时待办与配对记录保持不变；正在执行 /tmp/imv2-direct-open-outbox-replay.log。其余依赖同步建房资料的集成测试尚需更新为真实待办投影驱动，发送路径的旧同步转发回调也仍需清理。

## 建房待办验证与发送提交收尾清理

建房并发测试首次未配置第二数据库，辅助函数提前返回，/tmp/imv2-direct-open-outbox-replay.log 的通过汇总不算数据库证据。补齐第二数据库后复用同一构建运行，六种组合实际执行并通过（4.763 秒，/tmp/imv2-direct-open-outbox-replay-final.log，退出码 0）。

PostgresV2RoomWriteStore 已移除同步 shadowForwarder 依赖、提交后的逐条和批量影子调用、DirectProjectionShadowRequest 与提交结果中的影子恢复字段。公共接受和个人状态待办在房间事务中提交，用户投递由后台负责；正常用户迁移转发实现继续保留。相应专用延迟指标已删除，合并提交收尾指标更名为 commit_finalization。调用方与测试构造同步更新。

陌生人策略测试显式投递建房待办后再验证用户快照；正常发送与重放改为核对待办数量不变，不再用影子调用次数证明可靠性。正在执行 /tmp/imv2-room-personal-source-finalization.log，包含建房并发、陌生人策略和房间日志专项；结果待确认。其他依赖房间库即时个人日志的测试仍需逐项审查并改为真实待办投递。

发送清理后专项的建房并发与陌生人策略通过；房间日志测试的 8 个断言仍期待冷启动个人事件立即写入房间库日志，因此失败（/tmp/imv2-room-personal-source-finalization.log）。测试现已显式领取四条冷启动待办、调用真实用户投影器并验证重复接收复用序号，再检查用户日志序号；没有把待办数量冒充投递完成。

转发导入恢复测试不再注入已删除的影子转发失败，改为在测试数据库安装触发器，仅拒绝 accepted 到 completed 的收尾事务。要求消息和完成凭证已提交、转发仍待收尾；移除触发器后验证归属变化拒绝收尾、恢复归属后重试成功且待办数量不变。只保留 room 与 shard 两个实际准入组合，删除重复的 planner 标签和不再使用的影子测试替身。当前复验 /tmp/imv2-room-personal-finalization-recovery.log，结果待确认。

发送收尾与转发恢复复验已通过：4 项测试、9.689 秒，/tmp/imv2-room-personal-finalization-recovery.log，退出码 0。包含建房 6 组、房间日志 2 组、转发完成事务失败及归属变化 4 组。证明的是本批受测路径，其他个人生产端与全量回归继续待办。

## 已读水位生产端复核发现待补项

PostgresV2ReadReceiptStore.recordGroup 和 record 的群分支仍调用 appendOwnReadWatermarkProjection，在房间连接写 user_sync_sequences/user_sync_log；带归属验证的单条 recordGroupOwnerValidated 实际委托给批量实现。群批量 GroupReceiptBatchStatement 只更新 room_read_receipts 和 read_receipt_operations，没有产生本用户跨设备水位事件。现有批量回执测试检查规范水位和幂等结果，不能证明其他设备收到水位。需要在群单条及批量源事务内补可靠个人待办，并验证批量合并、旧水位、重试和独立用户库投递。

另外，V2RoutedReadReceiptStore 的单聊分支仍回落到 controlStore.record，需结合独立房间归属部署核对房间数据边界；不能用同库私聊回执测试证明该路由正确。上述缺口属于当前未读与跨设备恢复要求，完整目标继续未完成。

## 群已读水位待办实现中

recordGroup 改为复用群批量路径，record 先处理该群入口再进入私聊分支。批量沿用既有按操作和 room/user 排序的事务咨询锁，在更新规范水位前读取基线；水位真正前进时与操作记录同事务写 own_read_watermark 待办。同批同房间同用户只选一个操作身份，保存合并后的最终水位；不推进的请求及既有操作重放不新增事件。时间保留原生 PostgreSQL 写入，载荷毫秒从实际保存的 updated_at 截断计算。准备语句身份更新为 v4。

已读回归新增合并与重放数量检查、房间库无该群个人日志、独立用户库投递与重复接收序号复用。首次编译因复核发现末尾断言混入同场景私聊个人日志而主动中断（退出码 130），断言改为限定群 room_id 后重跑；/tmp/imv2-group-watermark-outbox-final.log 正在验证群已读、时间精度和持久化重放时钟，结果待确认。私聊跨房间归属的路由和控制库个人生产者仍待审查。

群水位专项第二次编译发现新增测试 map 闭包内缺少 try，编译退出码 1，未执行用例；已修正。当前有效运行日志为 /tmp/imv2-group-watermark-outbox-verified.log，结果待确认，之前日志均不计通过。

群已读待办专项已通过（3 项、10.596 秒，/tmp/imv2-group-watermark-outbox-verified.log，退出码 0），包括群容量/入口时间精度组合、6 组存储时钟重放、单条与合并批量待办及独立用户库投递。

统一入口的复核发现私聊操作编号被群请求复用时，旧批量 prior 只查群操作会漏掉冲突；现改为读取既有操作所属类型，同一私聊房间仍交给私聊处理，其他房间复用编号直接返回 idempotencyConflict。新增单条和批量冲突断言，准备语句身份更新 v5，正在复验 /tmp/imv2-group-watermark-conflict-final.log。该运行结果尚未计为通过。

群水位操作冲突复验已通过（3 项、9.568 秒，/tmp/imv2-group-watermark-conflict-final.log，退出码 0），包括新加的私聊操作编号被群单条/批量请求复用的幂等冲突检查。当前无测试进程遗留。

## 私聊已读跨库修复的隐私依赖

V2RoutedReadReceiptStore 的单条和批量非群分支都调用 controlStore.record，直接查询控制库 rooms/direct_room_pairs；独立房间库不能由该调用读取。简单改为调用房间库同名方法也不正确：appendDirectProjectionIfVisible 从当前连接读取双方 user_read_receipt_preferences，缺行默认允许，可能把控制库中已关闭的披露偏好忽略掉。

异步私聊已读还需要保留撤销版本。客户端当前 direct_read_receipt 隐藏事件删除缓存行，可见事件按水位 MAX 插入；服务端快照也没有该类型的版本比较。因而晚到的可见事件可能在隐藏事件后重新出现。私聊跨库修复必须同时覆盖权威隐私偏好的读取边界、待办事务以及隐藏状态的版本保留，不能只迁移写库地址。该项仍未实施，现有群水位验证不覆盖它。

## 私聊已读撤销版本的客户端实现中

服务端全量回归已启动，使用当前构建和两个可丢弃数据库，日志 /tmp/imv2-personal-producers-full-server.log；运行期间不修改服务端或 Core 输入。

客户端 direct_read_receipt 新载荷要求 reader_preference_revision 与 viewer_preference_revision，均为非负整数。按两方版本识别旧事件；一方版本前进而另一方后退视为不一致，同版本不能改变可见性。隐藏事件在实时表和快照表保留版本与 is_visible=false，并将缓存已读水位置零，公开读取入口过滤隐藏行；更高版本重新允许披露时才能显示。该机制不依赖墙钟时间决定权限新旧。

新增客户端测试同时覆盖普通落盘重启与快照激活：隐藏后迟到的高水位旧事件不能恢复披露，重新允许后旧隐藏事件不能撤销新状态，版本不一致和同版本可见性冲突均回滚。当前日志 /tmp/imv2-receipt-visibility-client.log，结果待确认；schema 指纹需按真实新库更新。服务端尚未生成这两个偏好版本字段，因此本批属于协议两端尚未接齐的中间状态，不代表私聊已读已完成或可以发布。

客户端撤销版本行为的两个参数组合首次通过；结构检查按新增字段预期失败。核对真实新库 177 个对象后主库指纹更新为 0xf0103a619959480c，复验 2 项测试、2 个套件通过（0.286 秒，/tmp/imv2-receipt-visibility-client-final.log，退出码 0）。正在运行客户端全量 /tmp/imv2-receipt-visibility-full-client.log；服务端全量仍运行于 /tmp/imv2-personal-producers-full-server.log。客户端通过不代表服务端已经具备新版本字段。

客户端并行全量 563 项首轮有两处失败，均为后台同步计时上限（实际 6.745/6.034 秒，要求小于 5 秒）；撤销版本行为测试通过。日志 /tmp/imv2-receipt-visibility-full-client.log 保留，不能计为全量通过。未修改计时断言或生产超时，改为串行全量复验 /tmp/imv2-receipt-visibility-full-client-serial.log，以核实并发测试负载的影响；结果待确认。

## 私聊已读跨库的后续实施边界

1. 房间归属负责校验房间、当前成员、请求水位与归属代次；同一事务保存自身水位待办和发往对端的已读候选待办，不从房间库缺省读取用户隐私偏好。路由门面单条与批量的非群分支都必须调用归属验证的私聊入口，不能回落到控制库读取房间。
2. 控制面 user_read_receipt_preferences 增加单调偏好修订号；无偏好行的默认允许状态修订号为 0，已提交变更递增，幂等重放不递增。客户端已有 reader_preference_revision/viewer_preference_revision 必须来自这一权威状态。
3. 已读候选在用户投递端读取双方当前偏好，按与偏好写入一致的锁名获取共享围栏，直到首次用户投影提交。任一方不允许时生成带当前双方版本的隐藏投影，水位置零；不能因为来源房间库缺少偏好行而默认披露。
4. 接收回执保留原始源载荷用于身份校验，并另外保存首次确定的最终投影载荷。确认丢失后必须复用原序号和首次载荷，不能按变化后的偏好重新改写同一事件；迁移镜像、压缩后重试和 receipt 复制都要保留这份最终载荷。现有 projector 的单一 payload 字段尚不满足这一点，必须连同 schema 与迁移复制一起更新。
5. 关闭披露的传播任务按控制面的 direct_room_owner_routes 枚举相关私聊，不依赖控制库 room_read_receipts 或 direct_room_pairs 的房间事实。隐藏事件不要求此前已有可见回执；投递端再次依据当前权威版本处理，避免旧关闭任务在重新开启后覆盖新状态。
6. 控制库产生的个人待办需要运行相同派发器并纳入积压指标。运行时已存在控制库 delivery 连接池，应复用并按物理数据库去重；不能只扫描 roomOwnerDatabaseURLs 或额外创建未计入预算的连接池。
7. 服务端快照保留已读隐藏版本，按双方修订和水位收敛，不能把隐藏事件直接删除。后端产出的可见/隐藏载荷须与已实现客户端格式一致。
8. 验证真实分离的房间/控制/用户库、偏好关闭与投递竞态、确认丢失后偏好变化、重启与镜像、旧事件晚到、重新开启、同一操作冲突及批量回执；最后再执行全量、App 与运行时负载回归。

以上是基于当前调用链确定的未实施工作，不是已完成声明。普通控制面投影的 shadowForwarder 使用 projectAllocated 在当前用户归属分配序号，不能误认为它机械复用控制库序号而一并删除；它与已删除的房间写入影子回调有不同来源边界。

客户端串行全量复验通过（563 项、98 套件、52.455 秒，/tmp/imv2-receipt-visibility-full-client-serial.log，退出码 0），未放宽任何计时断言。服务端全量仍运行，已出现首次私聊时间精度用例的旧同步日志断言失败；需等整轮结束后按来源待办与真实用户投影更新对应验证，不能把当前全量计为通过。临时失败汇总 /tmp/imv2-personal-producers-failure-summary.json 标记 partial=true，不是完整结果。

服务端全量当前失败还包含 Direct write sequence exhaustion：旧断言把房间/时间线序号耗尽和个人同步序号耗尽都视为源消息回滚。新模型应分别验证：房间序号耗尽仍阻止公共提交；用户归属序号耗尽不应回滚已提交房间消息，而应让对应个人待办保留、投递暂停且不产生溢出序号。后续调整必须验证目标投影器和待办状态，不能仅删除旧断言或只核对发送成功。该整轮仍在运行，失败分类尚非最终。

## 不再实施的兼容工作

- 不排空旧计划，不迁移旧共享载荷，不恢复旧部署的撤销基线。
- 不保留历史请求指纹版本、旧协议字段或旧客户端最低能力门槛。
- 不设计双写、灰度切换或恢复旧模式的兼容回滚。
- 本轮新增的历史载荷物化实现、测试和命令行工具已经删除，不再恢复。
- 不自动删除用户本地数据库；验证使用明确可丢弃的测试环境。

## 验收矩阵

| 维度 | 验收要求 |
| --- | --- |
| 公共写入 | 单聊、小群和大群公共发送均不产生逐用户正文复制；建群成员发现只在真实个人状态变化时写入 |
| 个人可靠性 | 源事务回滚、目标提交后确认丢失、租约过期、数据库中断和进程重启不丢事件、不重复分配序号 |
| 分片运行 | 复制、转发失败、归属切换、日志压缩后重试、源清理均保留去重证据与序号一致性 |
| 权限 | 加入、移除、重入及逆序事件不恢复已撤销权限；无法读取未获授权时段的消息 |
| 客户端 | 未打开会话的新消息、离线追赶、新设备、快照重置、单侧提示、会话排序和未读正确；不能伪造 cursor=head |
| 运维 | 新库可初始化并通过 readiness；运行时无旧任务；暂停事件可定位重放，积压可观测 |
| 性能 | 固定数据量、连接数、发送率和群规模，记录接受延迟 p50/p95/p99、数据库写行/WAL、后台 CPU、补拉延迟与客户端追赶时间；没有实测前不承诺提升倍数 |

## 保留约束

房间 `message_row` 快速存储属于房间日志，继续保留。媒体、转发、推送、客户端命令及个人状态的可靠待办不能按名称误删。正常产品中的消息版本、授权历史、离线恢复与运行时分片迁移继续有效；删除旧模式兼容不等于删除这些功能。缺失回执不能视作已读，游标只能跟随实际应用的事件前进。

## 私聊回执最终载荷的调用链复核

本轮只读复核时，全量服务端会话 44309 仍存活；保持服务端源码和测试输入不变。

- `V2RoutedUserStateEventProjector.project` 已在 `withCurrentRoute` 的控制事务内执行。该回调提供的控制连接可以取得双方偏好共享锁并读取权威偏好；无需再嵌套借用新的控制连接。必须保留现有“路由围栏连接池独立于用户写入池”的约束。
- `PostgresV2UserStateEventProjector.project` 当前只返回序号，迁移随后调用 `mirror(event, sequence:)`，因此仅新增 receipt 数据列还不够。内部投递结果须携带首次保存的最终载荷；普通协议入口可继续返回序号，路由入口使用完整结果镜像。重试从已有 receipt 返回最终载荷，不能用本次重新计算的载荷替换。
- `PostgresV2UserShardProjectionTransfer.copyUserStateReceipts` 的 SELECT、INSERT、冲突更新，以及 `fingerprintUserStateReceipts` 的 SELECT 和 `ProjectionUserStateReceiptRow.line` 都要加入最终载荷。否则迁移校验可能认可一份遗漏披露状态的副本。新增测试应只篡改最终载荷，证明指纹会拒绝该副本。
- 去重仍比较源 payload；用户日志占位一致性必须比较最终 payload。两者不可共用一个字符串，也不能把重新解析后的候选事件作为新源身份。

服务端日志的阶段性分类现为 7 个用例名称、294 条断言问题，仍非最终结果。新增的两类时间校验失败已检查具体断言：`Direct room creation validates persisted pair and profile timestamps` 的两条均在第 6016 行期待即时 user_sync_log=1；`Direct room and preference timestamps are rejected before durable writes` 的一条在第 10819 行期待即时 user_sync_log=3。它们当前没有报告时间拒绝失败，后续应保留时间拒绝断言，并分别核对已提交待办及真正投递后的用户日志。不能据此把整轮测试标为通过。

## 服务端回执快照补丁已准备，尚未应用

全量服务端会话 44309 仍运行，因此本次在 `/tmp/imv2-receipt-snapshot-draft/` 准备补丁，不改动其正在验证的服务端输入。`snapshot-privacy.patch` 修改 `PostgresV2UserProjectionWorker`：按双方隐私版本收敛，保留隐藏版本，拒绝交叉版本及同版本可见性冲突；隐藏载荷要求水位为 0。新增 `directReceiptSnapshotOrdering` 三个参数场景，覆盖隐藏后旧高水位、重新开启后旧隐藏、同版本低水位、worker 重建后持久状态，以及可见性、交叉版本和读者身份冲突。

临时文件已通过 `swiftc -frontend -parse`，补丁已通过 `git apply --check`；这些只证明语法和可应用性，不是编译或数据库测试通过。`source-hashes.json` 保存准备时两个源文件的 SHA-256，应用前要再检查源文件没有变化。本轮测试结束后应用补丁，并运行带真实数据库环境的专项测试。该补丁仅完成快照消费端，不替代候选生产、权威偏好版本或首次载荷冻结。

## 首次投递载荷与快照补丁已应用

服务端全量会话 44309 已结束，退出码 1；1015 项、136 套件、1314.885 秒、303 条问题。完整日志为 `/tmp/imv2-personal-producers-full-server.log`，`/tmp/imv2-personal-producers-failure-summary.json` 已标记 partial=false，按 9 个用例名称归类。除前述时间精度和序号耗尽外，还包括 direct/social shadow 与 display-name 分页投影断言；尚未把这些失败全部归因为旧测试，也未计为通过。

核对源文件 SHA-256 后，已应用临时目录的 complete.patch：

- 目标 receipt 同时保存源 payload 和 projection_payload；普通重试验证源身份并返回首次保存的最终载荷。镜像额外验证最终载荷，不能静默改写。
- 路由投递的内部结果携带序号和最终载荷，镜像使用该结果；迁移复制和迁移指纹都包含 projection_payload。
- 服务端快照按双方隐私版本保留隐藏状态，拒绝交叉版本、同版本可见性变化与读者身份变化。
- 新库契约更新为 im-v2-current-35，启动检查和部署结构检查要求最终载荷列为非空 JSON 对象。不提供历史升级路径。
- 新增首次载荷跨库镜像、日志压缩后重试、源身份冲突，以及三组快照顺序/冲突测试。

当前专项会话 6129 正在编译并测试 PostgresV2UserStateEventTests，已提供主库、独立目标库和可丢弃环境标记；日志 `/tmp/imv2-resolved-receipt-server.log`。生产模块已完成编译，整个专项尚无最终结果。权威隐私偏好修订、候选生成和跨库已读路由仍未接入，不能据此认定私聊已读链路完成。

## 首次载荷专项通过，隐私偏好修订已接入写入事务

会话 6129 退出码 0：20 项、1 套件、12.072 秒通过，日志 `/tmp/imv2-resolved-receipt-server.log`。实际执行了独立目标数据库的首次最终载荷镜像、日志删除后重试、源身份/镜像载荷冲突，以及三组快照隐私版本顺序场景。此结果只覆盖个人投递及快照，不代表整个私聊已读跨库链路完成。

控制面的 user_read_receipt_preferences 与 read_receipt_preference_operations 新增 preference_revision。首个已提交偏好操作为 1；新操作在相同事务中递增并保存操作版本，重复操作提前返回原结果，冲突操作不改变版本。递增不依赖 updated_at；到 Int64.max 时拒绝新操作并回滚，已提交操作仍可重放。偏好同步载荷携带 preference_revision，启动与部署结构检查要求两个版本列存在且非空。当前消费者尚未利用偏好自身投影的版本字段做逆序收敛；对端回执的投递政策解析仍待接入。

新增 readReceiptPreferenceRevisionOrdering 验证时钟倒退、幂等/冲突、载荷和操作版本一致，以及最大修订号下的拒绝与重放。会话 40817 正在编译验证，提供两个真实可丢弃数据库，日志 `/tmp/imv2-preference-revision-server.log`；尚未计为通过。

## 权威已读隐私校验已接入用户投递入口

偏好版本专项会话 40817 退出码 0：1 项、0.909 秒通过，日志 `/tmp/imv2-preference-revision-server.log`。

新增 V2DirectReadReceiptPolicy，并在 V2RoutedUserStateEventProjector 中处理 direct_read_receipt 候选。使用现有控制事务，按稳定 UUID 顺序获取与偏好写入相同名称的共享锁，读取双方权威开关和修订号，直至用户投递及镜像提交后释放。控制库没有偏好行才使用允许/版本 0；不再依赖用户目标库的偏好行。关闭时生成水位 0 的隐藏载荷，双方版本来自控制库；已存在的目标回执仍返回首次最终载荷。

专项会话 27936 退出码 0：21 项、1 套件、12.996 秒通过，日志 `/tmp/imv2-authoritative-receipt-policy.log`。新增两个参数场景分别由 reader 或 viewer 关闭控制库偏好，用户投递在独立数据库且该库没有偏好行；验证关闭后新事件隐藏、旧事件确认重试内容不变、重新允许后可见和服务端快照收敛。

该入口当前只接受正水位的房间回执候选。房间侧 record 仍需改成同事务保存 own_read_watermark 与 direct_read_receipt 候选，路由门面非群分支仍需移出 controlStore。偏好关闭传播还未改为控制目录与可靠候选；零水位/重新开启后的旧关闭任务必须单独设计并验证，不能把隐藏状态标成当前允许版本而造成同版本可见性冲突。当前通过不涵盖这些未接齐的生产路径。

## 私聊回执房间待办与归属路由已接入

PostgresV2ReadReceiptStore 的私聊推进事务现在原子保存 own_read_watermark 和 direct_read_receipt 候选待办，不读取房间库的隐私偏好，也不直接分配用户同步序号。重复操作和不前进的水位不再生成待办。V2OwnerValidatedReadReceiptStore 新增统一归属写入入口；路由门面的单条和批量非群分支均调用房间归属，控制面只处理用户偏好及披露查询。

首轮会话 7181 退出码 0：6 项、2 套件、2.385 秒通过，日志 `/tmp/imv2-direct-owner-outbox.log`。真实测试将私聊房间放在主数据库，控制目录和偏好放在独立数据库，用户投递使用独立 schema/连接池。两个参数覆盖单条和批量，检查错误归属拒绝、控制库没有该房间、重试/水位不变仅两条待办、源库没有即时已读同步日志，以及用户投递实际遵从控制库关闭偏好。

随后复核发现私聊归属校验先 FOR SHARE 后 FOR UPDATE 会有并发锁升级风险，已改为直接取得房间写锁；操作咨询锁改为与群入口相同的命名规则，并移除私聊入口中已不可达的旧群 CTE，改为直接读取已提交操作完成幂等重放。新增 8 个并发私聊上报，验证不产生重复待办且无锁升级死锁。

复验会话 22407 正在编译，日志 `/tmp/imv2-direct-owner-outbox-concurrency.log`；首轮通过不覆盖后续锁修改。本轮仍未迁移偏好关闭传播，也未更新所有旧即时日志断言或完成全量回归。

## 关闭回执传播改为控制目录待办，正在验证

并发私聊复验会话 22407 退出码 0：6 项、2 套件、2.478 秒通过，日志 `/tmp/imv2-direct-owner-outbox-concurrency.log`；包括两个分库参数场景中的 8 个并发回执上报。

零水位语义补充：可见性代表当前是否允许披露，零水位只更新政策版本，不证明发生阅读。客户端公开查询额外要求水位大于零；隐藏状态仍要求水位为零。这样，重新开启后迟到的关闭任务可以按最新偏好生成“允许但没有进度”的状态，同版本真正的正水位可以继续推进，同版本迟到的零水位不能覆盖已有正水位。该设计取代此前“可见状态必须为正水位”的内部约束；用户界面不会显示零水位已读。

客户端主表真实结构仍为 177 对象，指纹改为 0x153b6d54ce63806a。首次专项仅指纹断言失败，行为场景通过；核对真实新库后复验会话 52299 退出码 0：3 项、2 套件、0.302 秒通过，日志 `/tmp/imv2-receipt-policy-only-client-final.log`。客户端全量串行会话 78631 进行中，日志 `/tmp/imv2-receipt-policy-only-client-full.log`。

V2ReadReceiptPreferencePropagationWorker 已改为分页枚举控制库 direct_room_owner_routes，在事务内为双方保存零水位 direct_read_receipt 候选，保留原有租约、分页和确定性事件身份；删除即时控制日志分配、shadowForwarder/liveNotifier 依赖及相关调用参数。目标投递继续读取双方当前偏好并冻结首次载荷。服务端快照和候选解码同步允许政策专用的零水位。

复核运行时发现 roomOwnerDatabaseURLs 的构造已经显式包含 configuration.databaseURL，并按 URL 去重；派发、维护清理和指标都使用这组连接。因此早期“运行时可能遗漏控制库”的待办已由当前源码证明不适用，不再新增重复连接池。

新增 readReceiptPolicyDirectoryPropagation，控制库只有两条私聊目录而没有 direct_room_pairs，按每页一房间生成四条待办；在投递前重新开启，验证零水位保持不可展示、真实后续进度可以推进、原待办重试不覆盖结果。服务端会话 82668 正在编译/测试该用例和全部 PostgresV2UserStateEventTests，日志 `/tmp/imv2-policy-directory-propagation.log`，尚未计为通过。已有依赖旧 shadow 失败注入和即时控制日志的传播测试仍需改为真实待办故障/投递验证，不能仅删除断言。

客户端串行全量会话 78631 已通过，退出码 0：563 项、98 套件、37.418 秒，日志 `/tmp/imv2-receipt-policy-only-client-full.log`。服务端传播专项 82668 仍在编译，结果未定。

服务端会话 82668 退出码 1，测试未执行：一处返回类型推导的测试 worker 辅助函数仍传入已删除的 shadowForwarder 参数。已修正此编译遗漏，原测试的 shadow 故障注入语义仍列为待改为真实待办故障验证；新复验日志 `/tmp/imv2-policy-directory-propagation-final.log`。

## 传播故障用例改为真实完成事务失败，偏好投影补上版本收敛

传播复验会话 42947 退出码 1：22 项、2 套件、14.324 秒、2 条问题。PostgresV2UserStateEventTests 全部通过；目录传播用例失败在快照计数和最终状态查询。源码确认 PostgresV2UserProjectionWorker 每轮 LIMIT 1 用户，而此用例涉及三个用户；已改为明确运行三轮、逐轮断言失败数为零、累计五条记录，再确认无剩余工作。并非放宽生产行为。

receiptPropagationClockBounds 已移除不起作用的 shadow 故障参数，测试目录由实际房间身份建立。新增数据库触发器在双方候选已提交后拒绝传播任务的 completed 更新；断言观察的是真实持久待办、被保留的租约、恢复时间和重复执行不新增候选。即时已读控制日志要求为零，候选要求为两条；传播报告的房间计数对应已经保存的候选，完成失败不抹去该事实。

另补齐 read_receipt_preferences 自身的版本收敛：客户端缓存和服务端快照按 preference_revision 忽略旧事件，同版本不同内容拒绝。客户端新表仍有 177 个对象，真实指纹为 0xd16acc486e428e07。客户端首次专项仅结构指纹失败、偏好行为用例通过；已核对新库后更新指纹并启动串行全量会话 82217，日志 `/tmp/imv2-preference-client-order-full.log`。

服务端新复验会话 33830 包含 receiptPropagationClockBounds（三个参数）、目录传播和全部个人事件测试，使用两个独立数据库，日志 `/tmp/imv2-policy-propagation-clock-recovery.log`；正在编译，尚无最终结果。

客户端串行全量 82217 退出码 0：564 项、98 套件、37.314 秒通过，日志 `/tmp/imv2-preference-client-order-full.log`。服务端 33830 仍在编译复验。

## 传播恢复专项通过，继续修正旧即时日志测试

会话 33830 退出码 0：24 项、2 套件、17.225 秒通过，日志 `/tmp/imv2-policy-propagation-clock-recovery.log`。覆盖真实完成事务失败后的时钟/租约恢复（三种参数）、控制目录分页、重新开启后投递旧政策待办、所有个人事件投递及偏好/回执快照版本收敛。

已修改三组旧断言用例：directAuxiliaryProjectionTimestampPrecision、directRoomSourceTimestampBounds、directMessagingTimestampBoundaries。现在先验证房间源库没有即时用户日志、待办数量正确，再实际 claim/project/重复 project/acknowledge，最后检查用户投影。首次发送与源时间边界用例使用独立目标数据库；混合偏好边界用例保留原单库夹具，确认原有两条偏好同步记录加上真正投递的开房事件后才有三条用户日志。回滚快照补入待办表。

首次发送的旧 planner/preplanned/room-log 标签此前全部调用同一 scalar 代码，现合并为 scalar 与 atomic 两种真实入口，保留七组时间边界。新专项会话 27787 正在编译，日志 `/tmp/imv2-personal-clock-projection.log`，提供主/目标两个数据库。尚未计为通过，其他旧即时日志与序号耗尽测试仍待处理。

## 待办跨库时间精度修复与用户序号耗尽测试

会话 27787 退出码 1：3 项、13.292 秒、4 条问题；源时间边界及开房/偏好时间拒绝两项通过，首次发送在 scalar/atomic 的 clock=1（数据库纪元后约 1 微秒）各两条目标时间断言失败。复核发现 UserStateEventClaimRow 把持久时间解码为 Date，目标投递再编码 Date；该往返可能把原微秒向零截断。V2UserStateEvent 现保留内部 V2PostgresTimestamp，公共 createdAt 仅作 Date 视图；从待办读取、目标 receipt/log 写入及控制传播候选创建均保留原始微秒整数。公共 Date 构造入口仍先校验有限范围。

directWriteProjectionSequenceBoundary 已按新模型改写为六种真实入口/接收者场景，删除重复的 planner/preplanned 标签。先投递开房事件，再耗尽源库和独立用户目标的个人序号；消息或拒绝业务事实仍提交，失败的个人事件暂停保留。恢复测试目标容量后重新投递，检查最终序号、精确事件数量，以及源业务重试不产生新待办。未放宽房间序号约束；该用例只覆盖个人序号耗尽。

新会话 56860 正在编译，包含上述序号耗尽、三组时间测试和全部个人事件测试，日志 `/tmp/imv2-native-personal-event-timestamp.log`，使用主/目标两个数据库。尚未计为通过。其他个人操作中 direct-open/direct-receipt 的旧回滚假设及余下全量失败仍待更新验证。

## 原始微秒与消息侧个人序号边界通过

会话 56860 退出码 0：26 项、2 套件、44.574 秒通过，日志 `/tmp/imv2-native-personal-event-timestamp.log`。包含原先失败的数据库纪元后微秒边界、所有七组 scalar/atomic 时间案例、开房时间拒绝，以及六种用户目标序号耗尽后保留业务提交和暂停待办、恢复容量后唯一投递的场景。

personalProjectionSequenceBoundary 已为 direct-open/direct-receipt 单独增加异步分支：源操作提交且重试稳定，独立用户目标耗尽时没有半条投影，源待办暂停；恢复测试容量后通过实际路由投递器读取控制隐私并写入最大可用序号，重复投递不重新分配。其余七种控制面操作仍验证事务回滚，不统一改为异步假设。新专项日志 `/tmp/imv2-personal-operation-sequence.log`，结果待确认。

## 九类个人操作序号边界通过

会话 84858 退出码 0：1 项测试、9 个参数场景、7.500 秒通过，日志 `/tmp/imv2-personal-operation-sequence.log`。覆盖开房和私聊已读在目标耗尽时保留源待办并恢复到最后一个用户序号，以及其他七类控制面操作继续保持序号耗尽时的事务回滚。

已应用 denialResponseTimestampPrecision 与 directSocialResponseTimestampPrecision 的新链路验证：拒绝提示先检查源用户日志为空，再认领并向独立用户库投递全部待办，重复投递和确认后检查原时间戳；业务源重放快照加入待办表。混合社交用例仅开房走独立用户投递，其他社交操作保持原有即时事务检查。新日志 `/tmp/imv2-denial-social-event-clocks.log`，结果待确认。

## 拒绝与社交时间专项通过，迁移测试接入房间待办

会话 25552 退出码 0：2 项、51.862 秒通过，日志 `/tmp/imv2-denial-social-event-clocks.log`。拒绝提示包含 scalar/batch × generic/system 四组参数与五个时间边界；直接开房及其他社交操作继续验证数据库原时间、重试与状态不变。

已修改 forwardingShadowsDirectAndSocialUserSyncRecords：开房后实际认领待办，经独立路由围栏连接池投递到源用户分片并镜像；保留原有控制事件顺序与迁移校验，归属切换后额外重放开房事件，验证使用迁移后的接收回执而不增加序号。propagatesDisplayNameToExistingDirectPeers 先实际完成六条开房/首条消息待办，再测试显示名分页传播及原有控制侧失败恢复。

新专项日志 `/tmp/imv2-migration-personal-outboxes.log`，结果待确认。完成这两项后仍需重新执行全量，收集私聊回执和偏好传播改造引出的其余旧测试假设或实际缺陷。

## 当前客户端改造的 App 单元验证通过

App 会话 57653 退出码 0：233 项、36 套件、7.119 秒通过，日志 `/tmp/imv2-receipt-version-app.log`，结果包 `/tmp/imv2-receipt-version-app.xcresult`。复用本任务创建的 iOS 26.2 模拟器 IMV2 Room Log Acceptance（1BA89561-47DA-47F9-AE9B-08FA8A1DBA9D），使用临时签名 CODE_SIGN_IDENTITY=-，没有修改项目签名。结束后检查模拟器已经处于 Shutdown。

此结果覆盖当前客户端的回执/偏好缓存变更在 App 层的单元回归；不能代替真实 TLS 账号链路、单侧提示 UI 或当前服务端负载/重启验证。迁移专项会话 77381 仍在编译，日志 `/tmp/imv2-migration-personal-outboxes.log`。

迁移专项 77381 已通过，退出码 0：2 项、1.589 秒，日志 `/tmp/imv2-migration-personal-outboxes.log`。确认真实开房待办被镜像、切换归属后重放不增加序号；显示名更新在开房及首条消息待办已实际投递的基础上完成分页和重试验证。

当前构建的服务端全量串行回归已启动，日志 `/tmp/imv2-receipt-complete-full-server.log`；显式配置主/次可丢弃测试库并使用 --skip-build。运行期间保持服务端/Core 源码、测试及 schema 输入不变。结果尚未确定，不能沿用旧全量的通过记录。

## 当前界面与 schema 35 独立验收

当前 App UI 会话 94287 退出码 0：6 项、47.078 秒、无失败，日志 `/tmp/imv2-receipt-current-ui.log`，结果包 `/tmp/imv2-receipt-current-ui.xcresult`。覆盖未登录启动、密码登录/注册的大字体 RTL 布局、注册资料校验与撤销暂停恢复。此组没有单侧提示真实会话场景，不能替代该项验收。

`check_v2_document_links.sh` 与 `check_v2_schema_readiness_tables.sh` 均通过。原生 PostgreSQL 独立建库会话 88944 退出码 0，日志 `/tmp/imv2-schema35-bootstrap.log`：当前 schema 35 新建、145 个关系/338 个索引/23 个应用触发器/22 个函数校验、导出到第二个临时库后结构一致、部署契约校验及非空旧结构拒绝均通过；脚本退出时清理自己创建的两个数据库，没有复用全量回归数据库。

全量服务端会话 28732 已再次确认仍在运行。首组传播重试边界失败来自旧 fixture 缺少控制目录路由、仍期望即时回执 effects，且旧 shadow 故障对象不再连接生产路径。已在 `/tmp/imv2-retry-boundary-new.swift` 准备替换草稿，使用控制目录、真实完成事务触发器失败、源待办的内容/数量稳定断言；对应原片段为 `/tmp/imv2-retry-boundary-old.swift`。尚未应用，等待全量结束后修订并编译验证；仍需补充实际目标投递断言，不能以草稿视为修复完成。

## 回归期间补齐的传播测试草稿

回执重试草稿 `/tmp/imv2-retry-boundary-new.swift` 已增加恢复后的真实跨库投递：从源待办认领四条回执候选，经控制库隐私校验写入独立用户库，每条重复投递仍返回原序号，并检查四条隐藏零水位日志及源确认状态。枚举失败仍采用实际完成事务触发器，测试源待办内容在重复枚举后稳定。

另已准备 `/tmp/imv2-propagation-timestamp-new.swift`（原片段 `/tmp/imv2-propagation-timestamp-old.swift`），为回执分支提供控制目录，并读取源待办的原生 PostgreSQL 时间后经实际路由投影到独立目标库；保留五个时间边界、重复枚举及原目标记录逐字段稳定比较。极端未来时间直接验证原生事件的投影，不人为用越界租约认领时间。两份均为尚未应用、尚未编译的草稿，不能视为通过证据。

当前全量日志的阶段性失败汇总写入 `/tmp/imv2-receipt-current-failure-summary.json`，partial=true，目前28条问题均来自传播重试边界测试；完整结果仍以会话28732最终退出和完整日志为准。

## 传播序号耗尽测试草稿

已准备 `/tmp/imv2-propagation-sequence-new.swift`，对应原片段 `/tmp/imv2-propagation-sequence-old.swift`。回执两种接收方边界改为源传播正常完成、独立目标序号耗尽时无半条接收凭据、另一侧独立投递、暂停事件恢复到 Int64.max、重放不再次分配序号；重跑已完成传播不会复活已确认待办。已按当前 schema 校正源待办无 paused_at 字段，并按真实分配器校正最后可用返回序号为 Int64.max。仍未应用或编译，profile 分支的原有控制事务边界继续保留。

## 私聊回执时间测试切换草稿

全量阶段性新增14条问题均在 directReceiptResponseTimestampPrecision 的旧源库即时回执断言。已准备 `/tmp/imv2-direct-receipt-time-new.swift`（原片段 `/tmp/imv2-direct-receipt-time-old.swift`）：保留 scalar/batch × visible/hidden 四组、六个时间边界、前进/不前进水位与业务重放检查；读取源待办原生时间，通过实际路由投递至独立用户库，重复投递不新增记录，关闭展示产生隐藏零水位记录。重放快照加入源待办及目标投影状态。

四份当前待应用草稿（retry-boundary、propagation-timestamp、propagation-sequence、direct-receipt-time）已共同通过 `swiftc -frontend -parse` 语法检查，退出码0。这只证明可解析，不代表类型检查、编译或运行通过。全量会话28732仍在运行，尚未改动其测试源码。

## 真实连接单侧提示验收缺口定位

检查 `IMAppLocalAccountUITests.testReceiverCanBlockAndRestoreExistingDirectMessageDelivery`：当前真实 TLS 用例只验证 block、发送 forbidden、unblock、重新接受；没有读取双方 timeline_activity、本地重开或 XCUIApplication 会话提示断言。现有 launch UI 六项也不覆盖会话。可复用该文件现有随机账号、独立 SQLite、V2SyncEngine 与 scoped App 启动基础补充，但当前未实现，不能将旧真实连接通过作为单侧提示 UI 验收证据。

最新阶段性汇总为四组60条问题（28/14/16/2），分别对应已准备的重试、直接回执时间、传播序号、传播原生时间草稿；全量仍未结束，汇总保留 partial=true。

## 综合私聊传播故障修订草稿

`/tmp/imv2-composite-receipt-new.swift`（对应原片段 `/tmp/imv2-composite-receipt-old.swift`）为综合私聊策略用例补上控制目录与实际路由投递，首次两页产生四条回执后显式投递。第二次关闭偏好在真实 enumeration_checkpoint 更新触发器处注入瞬时故障，保留已提交候选，移除故障后保留显式暂停及 operator replay 验证，再完成两页并投递，检查累计八条而非重复新增。草稿已通过单文件 Swift 语法解析，尚未应用或编译。全量28732仍活跃，继续保持其源输入不变。

## 当前全量终态与修订应用

全量会话28732已退出1：1022项、136套件、1297.182秒、73条问题。最终汇总 `/tmp/imv2-receipt-current-failure-summary.json` 的 partial=false，六组分布为传播重试28、直接回执时间14、传播序号16、传播原生时间3、综合私聊6、单调已读状态6。

已在完整日志终态确认后将前五份草稿精确替换到集成测试源码。当前专项会话19519正在编译与运行，日志 `/tmp/imv2-receipt-five-revised-tests.log`，过滤五个对应测试方法，显式启用主/次独立测试库。尚无通过结论。

最后一组草稿 `/tmp/imv2-watermark-receipt-new.swift`（原片段 `/tmp/imv2-watermark-receipt-old.swift`）准备完成：区分源库无即时对方回执与目标库实际投递；包括新增私聊自己的水位，修正总计为四条 ownReadWatermark 加一条 directReadReceipt，使用真实控制隐私路由投影并重复投递验证。待19519结束后应用并测试，避免修改当前编译输入。

## 五组专项结果与有符号时间修复

会话19519退出1：编译200.32秒，5项27.836秒。传播重试24参数、传播序号3参数、综合私聊均通过。直接回执时间四参数及传播时间receipt参数共5条 invalidEvent，定位为真实契约问题：V2GatewayTimestamp 明确允许纪元前的有符号毫秒，但新增权威回执校验及两端投影对 recorded_at_ms 误加非负限制。

已移除 direct-read candidate、服务端 directReceipt/ownReadWatermark 快照解码、客户端对应解码中的非负时间限制；保留 Int64 解码边界和水位/版本/可见性校验。没有修改源事件原生微秒持久化。客户端既有回执重启/快照测试新增 -1 毫秒参数，自身水位测试也新增 -1 参数。

第六组 watermark-receipt 草稿已应用。当前服务端会话40076正在编译/运行六组专项，日志 `/tmp/imv2-receipt-six-signed-time-tests.log`；客户端会话66938正在编译/运行 V2DirectReceiptVisibilityTests 和 V2RoomReadWatermarkTests，日志 `/tmp/imv2-client-receipt-signed-time.log`。两者尚无最终结论；当前版本全量与App/真实运行验收仍需完成。

客户端66938已退出0：6项、2套件、0.357秒通过，包含回执快照/重启四参数与自身水位负时间参数。服务端40076仍在编译，不能据客户端专项推断服务端已通过。

## 六组修订收敛与快照验证通过

客户端全量95926退出0：564项、98套件、6.351秒通过，日志 `/tmp/imv2-client-signed-time-full.log`。

服务端40076退出1：编译202.80秒，6项41.777秒；五组通过，仅直接回执时间四参数各剩一个payload时间不一致。直接回执候选原使用 PostgreSQL floor(EXTRACT(EPOCH)*1000)，与响应 V2GatewayTimestamp 的向零截断契约在边界处不一致。已改为绑定相同 `v2GatewayMilliseconds(receipt.recordedAt)`，原生 created_at 不变。

服务端快照测试已应用有符号时间参数，水位非法时间由合法的-1替换为 Int64.max+1，保留真实越界拒绝检查。会话21296退出0：编译24.09秒，23项、2套件、18.247秒通过，日志 `/tmp/imv2-receipt-canonical-time-snapshot-tests.log`。覆盖直接回执四参数及全部 Independent user state events，包括快照六参数和自身水位两个时间范围。

当前源码的新一轮服务端全量已启动，日志 `/tmp/imv2-room-log-final-receipt-full.log`，显式两测试库、--skip-build、--no-parallel。运行期间继续保持Server/Core/schema/测试输入稳定；此次结果尚未确定，不能据专项推断全量通过。

## 当前 App 验证与真实单侧提示同步验收启动

App单元会话13616退出0：233项、36套件、7.305秒，日志 `/tmp/imv2-signed-time-app.log`，结果包 `/tmp/imv2-signed-time-app.xcresult`，包含最新客户端有符号回执时间修复。

已扩展真实本地账户测试 `testReceiverCanBlockAndRestoreExistingDirectMessageDelivery`：被限制发送后以两份独立SQLite同步，等待发送方恰好一条 directMessageRestricted 并检查接收方为空；断开发送方连接，重新打开原SQLite并用新TLS连接补拉，检查原提示身份、位置、时间完整保留且不重复；解除限制后仍可接受消息。该验证不启动聊天界面、不等同App进程重启，仍不能代替单侧提示UI验收。构建会话85522退出0，日志 `/tmp/imv2-private-hint-e2e-build.log`。

`verify_v2_live_account_authorization.py` 新增可选 `--private-hint`，要求 --app-ui --gateway，复用专有临时服务/数据库/模拟器，在原App验收中额外选择上述真实两客户端测试；不改默认选择。Python语法检查通过。已启动当前源码真实HTTPS/TLS/App恢复/headless及private-hint验收，输出目录 `/tmp/imv2-current-private-hint-acceptance`，入口日志 `/tmp/imv2-current-private-hint-acceptance.log`，结果尚未确定。

服务端全量8631仍在运行，保持其Server/Core/schema/测试源码不变。

## 单侧提示界面与冷启动验收已接入

在同一真实双客户端限制发送用例中新增 MainActor UI 步骤：使用发送者真实账号登录一份随机 scope 的 App 安装，等待既有私聊列表项，以事件 source ID 对应的 accessibilityIdentifier 检查聊天页恰好一条系统提示；terminate App 后通过 scoped restore 冷启动，再从原私聊检查同一提示且只有一条。defer 通过既有 scoped cleanup 清理 Keychain/SQLite 并终止 App。这里直接打开已同步的原私聊，不再次调用公开身份查询或新开房接口。注册辅助结果只增加随机测试 accountHandle 用于真实登录。

构建56728退出0，日志 `/tmp/imv2-private-hint-ui-build.log`。运行验收20849当前仍等待服务端全量8631持有的 SwiftPM 构建目录锁，尚未启动临时服务或模拟器；不是故障或进程失踪，不重启。锁释放后脚本将编译并执行更新后的同一测试方法，包含新增UI冷启动断言。当前只能确认编译通过，不能确认运行通过。

## 两项完成标准的当前复核

已勾选旧计划字段/准入协议耦合删除与群容量等级分离两项。当前仓库非文档、非测试源（含协议定义）搜索 fanoutPlan/targetRule/fanout_plan/target_rule 无命中，生产源码文件名也无旧扇出或预览引擎。V2GroupCapacityClass 仅 standard/large，V2GroupCapacityPolicy 保留5000/100000上下限；此前完整回归中公共操作与幂等边界均通过，最新六组回执专项也保留业务重复请求检查。此结论仅针对这两项，不代表完整服务端回归或运行验收已通过。

复核发现 schema 的容量不可变触发器仍有旧 delivery mode 错误文案，辅助个人日志唯一索引名称包含 nonfanout；它们对应现有约束，不是旧投递执行入口。设备登记 legacy 取消恢复属于独立账号生命周期范围，没有按“删除旧通讯模式”扩大删除。

## 当前发布二进制复测准备

当前全量阶段性汇总 `/tmp/imv2-room-log-final-receipt-summary.json` 为 partial=true、issues={}，不能视为全量已通过。已复核既有临时负载/重启脚本仍创建独立随机库、20连接、明确800消息场景、确认后SIGKILL及零游标恢复逐客户端水位核对，并在finally清理自身进程与数据库。

已排队构建当前 Release IMV2ServerApp 与 IMV2GatewayLoadGenerator（依次、jobs4），日志 `/tmp/imv2-current-release-build.log`，等待同一SwiftPM构建锁释放后执行。当前还未使用新二进制跑负载，不沿用之前的通过结论。真实验收20849也在等锁；两者不是挂起失踪，不因暂无输出而重启。

## 个人事件运维恢复完成标准复核

已勾选暂停定位/恢复/积压可观测项。当前 PostgresV2DurableWorkReplayStore 按 source_event_id/user_id/projection_kind 重排暂停行，清理旧租约并记录审计；userStateOperatorReplay 实际PostgreSQL测试覆盖单条幂等、有界分页、旧ACK失效、重新认领及3条审计，最近完整运行中通过（2.842秒）。HTTP重放路由与鉴权测试同轮通过。PostgresV2UserStateEventMetricsSource 区分 ready/leased/scheduled/paused，年龄排除已完成事件；当前专项21296中相关真实数据库测试通过（0.351秒）。main按含控制库的去重物理来源库集合安装采集器，V2DurableWorkMetrics输出对应四类积压和最老未完成年龄。相关实现未受随后时间修复改变。

此项通过不替代实际App单侧提示冷启动、当前发布负载/重启或当前服务端全量结果。

## 当前服务端全量通过

会话8631退出0：1022项、136套件、1310.659秒全部通过，日志 `/tmp/imv2-room-log-final-receipt-full.log`；最终汇总 `/tmp/imv2-room-log-final-receipt-summary.json` partial=false。此次运行包含最后的有符号回执时间、统一响应转换、六组实际跨库传播修订及快照参数，不沿用旧二进制结果。

结合当前生产路径复核及完整回归，勾选公共房间日志唯一写入、会话/成员个人事件、ClientKit/App统一房间同步、旧worker/载荷/队列清理四项。群创建和成员变化的当前SQL明确写 user_state_event_outbox；全量覆盖各公共变更/归属/权限/幂等边界，个人流公共载荷拒绝测试也通过。客户端564项及当前App233项通过，旧预览引擎已无生产入口。余下跨进程恢复、单侧提示真实UI、完整启动/运行及当前Release负载仍保持未完成。

全量释放锁后，真实验收20849已开始当前源的本地构建，日志显示C依赖编译推进；Release83331仍等待锁。没有重启任何任务。

## 当前真实服务已就绪

真实验收20849已输出当前账户程序构建完成、Native TLS Gateway及认证连接指标就绪、独立PostgreSQL/HTTPS监听就绪，已越过构建锁等待进入实际连接阶段。Release83331已完成首个IMV2ServerApp产品构建，正在构建负载工具；尚未开始本轮负载。两项进程已继续确认存活，最终结果待回收。

## 当前发布负载与强制重启复测通过

Release构建83331退出0，当前网关与负载工具构建完成。运行15784退出0，三轮固定负载（私聊、20人群、100000人群）与两轮确认后强制重启（私聊、大群）全部通过；每轮800条ACK、逐客户端水位及个人日志无公共message核对，正常停机与自身资源清理。当前报告见[当前版本运行验收](room-log-current-runtime-2026-09-13.md)，包含最终二进制哈希与每轮证据目录。此报告不宣称容量上限，也注明同机App验收造成的性能测量限制。

真实验收20849退出1：HTTPS授权套件通过，两个既有App恢复用例通过，但新增private-hint用例在open_direct_room返回UNAVAILABLE，尚未到提示检查。原因是原认证脚本未运行准入操作器或配置开房命令租约；网关日志有明确拒绝。已仅在 --private-hint 的独立临时库配置1小时/1000命令测试租约，仍走正常准入路径；测试临时目录提前创建，避免提前失败时清理不存在目录掩盖原错误。当前新验收70148运行中，目录 `/tmp/imv2-current-private-hint-acceptance-v2`，入口日志同名加`.log`，原失败模拟器及服务已由脚本清理。

## 单侧提示验收协议断言修正

真实验收70148退出1：临时命令租约已使开房成功，新增用例进一步到发送拒绝，但旧辅助断言仍期望FORBIDDEN；实际网关当前持久拒绝路径明确返回DIRECT_MESSAGE_RESTRICTED（V2GatewayDomainCommandHandler）。已将辅助方法更名为assertDirectMessageIsRestricted并严格断言当前码，保留retryable=false与不得接受消息检查，没有放宽为接受多个错误码。新验收22872运行中，目录 `/tmp/imv2-current-private-hint-acceptance-v3`，入口日志同名加`.log`。

当前文档链接检查20221退出0，日志 `/tmp/imv2-current-final-doc-links.log`。完整完成复核仍保留私聊偏好关闭与首次目标提交的强制并发验证要求：当前锁实现和版本/重放专项已有证据，但尚需用受控交错直接验证偏好写入确实等待首次投影提交；不能用顺序关闭再投递替代这一条。

## 真实单侧提示 UI 通过与汇总修正

验收22872退出1但不是用例失败：private-hint完整用例通过（21.679秒），两项既有认证/撤销恢复通过（32.815、31.738秒），合计3通过、1个既有未选可用环境用例跳过、0失败。新增测试已实际核对双方SQLite、重连、App聊天页及terminate后的scoped恢复。脚本旧汇总只允许gateway模式2项通过，漏算 --private-hint，因此在后台唤醒步骤之前退出；已严格增加int(args.private_hint)，未放宽失败计数或忽略跳过。新完整验收已启动，输出 `/tmp/imv2-current-private-hint-acceptance-v4`，日志同名加`.log`。

新增服务端受控交错测试 directReceiptPreferenceCommitFence（关闭读者/查看者两参数）已写入：目标接收凭据INSERT由真实advisory锁暂停；确认第二个真实偏好写入也被共享围栏阻塞后，释放目标事务，验证首次可见结果提交、偏好关闭成功、原事件重放序号不变、新事件隐藏。当前5498编译中，日志 `/tmp/imv2-receipt-commit-fence.log`，尚未通过。生产代码未修改，已通过的1022项全量仍对应当前生产实现。

## Concurrent privacy fence verification

Session 5498 exited 0: one test with reader/viewer closure parameters passed in 1.722 seconds (`/tmp/imv2-receipt-commit-fence.log`). A real target receipt INSERT is blocked before commit; the real preference setter must then wait on its shared control fence. Release preserves the first visible result and sequence, while a new candidate resolves hidden. Production source is unchanged from the passed 1022-test full run.

The single-side timeline and runtime measurement checklist items are now checked based on the passed v3 real UI/reconnect/cold-start test and the five current Release scenarios. The complete v4 script, including headless wake, remains running as session 89827.

Personal ACK-loss process probe 91389 exited 1 before killing the server: 40 source rows existed but only 15 target receipts had committed, so the deliberate fault precondition was not yet satisfied. Its owned resources were cleaned. The revised probe waits up to 90 seconds for all target receipts, then performs SIGKILL, fault removal, restart and immutable receipt/log/sequence comparison. Session 23985 is running; log `/tmp/imv2-personal-ack-restart-v2.log`. Do not count this as passed until its terminal evidence is available.

# V2 文档索引

这一页只回答一个问题：**哪个文件是当前合同？**

## 三条规则

1. **一份合同只有一个权威文档。** 同一主题有多份文件时，本页列出的是唯一权威版本，其余是它引用的补充合同或历史记录。
2. **合同只写"现在生效的规则"和"如何验证"。** 过程记录、逐批追加的验证日志一律不进合同，见 `archive/`。
3. **历史记录不参与判断当前状态。** `archive/` 下的文件保留原样，只为追溯决策来源；判断现状请看下面"当前状态"一行指向的三个文件。

## 先读哪一个

| 你想知道 | 看这里 |
| --- | --- |
| 如何逐项审核设计、实现与体验（执行计划，非通过证明） | [设计与实现质量审核蓝图](design-implementation-review-blueprint.md) |
| 如何判断测试是否有独立验证价值（首轮治理台账） | [测试有效性治理](test-governance-audit.md) |
| 账号密码变更、离线恢复码、断言版本与登录限流 | [账号认证生命周期](account-authentication-lifecycle.md) |
| 系统由哪些组件组成、消息怎么流动 | [当前系统架构](../current-system-map.md) |
| 现在有哪些能力、证据到什么等级 | [当前实现与发布证据](../../IMV2/docs/implementation-status.md) |
| 47 项问题的当前状态、未关闭项 | [当前问题状态表](status.md) |
| 为什么这样设计（设计决定与状态） | [ADR 登记册](../../IMV2/docs/ADR-REGISTER.md) |
| 还有哪些外部风险没有关闭 | [开放风险登记表](../../IMV2/docs/10-operations/residual-risk-register.md) |
| 某个结论是怎么验证出来的 | [验证运行记录索引](verification-records.md) |
| 房间日志改造的最终范围与完成清单 | [实施与验收记录](room-log-only-implementation.md) |
| 当前房间日志负载、重启和个人事件验收 | [当前版本运行验收](room-log-current-runtime-2026-09-13.md) |
| 独立分片裁剪与摘要数据分布复核 | [房间分片后续验证](room-log-shard-followup.md) |
| 客户端排序与房间恢复的目标设计 | [具体实施方案](client-owned-conversation-sync-plan.md) |
| 客户端房间恢复当前验收状态 | [验收矩阵](client-owned-conversation-sync-acceptance.md) |
| 客户端房间恢复事务与强杀覆盖 | [事务边界审计](client-owned-conversation-sync-transaction-audit.md) |
| 客户端房间恢复规模测量与边界 | [规模验收结果](client-owned-conversation-sync-scale-results.md) |
| 客户端房间恢复阶段证据（历史） | [阶段记录](client-owned-conversation-sync-evidence-2026-09-13.md) |
| 历史过程、被替换的旧结论 | [归档目录](archive/) |

## 当前合同

下表是全部当前生效的合同文档。`覆盖` 列是该文档对应的 47 项问题编号（P = B01–B29，D = D01–D08）；状态与关闭条件统一记录在 [当前问题状态表](status.md)，本文不重复维护。

### 基础与架构

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 组件边界、数据流、投递事实链 | [当前系统架构](../current-system-map.md) | — |
| 能力矩阵、schema 与协议政策、总门禁 | [当前实现与发布证据](../../IMV2/docs/implementation-status.md) | — |
| 设计决定与批准状态 | [ADR 登记册](../../IMV2/docs/ADR-REGISTER.md) | — |
| 外部发布缺口与关闭条件 | [开放风险登记表](../../IMV2/docs/10-operations/residual-risk-register.md) | E01–E10 |

### 认证、注册与设备生命周期

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 认证生命周期与 HTTP 认证处理 | [认证生命周期实施合同](2026-09-05-authentication-lifecycle-contract.md)、[账号生命周期内的 HTTP 认证处理](session-http-authorization.md) | B08、B09 |
| App、账号服务与 Gateway 的认证终止 | [认证终止验收](app-gateway-authentication-termination.md) | B09 |
| 本机真实账号 HTTPS 认证 | [真实账号 HTTPS 验收](live-account-https-authorization.md) | B09 |
| 密码输入与哈希 | [密码输入、Argon2id 与旧凭据边界](password-hash-contract.md) | B05 |
| 凭据签发、替换与结果交接 | [签发与替换边界](credential-issuance-boundaries-contract.md)、[已收到结果的持久交接](received-credential-recovery-contract.md)、[原子交付撤销凭据](atomic-revocation-credential-issue-contract.md) | B08 |
| 注册身份与重新登录 | [注册身份与重新登录](registration-lifecycle-contract.md) | B08 |
| 注册取消与签发仲裁 | [服务端仲裁](registration-cancellation-contract.md)、[HTTP 边界](registration-cancellation-http-contract.md)、[自动取消与冷启动归属](registration-cancellation-runner-contract.md)、[进程中断恢复](registration-process-interruption-contract.md)、[签发前证明与 HTTP 绑定](proof-bound-issuance-contract.md) | B08 |
| 设备撤销能力存储与兑换 | [存储与兑换合同](device-revocation-capability-storage-contract.md)、[HTTP 与 ClientKit 合同](device-revocation-capability-http-contract.md) | B08 |
| 退出时的撤销交接与执行 | [持久交接](device-revocation-handoff-contract.md)、[独立执行与本地退出](device-revocation-runner-contract.md)、[状态与显式恢复](device-revocation-status-contract.md) | B08 |
| 退出意图记录 | [可报错的退出意图记录](durable-sign-out-marker-contract.md) | B08 |
| 当前设备撤销 | [当前设备撤销：服务端合同](current-device-logout-contract.md) | B08 |
| 设备会话期限 | [设备会话绝对期限](device-session-absolute-expiry-contract.md) | B08 |

### 消息、变更与投递

[仅保留房间日志：实施与验收记录](room-log-only-implementation.md)（旧流水线移除及该范围验收已完成；后续客户端会话恢复的完整验收仍开放，见[验收矩阵](client-owned-conversation-sync-acceptance.md)）。

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 房间读模型：投递、未读与保留窗口（**已实施**：单聊与标准群默认都走读模型、未读、保留窗口与运维重放；列表为本地优先 + 服务端未读；进入房间按 §5.4 推进到已应用序号／房间头） | [房间读模型合同](room-read-model-contract.md) | B03、B04、D07 |
| 发送请求指纹与幂等 | [发送接受记录保留与清理](send-completion-retention.md)；[旧指纹实施历史](2026-09-05-send-message-fingerprint-contract.md)仅供追溯 | B11、D07 |
| 房间写入存储的职责拆分与事务边界 | [Room write Store decomposition](room-write-store-decomposition.md) | D07 |
| 静态房间归属与跨库持久发送授权 | [当前归属与发送授权合同](room-owner-migration-contract.md)；在线迁移章节仅供追溯 | B27、B04、B11、D07 |
| 房间逻辑寻址、激活、事务资格与回收 | [房间 Virtual Actor 合同](room-virtual-actor-contract.md) | B27 |
| 消息发送的 owner 栅栏 | [消息发送 owner 事务栅栏](send-message-owner-fence-contract.md) | B27 |
| 编辑、撤回、reaction 的接受事实与房间恢复 | [消息变更与房间日志](message-mutation-delivery-authority-contract.md) | B03、B06、D07 |
| 消息变更的历史可见性与扫描游标 | [读取与游标合同](message-mutation-read-contract.md)；[旧受众结算记录](message-mutation-audience-contract.md)仅供追溯 | B03 |
| 编辑的完整替换与版本缺口 | [可授权完整编辑与版本缺口](message-edit-replacement-contract.md) | B03、B06 |
| 编辑与权限变更的提交顺序 | [提交顺序合同](edit-policy-commit-ordering.md) | B02 |
| 消息终态与快照重放 | [终态、版本缺口与快照重放](message-terminal-projection-contract.md) | B06 |
| 回复、置顶与共享内容授权 | [引用可见性合同](message-reference-visibility-contract.md) | B03、B04 |
| 旧媒体入口授权 | [旧媒体授权与兑换边界](legacy-media-authorization-contract.md) | B03、B04 |
| 消息变更的 owner 栅栏 | [消息编辑、撤回与 reaction 的 owner 栅栏](message-mutation-owner-fence-contract.md) | B27 |
| 转发终态载荷清理 | [终态载荷保留与清理](forward-terminal-payload-retention.md) | B04、B27 |
| 转发源授权 | [转发源授权合同与当前实现边界](forward-source-authorization.md) | B04 |
| 转发导入与前台转发栅栏 | [后台转发导入](forward-import-owner-fence-contract.md)、[前台同库转发](foreground-forward-owner-fence-contract.md) | B04、B27 |
| 转发暂停任务恢复 | [转发暂停任务的审计恢复](forward-operator-replay.md) | B04 |
| 后台有界同步 | [有界同步、取消及系统回调](bounded-incremental-sync-contract.md) | D03 |
| 共享启动与 Push 恢复 | [共享 App 启动与 Push 恢复](shared-app-restoration-contract.md)、[无根页面 Push 入口](headless-push-entry-contract.md) | D02、D03 |
| 个人快照重建 | [个人快照重建合同](personal-snapshot-rebuild.md) | B06 |
| 持久重试与网络时序 | [跨批次公平性与网络重试](durable-retry-network-contract.md) | B07 |
| 连接代次隔离 | [旧连接回调与新连接隔离](network-generation-fencing.md) | D01 |
| 本地历史消息定位 | [有界历史消息定位](timeline-location-contract.md) | B18 |
| 房间实时订阅 | [房间订阅实施合同](2026-09-05-room-subscription-contract.md) | B17 |
| 本地账号存储生命周期 | [账号存储生命周期合同](2026-09-05-account-storage-lifecycle-contract.md) | B15 |

### 群组：权限、效果与快照

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 群管理效果与恢复约束 | [源版本与后续恢复约束](group-control-effect-contract.md) | B06 |
| 当前角色权限基线 | [角色权限基线合同](group-policy-baseline-contract.md) | B06 |
| 权限与幂等回执保留 | [群权限与幂等回执保留](group-policy-retention.md) | B06 |
| 公告与权限快照顺序 | [快照版本顺序](group-policy-snapshot-order.md) | B06 |
| 公告效果 | [客户端公告效果合同](announcement-effect-contract.md) | B06 |
| 置顶快照与效果 | [置顶快照顺序与取消状态](pin-snapshot-contract.md)、[客户端置顶效果与迁移](pin-effect-contract.md) | B06 |
| 成员角色快照 | [成员角色快照版本](member-role-snapshot-contract.md) | B06 |
| 权限恢复的持久存储与执行 | [客户端持久恢复存储](role-policy-recovery-store-contract.md)、[自动恢复执行器](role-policy-recovery-runner-contract.md)、[状态与显式重试](role-policy-recovery-ui-contract.md) | B06 |
| 客户端角色权限效果 | [角色权限效果合同](role-policy-effect-contract.md) | B06 |

### 群邀请与审批

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 跨 owner 全局申请名额与恢复边界 | [全局配额合同](group-join-global-quota-contract.md) | B23 |
| 申请人取消、审批竞态与重新申请 | [申请取消合同](group-join-cancellation-contract.md) | D06 |
| 邀请 token 目录与创建意图 | [token 目录与创建意图合同](group-invite-directory-contract.md) | B27 |
| 邀请创建后台恢复 | [创建恢复合同](group-invite-creation-recovery-contract.md) | B27 |
| 邀请 owner 路由与 control 身份 | [owner 路由合同](group-invitation-owner-routing-contract.md) | B27 |
| 历史邀请目录导入（已取消，历史设计） | [分页导入合同](group-invite-directory-import-contract.md) | B27 历史范围 |
| 历史邀请创建的目录绑定 | [兼容补充合同](group-invite-legacy-binding-contract.md) | B27 |
| 群申请原子审批 | [原子审批合同](atomic-group-approval-contract.md) | B26 |
| 遗留审批恢复 | [受控恢复](group-approval-recovery-contract.md)、[证据保留](approval-recovery-evidence-contract.md) | D05、B26 |
| 申请人配额 | [历史单库事务修复](invitation-applicant-quota-contract.md) | B23 |

### Owner 与分片栅栏

同一类栅栏按写入路径分别成文，改动任一路径时必须同时更新对应合同。

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 普通成员变更 | [成员变更 owner 栅栏](room-membership-owner-fence-contract.md) | B27 |
| 消息发送 | [发送 owner 栅栏](send-message-owner-fence-contract.md) | B27 |
| 消息编辑/撤回/reaction | [消息变更 owner 栅栏](message-mutation-owner-fence-contract.md) | B27 |
| 公告、置顶、角色权限、成员角色 | [群管理 owner 栅栏](group-capability-owner-fence-contract.md) | B27 |
| Moderation | [Moderation owner 栅栏](moderation-owner-fence-contract.md) | B27 |
| 已读回执与读者列表 | [已读回执 owner 栅栏](read-receipt-owner-fence-contract.md) | B27 |
| 转发导入 | [转发导入 owner 栅栏](forward-import-owner-fence-contract.md)、[前台转发 owner 栅栏](foreground-forward-owner-fence-contract.md) | B04、B27 |

### Push 与移动生命周期

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| Push 最终意图与版本 | [最终意图合同](push-intent-contract.md) | B16 |
| Push HTTP 与客户端传输 | [版本化 HTTP 与 ClientKit 传输](push-intent-http-contract.md) | B16 |
| 客户端持久 Push 意图 | [持久 Push 意图](push-intent-local-contract.md) | B16 |
| Push 自动执行器 | [自动执行器合同](push-intent-reconciler-contract.md) | B16 |
| App Push 接线 | [App 接线合同](push-intent-app-contract.md) | B16 |
| Push 认证代次与退出清理 | [认证隔离合同](push-intent-auth-contract.md) | B16 |

### 整数与时间边界

| 主题 | 当前合同 | 覆盖 |
| --- | --- | --- |
| 消息投影与整数入口审计 | [消息投影整数边界](message-projection-integer-boundaries.md) | B01 |
| 服务端时间戳转换 | [时间戳整数边界](timestamp-integer-boundaries.md) | B01 |
| 客户端时间戳与禁言投影 | [客户端时间戳与禁言投影边界](client-timestamp-integer-boundaries.md) | B01 |
| 资料版本与个人投影 | [资料版本与个人投影整数边界](profile-and-projection-integer-boundaries.md) | B01 |
| 账号限流计数与日期 | [账号限流策略、计数与日期绑定边界](account-rate-limit-integer-boundaries.md) | B01 |
| 账号证明与 Gateway 时钟 | [服务端账号证明与 Gateway 时钟整数边界](server-clock-integer-boundaries.md) | B01 |

## 维护规则

- 新增或修订合同：直接改对应合同文档，**不要**在状态文档或实现状态文档里追加"最新补充"段落。
- 过程记录、一次性实验、被替换的结论：写入 `archive/`，并在文首标注归档日期和替代它的合同。
- 状态变化：只更新 [当前问题状态表](status.md) 的状态列；能力与证据等级变化更新 [当前实现与发布证据](../../IMV2/docs/implementation-status.md)。
- 提交前运行 `bash scripts/check_v2_document_links.sh`，链接必须为零断链。

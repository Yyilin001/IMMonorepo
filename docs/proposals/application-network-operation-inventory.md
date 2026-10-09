# 应用网络操作登记（源码盘点）

本清单按 2026-09-28 当前生产源码登记入口与领域恢复合同；登记存在不代表整包回归或真实平台验收通过。Core 的 `V2OperationKind` 是测试可遍历的持久业务登记；认证、瞬时信号、读取和资源控制独立注册，不能塞进普通 durable command。

protocol44 进一步移除旧 TCP send/edit/withdraw/reaction/forward 请求及无消费者转发响应，当前消息写入经 typed HTTP 与公共 work 恢复；消息事实响应保留。Hello 必须绑定合法 UUID 设备。此批删除、生成与调用侧已落盘并完成生产编译；合并回归及后续修复的当前证据见[实施进度](application-weak-network-progress.md)，不由本清单推定通过。

## 公共语义

- 身份保留强类型领域 ID；scope/account 在构造与解码时校验。pair 为有向 owner/target，反转不属于同一调用者。标识仅允许 unreserved ASCII，禁止 `/`，所以 storageKey 分隔无歧义。
- 指纹按显式字段名排序，长度前缀、类型标签、大端整数与原始 UTF-8 编码。每个领域适配器必须穷尽业务字段及 expectedRevision；不得加入 token、attempt、请求时间等传输元数据。字段编码器本身不保证领域字段完整。
- 原回执必须由适配器核验 identity/fingerprint/outcome/revision。generic receipt 是强类型载荷容器，不是可信权威的自动提升。unresolved、HTTP 404/403 和传输错误都不提供未执行证明。
- 首次提交窗口只约束 neverSubmitted；submissionStarted 的到期动作一律 recoverOriginalIdentity。查询/关闭预算必须保留。每个 recovery round 的命令自动尝试首版硬上限 5、payload 1 MiB；领域现有更严格上限优先，此值不是容量测量。lifetime 尝试累计单独保留；只有用户明确开启新 round 才重置 round 计数。

## 生产 protobuf / App 调度

当前生产装配逐项对照：Core 登记 32 个 kind，`V2AppStore` 注册 30 个公共 dispatcher handler；另外 `mediaUpload`、`groupAvatar` 由 `V2ResourceTransferEngine` 与 `V2GroupAvatarIntentEngine` 专属持久引擎负责，Runtime 实际构造并随账号启动/排空。此为源码映射，不是32项均已通过验收的声明。

偏好/收藏、资料、名字、已读、发送/编辑/撤回、reaction、转发与禁言/移除成员已接账户公共 operation work dispatcher。App 已不再装配旧命令 lane；social、groupCreation 也已切公共 work。成员关系、群能力、禁言/移除旧 lane、TLS API 与待发表已删除；新链路已接生产调度，成员关系/群能力 App 生产编译通过，阶段统一回归待执行。生产装配存在不等于全部故障条件已验证。

私聊创建、消息审核删除、邀请/申请/审批已接新 HTTP 原身份恢复与公共 dispatcher。审核使用 `V2MessageModerationOperationService`，原 SDK redaction outbox、TLS 51/52 写与 SQLite 旧待发表已删除；`message.redacted` 同步事实保留。邀请使用独立 Keychain secret 引用，永久回执不含 bearer；三个 kind 已在 AppStore 注册。当前确认源码接线；已知Server组件失败已有后续分批复验证据，通知及HTTP错误分类的新修改尚待统一回归；具体证据以实施进度为准，不能声明整包通过。

| kind | 原业务身份 | 首次窗口 / 合并 | 权威、顺序、投影 |
| --- | --- | --- | --- |
| `sendMessage` | `ClientMessageID` | 24小时 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `withdrawMessage` | `MessageWithdrawalOperationID` | 10分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `editMessage` | `MessageEditOperationID` | 10分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `reaction` | `MessageReactionOperationID` | 24小时 / 未冻结目标 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `readReceipt` | `ReadReceiptOperationID` | 不设期限 / max watermark | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `directRoom` | `DirectRoomOperationID` | 10分钟 / 不合并 | 账户固定 placement / 房间 owner；user-pair 顺序；原 opened proof 仅证明会话身份，不授予当前访问权 |
| `groupRoom` | `GroupRoomOperationID` | 10分钟 / 不合并 | 控制面冻结 audience manifest 与固定 placement；owner 原子创建及永久 proof；finalizing 逐页恢复，不关闭已开始创建 |
| `membership` | `MembershipOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `moderation` | `ModerationOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `memberMute` | `ModerationOperationID` | 原点击确认最多120秒 / 不合并 | 新强类型 admission；RoomRef；成员revision及加入代次；提交/原回执/关闭共锁，已接公共handler和App入口；整体验收另记 |
| `moderatedMemberRemoval` | `ModerationOperationID` | 原点击确认最多120秒 / 不合并 | 与禁言共用成员管理合同；当前权限失败不能证明原操作未执行 |
| `strangerMessagePreference` | `StrangerMessagePreferenceOperationID` | 2分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `userAddPreference` | `UserAddPreferenceOperationID` | 2分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `readReceiptPreference` | `ReadReceiptPreferenceOperationID` | 2分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `liveActivityPreference` | `LiveActivityPreferenceOperationID` | 2分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `relationship` | `RelationshipOperationID` | 10分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `userBlock` | `UserBlockOperationID` | 2分钟 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `conversationPreference` | `ConversationPreferenceOperationID` | 7天 / 未冻结目标 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `messageFavorite` | `MessageFavoriteOperationID` | 7天 / 未冻结目标 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `pinnedMessage` | `PinnedMessageOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupAnnouncement` | `GroupAnnouncementOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupPermission` | `GroupPermissionOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupRole` | `GroupRoleOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `forwardMessage` | `MessageForwardOperationID` | 24小时 / 不合并 | 账户父计划 / source、target RoomRef owner；稳定逐子身份、原 export/inbox proof；取消只关闭未开始子项 |
| `profileUpdate` | `ProfileUpdateOperationID` | 24小时 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `contactAlias` | `ContactAliasOperationID` | 24小时 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `groupNickname` | `GroupNicknameOperationID` | 24小时 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupInvite` | `GroupInviteOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupJoinRequest` | `GroupJoinRequestOperationID` | 10分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `groupJoinDecision` | `GroupJoinDecisionOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |
| `mediaUpload` | `MediaUploadOperationID` | 24小时 / 不合并 | 账户/个人或专用资源 owner；user/field key；个人 sync/领域 confirmed snapshot |
| `groupAvatar` | `GroupAvatarOperationID` | 2分钟 / 不合并 | RoomRef/房间 owner；room/entity key；room event/sync 投影 |

群创建、多段转发、邀请/审批、资源 Ready 的阶段状态继续属于原领域。Core 登记并不替换消息/群头像已有关闭 proof。普通消息、reaction、偏好/收藏、资料/名字、私聊、社交/账号偏好、成员/群管理、审核与邀请已各自落地原回执 query/close；forward 与 group creation 使用父子/阶段恢复和未开始关闭。readReceipt 使用原回执或合法单调水位证明，不提供普通 close。资源和群头像沿专属 status/Ready/取消 proof；不能将这些不同合同统称为普通命令恢复。

## HTTP 源码注册盘点

以下按当前 `V2Vapor*Routes.swift` 的直接 `routes` 注册重新提取。表中行号用于定位，不是运行时可达性证明；辅助方法或其他 receiver 的动态注册仍须结合 endpoint registry 与 composition root 核对。认证/设备 capability 不进入普通重放队列，邀请 preview POST 是读取。旧邀请五个写入口已从当前源码表移除，新操作路由列入。

| 注册文件 | 源码行 | HTTP 注册 |
| --- | --- | --- |
| `V2VaporAccountDisableOperatorRoutes.swift` | 51 | `routes.post("internal", "v2", "accounts", "disable")` |
| `V2VaporAccountPreferenceOperationRoutes.swift` | 13 | `routes.get("v2","account-preferences",":kind","baseline")` |
| `V2VaporAccountPreferenceOperationRoutes.swift` | 20 | `routes.on(.post,"v2","account-preferences","operations","submit",maxBodySize:"4kb")` |
| `V2VaporAccountPreferenceOperationRoutes.swift` | 26 | `routes.on(.post,"v2","account-preferences","operations","recover",maxBodySize:"4kb")` |
| `V2VaporDeviceCredentialRoutes.swift` | 189 | `routes.on(.post, "v2", "device-credentials", maxBodySize: "16kb")` |
| `V2VaporDeviceCredentialRoutes.swift` | 247 | `routes.post("v2", "device-credentials", "refresh")` |
| `V2VaporDeviceRegistrationCancellationRoutes.swift` | 50 | `routes.on(.post, "v2", "device-credentials", "cancel-registration", maxBodySize: "1kb")` |
| `V2VaporDeviceRevocationCapabilityRoutes.swift` | 56 | `routes.on(.post, "v2", "device-credentials", "revoke", maxBodySize: "1kb")` |
| `V2VaporDeviceSessionRoutes.swift` | 66 | `routes.get("v2", "devices")` |
| `V2VaporDeviceSessionRoutes.swift` | 95 | `routes.get("v2","devices","revocation-baseline")` |
| `V2VaporDeviceSessionRoutes.swift` | 101 | `routes.on(.post,"v2","devices","remote-revocations","submit",maxBodySize:"32kb")` |
| `V2VaporDeviceSessionRoutes.swift` | 108 | `routes.on(.post,"v2","devices","remote-revocations","operations","recover",maxBodySize:"32kb")` |
| `V2VaporDeviceSessionRoutes.swift` | 116 | `routes.post("v2", "devices", "revoke-current")` |
| `V2VaporDeviceSnapshotResetOperatorRoutes.swift` | 57 | `routes.post("internal", "v2", "device-snapshots", "reset")` |
| `V2VaporDirectRoomOperationRoutes.swift` | 13 | `routes.on(.post,"v2","direct-room-operations","submit",maxBodySize:"4kb")` |
| `V2VaporDirectRoomOperationRoutes.swift` | 19 | `routes.on(.post,"v2","direct-room-operations","operations","recover",maxBodySize:"4kb")` |
| `V2VaporDurableWorkOperatorReplayRoutes.swift` | 129 | `routes.post("internal", "v2", "durable-work", "replay-event")` |
| `V2VaporDurableWorkOperatorReplayRoutes.swift` | 153 | `routes.post("internal", "v2", "durable-work", "replay")` |
| `V2VaporForwardPlanRoutes.swift` | 12 | `routes.on(.post,"v2","forward-plans","submit",maxBodySize:"64kb")` |
| `V2VaporForwardPlanRoutes.swift` | 18 | `routes.on(.post,"v2","forward-plans","operations","recover",maxBodySize:"64kb")` |
| `V2VaporForwardWorkOperatorReplayRoutes.swift` | 44 | `routes.post("internal", "v2", "forward-work", "replay")` |
| `V2VaporGroupAvatarCommandRoutes.swift` | 14 | `routes.on(.post, "v2", "rooms", ":roomID", "avatar", maxBodySize: "8kb")` |
| `V2VaporGroupAvatarPresentationRoutes.swift` | 14 | `routes.get("v2", "rooms", ":roomID", "avatar")` |
| `V2VaporGroupAvatarRecoveryRoutes.swift` | 14 | `routes.on(.post, "v2", "rooms", ":roomID", "avatar", "recovery", maxBodySize: "8kb")` |
| `V2VaporGroupCapabilityRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","group-capability-operations","admissions",maxBodySize:"32kb")` |
| `V2VaporGroupCapabilityRoutes.swift` | 19 | `routes.on(.post,"v2","rooms",":roomID","group-capability-operations","submit",maxBodySize:"32kb")` |
| `V2VaporGroupCapabilityRoutes.swift` | 25 | `routes.on(.post,"v2","rooms",":roomID","group-capability-operations","operations","recover",maxBodySize:"32kb")` |
| `V2VaporGroupCapabilityRoutes.swift` | 31 | `routes.get("v2","rooms",":roomID","messages",":messageID","pin-baseline")` |
| `V2VaporGroupCreationOperationRoutes.swift` | 12 | `routes.on(.post,"v2","group-creation-operations","begin",maxBodySize:"4kb")` |
| `V2VaporGroupCreationOperationRoutes.swift` | 17 | `routes.on(.post,"v2","group-creation-operations","append",maxBodySize:"32kb")` |
| `V2VaporGroupCreationOperationRoutes.swift` | 22 | `routes.on(.post,"v2","group-creation-operations","finalize",maxBodySize:"4kb")` |
| `V2VaporGroupCreationOperationRoutes.swift` | 27 | `routes.on(.post,"v2","group-creation-operations","operations","recover",maxBodySize:"4kb")` |
| `V2VaporGroupInvitationOperationRoutes.swift` | 12 | `routes.get("v2","rooms",":roomID","invitation-operations","baseline")` |
| `V2VaporGroupInvitationOperationRoutes.swift` | 19 | `routes.on(.post,"v2","rooms",":roomID","invitation-operations","admissions",maxBodySize:"8kb")` |
| `V2VaporGroupInvitationOperationRoutes.swift` | 26 | `routes.on(.post,"v2","rooms",":roomID","invitation-operations","submit",maxBodySize:"8kb")` |
| `V2VaporGroupInvitationOperationRoutes.swift` | 32 | `routes.on(.post,"v2","rooms",":roomID","invitation-operations","operations","recover",maxBodySize:"8kb")` |
| `V2VaporGroupInvitationRoutes.swift` | 39 | `routes.get("v2", "group-invites")` |
| `V2VaporGroupInvitationRoutes.swift` | 47 | `routes.post("v2", "group-invites", "preview")` |
| `V2VaporGroupInvitationRoutes.swift` | 57 | `routes.get("v2", "group-join-requests")` |
| `V2VaporLocalFilesystemMediaRoutes.swift` | 40 | `routes.on( .put, "v2", "local-media", "upload", ":mediaID", maxBodySize: ByteCount(value: maximumUploadBytes) )` |
| `V2VaporLocalFilesystemMediaRoutes.swift` | 106 | `routes.get("v2", "local-media", "download", ":mediaID")` |
| `V2VaporMediaEdgeRoutes.swift` | 28 | `routes.get("v2", "media", ":mediaID")` |
| `V2VaporMemberAdministrationRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","member-administration","admissions",maxBodySize:"4kb")` |
| `V2VaporMemberAdministrationRoutes.swift` | 20 | `routes.on(.post,"v2","rooms",":roomID","member-administration","submit",maxBodySize:"4kb")` |
| `V2VaporMemberAdministrationRoutes.swift` | 27 | `routes.on(.post,"v2","rooms",":roomID","member-administration","operations","recover",maxBodySize:"4kb")` |
| `V2VaporMembershipOperationRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","membership","admissions",maxBodySize:"4kb")` |
| `V2VaporMembershipOperationRoutes.swift` | 20 | `routes.on(.post,"v2","rooms",":roomID","membership","submit",maxBodySize:"4kb")` |
| `V2VaporMembershipOperationRoutes.swift` | 27 | `routes.on(.post,"v2","rooms",":roomID","membership","operations","recover",maxBodySize:"4kb")` |
| `V2VaporMessageModerationRoutes.swift` | 13 | `routes.get("v2","rooms",":roomID","messages",":messageID","moderation-baseline")` |
| `V2VaporMessageModerationRoutes.swift` | 21 | `routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","admissions",maxBodySize:"4kb")` |
| `V2VaporMessageModerationRoutes.swift` | 29 | `routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","submit",maxBodySize:"4kb")` |
| `V2VaporMessageModerationRoutes.swift` | 36 | `routes.on(.post,"v2","rooms",":roomID","message-moderation-operations","operations","recover",maxBodySize:"4kb")` |
| `V2VaporMessageMutationOperationRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","message-mutations","edit",maxBodySize:"1mb")` |
| `V2VaporMessageMutationOperationRoutes.swift` | 18 | `routes.on(.post,"v2","rooms",":roomID","message-mutations","withdraw",maxBodySize:"4kb")` |
| `V2VaporMessageMutationOperationRoutes.swift` | 24 | `routes.on(.post,"v2","rooms",":roomID","message-mutations","operations","recover",maxBodySize:"4kb")` |
| `V2VaporMessageReactionOperationRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","message-reactions","change",maxBodySize:"4kb")` |
| `V2VaporMessageReactionOperationRoutes.swift` | 18 | `routes.on(.post,"v2","rooms",":roomID","message-reactions","operations","recover",maxBodySize:"4kb")` |
| `V2VaporMessageReactionOperationRoutes.swift` | 24 | `routes.on(.get,"v2","rooms",":roomID","message-reactions",":message")` |
| `V2VaporMessageSendOperationRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","message-operations","send",maxBodySize:"1mb")` |
| `V2VaporMessageSendOperationRoutes.swift` | 18 | `routes.on(.post,"v2","rooms",":roomID","message-operations","recover",maxBodySize:"4kb")` |
| `V2VaporPersonalPreferenceRecoveryRoutes.swift` | 15 | `routes.on(.post, "v2", "rooms", ":roomID", "personal-preferences", "operations", "recover", maxBodySize: "4kb")` |
| `V2VaporProfilePresentationBatchRoutes.swift` | 14 | `routes.post("v2", "profile-presentations", "batch")` |
| `V2VaporProfilePresentationRoutes.swift` | 37 | `routes.get("v2", "profile-presentations", "contact-aliases")` |
| `V2VaporProfilePresentationRoutes.swift` | 47 | `routes.get("v2","profile-presentations","contact-aliases",":target")` |
| `V2VaporProfilePresentationRoutes.swift` | 51 | `routes.on(.put,"v2","profile-presentations","contact-aliases",":target",maxBodySize:"4kb")` |
| `V2VaporProfilePresentationRoutes.swift` | 57 | `routes.on(.post,"v2","profile-presentations","contact-aliases",":target","operations","recover",maxBodySize:"4kb")` |
| `V2VaporProfilePresentationRoutes.swift` | 63 | `routes.get("v2", "profile-presentations", "groups", ":room", "nicknames")` |
| `V2VaporProfilePresentationRoutes.swift` | 86 | `routes.get("v2","profile-presentations","groups",":room","nickname")` |
| `V2VaporProfilePresentationRoutes.swift` | 90 | `routes.on(.put,"v2","profile-presentations","groups",":room","nickname",maxBodySize:"4kb")` |
| `V2VaporProfilePresentationRoutes.swift` | 96 | `routes.on(.post,"v2","profile-presentations","groups",":room","nickname","operations","recover",maxBodySize:"4kb")` |
| `V2VaporProfileUpdateRoutes.swift` | 15 | `routes.get("v2", "profile", "me")` |
| `V2VaporProfileUpdateRoutes.swift` | 19 | `routes.on(.put, "v2", "profile", "me", maxBodySize: "8kb")` |
| `V2VaporProfileUpdateRoutes.swift` | 33 | `routes.on(.post, "v2", "profile", "me", "operations", "recover", maxBodySize: "2kb")` |
| `V2VaporPushEndpointRoutes.swift` | 54 | `routes.put("v2", "push-endpoint")` |
| `V2VaporPushEndpointRoutes.swift` | 70 | `routes.delete("v2", "push-endpoint")` |
| `V2VaporPushIntentRoutes.swift` | 63 | `routes.get("v2", "push-endpoint", "session")` |
| `V2VaporPushIntentRoutes.swift` | 70 | `routes.post("v2", "push-endpoint", "session")` |
| `V2VaporPushIntentRoutes.swift` | 79 | `routes.put("v2", "push-endpoint", "intent")` |
| `V2VaporReadReceiptRecoveryRoutes.swift` | 12 | `routes.on(.post,"v2","rooms",":roomID","read-receipts","operations","recover",maxBodySize:"4kb")` |
| `V2VaporResourceByteRoutes.swift` | 10 | `routes.get("v2", "resource-bytes", ":placementID")` |
| `V2VaporResourceImportRoutes.swift` | 12 | `routes.post("v2","resource-imports")` |
| `V2VaporResourceImportRoutes.swift` | 17 | `routes.post("v2","resource-imports","status")` |
| `V2VaporResourceImportRoutes.swift` | 22 | `routes.post("v2","resource-imports","cancel")` |
| `V2VaporResourceRoutes.swift` | 14 | `routes.get("v2", "resource-capabilities")` |
| `V2VaporResourceRoutes.swift` | 20 | `routes.post("v2", "resource-uploads")` |
| `V2VaporResourceRoutes.swift` | 25 | `routes.post("v2", "resource-uploads", "status")` |
| `V2VaporResourceRoutes.swift` | 30 | `routes.post("v2", "resource-uploads", "targets")` |
| `V2VaporResourceRoutes.swift` | 35 | `routes.post("v2", "resource-uploads", "finalize")` |
| `V2VaporResourceRoutes.swift` | 40 | `routes.post("v2", "resource-uploads", "cancel")` |
| `V2VaporSocialOperationRoutes.swift` | 13 | `routes.get("v2","social","targets",":targetUserID","baseline")` |
| `V2VaporSocialOperationRoutes.swift` | 20 | `routes.on(.post,"v2","social","operations","submit",maxBodySize:"4kb")` |
| `V2VaporSocialOperationRoutes.swift` | 26 | `routes.on(.post,"v2","social","operations","recover",maxBodySize:"4kb")` |

## 逐领域恢复与授权边界

| 入口组 | 离线/敏感性 | recovery / 终态依据 | 本地模型、失效、验证 |
| --- | --- | --- | --- |
| 消息、变更、读回执 | 允许持久意图；成员授权提交时核验 | send/edit/withdraw 原回执与关闭竞争已接 RoomRef；read 原回执优先，当前 watermark 证明另验授权 | room sync；message/room invalidation；现有 acceptance/recovery suites |
| 会话、收藏 | confirmed 投影与 pending 分开 | 原字段 revision；普通错误非 terminal | personal sync；entity/field invalidation；capabilities suites |
| social、隐私 | 收紧本地立即停止发布，放宽在线确认 | 原关系状态/配置 revision；权限错误需权威明确拒绝 | personal sync；user-pair invalidation；social suites |
| 群创建、权限、成员、公告 | 管理资格在线；保留多阶段 payload | 原 room owner/fence 回执；processing 非成功 | room event/sync；membership invalidation；group suites |
| 资料、备注、昵称、头像 | 草稿不是 confirmed 展示资格；上传 Ready 依赖 | profile/alias/nickname 原回执 query/close；group avatar 专属 proof | revision 不回退；presentation lease 失效；profile/avatar suites |
| invite/join/decision | token/成员目录不能作为离线授权 | 原阶段与决定回执；unavailable 非取消成功 | invitation 状态；room membership；invitation suites |
| Push | 专用 intentRevision/session/claim | 原专用 capability/intention，禁止跨账户 token | endpoint intent；push suites |
| 登录、设备、安全 | proof 不入普通持久 payload | 现有签发/撤销 journal 与 capability；passkey 未上线 | Keychain/epoch 栅栏；auth suites |
| 资源上传/import/download | provider 模式与 lease 约束；字节有界 | session status/finalize/Ready；业务 committed 独立 | resource journal/part/range；resource suites |
| 只读发现、目录、展示、sync | persistent projection / business snapshot / lease / online 分开 | 读取不产生操作未执行证明 | cursor+projection 原子；query generation；sync/presentation suites |

本人资料恢复生产装配位于 `IMV2AccountServerApp` 的已认证 routes group，沿用跨副本共享 PostgreSQL 限流 owner，使用独立 `profile-recovery` scope、cost 3，身份键为 user/device/scope 的 HMAC；额度跨进程保留。recover 请求硬限 2 KiB。当前没有新增永久墓碑的 lifetime 总量 quota，速率保护与终态不丢失分别处理。

## 已有门禁与本次验证范围

`ApplicationOperationTests` 检查全部 kind 有策略、指纹排列稳定/语义敏感、非法 identity/decode、未知结果期限不转拒绝。生产登记已对应领域 executor 与路由；字段上限、事务故障、平台生命周期等验收以实际回归结果为准，不用 inventory 的存在替代验收。

## W3 已实现的会话偏好与消息收藏

`V2ConversationStateCommand` 与 `V2MessageFavoriteCommand` 已要求 `expectedRevision`、`firstSubmissionDeadlineMilliseconds`，冻结后的 fingerprint 绑定账号、原操作 ID、房间/消息、目标状态、revision 和期限。无先前状态的 revision 为 0，成功变更从 1 开始。相同操作的重放返回 `V2PersonalPreferenceReceipt` 原始终态；业务拒绝、关闭与已提交回执永久保留，当前同步投影不替代原回执。

TLS 两命令自协议 33 引入独立 `PersonalPreferenceReceipt`（envelope field/frame command 124）；`ConversationStateSet` / `MessageFavoriteChanged` 作为同步投影保留 revision。查询与关闭使用 `POST /v2/rooms/{roomID}/personal-preferences/operations/recover`，body 为 `V2PersonalPreferenceRecoveryRequest` 的 Core Codable 编码；认证账号、path room 与 identity scope 必须一致。查询未受理返回 unresolved，关闭未受理写 closed，fingerprint 不匹配明确返回 conflict。端点限制 4 KiB、no-store，并使用生产持久限流独立 scope `personal-preference-recovery`、cost 3。

这两类写入通过既有 RoomRef administration 到房间 owner，事务先锁定操作身份，再校验 activation fence、当前成员/实体、首次期限和 revision。状态与回执及 room-bound `user_state_event_outbox` 同事务提交，现有 owner outbox worker 投递用户分片。该纵向在 `im-v2-current-55` 引入不可变 `personal_preference_operation_receipts`，删除两旧操作台账；收藏取消保留 false 状态及 revision。用户快照投影按 revision 抑制乱序旧值，并保留清空状态的版本，防止重建后把旧意图当成首次变更。

该段仅描述这两个领域；其他已接领域使用各自授权、版本和阶段合同，不能接入绕过 RoomRef 的全局写服务。


### W3 备注与本人群昵称已实现范围

两领域使用强类型 command/receipt/recovery/snapshot；首次意图携带 expectedRevision 与提交期限，永久 immutable receipt 分开于单目标编辑 baseline。所有新 committed 操作递增 revision（含清空/值不变），重放不增加；query/close 与提交共享稳定操作锁，closed/rejected 永久保留。群昵称经 RoomRef activation 围栏，备注通过账号关系权限；GET baseline 不提供资料展示 lease。canonical current56 删除旧 alias/nickname ledger 和对应 housekeeping。备注另有仅 target_user_id+revision 的 durable user-state invalidation，群昵称沿用 room nickname event。合同详见[既有名字展示与恢复主题](resource-system-implementation.md#联系人备注与本人群昵称编辑恢复)。


### W3 已读单调恢复已实现范围

`readReceipt` 保留原稳定 ID，新增 [强类型单调恢复合同](../../IMV2Core/Sources/IMV2Core/ReadReceiptRecovery.swift) 与 RoomRef owner HTTP query。原操作 receipt 与合法当前 max 满足证明分开；当前授权不可用只暂停核对，不能当作原 ID 永久拒绝。单次及群批重放都会重验当前成员与权威 head，不引入普通首次窗口或 close。详情见[单调恢复边界](application-weak-network-design.md)。


### 普通消息发送、编辑与撤回（current57 / protocol35）

普通生产写入口采用 `V2MessageSendOperationCommand`、`V2MessageEditOperationCommand`、`V2MessageWithdrawalOperationCommand`。发送保留 domain v3，公共 v1 包装稳定身份与首次截止；编辑／撤回绑定目标消息和 expected revision。发送首次窗口最多二十四小时，编辑／撤回十分钟；重放原结果不受首次截止影响。永久最小回执与原正文投影分开，提交／query／close 经 RoomRef 共操作锁与 activation fence；不支持旧 DTO fallback。具体领域边界见 [发送合同](../reviews/message-send-contract.md) 与 [变更合同](../reviews/message-mutation-owner-fence-contract.md)。reaction、forward parent 和其他普通命令的当前接线另列下文。

Reaction 已在 current58/protocol36 增补 typed own-key baseline、expectedReactionRevision、24 小时首次截止及永久原回执 query/close。每个新成功操作推进 key revision，包括目标已满足时；未知结果不能用当前聚合集合代替原证明。生产写经 RoomRef HTTP 端点，旧无截止 TLS 写入口已删除，保留同步事实。


Forward 父计划在 current59/protocol37 接入账户 HTTP submit/recover 与持久逐子 worker。冻结范围为100×10、每子20来源；公共最小回执≤64KiB、领域完整progress≤1MiB。账户元数据与源/目标RoomRef权威分开；已交接子项由原export/inbox回执核对，取消使用源pair共锁的关闭证明。社交、成员、群管理的当前合同另列；此处不声明真实部署联调通过。

### 独立写入口的当前源码状态

- 私聊：DB-first 原身份、公共 work、owner/control processing、永久回执查询/关闭、持久 pending UI 已接入。TLS 43/44 已退役；两个生产 CLI 改走账户 HTTP。opened 回执不授予当前房间访问权。
- 审核删除：120 秒原确认、message/membership revision、admission、RoomRef 原回执与关闭、ClientKit 持久 service 已接；App已接会话消息管理移除菜单、限时确认、持久状态观察及原身份继续核对，读取可配置moderateMessages权限；该新增入口尚未构建或行为回归。旧用户写通道退役，可信安全内部能力与同步事实保留。
- 邀请/申请/审核：新 admission/submit/recover/baseline 路由已接，App 三个 kind 注册公共调度；metadata control 与目录/配额恢复使用冻结原命令。secret 由 Keychain 保存，终态释放与锁屏后解锁清理独立于页面生命周期。
- 远程设备撤销：不占32个普通 kind；专属持久安全 journal 冻结 baseline/目标设备集合与原 ID，HTTP submit/query-close 绑定本人账号，永久最小 receipt 与可过期 baseline 分开；current-device revoke 仍走原专属安全合同。
- 四项账号隐私：未冻结草稿先落库、有限准备、显式重新确认、本地收紧覆盖与独立权威缓存已接；在线发布抑制已接真实连接：认证默认 suppressed，当前连接 typed control 仅在本人权威缓存允许且无本地收紧意图时放开；后台保持抑制，不靠断开全部 sync。

以上是当前源码状态，不表示最终端到端、真实 PostgreSQL 整包或平台验收通过；最新 Server 回归中断后的源码修复尚待下一次统一回归。

### 成员禁言 / 审核移除 C1 当前检查点

protocol38/current60：两类操作使用 Core `V2MemberAdministrationIntent` → 当前 RoomRef 签发不可续期 admission → 冻结 command → 永久原 receipt/query/close。原点击绝对授权截止≤120秒，whole membership revision 与 target joined incarnation 冻结；初始0合法。HTTP admissions/submit/operations/recover 各4KiB，认证 actor/path room 双绑定；原 TCP 请求53/55已删除并reserved，旧成员 ledger 读写删除。真实PG已验证新纵向与外层回执写失败的原子回滚，旧业务夹具已按新入口集中迁移，联合回归仍未完整通过。详见[moderation owner合同](../reviews/moderation-owner-fence-contract.md)。

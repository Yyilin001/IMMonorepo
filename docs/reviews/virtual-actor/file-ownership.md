# Room Virtual Actor file ownership, C0 preparation

The [machine-readable file list](file-ownership.json) currently assigns one edit owner to the current owned source paths, with retired paths mapped to verified replacements. It is an explicit path list, rather than a directory glob. The [static checker](../../../scripts/check_v2_virtual_actor_inventory.py) rejects duplicate/missing paths and cross-checks the [writer evidence claims](writer-evidence.json). The ownership table below records the original parallel-work plan, not a current production entry-point map; retired routed-store wrappers now live only in tests. The still-used control identity validator is in `V2MembershipIdentitySnapshotValidator.swift`; the group shard selector and fingerprints are in `V2GroupRoomCreationSelection.swift`, separate from the retired routed group-creation adapter. Media owner metadata is in `V2MessageMediaOwner.swift`; the current download grant writer is `V2RoomRefMediaDownloadClient.swift`. Files not listed remain outside the Room Virtual Actor scope unless the integration owner explicitly assigns them.

2026-09-25 退役映射：旧 `V2RoutedRoomWriteStore` 单测和 `routedSendOwnerEpochFence` 六档夹具已删除。控制库选路到独立物理 owner 的实际 Actor Host 发送见 `actorSendUsesSelectedRemoteOwner`；owner/route/kind 栅栏、两房间批量及旧 token 回滚见 `configuredSingleRoomFence`、`configuredTwoRoomFence`、`actorGrantedTwoRoomBatch`、`actorGrantedStaleMixedBatch`；锁等待与 epoch 交替见 `bothCommitSchedules`、`lockWaitCrossesExpiry`；direct fast/rich 发送见 `persistsDirectRoomLogWithoutPerUserFanoutArtifacts` 与 `reciprocalFirstSendsPromoteBothFastAppendDirections`。这些当前路径测试不是旧 routed wrapper 的逐行等价测试，历史记录仍可追溯。

2026-10-11 退役说明：下表引用的 `acceptForwardOwnerValidated` 已删除；同 Owner 转发及回归测试使用当前 `V2ActorForwardPairDomainExecutor`。表中原行号仅为迁移基线记录。

2026-10-11 回执调度清理：删除没有生产实例的进程级 `V2ReadReceiptBatcher`。当前 Host 使用 `V2HostRoomReceiptBatcher`，配置独立为 `V2RoomReceiptBatchConfiguration`，忙碌错误统一为 `V2RoomReceiptAdmissionError`。合批、成功结果、逐项失败隔离、取消、截止时间与队列上限由 `V2HostRoomReceiptBatcherTests` 验证；不再保留旧调度器专用测试。

| Owner | Existing-file boundary | New-file boundary |
| --- | --- | --- |
| C0 / main | `Package.swift`, lockfile, Core wire/domain references and four mixed files listed below | `IMV2ActorContracts/**`, Contracts tests, cross-domain dispatch and shared DTO/config/error definitions; initially extract mixed files without behavior change. |
| R1 | `IMV2/sql/schema.sql`, canonical schema contract, `V2SchemaReadiness.swift`, `V2RoomOwnerTransactionFence.swift` | Lease store/fence helper/schema tests. |
| R2 | none of the existing common files | `IMV2ActorRuntime/Hosting/**`, `Scheduling/**`, `Lifecycle/**`, `Coordination/**`. |
| R3 | none of the existing common files | `IMV2ActorRuntime/Client/**`, `IMV2ActorCluster/**`; P0 transport pin enters through C0 manifest owner. |
| D1 | send, mutation, credit and batcher files in JSON | `RoomDomain/Messaging/**`, send/mutation wire mappers and tests; residual `PostgresV2RoomWriteStore.swift` only after C0 extraction/handoff. |
| D2 | member/group/moderation files in JSON | `RoomDomain/Administration/**`; group nickname store/mapper only after C0 extraction. |
| D3 | receipt/query/log/subscription files in JSON | `RoomDomain/Queries/**`, `Receipts/**`, `Subscriptions/**`. |
| D4 | direct/group creation, audience/import and invitation files in JSON | `RoomCoordination/Creation/**`, `Invitations/**`. |
| D5 | forward workflow and media download authorization files in JSON | `RoomCoordination/Forwarding/**`, `MediaAuthorization/**`; extracted forward primitive only after C0 handoff. |
| D6 | retention/review/projection/housekeeping adapter files in JSON | `RoomMaintenance/**`; extracted room-owned housekeeping only after C0 handoff. |
| I1 / main | listed routed/owner-validated wrappers except C0's mixed media file and D6's review adapter, Gateway handler/session, three App `main.swift`, HTTP routes and cross-domain composition | App wiring and old-entry removal; shared dispatch changes coordinated with C0. |
| V1 | listed test Compose and load scripts | Fault harness, virtual actor Compose/test scripts, CI and isolated evidence. |

2026-10-11 清理：已移除当前所有权清单中 23 个不存在的源文件／测试条目，涵盖旧消息准入额度、批量追加、权限持久化凭据和实时唤醒层。它们不再作为现存文件或待恢复实现；原始分工可通过 Git 历史追溯。旧群事件唤醒的应用层替代路径更新为当前 `V2RealtimeJournalPublisher`。

## Required C0 extraction and explicit transfer

| Current file and actual collision | During extraction | After a reviewed no-behavior extraction |
| --- | --- | --- |
| `PostgresV2RoomWriteStore.swift` (9,410 lines): D1 send/credit/batch paths; D5 `acceptForwardOwnerValidated` line 261 and `importForwardExport` line 404; `acceptInTransaction` line 2442 contains source-target forwarding logic. | C0 sole editor. Move forward primitive and import receipt logic into independent same-target files with stable internal calls, preserving transaction/owner lock order. | D1 sole editor of remaining store and credit paths; D5 sole editor of extracted forward files. Any later shared helper request goes through main, not concurrent edits. |
| `PostgresV2ProfilePresentationStore.swift`: contact alias rows and room nickname rows/methods share store; `V2ProfilePresentationService.swift` presents both APIs. | C0 sole editor; split group nickname persistence/API adapter from user contact alias without changing HTTP behavior. | D2 owns group nickname file; I1 owns Account HTTP route; alias remains user-domain and has no D2 edit owner. |
| `V2ControlPlaneHousekeepingWorker.swift`: dynamic `deleteSimple` covers room operation receipts/content-review jobs plus media, profile, device, push, presence and user operation rows. | C0 sole editor; split room-owned cleanup descriptors/worker from control cleanup and preserve rotation/budget/minimum idempotency retention. | D6 owns room cleanup path; control cleanup remains I1/main shared maintenance boundary. |
| Historical `V2RoutedMediaDownloadService.swift`: message-locator room visibility and `media_download_grants` issue/claim/complete/release were interleaved with device and provider session handling. | C0 originally owned extraction; the old adapter now lives only in a test fixture. | Current RoomRef media authorization and grant lifecycle are in `RoomClients/V2RoomRefMediaDownloadClient.swift`. |
| Historical: `V2RoutedRoomStores.swift`, routed wrappers formerly in `V2RoutedRoomMutationStores.swift`, and `V2GatewayDomainCommandHandler.swift` | I1/main was the sole editor during migration; the retired wrappers are now test-only fixtures. | This row is not permission to restore the routed-store layer to product code. |

`PostgresV2MediaStore.swift` and provider upload/session stores are media authority, outside D5's ownership; D5 owns message-locator visibility and receives the extracted room adapter from C0. `PostgresV2RoomReadWatermark.swift` belongs to D3 because it directly updates `room_read_receipts`. `V2RoutedContentReviewWorker.swift` belongs to D6 application orchestration although most routed wrappers belong to I1.

New filenames above are namespace reservations. Before parallel editing, C0 must publish its compileable contract SHA and update the JSON if an extraction produces actual filenames. A file transfer is one explicit ownership edit and handoff, not two packages writing the same physical file. This inventory does not modify any manifest, schema, production code or review index.

## 实施期交接

已落成的 ActorContracts、Runtime、Cluster、Application、Contracts、Gateway、Room infrastructure 与 RoomClients 的现存文件及已拆分替代路径现登记在 JSON。退役路径保留 `retiredPath` 和 `replacedBy`，checker 要求替代文件有唯一归属且真实存在。`PostgresV2RoomWriteStore.swift` 仍由 C0/main 唯一编辑，D1/D5 通过 scoped primitive 请求接线。D6 housekeeping 拆分已交付；I1/main 负责总 Request/Auth/Factory/App 组合，领域代理只编辑明确分配的新门面文件。目录范围只是说明，实际归属以逐文件 JSON 为准。

群能力和审核的旧 `OwnerValidated` 协议已退役：当前生产写入由对应操作 Store 提供 activation scope，原有群控制、审核及成员管理持久化逻辑保留。JSON 清单不再登记这两个已删除协议文件；已读回执的旧批量归属协议和请求 DTO 也已删除；批量测试使用每房间唯一的 activation 令牌验证逐项失败隔离。

2026-10-11 回执接口收敛：删除无消费方的五组批量/群归属组合协议，以及已无生产实例的 `V2ReadReceiptService` 与 `V2ReadReceiptAdmission`。Gateway 单测的命令构造适配器位于 `V2ReadReceiptTestService`；真实数据库的单调已读集成测试改用 `recordActivationValidated`。生产记录入口保持 `V2RoomRefReadReceiptClient` 和 Host 激活执行器。

2026-10-11 目录与个人偏好旧包装退役：删除没有生产实例的 `V2RoomMembershipDirectoryService`、`V2ConversationCapabilitiesService` 及其 Gateway 遵循。单测依赖位于 `V2MembershipDirectoryTestService`、`V2ConversationCapabilitiesTestService`，不参与生产组合。生产名录仍经 `V2RoomRefQueryClient` 与 Actor 结果映射校验修订，个人偏好经当前 RoomRef 入口。

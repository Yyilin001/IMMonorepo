# Room Virtual Actor file ownership, C0 preparation

The [machine-readable file list](file-ownership.json) assigns one edit owner to each of **392 existing and implemented paths**. It is an explicit path list against the clean business base, rather than a directory glob. The [static checker](../../../scripts/check_v2_virtual_actor_inventory.py) rejects duplicate/missing paths and cross-checks the [writer evidence claims](writer-evidence.json). This is a planning freeze for future isolated worktrees, not evidence that every path needs editing. Files not listed remain outside the Room Virtual Actor scope unless the integration owner explicitly assigns them.

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

## Required C0 extraction and explicit transfer

| Current file and actual collision | During extraction | After a reviewed no-behavior extraction |
| --- | --- | --- |
| `PostgresV2RoomWriteStore.swift` (9,410 lines): D1 send/credit/batch paths; D5 `acceptForwardOwnerValidated` line 261 and `importForwardExport` line 404; `acceptInTransaction` line 2442 contains source-target forwarding logic. | C0 sole editor. Move forward primitive and import receipt logic into independent same-target files with stable internal calls, preserving transaction/owner lock order. | D1 sole editor of remaining store and credit paths; D5 sole editor of extracted forward files. Any later shared helper request goes through main, not concurrent edits. |
| `PostgresV2ProfilePresentationStore.swift`: contact alias rows and room nickname rows/methods share store; `V2ProfilePresentationService.swift` presents both APIs. | C0 sole editor; split group nickname persistence/API adapter from user contact alias without changing HTTP behavior. | D2 owns group nickname file; I1 owns Account HTTP route; alias remains user-domain and has no D2 edit owner. |
| `V2ControlPlaneHousekeepingWorker.swift`: dynamic `deleteSimple` covers room operation receipts/content-review jobs plus media, profile, device, push, presence and user operation rows. | C0 sole editor; split room-owned cleanup descriptors/worker from control cleanup and preserve rotation/budget/minimum idempotency retention. | D6 owns room cleanup path; control cleanup remains I1/main shared maintenance boundary. |
| `V2RoutedMediaDownloadService.swift`: message-locator room visibility and `media_download_grants` issue/claim/complete/release are interleaved with device and provider session handling. | C0 sole editor; extract room visibility authorization and leave route/provider orchestration behind, keeping snapshot/recheck semantics. | D5 owns extracted visibility adapter; I1 owns remaining HTTP/routed composition. |
| `V2RoutedRoomStores.swift`, `V2RoutedRoomMutationStores.swift`, `V2GatewayDomainCommandHandler.swift` and other `V2Routed*` wrappers | I1/main sole editor; C0 may request a coordinated extraction through main only. | D packages provide adapters and exact integration requests. Do not split edits by method inside these files. |

`PostgresV2MediaStore.swift` and provider upload/session stores are media authority, outside D5's ownership; D5 owns message-locator visibility and receives the extracted room adapter from C0. `PostgresV2RoomReadWatermark.swift` belongs to D3 because it directly updates `room_read_receipts`. `V2RoutedContentReviewWorker.swift` belongs to D6 worker adapter although most routed wrappers belong to I1.

New filenames above are namespace reservations. Before parallel editing, C0 must publish its compileable contract SHA and update the JSON if an extraction produces actual filenames. A file transfer is one explicit ownership edit and handoff, not two packages writing the same physical file. This inventory does not modify any manifest, schema, production code or review index.

## 实施期交接

已落成的 ActorContracts、Runtime、Cluster、RoomDomain、RoomCoordination、RoomMaintenance 与 RoomClients 文件现登记在 JSON。`PostgresV2RoomWriteStore.swift` 仍由 C0/main 唯一编辑，D1/D5 通过 scoped primitive 请求接线。D6 housekeeping 拆分已交付；I1/main 负责总 Request/Auth/Factory/App 组合，领域代理只编辑明确分配的新门面文件。目录范围只是说明，实际归属以逐文件 JSON 为准。

# 转发源授权合同与当前实现边界

对应 B04/B11/D07；2026-09-05。状态为实施中，不能据此宣布跨 owner 转发或完整内容版本受众已经验收。

历史实现记录中的 v1/v2 指纹、投递模式和迁移脚本已被当前房间日志架构替代。
当前接受成员权威来自 message_send_completions，普通发送与转发统一 v3；见[接受记录合同](message-send-contract.md)。
终态读取与尚未完成的载荷清理见[现行边界](forward-terminal-payload-retention.md)。

## 已实现的同库边界

- 每个 source/target pair 独立提交。批量命令最多 100 个源、10 个目标，源读取保留一次有序批量查询，目标执行维持有限并发。
- 初始读取与最终接受调用同一个 SQL 可见性谓词。用户必须存在覆盖 accepted membership revision 的历史成员区间，并另有覆盖当前房间 membership revision 的区间；当前正文若为编辑版本，还须存在覆盖该编辑提交 membership revision 的区间。这些区间可以不同。原区间内消息在合法重入后可读，离群期间接受的消息仍不可读。
- `message_row` 从消息自己的 `accepted_membership_revision` 读取历史版本；`room_event` 按 room/初始 room sequence/`message.accepted` 定位原始事件，并核对 payload 中的 message ID。缺失或身份不匹配时拒绝，不能回退到当前成员版本。
- 每个 pair 的接受事务在目标准入和消息锁之前，对完整源/目标房间集合按 PostgreSQL UUID 顺序取得行锁。最终源消息查询还核对房间与预读映射一致；所有源成员检查都在源房间锁下重新读取。源不存在时允许继续查询原完成记录，但新接受必须失败。
- 初始源内容带有强类型 content revision，最终在锁内比较精确版本，再检查源作者、未撤回状态、正文、富文本实体与附件 ID 顺序。附件仍走实际媒体可用性检查。权限检查不把 attribution 当作任意媒体授权。
- 首次为 pair 分配 client ID 时持久化源房间与版本；同一操作重试不能更换源引用，数据库 trigger 保护此身份。普通发送保留 v1 指纹，新转发使用包含源版本的 v2 指纹。
- 已提交 pair 的成功恢复沿用不可变完成语义；源后来撤回或被清理，不应导致先前成功的消息再次接受。

## 验证范围

真实隔离 PostgreSQL 测试覆盖 accepted 两种存储形式、当前离群、历史重入、离群期间 accepted、首次加入后的旧消息、原事件缺失/身份不符、篡改实体、16 个独立存储实例的反向转发，以及读取后源房间移除成员而目标资格仍在的精确时序。相邻完成记录回归涵盖 standard/hybrid/hybrid-mention 三种模式。最终运行状态及日志以修复进度表为准。

测试中通过真实发送创建 accepted 事件；不关闭 append-only 约束。`message_row` 历史区间测试将夹具转成合法消息行表示，覆盖该 SQL 分支，不宣称它证明全部直接会话部署组合。16 次并发是有界回归证据，不等于长期压力验收。

## 仍需完成

1. 精确 content revision、v2 指纹与 ABA 拒绝已实现；源撤回、媒体变化与接受的进一步组合时序仍需补齐。
2. 转发入口已检查当前编辑版本自身的历史受众。B03 的 fanout、room pull、preview、按 ID 读取、reply、pin、snapshot/repair 和媒体 grant 仍需贯穿同样的内容权限合同；不能把转发修复宣称为这些入口已经闭环。
3. 源引用已贯穿 App、SQLite 和协议 23，启动装配已按持久 owner 路由。同物理库的逻辑 owner 复用原接受事务；跨物理库现已配置源端 immutable export 入队、目标 inbox/admission/提交后恢复、媒体导入、源终态回执和持久投递运行时。请求未完成或暂停分别返回可重试 FORWARD_PENDING / FORWARD_PAUSED；默认未配置 crossOwner 的独立调用仍明确拒绝。媒体 HTTP owner 路由、operator 恢复、终态 envelope 清理及 owner migration 尚未完成，B04 保持开放。
4. 同库源媒体引用撤销和素材失效拒绝已有回归；跨 owner 媒体导入失败、崩溃恢复和迁移验收仍开放。上述同库测试不能代替这些边界。

## 精确源版本与迁移补充

schema 8 为 pair 增加 nullable source revision；只有旧记录可以保持未知，服务新建记录必填已验证的正版本。迁移不重新解释历史未知版本，旧 pending 操作失败关闭。协议 23 进一步要求重放时源房间/版本与持久绑定一致；旧成功记录若也缺原版本，不伪造版本以接受新协议请求。完整编码与迁移合同见 [发送指纹](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/2026-09-05-send-message-fingerprint-contract.md)。版本相同之外仍保留正文/实体/媒体比较，版本栅栏不能代替实际内容授权。

## Schema 9：当前编辑版本受众

转发检查对 `content_revision > 1` 按 `(room_id, message_id, message_revision)` 定位不可变 `message.edited` 事件，核对事件 payload 的 room ID，并检查用户在该事件 committed membership revision 上的历史成员区间。rev1 沿用原 accepted 受众。所有区间独立判断，合法重入后允许复制后来新提交的可见版本，不能复制缺席期间的版本。

该检查不依赖投影 state_event_id 非空，也不依赖可能按幂等保留策略回收的 edit operation 记录。已有部分旧投影的 state_event_id 为 NULL；只要原 accepted 和当前版本的真实事件完整，仍可正常转发。缺失或身份不符的版本事件拒绝，不能回退为当前成员资格。

`room_events_message_edit_revision_idx` 是针对编辑事件的唯一索引，约束一个内容版本只有一份提交权威并支持点查询。当前 schema 直接创建该索引；Swift/SQL gate 检查所属表、唯一性、可用状态、完整键表达式和部分索引条件。重复版本写入被拒绝，不从冲突记录中猜测权威。

范围仍限于转发初始读取和接受事务。当前版本受众、source revision 与源/目标锁共同保护该路径；不会自动纠正其他 feed 已经发出的未经授权编辑。完整 B03/B04 关闭仍需跨路径受众与恢复、跨 owner export/inbox、媒体等验收。

## 同库媒体转发

普通发送继续按 `ownedBy(sender)` 检查媒体所有者。转发在已锁定并授权的源消息与版本上，按 media ID 顺序取得完整附件引用的共享锁；拒绝任何 revoked_at 非空的引用，并比较完整 ID/ordinal 顺序。随后媒体对象检查使用该源消息的有效引用作为授权，同时继续要求 available 状态与有效期，并按 media ID 顺序锁对象。上一跳发送者不必是原素材所有者，不改写 asset owner，也不把 attribution 当作任意媒体 grant。

初始源读取若发现任何已撤销附件引用，整条源拒绝；不静默移除图片后只转发说明文字或剩余图片。素材确定失效使用与普通发送一致的 MEDIA_UNAVAILABLE。普通撤回前已经独立授权的复制消息保有自己的引用；这不等于显式 redaction/全局素材撤销已经完成跨历史受众传播。

真实数据库测试覆盖 A 原始消息→B 复制→C 再复制，素材仍属 A、附件顺序不变；伪造、缺失、调换和替换为转发人自己资产均拒绝；普通发送不能复用别人的资产。初读后单引用撤销、素材过期、failed 状态不产生新消息、引用或 completion；完成结果在后续源撤销/素材失效后仍可无副作用地重放。范围包含普通群与混合群，未声称物理文件跨 owner 导入已验证。

协议 23 已增加每条源的 room/message/revision 上下文，客户端 durable plan 与 chunk 完整保留。服务启动装配已按这些源房间与目标房间路由；只在部署证明全部逻辑 owner 共用一个物理位置时绕过控制面查询。不会遍历所有数据库或用默认 owner 替代失败的路由。

## App 完成展示与分块结果

一次 `flushOnce` 只处理一个分块，也可能先处理其他计划。App 必须按自己 enqueue 得到的 plan ID 重新读取持久父计划，只有 completed 才报告全部成功/失败计数；active 表示任务已保存且仍待处理，cancelled 不能显示排队。失败的一个分块不意味着其他分块已终止，最后一块的结果也不能替代累计结果。父计划查询缺失应暴露本地一致性错误。

这一状态判断已有真实 SQLite 与 App Store 集成验证，覆盖 100×2、首块失败、部分累计失败、旧计划先 flush、close/reopen、terminal replay 与 retryable pending。测试中的 FORWARD_PENDING 只是验证现有 retryable 传输错误保持 active，不代表服务端 export/inbox pending 协议已实现。源房间及选中版本已在协议 23 与持久队列中实现，仍需在跨 owner 复制执行与后台终态展示中贯穿。

## 协议 23 / Schema 10：源定位与选中版本

`V2ForwardMessageReference` 显式包含 roomID、messageID 和有界正 revision；JSON 解码重新验证版本，不允许默认版本。命令按 messageID 拒绝重复源，即使两个输入声称不同房间/版本。wire 保留旧 field 2 及 source_message_ids 名字，不重新使用其编号；新 sources 使用 field 4，网关拒绝缺失、空房间、零/越界版本和重复源。

App 勾选时保存源引用，确认时按原 room sequence 排序。后续编辑、撤回或窗口刷新不能把引用变成另一版本，也不能静默漏掉已选但移出窗口的消息；服务端按最新授权拒绝失效来源。初读只在所声明房间查消息，授权通过但 content revision 与选中版本不同返回 SOURCE_CHANGED；房间错误仍为 NOT_FOUND。pair client ID 与 source_room_id/source_content_revision 同事务持久绑定，成功或待定 pair 改动任一字段重试均返回 IDEMPOTENCY_CONFLICT。已成功的精确引用可在源以后修改/撤回后恢复原结果。内部发送 v1/v2 指纹字节不变。

当前 schema 直接保存转发操作的来源房间与版本，身份保护 trigger 拒绝修改这些字段，Swift/SQL 启动门禁要求完整结构。新环境安装规范 schema；不回填旧操作、不执行历史升级链。

SQLite 的 bindForwardSourceReferences 迁移为普通 pending command、parent plan、chunk 增加 source_references，为 parent 增加 terminal_code。新计划/分块完整保存选中引用，懒分块与重新打开数据库均不查询当前正文来替换来源；相同计划 ID 改房间或版本拒绝。旧队列无法恢复选中版本：未完成普通命令标 rejected、未完成 parent/chunk 标 cancelled，代码 SOURCE_RESELECTION_REQUIRED；成功/失败累计数与完成摘要原样保留，不把未发送项伪装成已失败发送。已有 chunk 的相同完成摘要仍可幂等确认，无需构造可再次发送的旧命令。后台计划状态的持续展示与升级提示仍需补齐，不能把数据库记录存在当作用户已收到提示。

本批实际验证：Core 78、ClientKit 293、App 170、服务端 75 项；含真实 SQLite 升级和 close/reopen、protobuf 往返、勾选后编辑/移出窗口、源房间错误、选中版本变化、同一操作改参、ABA、迁移链、不可变 trigger、八类启动门禁和媒体/网关回归。该批未覆盖跨 owner export/inbox、文件导入或 owner 迁移；后续真实双数据库路由验证见下一节。

## Owner 路由与分块 UUID

`V2RoutedForwardMessagesService` 在多物理位置时，对源/目标房间做一次有界控制目录查询，选择配置中对应的 owner service。若某房间不存在，仅回退为最多 110 个已知请求房间的目录点查，使其他 pair 仍可完成；目录故障和未知配置 owner 都不会触发另一个数据库读取。默认最多四个目标并发，每个目标按源顺序处理连续同库区段，结果仍按 source×target 原序排列。同库判断使用配置的 database URL/schema 物理键，逻辑 shard ID 不同本身不意味着跨库。

启动装配为转发复用普通写入的 owner store 与现有 policy/credit pool，消除固定 control DB 和重复创建 credit pool 的路径。真实两库测试在同一专用 PostgreSQL 实例的两个数据库运行：第二库消息不在 control DB 中，库内转发成功；两方向跨库组合均明确拒绝、无额外消息/forward operation/completion，源后来撤回后精确已完成 pair 可恢复原结果。多库路由、混合逻辑/物理拓扑、未知房间、未知 owner、目录/owner 故障及有界并发均有回归；这不表示持久跨库复制已经完成。

跨层验证另发现原 SQLite 懒分块 operation ID 为 parentUUID-f0，而服务端 PostgreSQL 路径要求 UUID。此前可在假传输上通过，实际服务在查询前即失败。新 `V2ForwardChunkIdentity` 用独立 domain、父 UUID 的 16 字节和 big-endian UInt64 chunk index 做 SHA-256，取前 16 字节并设置应用定义 UUID 的版本/variant 位；父计划相同且序号相同总是同一 UUID，UUID 字典顺序不再被用作分块顺序。独立 Python 夹具：父 00000000-0000-0000-0000-00000000f001 / chunk 0 → 59993946-8967-8ccb-9846-764840d87627。Core、客户端 protobuf 及真实 PostgreSQL 接受均验证这一合同。

SQLite `useUUIDForwardChunkIdentities` 只重写 pending 且精确匹配旧 parent-findex 的不可发送身份，保留 retry count/deadline、源引用、父计数；有效 UUID 和所有终态记录都不改写。未知 opaque 身份取消剩余计划并要求重选，不自行解释成新操作；同一旧 completed chunk 的摘要确认仍不增加计数。网关将非 UUID 操作 ID 明确映射为 INVALID_ARGUMENT。此修复不改变协议 23 或 schema 10，也不改变发送 v1/v2 指纹。

## Schema 11：源端不可变 export（尚未接入跨库投递）

`PostgresV2ForwardExportStore.prepare` 只访问明确指定的 source owner 数据库。事务先锁 pair 幂等键，再锁一个源房间；在房间锁内核对本地 shard/owner epoch、历史与当前成员区间、精确编辑版本受众、未撤回正文、富文本实体及全部附件引用。媒体对象按 UUID 排序加锁，任何已撤销引用、失效素材或版本不符都会拒绝整个副本。过程中没有 target RPC、远程房间查询或目标接受动作。

`message_forward_exports` 同时保存源授权和待投递记录：actor、operation、source room/message/revision、源作者、target room/client UUID、源/目标 shard+epoch、正文、实体和有序媒体 manifest。数据库禁止修改或删除已提交 envelope；没有 source message 或远程 target room 外键，因此源投影生命周期不能级联抹除授权。SHA-256 绑定实际持久化的 UTF-8 payload 字节，接收方必须校验这些原始字节，不能重新编码 JSON 后求 hash。它是完整性摘要，不是消息认证签名；媒体 manifest 只含素材 ID、upload session、类型和大小，摘要不证明文件字节已复制或已校验，也不保存 provider URL/凭据。

export COMMIT 是源授权的线性化点。同 pair、相同原始源引用的重试优先读取原字节和原 target client UUID；后来源编辑、撤回、退群或路由 epoch 改变不会重新授权或改写副本。换源房间/版本仍报幂等冲突。新 export 必须通过当前房间的 `owner_epoch` 检查；schema 10→11 只从同库且 owner 相符的目录行回填非零 epoch，远程目录部署在启用功能前必须同步本地 epoch。完整 owner 迁移和目标重新路由协议尚未因此完成。

媒体 retention 排除 export 引用；先用 SKIP LOCKED 取得有限候选对象，再用新的 READ COMMITTED 语句复核 pin 和清理条件，避免旧语句快照漏掉刚提交的 export。schema 11 阶段的 source store 默认每房间最多保留 1,024 份 export，重放不占新槽；该阶段尚无目标终态回执，因此所有 export 引用继续保留。后续 schema 14 已改为仅未完成导出占配额与 pin，见下文。后续必须完成目标回执、pin 释放和授权记录保留/清理策略，再启用跨库生产流量。全局内容封禁与普通源撤回是不同操作，强制清理合同仍需另行贯穿。

真实隔离 PostgreSQL 覆盖两种群 delivery mode、schema 7→11/8→11/10→11、16 个独立 store 并发重试、失败无新增记录、精确内容与媒体顺序、不同连接池重读、后续编辑/撤回/退群后的原字节恢复、改参冲突、旧 owner 拒绝、容量上限、媒体 pin 与无引用素材清理、缺列/禁用 trigger/伪造索引的启动拒绝。export 与 withdrawal 的两种提交顺序还使用测试数据库 trigger 暂停真实事务，核对后到者确实等待源房间锁。以修复进度表中的最终终态日志为验证依据；以上不代表 target inbox、真实文件导入、跨进程崩溃恢复或 owner 迁移已验收。

## Schema 12：目标 inbox 与接受事务（投递装配仍待接通）

`PostgresV2ForwardInboxStore.receive` 持久化精确 envelope，绑定 export ID、actor/operation/source message/target room 和唯一 target client UUID。相同 ID 的不同原字节或同 pair 的替代 export 被拒绝；默认每目标房间最多 1,024 个未完成 inbox。receive 使用独立配额 mutex；已有绑定先匹配返回，只有新绑定取得房间共享锁并持有到插入提交，不持房间锁等待已有 inbox，避免与接受路径形成相反锁序。收到 envelope 只意味着已入队。

`PostgresV2RoomWriteStore.importForwardExport` 读取已锁定 inbox，再使用原有共享接受事务；锁序为 inbox → message operation → target room/admission。只有从精确 inbox 和媒体映射构造的内部 authorization 能跳过目标库内的源消息查询，普通 SendMessage/forwardedFrom 仍走原源授权。目标的新接受仍检查本地 owner epoch、当前成员/账号/禁言/冻结/角色发言权限、私聊策略和容量准入。目标 epoch 在房间锁内读取。同 owner 的已接受消息恢复不因后来的退群、正文清理或部署文字上限缩小而变成新拒绝。后续 owner 栅栏修复明确区分 accepted 与不可变终态：accepted 重试和最终 completed 发布都必须检查原目标 owner；只有已 completed/rejected 的终态证据可以跨后续 epoch 变化重读，见[后台导入 owner 合同](forward-import-owner-fence-contract.md)。

inbox 的状态为 pending → accepted → completed，或 pending → rejected。accepted 与目标 message、send completion、日志和准入记账同事务提交；随后运行原有 cache/projection shadow 的提交后处理，成功后才标记 completed 并返回接受结果。事务中途失败时所有目标写入回滚，先前 receive 仍 pending；提交后失败时保留 accepted，重试通过原不可变 send completion 恢复提交后工作，不重复消息或用户投影。completed/rejected 及绑定身份不可改写，receipt 不依赖可变消息外键。

双库测试暴露并移除了旧 `messages.forwarded_from_message_id` 本地外键：目标数据库本来就不含源消息。schema 11→12 删除该外键，保留普通转发的源授权与 inbox capability 检查。Swift/SQL 启动 gate 同时拒绝残留来源外键（包括改名约束），校验 inbox、媒体映射、终态 shape、不可变 trigger 与唯一身份索引。

附件必须有完整的 ready 映射：source media ID/顺序固定，target media ID 必须是独立对象，且记录真实对象摘要。schema 12 本身不把 pending 行自动标成 ready，因此缺文件时不会把图片说明当纯文本发送。schema 13 文件 importer 提交 ready 后，接受事务仍要求目标素材归当前 actor 所有、可用且未过期，并比较实际类型/大小与原 manifest；不会把 source media ID 直接当任意目标素材的授权。目标未完成 inbox 的 ready 素材也受到 retention 保护。

最终双库回归覆盖普通群与 Hybrid 的 16 个 store 并发导入、源 export 后撤回、目标数据库零源消息、原子回滚、完成标记故障、目标副本撤回后恢复、改参冲突、普通 attribution 不能绕过源检查、八类目标边界，以及 planner/room-log/shard-room-log 私聊配置下真实 projection-shadow adapter 故障恢复。room-log 保持零 fanout plan/delivery，恢复不重复用户投影。源版本、媒体保留和迁移链回归一起运行，最终日志见进度表。

schema 12 阶段遗留的实际文件导入和源端回执已在后续 schema 13/14 实现。当前剩余工作包括 outbox/inbox worker 与启动接线、跨 owner pending 的客户端反馈/重试、owner 迁移及崩溃/丢 ACK 组合验收。当前源/目标保留完整 envelope，终态 payload 擦除、保留窗口和全局封禁清理也尚未完成。路由入口暂仍明确拒绝跨物理库转发，不能把这些未接线 primitive 宣称为 App 已具备完整跨库功能。


## Schema 13/14：实际文件导入与源端终态回执

媒体导入已新增 `PostgresV2ForwardMediaImportStore`、`V2ForwardMediaImportWorker` 与本地文件 copier。目标为每个 export/ordinal 持久分配独立的 media ID 和 upload session，lease 接管复用同一对象身份；分块复制计算实际 SHA-256，原子安装不覆盖冲突文件。复制摘要持久化后可在源文件已不可用时验证目标对象并继续扫描。扫描通过才提交 ready；旧 claim 或 owner epoch 变化后的写回拒绝。取消排空复制任务后释放 lease，暂时失败保留退避重试，不把重试耗尽当成目标接受。

schema 14 增加不可变 `message_forward_export_receipts`。目标 `terminalReceipt` 只能从 completed/rejected inbox 创建内部回执能力；pending 和 accepted-but-unfinalized 均无回执。回执绑定精确 export，不能把客户端上传的 JSON、校验和或临时结果作为源端释放依据。

源端 `PostgresV2ForwardReceiptStore.record` 比较本地原 envelope 与摘要，在源房间锁内检查 owner epoch，并幂等插入终态。重复相同结果不修改原记录，不同结果拒绝；已经保存的回执不因后续 epoch/成员变化失效。新回执仍拒绝旧 source owner，跨 owner 迁移交付需后续完整协议承接。回执插入失败或 ACK 丢失时，原导出继续保留且仍占用投递配额。

源房间配额只计没有终态回执的导出。媒体 retention 也只把未完成导出视为 source pin；同一素材有多份导出时，任何一份未完成都会阻止清理。全部终态后仍必须通过普通消息引用、撤回保留期和素材有效期条件，回执本身不会直接删除文件或使有效消息失去素材。独立目标对象及目标消息引用不受源 pin 释放影响。

本批测试覆盖目标未完成后处理时无终态回执、并发重复回执、不同结果/内容冲突、源 owner epoch 变化、插入回滚、丢源 ACK 后额度保留，以及真实单/双附件的两份导出全部结束后源清理。最终执行结果以修复进度中的本批记录为准；测试存在不等同于测试已通过。

截至 schema 14 组件批，投递 worker 与运行入口尚未接通；后续 schema 15 和 2026-09-06 运行接线批已补齐。终态 envelope 的正文擦除/保留窗口、全局内容封禁与完整 owner 迁移恢复也仍待完成。上述组件不能作为跨库 App 功能已验收的证据。


## Schema 15：持久投递 worker

源 export 与 `message_forward_delivery_jobs` 在同一事务入队；14→15 迁移为尚无终态回执的既有 export 回填任务，不重新读取或授权源消息。任务持有 pending/claimed/paused/completed、租约 token/期限、到期时间与重试次数，immutable envelope 不承担可变调度状态。

`PostgresV2ForwardDeliveryStore` 按配置的 source shard 和当前本地 owner epoch 领取有界任务，使用 SKIP LOCKED；过期 claimed 可接管。所有完成/调度写回检查当前 token 与未到期租约。重试计数在 Int64.max 饱和递增，避免溢出和丢失领取能力。completed 必须已有源终态回执，SQL trigger 同时拒绝无回执完成及终态改写。

`V2ForwardDeliveryWorker` 每轮最多领取 maximumConcurrency 个任务，结构化 task group 排空。网络和复制均在数据库事务之外。目标 nil 表示暂未完成，延期后继续，不计入连续失败次数；传输错误使用既有指数退避/抖动，耗尽后 paused 保留源 pin 和配额。取消只释放自己仍有效的 claim；旧租约不能修改新任务状态。目标调用默认在租约 80% 时触发取消，结构化任务组排空目标与计时器后再重试；目标适配器必须传播取消并为底层 I/O 设置期限，非协作驱动不能仅靠 Swift 取消实现硬时限。源回执已保存但 job completion 丢失时，下一轮直接补完任务，不重复目标请求。

`V2ForwardImportEndpoint` 复用目标 owner 已配置的 room write store 与 inbox；每次最多推进一份附件，仍未就绪就返回 pending。全部附件 ready 后才调用原共享接受事务，保持准入、shadow 和提交后恢复。`V2ConfiguredForwardExportDelivery` 只按 envelope 原 target shard 选择适配器，无默认库兜底。

当前组件有双库故障测试，执行终态见修复进度记录。Gateway/runtime 与 pending 的 wire 映射已在下一节接入；暂停任务的 operator 审计恢复、媒体 HTTP owner 路由、owner 迁移与终态 envelope 清理仍开放。不能把组件与运行时测试等同于已发布跨库功能。


## 2026-09-06：Gateway 入队与运行时生命周期

`V2CrossOwnerForwardService` 在前台仅提交源 export/job 和读取源终态回执；请求取消不会删除已提交任务。`V2RoutedForwardMessagesService` 完成所有配对的入队后，再返回整体 pending；不把第一个 pending 抛错给 task group 而取消尚未入队的目标。同库配对继续复用原接受事务，重试恢复既有结果；全部配对终态后才按原 source×target 顺序返回结果。暂停优先返回 `FORWARD_PAUSED`（retryable，30 秒），其他未完成返回 `FORWARD_PENDING`（retryable，1 秒），不会发送半份 messagesForwarded 完成包。

Gateway 使用每个 owner 原配置的 `PostgresV2RoomWriteStore`，通过值拷贝切换到同一物理库的 delivery workload pool，保留策略、cache、credit actor 和 shadow 后处理。`V2ForwardDeliveryRuntime` 为每个已配置 source shard 运行一个结构化循环，每批最多 4 个 export；退避遵循现有 bounded-busy cadence。Gateway 退出时取消并排空 runtime，再关闭数据库。配置缺失直接失败；没有默认目标库或扫描兜底。

本地 Compose 为 Gateway 与 Account 配置同一显式测试媒体目录、签名密钥来源和 volume。Gateway 不调用 provider.prepare，避免启动时清理账户进程的上传 staging。此处只支持已有本地测试 provider；生产对象存储与扫描适配器仍待接入。Account 重启清理 staging 的跨进程所有权，以及控制库固定媒体 grant/session 查询仍是未关闭边界。

真实双库测试通过实际持久 room directory、router、源服务、目标端点和 runtime 验证普通群/大群：运行中入队；停止期间源任务积压而目标不写入；重启后完成；重复请求、源后来撤回仍恢复原结果；更换源版本得到幂等冲突。Gateway handler 另验证 protobuf 错误映射。此处未启动 TLS Gateway/App 进程，不能称为完整设备端到端验收。最终日志与源码绑定见修复进度记录。

持久暂停也必须跨进程恢复：目标扫描耗尽提交 paused 后可能丢失响应，新 media worker 无可领取任务时读取该 export 的 paused 状态，继续返回 paused，源 worker 保持暂停。不能把不可领取的 paused 永远当成普通 idle。最终 **95 tests / 8 suites** 与 **37 配置测试 / 2 suites** 的完整日志及源码绑定见 [本轮持久证据](../../docs/reviews/verification-records.md#20260906-forward-runtime)；其中 17 种投递场景包含暂停响应丢失，29 种启动门禁故障均通过。


## Schema 16：独立 operator 审计恢复

新增 `forward_work_replay_audit`，审计 identity 和终态不可变。15→16 迁移不改既有 export、任务或媒体 ID。独立 operator 的 `/internal/v2/forward-work/replay` 使用现有 replay bearer、服务配置 principal 和显式 room owner registry；源 delivery 使用 export UUID，目标 media 使用 export UUID + ordinal。没有数据库 URL 输入、批量 SQL、自动扫描或默认库回退。

恢复审计与 paused→pending 在同一 owner 事务提交；失败整体回滚。新操作在房间锁下核对原 export 的 shard/epoch；媒体锁序为 inbox→room→job，终态 inbox 不恢复媒体。相同已审计 operationID 先返回原结果；更换目标或 reason 构成冲突。仅清租约并重置重试预算，保留原 target UUID、copied digest 和扫描要求。恢复后仍由普通 import 路径检查当前成员权限，不能把运维恢复当作新授权。

HTTP、真实双库恢复及迁移/门禁验证以本轮修复记录为准。具体配置、请求、先目标媒体再源投递的恢复次序和错误处理见 [暂停恢复操作合同](forward-operator-replay.md)。跨库媒体 HTTP owner 路由、owner 迁移及终态 envelope 清理仍开放；本轮没有部署 operator 或操作用户数据库。

Schema 16 最终 **104 tests / 11 suites** 通过，含 18 种投递场景与 34 种 schema gate 故障；同操作 16 次并发、不同操作 8 次并发、实际附件恢复和恢复后禁言均覆盖。完整失败/成功日志、差异原因与最终源码绑定见 [operator 恢复证据](../../docs/reviews/verification-records.md#20260906-forward-operator)。


## 2026-09-06：按消息位置路由媒体下载（schema 17）

会话下载携带 `room_id` 和 `message_id`；它们只是定位信息。HTTP 边界要求成对的 UUID，缺失一半或非法返回 400。服务器从控制面查房间持久 owner，再选择部署配置中的数据库与 provider；没有注册的 owner 返回 503，不能靠遍历数据库找到可读副本。头像保留不带消息位置的控制库路径。

下载授权分三处读取：控制库检查当前设备、有效账户；房间 owner 检查消息、当前及历史受众、当前内容版本、媒体可用状态和有效引用；原消息的不可变 send completion 决定读取个人投影还是 room log。个人交付必须在用户当前路由的存储中找到有效版本，含匹配消息/房间、内容 revision 和附件；不能要求设备镜像到目标库。旧消息缺 completion 时保守要求个人投影，不能根据群当前模式扩大访问权限。

用户路由沿用切换栅栏。读取投影前获取 owner 快照，之后在房间→消息/媒体锁内比较成员版本、内容版本和媒体状态。grant 创建、claim、provider 签名后的最终消费都执行授权；provider 调用发生在数据库事务之外。签名返回期间已撤回、撤销设备或移除投影会拒绝返回目标，释放本次 claim；取消会等待 provider 退出。

Schema 16→17 给下载 grant 增加消息/owner/epoch 的完整范围，并移除指向本地设备镜像的 FK。grant 的身份和范围不可变，consumed 不可重新打开；旧下载路径只能 claim 无消息范围的 grant。schema 门禁检查字段、完整 CHECK、身份 trigger 的启用状态和精确函数体，也拒绝重新加回设备 FK。已返回的 provider URL 仍有短期有效窗口，此合同不声称能撤销已发出的外部签名。

Account 从明确的 room/user registry 装配，连接预算覆盖去重后的所有数据库。本地 Compose 已配置同库实例；跨库测试使用独立 PostgreSQL 库。生产 provider/scanner、普通上传在多 owner 的分配、各 owner 保留清理、迁移和全局内容封禁仍属开放范围；组件与模拟器测试不等于已部署跨库服务或真实 TLS 全链路验收。

升级时先在所有配置的存储上执行 16→17 迁移，再使用匹配的服务端二进制和 Account room/user registry；旧 schema 会被启动门禁拒绝。新版 App 会话始终传消息位置，部署不能省略 room registry 后依赖旧控制库路径兜底。此轮没有执行生产迁移。

最终验证：Test run with 113 tests in 13 suites passed after 81.899 seconds.；ClientKit 294、Core 80、App 模拟器 170 项测试通过。完整初次失败与最终成功日志及源码绑定见 [schema 17 媒体路由证据](../../docs/reviews/verification-records.md#20260906-scoped-media)。

## 前台同库 owner 补充（2026-09-06）

前台路由现先解析每个来源和目标的 shard/epoch，再进入本地执行；来源查询、操作记录创建/修复、目标接受及结果补记均在对应事务内验证，保留来源集合读取、有界并发和原消息身份。详见[前台转发 owner 合同](foreground-forward-owner-fence-contract.md)。跨库 export/inbox 终态证据的读取规则保持独立；完整迁移、投影承接和全局内容封禁仍开放。

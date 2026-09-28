# 跨 owner 转发终态载荷保留与清理

日期：2026-09-27。当前 schema 59、协议 37；账户 HTTP 父计划沿用本主题的最小原回执与正文分离规则。
目标 inbox 与源 export 均已接入有界正文清理，清理事务提交前后 SIGKILL 专项已通过；运行器/外部副作用组合、成本与完整 owner 迁移仍未完成。

## 账户父计划与永久证明

生产提交入口为账户 HTTP `POST /v2/forward-plans/submit`，恢复入口为 `POST /v2/forward-plans/operations/recover`。两者最多 64 KiB，认证账户必须等于冻结命令 actor；返回 no-store。完整 manifest 限 100 条来源、10 个目标，每 20 条来源按目标形成稳定子块。恢复携带相同冻结命令，不依据摘要反推不存在的 manifest。

`forward_plan_operations` 保存有界强类型 manifest/progress 和最小终态摘要。公共 work 的终态回执仍最多 64 KiB；完整结果最多 1 MiB，按有序子身份与结果摘要校验。终态和 manifest 禁止修改或删除。每账户最多 64 个活跃父计划；耗尽返回绑定身份的非终态 admissionUnavailable 与 5 秒调度下限，不伪造原拒绝。

父提交、首次子交接、query、closeIfUnstarted、cancelRemaining 共父身份锁。24 小时首次窗口只限制首次交接，已交接子任务继续核对。cancelRemaining 只将尚未交接子任务记为 cancelledBeforeStart；处理中子任务必须向源 RoomRef 核对原 export。源尚无 export 时，共 export pair 锁持久保存 CLOSED_BEFORE_EXECUTION；已有 export 时，继续向目标 RoomRef 导入/核对原 inbox 结果并记录源回执。ACK 丢失、delivery job 暂停、当前权限改变均不允许将旧已执行结果猜成未执行。

`forward_preparation_rejections` 保存在原 export pair 锁内、无 export 时产生的永久来源拒绝或关闭证明，绑定 actor/child operation/source room/source revision/target。它不保存消息正文、不授予公开资料 lease，也不参与正文清理。查询既存原证明优先于当前来源可见性，但仍受当前精确 owner activation fence 限定。

账户 runtime 启动有界持久 worker；control store 只保存父元数据，所有来源准备、查询、关闭、目标导入和来源回执记录均经过 RoomRef。原 export/inbox 的媒体处理和持久投递仍有效。新无首次窗口的旧 TLS forward 入口停止准入。真实部署还需按配置的 accountBaseURL 验证可达与跨进程 owner 调用；当前专项夹具不能代替部署验收。

## 当前实现

`V2CrossOwnerForwardService` 首先用 actor、operation、source message、target room 查询源端不可变
export 与 terminal receipt。必须匹配原 source room / source revision，且回执摘要与导出摘要相等。
完全一致时直接返回原成功或拒绝结果，不读取 export.payload、不解码信封、不重新授权源正文，
也不依赖目标库可用。改换源房间或版本返回 IDEMPOTENCY_CONFLICT；摘要不一致按存储损坏报错。

没有终态回执时进入 prepareForDelivery。它在原 pair 互斥锁内，以同一条 SQL 联结 export 与 receipt：
该快照已有回执则返回终态并不选择正文，否则读取完整导出。源房间/修订绑定与回执摘要均须匹配。
因此预查未命中后提交的回执也能直接重放；若查询快照仍无回执，读取的是当时的完整导出。
取得导出后再次读回执，允许工作器随后完成任务。新请求继续原来源可见性、目标授权与持久投递流程。
原 public prepare 保留“返回完整导出”的合同；清理后校验绑定及回执摘要，再抛出明确的 payloadCompacted，
不重新生成导出。业务入口使用 prepareForDelivery 返回原终态。
此改动在未完成请求上增加一次按 export pair 唯一键的预查；尚无容量测量，不能宣称新路径没有成本。

终态回执现只保存 exportID、32 字节 payloadDigest 和结果。目标 terminalReceipt 只查询终态行，
不读取正文；源端 record 通过导出主键/摘要及数据库内保存的源 owner/epoch 核验，不读取正文。
投递工作器与目标 endpoint 均要求 ID 和摘要匹配原导出；错误摘要、结果冲突和首次提交的旧 owner 仍拒绝。
回执构造器保持模块内部，客户端提供的摘要不构成可信回执。此为服务器模块内 API 改动，未改网络协议。

目标 receive 的重复导出按主键与已验证的 SHA-256 摘要核对，不再查询已存正文；
status 与加锁读取仅在 pending/accepted 时选择正文。importForwardExport 先核对摘要，
终态直接返回原结果；未完成任务继续核对完整正文、执行原授权和接受流程。

schema 40 在目标 inbox 独立保存不可变 target_shard_id / target_epoch。operator 媒体重放
读取这些字段与 target_room_id，并通过不可删除的 inbox_media 行验证 ordinal，不再读取 payload。
继续核验当前房间归属；仅 pending inbox 的 paused 导入任务可重排队，终态返回 notPaused，
旧操作审计重放保持原结果。新建库合同和启动检查同步更新；不支持旧数据库就地升级。

schema 41 允许目标 inbox 在终态后单向转换为 payload=NULL，并记录 payload_compacted_at。
约束和触发器要求原记录已是 completed/rejected、时间不早于 completed_at，且其他所有字段不变；
不允许未完成任务清理、正文恢复、身份/结果改写或删除记录。
`PostgresV2ForwardInboxCompactor` 按完成时间和主键扫描，单批 1...1024，FOR UPDATE SKIP LOCKED；
一条 SQL 原子清理，重复执行无效。Gateway 原有维护生命周期按配置批量调用各 owner 后台数据库。
默认保留终态正文 7 天用于排查；这不是幂等身份有效期，身份、摘要、结果及媒体映射继续保留。
schema 42 的源 export 增加 delivery_completed_at / payload_compacted_at。
投递 job 进入 completed 时，数据库触发器在同事务给导出标记完成时间；必须已有匹配摘要的回执。
源清理器使用未清理终态的部分索引，要求 job 仍为 completed、时间与标记一致、回执摘要一致，
且投递完成与回执记录均超过 7 天。清理仅允许单向删除正文，身份、路由、媒体 ID 和摘要不能改。
源、目标清理使用各自库中的终态事实，没有跨库事务；旧租约不能重排完成任务。
本次只在临时数据库验证，未部署或操作生产数据。

本地文件适配器的删除现保存持久 `.object-state` 标记，普通上传和转发提交使用同一对象文件锁，
先检查删除标记再安装。删除先同步标记及目录，之后移除对象并同步目录；读取也检查标记，
防止标记已提交、尚未 unlink 的中断状态暴露旧对象。锁文件与删除标记不自动回收，不能复用已删媒体 ID。
本地适配器已补暂存完成、安装完成、删除完成三个真实 SIGKILL 检查点，并分别用新进程恢复验证。
这不覆盖数据库清理事务内强杀、文件系统掉电或 Linux；生产对象存储仍按 E03 验收迟到写入栅栏、持久性和标记保留成本。

## 仍须完成的清理边界

1. 目标 inbox 与源 export 已区分不可变身份/结果与可清理正文；仍须补跨组件端到端故障证据。
   不删除操作身份，不让原操作重新进入新导出或接受路径。
2. 源端 receipt.record 和目标 terminalReceipt、receive/status、导入终态重放已解除正文读取依赖；operator 媒体回放也已解除正文依赖。源投递只认领未完成任务，源清理必须已完成；
   媒体读写先锁定 inbox 并要求 pending，终态返回空/拒绝。真实本地文件复制完成后的成功/拒绝、双端清理与迟到元数据回调已验证；
   本地暂存上传跨删除的迟到安装已修复并专项验证；对象过期/清除与导入工作器交错的后续专项见下方验证入口，仍须补完整运行器跨进程强杀和生产外部存储失败。
   已完成任务不能因迟到工作器再次写入正文；pending、accepted 未收尾、paused 的未完成任务不得清理。
   生产 prepareForDelivery 用单语句快照选择终态或正文；已纳入清理后结果重放与直接 prepare 错误专项，
   源/目标、成功/拒绝、提交前后八个真实 SIGKILL 组合已通过；仍须补运行器与外部复制并发清理。
3. 目标端依据自身完整终态清理；源端结合目标回执与本地投递完成状态清理，不能依赖跨库事务或“暂时查不到任务”。
   核对媒体任务、源对象保留引用与返回失败的竞态，保留追踪结果所需身份和审计。
4. 双端有界扫描、事务回滚、并发/重复清理、事务提交前后 SIGKILL 及重放已纳入专项；仍须补
   跨进程运行器强杀、生产复制/存储故障和混合业务端到端验收；现已覆盖同进程重建运行器、
   真实媒体接受后丢回执、目标正文清理及配置边界注入不可达的重试组合，不代表真实网络分区。
   清理事务的客户端强杀不等同数据库崩溃/WAL 恢复，也不替代上述运行器组合。
5. 完整 room owner 迁移承接压缩状态、身份及结果；这部分依赖 B27，路由切换不替代迁移。

压缩信封只能回收正文副本，不等于接受记录 GC、媒体对象清除、备份清除或无界身份记录增长已解决。
接受记录另见[保留合同](send-completion-retention.md)。

## SQL 清理成本

[2026-09-19 成本专项](verification-records.md#20260919-forward-compaction-cost)直接提取两侧清理器 SQL，
在独立临时库测量 1,000/10,000 条记录、1 KiB/64 KiB 文本与 1/128/1024 批量，共 18 组。
源端原 JOIN 在小批清理前扫描历史回执，现改为按 export_id 主键的标量子查询，继续核验
job 状态/完成时间及 receipt 摘要/记录时间。缺失记录返回 NULL，不满足清理条件；每个主键最多一行。
1 万条记录中清理 1/128 条分别查询 1/128 个任务和回执，候选使用未清理终态的部分索引。
目标端小批也使用部分索引；批量 1024、实际更新 500 行时，优化器选择全扫目标表作为 UPDATE 的连接输入。
因此“有界”指更新条数，不保证任意统计分布下每一层扫描均严格受 limit 限制。
本次未改变 schema、保留期、锁顺序或更新触发器。测量包含触发器执行与 WAL，但为本机缓存命中，
逐次 EXPLAIN 更新后回滚，后续执行可能遇到已回滚版本；不是冷缓存、长期存储增长或生产吞吐承诺。
运行器/复制副作用及完整迁移仍开放，身份记录和对象删除标记的长期增长另需评估。

## 本批验证

完整投递运行器的附件回执丢失、目标正文清理与目标不可达重试组合见[运行器重试证据](verification-records.md#20260919-forward-runtime-compacted-retry)。

本地提供方并发初始化重复清理暂存目录的修复见[初始化重入证据](verification-records.md#20260919-forward-media-prepare-flight)。

导入工作器在复制调用未返回时与保留/清除工作器交错的专项见[复制与清除交错](verification-records.md#20260919-forward-copy-purge-interleaving)。

源/目标清理事务提交前后、成功/拒绝八个真实 SIGKILL 组合见[数据库清理强杀证据](verification-records.md#20260919-forward-compaction-sigkill)。

本地文件三个真实 SIGKILL 检查点与独立进程恢复见[进程中断证据](verification-records.md#20260919-forward-local-purge-sigkill)。

本地对象删除与迟到普通上传/转发安装的互斥及持久拒绝验证见[删除防护证据](verification-records.md#20260919-forward-local-purge-fence)。

真实双库、本地媒体文件、双端正文清理后的迟到回调与重放见[媒体清理组合证据](verification-records.md#20260919-forward-media-terminal-compaction)。

schema 42 源端实际清理、完成标记原子回滚、迟到租约与双端清理后重放见[源清理证据](verification-records.md#20260919-forward-source-compaction)。

schema 41 目标正文实际清理、回滚、并发清理、终态重放及启动拒绝验证见[清理证据](verification-records.md#20260919-forward-inbox-compaction)。

终态元数据查询的真实 PostgreSQL 专项及双 owner 运行器/回执回归通过。
回执去正文后，26 个双库参数场景与摘要长度/终态查询专项通过，见[回执证据](verification-records.md#20260919-forward-bodyless-receipt)。
schema 40 的归属元数据、operator 重放与启动拒绝专项见[归属元数据证据](verification-records.md#20260919-forward-inbox-owner-metadata)。
源端准备阶段的回执提交窗口专项及导出/双 owner 运行器回归见[准备阶段证据](verification-records.md#20260919-forward-prepare-terminal-snapshot)。
目标收件箱终态读取与导入重放专项、未完成任务业务回归见[收件箱证据](verification-records.md#20260919-forward-inbox-terminal)。
范围和日志见[验证记录](verification-records.md#20260919-forward-terminal-query)。
上述历史批次未执行载荷压缩或完整房间迁移；schema 41 目标清理证据单列，不能外推后续源端、强杀或迁移证据。

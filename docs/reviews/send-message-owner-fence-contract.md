# 消息发送 owner 事务栅栏

范围：B27 房间 owner 迁移前置条件中的普通 SendMessage。涵盖普通群/大群单条、普通私聊、私聊冷批量/暖缓存快速追加，以及大群集合批量。完整迁移执行器和后台跨 owner 转发导入仍未闭环。

## 路由与能力边界

`V2OwnerValidatedRoomWriteStore` 的单条与集合方法必传所选 shard/epoch，没有丢弃 epoch 的默认实现。路由 wrapper 每次逻辑执行解析房间路由，包括只有一个物理 owner 的部署；分类查询也保留路由错误，不能通过分类直接成功。多逻辑 shard 可以共享一个物理批次，每行仍携带自己的 route。不同物理 owner 独立提交，不具备跨库原子性，失败重试必须保留 clientMessageID。

PostgreSQL 为每次调用创建私有的值副本，保存该批房间的 owner 约束；副本共享原有缓存、credit actor、shadow forwarder 和 workload pool 身份。约束只在该次调用内使用，没有可变的全局/actor 路由状态。同房间出现矛盾约束时直接拒绝。

## 事务锁顺序

所有实际 acceptance 事务在 operation advisory locks 后、业务查询和回执重放前，按房间 UUID 顺序取 `FOR NO KEY UPDATE` 并检查当前 `room_shard_id/owner_epoch`。缺失房间、错误 shard 或 epoch 均抛出 `V2RoomOwnerFenceError.ownerChanged`。锁持有到事务完成；等待期间已提交的 owner 变更会被读到。使用 NO KEY UPDATE 保留既有 append 与外键 KEY SHARE 的兼容性。

普通单条经过完整接受事务；私聊标准批量、快速追加、内部热房间路径分别在自己的事务中校验。大群 PostgreSQL 条件集合写原来在 CTE 中取 operation locks；带 owner 约束时先按同样顺序单独取锁、验证 owner，再执行原集合语句。不把集合写退化成逐条事务。原本不带约束的房间本地 primitive 保持原行为，部署切换时仍须排空旧入口。

同 owner 的消息转发先沿用 source/target 的既有 UUID 锁顺序，再检查目标 owner，避免先锁目标后锁来源引入反序。该行为不等于验证来源 owner 或后台 inbox 的完整迁移交接。

## 失败、缓存和容量

owner 不匹配使整个物理发送批次回滚；与群回执逐行结果不同，发送 API 保留原集合原子语义。网关映射为 UNAVAILABLE/retryable，不返回发送成功。没有新增透明重路由或主动缓存失效，调用方等待路由更新后重试。

缓存只决定执行形态。即使 direct fast append 缓存命中、持有可用 admission credit，也要在提交事务内验证 owner。失败经过原有 credit 归还路径；credit 池可能保留既有预取额度，不能把它解释为消息已接受。owner 栅栏额外增加一次按房间集合查询；大群优化路径还增加一次先行 operation-lock 查询，尚未做吞吐/延迟验收。

## 验证与剩余范围

真实双库负向回归已证明修复前普通群/大群单条与大群批量实际写入旧 owner：3 个场景、6 个失败断言。首次夹具编译遗漏 try、首轮扩展夹具未使用缓存路由的日志分别保留，不作为修复成功证据。最终 **162 项测试 / 13 套件**通过、退出 0。私聊混合 epoch 的冷/暖批量回滚且归还 in-flight credit，群消息旧缓存/错库/未知 shard/等锁 owner 更新，以及有/无栅栏两种发送与回执并发路径均已验证。最终结果与源码绑定见[证据清单](evidence/20260906-send-owner/manifest.json)。

Gateway 单库和多 owner 入口已使用上述能力。最终组装也修正了只登记 group shard 的遗漏：共享房间依赖按完整 `roomShardStorage` 登记，独立命名的 direct shard 可以进入所选物理 owner。同库仍复用缓存和额度 actor。该接线经过编译、路由测试及源代码组装检查，未运行生产 TLS 端到端验证。

后台 `importForwardExport`、来源读取、其他 worker 和房间日志读取仍需逐项处理。发送链路自身的 control 身份/策略读取及 post-commit 用户投影跨库交接仍为现有实现，不能用本批 owner 校验宣称无 profile 副本的完整发送已经成立。

迁移必须先 fence 旧 owner，再切 control route。仅更新控制路由无法阻止仍与旧本地 epoch 匹配的缓存请求。完整历史复制、核验、切换、故障恢复、生产 TLS/App 与性能验收仍开放。PostgreSQL 25、protocol 25、SQLite 173/5 和 47 项问题状态统计均不变。

后续补充：后台转发目标新接收、accepted 重试与最终 completed 发布现已补 owner 校验，见[导入 owner 合同](forward-import-owner-fence-contract.md)。已完成不可变回执仍可跨后续 epoch 变化重读；活跃工作及 post-commit 投影的完整迁移交接仍开放。

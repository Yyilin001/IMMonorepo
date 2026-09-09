# 后台转发导入的 owner 栅栏

对应 B04/B27。此批修复目标 owner 上新 inbox 入队、accepted 重试与 completed 发布的事务竞争；不代表完整房间迁移执行器已完成。

## 持久事实与活跃工作

`completed/rejected` 是不可变终态证据，后来的成员变化或 epoch 切换不撤销该事实。相同绑定的终态重复读取不触发新的目标消息、投影或完成更新，仍可用于源端终态确认及保留释放。

`accepted` 表示目标消息与 inbox 接受回执已提交，但后处理/完成标记尚未结束。它仍是活跃工作。旧 owner 不能仅凭已有 message receipt 绕过当前 owner 检查，继续执行后处理或发布 completed。owner 变化应抛出 `V2ForwardInboxError.ownerChanged`，保留 accepted；不改写为 rejected，也不伪造终态证据。

## 三处事务约束

1. **新 inbox 接收**：先匹配已有 immutable binding，再取目标房间的配额 advisory lock，再次检查已有绑定。只有新绑定才取房间 `FOR SHARE`，检查原 export 的目标 shard/epoch，并持锁完成 inbox/media mapping 插入。与更新 epoch 的事务相互排斥；在等锁期间发生的更新必须被看到。已有绑定不会持房间锁等待接受事务锁住的 inbox。
2. **接受与 accepted 重试**：保持 inbox → message operation → target room/admission 的既有锁序，在读取 message 的旧接受/拒绝回执前核对 export 的目标 owner。相同 owner 上的原结果恢复仍不受后来的退群、目标消息撤回或新部署文字上限影响。
3. **最终完成标记**：后处理返回后，重新锁定 inbox；已 completed 可直接返回不可变结果。若仍 accepted，则取得目标房间 `FOR NO KEY UPDATE` 并验证 shard/epoch，再提交 completed。不能在后处理期间 owner 已变化后发布新的终态。

共享 owner helper 现在自行持有 NO KEY UPDATE 锁，原接受/媒体路径已有更强房间锁时为同事务重复取得，不改变其 inbox → room → media-job 顺序。没有新 schema、授权来源、重签 envelope 或跨库事务。

## 后台恢复与边界

投递 worker 没有得到目标终态时，不写源端 receipt、不把任务标完成。owner 错误按原重试/暂停策略处理，未终态 export 继续占用源端配额与保留引用。重试保留原 export、目标 client UUID 与原消息接受回执。

已提交的用户投影后处理与房间完成标记仍是不同事务；本批保证旧 owner 不继续重放 accepted、也不能误发布完成，但不声称能原子撤销后处理期间已发生的用户投影。迁移需要显式复制/承接 accepted 工作与投影完成状态，不能简单改 envelope epoch，也不能把本地不存在当作可释放证据。

测试为验证同 owner 恢复会在一次性数据库中恢复原 epoch；这不是生产迁移策略。前台同物理库转发后续已补来源/目标 route 保留及各阶段事务检查，详见[前台转发合同](foreground-forward-owner-fence-contract.md)；其证据独立于本批后台 inbox。完整 owner 历史复制、切换、恢复授权、旧 envelope 承接、全局内容封禁、终态清理、真实 TLS/App 与性能验收仍开放。

## 证据

修复前真实双库负向回归：3 项测试、9 个参数/独立场景，共 18 issues。覆盖新接收等锁、两种群模式 accepted 重试，以及三种私聊投递模式在后处理期间更新 epoch。首次测试夹具的复杂条件闭包导致编译器无法生成诊断；改为显式 if/else 后才运行负向测试，该编译日志独立保留。

首轮 **7 项集成测试**通过，包括 19 个后台投递参数场景；最终 **176 项测试 / 14 套件**通过、退出 0，包含媒体导入、终态回执、运行时及此前三库回归。最终运行日志、源码哈希和检查脚本见[证据清单](evidence/20260906-forward-import-owner/manifest.json)。PostgreSQL 25、protocol 25、SQLite 173/5 与 47 项关闭状态统计不变。

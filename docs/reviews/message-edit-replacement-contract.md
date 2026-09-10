# 可授权完整编辑与版本缺口

对应 B03/B06/D07，承接[历史读取与扫描游标](message-mutation-read-contract.md)。当成员看到 rev1、离群错过 rev2、重入后有权看到 rev3 时，普通文本增量无法证明 rev3 足以替换本地状态。本批让新编辑明确携带完整状态，并统一服务端个人投影与 ClientKit 的处理；不补发离群期间内容。

## protocol 27 合同

`message.edited` 保留消息、房间、变更 room sequence、revision、text/entities 等头字段，新增 `replacement`：

| 字段 | 含义与校验 |
| --- | --- |
| `schema_version` | 必须为 1；未知、null 或不完整对象均失败，不能回退为文本增量 |
| `accepted_event_id` | 原接受事件 UUID；本地已有消息必须匹配该来源 |
| `accepted_membership_revision` | 接受记录中的原成员版本，非负；受众仍由服务端历史成员交集决定 |
| `state` | 完整当前消息值：原房间/时间线序号、发送者、原时间、正文、媒体及呈现、mention、entities、reply/forward 引用与当前 revision |

state 使用已有完整消息状态编码。数组必须明确存在，nullable 引用必须明确提供 null 或值；不能靠接受事件的历史默认值声称“完整”。消息/房间/revision/text/entities 必须与编辑头一致，变更序号大于原接受序号。编辑值不能是撤回状态。接受身份、变更事件身份、变更 room sequence 和消费流 cursor 各有独立含义。

writer 从已锁定消息的完整投影构造新状态，并核对其 origin 与不可变 completion 一致，再在原命令事务中保存事件与共享状态。先前修复的分发归属和历史受众交集继续适用。普通 accepted 不增加逐用户正文 fanout；编辑载荷包含完整状态，因此体积比文本 delta 大，但仍受现有正文、附件和 mention 上限约束，共享 fanout payload 仍按事件复用。

protocol 从 26 升至 27，生成物同步更新；PostgreSQL 25、SQLite 173/5 不变。旧客户端只认识文本增量，不能与新 writer 混用。已存在的旧事件不改写：没有 replacement 的历史编辑仍按 delta 检查连续版本，旧缺口积压需要单独恢复。

## 物化与顺序

- ClientKit 的 personal、room 和 preview 入口共用消息效果记录。完整编辑可跨合法版本缺口；自包含接受身份也允许 preview 先到时建立基线，保持原消息排序和创建时间。
- 已有消息先核对原接受身份。旧版本无副作用，同版本要求完整语义一致，新版本原子替换内容并安排搜索更新；不能仅比较新文本。
- 去重摘要包括原接受身份、成员版本、变更序号和完整状态摘要。相同事件 ID 携带不同状态必须失败；物化、效果 claim、派生任务与消费 cursor 共用 SQLite 事务。
- room 入口额外核对房间及实际事件序号。preview 不写 durable room cursor；已有终态不允许编辑复活，晚到的历史编辑只消费其流位置。
- 完整编辑先到后，晚到原 accepted 不得把客户端或服务端个人快照退回 rev1。服务端共享单条、共享批量和内联路径均需保留新状态，同时消费该 accepted 的个人流序号。
- accepted 批量路径保持一次 SQL 批次：按现有当前投影键检查接受身份，保留已存在的新版本，并将保留记录计入成功数；矛盾身份仍使整个 checkpoint 事务失败。新增消息继续按共享 state reference 写入。

## 剩余工作

这不是 B03 的整体关闭。其他内容读取、具体版本受众、media grant、完整 room baseline/directory、access epoch 与账号响应栅栏、独立无正文撤销及旧积压恢复仍开放。reaction、pin 和角色等对象的版本并不变成 message content revision。普通撤回与审核追溯撤销仍遵守各自合同，不能借完整编辑扩大历史受众。

日志、实际 owner 载荷、运行脚本与源码哈希见[本批验证证据](../../docs/reviews/verification-records.md#20260906-message-edit-replacement)。本机真实数据库载荷交给 ClientKit 的测试属于跨层载荷验证，不能冒充 App 到 TLS 网关的端到端验收。

## 本批验证结果

修复前：客户端 18 个场景产生 18 条失败，既拒绝合法跨版本，也忽略不完整 replacement；服务端原缺口测试产生 10 条失败。初版完整替换通过后，再加入 accepted 晚到，复现共享单条和内联的 rev3→rev1 回退，以及共享批量当前投影唯一约束失败，共 5 条问题。

最终 **288 项服务端 / 25 套件**通过，含六种 gap/late accepted 组合、12 个严格解码场景、accepted 批量正常与异常回滚、历史读取、受众结算、owner、转发和 10 万成员规划回归。**372 项 ClientKit / 58 套件**通过，含三个消费入口、缺基线、重开、完整字段去重、五种事务回滚、富内容保留和两份真实 owner/fanout 载荷。**182 项 App / 17 套件**模拟器回归通过。

过程中四次测试代码编译失败均保留原日志，并与行为负例区分：缺少测试 capabilityProfile、错误使用 accepted.eventID、宏内漏写 try，以及宏中包含抛错的短路表达式。最终通过不是跳过这些测试获得的。协议生成物与文档一致、schema readiness 引用和 47 项状态统计检查通过；隔离 PostgreSQL 清理记录随证据归档。

后续终态批次已补齐普通撤回跨版本、旧编辑晚到和 ClientKit 快照后重放，见[消息终态合同](message-terminal-projection-contract.md)；独立审核撤销和旧缺依赖积压仍开放。

# 编辑与房间权限变更的提交顺序

对应 B02。原问题是作者被移除、禁言、冻结或失去发言权限后，仍能编辑旧消息产生新内容。已有修复把 edit 接入 send 使用的 `v2AuthorizeContentWrite`；本批验证剩余的并发提交合同，不改授权接口或数据库 schema。

## 授权与锁

新 edit 在 room 行锁内读取冻结状态、当前成员、当前角色权限和有效禁言，再锁消息检查作者、撤回状态与内容 revision。该房间锁一直持有到内容、事件、分发计划和操作回执原子提交。

| 权限变化 | 当前持久入口 | 与 edit 的共同序列化点 |
| --- | --- | --- |
| 冻结 | trusted safety moderation | rooms FOR UPDATE |
| 禁言 | member moderation | rooms FOR UPDATE |
| 移除成员 | member moderation | rooms FOR UPDATE |
| 移除成员 | room membership command | rooms FOR UPDATE |
| 撤销角色发言权 | group role permissions command | prepare 中 rooms FOR UPDATE |
| 角色降级至无发言权角色 | group member role command | prepare 中 rooms FOR UPDATE |

权限先提交：后进入锁的 edit 读取新状态，拒绝操作，消息内容/revision、编辑回执和编辑事件保持不变。edit 先提交：编辑生效一次，随后的权限变更生效；下一次新 edit 被拒绝，已完成的原 operation 只返回原回执。

已完成操作在重新授权前按不可变输入检查重放，保留断线重试语义；不重新发布内容。撤回、审核删文等清理动作仍保留自己的授权合同，不机械要求 sendMessages。

## 并发验证方法

`editPolicyCommitOrdering` 使用真实 send/edit/moderation/membership/group capability service 和 PostgreSQL 事务，覆盖六种权限变更 × 两种分发模式 × 两种确定顺序，共 24 场景。

测试专用触发器在 room_sequence 更新处等待 advisory lock。先运行的真实服务此时已持有 room 行锁；测试从 pg_locks 获取该服务 backend PID，再启动另一服务，并用 pg_blocking_pids 确认后者确实等待前者。只有观察到真实锁依赖后才释放 gate，没有用固定睡眠猜测哪个操作先提交，也没有用裸 SQL 替代正在竞争的权限命令。轮询有期限，失败时释放 gate 并取消、等待已启动的任务后清理。

检查覆盖确定的成功/拒绝结果、房间序号、正文和 revision、编辑事件/操作回执数量、权限生效后的原操作重放、新 operation 拒绝，以及重试前后的副作用数量不变。既有 `editsRespectCurrentContentWriteAuthorization` 另外验证冻结/禁言/被移除/撤权/账号不活跃的顺序拒绝及完整回执相等；编辑/撤回竞争和 owner epoch 仍纳入回归。

## 范围边界

此合同针对房间内的当前内容发布授权，不证明全局账号停用、设备撤销、owner 完整迁移、独立内容撤销或生产多 Gateway 压测已完成；这些仍由 B03/B04/B27、D07/D08 和对应 E 项跟踪。当前 membership API 没有自助 leave 命令，测试覆盖真实存在的两个成员移除入口，不把尚无入口的自助退出宣称为已验证。

## 当前验收结果

修正降级夹具的初始 membership revision 后，24 个确定提交顺序场景全部通过；初轮使用 revision 0，角色命令在进入数据库前被拒绝，造成 4 个 gate 超时，原始日志单独保留，不作为生产并发缺陷。最终相关服务端回归 **91 项 / 6 套件**通过（47.676 秒），包含顺序授权拒绝、合法原操作重放、编辑/撤回竞争、owner 事务栅栏、成员/群策略和发送 credit 准入。

本批新增测试与合同记录，没有修改生产授权算法、接口或 schema，也未重跑未修改的 Core/ClientKit/App。源码、原始失败/最终日志和执行脚本见[本批证据](../../docs/reviews/verification-records.md#20260906-edit-policy-commit-ordering)。

B02 的原始缺陷、共享策略、确定并发顺序及幂等重放要求已有当前证据，可标为已验证；47 项仍有 33 项未达到完整关闭条件。此关闭结论不扩大到上述其他问题或生产就绪。

# 历史邀请创建重试的目录绑定合同（B27 兼容补充）

2026-09-06。处理独立 room owner 已保存旧链接、control 尚无该链接目录的创建重试。B27 仍为实施中；本修复不代替分页批量导入，也不提供矛盾绑定的强制改写入口。

## 原因与修复

创建服务每次调用都会生成候选 invite ID 和本次创建时间。此前 owner 预检查虽然识别到同一 actor/operation 的已提交链接，但不返回原绑定；control 因而把本次候选 ID/时间写成 prepared intent。随后 owner 幂等重放原链接，协调器发现 ID 不同，报 ownerResultMismatch，后台恢复也无法改变不可变目录。

现在 owner 预检查在 room 共享锁和当前 epoch 栅栏内验证原操作的 room、digest、请求寿命及最大使用次数，并返回已存在的链接。路由存储沿用其 invite ID、createdAt 和 expiresAt 构建目录候选，保留本次 evaluatedAt。owner 没有原操作时，继续使用本次候选，并执行当前创建权限校验。

预检查不代替最终 owner 事务。目录 prepare 完成后仍重新解析持久路由，执行 owner epoch 检查及原操作匹配，协调器验证 owner 结果后才 finalize。没有跨 owner/control 长事务，也不会查询其他 owner 猜测位置。

## 重试与冲突边界

- 已提交的 active、expired、revoked、exhausted 链接都沿用原绑定；不延长有效期、不清除撤销、不重置使用次数。
- 已存在创建操作的精确重放可以在原创建人已停用后完成目录，因为没有新增链接或成员；新创建仍必须经过当前身份与角色授权。
- digest、请求寿命或最大使用次数变化，在分配目录前拒绝。错误 owner epoch 同样先拒绝。
- 并发重试继续依赖目录唯一约束和 owner 操作锁，仅产生一个绑定与一个 owner 链接。
- 发布失败时留下正确的 prepared intent，现有持久恢复 worker 按原 operation 完成发布和任务记账。
- 如果此前已写入不同 ID/时间的 prepared intent，或 digest/invite ID 已属于另一个目录操作，拒绝并保留原证据。后台对 ownerResultMismatch 持久暂停为 conflicting_evidence；普通重试不会自动覆盖错误绑定。
- 目录 ready 只证明定位关系。预览和提交继续检查 owner 当前有效性；已过期、已撤销链接不会因补目录重新可用。

## 验证与后续

未修复版本的初版回归在两种分发模式均以 ownerResultMismatch 失败。修复后新增 2 项测试覆盖普通群/大群各四种链接状态、每种十次并发重试、完整服务层原 token/日期返回、终态预览限制、发布失败恢复、epoch 拒绝及三类绑定冲突。最终 33 项测试 / 3 套件通过，包含三库 owner/control 回归和七条历史迁移链。Account 可执行目标已编译；没有执行真实 TLS 客户端、进程 kill -9 或生产部署。

本批不修改 PostgreSQL schema 24、protocol 25 或 SQLite 173/5。验证记录见[本批证据](../../docs/reviews/verification-records.md#20260906-legacy-invite-retry)。后续 schema 25 已接通独立 owner 旧链接的[显式分页导入与不可变审计](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/group-invite-directory-import-contract.md)；已有矛盾绑定的调查与处置、完整房间历史迁移和 B23 全局申请配额继续开放。

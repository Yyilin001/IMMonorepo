# 资料版本与个人投影整数边界

对应 B01。延续消息/成员命令的数值约束，本批处理资料版本、真实 PostgreSQL 绑定以及个人投影尾序号；不改 protocol 27、PostgreSQL 25 或 SQLite 173/5。

## 资料版本与 HTTP 输入

`V2ProfileRevision` 的合法范围现在是 `1...Int64.max`，构造与 RawRepresentable Codable 解码共用同一校验。合法 JSON 数字编码不变，类型提供已验证的 signedValue 供持久化使用。0、负数、小数、Int64 上界加一与 UInt64 最大值不能通过对应入口。

备注和群昵称 HTTP 接口不再使用 flatMap 将非法 revision 悄悄变成 nil。未提供版本仍表示原合同中的无当前值；显式提供非法值则返回 400，不能调用存储层。存储适配器也不再将不能表示的 expected revision 当作省略值。

备注、群昵称及公开资料的 expected/result revision 均以 Int64 绑定 PostgreSQL。此前直接绑定 UInt64 会触发 Debug PostgresNIO 的致命断言，合法最大值的无变化写入也无法完成。本批不通过切换 Release 或截断数值绕开检查。

## 递增与重放

备注/昵称只在内容实际变化时递增；公开资料同时检查内容版本和可见性版本。普通版本、最大值减一到最大值、最大值无变化操作及已完成操作重放均保留精确结果。任一需要递增的计数已达到上限时，沿用现有存储领域错误 `corruptPersistenceState`，事务不新增内容、操作回执或 outbox。本批不引入新的 HTTP 错误码或“计数耗尽后继续写入”策略。

## 投影尾序号

个人投影 worker 以最后成功应用的 Int64 序号维护进度，逐条验证下一条是否连续，不在消费完最大序号后再构造 max+1。共享批量、共享单条和 inline 路径都可应用 `Int64.max`，提交该 checkpoint、移除已追平 ready 行并在下一轮返回无工作。异常间隙仍失败，不采用 clamping 或跳过事件。

批量时间戳微秒转换也改用 `Int64(exactly:)`；Double 对 Int64.max 的舍入不能通过比较后再触发整数转换 trap。无法表示时退出批量优化候选，保留原单条处理入口；其他时间转换仍需独立审计。

## 验证与剩余范围

Core 负例证明构造/JSON 解码会接受两个超界值。独立 PostgreSQL 负例进程在昵称 expected revision 绑定以及最大序号投影处分别以 signal 5 退出；前者同时有两个错误的关系表夹具字段，已修正，不能用它们证明 alias 行为。最终测试补齐真实备注/昵称的普通与极值写入、公开资料两个计数、事务回滚、no-op 与重放。

初轮修复的 12 个备注/昵称、8 个公开资料、3 个投影场景通过，但 HTTP 测试发现 invalid-to-nil，最终修复后覆盖两个入口的 6 个拒绝场景。共享 Core 改动另经 ClientKit 全套及 App 模拟器测试；本批未修改客户端实现。

最终服务端扩展回归 **316 项 / 30 套件**通过（335.174 秒）；Core **87 项 / 27 套件**、ClientKit **374 项 / 58 套件**与 App **182 项 / 17 套件**全部通过。服务端覆盖本批边界及既有媒体、受众、owner、分发、转发和快照恢复回归，不代表完整服务端全套。

最终原始日志、脚本、源码哈希见[本批证据](../../docs/reviews/verification-records.md#20260906-profile-projection-boundaries)。B01 仍需对其他恢复 DTO、worker 计数/递增和时间转换完成逐入口审计；本批证据不支持关闭整个 B01。其他 46 个问题范围保持不变。模拟器/macOS Debug 回归不替代生产 Linux、真机、完整 TLS 与发布验收。

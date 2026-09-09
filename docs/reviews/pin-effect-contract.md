# B06 客户端置顶效果与迁移

更新：2026-09-06。ClientKit 已统一个人同步、前台房间预览、持久房间日志和 snapshot shadow 的置顶消费规则；历史权威恢复与完整成员代次边界仍开放。

## 身份、版本和负状态

`V2LocalPinnedMessageEffect` 校验 room/message/可选 actor UUID、事件类型、布尔状态、非负毫秒时间及可选正 Int64 源序号。正文中的源序号必须与房间 envelope 一致；旧正文缺字段时，可以使用可信房间 envelope 的序号，个人游标不能补位。规范 SHA-256 摘要包含规范化身份、置顶值、actor 和时间，源序号单独保存，以允许旧事实后来补齐这项证据。

`v2_pin_effects` 保存 sourceEventID/room 对应的 message、摘要和可选源序号。claim、可见状态和消费游标在同一事务提交。同来源改消息/内容/已知序号拒绝；相同对象源版本不同来源拒绝；已知旧源版本不能覆盖新版本。取消置顶保存明确的 false 行及版本，不删除顺序屏障。新增内部摘要表不触发 UI 全量刷新。

缺序号的不同旧事实在都未知时仍保留兼容的首次到达处理，但重复已知来源不能回滚后来的未知观察。未知来源不能覆盖已知源版本。旧 receipt 后续通过房间流获得真实源序号时重新比较，而不是仅因为已有 receipt 就跳过；来源发生顺序可能在这一步得到纠正。这不等于两条永远缺证据的旧事实已恢复正确历史。

## 快照和授权清理

个人快照带有的置顶状态及覆盖范围内的旧 receipts 一起切换。仍获授权的 hybrid 房间按源版本合并 live/shadow，保留较新的本地房间事实及其负状态；两者都未知时优先保留 incoming 快照观察。已知 receipt 可以补齐同来源快照的缺失序号，避免降级后再被未知旧事实覆盖。

快照来源与仍保留的 live receipt 冲突时拒绝准备，即使原消息不出现在新 bank 中。移除的房间或对象不额外携带其历史 receipts；本人退群清理包含新表。退群后任意迟到房间页、重新入群后的历史授权及撤回与置顶组合，仍需后续完整 membership/连接代次合同，不能从本批清理测试推断全部安全。

## 受控旧库迁移

追加 `orderPinnedMessageEffects`，主库 172 个对象，搜索库 5 个对象；主库指纹 `0xdd0136fa348a4c95`。旧置顶表的 room/message UUID 规范化，值和更新时间保留，可能来自个人游标的旧 room_sequence 丢弃为 NULL；不伪造来源或摘要。大小写重复对象若值不一致会拒绝迁移。

从保留的个人/房间日志回填来源证据，仅处理仍有置顶投影的对象，不恢复已清除房间或消息。可信房间 envelope 可为旧正文补源序号；缺证据历史不覆盖已观察到的未知值。旧 staging/prepared snapshot 丢弃暂存导入后从同一不可变 artifact 重导入，live bank、pending reset 和 outbox 保留。旧快照自身已经缺少的取消事实仍需权威基线恢复，本批不制造这类事实。

## 验证边界

ClientKit 最终 339 项 / 53 套件通过。覆盖两种跨流顺序、不同消息独立排序、重启、非法字段/房间 envelope、日志清理后重复、源序号补齐、普通/hybrid 快照、来源重用拒绝、快照元数据保留与移除、两种 staging 阶段迁移及本人退群清理。App 在 iPhone 17 / iOS 26.2 Debug、仅 IMAppTests、关闭签名下 **176 项 / 17 套件**通过。七份失败/成功日志与七份最终源码哈希见[置顶效果证据](evidence/20260906-pin-effects/manifest.json)。diff、协议文档及 schema relation coverage 检查通过，所有测试会话终态已确认；本批未启动 PostgreSQL。

protocol 25 与 PostgreSQL 18 未改。服务端置顶快照证据见[上一批合同](pin-snapshot-contract.md)。仍未完成置顶权威基线与丢失历史修复、writer/worker 一致切换、完整 receipts 保留/GC、成员角色及广义授权代次组合；没有部署或真实 App–TLS、Linux、负载、无障碍人工验收。B06 继续实施中。

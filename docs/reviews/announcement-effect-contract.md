# B06 客户端公告效果合同

更新：2026-09-06。公告的个人流、前台预览、持久房间流和 snapshot shadow 现共用一个版本化 reducer。B06 仍为实施中，尚未部署。

## 排序与幂等

`V2LocalAnnouncementEffect` 在 ClientKit 边界解析 UUID room/actor、正数 Int64 revision、非负时间及至多 4096 UTF-8 字节正文。公告 revision 决定新旧；个人同步 sequence 只用于该流的消费位置。旧 payload 可以没有 room_sequence，此时保存 NULL；房间入口若提供源序号，必须与 envelope 一致，并验证 payload room 与入口 room 一致。

规范摘要绑定 room、revision、正文、时间和可选 actor，使用解析后的 ID，而非 JSON 原文。`v2_announcement_effects` 以 sourceEventID/room 保存摘要、revision 和可选源序号。receipt、投影和当前流 cursor 在同一 SQLite 事务中提交。

- 同源同事实重复消费不再重写可见公告；已知旧 revision 只能推进所在流，不覆盖新状态。
- 同源不同事实、同 revision 不同事实或不同 sourceEventID，均拒绝并回滚本次事务。
- 同一旧事实后来带上源序号时可以补齐 NULL；之后不同的显式源序号会被拒绝，缺字段的再次重放不会抹掉已知序号。
- 空正文仍保存 revision 和证据，不会让迟到的旧公告恢复出来。它属于同步事实兼容，未放宽提交新公告的命令规则。

## 迁移、快照和授权

SQLite `orderAnnouncementEffects` 是追加迁移，主库 schema contract 从 166 增至 **167** 个对象，搜索库仍为 **5**。公告表增加可空来源与摘要，将 room_sequence 改为可空；旧值可能是个人游标，迁移不信任它。迁移规范化 room ID、保留已知正文/revision/时间，从仍保留的个人和房间事件回填身份。房间日志回填同样校验实际 envelope 的 room/sequence。

没有存续公告行的历史事件不参与回填，避免用退群后残留的个人日志恢复已清除的房间状态。无日志的旧公告保留可见值和 revision，来源保持未知；不能声称已经重建其历史 sourceEventID。随后相同版本必须匹配原可见值才能补齐来源。无法自洽的同版本历史冲突会使迁移事务失败，不选择任意正文。

公告和效果记录参与 snapshot bank 原子切换。个人快照只保留与新基线同 room、且不超过其 revision 的既有 receipts；同 revision 必须匹配快照事实。独立房间日志的公告和 receipts 仅为新基线仍授权的房间保留。旧版暂存或已准备快照没有来源证明，升级保留 live bank、outbox、pending reset，清空暂存导入后从同一不可变 artifact 重新导入。

效果表属于内部元数据，不触发全量 UI 刷新；公告可见表沿用原有通知范围。

## 验证与限制

失败与成功日志及最终源码 SHA-256 见[持久验证证据](evidence/20260906-announcement-effects/manifest.json)。ClientKit 新测试覆盖两种跨流顺序、乱序、重启、同版本/同身份冲突、NULL 源序号补齐、UUID/数值/长度校验、空公告快照、旧库和两种暂存阶段迁移、待发命令保留，以及不恢复已清除公告；原混合房间快照测试增加公告与 receipt 的保留断言。

协议保持 **24**，PostgreSQL schema 保持 **18**，此次未修改服务端。客户端各角色空权限与独立 revision、置顶负状态、成员离开/重入、完整 receipt 保留窗口和代次恢复仍未关闭。此次迁移不凭空重建已丢失的历史身份，也不替代 B03 缺失依赖恢复或独立房间日志授权基线。

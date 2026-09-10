# 客户端时间戳与禁言投影边界

对应 B01，延续[服务端与媒体时间戳检查](timestamp-integer-boundaries.md)。本批确认并修复了客户端实际可复现的整数转换崩溃，B01 的其他入口仍需审计。

## 崩溃与修复

一个合法的 moderation 同步事件携带 `mute_until_ms = Int64.max` 时，客户端能够解析并将日期保存到 SQLite。旧读取入口随后构造临时 JSON，将 REAL 日期乘以 1000 再转回 Int64；Double 对该边界向上舍入，导致 `Double value cannot be converted to Int64 ... greater than Int64.max`，整个测试进程退出。

现在 SQLite 读取直接构造不可变禁言投影，保留数据库已有日期，不再经过 JSON 和第二次毫秒转换；仍检查序号、日期有限性、来源范围及禁言晚于创建时间。最大合法 wire 时间戳可正常读回并在关闭、重开数据库后保持相同日期。此处不声称 Date/SQLite REAL 提供任意 Int64 毫秒的精确整数保真。

| 入口 | 现在的边界 |
| --- | --- |
| 禁言 outbox 入队 | 先对截断到毫秒的值执行 `Int64(exactly:)`；NaN、无穷及越界值报 invalidMuteExpiry，不写入 pending 命令 |
| protobuf 禁言请求 | 发送前精确转换并验证正值；失败不进入实际 wire |
| 会话免打扰命令 | Core 构造拒绝无法编码为正 Int64 毫秒的日期，零值继续保留给“未设置”；protobuf 序列化也使用精确检查 |
| heartbeat | 拒绝非有限和超出 UInt64 范围的日期；保留原有毫秒截断和纪元前有限值归零语义，合法的大 UInt64 时间仍可发送 |
| SQLite 禁言投影读取 | 直接还原已持久化的日期和类型化标识，不再反向生成 wire JSON |

没有修改有效日期的既有毫秒截断规则，也没有钳制越界禁言时间。没有更改协议或持久化 schema：Protocol 27、PostgreSQL 25、SQLite 173/5 保持不变。

## 验证

- 修复前的独立客户端进程在真实 SQLite 读回时发生 fatal error，原始失败日志已保留。
- 27 项 / 4 套件定向回归通过（0.133 秒），覆盖最大值读回/重开、非法值无写库/无网络副作用、心跳上下界和原有禁言重试/协议行为。
- Core 全套 91 项 / 29 套件通过（0.006 秒）。新增会话命令测试覆盖 NaN、正负无穷、舍入后的 Int64 上下界、零/负值、亚毫秒零值，以及有效/未设置日期。
- ClientKit 报告 392 项 / 61 套件（4.201 秒）；四项 opt-in 真实服务测试跳过，实际执行 388 项离线回归全部通过。
- iPhone 17 / iOS 26.2 App 单元回归 183 项 / 17 套件通过（4.816 秒）；服务端 Gateway 领域路由与会话 49 项 / 2 套件通过（0.019 秒）。本批没有新跑 UI 或真实 Gateway 端到端测试。

成功用例关闭并移除自己的临时 SQLite 目录。负向进程因 fatal error 无法执行 defer，已单独移除其确切目录中的主库、搜索库及 WAL/SHM；未清理其他数据库。脚本、原始日志与源码摘要见[本批证据](../../docs/reviews/verification-records.md#20260906-client-timestamp-boundaries)。

## 审计排除项与剩余范围

本轮曾怀疑服务端快照构建器在累加条数/字节之前未检查 Int64 上限。补查 canonical schema 后，确认 `sync_snapshot_artifacts` 的 CHECK 已将条数限制为 1,000,000、字节限制为 268,435,456、页索引限制为 4096，且每次追加也有有界页大小。因此当前 schema 下该处不是已证实的溢出缺陷，本批没有移除约束来制造负例，也没有修改构建器。

其余恢复 DTO、worker 递增和其他日期转换仍需逐入口核对类型、schema 与调用链。B01 保持实施中；问题总表仍为 15 项已验证、32 项开放。本批本地日志不代表生产 Linux、真实设备锁屏或完整恢复验收，E08 的干净 checkout 证据交付仍开放。

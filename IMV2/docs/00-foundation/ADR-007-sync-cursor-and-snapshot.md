# ADR-007：同步 cursor、snapshot reset 与多设备收敛

状态：已接受  
日期：2026-07-23  
所有者：客户端与同步负责人

## 背景与决定

每个用户同步日志具有单调、无间隙 `user_sync_seq`；每个 device 保存独立 ACK
cursor。过期/失效 cursor 通过具有 generation fence 的 snapshot reset 恢复：服务端
创建 manifest/pages，客户端 staged apply；服务端先以匹配 snapshot ACK 建立新 cursor，
客户端随后才原子激活 live projection。ACK 的精确重放在服务端幂等，即使下一代 reset
已经 staged 也不得覆盖新 fence；客户端在 ACK 前持久化 manifest、shadow 和 reset 前游标，
从而分别恢复 ACK 后崩溃与过期 reset 回退。
客户端以单 SQLite 事务持久化投影与下一 token/watermark。

## 备选方案

- 全量重拉：放大数据库和网络成本，无法表达未接受本地意图；
- 无 generation 的 snapshot：旧 ACK 可错误跨 reset；
- 增量 cursor + fenced snapshot：允许重试、断线和多设备独立恢复。

## 后果、回滚与复审

snapshot/page 能力必须绑定认证 device、generation、页号、digest 与过期时间；
未 ACK 的 staged 数据不能替换 ready 投影；服务端已 ACK、客户端未激活时必须优先重放
该 ACK，不能用旧 token 发起增量 pull。更改 token 保留、snapshot 格式、
capability profile 或多设备规则时复审。

设备身份与吊销事实属于控制面，不从 user shard 的 `auth_devices` 镜像推断。手工
reset 先向控制面 authority 校验 active device；吊销事件由独立集群 durable cursor
重放，并在 current owner/retained fallback 写入单调 tombstone 后删除 device-owned
capability。同步、reset 与 cleaner 对同一 user/device 使用一致的 advisory transaction
lock，避免已认证且在途的请求在异步清理后重新创建 cursor。

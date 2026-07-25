# ADR-007：同步 cursor、snapshot reset 与多设备收敛

状态：已接受  
日期：2026-07-23  
所有者：客户端与同步负责人

## 背景与决定

每个用户同步日志具有单调、无间隙 `user_sync_seq`；每个 device 保存独立 ACK
cursor。过期/失效 cursor 通过具有 generation fence 的 snapshot reset 恢复：服务端
创建 manifest/pages，客户端 staged apply，只有匹配 snapshot ACK 才建立新 cursor。
客户端以单 SQLite 事务持久化投影与下一 token/watermark。

## 备选方案

- 全量重拉：放大数据库和网络成本，无法表达未接受本地意图；
- 无 generation 的 snapshot：旧 ACK 可错误跨 reset；
- 增量 cursor + fenced snapshot：允许重试、断线和多设备独立恢复。

## 后果、回滚与复审

snapshot/page 能力必须绑定认证 device、generation、页号、digest 与过期时间；
未 ACK 的 staged 数据不能替换 ready 投影。更改 token 保留、snapshot 格式、
capability profile 或多设备规则时复审。

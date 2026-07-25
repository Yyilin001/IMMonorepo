# ADR-009：认证、设备撤销、本地存储与日志脱敏

状态：部分待批准  
日期：2026-07-23  
所有者：安全与客户端负责人

## 背景与决定

V2 已选择短期、device-bound access token 与 refresh rotation/reuse revocation；
认证网关验证 token subject/device/revocation。客户端 refresh credential 使用
device-only Keychain，SQLite/WAL/SHM/outbox/media cache 作为设备本地可重建状态，
不得进入备份或迁移。日志/Push 禁止原始凭据、正文和附件 URL。

媒体上传授权、扫描、对象下载 URL、保留/导出尚依赖 ADR-002，因此本 ADR 不
批准媒体访问模型。

## 备选方案与后果

- 将 refresh token 存 SQLite/UserDefaults：无法满足设备保护，拒绝采用；
- 允许备份未接受 outbox：需要独立加密/冲突恢复模型，当前拒绝；
- 以对象 URL 作为授权：不可撤销且会泄露，拒绝采用。

设备凭据模型、Keychain 可用性区分、备份排除和日志红线必须有单元/集成测试。
媒体策略批准、E2EE、认证 provider 或数据保留策略变化时复审。

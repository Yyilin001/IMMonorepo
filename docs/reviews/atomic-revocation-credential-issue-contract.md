# 登录事务原子交付撤销凭据

日期：2026-09-07。B08 仍为实施中。本批在已完成的[撤销 HTTP 入口](device-revocation-capability-http-contract.md)基础上接通注册、刷新和凭据持久化。App 的独立退出 checkpoint 与离线补偿执行器仍待实现。

## 注册事务

设备注册在既有 account-state 事务锁内生成独立 256 位撤销凭据。设备行、撤销摘要及会话时间绑定、access/refresh 状态、加密响应重放和注册配额同时提交。任何一步失败都回滚；不能先创建会话，再在另一个请求中申请撤销凭据。

注册响应在原字段外必需携带 `revocationCredential` 和 `revocationCredentialExpiresAtMilliseconds`。同注册 operation 的重放返回同一组完整凭据，包含相同撤销凭据和期限。撤销凭据只在同一有限期重放结果中保留加密明文，长期兑换依赖独立摘要表。

## 刷新

刷新请求必须携带原 `revocationCredential`，但不能提供期限或目标清理指令。服务端仍要求原 refresh 凭据证明；撤销凭据不能单独刷新。服务端在账号锁内复核撤销摘要、user/device 及会话创建/绝对截止的绑定，然后执行原刷新族轮换与重放。

每次成功响应返回同一撤销凭据和数据库保存的原期限。错配撤销证明会被拒绝，且不旋转或撤销仍有效的设备。撤销期限仍为原会话绝对截止加 10 分钟；刷新不会延长它。

## ClientKit 与 Keychain

`V2AuthCredentials` 中撤销凭据和期限均为必填字段，与 access/refresh 及 pending refresh operation 一起编码进原单一 Keychain item。登记 finalizer 仍在完整凭据持久化成功后执行。缺失撤销字段的记录无法被解码成完整会话。

刷新请求取自持久 pending record。保存刷新响应前同时比较 user/device、撤销凭据及撤销期限；改变证明或期限的响应作为 malformed response 拒绝，保留原记录和 pending operation，不借此删除账号状态。HTTP 传输负责两个新必填字段的解码。

测试用旧构造器仅存在于各测试 target 的 `RevocationCredentialFixture.swift`，用于现有 fake factories 的显式合成值；生产 initializer 没有可选字段或测试默认值。真实 PostgreSQL、在线 HTTP 和 App 登录使用真实签发的独立能力。

## Schema 28 与开发数据迁移

新环境唯一合同为 `im-v2-current-28`。加密重放表增加必填 encrypted revocation credential 和有限期时间；Swift/SQL 启动门禁验证字段和约束。

受控 27→28 开发迁移要求先停止凭据写入：凡已存在 access、refresh 或 credential replay 的设备，均终止旧会话、撤销全部 token、禁用 Push、追加幂等事件并移除旧不完整重放。没有签发过凭据的预建设备可以保留。迁移不补造 capability；旧已签发设备不能复活，重新登录必须创建新设备身份。这不是生产旧客户端兼容方案。

短期 replay GC 会删除包含 capability 的加密重放行；独立摘要与原会话绑定继续支持期限内撤销。摘要/设备长期清理仍受 B15 保留合同约束，不能提前复用设备标识。

## 验证边界

已完成验证：ClientKit 报告 423 项 / 66 套件（418 实际执行、5 在线跳过）；App 单元报告 193 项 / 19 套件（192 实际执行、1 在线跳过）；服务端单元 10 项 / 2 套件、真实 PostgreSQL 21 项 / 1 套件通过。独立迁移和字段缺失反向门禁通过。完整真实链路通过 5 项 HTTPS、2 项 App UI 和 1 项 headless；随后增加真实 capability 兑换，定向 HTTPS 5 项通过，确认 204×3、409×1、401×1 及数据库 7|3|0|0|3。

本批证据见 [manifest](evidence/20260907-atomic-revocation-issue/manifest.json)，保留失败和修正过程。需要分别核对原子回滚、完整重放、错配证明、刷新不变、短期重放清理后兑换、迁移正反向门禁，以及真实 App/Keychain/HTTPS 链路；不要用单元测试代替在线验收。

完整退出还需要：从旧认证 epoch 原子交接 capability 到独立持久记录、先清理本地再有界重试、401/410 与撤销确认区分、锁屏/杀进程及 A→B→A 竞态。B08 未关闭。

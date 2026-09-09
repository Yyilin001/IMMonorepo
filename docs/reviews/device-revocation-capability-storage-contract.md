# 仅撤销凭据：服务端存储与兑换合同

日期：2026-09-07。对应 B08，状态仍为实施中。

## 本批边界

本批提供 Core 值类型、服务端事务内签发原语、摘要存储和兑换服务。**尚未在登录/刷新响应中签发，也未开放 HTTP 兑换入口或接入 ClientKit/App。当前用户登录仍不会得到此凭据，离线退出补偿尚不可用。** 不将这批存储验证记作 B08 闭环。

## 凭据与用途

- 独立 256 位系统随机数，格式 `imv2-revoke-v1.` 加 43 个无 padding 的规范 base64url 字符。输入长度、字母表和尾部未使用位均校验。
- 普通字符串、反射与 dump 隐藏凭据；显式 `rawValue` 和 Codable 仅供受保护的传输/持久化边界使用。
- `device_revocation_capabilities` 仅保存 SHA-256 摘要及绑定元数据，不保存明文，也不依赖 access/refresh HMAC 密钥或短期响应重放加密密钥。
- 凭据绑定 user、device、会话创建时间及原绝对到期时间。到期为原会话绝对截止加固定 10 分钟收尾时间；兑换时重新读取绑定，不能通过 body 指定目标。
- 当前普通 Gateway/Account 认证及刷新均查各自的令牌表。撤销凭据不会被写入这些表；随机未知刷新值按既有规则拒绝且不触发撤销。

## 事务与重试

内部签发原语只接受事务 SQL 连接，先取得 credential issue 使用的 account-state 锁，再读取/锁住活动设备。调用方必须把返回明文放进同事务的有限期加密注册重放，才能提交并交付客户端。此调用方接线仍待实现；不能以登录后再申请凭据替代初始原子交付。

兑换先通过唯一摘要找出账号，再取得 account-state advisory lock，然后重新读取并锁定设备与凭据。时钟检查发生在等锁之后。普通账号停用、访问令牌失效或 HMAC key 轮换不妨碍旧会话清理。

兑换复用设备撤销事务，失效全部 access/refresh、禁用 Push、写一次 durable revocation event，并写操作 journal。已经撤销的设备仍补齐清理，保留第一次 revoked_at。数据库失败回滚全部变化；同 operation 并发只有一次 applied，其余 idempotent。相同账号的 operation 已属于另一目标时返回 conflict。

已知凭据到期时返回 expired，不产生新写入；未知或绑定不符返回 invalidCredential。expired 并不代表本次已确认执行远端撤销，后续客户端 checkpoint 必须区分“服务端已撤销”和“旧会话期限已结束”。

## Schema 与迁移

新环境唯一合同为 PostgreSQL **27**。Swift 启动门禁与独立 SQL 门禁检查凭据表字段、主键、唯一摘要、会话外键、摘要格式及精确的期限约束。受控 26→27 迁移仅增加此存储，不为旧凭据伪造明文 capability，也不改变现有设备状态。后续完整签发接线必须明确清理开发旧会话的策略；本批不引入生产兼容路径。

## 后续验收

1. 注册事务签发、短期加密重放、刷新保持原凭据与期限，响应丢失不会产生另一份 capability。
2. 受 trusted-edge 和独立客户端限流保护的 HTTP 兑换入口；请求体不接受目标账号/设备。
3. ClientKit 将 capability 与会话凭据原子保存；App 退出先将它交接给独立的小型持久清理记录。
4. A→B→A、断网、锁屏、杀进程、迟到响应与新账号登录的真实组合验证；失败不依赖新账号凭据。
5. 保留与清理策略不能让未到期 capability 对应的设备标识被复用。

本批执行证据见 [manifest](evidence/20260907-revocation-capability-storage/manifest.json)。

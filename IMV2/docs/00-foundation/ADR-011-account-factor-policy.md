# ADR-011：账户因子与设备绑定断言

## 状态

Accepted — 2026-07-24

## 决策

- Passkey 是首选注册和登录因子；iOS 使用 AuthenticationServices，服务端按
  WebAuthn Relying Party 规则验证挑战、origin/RP ID、签名、user verification
  与签名计数器。
- 密码仅是恢复/兜底因子。最少 12 个 UTF-8 字节，最多 1024 字节；服务端只
  保存由专用慢哈希器生成的 bcrypt verifier，且在 worker pool 上计算。
- 两种因子均只产出短期、设备 ID 绑定的 `accountAssertion`。客户端不持久化
  该断言；`POST /v2/device-credentials` 仅在断言的 device ID 与请求一致时
  才签发 V2 access/refresh credential。
- 账户断言不是长期 session，也不能替代 V2 refresh credential。它的最长 TTL
  为五分钟，当前内建 HMAC issuer 默认 90 秒。
- 未知账户走同成本 dummy bcrypt verifier，避免把账户存在性暴露为明显的
  密码校验时间差。
- 密码失败计数以规范化 account handle 为键持久化在 PostgreSQL；所有 account
  service 副本共享同一窗口与锁定状态。锁定响应必须是无缓存的 `429`，并携带
  由该持久状态计算的 `Retry-After`。窗口、失败阈值和锁定时间是显式部署输入，
  不提供代码默认值。
- 密码注册、成功断言和已执行 bcrypt 的拒绝断言必须与对应的账户或失败窗口
  变更在同一 PostgreSQL 事务中记录审计事实。审计只保存结果、时间、请求的
  device ID 与已知的 user ID；不得保存 account handle、密码、密码 hash、断言
  或网络转发头。已锁定请求不额外写入逐请求审计，避免攻击流量放大审计存储。
- 人工禁用是不可在此接口恢复的账户级 credential fence：独立、loopback-only
  operator 凭据一次只能禁用一个 UUID 用户，理由只能取封闭原因码。事务先持有与
  credential 签发/刷新相同的账户状态锁，再记录操作 ID、operator principal、
  原因和时间，撤销该用户全部设备的 access/refresh credential，并为每台设备写入
  gateway 撤销事件。已禁用用户的密码查询与新 credential 签发均失败；旧的短期
  assertion 也不能在禁用后换取新凭据。

## 后果

- App 的 Passkey 授权结果只包含 WebAuthn assertion artifacts；私钥及
  Face ID / Touch ID 的本地认证结果不离开系统 authenticator。
- 密码、WebAuthn assertion、accountAssertion、access token 与 refresh
  credential 均不得写日志、埋点、测试 fixture 或 UserDefaults。
- 实际部署必须提供可审计的 WebAuthn 验证器和挑战一次性存储；在此之前
  不得把 Passkey 登录入口暴露为生产可用。
- 公网 HTTPS 边缘仍必须在可信客户端/IP 维度实施独立限流，并为现有密码审计
  确定访问权限、保留和账户恢复政策。账户禁用的实际 bastion/mTLS 审批、独立
  secret 管理和演练记录也是发布前证据；不能用可伪造的转发头代替边缘身份。
- SSO 可以以后作为另一种账户因子接入，但不作为首发唯一入口。

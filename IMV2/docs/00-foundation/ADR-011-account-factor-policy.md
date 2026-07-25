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

## 后果

- App 的 Passkey 授权结果只包含 WebAuthn assertion artifacts；私钥及
  Face ID / Touch ID 的本地认证结果不离开系统 authenticator。
- 密码、WebAuthn assertion、accountAssertion、access token 与 refresh
  credential 均不得写日志、埋点、测试 fixture 或 UserDefaults。
- 实际部署必须提供可审计的 WebAuthn 验证器和挑战一次性存储；在此之前
  不得把 Passkey 登录入口暴露为生产可用。
- SSO 可以以后作为另一种账户因子接入，但不作为首发唯一入口。

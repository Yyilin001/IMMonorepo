# ADR-008：移动生命周期与 Push wake

状态：待客户端、通知与安全负责人批准  
日期：2026-07-23  
所有者：客户端与通知负责人

## 背景与决定候选

同步日志是投递正确性的唯一依据；live socket 与 Push 都只是可丢失唤醒。当前有
durable wake outbox、campaign/budget 基元、APNs adapter 和 worker；一次设备预算 admission 会在
数据库中与短期 provider lease 分开持久化，因此 provider 失败或 lease 过期重领
不会重复消耗设备 key-work 预算。受认证的活跃设备可以注册不透明 APNs token；token
使用独立部署 envelope key 加密保存，注册会换代 endpoint generation。APNs 只收到
`content-available` 的无内容 wake，不含房间、消息、发送者、媒体或 token；无效/注销
响应只会围栏禁用同一 generation，瞬态故障仍按 durable lease 重试。provider 默认关闭，
只有显式提供 APNs 凭据与 envelope key 时才会启用。

尚未批准的是设备 token 轮换/权限、前台/静音/用户设置的资格规则、通知类别和
campaign 窗口策略；这些不能由已存在的 provider adapter 推断。

原生客户端目前默认关闭后台 wake，用户显式启用后才会请求 UIKit 远程通知注册；
APNs token 只在内存中直送认证 endpoint，关闭时调用设备范围的删除接口。无内容
wake 只启动既有认证同步，不能作为消息投递或展示通知内容。App 配置同时区分
development/production 环境，并要求真实发布配置具备 Push-enabled App ID 与匹配的
provisioning profile；后者尚未获得外部发布证据。

## 备选方案

- Push 作为消息投递：不可重试/不可证明，拒绝采用；
- 每条/每设备即时 Push：高频群成本与隐私风险不可控；
- 有界、合并、无内容 wake：与 sync 恢复模型一致。

## 批准后的门槛与复审

明确 token 轮换/权限、静音、前台抑制、campaign 窗口、额度及 provider 故障策略；
补真实 APNs 凭据的端到端演练、隐私审计与 runbook。provider contract test 已覆盖
缺失 endpoint、APNs token 注销和瞬态 5xx 重试；通知产品策略或 provider 变化时复审。

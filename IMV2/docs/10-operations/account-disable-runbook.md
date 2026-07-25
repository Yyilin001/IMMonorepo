# Account-disable operator runbook

状态：已实现单账号、不可逆的 credential fence；恢复流程、审计读取授权/保留和
bastion/mTLS 实际部署仍须由安全与运维负责人批准。

`IMV2OperatorServerApp` 仅监听 `127.0.0.1` 或 `::1`。账户禁用只能经受管
bastion 或 mTLS operator proxy 到达，绝不可发布 `9445`、复用用户 token、把
bearer token 放进工单或在请求体中传入操作者身份。

## 权限与动作边界

使用与 durable-work replay **不同**的 secret scope：
`IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64`（至少 32 个随机字节的
Base64）与 `IM_V2_OPERATOR_ACCOUNT_DISABLE_PRINCIPAL`。部署模板见
[`operator-replay.env.example`](../../../IMV2Server/operator-replay.env.example)。
proxy/bastion 必须记录真实人员或工作负载身份、审批编号和访问时间；业务数据库只
保存受控的 operator principal，不接受任何自由文本备注。

唯一动作是：

```text
POST /internal/v2/accounts/disable
```

请求必须仅包含一个用户、一个新的 UUID 操作 ID 和封闭原因码：

```json
{
  "operationID": "new-uuid-per-approved-operation",
  "userID": "target-user-uuid",
  "reason": "credential_compromise"
}
```

原因只允许 `user_requested`、`credential_compromise` 或 `policy_enforcement`。接口
返回 no-store JSON；同一操作 ID 重试返回 `idempotent`，已由另一操作禁用的同一
用户返回 `already_disabled`。同一操作 ID 指向另一用户返回 `409`。不得以新 UUID
重复提交、不得批量禁用、不得把它用作删除、解禁、资料隐藏、数据导出或恢复工具。

## 执行与验证

1. 在外部 case-management 系统完成审批，确认精确 UUID 和受控原因码；那里保存
   人工身份与必要的调查信息，不能把这些自由文本写进业务库。
2. 经受控 proxy 调用上述 endpoint。网络重试必须复用原 `operationID`。
3. 确认 `im_v2.account_disables` 中恰有该 operation 的审计事实；确认 proxy/bastion
   审计也保存了审批和调用主体。不要将结果行、UUID 或任何 bearer 输出到公开日志。
4. 观察 gateway 每个副本消费 `device_revocation_events`，已有 socket 被关闭；再用
   受控验证证明旧 access token、refresh credential 和已有 assertion 都不能获得
   新 credential。若任一项失败，停止后续处置并升级安全 incident。

账号禁用会保留业务数据和登录标识，且当前没有解禁 API；这是为了避免未经定义的
恢复路径绕过取证、凭据验证或审计。只有在恢复政策、身份核验、审批、凭据重置与
审计保留全部获批准后，才可另行设计恢复能力。

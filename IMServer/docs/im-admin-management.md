# IM Admin Management

后台管理采用 Web 管理台 + Admin API，不放进 iOS 客户端。

## Runtime

- 管理后台只注册在 `command-api` 或本地 `combined` 角色。
- `gateway`、`query-api`、`outbox-relay`、`stream-consumer`、`ops` 不承载后台管理入口。
- 生产默认关闭：`IM_ADMIN_API_ENABLED=false`。

## Configuration

开发环境默认可打开 `/admin`，如果设置了 `IM_ADMIN_SHARED_SECRET`，所有 `/admin/api/*` 请求都必须带 secret。

生产开启后台时必须显式配置：

```env
IM_ADMIN_API_ENABLED=true
IM_ADMIN_SHARED_SECRET=<至少 32 字符的独立强随机密钥>
```

`IM_ADMIN_SHARED_SECRET` 必须和 `IM_INTERNAL_SHARED_SECRET` 不同。生产环境建议再叠加：

- 管理后台域名独立，例如 `admin.example.com`。
- 只允许 VPN、堡垒机或固定办公 IP 访问。
- 反向代理层增加 HTTPS、基础访问控制和审计日志。
- 不要把 `/admin` 暴露在客户端 API 域名的公网通配路径下。

## Routes

- `GET /admin`: 静态 Web 管理台页面。
- `GET /admin/api/overview`: 用户、在线 session、举报概览。
- `GET /admin/api/users`: 用户列表，支持 `query`、`status`、`cursor`、`limit`。
- `PATCH /admin/api/users/:userID/status`: 更新用户状态；封禁会撤销该用户全部 session。
- `GET /admin/api/reports`: 举报列表，支持 `status`、`targetType`、`cursor`、`limit`。
- `PATCH /admin/api/reports/:reportID`: 处理举报状态。
- `GET /admin/api/audit-events`: 后台审计日志。

API 请求头：

```http
X-IM-Admin-Secret: <IM_ADMIN_SHARED_SECRET>
X-IM-Admin-Actor: <operator-name>
```

也支持 `Authorization: Bearer <IM_ADMIN_SHARED_SECRET>`，但 Web 管理台默认使用 `X-IM-Admin-Secret`。

## Audit

后台写操作会落 `admin_audit_events`：

- `user.status.update`
- `report.status.update`

审计记录包含操作者、动作、目标类型、目标 ID、请求 ID、来源 IP、简短 metadata 和创建时间。

## Current Scope

第一版覆盖最小生产闭环：

- 管理入口和用户客户端分离。
- 独立 admin secret。
- 用户查询、封禁、恢复。
- 封禁自动撤销登录 session。
- 举报查询和状态处理。
- 写操作审计。

后续再补：

- 管理员账号体系和 MFA。
- 细粒度 RBAC。
- 操作二次确认和审批流。
- 更完整的消息、群组、设备、推送和风控管理页。

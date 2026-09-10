# 当前设备撤销：服务端合同

本批完成 B08 的服务端当前设备撤销入口。App 退出接线、重新登录身份轮换、完整持久 checkpoint 和离线撤销能力仍未完成，B08 保持实施中。

`POST /v2/devices/revoke-current` 接受 `operationID`，只撤销已认证身份中的设备；请求提供非空 `deviceID` 时返回 400。原设备列表的 `/v2/devices/revoke` 继续禁止撤销调用者自身。成功返回 204 和 no-store；无效凭据返回 401，数据库失败返回 503。

服务与签发/刷新共用账号事务锁。撤销当前 auth device、所有 access/refresh、Push endpoint 资格、持久 Gateway 撤销事件和操作记录在同一事务完成。沿用既有 `revoke_device` journal 类型，不修改 PostgreSQL 25、protocol 27 或 SQLite 173/5 合同。已经鉴权的并发请求可以重放同一操作；事务提交后使用旧凭据重新请求会被认证边界拒绝。这不是离线撤销能力。

真实 HTTPS/PostgreSQL 测试创建同账号 A/B 两个设备，刷新 A，再验证旧/新 access 均被撤销，当前 refresh 被拒绝，B 仍可使用。十次并发投递只增加一条操作记录。临时数据库专用 AFTER INSERT trigger 在指定 journal 写入时抛错，HTTP 返回 503 后 A 的两代 access 和 B access 均仍可使用，随后正常撤销成功。故障 trigger 不进入生产 schema。

最终真实测试 5 项 / 2 套件通过（2.629 秒），数据库计数为 `7|2|0|0|2`（总设备、撤销设备、撤销设备残留有效 access、残留有效 refresh、撤销事件）。服务端路由、认证中间件、凭据路由及撤销 worker 定向回归 19 项 / 4 套件通过。独立数据库及私有 CA/密钥目录已清除，未运行 App/模拟器/Gateway 进程，也未注入 APNs；本批未种入 Push endpoint，因此不把共享 SQL 更新视作新增的真实 Push 验收。原始日志和源码散列见[证据](../../docs/reviews/verification-records.md#20260906-current-device-logout)。

服务端已撤销的 device ID 不会恢复。客户端下一步必须为新登录生成新的会话设备身份，并持久保存注册重试身份；不能直接接入撤销 API 后继续使用当前安装级固定 device ID。退出补偿也不能使用后来登录账号的凭据。

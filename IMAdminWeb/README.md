# IM 管理后台

React / TypeScript / Vite / Ant Design 管理页面，与独立的 `IMV2AdminServerApp` 配合运行。
首版包含管理员登录、用户列表与详情、永久禁用账户、操作审计和未知结果恢复。

## 本地直接体验

本机已安装 PostgreSQL 16、Swift 6.4 和 Node.js 时，可运行：

```sh
python3 scripts/run_v2_admin_local.py start
```

访问 `http://127.0.0.1:5173`。脚本创建独立 PostgreSQL 集群，初始化真实管理接口与进程内 Policy Owner，生成测试管理员 `local.admin`，并准备 `demo_alice`、`demo_bob`、`demo_verify` 三个测试用户。管理员随机密码位于 `IMV2/local-admin/credentials.json`，文件仅当前系统用户可读，整个运行目录被 Git 忽略。再次启动保留数据和禁用结果，不会重新启用用户。

```sh
python3 scripts/run_v2_admin_local.py stop
```

停止后数据仍保留。该模式仅监听回环地址，显式使用 `--local-demo`；它复用真实认证、数据库审计和 Policy Owner 禁用事务，但不启动远程 Actor 集群、IM 网关或客户端投影消费者，因此不验证跨节点撤销通知。普通启动仍要求下述完整部署配置。

## 服务准备

1. 在现有控制数据库上显式执行 `IMV2/sql/admin-schema.sql`，安装独立的 `im_admin` schema。此脚本只用于首次安装，重复执行会失败并回滚；服务启动不会自动建表。回滚代码时保留该 schema，尤其不能删除审计和未完成操作。管理表不改变 `im_v2` 协议版本。
2. 按 `IMV2Server/admin.env.example` 注入配置。服务固定监听 `127.0.0.1`；数据库策略与现有服务一致。独立 caller-only Actor 身份需要加入既有信任与 `policyMutation` 权限配置，并匹配已部署的 Policy Owner placement。不要复用普通用户 token 或将 Operator bearer 提供给浏览器。
3. 生成管理员密码哈希：

```sh
swift build --package-path IMV2Server --product IMV2AdminServerApp
python3 -c 'import getpass; print(getpass.getpass("管理员密码："))' \
  | IMV2Server/.build/debug/IMV2AdminServerApp --hash-password
```

密码要求 12–1024 UTF-8 字节。只将输出的 Argon2id PHC 串写入部署的私有 JSON 文件，不把密码写入 shell 历史。该文件结构为：

```json
[
  { "username": "ops.primary", "passwordHash": "替换为生成的 Argon2id PHC 串", "role": "operator" },
  { "username": "support.reader", "passwordHash": "替换为另一个账号的 PHC 串", "role": "viewer" }
]
```

将 `IM_V2_ADMIN_ACCOUNTS_FILE` 指向此文件，限制文件读取权限；文件不应提交 Git。
用户名仅支持 3–64 位小写字母、数字、点、下划线和短横线，最多 100 个管理员。
配置从部署文件加载，修改密码、删除账号或更改角色后重启所有管理服务副本；新配置会拒绝旧会话。

```sh
# 先由运行环境注入 admin.env.example 中的变量及真实密钥文件
swift run --package-path IMV2Server IMV2AdminServerApp
```

## 本地前端

```sh
cd IMAdminWeb
npm ci
npm run dev
```

本地设置 `IM_V2_ADMIN_ORIGIN=http://127.0.0.1:5173`，使用 Vite 输出的同一地址访问。
Vite 将 `/admin/api` 转发给 `127.0.0.1:9446`。只有显式 loopback HTTP origin 使用本地开发 Cookie；其他 origin 必须是 HTTPS，并使用 `__Host-`、Secure、HttpOnly、SameSite=Strict Cookie。开发模式不产生默认管理员，不提供模拟登录。

## 生产入口

`npm run build` 输出 `dist/`，由 HTTPS 代理托管。参考 `deploy/nginx.conf.example`，将域名和证书换成部署值，`IM_V2_ADMIN_ORIGIN` 必须与浏览器 origin 完全一致且不含尾斜杠。前端和 API 保持同域，不开放 CORS。
第一版面向受控管理网络；如需面向公网员工访问，应在入口接入组织 SSO/MFA 等访问控制。该版本本身使用独立管理员密码登录，未实现 SSO/MFA。

## 行为合同

- 管理员只有 `viewer`、`operator` 两种角色；两者均可查询用户和审计，只有 operator 可禁用账户。服务端执行权限检查。
- 登录会撤销该管理员既有会话，并创建 30 分钟绝对期限的新会话。数据库只存高熵令牌的 SHA-256 摘要；退出立即撤销。角色或密码摘要变化使旧会话无效。
- 所有 API 请求需要 `X-IMV2-Admin: 1`；所有 POST 同时要求精确匹配 Origin。登录使用现有 Argon2id 有界工作器，全局每分钟最多 60 次、每个配置账号（或共享未知账号桶）最多 5 次，预算跨副本共享。
- 用户查询基于 `public_user_profiles`，支持精确 UUID/公开账号和显示名称字面子串。包括已隐藏、暂停或禁用的资料；不返回密码、令牌或消息内容。列表最多 50 条，按 UUID 游标翻页。有效设备数排除已撤销或会话已过期的设备，不代表实时在线人数。
- 禁用前先保存不可变的操作 ID、管理员主体、目标和原因，然后调用现有 Policy Owner 禁用服务；主体来自服务端认证会话。业务停用事实与管理审计共享同一操作 ID。
- 管理意图与 Policy Owner 提交分属事务。只有确认业务结果且保存审计结果后才返回成功；网络中断或结果保存失败保留 `pending`，不声称失败，也不自动产生新意图。前端保留操作编号，可查结果、重试原操作。浏览器关闭后可从审计展开行接续自己的 pending 操作。
- 重试必须保持管理员、目标、原因和操作 ID 不变；冲突返回 409。审计数据库触发器禁止删除或改写身份与已完成结果，只允许 pending 收敛到已确认结果。
- 这是永久停用流程，会沿用现有设备凭据撤销、资料暂停和事件传播；不提供解封或删除历史数据。
- 成功登录、失败登录、退出、用户查询/详情与禁用结果留有审计。审计读取本身不额外写入一条读取事件；未认证请求由入口访问控制处理。账号和目标 ID 仅存在受限业务/审计数据中，HTTP 日志不记录原始查询串、Cookie 或请求体。

## 验证

在仓库根目录运行：

```sh
bash scripts/test_v2_admin.sh
cd IMAdminWeb
npm run build
npm test # 使用本机 Google Chrome
```

数据库脚本在本机创建一次性 PostgreSQL 16 集群并自动清理，不使用现有业务数据库。
`IMV2_ADMIN_TEST_PG_BIN` 可指定 PostgreSQL bin 路径。测试使用真实数据库和进程内 Policy Owner，覆盖 HTTP 完整流程、权限、凭据撤销、丢失响应恢复及审计不可变性；它不替代远程 Actor 部署的多节点验收。
前端 Playwright 测试使用固定接口夹具验证交互、失败恢复与只读角色，不连接生产账户。

## 服务监控

登录后进入“服务监控”（`/#monitoring`），只读与操作员均可访问。页面每 15 秒刷新一次；离开页面后停止采集，隐藏标签页暂停自动刷新。后端共享并缓存 5 秒采集结果，避免并发页面放大查询。

- 管理 API：表示已认证请求正在被管理进程处理，不代表全部业务服务健康。
- PostgreSQL：执行有 2 秒语句期限的审计表只读聚合，返回 pending 禁用操作数量与最早登记时间；失败时数量为未知。连接与连接池期限由进程数据库配置控制，本地演示均为 2 秒。
- Policy Owner：通过已认证的 Actor RPC 读取每个配置宿主的策略目录，汇总实例数和在途操作数。目录关闭显示异常，任一宿主未响应时计数未知。本地演示直接读取同一组目录指标。
- 账户服务：向 `IM_V2_ADMIN_ACCOUNT_ORIGIN` 的身份接口发送匿名 HTTPS 请求，核对预期的 401 和业务错误响应。消息网关：向 `IM_V2_ADMIN_GATEWAY_HOST` / `IM_V2_ADMIN_GATEWAY_PORT` 发起经过证书验证的 TLS 握手并校验 IM 协议协商结果。
- Actor 集群：对各分片读取经 Raft 多数派确认的快照，核对每个 Room Host 的活动进程身份与发现结果。每次远程检查独立设置超时。演示模式的远程服务仍显示“未部署”。
- 采集失败或快照超过 30 秒时，历史绿色状态变为“状态待确认”，待确认操作数量显示“—”；正常计数 0 与采集缺失明确区分。
- `GET /admin/api/monitoring` 需要有效管理员会话与管理请求头，返回 `no-store`，不暴露内部地址、凭据或原始错误。会话认证也依赖数据库；数据库完全不可达时整个请求可能失败，页面会显示采集失败，不绕过认证。

本地监控不是独立告警系统，当前未保存历史时间序列。

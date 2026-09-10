# 签发前取消证明与 HTTP 强制绑定

对应 B08；本批不关闭整个退出/凭据生命周期问题。PostgreSQL schema 29、protocol 27、SQLite 173/5 均不变。

## 当前合同

- 客户端在发送签发请求前保存完整 `V2DeviceRegistrationCancellation`：设备 UUID、操作 UUID、独立随机证明和毫秒签发截止时间。App 的账号注册租约在请求账号因子前完成此保存；通用发行适配器在发送签发 HTTP 前完成保存。
- 新尝试默认十分钟签发期限。同一未过期尝试重放同一证明；已经过期时，App 注册存储将原证明原子移到 abandoned，使用新的设备、操作和证明。保存失败保留原记录，不发布新租约。
- `POST /v2/device-credentials` 必须携带 cancellation，外层设备/操作必须与证明一致。请求根字段和证明字段使用白名单，非法 JSON/证明返回 400，校验失败不调用账号验证或发行。JSON body 上限 16 KiB。
- 发行接口依赖要求 `V2CancellableDeviceRegistration`。具体服务保留已有内部可信注册方法；公开 HTTP 路径没有无证明降级。数据库在同一事务绑定证明、设备会话和返回凭据，继续使用上一批的取消/签发锁顺序。
- 签发响应回传完整 registrationCancellation。客户端先持久交接有效返回凭据的撤销权限，再检查确认是否匹配；确认缺失、格式非法或不匹配时，交接撤销任务后拒绝登录。这样可以发现忽略新字段的旧后端。若返回凭据本身无法验证，仍保留请求前证明。
- `V2DeviceRegistrationStore` ledger 升级为 format 2，沿用原 Keychain account。pending、abandoned 和 legacy 总数最多 256。旧 format 1 的两个 ID 只能作为 legacy 档案保存，不能生成可以取消已发送请求的新权限。迁移失败保留原字节；通用单设备 Keychain 适配器对旧记录保留并报错。
- 退出把 pending 原子移入 abandoned；pendingCancellations 只读；completeCancellation 必须完整证明相等才删除 abandoned，迟到旧完成不能影响新租约。证明与会话撤销权限均是敏感能力值，不能写入普通日志。
- 压测凭据脚本在签发前把证明写入输出旁的 `.registration-recovery` 目录，文件 0600、目录 0700，写入并 fsync 文件/目录后才请求。该目录不会随临时响应目录清理。导出要求服务端确认原证明，并保留返回的会话撤销能力。目录需与凭据文件一样保护，完成会话清理后才删除。
- 本地 Compose 栈验证脚本也使用同一 Python 持久化工具，证明存放在已有忽略目录 `IMV2/local-ca/registration-recovery`；其禁用账号后的刷新检查补齐原会话撤销能力。该 Compose 脚本本批只检查语法与共用工具合同，未启动或操作现有 Docker 栈。

## 验证边界

本批证据位于 [evidence/20260907-proof-bound-issuance](../../docs/reviews/verification-records.md#20260907-proof-bound-issuance)。

离线测试覆盖缺失/非法/不匹配证明、签发回执确认、保存失败、过期旋转、旧格式迁移和迟到完成。压测脚本使用替换 curl 的离线测试覆盖确认成功、缺少确认和响应丢失，不声称脚本本身已跑真实负载。

真实数据库测试经 HTTP 完成签发与取消，覆盖取消先于签发、绑定后取消、事务失败、地址限流和迁移回归。原生 HTTPS 测试在真实服务端提交后，由 transport 故障注入丢弃整个 200 响应，发行器无法取得响应字节，也没有 received-result 凭据记录；保存适配器保留原证明，重建 owner 后取消，数据库独立核对撤销与事件。此故障注入不是物理网络断包，也不是进程被杀。

## 尚未关闭

- App 自动扫描/退避/暂停/重试 abandoned 证明的执行器与状态展示。
- 冷启动对请求前 pending 证明和已经持久采纳的凭据做所有权协调，避免错误取消已完成登录；不能直接把全部 pending 当作遗弃。
- legacy 档案和旧后端完全丢失响应的会话清理、部署切换策略。响应确认只能检测收到的旧响应，不能使旧后端追溯绑定新证明。
- OS 杀进程、真实锁屏、系统后台与跨版本升级的完整生命周期验收。
- 注册取消记录 GC（含未签发墓碑）仍需独立保留合同；不可在十分钟签发截止后直接删除已绑定会话的证明。

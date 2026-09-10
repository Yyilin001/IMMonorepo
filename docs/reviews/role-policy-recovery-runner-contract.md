# B06 自动权限恢复执行器

更新：2026-09-06。执行器已接入 App 的认证连接后台任务，继续使用[恢复存储的本地栅栏](role-policy-recovery-store-contract.md)。本机分层回归已通过，未执行真实 App–Gateway TLS 端到端验收。

## 调度和失败隔离

`V2RolePolicyRecoveryRunner` 每批发现并处理至多 16 个房间（可配置 1–100）。它复用 `V2CommandRetryScheduler`：先订阅 GRDB ValueObservation，再读下次到期时间，避免发现房间或提交重试时间时丢失唤醒。首次启动、房间投影变化、恢复请求变化及 reset 完成都能触发重新检查，不依赖额外 availability 提示。

`scheduleRolePolicyRecovery` 追加迁移保存 attempt_count、next_attempt_at 和 pending/paused 状态，并增加到期索引。旧请求 ID、账号和成员/代次栅栏保持不变，默认立即可执行。主 schema 为 **171** 个对象，搜索库为 **5**，主库指纹 **0x87a3b2175e9448e3**。

网络失败按 1、2、4…秒退避，最多 60 秒，并尊重服务端更长的 retryAfter。一个房间延后不阻塞其他到期房间。重试时间持久化，重启不会提前执行；尝试计数饱和到 Int32.max，避免溢出。

错误响应或不可重试错误暂停该房间；暂停请求不再驱动定时循环。`resumeRolePolicyBaseline` 是显式重试接口，会创建新的请求身份；成员或同步栅栏改变也可重新发现。FORBIDDEN/NOT_FOUND 仅在当前请求和全部本地栅栏仍匹配时撤销房间的本地读取授权、清除观察点和请求。暂停和重试会增加 attempt_count，使旧尝试的失败结果不能继续修改新尝试。

## 连接生命周期

`V2ClientRuntime` 在初始认证、同步和优先命令完成后启动独立恢复任务。显式 stop 取消并等待该任务；后台故障也取消它。App 的 loop 闭包每次创建新的 runner，避免已取消的旧连接执行器占有替代连接。

执行器在网络调用前、响应返回后和写入前检查取消；store 在成功或失败处理入口同样检查取消。取消不写成重试或权限撤销。即使测试传输忽略取消并晚到，旧结果也不能写入。账号、成员和代次栅栏继续由持久 store 在事务中检查；网络设备授权仍由认证连接和服务器承担。

## App 权限编辑

会话刷新现在读取最新权限投影，独立的读取 generation 防止旧的显式读取覆盖自动恢复结果。权限弹层在未知时禁用编辑/保存；第一次获得策略时初始化草稿。草稿持有开始编辑时的策略版本，新投影到达不会暗中替换其 expectedRevision；用户可选择“重新载入最新权限”。

后续已接入针对 paused 请求的 App 状态反馈和显式重试按钮，见[状态与重试合同](role-policy-recovery-ui-contract.md)。下文保留执行器批的验证范围，真实链路和权限弹层点击验收仍未完成。

## 证据与限制

ClientKit **327 项 / 53 套件**、App **171 项 / 17 套件**通过。测试覆盖跨房间失败隔离、重试后重启、服务端延迟、暂停/显式重试、FORBIDDEN、取消和成员变化后的迟到结果、无额外提示的发现、旧请求表迁移、runtime stop 拥有恢复任务，以及 App 新旧权限读取交错。失败/成功日志与源码绑定见[执行器证据](../../docs/reviews/verification-records.md#20260906-policy-runner)。

本批未新跑 Core/server/PostgreSQL、真实网络、Linux、负载或无障碍人工验收，也未执行权限弹层的点击端到端测试。未部署，protocol 25 与 PostgreSQL 18 未变。暂停交互、置顶/成员角色、完整 receipts 保留/清理及组合验收仍开放，B06 不关闭。

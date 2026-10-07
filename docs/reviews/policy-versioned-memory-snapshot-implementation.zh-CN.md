# 权限版本化内存快照改造

日期：2026-10-06。适用于配置 Policy Placement 后的 Gateway current-state 发送链路。替代此前节点缓存的 TTL、后台续租、失效后重拉与权限冷加载请求调度。

## 状态与职责

新增 `V2PolicyFactsSnapshot(scope, version, facts)` 和独立 Snapshot Wire。快照不包含 Owner ID、epoch、租约期限或剩余生命周期。双方关系的两个方向规范化为同一个 scope，避免相同版本被误判为内容冲突。账号、双方关系、陌生人设置分别按 scope 共享；房间不长期保存最终权限结果。每次发送组合当前内存事实做判断。

消息准备仍有执行截止时间，它限制单次发送尝试，不表示权限事实过期。既有消息事务、Room Owner 围栏、幂等回执保持原有职责。

Policy Owner 的所有权认领/续期只保留在已有策略写入及旧注册授权接口中，不再由 current-state 权限读取触发。

## 首次初始化

Gateway 的 `loadSnapshots` 合并同 scope 的首次请求，不设逻辑读取并发额度；不同 scope 可以独立初始化。单个调用者取消不会取消其他调用者共享的实际加载。

Owner 先注册更新接收者，再返回内存快照；未初始化时由 Journal 通过一条 SQL 读取事实和 scope 版本。同一个 RPC 中最多四个未加载 scope 共用一次查询；PostgreSQL 单条语句的 MVCC 快照保证版本与事实一致，无需显式 BEGIN、隔离级别设置和 COMMIT。读取不写租约、不获取 advisory lock、`FOR SHARE` 或 `FOR UPDATE`。不存在 scope 行时，使用初始版本 1，策略修改在同事务创建/修改 scope 并推进版本。

实际数据库操作仍受独立数据库资源准入保护。该额度不覆盖 RPC 等待或内存判断。Owner 读取不占用修改任务的 bounded roots 或 Owner 对象数量额度。

## 变更主动更新

拉黑、解除好友、陌生人设置、封禁等现有策略写入仍由对应 scope Owner 串行执行，提交事实及新版本后产生完整快照。Directory 安装权威内存状态，Publisher 更新本节点正在使用的缓存，并向已注册的 Gateway 推送新快照。

推送内容包含完整事实和版本。Gateway 只接受更新版本，同版本同内容幂等，旧版本忽略，同版本不同内容报错。初始化中的 scope 同样接收更新；加载期间保留收到的新版本，即使 LRU 淘汰，也不能让旧返回结果覆盖它。

修改成功返回前等待相关在线接收节点的安装确认。通知失败报告 outcomeUnknown，不能声称修改已回滚；既有回放与 outbox 可再次发布当前版本。没有新建完整的断线追赶、动态成员或故障切换系统。

订阅目标限定于部署配置中的 host/endpoint；认证层要求 service principal、policyRegistration 权限及订阅 host 属于调用方。更新要求 policyMutation 权限。快照内容和 scope 身份在解码时校验。

## 移除旧读取限制

Gateway 不再创建 `V2PolicyStateRequestScheduler`，current-state service 不再返回需要该 scheduler 的 preparation stages。房间 current-state 快照加载也不再用 maximumInFlight 限制读取；消息执行本身原有的并发和排队保护仍保留。

Gateway 不启动节点缓存续租任务。正常读取不查数据库、不调用 Owner、不检查租约时间。变更更新快照而非删除快照。

旧的租约状态、失效 Wire 和注册授权实现保留用于既有兼容链路及测试，没有接入上述生产读取路径；不能把这些遗留 API 的存在理解为生产仍周期续租。

## 内存与一致性边界

Gateway 和权威快照缓存默认各保留最多 32,768 个 scope，LRU 淘汰后才重新初始化。已淘汰的 Gateway scope 收到推送不会重新填充缓存。订阅记录按进程生命期维护，目标节点集合来自静态配置，动态退订与断线恢复留待后续闭环。

初始化期间到达的新版本优先于旧 SQL/RPC 结果。多个 scope 不提供全局原子快照。发送按准备时采样的权限执行；已准备的发送不会因之后的修改被跨房间撤回，修改成功后的新准备使用新状态。

## 验证

- 版本缓存测试：10,000 次热读和主动更新无额外获取；加载合并；调用取消；独立 scope 并发；旧返回与 LRU 竞态；重复/乱序推送；淘汰重载。
- 真实 PostgreSQL：首次加载不创建租约行；持有账号业务 advisory/row lock 时，只读初始化仍能完成。
- 真实 TCP：首次获取后隐藏权限事实表及 scope 表，跨越测试租约时间后继续热读；拉黑、设置修改、封禁后收到推送，Owner 获取请求数量不增加。
- 既有真实消息发送、回放、修改期间独立房间发送及冷热状态竞态验证。

### 最终结果

- Release Gateway、Account、LoadGenerator 构建成功；最后一次 Gateway 检查构建成功。
- 快照缓存与 PostgreSQL/TCP 测试：9 项、2 个 suite，通过；日志 `/tmp/imv2-snapshot-final-native-tests.log`。
- 新旧 Policy RPC 权限验证：4 项（含参数化场景）、1 个 suite，通过，同一日志。
- 消息准备、发送、回放、策略修改及房间隔离：5 项（含参数化场景）、1 个 suite，通过；日志 `/tmp/imv2-snapshot-final-room-tests.log`。
- 共 18 项相关测试通过。没有运行整个仓库的全套测试。
- R26 全部 10,000 连接 ready；1,000 msg/s 在约 20 秒因重试耗尽停止，未完成 60 秒，只有 2/12 客户端报告。消息 Owner 正文仍约 35.832 ms；整体吞吐尚未达标。详见 [压测报告及限制](performance-policy-versioned-snapshot-10000-online-1000msg-20261006.md)。
- R25 的源端口冲突启动失败已排除；有效 R26 的所有进程已结束，没有强制 kill，但两个 Gateway 出现连接 drain 超时退出 1。测试和压测 PostgreSQL 均已停止。


## 单条 SQL 冷加载优化（2026-10-06）

`PostgresV2PolicyFactsSnapshotReader` 使用参数绑定的 scope 输入表，一次返回版本及账号、关系和陌生人设置事实。保留缺省版本 1、缺省陌生人允许、账号不存在时不可用，以及 pending change 拒绝读取的语义。策略写入仍然使用事务原子提交事实和版本。

保留原 `policy_owner_state_transaction` 指标名称以兼容现有监控；新读取路径中它表示整个单语句加载耗时，不再表示显式事务。`policy_owner_state_facts` 包含单语句执行与结果转换。R26 的事务耗时属于优化前数据，不能用作本次优化后的测量。

本次验证：快照缓存与真实 PostgreSQL/TCP 共 10 项测试、2 个 suite 通过（`/tmp/imv2-policy-single-statement-tests.log`）。新增测试覆盖缺省事实、请求顺序、并发原子写入下版本/事实一致性及 pending-change 拒绝。测试数据库已停止。本次未重跑 10,000 在线 / 1,000 msg/s 压测，没有新的端到端提升比例。

本次 Release Gateway 构建成功（`/tmp/imv2-policy-single-statement-release.log`）。

单条 SQL 后 R27 已复测：10,000 在线全部 ready，权限状态获取观测均值 15.855 → 7.183 ms；冷加载 19.119 → 7.376 ms。整体仍约 20 秒重试耗尽，6/12 报告，未完成 60 秒目标。详细对比见性能报告的 R27 节。压测服务和 PostgreSQL 已结束。

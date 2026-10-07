> 2026-10-06 最新实现：权限读取已改为不带租约的版本化内存快照，变更主动推送；本文件中的周期续租、失效后重拉和冷加载调度描述属于此前实现。见 [完整改造与验证](policy-versioned-memory-snapshot-implementation.zh-CN.md)。

# 授权内存状态：归属与更新路径

> 2026-10-06 更新：发送热路径已增加节点共享 scope 缓存，首次加载后本地复用；策略提交后通知失效，活跃状态由后台续租。下文此前的逐次 Owner 获取描述是旧实现，当前逻辑见 [节点权限缓存实现说明](policy-node-memory-cache-redesign.zh-CN.md)。

状态：实施中。本文件记录用户要求“先不要考虑真实环境闭环”后的授权设计调整；不代表原消息链路重设计或容量验收已经完成。

用户随后要求“现在先测试一下性能”。最新 R23 的 10,000 在线 / 1,000 新消息每秒测试未通过，另发现并修复 Release 连接池容量通知的栈溢出；实际失败数据、回归证据和收尾限制见 [2026-10-06 性能记录](performance-10000-online-1000msg-20261006.md)。下文 R18–R20 保留为历史证据，不代表最新容量结果。本次测试未继续扩大授权模块设计。

## 当前实施边界

用户指出讨论偏离后，本阶段重新聚焦账号状态、双向拉黑、好友关系、陌生人设置的状态归属、内存读取和修改发布。原消息链路重设计目标保留，但队列调度和容量压测不作为本阶段继续扩展的内容；多节点传播、接管、部署切换不作为本阶段的完成条件。

领域归属与进程托管分开说明：账号及设置由账号领域修改，好友及拉黑由关系领域修改；它们共用按 account/pair/stranger 分隔的授权状态入口。当前状态实例由 `GatewayPolicyAssembly` 托管，Account/Operator 调用同一路由；这不意味着房间拥有这些事实。不能在 Account、Operator 和每个房间各放一份独立更新的策略缓存。

本阶段的验证重点是：发送命中内存不读取全局策略事实表；策略提交成功并发布内存后才返回；未提交的写入不发布新事实；策略更新不等待已经授权的房间消息提交；首次加载不会覆盖随后提交的新状态。

## 当前落地入口与本轮核验

### 本轮范围收敛

按用户再次指出偏离后的要求，本轮只核验策略状态的领域入口、内存归属、提交后发布和发送读取。连接池借用、房间队列和回执批处理的历史改动不作为本轮新增工作，也不作为授权模块完成的证据。

当前源码的装配有明确前提：Account 在 `actorConfiguration.policyPlacement != nil` 时绑定 Social/Preference 的 `usingPolicyOwners`；Operator 在存在 `policyCaller` 时绑定 Disable 的同一接口；Gateway 在存在 policy placement 和 host identity 时建立目录并启用 `usesCurrentState: true`。缺少配置仍有旧路径，因此本地状态测试通过不能证明任意启动配置都已经使用内存授权。这里记录现有条件，不扩展为部署切换任务。

“发送读取内存”指不逐条读取账号、拉黑、好友和陌生人设置的事实表。当前 Gateway 托管对应状态；同进程通过本地目录访问，其他进程通过策略入口访问。首次缺失或状态权威过期仍可能加载或续租；房间自己的消息事务仍访问数据库。不能将这一实现描述成每条消息完全没有 SQL，也不能把 Gateway 托管解释成 Gateway 拥有账号和关系的领域职责。

本轮重新构建当前测试目标（27.03 秒），在独立 PostgreSQL 25462 执行 `scopeMutationOrderAndIsolation`、`currentPolicyServiceSendAndReplay`、`currentPolicyMutationDoesNotWaitForRoom`、`policyMutationCommittedMemoryPublication`、`warmRoomPolicyMutationIsolation`、`currentPolicyMutationSupersedesCapturedColdResult`：6 项测试、24 个参数用例通过（18.739 秒），实际测试进程 exit=0，日志 `/tmp/imv2-policy-scope-refocus-tests.log`。数据库已停止并确认端口无响应。本轮未新增授权生产代码，也未执行容量压测；此次证据核验现有实现的本地状态边界，原整体链路目标仍未完成。

### 修改入口归属核验

随后逐项核对当前源码中修改授权事实的业务入口，区分外部提交入口和事务内执行方法：

| 修改 | 外部提交入口 | 状态归属 | 事务内执行 |
| --- | --- | --- | --- |
| 好友请求、接受、拒绝、解除好友；拉黑和解除拉黑 | `PostgresV2SocialRelationshipStore.submitSocialOperation` | 双方规范化 pair | `applyPolicyOperation` 验证 scope、操作身份和指纹；关系和拉黑实际 SQL 在私有方法内执行。 |
| 陌生人消息设置 | `PostgresV2AccountPreferenceOperationStore.submit` 的 `strangerMessagePreference` 分支 | 接收方 stranger | `applyPolicyOperation` 只接受该设置类型并验证 scope、操作身份和指纹；通过现有设置事务方法写入。 |
| 封禁 | `V2PostgresAccountDisableService.disable` | 被封禁用户 account | `applyPolicyOperation` 验证 scope、操作身份和指纹，再在上下文事务内执行账号停用。 |

三类入口绑定 `usingPolicyOwners` 后均先调用策略 mutation executor，不能把其内部领域 Store 的 SQL 调用误读为发送时查库。`PostgresV2PolicyMutationDispatcher` 在 journal 提供的同一个事务上下文中调用上述执行方法；`PostgresV2PolicyOwner.changeExecution` 等实际事务结果返回，再通过 `jobFinished` 发布快照，之后完成调用。永久结果重放不会重复应用修改。

另检查了 `V2PublicIdentityAccountStore` 和 `PostgresV2ProfileUpdateStore` 的资料更新：它们更新名称、头像和资料修订，不修改此处 account facts 使用的账号活跃状态或特殊账号消息能力，因此这些更新不需要使授权快照失效。该核验限定于当前三个修改领域及资料更新源码，不证明数据库外部写入、脚本或未来新增账号能力修改都已经接入状态入口；也未新增此类真实环境闭环。

### 当前内存模式的容量和保留验证

目录的 `retainedFactBudget` 和 `cachedStatesBypassBusyRoots` 原来仅使用默认旧模式 journal。现在两项均参数化新旧模式，当前模式明确设置 `roomDrainRequired: false`；原来的 SQL 阻塞、字节上限、事实查询计数和实际容量断言均保留。验证字节预算满时恢复所请求的快照不会先被淘汰，真正已淘汰的事实重新读取；另验证无关 SQL 占满目录 root 时，暖状态读取仍复用同一 facts、revision 和 deadline，冷缺失仍返回 busy。

独立 PostgreSQL 25462 运行目录测试及 `currentPolicyRetainedFactsAcrossEviction`：重新构建 27.29 秒，5 项测试、8 个执行用例通过（4.145 秒），实际进程 exit=0，日志 `/tmp/imv2-policy-memory-budget-tests.log`。包括状态对象淘汰、修改提交/失败、到期续租时保留正确事实，以及取消/关闭等待实际 SQL 结算。数据库已停止并确认端口无响应。本轮补充当前模式此前缺少的直接覆盖，没有修改生产容量或状态协议，不是吞吐证据。

当前实现的核心链路是：领域修改入口 → 对应 account/pair/stranger 状态 → 数据库提交 → 替换内存快照 → 返回结果；消息授权读取同一状态入口，房间负责自己的消息事务。

| 职责 | 当前代码入口 |
| --- | --- |
| Account 的好友、拉黑与陌生人设置修改 | `IMV2AccountServerApp/main.swift` 将 Social/Preference store 绑定 `usingPolicyOwners` |
| Operator 的封禁修改 | `IMV2OperatorServerApp/main.swift` 将 Disable service 绑定 `usingPolicyOwners` |
| 状态定位与内存归属 | `PostgresV2PolicyOwnerDirectory` 按 scope 定位，`PostgresV2PolicyOwner` 保留已提交状态 |
| 同状态修改顺序与提交后发布 | `PostgresV2PolicyOwner.changeExecution` 的 scope 内任务链；`PostgresV2PolicyAuthorizationJournal.changeCurrentPolicy` 的单事务 |
| 发送授权读取 | `V2RoomPolicyAuthorizationService` 的 `usesCurrentState` 路径，内存命中不读取全局策略事实表 |
| 当前进程装配 | `GatewayPolicyAssembly` 启用 `roomDrainRequired: false` 与 `usesCurrentState: true` |

2026-10-06 重新构建并核验当前工作树，使用独立 PostgreSQL 25462：`scopeMutationOrderAndIsolation`、`currentPolicyServiceSendAndReplay`、`currentPolicyMutationDoesNotWaitForRoom`、`policyMutationCommittedMemoryPublication`、`warmRoomPolicyMutationIsolation` 共 5 项测试、22 个参数化用例通过，测试耗时 18.786 秒，日志 `/tmp/imv2-policy-scope-audit-tests.log`。实际阻塞消息 COMMIT 或策略事务，验证同状态串行、其他状态独立执行、提交前读取旧快照、提交后读取新快照及失败 COMMIT 不发布新事实；隐藏全部六张全局策略事实表后，生产房间仍按内存状态授权，并覆盖两种消息准备入口与结果重放。

这份证据只覆盖上述本地策略链路，不证明所有房间共享资源都已隔离，也不证明 10,000 在线 / 1,000 msg/s 已通过。历史压测和关闭超时记录保留在后文，但不作为这一阶段继续扩展实现的依据。原核验未覆盖的首次加载与修改交错，见下一节新增验证。

### 纠偏后的本地策略边界核验

2026-10-06 对当前工作树重新构建（72.53 秒），使用独立 PostgreSQL 25462 执行 6 项测试、24 个参数用例，全部通过（20.311 秒）；日志 `/tmp/imv2-policy-boundary-review-tests.log`，实际测试进程 exit=0。测试结束后数据库停止并确认端口无响应。本轮没有继续容量调优或扩大真实环境闭环。

| 本阶段要求 | 当前实现与直接证据 |
| --- | --- |
| 状态归属统一，房间不各自维护权威策略 | Gateway 托管 scope directory；Account Social/Preference 与 Operator Disable 的实际装配均使用同一个 mutation executor。account / canonical pair / recipient stranger 分别定位状态。 |
| 同策略修改有序，不同策略不等待彼此 | `scopeMutationOrderAndIsolation` 的真实数据库阻塞测试；覆盖当前模式及旧模式，共 2 个用例。共享数据库容量仍可能产生资源等待，这不等于存在跨策略串行任务链。 |
| 发送命中内存不查账号、关系、设置事实表 | `currentPolicyServiceSendAndReplay` 的 4 个准备入口组合；隐藏六张全局事实表后仍实际提交，覆盖拉黑、解除拉黑、永久回执和身份冲突。房间自己的成员、回复、配额与回执 SQL 仍保留。 |
| 持久化完成后发布快照，再完成修改调用 | `policyMutationCommittedMemoryPublication` 的真实 COMMIT 阻塞/失败测试，4 个新旧模式用例；未提交事实不发布，失败后缓存可能清除并重载。 |
| 策略更新不等待已授权房间消息 | `currentPolicyMutationDoesNotWaitForRoom` 的拉黑、解除好友、陌生人设置、封禁 4 个用例；阻塞真实消息 COMMIT，策略修改仍完成。 |
| 更新影响相关授权，其他房间继续推进 | `warmRoomPolicyMutationIsolation` 的 8 个用例；实际领域入口修改及逆向恢复、策略 SQL 阻塞期间的暖发送与不相关房间推进。 |
| 首次加载不能覆盖提交后的新快照 | `currentPolicyMutationSupersedesCapturedColdResult` 的 2 个用例；真实旧 SQL 已提交、延迟结果返回，再提交新策略，等待者读取新快照；同时覆盖调用取消。 |

这里证明的是本地账号/关系/设置的读取与更新边界。测试没有证明全链路容量、所有 writer 顺序或统一物理数据库代理；原目标仍保留这些待完成要求。无需为本阶段另建 Account 缓存、房间策略副本或部署迁移流程。

失败不会发布事务中捕获的新事实。当前实现对修改失败统一清除可能不确定的缓存，再读取持久化状态；因此不能将其描述为所有失败都会原样保留内存快照。

### 首次加载等待期间发生策略修改

发现并修复了返回结果的版本边界：旧加载的 generation 检查原来只保护缓存发布，等待该加载的调用仍直接取得旧任务的结果。一次修改已经提交并发布新快照后，旧加载仍可能返回不同的状态租约，或因事实读取失败而让等待中的授权失败。

`PostgresV2PolicyOwner.stateFinished` 现在同时检查缓存发布和等待者的结果。旧 generation 的实际加载结束后，新模式只返回当前有效的已提交快照；没有有效快照则返回 `busy`，已关闭则返回 `closed`。旧加载在 SQL/准入实际结束前仍保留其根，不提前释放容量，不启动替代数据库任务。原 room registration 合同的结果行为保持不变。

新增真实 PostgreSQL 测试将首次读取阻塞在状态 SQL 准入，再让账号策略修改完成。覆盖旧读取随后成功、隐藏事实表导致旧读取失败、修改事务回滚后无可用快照、关闭等待旧加载结束四种情况。修改前 `/tmp/imv2-policy-cold-supersession-before.log`：1 项测试、2 个用例失败；修复后 `/tmp/imv2-policy-cold-supersession-after.log`：6 项测试、17 个用例通过（13.773 秒），包括消息准备、消息 COMMIT 隔离、提交发布、空恢复与合并加载取消/关闭回归；最终 `/tmp/imv2-policy-cold-supersession-boundaries.log`：2 项测试、4 个用例通过（3.067 秒）。

随后补齐“SQL 已读出旧事实、实际事务结束后延迟返回”的调度点：测试专用数据库包装器正常执行真实 PostgreSQL 事务，仅在 COMMIT future 已成功后暂停首个冷状态结果的交付，不改变生产代码或替换事实。独立事务通过 `FOR UPDATE NOWAIT` 获取该 scope 行锁，证明旧事务已释放锁；此时冷结果明确包含 active=true。账号修改随后实际提交并发布 active=false、revision+1，隐藏账号事实表，再释放旧结果。等待者及后续读取都得到发布后的同一份快照，旧事实不能返回或覆盖缓存。另一个用例取消等待调用，仍保留冷加载根直到交付实际结束。

`/tmp/imv2-policy-captured-cold-tests.log`：重新构建后 3 项测试、6 个用例通过（4.998 秒），包括首次读取排队、已捕获旧结果、修改失败与关闭的交错。此项只补本地状态交错证据；当前 Release 尚未重建，容量结果仍沿用此前未通过的记录。

### 无副作用查询与首次内存保留

另一个交错缺口是：首次加载已经开始，在结果交付前又开始永久回执查询或空恢复查询。原 `stateFinished` 即使 generation 未变化，也因 `jobs` / `recoveries` 非空而放弃缓存发布。查询结束后没有内存值，下一条消息仍可能重读事实表。这些查询尚未执行策略修改，不能作为丢弃已加载事实的理由。

当前模式现在以 generation 区分是否发生真正的修改：generation 未变化且入口未关闭时，成功的首次加载可以在结果/恢复查询等待期间保留。`beginMutation` 和 `beginRecovery` 继续推进 generation；真实效果、失败和关闭仍受前述返回与发布边界保护。旧注册模式保留原来的封闭读取行为。

新增测试通过真实表锁阻塞永久结果或空恢复查询，同时交付之前已经开始的真实冷加载，检查等待期间已有内存；隐藏账号事实表后完成查询，后续读取仍复用相同 owner、facts 和 deadline。修复前 `/tmp/imv2-policy-cold-lookup-before-r2.log`：2 个用例、6 个断言问题，复现内存缺失及后续 SQL 失败。修复后 `/tmp/imv2-policy-cold-lookup-after.log`：8 项测试、16 个用例通过（17.289 秒），包括旧结果晚返回、修改回滚、关闭、真实 COMMIT 发布、空恢复、已知 pending 恢复及加载取消/结算。

本地入口配置另经源码与生成器核验：`run_v2_local_account_stack.sh` 首次启动生成带 `--policy-partitions 16` 的统一 Gateway/Account/Operator 配置，再执行一致性检查；配置生成及校验的 5 项 Python 测试通过。本工作树当前没有 `IMV2/local-room-actors`，因此这项证据是启动入口与配置生成行为，不是已经启动了本地服务。

### 最新 R18 容量状态

上述内存发布修复后的 Gateway、Account、Loader Release 均已重新构建成功。相同 10,000 在线 / 1,000 新消息每秒场景运行 `/tmp/imv2-memory-policy-10k1000-20261006-r18`，12 份在线就绪和 12 份最终报告完整，但共同窗口仅 20.004 秒、ACK 13,660 / 发送 19,984，客户端 p95 约 9.19–10 秒，质量和 drain 未通过。冷状态队列完成等待均值仍约 2.30 秒，状态 SQL 事务约 30.01 ms、Owner 正文约 39.57 ms，未发生状态驱逐。内存正确性修复不能替代原容量验收；本轮未证明吞吐提升。完整证据与阶段范围见 [消息链路实施记录的 R18](message-execution-redesign-implementation.zh-CN.md#r18当前内存发布修复后的同场景验证)。

### 冷状态首次所有权获取与 R19

当前模式、没有缓存事实的 `acquireOwnerState` 原来先 `INSERT ... DO NOTHING` 确保 scope 存在，再执行所有权锁定/续租。现用一次 `INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING` 创建或获取 scope，返回版本与 pending 状态；它仍在原事实读取事务内，事实失败或 pending 检查失败整体回滚。冲突更新在实际行锁等待后重新计算有效期，不能复用 INSERT 在等待前计算的有效期。同一有效 Owner 保留 epoch，过期 Owner 推进 epoch；有效的其他 Owner 不能被抢占。epoch 上限和拒绝获取时回到原 helper，保留原错误分类。已有缓存事实及旧注册模式仍使用原 helper，核对续租前 owner ID、epoch、revision 后才复用事实。

`/tmp/imv2-cold-claim-tests.log`：7 项真实 PostgreSQL 测试、20 个用例通过（21.965 秒）。新增覆盖初次创建、同 Owner、过期接管、有效其他 Owner、有效 MAX epoch、过期 MAX epoch；另将真实 scope 行锁等待保持超过 INSERT 提议有效期，验证冲突更新仍获得新有效期。原事实失败回滚、pending 拒绝、事实行锁等待后到期、生产消息准备/重放、首次加载交错测试同时通过。

Gateway `/tmp/imv2-cold-claim-r19-gateway-build.log`（194.65 秒）、Account `/tmp/imv2-cold-claim-r19-account-build.log`（9.61 秒）、Loader `/tmp/imv2-cold-claim-r19-loader-build.log`（13.83 秒）Release 均成功。R19 输出 `/tmp/imv2-memory-policy-10k1000-20261006-r19`：12 份 ready 证明启动时 10,000 在线，但最终只有 10 份报告；完整共同窗口为零，质量、steady、capacity、drain 未通过。10 份报告的认证 8,333、发送 16,653、ACK 11,824、workloadFailed 4,829 仅是局部合计，不能拿它与 R18 的 12 份合计计算全局吞吐提升。

`candidate/policy-partial-window-diagnostic.json` 在 10 份已知报告的约 20.002 秒交集内选择 4 个完整六节点采样，首末跨度 15.477 秒；缺少另两份报告，因此不是完整负载共同窗口证明。局部均值：state SQL 事务 26.00 ms、SQL 准入 10.25 ms、事实读取 9.07 ms、内存探测 20.23 ms、冷队列完成等待 1,870.50 ms、Owner 正文 38.54 ms。probe hit/miss=7,107/8,187，没有 Owner/事实驱逐。每节点实际冷请求峰值仍为 5，冷队列峰值 132/122/123/155/145/85；排队问题仍存在。13 个服务均正常退出，25 个进程 settled、无强制 kill；缺失报告 3、6 的负载器在清理时收到 SIGTERM（exit=-15），其余负载器 exit=1。测试和压测 PostgreSQL 均已停止。

### 已准入读取复用与 R20 历史记录

冷状态需求在进入队列前已经完成内存探测。当前 `v2WithScheduledPolicyStateRequest` 检查需求是否属于同一个 scheduler 的实际准入：已准入的普通读取直接执行状态读取，不再重复内存探测 RPC；其他 scheduler 的调用及 `cachedOnly` 调用仍按原规则探测，缓存缺失不能偷偷转成 SQL。未改连接池、队列容量、调用截止或状态有效期。

修复前 `/tmp/imv2-admitted-policy-probe-before.log` 的 own-admission 用例失败，证明重复调用探测；修复后 `/tmp/imv2-admitted-policy-probe-after.log` 9 项测试、14 个参数用例通过（4.705 秒），覆盖本 scheduler、其他 scheduler、cache-only 命中/缺失及真实发送路径。真实 staged 发送在首轮仅记录一次内存探测和一次冷需求准入；永久结果重放、身份冲突、策略修改及隐藏事实表后的内存发送同时通过。

此前已执行 R20，三份 Release 构建成功：Gateway 192.73 秒、Account 9.81 秒、Loader 13.80 秒，日志前缀 `/tmp/imv2-admitted-policy-probe-r20-`。输出 `/tmp/imv2-memory-policy-10k1000-20261006-r20`：启动时 12 份 ready、10,000 在线，最终只有 8/12 份报告，完整共同窗口为零，所有容量及质量要求仍未通过。已知报告发送 13,323、ACK 10,170、workloadFailed 3,153，均为局部合计；p95 为 6,775–7,621 ms。缺失报告 0/6/8/9 的负载器在清理时收到 SIGTERM，13 个服务正常退出，全部进程 settled、无强制 kill。

局部诊断仅使用 8 份已知报告交集内的 4 个完整六节点采样，跨度 15.471 秒，不证明全局窗口。状态 SQL 事务均值 24.99 ms、事实读取 8.64 ms、Owner 正文 37.38 ms、冷队列完成等待 1,390.66 ms，没有 Owner/事实驱逐。跳过重复探测改变了 probe 指标的计数范围，不能用与 R19 的命中比例变化证明缓存命中提升，也不能比较缺失报告下的合计来证明吞吐提升。

该记录归档已经执行的工作，不将继续容量调优作为当前策略状态归属与更新阶段的任务。

## 目标与一致性边界

发消息通过负责授权的状态模块读取内存中的账号、关系和设置。房间继续负责消息顺序、成员权限和消息持久化，但不拥有这些跨房间策略的权威副本。

策略操作成功返回之前，必须完成数据库提交和负责该策略的内存状态更新。成功返回后新开始的授权使用更新后的状态。已完成授权、尚在执行的消息可以按原授权完成；策略变更不等待这些消息或相关房间的 SQL。已在队列中但尚未授权的消息使用执行授权时的状态。

修改事务尚未提交时，已加载且仍有效的上次提交快照继续可读。不能仅因为同一策略有写入任务，就清空该快照或让发送返回忙碌。提交成功后替换快照；提交结果不确定或失败时清除缓存，后续重新读取已持久化的事实。没有快照或快照已过期时，仍走有界加载路径，不将过期状态当作有效授权。

这里只调整账号、关系和陌生人设置的授权边界。消息 operation 身份、永久回执、房间序号、成员检查以及 Room Owner/activation 围栏仍有各自职责。账号策略版本不替代房间所有权围栏。

## 状态归属

| 状态 | 逻辑所有者 | 写入入口 |
| --- | --- | --- |
| 账号是否可用、特殊账号消息能力 | 用户账号状态 | 账号管理、封禁操作 |
| 双向拉黑、好友关系 | 排序后的双方用户组合 | 拉黑、解除拉黑、好友关系操作 |
| 是否接收陌生人消息 | 接收方设置状态 | 用户设置操作 |

用户组合必须规范化，双方顺序不同不能产生两个状态。分片选择负责定位所有者；每个具体状态有自己的变更顺序，不在一个分片上等待整个操作完成后才处理其他状态。

当前代码中，领域校验和写入分别在 `PostgresV2SocialRelationshipStore`、`PostgresV2AccountPreferenceOperationStore` 和 `V2PostgresAccountDisableService`。这些模块通过 `usingPolicyOwners` 接入同一状态更新入口；`PostgresV2PolicyMutationDispatcher` 在对应状态的事务内调用它们。授权内存统一由 `PostgresV2PolicyOwnerDirectory` 按 account/pair/stranger scope 管理，当前由 `GatewayPolicyAssembly` 托管。Account 与 Operator 的 HTTP 入口路由到这份状态，不能各自另外建立未经同步的内存缓存。这里的领域归属与当前进程托管位置是两个概念。

## 变更路径

1. 统一入口将操作路由到对应状态所有者；同一操作身份的重试合并或返回永久结果，身份冲突拒绝。
2. 同一状态的不同变更按接收顺序执行。等待队列有容量上限；等待中的调用不占数据库事务或连接。其他状态可独立执行。
3. 短事务持久化领域事实、版本和操作结果。在事务内构造最终状态，避免提交后再次查询事实。
4. 等实际 COMMIT 成功后，所有者发布不可变内存状态，再完成调用。事务失败不能发布新状态。
5. 已接受的操作不因调用方取消而丢失。关闭入口后等待实际已接受任务结束；不能通过移除调用等待来宣称数据库已经结束。

内存命中不需要每条消息去数据库核对关系。首次加载从数据库取事实，加载与更新必须受同一状态的顺序约束，旧加载不能覆盖新提交的状态。多进程传播、故障接管和部署切换暂不作为本阶段的完成条件。

## 发送路径与旧实现的替换

私聊读取发送者账号、接收者账号及双方关系；只有非好友分支读取接收方陌生人设置。群聊仍保留成员权限检查，账号规则读取账号状态。准备结果绑定原消息身份，不能拿一条命令的事实快照替另一条命令授权。

准备完成时固定该命令使用的跨房间策略事实；消息事务再结合锁定的房间事实完成业务判定。两者不能混为一谈：非好友且设置拒收陌生人消息时，如果接收方已经在该房间回复，仍可能允许继续发送。房间内回复记录、成员权限、配额等由房间事务校验。业务拒绝也必须走原永久结果写入路径，不能在准备阶段抛出 `blocked` / `strangerForbidden` / `senderInactive` 来替代持久拒绝回执。这里不会因此重新查询数据库中的账号/关系/设置事实。

旧的房间 runtime 路径缓存带持久 registration 的策略快照；旧策略变更会封闭 scope、枚举 holders、等待房间撤销完成，然后提交新事实。该路径仍保留用于原合同的回归测试。

替换时要同时改两边：发送改为读取当前权威内存状态，变更改为提交并发布状态。仅删除 `revoke` 或 `notDrained` 检查会留下仍被复用的房间旧快照，不能作为实现。也不能把每次发送改成重新写一份持久 registration 来假装使用内存。

## 当前实现进度

`PostgresV2PolicyOwner` 已改为每个 scope 保留一个有界变更链。后继操作等待前一个实际任务结束后才进入 journal；不同 scope 不共享这个等待链。恢复操作与正常变更互斥。每次实际变更开始时才推进内存 generation，前一个已提交状态在后继开始之前发布，使永久结果重试可保留正确的内存状态。

Gateway 的 `policyPlacement` 路径现已同时选择 `roomDrainRequired: false` 与 `usesCurrentState: true`。发送从状态 Owner 获取当前事实，构造 `V2CurrentRoomPolicySnapshot`；每次准备重新读取，房间不缓存该策略结果，不创建 holders、策略 registration 或 room policy lease。关系和账号事实的内存命中不进入 SQL；冷加载及所有权续租仍使用既有有界状态读取路径。

准备结果绑定完整命令和 activation，执行前检查原 deadline 与 runtime 是否关闭。实际执行保留有界任务及内存生命周期，等 operation 的实际结果（含 COMMIT）结束才失效；保留的旧执行句柄不能在结束后复用。消息事务继续验证 Room Owner/activation、永久回执、成员与房间规则；它不再验证不存在的账号策略 room lease。策略更新不撤销已授权消息。

新策略变更路径保留 operation 身份、scope 所有权、持久版本、领域事实与结果事务及提交后发布；不枚举房间、不发撤销 RPC、不等待房间 SQL。短事务内捕获最终事实，实际 COMMIT 成功后才更新 Owner 内存，随后回复变更结果。

收敛后的新路径直接在一个事务中获取状态写入权、修改事实、递增版本、记录永久结果及通知义务；不再先提交 beginChange，不持久化中间 pending 标记，不读取撤销目标或更新房间 holders。失败会整体回滚，原状态可重新读取，同一操作可直接重试。旧两阶段路径仍仅用于旧注册合同。当前仍检查是否存在旧 holders，发现混用时明确拒绝，而不执行迁移或撤销等待。

为了避免静默改变旧的注册授权合同，新 journal 拒绝创建 room registration；如果目标 scope 仍有未撤销的旧 holder，新变更在创建 pending 标记之前返回 `notDrained`，不能直接绕过它。当前阶段没有自动迁移旧部署或更改其持久数据。

原消息链路重设计和全链路性能验收仍未完成。该路径的接入不能作为 10,000 在线 / 1,000 msg/s 达标的证据。

本地验证（2026-10-06）：专用 PostgreSQL 25462。`PostgresV2PolicyOwnerTests` 4 项通过，其中新增测试实际阻塞首个操作的房间撤销，确认同 scope 第二个操作保留到首个结束、其他 scope 已提交，并确认等待调用取消后操作仍按顺序持久化。另有 6 项回归通过，覆盖 Owner Directory 容量/驱逐、实际 COMMIT 成功与失败的内存发布、领域事务回滚恢复及内存事实复用。日志分别为 `/tmp/imv2-policy-scope-lane-tests.log` 和 `/tmp/imv2-policy-scope-lane-regression.log`。没有运行容量测试，也未重建 Release。

后续验证：`/tmp/imv2-current-policy-service-tests-r2.log`，13 项测试、3 个 suite 通过（15.039 秒）。新增核心测试覆盖拉黑、解除好友、拒收陌生人消息、封禁四个分支：真实消息事务已经写入、阻塞于 COMMIT 前时，策略变更仍完成，原执行仍在场；隐藏控制库全部策略事实表后，新授权按更新后的内存状态拒绝；释放后原消息提交，执行句柄失效。两个准备/执行入口测试覆盖普通 Owner Batch 与 preborrow、拉黑后永久接受结果重放、解除拉黑后隐藏事实表仍可发送，且事实读取次数不增加、registration 阶段及 holders/room policy lease 数量均为零。还验证旧 holders 不能被新模式静默跳过，以及旧租约路径的 8 个发送变体、冷加载撤销与真实提交发布回归。

`/tmp/imv2-current-policy-group-isolation.log`，3 项测试通过（4.199 秒）：群聊实际接受、只创建一个发送者账号状态、封禁后隐藏账号事实表仍从内存拒绝；远端状态提供者被阻塞且逻辑队列已满时，暖房间与新 runtime 复用本机完整状态并实际提交，等待期间控制 SQL 许可为零。隔离测试同时覆盖新边界和原租约边界。

`/tmp/imv2-current-policy-forward-recovery.log`，1 项参数化测试、8 个变体通过（6.781 秒）：新旧边界分别覆盖私聊/群聊转发，实际消息 COMMIT 后最终化阻塞和失败时允许停用发送者；停止状态 Owner 并隐藏事实表后仍通过原接受结果恢复；缺失不可变证明时明确拒绝恢复。Release 尚未重建，容量测试尚未重跑。

## 验证要求

### 2026-10-06：生产房间恢复与已提交事实保留

`warmRoomPolicyMutationIsolation` 已同时覆盖新旧授权路径。新路径的测试阻塞实际策略 outbox 写入，验证另一个房间通过生产 RoomActivationHost 仍可提交；不再等待不存在的房间撤销。之后隐藏控制库与房间库的全部策略事实表，验证受影响房间拒绝、不相关房间继续发送；恢复拉黑/好友/陌生人设置后再次隐藏事实表，原 activation 的新消息恢复发送，首次展示的账号资料事件不重复生成。`/tmp/imv2-current-policy-restoration.log`：1 项测试、8 个变体通过（7.008 秒）。这是账号/关系/设置的实际入口验证，不是直接更新缓存的模拟。

检查发现 `commitPolicyExecution` 只在所有权租约仍有效时返回捕获的状态，且永久结果重放会丢弃过期状态。这会让一次成功提交在租约到期后退回事实 SQL。现已保留精确提交版本的事实及原始过期截止：过期状态不能作为发送许可；读取必须在 scope 锁下续租，并检查续租前 owner ID、epoch、revision 与缓存一致才复用事实。其他 owner 接管、版本变化及 pending 标记仍禁止直接复用。没有延长租约或免除所有权验证。

`/tmp/imv2-current-policy-expired-commit.log`：9 项测试、2 个 suite 通过（10.611 秒）。新增测试使用一秒租约，在真实 mutation 事务中等待租约到期并隐藏事实表，然后成功 COMMIT；缓存探测仍返回无有效授权，永久回执重放保留已提交事实，续租后同一事实与版本可继续使用，epoch 前进且事实读取次数不增加。原提交失败不发布、不同事实类型续租、接管/版本变化/封闭 scope 及 Owner 操作恢复回归同时通过。

### 2026-10-06：补齐房间规则与永久拒绝结果

检查发现上一版 `V2CurrentRoomPolicySnapshot.requireAllowed` 在准备阶段提前拒绝陌生人设置，也提前拒绝拉黑和停用账号。这既漏掉接收方已回复的房间规则，也绕过消息操作的永久业务拒绝结果。现已移除该方法：准备只读取并绑定内存事实，实际房间事务结合回复/成员等本地事实完成判定及结果持久化，不因此读取数据库中的全局策略事实。

`/tmp/imv2-current-policy-room-rules.log`，4 项测试、13 个参数变体通过（11.822 秒）。新增“拒收陌生人设置 + 对方已回复/未回复”在 scalar、Owner Batch、preborrow 三条路径的 6 个变体；首次发送后隐藏控制库事实表，再次发送结果不变。既有新路径测试加强为检查真实 SQL 的业务拒绝回执：解除拉黑后，原拒绝身份仍重放原拒绝，新身份才允许发送；群聊停用发送者返回永久 `permissionDenied`；四种策略更新先验证新内存事实，再验证房间实际拒绝，原 COMMIT 阻塞测试继续通过。

`/tmp/imv2-current-policy-room-rules-regression.log` 中转发恢复 8 个变体、旧房间策略发送 8 个变体、原陌生人设置及配额测试通过。扩展 TCP 转发到新模式时，测试原先锁定 `room_policy_authorization_leases`，在新模式下没有该记录，导致测试未阻塞实际 SQL。测试现改锁新旧路径都必须检查的持久房间行，并严格要求记录存在。受影响测试重新执行：`/tmp/imv2-current-policy-room-rules-remote-r2.log`，1 项测试、4 个变体通过（8.451 秒），覆盖同 host / 分离 host、新旧授权边界、业务拒绝、原结果重放、响应丢失与取消后真实 SQL 结算。没有增加超时或删去取消期间房间预留检查。

以上是授权边界的验证，未重建 Release、未运行容量验收，也不宣称整体消息重设计完成。

- 同一状态同时收到多个变更，按接收顺序持久化并返回结果；同一身份重试不重复执行。
- 一个状态的变更被阻塞时，另一个状态仍可提交。
- 提交成功才发布新内存状态；回滚、未知提交结果及旧加载不能发布错误版本。
- 修改前后的发送授权分别使用正确状态，拉黑/解除拉黑、解除好友/恢复好友、设置变更和封禁均有真实入口回归。
- 新设计下，已授权消息被故意阻塞时，策略变更可以完成；变更完成后的新授权拒绝旧策略允许的操作，且无需查询事实表或等待该消息。
- 最后独立验证原消息重设计的房间顺序、资源边界及 10,000 在线 / 1,000 msg/s 指标；局部测试不能替代容量验收。

### 2026-10-06：进一步收敛策略修改事务

用户指出设计偏离后，检查确认新授权虽已不等待房间，策略修改仍复用了旧路径的 acquireOwner、beginChange、commit 三个独立事务。这没有必要。现新增 changeCurrentPolicy，新模式直接执行一个事务，完成事实、版本与结果写入，并复用提交后内存发布；尚在执行的消息不参与这个事务。

保留的状态 Owner 用于已有多进程本地服务中定位唯一写入者，避免 Account、Operator、Gateway 分别持有无人更新的缓存；其职责是账号、用户关系和设置状态归属。它不是房间策略租约。此阶段不新增故障接管、部署切换或生产迁移流程。房间成员、回复记录、消息顺序与结果持久化继续由房间负责。

本次验证：/tmp/imv2-current-policy-atomic-tests.log，4 项测试共 11 个变体通过（11.591 秒）；/tmp/imv2-current-policy-atomic-regression.log，18 项测试、3 个 suite 通过（22.519 秒）。同状态顺序测试增加新路径，在真实事务中阻塞首个修改，确认另一状态可提交、同状态后继仍按序提交，等待调用取消不会丢失已接受操作。另覆盖原注册合同、陌生人回复规则、生产房间恢复及转发结果恢复。Gateway 新装配不再创建远端房间撤销器，状态 Owner 使用明确拒绝撤销的回调。前一版 Gateway Release 已构建成功，但此后事务收敛改动尚未重建 Release，不可用旧二进制验收本次改动。

### 最新构建与本地容量结果

Gateway 最新 Release 构建 /tmp/imv2-current-policy-atomic-release-gateway-r2.log 成功（15.83 秒，修复新增拒绝回调缺少 Application 模块导入后）；Account /tmp/imv2-current-policy-atomic-release-account.log 成功（11.08 秒）。随后运行 /tmp/imv2-memory-policy-10k1000-20261006-r13，未通过验收。

12 份负载报告齐全，认证与峰值在线均 10,000；计划 60 秒，实际共同窗口 20.002 秒，提交 19,989、ACK 15,293，质量与覆盖证明失败，不能认定容量完成。2,771 次 SERVER_BUSY，78 次重试耗尽；负载器触发 workload failure guard 后关闭连接，另记录 4,618 次未知结果连接关闭，不能全部当作服务端主动断连。12 个负载器失败退出，服务清理 settled=true、forcedKillCount=0。

有效窗口中有 4 次完整 metrics 采样，首末快照跨度 15.566 秒。阶段计数差分：授权状态读取 11,544 次、平均 555.60 ms；逻辑授权排队 8,859 次、平均 675.04 ms；状态 SQL 事务 8,866 次、平均 27.65 ms；事实读取 8,861 次、平均 9.02 ms；registration 为零。均值范围不同且阶段嵌套，不能相加或当作客户端延迟。客户端报告样本 p95 约 6.2–6.7 秒，仍显著不达目标。

另发现内存容量配置与实际工作集不匹配：本次报告实际 targetsPerConnection=2，fixture 为 10,000 个两成员房间。按生产 scope key 与 SHA256 分片算法重算，账号 + 陌生人设置 + 私聊双方关系合计 30,000 个状态；6 个节点分别负责 5,537 / 5,641 / 5,602 / 5,759 / 3,663 / 3,798 个状态，而每节点最大 Owner 默认 4,096。前四节点无法同时保留其完整状态工作集。证据位于 candidate/policy-working-set-diagnostic.json。这证明配置容量不匹配；尚无直接驱逐计数，不能将全部 SQL 或延迟直接归因于驱逐，也不能靠增加连接/放宽通过条件掩盖失败。

### 2026-10-06：分离运行对象与事实状态的保留

Directory 的 idle Owner 回收原来直接丢弃内存事实，因此 Owner 对象上限也成了事实工作集上限。现增加 Directory 管理的紧凑保留区：只收取已实际结束、无活动使用者的 Owner 状态；重建对象前先取走该状态，再保留被回收对象的状态，避免满额时挤掉本次请求。有效保留状态可直接返回；过期状态交新 Owner，在 scope 锁下续租并核对原所有者、epoch 与版本，再复用事实。关系双方顺序不同仍按规范 key 找到同一状态。

它不是房间的权威缓存：修改先移走保留状态交给唯一 Owner，实际成功提交后的状态才可再次保留；失败修改无法把保留区的旧副本重新用于授权。原 Owner 对象上限 4,096、任务与连接上限不变。Gateway 为额外紧凑状态启用数量上限 4,096、估算保留值字节上限 4 MiB；这是新增的显式事实保留预算，并非声称内存上限完全未增加，也不等同于 allocator RSS。默认构造保持保留区关闭，既有旧合同路径不被隐式启用。新事件计数 owner_hit / retained_hit / miss / owner_evicted / owner_restored / facts_retained / facts_evicted 使用固定标签，随既有物理资源指标导出，不含用户或状态 key。

验证 /tmp/imv2-retained-policy-tests.log：6 项测试、2 suite，通过（5.754 秒）；/tmp/imv2-retained-policy-regression.log：10 项测试、3 suite，通过（13.797 秒）；最终 /tmp/imv2-retained-policy-rollback-tests.log：5 项测试、2 suite，通过（4.522 秒）。生产策略测试仅保留一个运行对象及四份紧凑状态，覆盖真实拉黑提交、真实 COMMIT 失败不发布、同一 operation 重试、双方逆序恢复、租约到期、隐藏全部六张事实表后续租授权且事实 SQL 计数不增加。字节预算测试验证保留区驱逐、真正 miss 会冷读，满额下恢复原状态不额外查事实；取消/关闭仍保留实际数据库任务，关闭清空保留值。

最新 Release 与容量结果尚待本次改动后的重新验证，不能沿用 R13 二进制结论。

### R14：保留区验证后的实际负载与归因纠正

最新 Gateway Release /tmp/imv2-retained-policy-release-gateway.log 构建成功（221.48 秒），Account /tmp/imv2-retained-policy-release-account.log 成功（9.65 秒）。使用相同 fixture、场景、连接和并发预算运行 /tmp/imv2-memory-policy-10k1000-20261006-r14。12 份报告齐全，认证与峰值在线均 10,000；有效共同窗口仍只有 20.004 秒，提交 19,983、ACK 14,947，质量、覆盖与 drain 未通过，不能认为容量验收完成。临时 SERVER_BUSY 3,063 次；重试耗尽后负载器失败率保护触发，关闭时记录 4,945 次未知结果。服务清理 settled=true、forcedKillCount=0，12 个失败退出对应负载器。

新增指标推翻了将本次失败归因于驱逐的假设：最后一次采样 owner_hit=40,243、miss=11,791，owner_evicted / owner_restored / retained_hit / facts_retained / facts_evicted 均为零。静态完整工作集超过对象上限是潜在容量问题，但当前短窗口并未到达该上限；不能把静态计算当作这次 SQL 冷读的实际原因。紧凑保留功能的正确性由单对象测试证明，它在 R14 窗口没有被使用，不能给它归因吞吐收益。

4 个完整窗口内采样的首末快照跨度 15.523 秒，差分 owner_hit=36,967、miss=7,985，仍无驱逐；授权请求 11,425 次、平均 579.40 ms，状态事实读取 8,838 次、平均 9.16 ms，状态事务 8,839 次、平均 27.88 ms；消息正文 7,399 次、平均 36.71 ms，registration=0。诊断保存于 candidate/policy-window-diagnostic.json；阶段均值不能相加，不能外推为 60 秒稳定吞吐。

代码检查确认另一个实际耦合：PostgresV2RemotePolicyOwners.cachedRegistrationStates 仅能探测全本机 scope；包含远端 scope 的请求在调用远端内存前进入 V2PolicyStateRequestScheduler 的冷加载等待队列。远端 Owner 即使已经有内存状态，也只能等调用方排过该队列才被访问。需要为远端已持有状态提供不创建 SQL 的内存探测，再让真实 miss 进入原有有界冷加载路径；现阶段未实现此项，不能宣称热房间已免于远端冷加载排队。SQL 预算、Owner 永久结果与状态写入顺序继续保留。

### 2026-10-06：远端权威内存探测先于冷队列

针对 R14 查明的热/冷请求等待耦合，现扩展已有 authenticated policy claim 的 cachedOnly 标记。缓存探测只调用接收方 Directory.cachedRegistrationStates，未命中返回空结果，不创建 Owner、scope、SQL 任务或续租。客户端仅在 cachedOnly 请求上接受空结果作为 miss；非空结果仍核对 scope 完整性、预期 Owner incarnation、事实类型与截止。服务器入口保留原认证及权限验证。旧 DTO 缺少标记时解码为 false，普通读取合同不变。

PostgresV2RemotePolicyOwners 可显式启用 probesRemoteMemory；Gateway 新模式启用它，既有默认构造仍保持关闭。已持有远端状态从权威 Owner 读取，不在调用方或房间另建长期缓存。真实 miss 继续走原 V2PolicyStateRequestScheduler 的有界冷队列及接收方 SQL 准入，未增加连接或冷工作额度。探测沿用当前房间有界 preparation 根（生产 Collector 最多 128 个）及原 RPC 入口限制，不增加独立后台工作队列；每次分组最多四个 scope，所有子请求实际结束后才完成。传输中过期的状态返回 miss，由普通路径在 scope 锁下续租；错误账号事实仍拒绝，不能变成宽松 miss。

新增 policy_owner_memory_probe 阶段耗时及 snapshot_probe_hit / snapshot_probe_miss 固定计数，完整 policy_owner_state 阶段仍包含探测及真正冷读取，不能与其子阶段相加。

实际验证：/tmp/imv2-remote-memory-probe-tests-r3.log，2 项测试通过（0.983 秒）。旧 DTO 解码、新标记 round trip；真实 TCP 在调用方冷队列 inFlight=1、queued=1 且接收方八个 SQL 根被 scope 行锁阻塞时，四份远端已缓存状态仍成功返回，冷路径回调不能执行；真实 cache miss 不创建 scope，普通冷读保留 overload；错误账号、传输过期、隐藏事实表和后续领域操作亦覆盖。首次测试新增验证查询试图在已占满连接池时借连接而超时，验证查询现放在实际阻塞任务结束之后；没有增加预算。

/tmp/imv2-remote-memory-probe-room-regression.log：7 项测试、2 suite，通过（11.614 秒），覆盖冷等待不占房间 SQL、真实策略修改不等待消息 COMMIT、单对象紧凑状态及真实提交失败、两种准备执行路径。/tmp/imv2-remote-memory-probe-forward-regression.log：1 项测试、4 变体，通过（8.899 秒），覆盖新旧授权、同/分离 host、取消结算、丢失响应及永久结果恢复。

最新 Release 和本次容量结果待完成；上述正确性不能证明 10,000 在线 / 1000 msg/s 达标。

### R15：远端探测生效，准备任务槽仍被冷等待占用

最新 Gateway /tmp/imv2-remote-memory-probe-release-gateway.log 构建成功（213.97 秒），Account /tmp/imv2-remote-memory-probe-release-account.log 成功（9.67 秒）。/tmp/imv2-memory-policy-10k1000-20261006-r15 仍未通过。启动时 12 份 ready 标记严格验证 10,000 在线；失败后仅有 8 份 loader 报告，聚合认证/峰值 6,667、提交 13,313、ACK 9,711 只是这 8 份的合计，不代表完整负载。全局共同窗口=0，不能用缺失报告宣称 60 秒或 10,000 持续在线。可用报告约 20 秒后由 workload failure guard 结束；所有资源 settled=true、无 forced kill，12 个负载器失败退出。

最后一次服务采样 snapshot_probe_hit=8,150、snapshot_probe_miss=5,085，证明新路径确实被采用；没有 Owner/事实驱逐。8 份可用报告覆盖的局部指标区间包含 4 个完整采样、首末跨度 15.523 秒。探测 10,870 次、平均 17.96 ms；完整状态读取 11,406 次、平均 560.90 ms；真正排过冷队列 3,357 次、平均等待 1717.71 ms；状态事务 9,577 次、平均 31.26 ms；消息正文 7,293 次、平均 38.31 ms。命中与 miss 的区间计数为 7,501 / 3,369。这些是不同范围、嵌套阶段的均值，不能相加或外推容量。诊断位于 candidate/policy-partial-window-diagnostic.json。

进一步检查实际资源峰值：六节点 preparation_owner_in_flight_batches 最大为 128 / 128 / 128 / 128 / 128 / 108；policy_state_requests_queued 最大为 78 / 109 / 116 / 109 / 88 / 96，cold inFlight 每节点均达到 5，receiver policy SQL inFlight 也达到 5。准备器在 batches.count 达到 maximumPreparationTasks 时不再启动其他房间，而已启动任务在等待冷准入时仍留在 batches 中。远端内存探测位于这个任务内部，所以拆开 RPC 热/冷队列后，上游准备任务容量仍可能被冷等待耗尽，其他房间不能进入其快速探测。需要将尚未获准的冷等待表达成受命令/字节/截止约束的需求项，执行槽只服务已可推进的准备；等待责任与真实任务仍须保留，不能通过释放计账或遗弃旧任务伪造完成。此项尚未落地，整体目标仍未完成。


### 2026-10-06：策略写入期间继续读取已提交内存状态

核对实际读写链路发现，新模式虽已取消房间撤销等待，但 `PostgresV2PolicyOwner` 仍在修改开始时清空快照，并因存在修改任务拒绝状态读取。这会把同一策略的写入等待带到消息授权，与提交后更新内存的边界不一致。

现已将新模式调整为：开始修改只推进 generation，隔离旧加载的发布；上次已提交且仍有效的状态继续可读。实际事务成功结算后发布新状态再返回修改结果。失败仍清除状态，恢复操作仍与正常读写互斥，过期状态仍不能命中。原 registration/revocation 模式保留原有封闭行为。没有提高任务、连接、队列或截止预算。

`warmRoomPolicyMutationIsolation` 在真实 outbox 写入锁等待期间增加受影响房间的实际发送，覆盖拉黑、解除好友、陌生人设置和封禁。状态读取指标连接到实际 journal，要求冷读计数先大于零，再证明这次发送没有新增事实读取或状态事务；修改根任务仍在场。释放提交后，新消息得到永久策略拒绝；非封禁分支还覆盖反向恢复操作。原模式也继续运行。

`/tmp/imv2-committed-policy-reader-tests-r2.log`：3 项测试、14 个参数变体通过（15.731 秒），包含上述发送、实际 COMMIT 失败不发布、同一操作重试及紧凑事实驱逐回归。`/tmp/imv2-committed-policy-reader-lifetime-tests.log`：5 项测试、2 个 suite 通过（2.299 秒），覆盖过期提交事实、续租、目录容量、取消和关闭结算。此前 `/tmp/imv2-committed-policy-reader-tests.log` 的状态修改顺序及恢复回归也通过。

这证明本次内存读写边界的修正；Release 未重建，容量验收未重跑，整体消息链路重设计仍未完成。


### 2026-10-06：永久结果查询与身份冲突不清除已提交快照

入口核对：Account 的社交操作和陌生人设置操作通过 `policyMutationExecutor` / `usingPolicyOwners` 接入状态所有者；Operator 封禁也使用同一入口。昵称、头像修改不改变 `V2PolicyAccountFacts` 中的授权字段。此核对针对现有应用代码中的写入入口，不把外部管理 SQL 或真实环境传播纳入本阶段证明。

扩展 `PostgresV2RemotePolicyOwnershipTests.distributedClaims`，分别覆盖旧模式和当前内存模式。当前模式不建立 room registration；真实 TCP 路由读取 account/pair/stranger 状态，真实社交/设置操作及 Operator HTTP 封禁返回后隐藏全部六张策略事实表，再经认证 TCP 缓存探测读取提交后的禁用、拉黑和拒收陌生人状态。当前模式的 holders、room policy leases、revocations 均保持零。

第一轮 `/tmp/imv2-current-policy-tcp-tests.log` 未通过：最终缓存探测返回缺失。原因是测试中的同身份不同内容冲突会在永久结果查询之前推进状态变更并清除缓存；正确的冲突响应也让后续合法读取退回事实 SQL。现将无写入副作用的永久结果查询移到 `beginMutation` 之前，同一状态仍按原变更链顺序查询。已完成结果重放、身份冲突或查询失败只结算查询任务，不改变已有快照；确认需要新修改后才推进 generation 和执行修改事务。恢复入口保留独立的结果查询。没有增加一次修改的查询次数，也没有改变永久结果、任务/连接预算或失败事务处理。

修复后的 `/tmp/imv2-current-policy-tcp-tests-r2.log`：7 项测试、2 个 suite 通过（2.574 秒），覆盖真实 TCP/HTTP、当前/旧模式、同身份冲突、状态修改顺序、取消和恢复。`/tmp/imv2-current-policy-result-lookup-tests.log`：5 项测试通过（17.860 秒），包括新增当前/旧模式的真实结果表缺失测试：读取失败后缓存 facts、owner tuple、原 deadline 不变，没有调用领域修改或撤销，实际根任务结算为零；以及提交失败、过期提交、紧凑状态驱逐、四种策略操作期间的真实发送回归。

Release 和容量本轮未重跑。本轮结果证明上述授权内存读写路径，不证明整体吞吐目标已经达到。

### 2026-10-06：重新聚焦授权入口并验证实际准备器

源码核对：Account 的 social/preference 路由通过 `usingPolicyOwners` 接入同一 mutation executor，Operator 的 disable 路由也通过该入口；Gateway 的 current-state 授权通过同一状态路由读取内存。`PostgresV2PolicyMutationDispatcher` 继续使用各领域 store 的事务写入方法；`PostgresV2PolicyOwner` 在实际事务成功返回后发布捕获的最终状态，再返回修改结果。生产组装使用 `roomDrainRequired: false` 和 `usesCurrentState: true`。

补充 `currentPolicyServiceSendAndReplay` 的生产准备器变体：实际经过 `ownerPreparationStages` 和 collector，冷加载并发宽度为 1，覆盖普通执行及 preborrow。首次发送、拉黑后新操作拒绝、原结果重放、解除拉黑后新操作恢复，均经过这条准备路径；隐藏全部六张全局策略事实表后仍能发送，事实读取计数不增加，且不创建房间授权注册记录。原手动两阶段变体保留，继续验证输入归属与原截止约束。

`/tmp/imv2-policy-entry-audit-tests.log`：3 项真实数据库测试、12 个参数变体通过（10.680 秒），包括生产准备器、四类策略修改不等待消息 COMMIT，以及提交成功/失败与内存发布。`/tmp/imv2-policy-entry-warm-room-tests.log`：生产暖房间修改及隔离测试的 8 个变体通过（7.692 秒）。这些证据仅证明上述授权边界，不代表 10,000 在线 / 1000 msg/s 或整个消息重设计已通过验收。

`/tmp/imv2-policy-entry-tcp-tests.log`：2 项测试通过（1.849 秒），其中真实 TCP 入口覆盖新旧授权边界两个变体，并验证 Operator HTTP 停用及修改后的内存读取。此处沿用现有入口验证，没有增加多节点传播或接管实现。

### 2026-10-06：写入入口审计与缓存加载生命周期

核对 `IMV2Server/Sources` 中六张授权事实表的写入：好友及拉黑由 `PostgresV2SocialRelationshipStore` 写入；陌生人设置由 account preference 的事务方法调用 `PostgresV2DirectMessagingStore.applyStrangerMessagePermission`；停用由 `V2PostgresAccountDisableService` 同时写入停用记录与资料状态。生产 Account/Operator 装配将这些入口绑定到统一 policy mutation executor。昵称、头像的两个资料更新入口不修改账号状态或特殊账号消息能力；密码注册插入新的账号资料，由首次状态加载读取。没有发现这四类已有策略修改另有绕过统一入口的生产写入。此审计结论限定当前源码和现有生产入口，不覆盖外部 SQL 或未来新增入口。

新增 `durablePreparationPolicyCacheLifetime`，使用实际 Store 预读和真实、不可变、绑定 Store 的准备句柄，仅在冷加载完成处设置确定性阻塞。验证：缓存命中的另一个房间可以完成；冷队列请求取消后不执行加载；同房间后继在前一准备结束前保持排队，取消后释放；取消实际加载及两个并发关闭请求均不提前归还房间、命令和字节责任，实际加载返回后全部计数归零。没有添加业务机制、增大并发或改变截止。

`/tmp/imv2-policy-cache-lifetime-tests.log`：1 项实际数据库测试通过（0.967 秒），构建成功。该测试证明准备器缓存加载的局部生命周期；不证明 RPC 内部取消、连接租借各阶段或整体容量验收全部完成。

### 2026-10-06：恢复查询不再无故丢弃已提交内存

发现 `PostgresV2PolicyOwner.recover` 在 `pendingChanges` 查询前调用 `invalidateState`。目录后台扫描可能取到随后已完成的操作，或者待恢复查询本身失败；这两种情况都没有执行恢复修改，却会丢弃已发布的内存状态。此处是源码确认的缺陷，不据此推定它导致了 R15 的容量失败。

current-state 路径现将恢复查询与实际恢复分开：只读查询期间保留仍有效的提交状态；查询为空或查询失败仅释放查询根任务，不发布或覆盖任何状态。确认存在 pending 操作后，才使状态失效并推进 generation，阻止旧加载覆盖恢复结果。实际恢复失败仍不保留不确定事实。原 registration 路径继续在恢复开始时封闭读取。

新增 `currentPolicyEmptyRecoveryPreservesMemory` 的两个真实数据库变体：实际锁住待恢复表，使查询处于数据库等待，期间缓存读取仍得到原事实；空查询结束后事实保留；隐藏 journal 表使查询失败后事实也保留。检查无额外事实读取、无 mutation apply、实际根任务归零。新增 `currentPolicyPendingRecoverySealsMemory` 确认发现真实旧 pending 操作时仍清除状态并拒绝静默接管其契约。

修复前 `/tmp/imv2-policy-empty-recovery-before.log`：两个变体产生 6 个断言失败，复现查询期间及查询结束后内存丢失。修复后 `/tmp/imv2-policy-empty-recovery-after.log`：4 项测试通过（9.433 秒），包含真实发送、提交发布与旧恢复。最终 `/tmp/imv2-policy-recovery-memory-regression.log`：9 项测试、2 个 suite 通过（11.171 秒），覆盖上述新测试、Owner 顺序/关闭/恢复，以及暖房间策略更新和缓存加载生命周期。未重建 Release 或重跑容量测试。

### 2026-10-06：合并账号冷加载的行锁读取

R16 的失败诊断后核对账号状态冷读：原先 shared advisory 锁、资料行锁、特殊账号行锁、事实读取各有一次调用。`PostgresV2PolicyOwnerStateReader` 现用一条 materialized CTE 语句消费两个行锁集合，并通过资料 count 的依赖保持 profile → special 的锁顺序，减少一次数据库往返。最终事实读取仍是获取锁后的独立语句，以便在 READ COMMITTED 下取得锁等待结束后的新快照。并发、授权状态有效期、scope 围栏和消息身份约束均未修改。

新增 `accountPolicyColdRowLocksPreserveCommittedFacts` 两个实际 PostgreSQL 变体，分别在另一事务中修改并锁住 profile / special 行。使用 `pg_blocking_pids` 确认冷加载实际处于锁等待；special 等待期间 profile 的 NOWAIT 写锁必须返回 SQLSTATE 55P03；释放阻塞事务后，冷加载读取新提交的 suspended 状态，或 paused 特殊账号及关闭后的服务/客户消息权限。profile 变体同时覆盖不存在 special 行的情况。

`/tmp/imv2-policy-cold-row-lock-tests.log`：5 项测试通过（15.818 秒），包含新行锁测试、冷读取失败回滚、锁等待后的租约到期拒绝、实际发送及暖房间修改隔离。加强 NOWAIT 的精确 SQLSTATE 验证后，`/tmp/imv2-policy-cold-row-lock-state-tests.log` 两个变体再次通过（1.666 秒）。实际往返数量依据源码调用从 4 降至 3；此处仅计账号事实读取阶段，不包含 scope 获取、事务控制和末尾的有效期校验。未以该变更后的 Release 重跑原负载，不宣称其吞吐收益或容量通过。

### 2026-10-06：Owner 预读复用已读取的永久回执

核对 current-state 准备路径发现 `readBudgetSnapshot` 已在同一查询中返回消息操作的永久回执、域指纹及 completed 标记，`readOwnerPreparationInputs` 随后又租借一个连接并查询同一张回执表。现复用预算预读中的回执，继续解码并验证操作身份、操作指纹和域指纹；缺失或损坏的回执字段仍报错。已完成身份不再重新准备策略，最后的实际执行事务仍在操作锁下重复验证永久结果，预算预读不作为执行授权。

加强 `currentPolicyServiceSendAndReplay` 的四个变体：隐藏全部全局策略事实表后，使用已接受身份但更换消息内容，实际事务返回 fingerprintConflict；该请求不增加 policy preparation 计数。既有拒绝结果重放、解封后的新操作、Store 归属、原截止和普通/preborrow/生产 collector 路径继续覆盖。

`/tmp/imv2-owner-preflight-reuse-tests.log`：4 项真实数据库测试通过（10.693 秒），包含上述发送/重放、陌生人拒收与房间回复例外、群聊封禁和缓存加载关闭。该路径少一次连接租借及一次 SQL 回执读取；没有删除最终事务的回执、身份、围栏或配额校验。正在为原负载复测重建 Release，容量结果尚未形成。

R17 已完成 Release 重建及原本地负载复测：启动 10,000 连接，最终报告仅 10/12、质量未通过。局部预读均值降至约 18.34 ms，但 cold queue 等待仍约 2.40 秒；两个 Gateway 在清理请求后非零退出，需要继续定位生命周期问题。详见消息链路落地记录，不能把预读复用的正确性或局部时间下降当作容量通过。

# IM V2 当前设计与实现问题总表

> **这是判断"哪些问题还开着"的唯一文档。**
> 逐批追加的验证过程已移出到 [历史时间线](archive/2026-09-05-remediation-timeline.md)；
> 某个主题当前生效的设计合同见 [合同索引](README.md)。
>
> **状态列的最后复核时点为 2026-09-07。** 2026-09-09 的整改提交
> `3738674b`（307 个源码文件）**尚未回填到下表**，因此"实施中"的条目里有一部分
> 可能已经完成而只是状态列未更新。在状态列回填之前，不要把本表的计数当作
> 当前关闭数；要确认某项是否真的关闭，需按该行链接的合同文档重新核对该合同的验证小节。

审查日期：2026-09-05；运行接线复核更新：2026-09-07。范围：IMApp、ClientKit、Core、Server、协议、PostgreSQL schema、部署与运维证据。

**结论：分层与持久化方向可以保留，但同步恢复、认证生命周期、审批一致性和跨 owner 执行尚未闭环，当前证据不足以宣称生产就绪。**

这是对既有 47 项审查结果的当前状态复核，不是新增 47 个现存缺陷，也不宣称穷尽所有潜在问题。原始 29 项实现问题为 10 P1 / 17 P2 / 2 P3；另有 8 项设计风险和 10 项外部发布缺口。表中优先级保留原始分类，已修复项不再当作现存故障。

状态来源为仓库修复记录，结合本次关键路径静态复核。**“已验证”表示此前修复记录已有相应验证，并不表示本次重新执行了全套测试。** 初次复核未找到上一轮媒体导入临时日志；后续修复批已重新完成双库及媒体回归。最新 B06 reaction 顺序、移除快照和撤回保护的 302 项 ClientKit、170 项 App、8 项服务端测试见 [reaction 验证记录](../../docs/reviews/verification-records.md#20260906-reaction-effects)；此前消息跨流去重的 299 项 ClientKit、170 项 App 测试与源码绑定见 [消息效果验证记录](../../docs/reviews/verification-records.md#20260906-message-effects)；schema 17 媒体路由、Core/ClientKit/App 测试与源码绑定见 [媒体路由验证记录](../../docs/reviews/verification-records.md#20260906-scoped-media)；此前 operator 审计恢复的 104 项测试与源码绑定见 [operator 验证记录](../../docs/reviews/verification-records.md#20260906-forward-operator)；前一轮运行接线和持久暂停恢复的 95 项服务端测试、37 项配置测试与源码绑定见 [运行时验证记录](../../docs/reviews/verification-records.md#20260906-forward-runtime)，先前回执验证见 [回执修复验证记录](../../docs/reviews/verification-records.md#20260905-forward-receipts)。

## 架构判断

- **模块边界基本合理。** SwiftUI App 负责交互，ClientKit 负责认证/SQLite/outbox，Core 保存领域规则，Gateway/Account 提供传输入口，PostgreSQL 保存权威提交。无需因为发现问题而整体重写。
- **可靠性取决于事件组合。** ACK、outbox 和持久游标是基础，但 accepted 与 mutation 分流后，消费者必须处理重复、乱序和缺基线；B03/B06 表明这一合同仍不统一。
- **授权应随内容版本绑定。** 当前成员身份不能证明能看到历史消息或某次编辑。B04 已补这一边界，但跨库授权凭证、交付结果、保留与迁移必须形成完整协议。
- **异步任务必须有唯一所有者和恢复步骤。** generation 能隔离迟到 UI 结果，却不能撤销已经发生的远端 PUT/DELETE。Push、退出和文件擦除要以持久用户意图驱动。
- **优化路径增加一致性成本。** planner/preplanned/room_log/hybrid 应共享授权、幂等结果和投影不变量；单条路径通过不代表模式组合正确。
- **运行入口与组件能力要分别验收。** 当前 PostgreSQL schema 为 30，协议为 27；Gateway 已配置跨库 export 入队和投递运行时，pending/paused 映射为可重试错误；真实双库路由与运行时恢复已通过最终回归。operator 暂停恢复已增加独立入口、审计事务与 owner 栅栏并通过最终双库组合回归；媒体 HTTP 已按消息 owner 路由，个人投影走 user store、设备检查留控制库，provider 返回后再次授权；owner 迁移、终态保留和生产媒体部署仍需闭环。

## 状态汇总

- 已验证：16 项。
- 实施中：14 项。
- 已实现待验证：1 项。
- 待外部验收：2 项。
- 未开始：14 项。

共 47 项，其中 31 项未满足完整关闭条件；这 31 项含待外部验收与验证缺口，不等同于 31 个仍能复现的代码缺陷。

## 完整问题表

| ID | 原优先级 | 问题/风险 | 当前状态 | 当前判断与关闭要求 |
| --- | --- | --- | --- | --- |
| B01 | P1 | 幂等比较可因 revision 整数越界终止 Gateway | 实施中 | 三个命令入口已加边界；资料版本构造/解码、备注与昵称 HTTP、真实资料写入的有符号绑定和递增，以及个人投影最大序号已补[整数边界修复](profile-and-projection-integer-boundaries.md)；媒体、消息状态、跨 owner 与设备 HTTP/APNs 的[时间转换](timestamp-integer-boundaries.md)已补精确检查及回归。客户端禁言入队、会话命令、protobuf 和 SQLite 日期重建已补[客户端边界修复](client-timestamp-integer-boundaries.md)，真实最大时间戳读回崩溃已复现并修复。账号限流已补[策略/SQL 计数/日期绑定边界](account-rate-limit-integer-boundaries.md)，29 项回归含真实 PostgreSQL 上限并发和无写入检查。其他恢复 DTO、计数/递增和时间转换仍需逐入口检查。已补[账号证明与 Gateway 时钟边界](server-clock-integer-boundaries.md)，覆盖非有限时钟、有效期相加越界、心跳状态释放和不缓存的 503；57 项服务端及真实 HTTPS/App/Gateway 回归通过。 |
| B02 | P1 | 编辑旧消息绕过当前群写入权限 | 已验证 | 发送与编辑共用当前发布授权；六类权限变更、普通/大群及双方先提交的 24 个真实 PostgreSQL 并发场景通过。新操作按提交后的权限拒绝，合法原操作只重放原回执，正文/版本/事件/回执不重复写入。最终 91 项相关服务端回归通过，见[提交顺序合同](edit-policy-commit-ordering.md)。全局账号/设备与 owner 完整迁移仍按其他条目验收。 |
| B03 | P1 | room-log 消息的 mutation 缺少原始消息投影，阻塞恢复 | 实施中 | 普通编辑/作者撤回/reaction 已改为读取不可变接受记录决定分发，见[分发归属合同](message-mutation-delivery-authority-contract.md)。新 personal 变更的 fanout 已加入[历史/当前受众交集与精确预留结算](message-mutation-audience-contract.md)。已补齐 [reaction 操作者、普通变更 room pull 的历史授权与 protocol 26 扫描游标](message-mutation-read-contract.md)。新编辑已接通[protocol 27 完整替换与晚到 accepted 保护](message-edit-replacement-contract.md)，撤回与快照重放的[终态合同](message-terminal-projection-contract.md)也已补齐当前分支。回复/置顶及共用内容读取已补[历史引用授权](message-reference-visibility-contract.md)。旧媒体入口也已补[历史授权与兑换完成检查](legacy-media-authorization-contract.md)。仍缺其他读取入口的同等过滤、旧积压缺基线恢复、独立内容撤销和完整快照；当前消费者仍可能因缺依赖阻塞 checkpoint。 |
| B04 | P1 | 转发源缺少消息提交时的成员可见性检查 | 实施中 | 同库历史受众、选中源版本已补；Gateway 已接入跨库持久入队、pending/paused 反馈及有生命周期的后台投递。普通群/大群真实双库测试覆盖运行中入队、停止后积压、重启恢复及幂等。operator 暂停恢复通过双库并发、审计回滚、旧 lease 和恢复后权限拒绝组合回归；媒体 HTTP 已接入精确消息定位与 owner/user/control 三处授权，真实双库附件和模拟器单元回归通过；目标 inbox 新接收、accepted 重试与最终 completed 发布已补[owner 事务栅栏](forward-import-owner-fence-contract.md)，失败保持未终态与源端占用。前台同库路径也已补[来源/目标事务栅栏](foreground-forward-owner-fence-contract.md)，涵盖来源读取、幂等创建/修复、接受和结果补记。仍缺完整 owner 迁移承接、终态 envelope 清理和全局内容封禁，生产媒体与多 owner 清理仍开放。 |
| B05 | P1 | 密码长度规则与 bcrypt 实际输入不一致 | 已验证 | 已切换 Argon2id v19（64 MiB/t=3/p=1），保留 12–1024 UTF-8 字节、拒绝 NUL、不截断或归一化；双线程池固定预算、满额 503、取消不提前归还。旧 bcrypt 保留但限制密码断言，不自动升级；成功认证事务复核完整 PHC 值并原子记录审计/清理失败窗口。39 项回归覆盖官方向量、边界、Unicode、实际突发、旧记录、并发改密和故障回滚。见[合同](password-hash-contract.md)。生产可信恢复/多副本容量与 Linux 验收仍按 E01/E02/E09/E10 跟踪。 |
| B06 | P1 | 同一编辑/撤回经两条事件流到达时不幂等 | 实施中 | 撤回终态已补齐合法版本缺口、快照先到后的源事件重放及旧回复引用清理，见[终态合同](message-terminal-projection-contract.md)。消息 accepted/edit/withdraw/redact 已共享持久事件摘要和事务去重，重复不产生搜索任务，同身份异内容拒绝；跨流重启、旧库回填、快照升级和迟到编辑已验证。reaction 已按 room sequence 处理乱序，保留负状态快照并阻止撤回后复活；群管理新源事件已补 room sequence，权限幂等已改为集合比较，schema 18 的持久策略标记与回执 GC 解耦并通过单条/批量授权及迁移验证；服务端公告和各角色权限快照已按对象 revision 排序并保留空状态；客户端公告已共享持久去重、revision 冲突判断和受控旧库/快照迁移。客户端角色策略现已独立排序并保存显式空集合，缺失角色保持未知；服务端当前态权限基线和不缓存的 owner 复核已验证，protocol 25 的网关、生产组装及客户端传输已验证，客户端角色 reducer、旧正权限行与暂存快照迁移已验证，恢复请求、完整观察点及本地账号/成员/代次栅栏已持久化并验证；自动 runner 与 App 生命周期已接通并验证，暂停反馈与显式重试入口已接通，原子读取、重复提交、失败重试及旧失败交错保护已验证；真实链路及人工交互验收仍待完成。protocol 24 已接通显式个人基线恢复并持久保留重建意图，旧库/重启/跨代及 outbox 保留已验证；服务端置顶快照现已按已知源序号排序并保留取消状态，逆序 fanout 与实际快照 build/read/ACK 已验证，客户端快照 UUID 键兼容已修复；客户端置顶四路 reducer、持久摘要及受控迁移现已验证；服务端当前成员角色快照排序和冲突回滚现已验证；逐成员离开/重入、客户端角色处理、缺序号旧历史权威恢复、群迁移触发、完整保留窗口与代次栅栏仍开放，见 [群管理合同](group-control-effect-contract.md)。 |
| B07 | P1 | outbox 记录了重试时间，却没有到时唤醒任务 | 已实现待验证 | 定时 retry worker 已接入；本批修复跨有限批次从首 lane 重启导致的公平性缺口，并通过[真实 SQLite/protobuf/NWConnection 组合验证](durable-retry-network-contract.md)：发送与编辑安静到期重试、空闲入队、runtime 停止无查询/发包、重开数据库和重连后复用原 ID 完成。26 项相关、390 项客户端及 183 项 App 单元回归通过，另 4 项在线测试跳过。真实 App scene 后台/挂起恢复仍待验收，测试 runtime 重建不代替系统挂起。 |
| B08 | P1 | 认证失效后退出流程依赖已删除的凭据 | 实施中 | 已完成持久交接、独立撤销队列、[证明绑定](proof-bound-issuance-contract.md)及[自动取消与冷启动归属](registration-cancellation-runner-contract.md)。新增[实际 App 两次进程中断恢复](registration-process-interruption-contract.md)：签发和首次取消提交后不转发响应，分别终止 App，真实 Keychain 保存原证明并在第二次重启后完成重放，新登录使用新设备。修复命令行证明设备 ID 编码，真实脚本签发/鉴权/取消通过。新增[旧档案服务端仲裁](legacy-registration-arbitration-contract.md)，持久取消与签发共用锁；[账号证明验证与 HTTP 清理](legacy-registration-http-contract.md)已通过真实密码/HTTPS/事务验收；[ClientKit/App 旧档案恢复](legacy-registration-client-recovery-contract.md)已接线并通过真实 Keychain 和 HTTPS 分层验收；新增[实际 App 旧档案跨进程恢复](legacy-registration-app-process-contract.md)，清理确认前终止后从真实 Keychain 重放并完成新登录/冷恢复；其他退出/换号检查点、真机强杀/锁屏/系统后台验收仍开放。 |
| B09 | P1 | 刷新凭据的终止错误未映射成重新登录 | 已验证 | 业务 HTTP 已统一接入[账号代次与刷新判定](session-http-authorization.md)。真实 App 验收另复现并修复 Gateway 仅以 EOF 表达认证拒绝的问题：现在先返回明确拒绝再关闭连接，数据库故障不误报认证终止。两项真实 App UI、四项真实 HTTPS、64 项服务端和 384 项离线 ClientKit 回归通过；Keychain/SQLite、前后台及冷启动、数据库撤销结果和连接清理均验证，见[完整链路合同](app-gateway-authentication-termination.md)。B08 完整退出/换号与外部部署验收保持开放。 |
| B10 | P1 | 邀请预览与实际提交 token 可指向不同群 | 已验证 | 预览与 token 绑定、取消与 generation 已修复；记录包含 A/B 请求迟到交错回归。 |
| B11 | P2 | 编辑/撤回后重放原 SendMessage 被误判冲突 | 实施中 | 原接受指纹/回执已独立持久化；GC、owner 迁移、竞争条件及新增记录的写放大仍需验证。 |
| B12 | P2 | 房间追赶的一轮预算耗尽后不继续 | 已验证 | 公平追赶 worker 已消费剩余工作；记录覆盖空房间、冷热房间、无新 hint 和取消恢复。 |
| B13 | P2 | 并发 flush 同时取到同一 pending 命令 | 已验证 | outbox 单飞与完成摘要已实现；记录覆盖并发 flush、重复/冲突完成和 SQLite 回滚。 |
| B14 | P2 | 取消单个请求会把迟到响应升级为整条 TLS 失败 | 已验证 | 取消后保留有界 wire correlation 与期限；记录覆盖迟到回复、容量和并行请求。 |
| B15 | P2 | 擦除主 SQLite 时遗漏保存正文的独立搜索库 | 实施中 | 主库/搜索库/sidecar 与账号目录已统一；所有显式擦除入口、旧媒体和真实冷启动仍需闭环。 |
| B16 | P2 | Push 关闭后，迟到的注册仍可重建远端端点 | 实施中 | 服务端条件写、HTTP、SQLite 173 持久状态、自动单飞 reconciler 及 App 开关/状态观察/退出已接入；真实网络最终状态、账号切换/重启/退出组合仍未闭环。见[App 合同](push-intent-app-contract.md)。 |
| B17 | P2 | 连接恢复后，仍打开的会话不重建实时订阅 | 已验证 | runtime 共享订阅与连接代次恢复已接入；记录覆盖多 scene、迟到 ACK、typing/presence 与重连。 |
| B18 | P2 | 800 条滑动窗口使更旧搜索命中无法定位 | 已验证 | 已改为同快照索引定位及前后有界窗口，并修正真实滚动行 ID。1k/100k 历史、活动同键、授权/撤回、取消/刷新、真实 App 滚动及原 bug 负向回归通过；见[定位合同](timeline-location-contract.md)。 |
| B19 | P2 | 搜索连续加载可重复追加同一页 | 已验证 | 分页单飞、结果去重与查询代次已补；记录覆盖取消、旧结果、筛选变化和游标停滞。 |
| B20 | P2 | 搜索索引建好后页面仍停在 indexing | 已验证 | 已观察索引 generation/ready，完成后自动重查；保留为已修复历史问题。 |
| B21 | P2 | 实时刷新把已加载会话/联系人分页重置为第一页 | 已验证 | 已保留有界分页窗口与锚点，并合并后台变更；保留为已修复历史问题。 |
| B22 | P2 | 文件时间戳 API 缺少 App 隐私清单声明 | 待外部验收 | 已加入文件时间戳隐私声明并有 Debug 包检查记录；正式归档合并报告与发布验收待完成。 |
| B23 | P2 | 跨邀请并发申请可突破每人 20 条待审上限 | 实施中 | 单库入口已采用申请人事务锁，真实锁屏障证明旧版 19→21、修复版保持 20；重复与释放回归通过。control 全局 reservation、owner 终态释放和双库验证仍开放，见[配额合同](invitation-applicant-quota-contract.md)。 |
| B24 | P2 | 待审批游标随着审批状态变化而失效 | 已验证 | 已用不可变时间/ID 游标，锚点不必继续 pending；记录覆盖审批、删除锚点与精度。 |
| B25 | P2 | 已耗尽链接不展示，却继续占满活跃链接额度 | 实施中 | 耗尽链接的计数与筛选已修；管理历史展示及审批关联一致性仍在跟踪范围内。 |
| B26 | P2 | 审批冲突重试后未持久化实际 membership revision | 实施中 | 新审批已改为单库单事务：成员/admission/event/outbox/邀请记账和决策一并提交，保存实际 revision 与成员结果回执；schema 20 决策唯一键、三处故障回滚、并发重放及普通移除竞争已通过。旧 approving 恢复已按 D05 验证；生产 owner 路由、迁移交接及进程崩溃/真实 HTTP ACK 丢失组合仍需完成，见[合同](atomic-group-approval-contract.md)。 |
| B27 | P2 | 新增邀请链路没有按群所属数据库路由 | 实施中 | Account 已接通持久 owner/epoch 和 control 身份，schema 23 移除四个身份外键；独立 control＋两个无 profile 副本 owner 的两种分发模式、创建中断、全部邀请操作、旧缓存及未知 owner 已验证。schema 24 已接入持久后台恢复，长时间重试的状态/额度判断、租约/退避/取消及并发恢复已验证。历史 owner 已有链接的创建重试现沿用原 ID/时间，发布失败可后台恢复，矛盾绑定仍拒绝，见[兼容合同](group-invite-legacy-binding-contract.md)。schema 25 已接入独立 operator 的分页目录导入、不可变审计和整页冲突回滚，见[导入合同](group-invite-directory-import-contract.md)。普通成员、消息编辑/撤回/reaction、公告/置顶/权限/成员角色、moderation 及群已读回执/读者列表现保留所选 owner epoch，在回执重放前于事务内验证，见[成员栅栏](room-membership-owner-fence-contract.md)、[消息变更栅栏](message-mutation-owner-fence-contract.md)、[群管理栅栏](group-capability-owner-fence-contract.md)、[moderation 栅栏](moderation-owner-fence-contract.md)和[群回执栅栏](read-receipt-owner-fence-contract.md)；普通发送、私聊冷/暖批量、大群集合写已补[发送事务栅栏](send-message-owner-fence-contract.md)，Gateway 同库也保留 route/epoch。后台转发目标接收/accepted 重试/完成发布也已补[导入栅栏](forward-import-owner-fence-contract.md)。前台同库转发已补[来源/目标事务栅栏](foreground-forward-owner-fence-contract.md)，保留批量来源读取和有界并发。发送 control 身份/策略隔离、其他读取与 worker、投影及活跃任务迁移承接、完整 owner 历史迁移仍开放。 |
| B28 | P3 | VoiceOver 筛选值朗读内部 UUID | 待外部验收 | 筛选朗读已改为显示身份；真实 VoiceOver 朗读/焦点与真机验收未完成。 |
| B29 | P3 | 当前协议版本文档已漂移 | 已验证 | 协议文档门禁已补，本次实际通过；当前协议 27。 |
| D01 | P2 | 旧 TLS reader 的迟到失败可能关闭新连接 | 已验证 | [连接代次隔离验收](network-generation-fencing.md)已补确定性真实 NWConnection 回调：旧 reader 已进入接收、旧队列暂停、新连接请求已到达后才释放旧失败；新请求成功。临时移除 close 代次保护时同用例按预期失败，恢复后 9 项生命周期及完整客户端回归通过（392 项含 4 项在线跳过，388 项实际执行）。此用例使用 loopback TCP，验证回调隔离，不代替 TLS 证书/部署验收。 |
| D02 | P2 | Push handler 依赖页面出现，无 scene 冷启动不能恢复会话 | 实施中 | 已改为 App delegate 初始化持有共享 store 并注册 handler；页面与 Push 共用有所有权和期限的恢复操作，后台初始不启动完整前台循环。Push 恢复与增量同步共享绝对截止，短等待方不取消其他使用者。见[共享启动合同](shared-app-restoration-contract.md)。已补[真实凭据的无根页面入口验证](headless-push-entry-contract.md)：独立 delegate/store 不创建根页面，经 Keychain、TLS 与 SQLite 完成恢复、重放和远端撤销；系统无 scene 冷启动、APNs、锁屏/首次解锁与 completion 时限仍需验收。 |
| D03 | P2 | 后台 Push 跑完整 runtime，缺总时间预算 | 实施中 | 已接入[专用后台 runner](bounded-incremental-sync-contract.md)：默认 25 秒工作截止、个人/room-log 合计 4 页、每页 100 条、reset 延后；独立连接在超时/前台恢复/退出时取消排空，Push 不再启动完整 runtime 或等待完整退出。新增同步 gate、可取消共享认证等待及真实 SQLite 新增计数，取消后迟到写入已反向复现并修复。新增[真实网络期限验证](../../docs/reviews/verification-records.md#20260906-background-network-deadlines)，覆盖 TLS/Hello/认证/pull/ACK 挂起、关闭及凭据保留，四个协议阶段重连成功，ACK 重放不算新增；最终 402 项客户端实际执行通过，另 4 项在线测试跳过。188 项 App 单元为上一批结果，本批未重跑。仍需实际 Push/真机截止与额外 5 秒收尾、锁屏及前后台交错验收；D02 无 scene 冷启动独立开放。 |
| D04 | P2 | 媒体文件和缩略图缺账号/安装级生命周期 | 未开始 | 账号目录隔离已有基础，但媒体任务、旧目录、缩略图与安装失配的清理链路尚不完整。 |
| D05 | P2 | 原审批人失去权限后，孤立 approving 无接管路径 | 已验证 | 已增加独立 operator 认证入口、owner/epoch 检查、100 条分页、单事务补记账或退回 pending、不可变审计及旧 operation 阻断。已提交后离群/审核人禁用、缺失或冲突证据隔离、在途旧写与恢复竞争、双 owner 分页及 schema 21 迁移均通过，最终 15 项回归通过。释放判断要求完整历史区间；未来历史裁剪与在线 owner 迁移仍按 B27/D08 验收，见[合同](group-approval-recovery-contract.md)。 |
| D06 | P2 | 待审申请缺少申请人取消或清理机制 | 未开始 | 待审申请缺申请人取消/TTL；无人审批可长期占满个人额度。 |
| D07 | P2 | 不同消息路径重复实现授权、准入和投影规则 | 实施中 | 部分授权与接受回执已共享；单条与批量 PostgreSQL planner 已共用分页、受众及结算实现。planner/preplanned/room_log/hybrid 的其余准入和投影规则仍需统一合同。 |
| D08 | P2 | 关键状态机的组合测试不足，能力证据描述过宽 | 未开始 | 组合故障测试与能力声明尚未逐项闭环；通过单元测试不能替代双流、审批中断、跨 owner 和冷启动验收。 |
| E01 | 发布验收 | 生产部署、密钥、证书与 operator 入口 | 未开始 | 生产拓扑、密钥管理/轮换、TLS、operator 权限及回滚需真实环境验收。 |
| E02 | 发布验收 | 生产 Passkey / WebAuthn | 未开始 | 生产 WebAuthn verifier/challenge/counter 与真实注册登录证据未闭环。 |
| E03 | 发布验收 | 生产媒体存储、扫描和 CDN | 未开始 | 本地文件/EICAR 适配器不是生产存储与扫描验收；需对象存储/CDN、扫描失败与保留策略验证。 |
| E04 | 发布验收 | 真机、多端、无障碍和签名 | 未开始 | 签名归档、真机多端、Keychain 锁屏/重启、相机与无障碍证据未闭环。 |
| E05 | 发布验收 | 真实 APNs | 未开始 | 真实 APNs 凭据/profile、失效 token、后台冷启动与用户开关组合未闭环。 |
| E06 | 发布验收 | NATS 生产安全和可观测性 | 未开始 | NATS 安全、指标和分区/重连长稳未闭环；需证明提示丢失后持久游标仍能恢复。 |
| E07 | 发布验收 | WAL/PITR、RPO/RTO 和灾备 | 未开始 | 逻辑备份不代表 WAL/PITR；需时间点恢复、密钥恢复、故障切换和 RPO/RTO 演练。 |
| E08 | 发布验收 | 远端 CI / 干净 checkout 证据 | 未开始 | 当前工作区有大量未提交变更；缺与最终代码一致的干净 checkout/远端统一门禁证据。本次未查询账户额度。 |
| E09 | 发布验收 | 完整混合负载、长期运行与多 Gateway/分片容量 | 未开始 | 容量数字只适用于原 workload；需同一 binary 的混合消息、热点、多设备、多 Gateway/owner 与长期故障验证。 |
| E10 | 发布验收 | ARM64 Linux 压力下历史 SIGSEGV 根因未关闭 | 未开始 | 历史 ARM64 Linux SIGSEGV 仍缺符号化根因；一次未复现不能关闭，需原始 core 与同版本长稳。 |

## 本次复核的直接代码证据

以下行号对应本次工作区，不沿用原始审查时的旧行号。

| 事项 | 当前证据 | 结论 |
| --- | --- | --- |
| B03/B06 缺基线/重复变更 | [GRDBV2LocalSyncStore.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 与 V2LocalMessageEffect 共用消息效果记录 | 重复消息效果与旧编辑已有处理；新完整编辑可建立合法基线并跨版本，旧文本 delta 的缺基线/缺版本仍拒绝，旧积压需 B03 持久恢复；reaction 已有顺序与负状态，其他对象未统一 |
| B04 跨库主路径 | [V2RoutedForwardMessagesService.swift](../../IMV2Server/Sources/IMV2Server/V2RoutedForwardMessagesService.swift) 已配置跨 owner service；[Gateway 组装](../../IMV2Server/Sources/IMV2ServerApp/main.swift) 使用该 router 并启动、取消和排空投递运行时 | 真实双库 router/runtime 已验证；主程序编译通过，尚未启动真实 Gateway/App 做端到端验收 |
| B04 媒体导入 | [V2ForwardMediaImportWorker.swift](../../IMV2Server/Sources/IMV2Server/V2ForwardMediaImportWorker.swift)、[PostgresV2ForwardMediaImportStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2ForwardMediaImportStore.swift)、[本地复制器](../../IMV2Server/Sources/IMV2Server/V2LocalFilesystemForwardMediaCopier.swift) | 有复制、扫描、lease、重试及 fencing 实现；后续批已重新验证 13 种媒体场景，见持久日志 |
| B04 媒体下载 | [V2RoutedMediaDownloadService.swift](../../IMV2Server/Sources/IMV2Server/V2RoutedMediaDownloadService.swift) 与 Account room/user registry | schema 17；消息 owner、用户投影和控制库设备分别授权；15 个下载场景与实际转发附件读回通过，仍需生产媒体和 owner 清理验收 |
| B04 保留释放 | [PostgresV2ForwardExportStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2ForwardExportStore.swift)、[PostgresV2MediaRetentionStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2MediaRetentionStore.swift) | export 配额与源媒体 pin 必须配套终态回执/释放，不能只增加不可变记录 |
| B05 密码边界 | [V2PasswordHashWorker.swift](../../IMV2Server/Sources/IMV2Server/V2PasswordHashWorker.swift) 与 [V2PasswordAccountStore.swift](../../IMV2Server/Sources/IMV2Server/V2PasswordAccountStore.swift) | 完整输入 Argon2id、有界 worker、旧记录限制及认证后事务复核已验证；修复前 HTTP 反例 9 issues 与最终 39 项回归分别留证 |
| B16 Push 竞态 | [V2PushWakeSettings.swift](../../IMApp/IMApp/V2/V2PushWakeSettings.swift)、[V2PushIntentReconciler.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2PushIntentReconciler.swift) 及服务端版本条件写 | 旧 register/remove 链路已替换；持久最终意图、单飞和版本拒绝已分层验证，真实网络与 App 账号生命周期组合仍待验收 |
| B18 历史定位 | [V2ConversationDetailStore.swift](../../IMApp/IMApp/V2/V2ConversationDetailStore.swift) 的 loadTimeline 与 SQLite conversationTimelineWindow | 数量增长循环已删除；直接按消息和活动共同排序定位，800 条保留上限不再阻断导航；真实 SwiftUI 滚动已验证 |
| B23 配额 | [PostgresV2GroupInvitationStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 submit | 单库已改为 applicant 事务锁，等待后重新计数；各 owner 仍须共同使用 control 的唯一配额预留 |
| B26 审批恢复 | [PostgresV2GroupInvitationStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 approve | 新请求单事务提交；旧 approving 通过独立 operator 按确切操作和完整历史证据恢复，审计及旧操作阻断同事务 |
| B27 owner 路由 | [Account 主入口](../../IMV2Server/Sources/IMV2AccountServerApp/main.swift) 的 groupInvitations 组装 | 已组装 V2RoutedGroupInvitationStore；持久 route/epoch、control 身份及 token 目录已接入 |

## 修复顺序与验收要求

1. **优先消除核心阻断和授权缺口：B03/B06、B05、B01 剩余边界。** 同一个事实重复到达不得回滚整个同步；缺基线恢复不得泄漏入群前历史；密码规则需覆盖兼容迁移。
2. **闭环用户状态：B08/B09/B15/B16、D01–D04。** 验收认证失效、锁屏、断网、退出、杀进程与 A→B→A 的交错，观察磁盘与远端状态，不能只断言 UI。
3. **闭环持久多阶段事务：B04/B11/B23/B26/B27、D05/D06。** 验收提交后 ACK 丢失、重复投递、lease 接管、owner epoch 变化、额度与保留释放。跨库操作避免依赖跨数据库长事务。
4. **收敛模式合同并完成发布证据：D07/D08、E01–E10。** 用同一最终版本验证各投递模式和实际环境，记录测试范围与未覆盖项，避免用历史容量数字外推当前部署。

本次实际完成 `git diff --check` 与 `python3 scripts/check_v2_protocol_documentation.py`，均通过。未重跑 Swift/App/PostgreSQL 全套测试，未查询远端 CI/APNs/生产系统，未把历史日志记作本轮成功，也未修改业务源码或部署。

详细原始触发条件、影响、历史实验和建议见 [原始审查](archive/2026-09-05-system-design-implementation-audit.md)；逐批实现与证据见 [修复进度](archive/2026-09-05-system-remediation-progress.md)；执行依赖见 [修复方案](archive/2026-09-05-system-remediation-plan.md)。原始审查的代码行号对应审查基准，不保证与已修改文件一致。

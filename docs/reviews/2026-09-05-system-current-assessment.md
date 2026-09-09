# IM V2 当前设计与实现问题总表

审查日期：2026-09-05；运行接线复核更新：2026-09-07。范围：当前工作区（包括未提交修复），IMApp、ClientKit、Core、Server、协议、PostgreSQL schema、部署与运维证据。

**结论：分层与持久化方向可以保留，但同步恢复、认证生命周期、审批一致性和跨 owner 执行尚未闭环，当前证据不足以宣称生产就绪。**

这是对既有 47 项审查结果的当前状态复核，不是新增 47 个现存缺陷，也不宣称穷尽所有潜在问题。原始 29 项实现问题为 10 P1 / 17 P2 / 2 P3；另有 8 项设计风险和 10 项外部发布缺口。表中优先级保留原始分类，已修复项不再当作现存故障。

状态来源为仓库修复记录，结合本次关键路径静态复核。**“已验证”表示此前修复记录已有相应验证，并不表示本次重新执行了全套测试。** 初次复核未找到上一轮媒体导入临时日志；后续修复批已重新完成双库及媒体回归。最新 B06 reaction 顺序、移除快照和撤回保护的 302 项 ClientKit、170 项 App、8 项服务端测试见 [reaction 验证记录](evidence/20260906-reaction-effects/manifest.json)；此前消息跨流去重的 299 项 ClientKit、170 项 App 测试与源码绑定见 [消息效果验证记录](evidence/20260906-message-effects/manifest.json)；schema 17 媒体路由、Core/ClientKit/App 测试与源码绑定见 [媒体路由验证记录](evidence/20260906-scoped-media/manifest.json)；此前 operator 审计恢复的 104 项测试与源码绑定见 [operator 验证记录](evidence/20260906-forward-operator/manifest.json)；前一轮运行接线和持久暂停恢复的 95 项服务端测试、37 项配置测试与源码绑定见 [运行时验证记录](evidence/20260906-forward-runtime/manifest.json)，先前回执验证见 [回执修复验证记录](evidence/20260905-forward-receipts/manifest.json)。

最新补充：服务端公告和各角色权限快照已按对象 revision 排序并保留空状态；真实逆序分发、迟到旧事实、同版本冲突及此前权限保留/迁移/跨 owner 回归共 **24 项服务端测试 / 4 个套件** 通过，见 [策略快照验证](evidence/20260906-group-policy-snapshots/manifest.json)。客户端群控制 reducer、完整基线恢复、置顶历史和成员角色边界仍未关闭，B06 状态不变。

最新补充：protocol 24 已实现显式个人快照重建与 SQLite 持久意图，主库增至 166 个对象；响应丢失、重启、跨代恢复、outbox 保留、空账户及真实 ACK/设备撤销路径已验证。ClientKit **305 项 / 52 套件**、App **170 项 / 17 套件**、服务端定向回归 **56 项 / 6 套件**通过，见[个人基线恢复证据](evidence/20260906-personal-snapshot-rebuild/manifest.json)。群控制 reducer 迁移触发、历史负事实和独立房间日志恢复仍待完成，B06 状态不变。

最新补充：客户端公告已统一个人/预览/房间/快照的 revision 排序和持久去重；旧库未知来源不再以个人游标冒充，旧暂存快照升级重新导入，迁移不恢复已清除公告。最终 **309 项 ClientKit / 52 套件、170 项 App / 17 套件**通过，见[公告效果证据](evidence/20260906-announcement-effects/manifest.json)。SQLite 主库为 167 个对象；protocol 24、PostgreSQL schema 18 不变。各角色权限、置顶和成员角色仍待完成。

最新补充：角色权限恢复的服务端当前态基线、成员检查及不缓存的 owner 复核已实现。默认/显式空策略、GC/迁移、并发版本一致性、退群重入和实际控制库 epoch 变化已验证；**82 项 Core / 25 套件、29 项服务端定向回归 / 6 套件**通过，见[权限基线证据](evidence/20260906-policy-baseline/manifest.json)。此基础读取批尚未接入网关；后续协议接线见下文，客户端持久恢复和各角色 reducer 仍未完成。

最新补充：protocol **25** 已接通当前角色权限基线的认证网关、各 owner 生产组装和 ClientKit 传输，保留显式空策略并拒绝非法角色、权限、版本和响应关联。最终 **82 项 Core / 25 套件、312 项 ClientKit / 53 套件、170 项 App / 17 套件、72 项服务端定向回归 / 8 套件及 14 项编解码与监控回归 / 2 套件**通过，见[协议接线证据](evidence/20260906-policy-wire/manifest.json)。客户端持久恢复、各角色独立版本及迁移仍未接入，B06 不关闭；以上是分层测试，未执行真实 App 到 TLS 网关端到端验收。

最新补充：客户端角色权限已统一个人/预览/房间/快照的独立 revision 排序、来源冲突检查和空集合持久状态。旧库保留观察到的正权限值，不以个人游标伪造源版本；缺失角色保持未知，旧暂存快照重新导入。最终 **317 项 ClientKit / 53 套件、170 项 App / 17 套件**通过，见[角色效果证据](evidence/20260906-role-policy-effects/manifest.json)。SQLite 为 **168/5** 个对象；protocol 25、PostgreSQL 18 未变。持久基线恢复、账号/成员栅栏、置顶和成员角色仍待完成，B06 状态不变。

最新补充：客户端权限基线已增加持久恢复请求、独立完整观察点和账号/安装/成员/同步代次事务栅栏。重启、读取期间新事件、过旧响应保留意图、退群重入、小写 UUID 本人识别、账号变化、快照保留/移除及 staging 迁移已验证。最终 **322 项 ClientKit / 53 套件、170 项 App / 17 套件**通过，见[恢复存储证据](evidence/20260906-policy-recovery-store/manifest.json)。SQLite 为 **170/5** 个对象；自动 runner、认证连接生命周期和 App 接线仍待完成，B06 不关闭。

最新补充：权限恢复 runner 已按持久 nextAttemptAt 自动发现/重试，并接入 App 认证连接后台任务。单房间失败隔离、暂停/显式存储重试、FORBIDDEN、取消或成员变化后的迟到结果、无提示发现、旧请求迁移和 runtime stop 已验证；App 自动刷新权限并防止旧读取覆盖恢复结果，编辑草稿保留原 expectedRevision。最终 **327 项 ClientKit / 53 套件、171 项 App / 17 套件**通过，见[执行器证据](evidence/20260906-policy-runner/manifest.json)。SQLite 为 **171/5** 个对象；暂停状态的 App 反馈/重试入口、真实网络及权限弹层交互验收仍开放，B06 不关闭。

最新补充：权限策略与恢复状态已在同一次 SQLite 读取中返回，App 区分等待同步、排队、暂停和不可读取，并提供持久显式重试入口。重复提交、失败后再试、能力缺失、旧请求失败与新状态交错及通知范围已验证。最终 **329 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[状态与重试证据](evidence/20260906-policy-recovery-ui/manifest.json)。protocol 25、PostgreSQL 18、SQLite 171/5 未改；真实 TLS、弹层点击和无障碍人工验收仍开放，B06 不关闭。

最新补充：服务端置顶投影已按源房间序号比较并保留取消置顶负状态；实际逆序分发、日志清理后的重复、快照构建/读取/ACK 和冲突回滚已验证。ClientKit 同步修复群管理快照键的等价 UUID 拼写误拒绝。最终 **19 项服务端定向回归 / 4 套件、331 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[置顶快照证据](evidence/20260906-pin-snapshots/manifest.json)。客户端置顶 reducer、缺源序号的旧历史恢复、统一 worker 切换及成员角色仍开放，B06 不关闭。

最新补充：ClientKit 置顶四路消费已共享持久摘要、源序号排序及取消负状态。旧库个人游标丢弃为未知，可信房间日志回填，旧 staging 重导入并保留 outbox；普通/hybrid 快照、来源冲突、元数据补齐和本人退群清理已验证。最终 **339 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[置顶效果证据](evidence/20260906-pin-effects/manifest.json)。SQLite 为 **172/5**；置顶缺源历史权威恢复、成员角色及完整授权代次/保留合同仍开放，B06 不关闭。

最新补充：服务端成员角色快照已按 room/target 的 membership revision 排序，旧管理员角色不能覆盖仍保留的新 member 事实，同版本不同来源拒绝并回滚用户 checkpoint。真实角色提交、逆序 fanout 与快照 build/read/ACK 等 **22 项服务端定向回归 / 4 套件**通过，见[成员角色快照证据](evidence/20260906-member-role-snapshots/manifest.json)。本批未新跑 ClientKit/App；逐成员离开/重入负状态、客户端处理和旧历史恢复仍开放，B06 不关闭。

最新补充：B16 已加入服务端 Push 会话 CAS、持久意图版本和禁用记录，低版本拒绝、同版本幂等/冲突、端点代次保护及原子回滚已通过真实数据库回归。PostgreSQL 更新为 **19**；Core **84 项 / 26 套件**、服务端定向回归 **23 项 / 4 套件**通过，含旧迁移链修正，失败及最终日志均见[Push 存储证据](evidence/20260906-push-intent-storage/manifest.json)。HTTP/客户端/App 尚未接通版本机制，B16 为实施中；现有 App 竞态仍开放。

最新补充：B16 版本路由已接入 Account 认证/限流入口，ClientKit 增加设备绑定的会话与意图传输。真实 HTTP pipeline＋PostgreSQL 反序写入和 legacy 拒绝、输入/错误映射及限流已验证，**343 项 ClientKit / 54 套件、10 项服务端 / 4 套件、176 项 App / 17 套件**通过，见[HTTP 证据](evidence/20260906-push-intent-http/manifest.json)。App 仍走旧链路，持久意图执行器及其接线继续开放。

最新补充：B16 本地单行状态已保存偏好/desired、单调版本、claim、token 随机引用和重试/暂停，并以完整状态比较保护执行器接管和迟到结果。重开数据库、pending reset 迁移保留待发消息、退出偏好、账号/安装/设备隔离及事务回滚已验证；**348 项 ClientKit / 55 套件、176 项 App / 17 套件**通过，见[本地 Push 证据](evidence/20260906-push-intent-local/manifest.json)。SQLite 为 **173/5**，自动执行器和 App 接线仍开放。

最新补充：B16 自动执行器已实现本地输入合并、HTTP 单飞、自动发现、持久退避/429 等待、原 claim 重试、stale 暂停和停止排空。实际 SQLite 观察/计时器、旧请求等待期间关闭、重开数据库、旧 owner 回包等已验证，**355 项 ClientKit / 56 套件、176 项 App / 17 套件**通过，见[执行器证据](evidence/20260906-push-intent-reconciler/manifest.json)。App 仍走旧设置链路，状态观察、退出及账号生命周期接线继续开放。

最新补充：B16 App 开关、APNs 回调、持久状态观察、用户偏好备份及退出移除已接入版本执行器；注册期间可关闭，失败自动重试，并发停止共同等待排空后才关闭数据库。最终 **355 项 ClientKit / 56 套件、176 项 App / 17 套件**通过，编译失败与修正过程见[App 接线证据](evidence/20260906-push-intent-app/manifest.json)。真实 HTTPS/服务端最终状态、App 账号切换及退出组合仍开放，B16 不关闭。

最新补充：B16 Push 请求已绑定认证代次，获取凭据/发送/响应均复核；同设备重新登录后的旧请求取消，退出先排空旧 owner，再用清理代次和更高版本禁用。真实认证 actor＋SQLite＋受控 HTTP 组合及相同代次刷新通过；最终 **361 项 ClientKit / 57 套件、176 项 App / 17 套件**通过，见[认证隔离证据](evidence/20260906-push-intent-auth/manifest.json)。真实网络、持久退出及完整 App 换号验收仍开放，B08/B09/B16 状态不变。

最新补充：B18 已闭环本地历史定位。目标主键与前后索引 seek、共同排序、装饰及授权/撤回读取在同一 SQLite 快照内；10 万条历史和置顶负记录下查询步数保持有界，App 取消/刷新/更晚目标与实际滚动通过。恢复原裸滚动 ID 的负向实验只触发对应回归失败；最终 **365 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，见[定位证据](evidence/20260906-timeline-location/manifest.json)。B18 更新为已验证，其他问题状态不变。

最新补充：B23 单库配额竞态已通过真实锁屏障复现并修复。19 条 pending/approving 占位下两个不同邀请并发提交，旧实现最终为 21，修复版为 20；重复 operation、输入冲突和拒绝后重用名额通过。最终 **6 项服务端测试 / 2 套件**通过，见[配额证据](evidence/20260906-invitation-applicant-quota/manifest.json)。本批未改 schema，control 全局 reservation 和跨 owner 释放仍待实现，B23 为实施中。

最新补充：B08 的仅撤销凭据已完成类型、摘要存储和兑换事务，PostgreSQL 为 **27**。认证/刷新误用拒绝、刷新后撤销、会话绑定变化、10 个并发重复、失败回滚、新会话隔离及期限已通过真实数据库验证；**93 项 Core / 30 套件、16 项服务端单元 / 2 套件、20 项真实 PostgreSQL 回归 / 1 套件**通过，独立 26→27 迁移及 schema 正反向门禁通过，失败过程保留于[验证证据](evidence/20260907-revocation-capability-storage/manifest.json)。内部签发尚未接入登录响应，HTTP/ClientKit/App 尚未接线，见[存储合同](device-revocation-capability-storage-contract.md)。B08 保持实施中，47 项总表仍为 16 项已验证、31 项开放。

最新补充：B08 已接通[仅撤销 HTTP 与 ClientKit 传输](device-revocation-capability-http-contract.md)，Account 入口纳入 trusted-edge 和持久地址限流，严格限制目标输入；独立客户端不读取或刷新当前账号凭据。**20 项服务端单元 / 4 套件、4 项真实 PostgreSQL 回归 / 1 套件**通过；ClientKit **421 项报告 / 66 套件，416 项实际执行、5 项在线跳过**，见[证据](evidence/20260907-revocation-capability-http/manifest.json)。真实数据库 HTTP pipeline 验证 503 完整回滚、204 幂等、429 保留新设备；本批未执行 HTTPS socket/App 全链路。登录交付及 App 持久补偿仍未完成，B08 保持实施中，16 项已验证、31 项开放。

最新补充：B08 已修复[签发取消与活动旧凭据替换](credential-issuance-boundaries-contract.md)。四个取消挂起点原先仍发送 HTTP（14 个失败断言），活动旧凭据也可被直接覆盖（4 个失败断言），另补 URLSession 取消分类。最终 **439 项客户端实际执行（5 在线跳过）、195 项 App 实际执行（1 在线跳过）**通过，真实 HTTPS/PostgreSQL 5 项通过，见[证据](evidence/20260907-issuance-boundaries/manifest.json)。迟到/完全丢失响应的持久结果归属仍开放，B08 与 47 项状态不变。

最新补充：B08 已补[退出确认状态与显式恢复](device-revocation-status-contract.md)，仅向 UI 提供聚合状态；恢复保留原操作与次数、普通退避不变，读失败后的无变化重试也重新订阅。**437 项 ClientKit 实际执行（5 在线跳过）、195 项 App 实际执行（1 在线跳过）**通过。两项最终 UI 测试与截图验证点击、显式最大字号、RTL、登录/重试触达和无障碍审计，见[证据](evidence/20260907-revocation-status/manifest.json)。早期仅用启动参数的通过结果未证明最大字号，已留证并纠正。真机 VoiceOver 与完整系统后台边界仍开放，47 项状态不变。

最新补充：B08 已接通[独立撤销执行与本地退出](device-revocation-runner-contract.md)。前台自动发现持久任务并退避重试，后台取消保留旧 flight 所有权；退出已移除 Push 网络清理依赖，过期本地凭据也能退出并冷启动保持 signedOut。**434 项 ClientKit 实际执行（5 在线跳过）、194 项 App 实际执行（1 在线跳过）**通过；真实 HTTPS＋PostgreSQL 5 项验证提交后结果丢失、原操作重放和队列完成，见[证据](evidence/20260907-revocation-runner/manifest.json)。暂停反馈/恢复入口及完整生命周期交互仍开放，B08 不关闭，16 项已验证、31 项开放。

最新补充：B08 已完成[退出时的持久交接](device-revocation-handoff-contract.md)：原凭据先保存操作 ID，再提交独立撤销队列，最后删除登录凭据；重启不恢复标记退出的会话，新登录不能覆盖未交接的旧记录。最终 **427 项 ClientKit 实际执行（5 在线跳过）、193 项 App 实际执行（1 在线跳过）**通过，含真实签名模拟器 Keychain 的保护等级、重建 owner 和换号隔离。初次无签名测试宿主的 Keychain 权限失败和修正后的运行均见[证据](evidence/20260907-revocation-handoff/manifest.json)。自动联网执行及断网退出仍未接通；B08 保持实施中，16 项已验证、31 项开放。

最新补充：B08 已完成[原子签发和凭据保存](atomic-revocation-credential-issue-contract.md)，PostgreSQL 为 **28**。注册事务保存撤销摘要和加密完整重放；刷新保持原证明及期限，ClientKit 与 access/refresh 同项保存。**21 项 PostgreSQL、10 项服务端单元、418 项客户端实际执行（5 在线跳过）、192 项 App 实际执行（1 在线跳过）**通过。完整真实链路另通过 5 项 HTTPS、2 项 UI 和 1 项 headless；新增 capability 兑换定向 HTTPS 5 项通过，见[证据](evidence/20260907-atomic-revocation-issue/manifest.json)。App 独立持久交接及离线补偿尚未实现，B08 不关闭，16 项已验证、31 项开放。

最新补充（B08 已收到结果）：HTTP 签发返回前先保存仅含撤销能力的中间记录；冷启动识别已接管会话，其余转入持久撤销队列。取消/退出后的迟到结果、写入失败、既有暂停任务保留和真实模拟器 Keychain 恢复通过。最终 ClientKit 447 项实际执行（5 跳过）、App 196 项实际执行（1 跳过）、真实 HTTPS/PostgreSQL 5 项通过。见[结果交接合同](received-credential-recovery-contract.md)及[证据](evidence/20260907-issued-result-recovery/manifest.json)。完全丢失响应和系统级中断验收仍开放，B08 保持实施中；16 项已验证、31 项开放。

最新补充（B08 注册取消仲裁）：新增请求前可持有的独立取消证明、服务端取消记录，以及与签发共用事务的绑定；取消先到阻止签发，签发先到则原子撤销。锁后期限检查、证明四字段隔离、两侧回滚和旧迁移链共 21 项真实 PostgreSQL 测试通过，Core 95 项、原有 HTTP 单元 10 项通过。PostgreSQL 升至 29，见[合同](registration-cancellation-contract.md)。HTTP/App 尚未切换到新证明，完全丢失响应的端到端恢复仍开放，B08 及全部 47 项状态不变。

最新补充（B08 取消 HTTP）：账号服务已挂载受 trusted-edge 和地址限流保护的注册取消路由，ClientKit 增加不依赖登录凭据的传输。ClientKit 453 项实际执行（5 跳过）、HTTP 单元 13 项、真实 PostgreSQL 22 项通过；真实 HTTPS 5 项验证取消提交后丢弃客户端结果、原证明重放仍只有一条取消记录。见[HTTP 合同](registration-cancellation-http-contract.md)及[证据](evidence/20260907-registration-cancellation-http/manifest.json)。HTTP 签发强制证明与 App 请求前持久化/独立取消队列仍开放，16 项已验证、31 项开放不变。

## 架构判断

- **模块边界基本合理。** SwiftUI App 负责交互，ClientKit 负责认证/SQLite/outbox，Core 保存领域规则，Gateway/Account 提供传输入口，PostgreSQL 保存权威提交。无需因为发现问题而整体重写。
- **可靠性取决于事件组合。** ACK、outbox 和持久游标是基础，但 accepted 与 mutation 分流后，消费者必须处理重复、乱序和缺基线；B03/B06 表明这一合同仍不统一。
- **授权应随内容版本绑定。** 当前成员身份不能证明能看到历史消息或某次编辑。B04 已补这一边界，但跨库授权凭证、交付结果、保留与迁移必须形成完整协议。
- **异步任务必须有唯一所有者和恢复步骤。** generation 能隔离迟到 UI 结果，却不能撤销已经发生的远端 PUT/DELETE。Push、退出和文件擦除要以持久用户意图驱动。
- **优化路径增加一致性成本。** planner/preplanned/room_log/hybrid 应共享授权、幂等结果和投影不变量；单条路径通过不代表模式组合正确。
- **运行入口与组件能力要分别验收。** 当前 PostgreSQL schema 为 30，协议为 27；Gateway 已配置跨库 export 入队和投递运行时，pending/paused 映射为可重试错误；真实双库路由与运行时恢复已通过最终回归。operator 暂停恢复已增加独立入口、审计事务与 owner 栅栏并通过最终双库组合回归；媒体 HTTP 已按消息 owner 路由，个人投影走 user store、设备检查留控制库，provider 返回后再次授权；owner 迁移、终态保留和生产媒体部署仍需闭环。

最新补充：B27 第一阶段已加入 control token 目录、稳定创建 intent 与提交协调器，PostgreSQL 更新至 **22**。真实双库提交后丢响应、目录完成失败、并发重试、冲突绑定和 21→22 历史链接回填通过；最终 **17 项测试 / 2 套件**包含七条历史迁移链及审批、配额、恢复回归，见[目录证据](evidence/20260906-invite-directory/manifest.json)。Account 生产路由、epoch 和 control 身份拆分尚未接入，B27 保持实施中。

最新补充：B27 已完成 Account owner 路由与 control 身份拆分，PostgreSQL 为 **23**；三库验收覆盖两个无 profile 副本 owner 的完整邀请操作及 epoch/缓存边界。最终 **29 项测试 / 3 套件**、22→23 数据保留迁移和完整 readiness 负例通过，见[路由证据](evidence/20260906-routed-invitation/manifest.json)。完整 owner 迁移、历史目录导入、主动 intent 恢复以及 B23 全局申请配额仍开放，关闭总数不变。

最新补充：B27 的 prepared 创建意图已接入持久队列与 Account 后台恢复，PostgreSQL 为 **24**。原创建时间与本次判断时间分离，过期、额度、目录/任务原子发布、并发认领/前台重试、失权后原结果恢复及取消后的租约接管已验证。最终 **31 项测试 / 3 套件**和 23→24 回填/完整 readiness 负例通过，见[创建恢复证据](evidence/20260906-invite-creation-recovery/manifest.json)。B27 仍待完整历史迁移及旧目录导入，关闭总数不变。

最新补充：B27 的历史 owner 链接创建重试已修复：预检查返回原链接，control 沿用原 ID/时间建目录。未修复版本在普通群和大群均复现 ownerResultMismatch；修复后四种状态、每种十次并发重试、原 token、发布失败后后台恢复及矛盾绑定保留已验证。最终 **33 项测试 / 3 套件**通过，见[历史绑定证据](evidence/20260906-legacy-invite-retry/manifest.json)。PostgreSQL 24、protocol 25、SQLite 173/5 不变；旧目录分页导入和完整 owner 历史迁移仍开放，关闭总数不变。

最新补充：B27 的独立 operator 旧目录分页导入已接通，PostgreSQL 为 **25**。103 条链接跨页、十次并发幂等、prepared/claimed 任务完成、三类绑定冲突整页回滚、不可变审计、owner 读取期间 control 路由改变，以及实际 HTTP/同库空页已验证。最终 **39 项测试 / 5 套件**与真实 24→25 数据保留迁移及完整 readiness 负例通过，见[导入证据](evidence/20260906-invite-directory-import/manifest.json)。完整 owner 历史迁移仍开放；protocol 25、SQLite 173/5 和关闭总数不变。

最新补充：B27 迁移前置检查发现普通成员变更丢弃 owner epoch、单库跳过路由的问题；修复前两种群模式均产生了旧 owner 上的实际移除/回执/事件。现已强制传递 route/epoch，在回执重放前取得事务栅栏，并接通单库 Gateway。旧缓存、新 epoch 重放、十次并发、等待房间锁期间 epoch 变化及当前身份保护已验证；最终 **78 项测试 / 7 套件**通过，见[成员栅栏证据](evidence/20260906-membership-owner-fence/manifest.json)。其他房间写入路径的统一栅栏及完整迁移执行器仍开放；schema 25、protocol 25、SQLite 173/5 和关闭总数不变。

最新补充：消息编辑、撤回与 reaction 同样存在丢弃 owner epoch、旧回执先于 owner 校验的问题；负向测试在两种群模式共六个场景确认旧 owner 实际提交。现已强制传递所选 route，并在消息事务内先锁房间核对 owner，再重放或写入；单库 Gateway 也使用验证入口。最终 **87 项测试 / 7 套件**通过，见[消息变更栅栏证据](evidence/20260906-message-mutation-owner/manifest.json)。通用发送、其他房间命令、后台任务及完整迁移仍开放；47 项关闭总数与 schema 版本不变。

最新补充：公告、置顶、角色权限和成员角色同样存在 owner 栅栏缺口；修复前八个真实双库场景均发生旧 owner 提交，32 个断言失败。现已在四类事务回执重放及 self-role 提前返回之前校验所选 owner，单库与同物理库多 shard 也保留 epoch。最终 **93 项测试 / 7 套件**通过，见[群管理栅栏证据](evidence/20260906-group-capability-owner/manifest.json)。moderation、已读回执、通用发送、读取/后台任务及完整迁移仍开放；schema 与 47 项状态总数不变。

最新补充：普通 moderation 的消息屏蔽/禁言/移除，以及可信安全服务的屏蔽/冻结/解冻，均已补齐所选 owner 的事务栅栏。修复前十二个真实双库场景均在旧 owner 提交业务和审计，60 个断言失败；修复后旧回执也必须先通过 owner 检查。Gateway 单库和内容审核服务已接通，审核遇到 owner 错误保留重试/暂停，不误记完成；私有 selector 已移除同库绕过入口。最终 **113 项测试 / 8 套件**通过，见[moderation 栅栏证据](evidence/20260906-moderation-owner/manifest.json)。已读回执、通用发送、其他后台任务和完整迁移仍开放，schema 和 47 项状态总数不变。

最新补充：群已读回执单条/批量和读者候选分页已保留所选 owner。批量按固定顺序取房间共享锁，逐行验证 epoch，错误行不参与游标推进或旧回执重放，合法同行正常提交；路由单条复用同一批量锁路径。混合 owner、20 次单条/批量竞争、control 隐私过滤、两房间并发及既有三库回归最终 **126 项测试 / 11 套件**通过，见[群回执栅栏证据](evidence/20260906-read-receipt-owner/manifest.json)。私聊后续 control 投影事务的跨库交接、通用发送、其他后台任务及完整迁移仍开放；schema 与 47 项状态总数不变。

最新补充：普通消息发送的单条、私聊冷批量/暖缓存快速追加和大群集合批量已在事务内验证 owner；同物理库仍保留逐房间 route/epoch。Gateway 共享房间依赖也补齐独立命名的 direct shard，复用原缓存与额度 actor。最终 **162 项测试 / 13 套件**通过，包含旧缓存、错误/未知 owner、等锁时 epoch 改变、整批回滚、credit 归还、两房间并发及既有三库恢复链，见[发送 owner 证据](evidence/20260906-send-owner/manifest.json)。发送 control 身份/策略隔离、后台转发导入、来源/其他读取、投影交接和完整迁移仍开放；47 项状态统计不变。

最新补充：后台转发目标的新 inbox 入队、accepted 恢复与最终 completed 发布已补 owner 事务栅栏。旧 owner 不再新增任务或误发布终态，源端继续保留未完成 export 的占用；同 owner 恢复保持原消息身份，已完成不可变回执仍可重读。首轮 7 项集成测试、最终 **176 项测试 / 14 套件**通过，见[后台转发 owner 证据](evidence/20260906-forward-import-owner/manifest.json)。前台同库转发的 route 快捷分支、投影/活跃任务迁移承接及完整迁移仍开放，B04/B27 与 47 项状态统计不变。

最新补充：前台同库转发现保留来源与目标的 shard/epoch，并在来源读取、幂等记录/结果修复、消息接受和最终补记事务中验证。仍保留同库一次来源批量查询及有界目标并发。旧实现两端 epoch 反例共 6 issues；修复后 **184 项测试 / 14 套件**通过，含等锁更新、接受前后 owner 变化、稳定消息身份、并发重试、反向互转及既有三库回归，见[前台转发 owner 证据](evidence/20260906-local-forward-owner/manifest.json)。完整历史/活跃工作迁移、用户投影交接、其他读取与 worker、全局内容封禁和终态清理仍开放，B04/B27 及 47 项状态统计不变。

最新补充：B05 已改为 Argon2id v19 完整 UTF-8 输入、固定参数 PHC 编码及独立双线程预算。NUL 拒绝，长密码后缀参与验证；旧 bcrypt 保留原样且不再凭前缀等价验证发出断言。成功认证先事务复核原完整 hash，再原子提交审计/失败窗口清理。最终 **39 项测试 / 7 套件**通过，含官方向量、Unicode/空白、异常参数、真实 32 请求突发（2 执行 / 30 busy）、取消排空、PostgreSQL HTTP、并发凭据替换及审计故障回滚，见[密码哈希证据](evidence/20260906-password-hash/manifest.json)。B05 在当前绿地输入/存储/认证合同内已验证；生产旧账号可信恢复、Linux binary 和完整容量验收仍归发布缺口，不能据此宣称生产就绪。

最新补充：B03 的普通编辑、作者撤回和 reaction 已按每条消息不可变的接受记录选择分发，direct room-log 不再误建逐用户变更任务；原 accepted 与变更从同一房间日志恢复。缺少接受记录的新操作在修改前失败，已完成操作保持幂等。最终 **186 项测试 / 14 套件**通过，含 21 个发送/存储/重放组合和 6 个缺失记录回滚场景，见[分发归属证据](evidence/20260906-message-delivery-authority/manifest.json)。B03 更新为实施中；历史受众交集、精确额度结算、typed replacement、旧缺基线恢复、内容撤销和完整快照仍开放。

最新补充：B03 新 personal 变更的 fanout 已按 accepted 与变更时刻的独立成员区间取交集，保留离群重入成员、排除纯新成员。单条/批量 planner 共用分页，持久结束标记后原子结算真实人数及预留差额；同窗口退还多余消耗，换代后保留新窗口计数。零受众关闭计划与 outbox，混合批次确认仍验证未完成行的租约。最终 **221 项测试 / 16 套件**通过，含故障注入、八路并发重试、真实完成释放与 10 万成员分页，见[受众结算证据](evidence/20260906-message-audience/manifest.json)。reaction 操作者历史授权、其他读取入口、typed replacement、旧积压恢复和内容撤销仍开放，B03/D07 及 47 项状态统计不变。

最新补充：B03 的 reaction 新操作已验证 accepted 时刻与当前成员身份；普通 edit/withdraw/reaction 的 room pull 在分页前按原消息和变更时刻独立过滤。缺少接受记录直接失败，不跳过未知内容。protocol **26** 将 continuation 明确为已扫描序号，ClientKit 接受不可见尾部及空页推进，物化失败仍原子回滚，预览不写持久游标。最终 **262 项服务端 / 21 套件、367 项 ClientKit / 58 套件、182 项 App / 17 套件、84 项 Core / 26 套件**通过，见[历史读取证据](evidence/20260906-message-read-authority/manifest.json)。typed replacement、其他内容入口、access epoch 恢复、独立撤销和完整快照仍开放，47 项状态统计不变。

最新补充：protocol **27** 的新编辑携带原接受身份和显式完整内容，ClientKit 与服务端个人投影可处理成员重入后的合法 rev1→rev3，以及编辑先到、accepted 后到，旧增量仍不得跳版本。共享批量、共享单条和内联投影均保留新状态；错误身份、同版本冲突、非法完整值和终态后的替换失败并回滚。最终 **288 项服务端 / 25 套件、372 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含真实 owner/fanout 载荷交给 ClientKit 的验证，见[完整编辑证据](evidence/20260906-message-edit-replacement/manifest.json)。旧积压、其他读取入口、access epoch、独立撤销与完整 room 恢复仍开放，B03/B06/D07 和 47 项统计不变。

最新补充：普通撤回已支持合法 revision 缺口和完整状态先到，晚到 accepted/旧编辑不会恢复正文；ClientKit 快照激活后的同终态源事件可从 personal/room/preview 重放，清除遗留回复引用且不重复创建搜索任务。错误房间、非法版本、矛盾活动状态及审核删文缺基线保持失败与 checkpoint 回滚。最终 **289 项服务端 / 25 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含 21 个服务端终态场景及实际快照导入、重开验证，见[终态证据](evidence/20260906-message-terminal-projection/manifest.json)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；缺基线旧积压、独立内容撤销和未重放历史行清理仍开放，B03/B06/B04 与 47 项状态不变。

最新补充：回复和置顶已在 owner 写入事务内校验原 accepted 与当前内容版本受众，隐藏置顶 no-op 也不能绕过授权；转发与按消息定位的媒体读取统一使用不可变接受记录，正文存储兼容列不再决定历史可见性。修复前 32 个场景记录 32 处失败，最终 **292 项服务端扩展回归 / 25 套件**通过，包含 44 个引用场景、15 个媒体场景及历史完整/缺失记录和索引计划，见[引用授权证据](evidence/20260906-message-reference-visibility/manifest.json)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；本批未修改或重新测试客户端，B03/B04 和 47 项状态不变。

最新补充：旧媒体入口已修复合法 UUID 拼写误拒绝，并要求消息原 accepted/当前版本受众及有效投影；头像保持独立可见性。申请、领取与供应商返回后的完成消费均检查账号/设备/内容，旧 token、过期或被接管租约不能返回地址；领取、供应商和数据库完成阶段的取消/过期均覆盖。最终 **307 项服务端扩展回归 / 28 套件**通过，含 30 个真实数据库场景及 6 个返回边界场景，见[旧媒体证据](evidence/20260906-legacy-media-authorization/manifest.json)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；本批未改客户端，多 owner 完整迁移及统一 access epoch 仍开放，B03/B04 和 47 项统计不变。

最新补充：B01 的资料版本已限定为正 Int64，备注/昵称 HTTP 拒绝显式非法版本，SQL 使用有符号绑定，资料版本耗尽时失败并回滚；个人投影可提交最大序号，不再计算溢出的下一序号。最终 **316 项服务端扩展回归 / 30 套件、87 项 Core / 27 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含 12 个备注/昵称、8 个公开资料、3 个投影极值及 6 个 HTTP 拒绝场景，见[整数边界证据](evidence/20260906-profile-projection-boundaries/manifest.json)。负例包含两个独立进程 signal 5 和初轮 HTTP 失败，均保留原始日志；protocol 27、PostgreSQL 25、SQLite 173/5 不变。其他恢复 DTO、计数及时间转换仍待审计，B01 和 47 项统计不变。

最新补充：B01 七处浮点时间转整数已使用精确可表示性检查，保留各自向下/向零取整与错误类别。Core 媒体和真实跨 owner projector 修复前均以 signal 5 退出，修复后异常时间拒绝且不写分发状态，合法微秒与重试幂等保持精确。最终 **338 项服务端扩展回归 / 33 套件、89 项 Core / 28 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，见[时间戳证据](evidence/20260906-timestamp-integer-boundaries/manifest.json)。快照计数经现有 schema 上限约束排除溢出疑点；其他转换/计数与恢复 DTO 仍开放，47 项状态不变。同步更正 B29 当前协议号为 27。

最新补充：B02 已补 24 个真实 PostgreSQL 确定提交顺序场景，覆盖冻结、禁言、moderation/membership 两种移除、撤销角色发言权及降级。通过 pg_locks/pg_blocking_pids 观察真实锁依赖；权限先提交则编辑拒绝，编辑先提交则只生效一次，限制后原操作仅重放回执。最终 **91 项相关服务端回归 / 6 套件**通过，见[提交顺序证据](evidence/20260906-edit-policy-commit-ordering/manifest.json)。本批仅新增验证与文档，B02 标为已验证；全表变为 **14 项已验证、33 项仍开放**，不代表其他授权/恢复/生产验收问题已关闭。

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
| D03 | P2 | 后台 Push 跑完整 runtime，缺总时间预算 | 实施中 | 已接入[专用后台 runner](bounded-incremental-sync-contract.md)：默认 25 秒工作截止、个人/room-log 合计 4 页、每页 100 条、reset 延后；独立连接在超时/前台恢复/退出时取消排空，Push 不再启动完整 runtime 或等待完整退出。新增同步 gate、可取消共享认证等待及真实 SQLite 新增计数，取消后迟到写入已反向复现并修复。新增[真实网络期限验证](evidence/20260906-background-network-deadlines/manifest.json)，覆盖 TLS/Hello/认证/pull/ACK 挂起、关闭及凭据保留，四个协议阶段重连成功，ACK 重放不算新增；最终 402 项客户端实际执行通过，另 4 项在线测试跳过。188 项 App 单元为上一批结果，本批未重跑。仍需实际 Push/真机截止与额外 5 秒收尾、锁屏及前后台交错验收；D02 无 scene 冷启动独立开放。 |
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
| B03/B06 缺基线/重复变更 | [GRDBV2LocalSyncStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 与 V2LocalMessageEffect 共用消息效果记录 | 重复消息效果与旧编辑已有处理；新完整编辑可建立合法基线并跨版本，旧文本 delta 的缺基线/缺版本仍拒绝，旧积压需 B03 持久恢复；reaction 已有顺序与负状态，其他对象未统一 |
| B04 跨库主路径 | [V2RoutedForwardMessagesService.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2RoutedForwardMessagesService.swift) 已配置跨 owner service；[Gateway 组装](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2ServerApp/main.swift) 使用该 router 并启动、取消和排空投递运行时 | 真实双库 router/runtime 已验证；主程序编译通过，尚未启动真实 Gateway/App 做端到端验收 |
| B04 媒体导入 | [V2ForwardMediaImportWorker.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2ForwardMediaImportWorker.swift)、[PostgresV2ForwardMediaImportStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/PostgresV2ForwardMediaImportStore.swift)、[本地复制器](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2LocalFilesystemForwardMediaCopier.swift) | 有复制、扫描、lease、重试及 fencing 实现；后续批已重新验证 13 种媒体场景，见持久日志 |
| B04 媒体下载 | [V2RoutedMediaDownloadService.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2RoutedMediaDownloadService.swift) 与 Account room/user registry | schema 17；消息 owner、用户投影和控制库设备分别授权；15 个下载场景与实际转发附件读回通过，仍需生产媒体和 owner 清理验收 |
| B04 保留释放 | [PostgresV2ForwardExportStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/PostgresV2ForwardExportStore.swift)、[PostgresV2MediaRetentionStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/PostgresV2MediaRetentionStore.swift) | export 配额与源媒体 pin 必须配套终态回执/释放，不能只增加不可变记录 |
| B05 密码边界 | [V2PasswordHashWorker.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2PasswordHashWorker.swift) 与 [V2PasswordAccountStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/V2PasswordAccountStore.swift) | 完整输入 Argon2id、有界 worker、旧记录限制及认证后事务复核已验证；修复前 HTTP 反例 9 issues 与最终 39 项回归分别留证 |
| B16 Push 竞态 | [V2PushWakeSettings.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMApp/IMApp/V2/V2PushWakeSettings.swift)、[V2PushIntentReconciler.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2ClientKit/Sources/IMV2ClientKit/V2PushIntentReconciler.swift) 及服务端版本条件写 | 旧 register/remove 链路已替换；持久最终意图、单飞和版本拒绝已分层验证，真实网络与 App 账号生命周期组合仍待验收 |
| B18 历史定位 | [V2ConversationDetailStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMApp/IMApp/V2/V2ConversationDetailStore.swift) 的 loadTimeline 与 SQLite conversationTimelineWindow | 数量增长循环已删除；直接按消息和活动共同排序定位，800 条保留上限不再阻断导航；真实 SwiftUI 滚动已验证 |
| B23 配额 | [PostgresV2GroupInvitationStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 submit | 单库已改为 applicant 事务锁，等待后重新计数；各 owner 仍须共同使用 control 的唯一配额预留 |
| B26 审批恢复 | [PostgresV2GroupInvitationStore.swift](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 approve | 新请求单事务提交；旧 approving 通过独立 operator 按确切操作和完整历史证据恢复，审计及旧操作阻断同事务 |
| B27 owner 路由 | [Account 主入口](/Users/yyl/Desktop/Code/IMMonorepo/IMV2Server/Sources/IMV2AccountServerApp/main.swift) 的 groupInvitations 组装 | 已组装 V2RoutedGroupInvitationStore；持久 route/epoch、control 身份及 token 目录已接入 |

## 修复顺序与验收要求

1. **优先消除核心阻断和授权缺口：B03/B06、B05、B01 剩余边界。** 同一个事实重复到达不得回滚整个同步；缺基线恢复不得泄漏入群前历史；密码规则需覆盖兼容迁移。
2. **闭环用户状态：B08/B09/B15/B16、D01–D04。** 验收认证失效、锁屏、断网、退出、杀进程与 A→B→A 的交错，观察磁盘与远端状态，不能只断言 UI。
3. **闭环持久多阶段事务：B04/B11/B23/B26/B27、D05/D06。** 验收提交后 ACK 丢失、重复投递、lease 接管、owner epoch 变化、额度与保留释放。跨库操作避免依赖跨数据库长事务。
4. **收敛模式合同并完成发布证据：D07/D08、E01–E10。** 用同一最终版本验证各投递模式和实际环境，记录测试范围与未覆盖项，避免用历史容量数字外推当前部署。

本次实际完成 `git diff --check` 与 `python3 scripts/check_v2_protocol_documentation.py`，均通过。未重跑 Swift/App/PostgreSQL 全套测试，未查询远端 CI/APNs/生产系统，未把历史日志记作本轮成功，也未修改业务源码或部署。

详细原始触发条件、影响、历史实验和建议见 [原始审查](2026-09-05-system-design-implementation-audit.md)；逐批实现与证据见 [修复进度](2026-09-05-system-remediation-progress.md)；执行依赖见 [修复方案](2026-09-05-system-remediation-plan.md)。原始审查的代码行号对应审查基准，不保证与已修改文件一致。

后续修复批补充：schema 14 源端终态回执、配额与 pin 释放已通过 89 项相邻回归，并追加真实源文件删除/目标副本保留验证。完整 B04 仍未关闭；本报告主体的“本次复核”测试边界对应生成时点，后续证据以修复进度为准。

后续 schema 15 批补充：持久投递 worker、精确目标适配器、原子入队、租约/退避/超时取消与迁移回填已通过 90 项相邻回归（16 种投递场景、29 种门禁场景），见 [持久证据](evidence/20260905-forward-delivery/manifest.json)。运行入口仍未接通，B04 保持实施中。

最新补充：B09 业务 HTTP 的 401 已进入共享刷新判定，刷新终止通过认证快照驱动 App；业务 403、网络失败及取消保留凭据，前驱 token 和旧账号回包受代次保护。共享刷新只收尾一次，32 并发调用者误报会话失效的问题已修复。最终 **384 项 ClientKit / 59 套件、183 项 App / 17 套件**通过，见[HTTP 认证合同](session-http-authorization.md)与[原始证据](evidence/20260906-session-http-authorization/manifest.json)。本批使用受控 HTTP，真实账号服务和 TLS 仍开放；B09 状态不变，维持 14 项已验证、33 项开放。

最新补充：B09 已加入[本地真实账号 HTTPS 验收](live-account-https-authorization.md)，四项测试通过，实际数据库确认被撤销设备无有效访问/刷新凭据且撤销事件恰好一次。未更改生产策略或信任设置；App 完整界面、Keychain 和实时 Gateway 重连尚未纳入该链路，B09 保持已实现待验证。原始日志、状态计数与清理记录见[本批证据](evidence/20260906-live-account-https/manifest.json)。

最新补充：B09 的真实 App＋Gateway 验收复现了设备撤销后只看到 EOF、继续重连的实际缺陷。服务端现先写出可关联的认证拒绝再关闭连接；基础设施异常保留原失败路径。两项 App UI、四项真实 HTTPS、64 项服务端及 384 项 ClientKit 离线测试通过，数据库和 Gateway 指标确认撤销与清理，见[完整链路证据](evidence/20260906-app-gateway-authentication/manifest.json)。B09 标为已验证；当前共 **15 项已验证、32 项仍开放**，B08 的持久退出/换号与外部验收不随之关闭。

最新补充：B01 已修复客户端合法最大毫秒值保存到 SQLite 后、读取禁言投影时反向转换 Int64 的实际崩溃；新禁言、会话命令和心跳加入精确转换检查。最终 **91 项 Core、388 项实际执行的 ClientKit 离线测试、183 项 App 和 49 项服务端**通过，见[客户端时间边界合同](client-timestamp-integer-boundaries.md)及[证据](evidence/20260906-client-timestamp-boundaries/manifest.json)。服务端快照计数已由 schema 约束排除当前溢出风险，未误列为新缺陷；B01 继续实施中，维持 15 项已验证、32 项开放。

最新补充：B01 的账号限流窗口、密码锁定时长和失败阈值已与驱动日期编码及 SQL integer 范围对齐；消费、清理和密码失败写入均在绑定前检查实际日期，失败计数达到 Int32 上限后继续维持拒绝状态和审计。最终 **29 项服务端 / 5 套件**通过，含三个真实 PostgreSQL 场景；负向配置、计数上限四路并发和非法日期无写入证据见[限流边界合同](account-rate-limit-integer-boundaries.md)及[证据](evidence/20260906-account-rate-limit-boundaries/manifest.json)。B01 保持实施中，仍为 15 项已验证、32 项开放。

最新补充（D01 关闭）：补强真实 Network.framework 旧 reader 迟到失败测试，增加接收进入及结束断言；反向移除 generation close guard 后，新连接按预期报 connectionClosed，随后已恢复原源码并通过完整客户端回归。生产代次隔离实现本批未变。见[验收说明](network-generation-fencing.md)与[证据](evidence/20260906-network-generation-fencing/manifest.json)。当前 **16 项已验证、31 项仍开放**。

最新补充（B07）：跨批次公平调度已修复，预算 1/2/4 的原实现失败证据与修复回归已归档。实际 SQLite、双 outbox lane、protobuf 与 NWConnection 组合覆盖安静到期、空闲入队、停止后无活动及数据库重开恢复；客户端 390 项实际执行、App 183 项单元回归通过。见[合同](durable-retry-network-contract.md)及[证据](evidence/20260906-durable-retry-network/manifest.json)。B07 保留真实 App 后台恢复验收，计数仍为 **16 项已验证、31 项仍开放**。

最新补充（B08）：退出标记改用带版本的原子文件、显式同步与错误传播，兼容旧 UserDefaults 并按 Keychain service 隔离；本地完成记录延后到任务停止/数据库关闭之后，重试补齐单飞。189 项 App 单元、4 项真实 HTTPS、2 项真实 App UI（HTTP/TLS Gateway 撤销及冷启动）通过；独立临时环境已清理。见[合同](durable-sign-out-marker-contract.md)和[证据](evidence/20260906-durable-sign-out-marker/manifest.json)。真机文件保护、每步强杀、完整退出 checkpoint 与离线远端补偿仍开放，计数仍为 **16 项已验证、31 项仍开放**。

最新补充（D03）：App Push 已切换至默认 25 秒工作截止、个人/room-log 合计 4 页的专用后台 runner。补齐同步 gate、可取消共享认证等待、迟到 pull 写入拦截和 SQLite 实际新增计数；后台认证终止不再 await 完整退出。401 项客户端实际执行、188 项 App 单元、4 项真实 HTTPS、2 项真实 App 认证终止/冷启动 UI 回归通过。后两项未注入 Push；实际 Push/真机收尾、锁屏与网络悬挂仍待验证，D02 无 scene 恢复独立开放。见[合同](bounded-incremental-sync-contract.md)和[证据](evidence/20260906-bounded-incremental-sync/manifest.json)。当前 **16 项已验证、31 项仍开放**；实施中 14 项、未开始 14 项。

最新补充（D03 网络期限）：真实回环 NWConnection 的 TLS、Hello、认证、pull、ACK 五个挂起场景通过；1 秒工作预算下断言小于 5 秒返回并关闭对端连接，认证材料保留。四个非 TLS 场景恢复响应后重连同步成功，ACK 超时已提交的数据不重复算作新增。完整客户端报告 406 项 / 63 套件，其中 402 项实际执行、4 项在线跳过；本批未修改生产代码、未重跑 App 或注入真实 Push。D03 仍为实施中，16 项已验证、31 项开放不变。见[网络期限证据](evidence/20260906-background-network-deadlines/manifest.json)。

最新补充（D02/D03）：App delegate 初始化即创建共享 store 并注册 Push handler，页面复用同一实例；Push 可等待共享恢复，恢复与增量同步共用绝对截止，后台不启动完整前台任务。单个取消/期限、恢复所有者迟到回调、剩余预算、短同步等待方及无 View delegate 回调已验证。最终 **404 项客户端实际执行、192 项 App 单元、4 项真实 HTTPS、2 项真实 App 认证终止/冷启动 UI**通过；另 4 项在线客户端测试在离线全量回归中跳过。UI 回归未注入 Push，真实带凭据无 scene、锁屏和系统期限仍待验收。D02 从未开始改为实施中，当前 **16 项已验证、31 项开放；实施中 15 项、未开始 13 项**。见[共享启动合同](shared-app-restoration-contract.md)和[证据](evidence/20260906-shared-app-restoration/manifest.json)。

最新补充（D02/D03 真实入口）：新增独立 delegate/store 的真实凭据入口测试，经 HTTPS 签发、Keychain、TLS Gateway 和 SQLite 完成首次恢复、重放、远端撤销及退出后的 Push。最终 1 项入口、4 项真实 HTTPS、2 项真实 UI 和 192 项离线 App 测试通过；离线报告另有 1 项在线测试跳过。本批只改测试/验证脚本与文档，修正了 UI 弹层切换时的立即取样断言及撤销测试的调用方式。系统无 scene/APNs/锁屏验收保持开放，47 项状态不变。见[合同](headless-push-entry-contract.md)与[证据](evidence/20260906-headless-push-entry/manifest.json)。

最新补充（B08 服务端）：新增仅撤销认证当前设备的 HTTP 入口，复用账号锁和凭据/Push/事件原子撤销。5 项真实 HTTPS 测试与 19 项服务端定向回归通过；临时数据库注入 journal 失败验证事务回滚，十次并发投递只增加一条操作记录。App 接线及新登录 device ID 轮换尚未完成，B08 保持实施中，16 项已验证、31 项仍开放。见[合同](current-device-logout-contract.md)及[证据](evidence/20260906-current-device-logout/manifest.json)。

最新补充（2026-09-07，B08）：App 新登录改用按账号隔离的 Keychain 注册记录，成功后退休 device/operation 身份；旧注册完成不能清除新记录，异步准备前后的认证 epoch 防止退出后迟到开始签发。最终客户端 416 项报告 / 411 项实际执行、App 193 项报告 / 192 项实际执行通过。两项真实 App UI 覆盖 HTTP/Gateway 撤销、冷启动后同账号再次登录，并用服务端设备列表确认新 ID；5 项真实 HTTPS 及 1 项独立 delegate/store 后台入口回归通过。数据库 15|5|0|0|5，清理后 Gateway 为 0，专用资源已移除。见[合同](registration-lifecycle-contract.md)和[证据](evidence/20260907-registration-lifecycle/manifest.json)。B08 保持实施中，当前 16 项已验证、31 项开放。

最新补充（2026-09-07，B08 期限）：PostgreSQL 升至 26，设备会话默认绝对 30 天，access/refresh 与认证租约不能超过截止，操作重放也检查当前设备状态；Push、快照可用性和媒体授权按期限拒绝，上传/下载提供方返回后的兑换补齐当前授权。19 项真实 PostgreSQL、54 项服务端单元、schema 25 到 26 迁移与负向就绪检查通过；5 项真实 HTTPS、2 项撤销后重新登录 App UI、1 项后台 delegate/store 入口回归通过，临时资源已清理。见[合同](device-session-absolute-expiry-contract.md)和[证据](evidence/20260907-session-absolute-expiry/manifest.json)。离线补偿能力和 App 完整退出 checkpoint 尚未完成，仍为 16 项已验证、31 项开放。


最新补充（2026-09-07，B08 签发证明绑定）：[请求前持久化与强制 HTTP 绑定](proof-bound-issuance-contract.md)已实现，注册 ledger 升为 format 2；缺少或不匹配确认会先交接收到的撤销能力再拒绝登录，旧记录保留档案，过期尝试保留证明并换用新身份。客户端 **462 项报告 / 457 项实际执行**、接口 **14 项**、真实 PostgreSQL **22 项**、App **197 项报告 / 196 项实际执行**通过；最终真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过。数据库设备/撤销/残留访问/残留刷新/事件为 **16|7|0|0|7**，取消记录总数/绑定/取消为 **17|16|2**；独立补偿允许多个操作指向同一已撤销设备，事件仍不重复。脚本调用同步补齐证明，Compose 栈脚本只做语法及共用工具离线检查。初始解码错误、旧 UI 夹具和旧统计假设的失败均留档；最终专用资源已移除。见[证据](evidence/20260907-proof-bound-issuance/manifest.json)。自动取消执行器、冷启动请求前证明归属、旧会话清理和真机系统中断仍开放；47 项仍为 **16 已验证、31 开放**，B08 不关闭。


最新补充（2026-09-07，B08 遗弃注册自动取消）：[执行器与冷启动归属](registration-cancellation-runner-contract.md)已接入 App。format 3 原子迁移旧证明并保存尝试次数、退避和暂停，冷启动只把未被当前持久凭据接管的 pending 入队；前台观察自动执行，后台取消并等待实际请求结束，清理反馈和手动重试覆盖两类队列。客户端 **472 项报告 / 467 项实际执行**、签名 App **199 项报告 / 198 项实际执行**通过；真实 Keychain 验证归属及暂停反馈。真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过，验证签发和取消响应相继丢失后仍使用原证明重试。数据库 **16|7|0|0|7**，取消记录 **17|16|2**，取消 HTTP 204 四次但记录不重复；专用资源已清理。见[证据](evidence/20260907-registration-cancellation-runner/manifest.json)。旧会话/legacy 档案清理、真实强杀/锁屏/系统后台和记录 GC 仍开放；B08 保持实施中，全部 47 项仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 实际进程中断）：[真实 App 两次终止后恢复](registration-process-interruption-contract.md)已通过。HTTPS 代理在服务端签发/取消分别提交后保留响应，受控终止专用模拟器里的 App；第二次重启从真实 Keychain 使用原证明重放，并完成新设备登录。原设备单独核对 **2|1|1|1|0|0**（账号设备数/原设备撤销/证明取消记录/事件/有效 access/有效 refresh）；没有重复事件。同期修复命令行证明将 DeviceID 误编码为字符串的问题，真实凭据准备脚本的签发、鉴权和取消通过。最终 **5 项原生 HTTPS、3 项 App UI、1 项独立后台入口**通过，全库 **19|9|0|0|9**、取消记录 **20|19|4**。见[证据](evidence/20260907-registration-process-interruption/manifest.json)。这是 simctl 受控进程终止，不等同于 SIGKILL/OS jetsam/真机锁屏；legacy 清理及其他检查点仍开放。47 项仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 旧档案服务端仲裁）：[账号范围的持久取消](legacy-registration-arbitration-contract.md)已实现，PostgreSQL 更新为 **30**。取消与签发共用账号/注册锁，原子撤销已签发会话并拒绝同账号迟到签发；其他账号不受旧 ID 阻断。真实 PostgreSQL **26 项 / 1 套件（32.416 秒）**通过，覆盖新增四项隔离、回滚、并发和配额测试及七条历史迁移链；29→30 保留凭据、约束正反向门禁通过。HTTP 单元 **14 项 / 3 套件（0.011 秒）**、原生 HTTPS **5 项 / 2 套件（2.729 秒）**通过，数据库 **8|4|0|0|4**，注册取消记录 **9|8|2**。首次新增测试未清理 schema，导致后续测试初始化失败；修正成功/失败清理后全组通过，失败日志保留，早先回滚通过的过早进度说明已纠正。三个专用资源根目录已独立确认移除。见[证据](evidence/20260907-legacy-registration-arbitration/manifest.json)。尚未提供 legacy HTTP 入口或 ClientKit/App 清理接线，启用前必须停止旧签发进程；本批未新跑 App/UI/Gateway/headless/真机。47 项仍 **16 已验证、31 开放**，B08 不关闭。


最新补充（2026-09-07，B08 旧档案 HTTP）：[账号证明与受保护清理入口](legacy-registration-http-contract.md)已接入生产 Account 组装及地址限流。严格四字段、UUID、新旧设备不同及证明边界先于域调用；真实 HMAC 验证与 18 项接口测试 / 4 套件（0.012 秒）通过。真实 HTTPS 基线 5 项 / 2 套件（2.691 秒）通过，新增扩展使用真实密码因子验证 503 整体回滚、204 幂等、同一证明新设备签发、迟到签发 403、另一账号隔离 404 及容量 507/原操作 204；仅记录目标计数，不保存密码或令牌。扩展在基线统计后执行，另增 3 个设备、1 条撤销事件和 256 条账号范围取消记录（254 条为配额种子）。相邻 PostgreSQL 与七条历史迁移链共 26 项 / 1 套件（30.563 秒）通过，三个专用资源根目录已独立核实移除。首轮扩展把既有签发 403 错写为 401，修正预期后完整通过，失败日志保留。见[证据](evidence/20260907-legacy-registration-http/manifest.json)。ClientKit/App 的旧档案 CAS 与登录接线尚未完成，本批未新跑 App/UI/Gateway/headless/真机；schema 30、protocol 27、SQLite 173/5 不变，仍 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 旧档案客户端恢复）：[ClientKit/App 登录接线](legacy-registration-client-recovery-contract.md)已实现，同一次账号因子先清理、完整本地确认后再签发。失败保留，完整注册尝试和旧档案 CAS 防止迟到确认；一个恢复专用位置解决 256 条旧档案满额时无法创建清理尝试的问题。最终 ClientKit 480 项报告 / 474 项实际 / 6 项在线跳过（76 套件，6.167 秒），签名 App 200 项报告 / 199 项实际 / 1 项在线跳过（21 套件，5.143 秒）通过。真实 HTTPS 5 项 / 2 套件（2.714 秒）、新增旧档案恢复 1 项 / 1 套件（1.556 秒）、App UI 2 项（64.579 秒）、后台入口 1 项（1.323 秒）通过。数据库 18|8|0|0|8，注册取消记录 19|18|2，无旧有效凭据残留或重复事件。三套件并行触发两个密码 worker 的 503，首次分组仍带入第三套件；最终拆为独立文件顺序运行，两轮失败留档。三个临时根目录和一个模拟器已独立核实移除。见[证据](evidence/20260907-legacy-registration-client/manifest.json)。真实 HTTPS 的 owner 重建使用内存持久适配器，真实 Keychain 单独验收；不替代实际 App legacy 跨进程、旧二进制升级或真机锁屏/系统后台验收。B08 仍实施中，全部47项保持 **16 已验证、31 开放**。


最新补充（2026-09-07，B08 实际 App 旧档案恢复）：[跨进程清理检查点](legacy-registration-app-process-contract.md)已通过。真实签发的旧设备/原操作以 format 1 写入隔离 Keychain，清理提交后代理不转发响应并受控终止 App；不带种子参数的重启从真实档案重放，新证明绑定新设备，登录后再次冷恢复仍保持新会话。目标数据库核对 **2|1|1|1|0|0|0|1**，旧设备只有一条取消记录和撤销事件，无有效 access/refresh；首次准备设备未签发且已持久取消。真实 HTTPS **5 项（2.717 秒）**、App UI **3 项（104.240 秒）**及后台入口 **1 项（1.289 秒）**通过，全库 **18|8|0|0|8**、注册取消记录 **20|18|3**。签名 App 全量 **201 项报告 / 200 项实际 / 1 项跳过**通过（22 套件，5.063 秒），新增测试验证夹具要求隔离域、拒绝覆盖、清理不影响未加测试域的 Keychain。专用数据库根与模拟器已独立核实移除。见[证据](evidence/20260907-legacy-app-process/manifest.json)。这验证受控 simctl 终止和明确构造的旧格式数据，不是旧二进制升级、SIGKILL/OS jetsam、掉电或真机锁屏验收；其他检查点、永久冲突与 GC 仍开放。全部47项保持 **16 已验证、31 开放**。


最新补充（2026-09-07，B01 服务端时钟）：[账号证明与 Gateway 时钟边界](server-clock-integer-boundaries.md)已补检查；独立进程复现 NaN 转 Int64 fatal error 后，新增非有限值、有效期相加越界和不可用编码截止的拒绝。Hello 在状态变更前检查，心跳覆盖异步准入后再次失效并释放请求关联；凭据接口将时钟故障返回为空正文、不缓存的 503，修复前错误 401 的三条失败断言留档。最终服务端 **57 项 / 7 套件（6.387 秒）**、真实 HTTPS **5 项 / 2 套件（2.734 秒）**、App UI **2 项（64.268 秒）**、独立后台入口 **1 项（1.298 秒）**通过。数据库 **16|7|0|0|7**、注册取消记录 **17|16|2**，专用数据库根与模拟器已独立核实移除。见[证据](evidence/20260907-server-clock-boundaries/manifest.json)。这不是远端可控时间戳攻击的证明；其余恢复 DTO、计数和时间消费者继续审计，B01 仍实施中，全部47项保持 **16 已验证、31 开放**。

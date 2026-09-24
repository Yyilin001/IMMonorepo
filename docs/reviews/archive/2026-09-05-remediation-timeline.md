# IM V2 修复与验证时间线（2026-09-05 → 2026-09-07）

> **历史归档。** 本文按时间顺序保留整改期间的追加记录，**不代表当前状态**。
> 判断当前设计合同请看 [合同索引](../README.md)，判断当前问题状态请看
> [问题状态表](../status.md)，判断能力与证据等级请看
> [`implementation-status.md`](../../../IMV2/docs/implementation-status.md)。
>
> 这些段落原先直接追加在状态文档和实现状态文档的正文里，导致"当前合同"与
> "演进过程"混在一起。2026-09-10 的文档整理把它们移到此处。

## 追加记录（倒序阅读无意义，按写入顺序保留）

后续修复批补充：schema 14 源端终态回执、配额与 pin 释放已通过 89 项相邻回归，并追加真实源文件删除/目标副本保留验证。完整 B04 仍未关闭；本报告主体的“本次复核”测试边界对应生成时点，后续证据以修复进度为准。
后续 schema 15 批补充：持久投递 worker、精确目标适配器、原子入队、租约/退避/超时取消与迁移回填已通过 90 项相邻回归（16 种投递场景、29 种门禁场景），见 [持久证据](../verification-records.md#20260905-forward-delivery)。运行入口仍未接通，B04 保持实施中。

最新补充：服务端公告和各角色权限快照已按对象 revision 排序并保留空状态；真实逆序分发、迟到旧事实、同版本冲突及此前权限保留/迁移/跨 owner 回归共 **24 项服务端测试 / 4 个套件** 通过，见 [策略快照验证](../verification-records.md#20260906-group-policy-snapshots)。客户端群控制 reducer、完整基线恢复、置顶历史和成员角色边界仍未关闭，B06 状态不变。

最新补充：protocol 24 已实现显式个人快照重建与 SQLite 持久意图，主库增至 166 个对象；响应丢失、重启、跨代恢复、outbox 保留、空账户及真实 ACK/设备撤销路径已验证。ClientKit **305 项 / 52 套件**、App **170 项 / 17 套件**、服务端定向回归 **56 项 / 6 套件**通过，见[个人基线恢复证据](../verification-records.md#20260906-personal-snapshot-rebuild)。群控制 reducer 迁移触发、历史负事实和独立房间日志恢复仍待完成，B06 状态不变。

最新补充：客户端公告已统一个人/预览/房间/快照的 revision 排序和持久去重；旧库未知来源不再以个人游标冒充，旧暂存快照升级重新导入，迁移不恢复已清除公告。最终 **309 项 ClientKit / 52 套件、170 项 App / 17 套件**通过，见[公告效果证据](../verification-records.md#20260906-announcement-effects)。SQLite 主库为 167 个对象；protocol 24、PostgreSQL schema 18 不变。各角色权限、置顶和成员角色仍待完成。

最新补充：角色权限恢复的服务端当前态基线、成员检查及不缓存的 owner 复核已实现。默认/显式空策略、GC/迁移、并发版本一致性、退群重入和实际控制库 epoch 变化已验证；**82 项 Core / 25 套件、29 项服务端定向回归 / 6 套件**通过，见[权限基线证据](../verification-records.md#20260906-policy-baseline)。此基础读取批尚未接入网关；后续协议接线见下文，客户端持久恢复和各角色 reducer 仍未完成。

最新补充：protocol **25** 已接通当前角色权限基线的认证网关、各 owner 生产组装和 ClientKit 传输，保留显式空策略并拒绝非法角色、权限、版本和响应关联。最终 **82 项 Core / 25 套件、312 项 ClientKit / 53 套件、170 项 App / 17 套件、72 项服务端定向回归 / 8 套件及 14 项编解码与监控回归 / 2 套件**通过，见[协议接线证据](../verification-records.md#20260906-policy-wire)。客户端持久恢复、各角色独立版本及迁移仍未接入，B06 不关闭；以上是分层测试，未执行真实 App 到 TLS 网关端到端验收。

最新补充：客户端角色权限已统一个人/预览/房间/快照的独立 revision 排序、来源冲突检查和空集合持久状态。旧库保留观察到的正权限值，不以个人游标伪造源版本；缺失角色保持未知，旧暂存快照重新导入。最终 **317 项 ClientKit / 53 套件、170 项 App / 17 套件**通过，见[角色效果证据](../verification-records.md#20260906-role-policy-effects)。SQLite 为 **168/5** 个对象；protocol 25、PostgreSQL 18 未变。持久基线恢复、账号/成员栅栏、置顶和成员角色仍待完成，B06 状态不变。

最新补充：客户端权限基线已增加持久恢复请求、独立完整观察点和账号/安装/成员/同步代次事务栅栏。重启、读取期间新事件、过旧响应保留意图、退群重入、小写 UUID 本人识别、账号变化、快照保留/移除及 staging 迁移已验证。最终 **322 项 ClientKit / 53 套件、170 项 App / 17 套件**通过，见[恢复存储证据](../verification-records.md#20260906-policy-recovery-store)。SQLite 为 **170/5** 个对象；自动 runner、认证连接生命周期和 App 接线仍待完成，B06 不关闭。

最新补充：权限恢复 runner 已按持久 nextAttemptAt 自动发现/重试，并接入 App 认证连接后台任务。单房间失败隔离、暂停/显式存储重试、FORBIDDEN、取消或成员变化后的迟到结果、无提示发现、旧请求迁移和 runtime stop 已验证；App 自动刷新权限并防止旧读取覆盖恢复结果，编辑草稿保留原 expectedRevision。最终 **327 项 ClientKit / 53 套件、171 项 App / 17 套件**通过，见[执行器证据](../verification-records.md#20260906-policy-runner)。SQLite 为 **171/5** 个对象；暂停状态的 App 反馈/重试入口、真实网络及权限弹层交互验收仍开放，B06 不关闭。

最新补充：权限策略与恢复状态已在同一次 SQLite 读取中返回，App 区分等待同步、排队、暂停和不可读取，并提供持久显式重试入口。重复提交、失败后再试、能力缺失、旧请求失败与新状态交错及通知范围已验证。最终 **329 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[状态与重试证据](../verification-records.md#20260906-policy-recovery-ui)。protocol 25、PostgreSQL 18、SQLite 171/5 未改；真实 TLS、弹层点击和无障碍人工验收仍开放，B06 不关闭。

最新补充：服务端置顶投影已按源房间序号比较并保留取消置顶负状态；实际逆序分发、日志清理后的重复、快照构建/读取/ACK 和冲突回滚已验证。ClientKit 同步修复群管理快照键的等价 UUID 拼写误拒绝。最终 **19 项服务端定向回归 / 4 套件、331 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[置顶快照证据](../verification-records.md#20260906-pin-snapshots)。客户端置顶 reducer、缺源序号的旧历史恢复、统一 worker 切换及成员角色仍开放，B06 不关闭。

最新补充：ClientKit 置顶四路消费已共享持久摘要、源序号排序及取消负状态。旧库个人游标丢弃为未知，可信房间日志回填，旧 staging 重导入并保留 outbox；普通/hybrid 快照、来源冲突、元数据补齐和本人退群清理已验证。最终 **339 项 ClientKit / 53 套件、176 项 App / 17 套件**通过，见[置顶效果证据](../verification-records.md#20260906-pin-effects)。SQLite 为 **172/5**；置顶缺源历史权威恢复、成员角色及完整授权代次/保留合同仍开放，B06 不关闭。

最新补充：服务端成员角色快照已按 room/target 的 membership revision 排序，旧管理员角色不能覆盖仍保留的新 member 事实，同版本不同来源拒绝并回滚用户 checkpoint。真实角色提交、逆序 fanout 与快照 build/read/ACK 等 **22 项服务端定向回归 / 4 套件**通过，见[成员角色快照证据](../verification-records.md#20260906-member-role-snapshots)。本批未新跑 ClientKit/App；逐成员离开/重入负状态、客户端处理和旧历史恢复仍开放，B06 不关闭。

最新补充：B16 已加入服务端 Push 会话 CAS、持久意图版本和禁用记录，低版本拒绝、同版本幂等/冲突、端点代次保护及原子回滚已通过真实数据库回归。PostgreSQL 更新为 **19**；Core **84 项 / 26 套件**、服务端定向回归 **23 项 / 4 套件**通过，含旧迁移链修正，失败及最终日志均见[Push 存储证据](../verification-records.md#20260906-push-intent-storage)。HTTP/客户端/App 尚未接通版本机制，B16 为实施中；现有 App 竞态仍开放。

最新补充：B16 版本路由已接入 Account 认证/限流入口，ClientKit 增加设备绑定的会话与意图传输。真实 HTTP pipeline＋PostgreSQL 反序写入和 legacy 拒绝、输入/错误映射及限流已验证，**343 项 ClientKit / 54 套件、10 项服务端 / 4 套件、176 项 App / 17 套件**通过，见[HTTP 证据](../verification-records.md#20260906-push-intent-http)。App 仍走旧链路，持久意图执行器及其接线继续开放。

最新补充：B16 本地单行状态已保存偏好/desired、单调版本、claim、token 随机引用和重试/暂停，并以完整状态比较保护执行器接管和迟到结果。重开数据库、pending reset 迁移保留待发消息、退出偏好、账号/安装/设备隔离及事务回滚已验证；**348 项 ClientKit / 55 套件、176 项 App / 17 套件**通过，见[本地 Push 证据](../verification-records.md#20260906-push-intent-local)。SQLite 为 **173/5**，自动执行器和 App 接线仍开放。

最新补充：B16 自动执行器已实现本地输入合并、HTTP 单飞、自动发现、持久退避/429 等待、原 claim 重试、stale 暂停和停止排空。实际 SQLite 观察/计时器、旧请求等待期间关闭、重开数据库、旧 owner 回包等已验证，**355 项 ClientKit / 56 套件、176 项 App / 17 套件**通过，见[执行器证据](../verification-records.md#20260906-push-intent-reconciler)。App 仍走旧设置链路，状态观察、退出及账号生命周期接线继续开放。

最新补充：B16 App 开关、APNs 回调、持久状态观察、用户偏好备份及退出移除已接入版本执行器；注册期间可关闭，失败自动重试，并发停止共同等待排空后才关闭数据库。最终 **355 项 ClientKit / 56 套件、176 项 App / 17 套件**通过，编译失败与修正过程见[App 接线证据](../verification-records.md#20260906-push-intent-app)。真实 HTTPS/服务端最终状态、App 账号切换及退出组合仍开放，B16 不关闭。

最新补充：B16 Push 请求已绑定认证代次，获取凭据/发送/响应均复核；同设备重新登录后的旧请求取消，退出先排空旧 owner，再用清理代次和更高版本禁用。真实认证 actor＋SQLite＋受控 HTTP 组合及相同代次刷新通过；最终 **361 项 ClientKit / 57 套件、176 项 App / 17 套件**通过，见[认证隔离证据](../verification-records.md#20260906-push-intent-auth)。真实网络、持久退出及完整 App 换号验收仍开放，B08/B09/B16 状态不变。

最新补充：B18 已闭环本地历史定位。目标主键与前后索引 seek、共同排序、装饰及授权/撤回读取在同一 SQLite 快照内；10 万条历史和置顶负记录下查询步数保持有界，App 取消/刷新/更晚目标与实际滚动通过。恢复原裸滚动 ID 的负向实验只触发对应回归失败；最终 **365 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，见[定位证据](../verification-records.md#20260906-timeline-location)。B18 更新为已验证，其他问题状态不变。

最新补充：B23 单库配额竞态已通过真实锁屏障复现并修复。19 条 pending/approving 占位下两个不同邀请并发提交，旧实现最终为 21，修复版为 20；重复 operation、输入冲突和拒绝后重用名额通过。最终 **6 项服务端测试 / 2 套件**通过，见[配额证据](../verification-records.md#20260906-invitation-applicant-quota)。本批未改 schema，control 全局 reservation 和跨 owner 释放仍待实现，B23 为实施中。

最新补充：B08 的仅撤销凭据已完成类型、摘要存储和兑换事务，PostgreSQL 为 **27**。认证/刷新误用拒绝、刷新后撤销、会话绑定变化、10 个并发重复、失败回滚、新会话隔离及期限已通过真实数据库验证；**93 项 Core / 30 套件、16 项服务端单元 / 2 套件、20 项真实 PostgreSQL 回归 / 1 套件**通过，独立 26→27 迁移及 schema 正反向门禁通过，失败过程保留于[验证证据](../verification-records.md#20260907-revocation-capability-storage)。内部签发尚未接入登录响应，HTTP/ClientKit/App 尚未接线，见[存储合同](../device-revocation-capability-storage-contract.md)。B08 保持实施中，47 项总表仍为 16 项已验证、31 项开放。

最新补充：B08 已接通[仅撤销 HTTP 与 ClientKit 传输](../device-revocation-capability-http-contract.md)，Account 入口纳入 trusted-edge 和持久地址限流，严格限制目标输入；独立客户端不读取或刷新当前账号凭据。**20 项服务端单元 / 4 套件、4 项真实 PostgreSQL 回归 / 1 套件**通过；ClientKit **421 项报告 / 66 套件，416 项实际执行、5 项在线跳过**，见[证据](../verification-records.md#20260907-revocation-capability-http)。真实数据库 HTTP pipeline 验证 503 完整回滚、204 幂等、429 保留新设备；本批未执行 HTTPS socket/App 全链路。登录交付及 App 持久补偿仍未完成，B08 保持实施中，16 项已验证、31 项开放。

最新补充：B08 已修复[签发取消与活动旧凭据替换](../credential-issuance-boundaries-contract.md)。四个取消挂起点原先仍发送 HTTP（14 个失败断言），活动旧凭据也可被直接覆盖（4 个失败断言），另补 URLSession 取消分类。最终 **439 项客户端实际执行（5 在线跳过）、195 项 App 实际执行（1 在线跳过）**通过，真实 HTTPS/PostgreSQL 5 项通过，见[证据](../verification-records.md#20260907-issuance-boundaries)。迟到/完全丢失响应的持久结果归属仍开放，B08 与 47 项状态不变。

最新补充：B08 已补[退出确认状态与显式恢复](../device-revocation-status-contract.md)，仅向 UI 提供聚合状态；恢复保留原操作与次数、普通退避不变，读失败后的无变化重试也重新订阅。**437 项 ClientKit 实际执行（5 在线跳过）、195 项 App 实际执行（1 在线跳过）**通过。两项最终 UI 测试与截图验证点击、显式最大字号、RTL、登录/重试触达和无障碍审计，见[证据](../verification-records.md#20260907-revocation-status)。早期仅用启动参数的通过结果未证明最大字号，已留证并纠正。真机 VoiceOver 与完整系统后台边界仍开放，47 项状态不变。

最新补充：B08 已接通[独立撤销执行与本地退出](../device-revocation-runner-contract.md)。前台自动发现持久任务并退避重试，后台取消保留旧 flight 所有权；退出已移除 Push 网络清理依赖，过期本地凭据也能退出并冷启动保持 signedOut。**434 项 ClientKit 实际执行（5 在线跳过）、194 项 App 实际执行（1 在线跳过）**通过；真实 HTTPS＋PostgreSQL 5 项验证提交后结果丢失、原操作重放和队列完成，见[证据](../verification-records.md#20260907-revocation-runner)。暂停反馈/恢复入口及完整生命周期交互仍开放，B08 不关闭，16 项已验证、31 项开放。

最新补充：B08 已完成[退出时的持久交接](../device-revocation-handoff-contract.md)：原凭据先保存操作 ID，再提交独立撤销队列，最后删除登录凭据；重启不恢复标记退出的会话，新登录不能覆盖未交接的旧记录。最终 **427 项 ClientKit 实际执行（5 在线跳过）、193 项 App 实际执行（1 在线跳过）**通过，含真实签名模拟器 Keychain 的保护等级、重建 owner 和换号隔离。初次无签名测试宿主的 Keychain 权限失败和修正后的运行均见[证据](../verification-records.md#20260907-revocation-handoff)。自动联网执行及断网退出仍未接通；B08 保持实施中，16 项已验证、31 项开放。

最新补充：B08 已完成[原子签发和凭据保存](../atomic-revocation-credential-issue-contract.md)，PostgreSQL 为 **28**。注册事务保存撤销摘要和加密完整重放；刷新保持原证明及期限，ClientKit 与 access/refresh 同项保存。**21 项 PostgreSQL、10 项服务端单元、418 项客户端实际执行（5 在线跳过）、192 项 App 实际执行（1 在线跳过）**通过。完整真实链路另通过 5 项 HTTPS、2 项 UI 和 1 项 headless；新增 capability 兑换定向 HTTPS 5 项通过，见[证据](../verification-records.md#20260907-atomic-revocation-issue)。App 独立持久交接及离线补偿尚未实现，B08 不关闭，16 项已验证、31 项开放。

最新补充（B08 已收到结果）：HTTP 签发返回前先保存仅含撤销能力的中间记录；冷启动识别已接管会话，其余转入持久撤销队列。取消/退出后的迟到结果、写入失败、既有暂停任务保留和真实模拟器 Keychain 恢复通过。最终 ClientKit 447 项实际执行（5 跳过）、App 196 项实际执行（1 跳过）、真实 HTTPS/PostgreSQL 5 项通过。见[结果交接合同](../received-credential-recovery-contract.md)及[证据](../verification-records.md#20260907-issued-result-recovery)。完全丢失响应和系统级中断验收仍开放，B08 保持实施中；16 项已验证、31 项开放。

最新补充（B08 注册取消仲裁）：新增请求前可持有的独立取消证明、服务端取消记录，以及与签发共用事务的绑定；取消先到阻止签发，签发先到则原子撤销。锁后期限检查、证明四字段隔离、两侧回滚和旧迁移链共 21 项真实 PostgreSQL 测试通过，Core 95 项、原有 HTTP 单元 10 项通过。PostgreSQL 升至 29，见[合同](../registration-cancellation-contract.md)。HTTP/App 尚未切换到新证明，完全丢失响应的端到端恢复仍开放，B08 及全部 47 项状态不变。

最新补充（B08 取消 HTTP）：账号服务已挂载受 trusted-edge 和地址限流保护的注册取消路由，ClientKit 增加不依赖登录凭据的传输。ClientKit 453 项实际执行（5 跳过）、HTTP 单元 13 项、真实 PostgreSQL 22 项通过；真实 HTTPS 5 项验证取消提交后丢弃客户端结果、原证明重放仍只有一条取消记录。见[HTTP 合同](../registration-cancellation-http-contract.md)及[证据](../verification-records.md#20260907-registration-cancellation-http)。HTTP 签发强制证明与 App 请求前持久化/独立取消队列仍开放，16 项已验证、31 项开放不变。

最新补充：B27 第一阶段已加入 control token 目录、稳定创建 intent 与提交协调器，PostgreSQL 更新至 **22**。真实双库提交后丢响应、目录完成失败、并发重试、冲突绑定和 21→22 历史链接回填通过；最终 **17 项测试 / 2 套件**包含七条历史迁移链及审批、配额、恢复回归，见[目录证据](../verification-records.md#20260906-invite-directory)。Account 生产路由、epoch 和 control 身份拆分尚未接入，B27 保持实施中。

最新补充：B27 已完成 Account owner 路由与 control 身份拆分，PostgreSQL 为 **23**；三库验收覆盖两个无 profile 副本 owner 的完整邀请操作及 epoch/缓存边界。最终 **29 项测试 / 3 套件**、22→23 数据保留迁移和完整 readiness 负例通过，见[路由证据](../verification-records.md#20260906-routed-invitation)。完整 owner 迁移、历史目录导入、主动 intent 恢复以及 B23 全局申请配额仍开放，关闭总数不变。

最新补充：B27 的 prepared 创建意图已接入持久队列与 Account 后台恢复，PostgreSQL 为 **24**。原创建时间与本次判断时间分离，过期、额度、目录/任务原子发布、并发认领/前台重试、失权后原结果恢复及取消后的租约接管已验证。最终 **31 项测试 / 3 套件**和 23→24 回填/完整 readiness 负例通过，见[创建恢复证据](../verification-records.md#20260906-invite-creation-recovery)。B27 仍待完整历史迁移及旧目录导入，关闭总数不变。

最新补充：B27 的历史 owner 链接创建重试已修复：预检查返回原链接，control 沿用原 ID/时间建目录。未修复版本在普通群和大群均复现 ownerResultMismatch；修复后四种状态、每种十次并发重试、原 token、发布失败后后台恢复及矛盾绑定保留已验证。最终 **33 项测试 / 3 套件**通过，见[历史绑定证据](../verification-records.md#20260906-legacy-invite-retry)。PostgreSQL 24、protocol 25、SQLite 173/5 不变；旧目录分页导入和完整 owner 历史迁移仍开放，关闭总数不变。

最新补充：B27 的独立 operator 旧目录分页导入已接通，PostgreSQL 为 **25**。103 条链接跨页、十次并发幂等、prepared/claimed 任务完成、三类绑定冲突整页回滚、不可变审计、owner 读取期间 control 路由改变，以及实际 HTTP/同库空页已验证。最终 **39 项测试 / 5 套件**与真实 24→25 数据保留迁移及完整 readiness 负例通过，见[导入证据](../verification-records.md#20260906-invite-directory-import)。完整 owner 历史迁移仍开放；protocol 25、SQLite 173/5 和关闭总数不变。

最新补充：B27 迁移前置检查发现普通成员变更丢弃 owner epoch、单库跳过路由的问题；修复前两种群模式均产生了旧 owner 上的实际移除/回执/事件。现已强制传递 route/epoch，在回执重放前取得事务栅栏，并接通单库 Gateway。旧缓存、新 epoch 重放、十次并发、等待房间锁期间 epoch 变化及当前身份保护已验证；最终 **78 项测试 / 7 套件**通过，见[成员栅栏证据](../verification-records.md#20260906-membership-owner-fence)。其他房间写入路径的统一栅栏及完整迁移执行器仍开放；schema 25、protocol 25、SQLite 173/5 和关闭总数不变。

最新补充：消息编辑、撤回与 reaction 同样存在丢弃 owner epoch、旧回执先于 owner 校验的问题；负向测试在两种群模式共六个场景确认旧 owner 实际提交。现已强制传递所选 route，并在消息事务内先锁房间核对 owner，再重放或写入；单库 Gateway 也使用验证入口。最终 **87 项测试 / 7 套件**通过，见[消息变更栅栏证据](../verification-records.md#20260906-message-mutation-owner)。通用发送、其他房间命令、后台任务及完整迁移仍开放；47 项关闭总数与 schema 版本不变。

最新补充：公告、置顶、角色权限和成员角色同样存在 owner 栅栏缺口；修复前八个真实双库场景均发生旧 owner 提交，32 个断言失败。现已在四类事务回执重放及 self-role 提前返回之前校验所选 owner，单库与同物理库多 shard 也保留 epoch。最终 **93 项测试 / 7 套件**通过，见[群管理栅栏证据](../verification-records.md#20260906-group-capability-owner)。moderation、已读回执、通用发送、读取/后台任务及完整迁移仍开放；schema 与 47 项状态总数不变。

最新补充：普通 moderation 的消息屏蔽/禁言/移除，以及可信安全服务的屏蔽/冻结/解冻，均已补齐所选 owner 的事务栅栏。修复前十二个真实双库场景均在旧 owner 提交业务和审计，60 个断言失败；修复后旧回执也必须先通过 owner 检查。Gateway 单库和内容审核服务已接通，审核遇到 owner 错误保留重试/暂停，不误记完成；私有 selector 已移除同库绕过入口。最终 **113 项测试 / 8 套件**通过，见[moderation 栅栏证据](../verification-records.md#20260906-moderation-owner)。已读回执、通用发送、其他后台任务和完整迁移仍开放，schema 和 47 项状态总数不变。

最新补充：群已读回执单条/批量和读者候选分页已保留所选 owner。批量按固定顺序取房间共享锁，逐行验证 epoch，错误行不参与游标推进或旧回执重放，合法同行正常提交；路由单条复用同一批量锁路径。混合 owner、20 次单条/批量竞争、control 隐私过滤、两房间并发及既有三库回归最终 **126 项测试 / 11 套件**通过，见[群回执栅栏证据](../verification-records.md#20260906-read-receipt-owner)。私聊后续 control 投影事务的跨库交接、通用发送、其他后台任务及完整迁移仍开放；schema 与 47 项状态总数不变。

最新补充：普通消息发送的单条、私聊冷批量/暖缓存快速追加和大群集合批量已在事务内验证 owner；同物理库仍保留逐房间 route/epoch。Gateway 共享房间依赖也补齐独立命名的 direct shard，复用原缓存与额度 actor。最终 **162 项测试 / 13 套件**通过，包含旧缓存、错误/未知 owner、等锁时 epoch 改变、整批回滚、credit 归还、两房间并发及既有三库恢复链，见[发送 owner 证据](../verification-records.md#20260906-send-owner)。发送 control 身份/策略隔离、后台转发导入、来源/其他读取、投影交接和完整迁移仍开放；47 项状态统计不变。

最新补充：后台转发目标的新 inbox 入队、accepted 恢复与最终 completed 发布已补 owner 事务栅栏。旧 owner 不再新增任务或误发布终态，源端继续保留未完成 export 的占用；同 owner 恢复保持原消息身份，已完成不可变回执仍可重读。首轮 7 项集成测试、最终 **176 项测试 / 14 套件**通过，见[后台转发 owner 证据](../verification-records.md#20260906-forward-import-owner)。前台同库转发的 route 快捷分支、投影/活跃任务迁移承接及完整迁移仍开放，B04/B27 与 47 项状态统计不变。

最新补充：前台同库转发现保留来源与目标的 shard/epoch，并在来源读取、幂等记录/结果修复、消息接受和最终补记事务中验证。仍保留同库一次来源批量查询及有界目标并发。旧实现两端 epoch 反例共 6 issues；修复后 **184 项测试 / 14 套件**通过，含等锁更新、接受前后 owner 变化、稳定消息身份、并发重试、反向互转及既有三库回归，见[前台转发 owner 证据](../verification-records.md#20260906-local-forward-owner)。完整历史/活跃工作迁移、用户投影交接、其他读取与 worker、全局内容封禁和终态清理仍开放，B04/B27 及 47 项状态统计不变。

最新补充：B05 已改为 Argon2id v19 完整 UTF-8 输入、固定参数 PHC 编码及独立双线程预算。NUL 拒绝，长密码后缀参与验证；旧 bcrypt 保留原样且不再凭前缀等价验证发出断言。成功认证先事务复核原完整 hash，再原子提交审计/失败窗口清理。最终 **39 项测试 / 7 套件**通过，含官方向量、Unicode/空白、异常参数、真实 32 请求突发（2 执行 / 30 busy）、取消排空、PostgreSQL HTTP、并发凭据替换及审计故障回滚，见[密码哈希证据](../verification-records.md#20260906-password-hash)。B05 在当前绿地输入/存储/认证合同内已验证；生产旧账号可信恢复、Linux binary 和完整容量验收仍归发布缺口，不能据此宣称生产就绪。

最新补充：B03 的普通编辑、作者撤回和 reaction 已按每条消息不可变的接受记录选择分发，direct room-log 不再误建逐用户变更任务；原 accepted 与变更从同一房间日志恢复。缺少接受记录的新操作在修改前失败，已完成操作保持幂等。最终 **186 项测试 / 14 套件**通过，含 21 个发送/存储/重放组合和 6 个缺失记录回滚场景，见[分发归属证据](../verification-records.md#20260906-message-delivery-authority)。B03 更新为实施中；历史受众交集、精确额度结算、typed replacement、旧缺基线恢复、内容撤销和完整快照仍开放。

最新补充：B03 新 personal 变更的 fanout 已按 accepted 与变更时刻的独立成员区间取交集，保留离群重入成员、排除纯新成员。单条/批量 planner 共用分页，持久结束标记后原子结算真实人数及预留差额；同窗口退还多余消耗，换代后保留新窗口计数。零受众关闭计划与 outbox，混合批次确认仍验证未完成行的租约。最终 **221 项测试 / 16 套件**通过，含故障注入、八路并发重试、真实完成释放与 10 万成员分页，见[受众结算证据](../verification-records.md#20260906-message-audience)。reaction 操作者历史授权、其他读取入口、typed replacement、旧积压恢复和内容撤销仍开放，B03/D07 及 47 项状态统计不变。

最新补充：B03 的 reaction 新操作已验证 accepted 时刻与当前成员身份；普通 edit/withdraw/reaction 的 room pull 在分页前按原消息和变更时刻独立过滤。缺少接受记录直接失败，不跳过未知内容。protocol **26** 将 continuation 明确为已扫描序号，ClientKit 接受不可见尾部及空页推进，物化失败仍原子回滚，预览不写持久游标。最终 **262 项服务端 / 21 套件、367 项 ClientKit / 58 套件、182 项 App / 17 套件、84 项 Core / 26 套件**通过，见[历史读取证据](../verification-records.md#20260906-message-read-authority)。typed replacement、其他内容入口、access epoch 恢复、独立撤销和完整快照仍开放，47 项状态统计不变。

最新补充：protocol **27** 的新编辑携带原接受身份和显式完整内容，ClientKit 与服务端个人投影可处理成员重入后的合法 rev1→rev3，以及编辑先到、accepted 后到，旧增量仍不得跳版本。共享批量、共享单条和内联投影均保留新状态；错误身份、同版本冲突、非法完整值和终态后的替换失败并回滚。最终 **288 项服务端 / 25 套件、372 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含真实 owner/fanout 载荷交给 ClientKit 的验证，见[完整编辑证据](../verification-records.md#20260906-message-edit-replacement)。旧积压、其他读取入口、access epoch、独立撤销与完整 room 恢复仍开放，B03/B06/D07 和 47 项统计不变。

最新补充：普通撤回已支持合法 revision 缺口和完整状态先到，晚到 accepted/旧编辑不会恢复正文；ClientKit 快照激活后的同终态源事件可从 personal/room/preview 重放，清除遗留回复引用且不重复创建搜索任务。错误房间、非法版本、矛盾活动状态及审核删文缺基线保持失败与 checkpoint 回滚。最终 **289 项服务端 / 25 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含 21 个服务端终态场景及实际快照导入、重开验证，见[终态证据](../verification-records.md#20260906-message-terminal-projection)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；缺基线旧积压、独立内容撤销和未重放历史行清理仍开放，B03/B06/B04 与 47 项状态不变。

最新补充：回复和置顶已在 owner 写入事务内校验原 accepted 与当前内容版本受众，隐藏置顶 no-op 也不能绕过授权；转发与按消息定位的媒体读取统一使用不可变接受记录，正文存储兼容列不再决定历史可见性。修复前 32 个场景记录 32 处失败，最终 **292 项服务端扩展回归 / 25 套件**通过，包含 44 个引用场景、15 个媒体场景及历史完整/缺失记录和索引计划，见[引用授权证据](../verification-records.md#20260906-message-reference-visibility)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；本批未修改或重新测试客户端，B03/B04 和 47 项状态不变。

最新补充：旧媒体入口已修复合法 UUID 拼写误拒绝，并要求消息原 accepted/当前版本受众及有效投影；头像保持独立可见性。申请、领取与供应商返回后的完成消费均检查账号/设备/内容，旧 token、过期或被接管租约不能返回地址；领取、供应商和数据库完成阶段的取消/过期均覆盖。最终 **307 项服务端扩展回归 / 28 套件**通过，含 30 个真实数据库场景及 6 个返回边界场景，见[旧媒体证据](../verification-records.md#20260906-legacy-media-authorization)。protocol 27、PostgreSQL 25、SQLite 173/5 不变；本批未改客户端，多 owner 完整迁移及统一 access epoch 仍开放，B03/B04 和 47 项统计不变。

最新补充：B01 的资料版本已限定为正 Int64，备注/昵称 HTTP 拒绝显式非法版本，SQL 使用有符号绑定，资料版本耗尽时失败并回滚；个人投影可提交最大序号，不再计算溢出的下一序号。最终 **316 项服务端扩展回归 / 30 套件、87 项 Core / 27 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，含 12 个备注/昵称、8 个公开资料、3 个投影极值及 6 个 HTTP 拒绝场景，见[整数边界证据](../verification-records.md#20260906-profile-projection-boundaries)。负例包含两个独立进程 signal 5 和初轮 HTTP 失败，均保留原始日志；protocol 27、PostgreSQL 25、SQLite 173/5 不变。其他恢复 DTO、计数及时间转换仍待审计，B01 和 47 项统计不变。

最新补充：B01 七处浮点时间转整数已使用精确可表示性检查，保留各自向下/向零取整与错误类别。Core 媒体和真实跨 owner projector 修复前均以 signal 5 退出，修复后异常时间拒绝且不写分发状态，合法微秒与重试幂等保持精确。最终 **338 项服务端扩展回归 / 33 套件、89 项 Core / 28 套件、374 项 ClientKit / 58 套件、182 项 App / 17 套件**通过，见[时间戳证据](../verification-records.md#20260906-timestamp-integer-boundaries)。快照计数经现有 schema 上限约束排除溢出疑点；其他转换/计数与恢复 DTO 仍开放，47 项状态不变。同步更正 B29 当前协议号为 27。

最新补充：B02 已补 24 个真实 PostgreSQL 确定提交顺序场景，覆盖冻结、禁言、moderation/membership 两种移除、撤销角色发言权及降级。通过 pg_locks/pg_blocking_pids 观察真实锁依赖；权限先提交则编辑拒绝，编辑先提交则只生效一次，限制后原操作仅重放回执。最终 **91 项相关服务端回归 / 6 套件**通过，见[提交顺序证据](../verification-records.md#20260906-edit-policy-commit-ordering)。本批仅新增验证与文档，B02 标为已验证；全表变为 **14 项已验证、33 项仍开放**，不代表其他授权/恢复/生产验收问题已关闭。

最新补充：B09 业务 HTTP 的 401 已进入共享刷新判定，刷新终止通过认证快照驱动 App；业务 403、网络失败及取消保留凭据，前驱 token 和旧账号回包受代次保护。共享刷新只收尾一次，32 并发调用者误报会话失效的问题已修复。最终 **384 项 ClientKit / 59 套件、183 项 App / 17 套件**通过，见[HTTP 认证合同](../session-http-authorization.md)与[原始证据](../verification-records.md#20260906-session-http-authorization)。本批使用受控 HTTP，真实账号服务和 TLS 仍开放；B09 状态不变，维持 14 项已验证、33 项开放。

最新补充：B09 已加入[本地真实账号 HTTPS 验收](../live-account-https-authorization.md)，四项测试通过，实际数据库确认被撤销设备无有效访问/刷新凭据且撤销事件恰好一次。未更改生产策略或信任设置；App 完整界面、Keychain 和实时 Gateway 重连尚未纳入该链路，B09 保持已实现待验证。原始日志、状态计数与清理记录见[本批证据](../verification-records.md#20260906-live-account-https)。

最新补充：B09 的真实 App＋Gateway 验收复现了设备撤销后只看到 EOF、继续重连的实际缺陷。服务端现先写出可关联的认证拒绝再关闭连接；基础设施异常保留原失败路径。两项 App UI、四项真实 HTTPS、64 项服务端及 384 项 ClientKit 离线测试通过，数据库和 Gateway 指标确认撤销与清理，见[完整链路证据](../verification-records.md#20260906-app-gateway-authentication)。B09 标为已验证；当前共 **15 项已验证、32 项仍开放**，B08 的持久退出/换号与外部验收不随之关闭。

最新补充：B01 已修复客户端合法最大毫秒值保存到 SQLite 后、读取禁言投影时反向转换 Int64 的实际崩溃；新禁言、会话命令和心跳加入精确转换检查。最终 **91 项 Core、388 项实际执行的 ClientKit 离线测试、183 项 App 和 49 项服务端**通过，见[客户端时间边界合同](../client-timestamp-integer-boundaries.md)及[证据](../verification-records.md#20260906-client-timestamp-boundaries)。服务端快照计数已由 schema 约束排除当前溢出风险，未误列为新缺陷；B01 继续实施中，维持 15 项已验证、32 项开放。

最新补充：B01 的账号限流窗口、密码锁定时长和失败阈值已与驱动日期编码及 SQL integer 范围对齐；消费、清理和密码失败写入均在绑定前检查实际日期，失败计数达到 Int32 上限后继续维持拒绝状态和审计。最终 **29 项服务端 / 5 套件**通过，含三个真实 PostgreSQL 场景；负向配置、计数上限四路并发和非法日期无写入证据见[限流边界合同](../account-rate-limit-integer-boundaries.md)及[证据](../verification-records.md#20260906-account-rate-limit-boundaries)。B01 保持实施中，仍为 15 项已验证、32 项开放。

最新补充（D01 关闭）：补强真实 Network.framework 旧 reader 迟到失败测试，增加接收进入及结束断言；反向移除 generation close guard 后，新连接按预期报 connectionClosed，随后已恢复原源码并通过完整客户端回归。生产代次隔离实现本批未变。见[验收说明](../network-generation-fencing.md)与[证据](../verification-records.md#20260906-network-generation-fencing)。当前 **16 项已验证、31 项仍开放**。

最新补充（B07）：跨批次公平调度已修复，预算 1/2/4 的原实现失败证据与修复回归已归档。实际 SQLite、双 outbox lane、protobuf 与 NWConnection 组合覆盖安静到期、空闲入队、停止后无活动及数据库重开恢复；客户端 390 项实际执行、App 183 项单元回归通过。见[合同](../durable-retry-network-contract.md)及[证据](../verification-records.md#20260906-durable-retry-network)。B07 保留真实 App 后台恢复验收，计数仍为 **16 项已验证、31 项仍开放**。

最新补充（B08）：退出标记改用带版本的原子文件、显式同步与错误传播，兼容旧 UserDefaults 并按 Keychain service 隔离；本地完成记录延后到任务停止/数据库关闭之后，重试补齐单飞。189 项 App 单元、4 项真实 HTTPS、2 项真实 App UI（HTTP/TLS Gateway 撤销及冷启动）通过；独立临时环境已清理。见[合同](../durable-sign-out-marker-contract.md)和[证据](../verification-records.md#20260906-durable-sign-out-marker)。真机文件保护、每步强杀、完整退出 checkpoint 与离线远端补偿仍开放，计数仍为 **16 项已验证、31 项仍开放**。

最新补充（D03）：App Push 已切换至默认 25 秒工作截止、个人/room-log 合计 4 页的专用后台 runner。补齐同步 gate、可取消共享认证等待、迟到 pull 写入拦截和 SQLite 实际新增计数；后台认证终止不再 await 完整退出。401 项客户端实际执行、188 项 App 单元、4 项真实 HTTPS、2 项真实 App 认证终止/冷启动 UI 回归通过。后两项未注入 Push；实际 Push/真机收尾、锁屏与网络悬挂仍待验证，D02 无 scene 恢复独立开放。见[合同](../bounded-incremental-sync-contract.md)和[证据](../verification-records.md#20260906-bounded-incremental-sync)。当前 **16 项已验证、31 项仍开放**；实施中 14 项、未开始 14 项。

最新补充（D03 网络期限）：真实回环 NWConnection 的 TLS、Hello、认证、pull、ACK 五个挂起场景通过；1 秒工作预算下断言小于 5 秒返回并关闭对端连接，认证材料保留。四个非 TLS 场景恢复响应后重连同步成功，ACK 超时已提交的数据不重复算作新增。完整客户端报告 406 项 / 63 套件，其中 402 项实际执行、4 项在线跳过；本批未修改生产代码、未重跑 App 或注入真实 Push。D03 仍为实施中，16 项已验证、31 项开放不变。见[网络期限证据](../verification-records.md#20260906-background-network-deadlines)。

最新补充（D02/D03）：App delegate 初始化即创建共享 store 并注册 Push handler，页面复用同一实例；Push 可等待共享恢复，恢复与增量同步共用绝对截止，后台不启动完整前台任务。单个取消/期限、恢复所有者迟到回调、剩余预算、短同步等待方及无 View delegate 回调已验证。最终 **404 项客户端实际执行、192 项 App 单元、4 项真实 HTTPS、2 项真实 App 认证终止/冷启动 UI**通过；另 4 项在线客户端测试在离线全量回归中跳过。UI 回归未注入 Push，真实带凭据无 scene、锁屏和系统期限仍待验收。D02 从未开始改为实施中，当前 **16 项已验证、31 项开放；实施中 15 项、未开始 13 项**。见[共享启动合同](../shared-app-restoration-contract.md)和[证据](../verification-records.md#20260906-shared-app-restoration)。

最新补充（D02/D03 真实入口）：新增独立 delegate/store 的真实凭据入口测试，经 HTTPS 签发、Keychain、TLS Gateway 和 SQLite 完成首次恢复、重放、远端撤销及退出后的 Push。最终 1 项入口、4 项真实 HTTPS、2 项真实 UI 和 192 项离线 App 测试通过；离线报告另有 1 项在线测试跳过。本批只改测试/验证脚本与文档，修正了 UI 弹层切换时的立即取样断言及撤销测试的调用方式。系统无 scene/APNs/锁屏验收保持开放，47 项状态不变。见[合同](../headless-push-entry-contract.md)与[证据](../verification-records.md#20260906-headless-push-entry)。

最新补充（B08 服务端）：新增仅撤销认证当前设备的 HTTP 入口，复用账号锁和凭据/Push/事件原子撤销。5 项真实 HTTPS 测试与 19 项服务端定向回归通过；临时数据库注入 journal 失败验证事务回滚，十次并发投递只增加一条操作记录。App 接线及新登录 device ID 轮换尚未完成，B08 保持实施中，16 项已验证、31 项仍开放。见[合同](../current-device-logout-contract.md)及[证据](../verification-records.md#20260906-current-device-logout)。

最新补充（2026-09-07，B08）：App 新登录改用按账号隔离的 Keychain 注册记录，成功后退休 device/operation 身份；旧注册完成不能清除新记录，异步准备前后的认证 epoch 防止退出后迟到开始签发。最终客户端 416 项报告 / 411 项实际执行、App 193 项报告 / 192 项实际执行通过。两项真实 App UI 覆盖 HTTP/Gateway 撤销、冷启动后同账号再次登录，并用服务端设备列表确认新 ID；5 项真实 HTTPS 及 1 项独立 delegate/store 后台入口回归通过。数据库 15|5|0|0|5，清理后 Gateway 为 0，专用资源已移除。见[合同](../registration-lifecycle-contract.md)和[证据](../verification-records.md#20260907-registration-lifecycle)。B08 保持实施中，当前 16 项已验证、31 项开放。

最新补充（2026-09-07，B08 期限）：PostgreSQL 升至 26，设备会话默认绝对 30 天，access/refresh 与认证租约不能超过截止，操作重放也检查当前设备状态；Push、快照可用性和媒体授权按期限拒绝，上传/下载提供方返回后的兑换补齐当前授权。19 项真实 PostgreSQL、54 项服务端单元、schema 25 到 26 迁移与负向就绪检查通过；5 项真实 HTTPS、2 项撤销后重新登录 App UI、1 项后台 delegate/store 入口回归通过，临时资源已清理。见[合同](../device-session-absolute-expiry-contract.md)和[证据](../verification-records.md#20260907-session-absolute-expiry)。离线补偿能力和 App 完整退出 checkpoint 尚未完成，仍为 16 项已验证、31 项开放。

最新补充（2026-09-07，B08 签发证明绑定）：[请求前持久化与强制 HTTP 绑定](../proof-bound-issuance-contract.md)已实现，注册 ledger 升为 format 2；缺少或不匹配确认会先交接收到的撤销能力再拒绝登录，旧记录保留档案，过期尝试保留证明并换用新身份。客户端 **462 项报告 / 457 项实际执行**、接口 **14 项**、真实 PostgreSQL **22 项**、App **197 项报告 / 196 项实际执行**通过；最终真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过。数据库设备/撤销/残留访问/残留刷新/事件为 **16|7|0|0|7**，取消记录总数/绑定/取消为 **17|16|2**；独立补偿允许多个操作指向同一已撤销设备，事件仍不重复。脚本调用同步补齐证明，Compose 栈脚本只做语法及共用工具离线检查。初始解码错误、旧 UI 夹具和旧统计假设的失败均留档；最终专用资源已移除。见[证据](../verification-records.md#20260907-proof-bound-issuance)。自动取消执行器、冷启动请求前证明归属、旧会话清理和真机系统中断仍开放；47 项仍为 **16 已验证、31 开放**，B08 不关闭。

最新补充（2026-09-07，B08 遗弃注册自动取消）：[执行器与冷启动归属](../registration-cancellation-runner-contract.md)已接入 App。format 3 原子迁移旧证明并保存尝试次数、退避和暂停，冷启动只把未被当前持久凭据接管的 pending 入队；前台观察自动执行，后台取消并等待实际请求结束，清理反馈和手动重试覆盖两类队列。客户端 **472 项报告 / 467 项实际执行**、签名 App **199 项报告 / 198 项实际执行**通过；真实 Keychain 验证归属及暂停反馈。真实 HTTPS **5 项**、App UI **2 项**、独立后台入口 **1 项**通过，验证签发和取消响应相继丢失后仍使用原证明重试。数据库 **16|7|0|0|7**，取消记录 **17|16|2**，取消 HTTP 204 四次但记录不重复；专用资源已清理。见[证据](../verification-records.md#20260907-registration-cancellation-runner)。旧会话/legacy 档案清理、真实强杀/锁屏/系统后台和记录 GC 仍开放；B08 保持实施中，全部 47 项仍 **16 已验证、31 开放**。

最新补充（2026-09-07，B08 实际进程中断）：[真实 App 两次终止后恢复](../registration-process-interruption-contract.md)已通过。HTTPS 代理在服务端签发/取消分别提交后保留响应，受控终止专用模拟器里的 App；第二次重启从真实 Keychain 使用原证明重放，并完成新设备登录。原设备单独核对 **2|1|1|1|0|0**（账号设备数/原设备撤销/证明取消记录/事件/有效 access/有效 refresh）；没有重复事件。同期修复命令行证明将 DeviceID 误编码为字符串的问题，真实凭据准备脚本的签发、鉴权和取消通过。最终 **5 项原生 HTTPS、3 项 App UI、1 项独立后台入口**通过，全库 **19|9|0|0|9**、取消记录 **20|19|4**。见[证据](../verification-records.md#20260907-registration-process-interruption)。这是 simctl 受控进程终止，不等同于 SIGKILL/OS jetsam/真机锁屏；legacy 清理及其他检查点仍开放。47 项仍 **16 已验证、31 开放**。

最新补充（2026-09-07，B08 旧档案服务端仲裁）：[账号范围的持久取消](legacy-registration-arbitration-contract.md)已实现，PostgreSQL 更新为 **30**。取消与签发共用账号/注册锁，原子撤销已签发会话并拒绝同账号迟到签发；其他账号不受旧 ID 阻断。真实 PostgreSQL **26 项 / 1 套件（32.416 秒）**通过，覆盖新增四项隔离、回滚、并发和配额测试及七条历史迁移链；29→30 保留凭据、约束正反向门禁通过。HTTP 单元 **14 项 / 3 套件（0.011 秒）**、原生 HTTPS **5 项 / 2 套件（2.729 秒）**通过，数据库 **8|4|0|0|4**，注册取消记录 **9|8|2**。首次新增测试未清理 schema，导致后续测试初始化失败；修正成功/失败清理后全组通过，失败日志保留，早先回滚通过的过早进度说明已纠正。三个专用资源根目录已独立确认移除。见[证据](../verification-records.md#20260907-legacy-registration-arbitration)。尚未提供 legacy HTTP 入口或 ClientKit/App 清理接线，启用前必须停止旧签发进程；本批未新跑 App/UI/Gateway/headless/真机。47 项仍 **16 已验证、31 开放**，B08 不关闭。

最新补充（2026-09-07，B08 旧档案 HTTP）：[账号证明与受保护清理入口](legacy-registration-http-contract.md)已接入生产 Account 组装及地址限流。严格四字段、UUID、新旧设备不同及证明边界先于域调用；真实 HMAC 验证与 18 项接口测试 / 4 套件（0.012 秒）通过。真实 HTTPS 基线 5 项 / 2 套件（2.691 秒）通过，新增扩展使用真实密码因子验证 503 整体回滚、204 幂等、同一证明新设备签发、迟到签发 403、另一账号隔离 404 及容量 507/原操作 204；仅记录目标计数，不保存密码或令牌。扩展在基线统计后执行，另增 3 个设备、1 条撤销事件和 256 条账号范围取消记录（254 条为配额种子）。相邻 PostgreSQL 与七条历史迁移链共 26 项 / 1 套件（30.563 秒）通过，三个专用资源根目录已独立核实移除。首轮扩展把既有签发 403 错写为 401，修正预期后完整通过，失败日志保留。见[证据](../verification-records.md#20260907-legacy-registration-http)。ClientKit/App 的旧档案 CAS 与登录接线尚未完成，本批未新跑 App/UI/Gateway/headless/真机；schema 30、protocol 27、SQLite 173/5 不变，仍 **16 已验证、31 开放**。

最新补充（2026-09-07，B08 旧档案客户端恢复）：[ClientKit/App 登录接线](legacy-registration-client-recovery-contract.md)已实现，同一次账号因子先清理、完整本地确认后再签发。失败保留，完整注册尝试和旧档案 CAS 防止迟到确认；一个恢复专用位置解决 256 条旧档案满额时无法创建清理尝试的问题。最终 ClientKit 480 项报告 / 474 项实际 / 6 项在线跳过（76 套件，6.167 秒），签名 App 200 项报告 / 199 项实际 / 1 项在线跳过（21 套件，5.143 秒）通过。真实 HTTPS 5 项 / 2 套件（2.714 秒）、新增旧档案恢复 1 项 / 1 套件（1.556 秒）、App UI 2 项（64.579 秒）、后台入口 1 项（1.323 秒）通过。数据库 18|8|0|0|8，注册取消记录 19|18|2，无旧有效凭据残留或重复事件。三套件并行触发两个密码 worker 的 503，首次分组仍带入第三套件；最终拆为独立文件顺序运行，两轮失败留档。三个临时根目录和一个模拟器已独立核实移除。见[证据](../verification-records.md#20260907-legacy-registration-client)。真实 HTTPS 的 owner 重建使用内存持久适配器，真实 Keychain 单独验收；不替代实际 App legacy 跨进程、旧二进制升级或真机锁屏/系统后台验收。B08 仍实施中，全部47项保持 **16 已验证、31 开放**。

最新补充（2026-09-07，B08 实际 App 旧档案恢复）：[跨进程清理检查点](legacy-registration-app-process-contract.md)已通过。真实签发的旧设备/原操作以 format 1 写入隔离 Keychain，清理提交后代理不转发响应并受控终止 App；不带种子参数的重启从真实档案重放，新证明绑定新设备，登录后再次冷恢复仍保持新会话。目标数据库核对 **2|1|1|1|0|0|0|1**，旧设备只有一条取消记录和撤销事件，无有效 access/refresh；首次准备设备未签发且已持久取消。真实 HTTPS **5 项（2.717 秒）**、App UI **3 项（104.240 秒）**及后台入口 **1 项（1.289 秒）**通过，全库 **18|8|0|0|8**、注册取消记录 **20|18|3**。签名 App 全量 **201 项报告 / 200 项实际 / 1 项跳过**通过（22 套件，5.063 秒），新增测试验证夹具要求隔离域、拒绝覆盖、清理不影响未加测试域的 Keychain。专用数据库根与模拟器已独立核实移除。见[证据](../verification-records.md#20260907-legacy-app-process)。这验证受控 simctl 终止和明确构造的旧格式数据，不是旧二进制升级、SIGKILL/OS jetsam、掉电或真机锁屏验收；其他检查点、永久冲突与 GC 仍开放。全部47项保持 **16 已验证、31 开放**。

最新补充（2026-09-07，B01 服务端时钟）：[账号证明与 Gateway 时钟边界](../server-clock-integer-boundaries.md)已补检查；独立进程复现 NaN 转 Int64 fatal error 后，新增非有限值、有效期相加越界和不可用编码截止的拒绝。Hello 在状态变更前检查，心跳覆盖异步准入后再次失效并释放请求关联；凭据接口将时钟故障返回为空正文、不缓存的 503，修复前错误 401 的三条失败断言留档。最终服务端 **57 项 / 7 套件（6.387 秒）**、真实 HTTPS **5 项 / 2 套件（2.734 秒）**、App UI **2 项（64.268 秒）**、独立后台入口 **1 项（1.298 秒）**通过。数据库 **16|7|0|0|7**、注册取消记录 **17|16|2**，专用数据库根与模拟器已独立核实移除。见[证据](../verification-records.md#20260907-server-clock-boundaries)。这不是远端可控时间戳攻击的证明；其余恢复 DTO、计数和时间消费者继续审计，B01 仍实施中，全部47项保持 **16 已验证、31 开放**。

邀请申请的单库申请人配额已增加事务互斥并通过真实并发回归；跨 owner 全局 reservation 与终态释放仍开放，见[配额合同](../invitation-applicant-quota-contract.md)。

已补[签发取消与活动旧凭据替换](../credential-issuance-boundaries-contract.md)及[已收到结果的持久交接](../received-credential-recovery-contract.md)：返回前保存撤销能力，冷启动识别正常接管并恢复废弃结果，转交不重置已有任务。完全丢失签发响应及真机系统中断验收仍开放。

2026-09-07，B08 旧注册档案：新增[服务端取消仲裁](legacy-registration-arbitration-contract.md)，以重新验证的账号权限限定清理范围；账号/注册锁内持久取消、原子撤销并拒绝同账号迟到签发。每账号上限 256 条，29→30 保留既有凭据且不推断历史取消。启用前必须停止全部旧签发进程。HTTP、ClientKit 与 App 的 legacy 清理尚未接线，记录 GC 及完整系统生命周期验收仍开放。

2026-09-07，B08 已接通[旧注册清理 HTTP](legacy-registration-http-contract.md)：生产账号入口校验新设备绑定的短期账号证明，加入可信边缘和持久地址限流。18 项接口、26 项 PostgreSQL、5 项真实 HTTPS 基线与新增真实密码/清理扩展通过；ClientKit/App 旧档案恢复仍待接线。

2026-09-07，B08 [客户端旧档案恢复](legacy-registration-client-recovery-contract.md)已加入 App 登录：复用一次账号因子完成旧注册清理及新凭据签发。原注册尝试和完整档案 CAS 防止迟到确认覆盖，错误与容量反馈保留记录；最多一个额外位置供满额旧档案恢复。真实 Keychain 与 ClientKit/HTTPS 分层验收通过，实际 App legacy 交互/进程中断与真机边界仍开放。

2026-09-07，B08 [实际 App 旧档案跨进程恢复](legacy-registration-app-process-contract.md)已通过：真实 Keychain、清理响应前受控终止、新证明重放、新登录及再次冷恢复，服务端目标无有效凭据残留或重复事件。DEBUG 种子及清理只作用于隔离测试域，拒绝覆盖已有档案。真机、其他检查点和永久冲突/GC 仍开放。

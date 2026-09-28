# 应用级弱网实施状态

本文件跟踪[目标设计](application-weak-network-design.md)与[验收计划](application-weak-network-implementation-plan.md)的当前差距。完整目标仍为 W0–W6；基础组件通过不代表全 App 已完成。

用户已将 F18 本地单机连接验收目标调整为 **1000 条真实连接**；2k 非空积压及原身份、TTL、游标追赶要求不变。此前万级运行保留为历史诊断，不再是当前验收门槛。最新万级轮在17名注册及双刷新通过后按用户变更主动 SIGINT 停止（exit130），私有服务、PostgreSQL 与临时凭据目录均已清理；不能把它记为容量失败或1000条连接通过，也不能复用已清理的凭据。

当前1000连接本地非空恢复轮73969已真实exit0，输出 `/tmp/weak-network-nonempty-recovery-1000-bounded-confirmation`。1000名真实账号注册、早期17名连续双刷新及全量刷新通过；warmup中1000条TLS均认证、峰值在线1000，1000个direct room及tail游标准备完成，workloadFailed为0。有界HTTP控制最多32个实际请求，1000个direct提交均HTTP200，HTTPS代理TLS失败摘要为空。断线后1000个唯一订阅房间各注入1条真实typed消息，1000条原订阅全部满足 `before < injectedThrough <= recoveryTarget <= applied` 且gap0；恢复1000次连接尝试全部认证、失败0、连接尝试放大系数1，最后一次启动偏移16.949毫秒。房间事件拉取1929次，其中可重试拒绝929次，不能称没有业务重试。恢复阶段110.306秒exit0，隔离服务、PostgreSQL和临时凭据均清理。此轮证明本地1000连接及1000房间非空追赶；不单独证明2k积压全矩阵、App持久工作、真机或外部部署，也不将scope中的 `fullF18Passed:false` 改称完整F18通过。

## 当前交付状态

当前源码为 protocol44/current63。Core 的32个持久 kind 对应 App 的30个公共 handler 与2个资源专属引擎；旧 App 命令 lane 和旧消息写 wire 已退役。当前交付包括原身份永久回执、账号关闭围栏、已读归档控制预留、资源恢复和后台桥接。源码接线不等于全 App 验收完成。

W6 本批移除了未注册、无生产调用方的全局 `POST /v2/message-operations/recover` 路由及对应客户端策略登记；当前发送恢复仍走按房间限定的 `POST /v2/rooms/{roomID}/message-operations/recover`。这项删除仅完成源码与引用核对，以上既有回归日志早于此次修改，不构成删除后的构建或运行证据。

typed消息通知缺陷已修复；resource-live-final7实际收到直聊及大群hint、作者资料补充，并完成头像字节访问和权限拒绝检查。该轮后段被撤回夹具错误的24小时期限阻断；按现行10分钟合同修正后，resource-live-final8整链通过（3.296秒）。资源暂存诊断已有准入扫描与日志接线，本批已修正未观察峰值被表示为0、累计计数未输出及提前超额扫描的口径。完整目标保留 W0–W6 及 F01–F20，不以本地参考 provider 或组件测试替代平台、供应商和容量证据。

| 最近证据 | 当前结论与边界 |
| --- | --- |
| Server 合并轮73854及收尾10880 | 合并轮剩余5函数已在8项收尾复验中通过；保留原 skip。此后通知装配修改不在该证据范围内 |
| App336项、增量135项；Client受影响32项及签名恢复4场景 | 已运行范围通过；不覆盖此后新增生产修改、真机后台或外部存储 |
| resource-live-final8，exit0 | 整条本地HTTPS/独立Actor/TLS资源场景通过：头像/附件、直聊/大群作者、撤回与屏蔽撤权、昵称修订、精确发现和入群审核权限。3.296秒，自有PG正常关闭；不是外部provider证明 |
| 暂存受影响合并回归84779，exit0 | 10项/1suite，1.241秒；未知根拒绝、重叠根两注册顺序、并发预算及既有后台接管/排空通过 |
| 账号HTTPS/Gateway/App组合26270，exit0 | Client5项、App3项、headless Push1项通过；两次响应丢失真实终止恢复，远程撤销原回执与重启状态；另1项未启用消息后台场景skip。仅模拟器，不替代真机后台 |
| 本地1000连接非空恢复73969，exit0 | 1000认证与峰值在线、1000唯一房间离线写入及逐游标gap0；连接尝试放大系数1，房间事件拉取仍有929次可重试拒绝。私有资源清理；不覆盖2k积压完整矩阵 |

对应日志：`/tmp/weak-network-final-precision-regression.log`、`/tmp/weak-network-protocol44-resource-live-final8/client.log`、`/tmp/weak-network-staging-budget-regression.log`。其他具体范围与证据见[统一回归范围](application-weak-network-regression-scope.md)。

## 当前执行节奏（用户最新要求）

按用户再次明确的要求，当前按批次完成业务实现与必要静态核对，不逐项启动构建、测试或扩展夹具。上一批已通过范围保留为其对应版本证据，不覆盖下面的新改动；待实现批次结束后统一回归。本地1000连接非空恢复已取得上述证据；2k积压完整矩阵、外部provider/CDN和真机系统行为仍需各自环境证据。

本批继续完成待处理发送的业务可访问性：移除最旧64条列表对操作入口的限制，活跃发送优先展示，已释放容量的终态历史可分页；展示与观察选择一致。重试/取消按指定intent ID读取阶段，避免跨房间积压导致误判。输入区下方增加有高度上限的独立滚动列表及消息文字预览，删除忽略页号的旧接口桥接。仅做源码审阅与差异格式核对，未运行构建或测试；第65条以后的重试/取消、超过200条终态翻页及投影收敛后的页更新留待统一回归。

## 本批源码收口与受影响回归

待处理发送分页与刷新脚本修复整批收口后，集中验证已结束：App生产编译79784通过；Client98762一个分页函数通过0.953秒；App28444一个参数化函数的retry/cancel两场景通过0.180秒。离线刷新脚本91780虽一个测试通过3.138秒，但替身错造对象凭证，不证明当前字符串wire；修正后80551一个测试3.154秒exit0，覆盖规范字符串及harness解析。首次App22654筛选未命中函数，实际0测试，保留原记录且不计通过；补漏复用编译结果。模拟器已处于Shutdown。上述是本批有限范围证据，未重跑旧套件及10k真实容量；完整日志和未覆盖交错见统一回归范围。

- `V2CommittedHybridGroupEventObserver` 现对新接受消息先构造原有 direct 草稿，保留精确两人受众，再尝试原 large-group 草稿。单次遍历后沿既有排序、缓存、bounded sink与作者补充链路发布；不能物化完整事件的消息仅发布原水位提示。外层事务提交后才观察的边界保持不变，幂等回放不重复发布。客户端订阅确认、持续读帧、解码和早到事件缓存未发现需要修改的入口。
- `V2ResourceStagingBudget` 的观测峰值与准入预留峰值在尚未观测时为nil；超额早停仅更新已观察下界，完整总量保持未知。现有日志输出累计峰值与饱和拒绝计数，不增加扫描。预算加权值仍不等于实际磁盘峰值。
- 暂存准入不再把目录枚举失败、未知文件大小或无法确认的根目录当成零占用。新增独立usageUnavailable拒绝口径；中途枚举失败也停止准入，最后完整观测清为未知而不抹去已观察峰值。同路径跨普通/后台根重叠按最大权重计额，避免遍历顺序漏掉系统副本预留；每次扫描最多65536项，超限保持未知且拒绝增长。直接调用方均先创建根目录或使用已有源目录，不新增周期扫描。
- 消息send/mutation/reaction HTTP响应保留CancellationError；RoomRef入口把明确notAccepted(cancelled)还原为取消，其他不确定结果仍保持原分类。表态GET仅对明确领域不可见返回403，损坏状态/基础设施故障返回503，非法reaction返回400，避免临时故障冒充撤权。
- 当前HTTP清单按源码重新登记93条直接routes声明，修正roomID及行号；这不是运行时注册数量证明。账号只读升级、显式resume与头像lease的有限静态核对未发现新增缺口。
- Range重复前缀已有同版本与最终完整性证据约束，本批未扩展为上传重复字节估算。真实系统副本、外部provider和容量证据仍缺。

上述源码收口阶段仅做静态核对；之后的合并回归结果见当前证据表。消息错误分类仅在既有两个suite补最少边界断言。67522真实通过4项/2suite、0.018秒；原filter误写了两个不存在的独立send/mutation suite名，已用实际V2VaporMessageOperationRoutesTests在74696以skip-build补齐1项/1suite、0.009秒，不重跑前两suite。日志为 `/tmp/weak-network-message-route-classification-tests.log` 与 `/tmp/weak-network-message-operation-routes-tests.log`。本批通过不等于完整F01–F20或平台部署验收。

## 账号故障联调（本批通过）

仅推进此前未验收的账号HTTPS/Gateway/模拟器组合，不重复已通过资源链路。启动前核对Client两suite及App的撤销、中断注册、headless三入口；修正Client旧401/TLS错误类型期望，远程撤销保留原baseline、ID、期限并核验query等值回执。

首轮3054已exit1，输出 `/tmp/weak-network-protocol44-account-live-final`。生产构建完成，但脚本没有提供现行必需的Actor配置，Account在composition阶段退出，尚未执行客户端/App场景。自有PG及所属进程已清理。Actor装配已补齐：Account、Gateway及可选secondary拥有独立身份与匹配peer。续跑79609因脚本漏导入sys退出，已补；52332已证明Account启动，但Gateway拒绝未展开的Compose布尔占位符。现已统一解析checked-in非secret默认值并静态核对数字/布尔字段，不读开发.env；三轮自有资源均已清理。52936已exit1并实际执行5项Client场景：4项通过，凭据获取阶段401的夹具错误期望已修为unauthenticated，凭据清除与会话结束断言保留。随后9673（`/tmp/weak-network-protocol44-account-live-final5`）Client5项/2suite真实通过2.726秒，Account/Gateway正常；App E2E整个target仍引用已退役TCP写方法和旧outbox，导致编译失败，尚无App运行结论。该轮私有服务、PG与模拟器已清理。整个target已按LocalAccount、membership/directory、scale/slowTLS三组完成迁移；发送使用真实SQLite公共work，原身份/期限单次冻结并比较本地与服务器原回执，轮换场景注入原认证会话。未恢复旧接口。93955续验仅报新helper把await放入XCTUnwrap，已拆分；73131已完成Swift编译但E2E目标未直接链接GRDB，已补目标依赖（锁定版本仍7.10.0）。43384单独build-for-testing真实exit0，日志 `/tmp/weak-network-account-e2e-fixture-build.log`，完整E2E目标编译/链接通过。26270已真实exit0，输出 `/tmp/weak-network-protocol44-account-live-final8`：Client5项通过，App3项通过（两次响应中断后的冷启动取消、Gateway撤销、HTTP远程撤销；均含重启状态），headless Push1项通过。App类内另一个未启用的pending-message后台场景skip1，未计通过。脚本记录issueTerminations=1、cancelTerminations=1并完成数据库/HTTP证明检查。PG日志确认shutdown，专属模拟器已不在simctl列表，私有证书/密钥和临时目录已清理。规模/慢TLS夹具本批只编译，不计行为通过。

## 恢复公平与页面状态收口（新增，待统一回归）

本批未运行构建或测试，仅做源码交叉复核和差异空白检查。此前绿色结果不覆盖本节。

- 公共 dispatcher 原来只按最早时间领取空闲槽数量的候选，大量旧恢复可能挡住新操作。现在分别查询最近60秒内尚未首尝试的工作与其余恢复工作，跨唤醒按3:1选择，两条SQL合计最多32项；orderingKey前驱与依赖仍在SQL中约束。该窗口只是有限的新操作优先，不把历史未发送积压或显式resume冒称用户P0。
- 最大并发大于1时，恢复步骤最多占N-1个domain槽，为新首尝试保留1槽；默认纯恢复并发由6变为5，付出1/N吞吐代价以保证黑洞恢复期间新交互仍有派发机会。单槽配置仍允许恢复执行。网络叶子的物理许可和排空不变，不抢占在途I/O。恢复槽已满时只按交互候选安排计时，避免旧due工作形成轮询。
- 移除公共work观察中仅按MIN(next_action_at)去重：最早积压时间不变时，新插入工作仍须唤醒派发。观察流继续bufferNewest(1)，不增全队列任务或独立轮询。
- 隐私设置拆开已确认值、带revision的权威快照和待处理限制。每次草稿/操作变化从已确认事实重算；取消草稿或确定拒绝后，不在旧显示值上保留已经结束的限制。成功操作使用同事务写入的原回执缓存，不用旧command覆盖后来设备产生的新revision；本地刷新在等待网络前读取当前投影/缓存revision。已读设置异步提交后补取消检查，避免取消页面的迟到显示更新。
- 共享RoomRef administration caller仅把明确notAccepted(cancelled)还原为CancellationError，结果未知保持原语义；账号偏好、social、membership、邀请、建群、成员管理、群能力、moderation的typed操作响应不再把取消伪装503。原身份证明、权限和过载合同保持不变。

以上为生产实现收口，不证明完整F18/F20已通过。网络共享重试桶、服务冷却、认证single-flight和字节许可排空本次有限复核未发现新增缺口，未重复改造或运行既有测试。

## 失败处置与草稿恢复收口（新增，待统一回归）

本批继续只做业务实现和源码复核，未构建、未运行测试。

- 消息永久拒绝原先没有丢弃/重新发送入口。现沿原消息journal处理：远端closed/rejected必须有匹配原identity/fingerprint的不可变负回执；重新发送使用新intent/client/resource身份并保留旧work/proof，丢弃后由既有依赖与暂存释放谓词清理。本地expiredUnsubmitted只有同时finished且submissionStarted=false才可使用本地未提交证明处置，不伪造远端回执；unknown不能借普通失败码获得重新发送或释放资格。API更名为replaceProvenUnsentSendIntent/abandonProvenUnsentSendIntent，调用及既有测试引用同步，不保留旧wrapper；这里是原内容重新发送，不是新增消息编辑器。取消失败页面保留原消息/附件，不再声称已请求取消。
- 个人资料入队成功后将头像预览转给已持久化草稿引用；显式丢弃后清除已释放的路径与处置状态，文字编辑保留。重新应用使用refreshProfile落盘后回读的最高已确认revision，避免迟到副本响应冻结旧基线；取消后不新建替代意图。
- 名称编辑器只恢复尚待处置的草稿，不再把committed旧command重新填入输入框。恢复中的原操作成功后解除restored文本保护，读取当前缓存；用户实际键入的内容仍保留。补齐读取完成后的取消检查。
- 邀请无command且已frozen的公共work表示原身份只恢复/关闭。现在该明确状态可在原窗口内领取reconcile claim，不再因尚未开始普通submit而一直拒绝领取；执行closeIfAbsent，已有原回执仍优先。使用既有持久状态，不改schema/原fingerprint/期限。正常已冻结command的未知操作仍按原query与到期关闭规则恢复。
- 成员管理与群能力观察到新rejected/conflicted终态时，将旧成员编辑基线标记stale；群能力同时清掉待确认提案。保留展示与原proof，要求刷新后再确认新操作。

本节不替代后续统一故障回归、真实平台/供应商或容量验收。

## 建群恢复与设备会话显示（新增，待统一回归）

- 公共claim的到期原身份恢复范围补入groupRoom。建群流程已可能拥有服务器阶段事实，未开始本次submit的过期work不再先被本地expiredUnsubmitted截断，而是交给现有GroupCreationService查询/closeIfAbsent取得原proof；已finalizing仍由服务端阶段/created回执裁决。
- 设备列表读取及分页遇到明确unauthenticated/sessionInvalidated时，清除旧列表、管理基线与分页资格，沿既有授权拒绝路径展示恢复提示。暂时credentialsUnavailable与网络故障不被当作退出证明。读取撤销baseline的取消单独退出，不显示普通失败反馈。
- 资源借用/取消/快照保留和转发/表态原身份恢复的有限源码核对未发现新增确定缺口，不重复改造。

- 消息管理移除现已补齐AppStore依赖注入、会话菜单、权威baseline读取、明确确认入队、本地pending观察和needsAttention继续原work入口。展示资格读取非stale成员目录与ready角色权限配置，使用moderateMessages而非管理员角色硬编码；服务端仍最终重验。基线响应绑定请求room/message，确认从读取前限定120秒，enqueue沿原绝对截止；准备/保存单飞与已消费proposal防重复确认，离页/到期清proposal且不取消已保存work。原pending立即读SQLite，权限读取由独立页面task持有，避免离线时挡住恢复状态。理由采用中性moderation_removal，动作是管理移除而非举报。

本批未构建、未运行测试。相关变更只有源码接线和差异空白检查证据；完整功能与故障行为待统一回归。

## 当前业务批次合并生产编译（通过，行为回归仍待执行）

2026-09-28集中完成上述恢复公平、隐私/草稿状态、失败处置、邀请/建群关闭和消息管理移除接线后，仅执行一次生产组合编译：

- App句柄12122真实exit0，generic iOS Simulator、Debug、CODE_SIGNING_ALLOWED=NO，日志`/tmp/weak-network-business-closure-app-build.log`明确BUILD SUCCEEDED，包含当前ClientKit生产依赖。
- Server句柄14863真实exit0，XcodeDefault swift build --package-path IMV2Server --jobs 4，全部生产products完成，14.86秒；日志`/tmp/weak-network-business-closure-server-build.log`。

没有编译错误，无需修改或重编；未构建测试target、未运行测试。上文“待统一回归”仍成立，编译不能证明新业务故障行为通过。

当前证据缺口按原范围保留：F01–F14既有组件/部分本地联调不足以覆盖本批所有新增交错；F15–F17本地参考provider整链不能替代真实供应商和跨故障域迁移；F18仍缺10k真实连接非空积压及客户端2k工作公平的完整容量证据；F19仍需慢资源故障时HTTP/TCP共同推进；F20模拟器与组件不能替代真机系统挂起、锁屏、强退、重启和晚完成。下一轮行为验证合并已登记的受影响范围，不重复未受影响的全套。

## 当前业务批次统一行为回归（205项及3项补查已通过）

在前三批业务集中实现且生产组合编译通过后，按用户要求统一选择受影响范围，不逐项运行、不重跑未受影响全套。

- ClientKit由工作调度代理持有46445，独立native scratch、no-parallel；6个实际suite：V2OperationBacklogTests、V2OperationWorkTests、V2ProfileIntentTests、V2MessageSendWorkTests、V2GroupCreationOperationTests、V2HTTPGroupInvitationClientTests。日志`/tmp/weak-network-business-closure-client-regression.log`。新增真实SQLite 1999旧工作占恢复槽后插入第2000个新工作，检查MIN不变时仍唤醒并可提交。HTTP邀请adapter不等于service只恢复关闭验证；发送过期状态不等于处置入口验证，后续结果单列边界。
- App由HTTP代理持有77841，只选6个现有suite：V2ConversationStoreTests、V2NameEditorStoreTests、V2PublicIdentitySettingsStoreTests、V2DeviceSessionsStoreTests、V2OperationConversationSenderTests、V2OperationMessageSenderTests。日志`/tmp/weak-network-business-closure-app-regression.log`。仅补一个消息管理移除的本地观察、离页确认围栏关键场景，未跑全App。
- Server首轮28517已exit1，唯一阻断为新增夹具误用了旧Vapor middleware类型；已按现行接口修复，由Core持有44984继续相同两个suite：V2RoomRefClientsTests、V2VaporPersonalPreferenceRecoveryRoutesTests。日志`/tmp/weak-network-business-closure-server-regression-confirmation.log`。验证caller取消/unknown区别与两个真实baseline路由取消透传；其他具体数据库路由不能借本轮冒称直接行为覆盖。未启用PG或扩到消息此前已通过范围。

以上启动句柄均已终态：

- Client46445真实exit0，45项/6suite，9.921秒。新增1999旧黑洞恢复加第2000个交互通过1.451秒，另2000工作滚动排空通过6.195秒。没有失败，未重复已通过范围。这是客户端真实SQLite调度证据，不是10k网络容量证明。
- Server44984真实exit0，11项/2suite，0.019秒，0issue/0skip。原caller取消与unknown区别、两条真实baseline路由取消透传通过；不扩充为其他数据库路由行为证据。
- App首轮77841真实exit65，仅新增测试构造参数顺序编译错误，未执行测试；修复夹具后同6suite57981真实exit0，149项/6suite，4.322秒。新增消息管理移除本地优先/离页双确认围栏/原work保留场景0.031秒通过。日志主路径不变，首轮日志单独保留app-regression-compile-failure.log；没有生产修复或全套回跑。

合计205项已通过。三处直接断言补查73460也已真实exit0，3函数/3suite、0.124秒，发送函数3参数均通过：邀请recovery-only在原窗口内取得claim并发送closeIfAbsent，原身份closed；有效负回执/本地从未提交过期可新身份替换与丢弃，started unknown两API拒绝且原command保留；资料迟到revision2响应不能使新意图低于已持久revision5。日志`/tmp/weak-network-business-closure-client-gap-confirmation.log`。仅新增函数运行，不重复此前205项，没有生产错误或新增修复。App新对话框真实UI交互及全权限/时钟组合未由该单个场景证明；平台、供应商与完整容量边界仍保留。

## 容量与真机环境准备（进行中）

已有205项加3项补查不重复运行。Gateway burst driver已接入全部旧连接关闭后的typed HTTP积压写入；专用隔离脚本逐原连接核对原回执、非空cursor差距与实际追赶。首次2连接命令92308已exit1：driver排序表达式触发编译器类型检查超时，日志 `/tmp/weak-network-nonempty-recovery-small2/build.log`；未启动私有PG、服务或负载，不计容量通过。已拆为显式类型与简单比较分支；按用户最新要求，本轮只做实现与静态核对，没有立即复编或重跑，后续统一回归。

本机资源只读检查：FD软限1048575、硬限unlimited，物理内存48GiB、14核；这些仅说明运行资源，不是10k能力证明。devicectl实际列出当前paired/available的iPhone 17 Pro Max和iPad Air 5。现有native联调脚本仍通过simctl创建模拟器与信任临时CA，不能直接作为物理F20入口。真机需要用户选定专用设备、可访问的HTTPS/provider地址与信任/签名配置以及锁屏/重启操作窗口；本次没有安装、启动、重启或改变任何物理设备。外部存储/CDN尚未由用户指定。

容量脚本静态收口了外层超时短于完整阶段、凭据有效期要求短于阶段预算的确定问题：按连接数统一计算两段启动节奏、预热、离线写入、恢复观察、排空与清理预算，10k的预热/burst为525/655秒，最早凭据剩余寿命须575/705秒；不延长服务端token TTL，刷新后不足则拒绝开始。失败保存不含凭据的阶段摘要，并清理本次独立进程组，覆盖父进程先退出而子进程仍存活的情况。本轮未运行脚本、构建或测试。

本轮另外限定核对账号关闭到后台字节排空的生产调用链：后台对账先于业务活动启动，关闭捕获旧账号实例，资源活动及实际系统传输排空后释放许可；未发现需要修改的确定缺口。仅是源码核对，没有运行F19慢资源组合或F20真机场景。

## 发送受理与本地展示收敛（新增，待统一回归）

修复公共发送意图（文本和附件）在HTTP accepted后立即从待发送行消失、而真实消息同步尚未到达时页面缺少内容的问题。现在显示“服务器已受理，等待消息同步”，不提供重发或取消；accepted仍只证明服务器受理，不冒充送达或审核通过。

原永久回执与其messageID/roomSequence派生索引同事务保存。展示收敛采用单向持久标记：真实live投影以messageID、roomID、roomSequence匹配，合法墓碑以messageID、roomID匹配；投影先到时安装回执反查。标记在投影/墓碑写事务中更新，不依赖打开页面，后续缓存裁剪不会重新生成旧等待行。显式房间失权只抑制展示，不把缺失投影或旧授权记录当作已物化证明。

Snapshot准备阶段针对已校验shadow计算原操作的候选证据，ACK激活事务按snapshotID索引将候选转为已收敛；准备之后、ACK之前安装的回执同事务补对应候选。未激活shadow不提前结束等待；激活后到达的回执反查live投影。序列转换超出本地整数范围抛错并回滚，不进行有损转换。

待展示行在SQL筛选后再使用现有LIMIT，不被历史committed记录挤占。未收敛消息仍占既有每房间200条及公共2000条/32MiB原载荷预算；仅保留存储额度，不重开已完成工作或占执行槽。收敛释放额度并唤醒已读准备观察。7天历史清理新增已展示收敛条件，避免等待中的原消息被自动删掉。

本批仅修改最新建库定义、生产逻辑及文档，不保留历史schema兼容路径；没有构建、测试或启动服务。schema实际对象数/指纹及上述交错留待统一回归，此前207对象及旧hash不作为本批新schema通过证据。

## 本批集中验证（受影响范围已通过）

实现收口后只选择新增发送展示/额度/快照交错、App生产编译及容量专用入口，不重复此前205项及3项补查。

- App生产编译32929已真实exit0，日志 `/tmp/weak-network-send-projection-app-build.log` 第1575行 `BUILD SUCCEEDED`。无编译错误，未运行App测试。
- 2连接隔离容量入口52165已真实exit0，输出 `/tmp/weak-network-nonempty-recovery-small2-confirmation`。断线后1唯一房间注入1条真实typed消息，原回执sequence1；两原订阅均before0 < injected1 = target1 = applied1，gap0，恢复尝试2、放大系数1。注册1.061秒、预热22.903秒、恢复96.208秒均exit0无超时，整体私有服务/PG清理已完成。仅本地smallN2，不证明10k、App完整故障矩阵或生产部署。
- Client新增仅一个参数化函数 `acceptedPresentationConvergesWithoutResurrection`。34232因测试参数label误写而编译失败，修复后46627运行：receiptFirst、projectionFirst、preparedSnapshot三种真实SQLite交错全部通过（0.384秒），覆盖等待行、禁止替代/丢弃、存储额度和retention、snapshot准备后回执及ACK、无页面读取的持久收敛、trim后不复活。没有生产错误。该轮仍因schema旧期望失败：实测209对象、hash `0xd64604e42567c696`。已仅据实际结果更新schema期望，85348单独复验schema已真实exit0，2项/1suite通过0.080秒，不重复三种已通过交错。日志 `/tmp/weak-network-accepted-projection-client-regression.log`、`/tmp/weak-network-accepted-projection-client-regression2.log` 及 `/tmp/weak-network-accepted-projection-client-schema-confirmation.log`。

## 10k容量尝试与慢资源入口补齐（进行中）

10k隔离命令39469已真实exit1，日志 `/tmp/weak-network-nonempty-recovery-10000.log`。生产构建和私有服务启动完成，但registration-0仅0.142秒以exit4退出，HTTP汇总记录注册503共10次；未进入Gateway连接或离线恢复，因此不计容量结果。自有服务与PG已清理。

已确认准备脚本默认16并发与生产 `V2PasswordHashService.maximumConcurrent=2` 不匹配，注册路由对哈希busy明确返回503。现仅在专用recovery的注册子进程环境设置准备并发2，manifest记录该值及生产哈希上限；不改变正式服务、通用脚本默认、凭据TTL或10000恢复目标。原私有注册日志已随清理删除，503统计和源码限制可证实错配，不将其扩大为所有503原因的证明。后续2564结果见下文。

F19现有资源联调先完成上传再验证消息，不能证明慢字节传输期间控制独立推进。已补 `verify_v2_live_resource_authors.py --slow-resource` 与单个 `slowResourceUploadKeepsControlAndCursorProgress` 场景：256KiB真实上传读取首16KiB后有界暂停，上传账号的HTTP执行器、资源executor和TLS连接共用普通1槽/字节1槽scheduler；gate仍waiting时核验typed send原回执/query和该账号自己的hint/pull及SQLite投影，随后释放、等待上传与finalize。gate有45秒上界、聚合字节/完成证据和失败排空；脚本清理本次独占进程组，覆盖leader先退出仍有子进程的情况。源码已收口，未构建或运行该场景，不能记F19通过。F20真机清单已补入现有资源provider合同，仍须用户指定设备及可达环境，未操作物理设备。

## 慢资源集中联调通过与10k续验

F19本地真实慢上传场景92151已实际exit0，输出 `/tmp/weak-network-slow-resource-control`。仅运行新场景1项/1suite，1.408秒通过：同上传账号共享普通1槽/字节1槽scheduler，gate仍waiting期间HTTP typed send原receipt/query等值、自己的TCP hint/pull及SQLite消息投影推进；释放后原上传/finalize完成。gate实际读取262144字节、hits1/completed1、expired0/active0，最后scheduler许可归零。私有Account/Gateway/Actor/PG已清理。只证明本地参考provider的慢字节阻塞隔离，不扩充为外部供应商或真机后台结论，不重跑此场景。

10k修复复验2564已实际exit1，输出 `/tmp/weak-network-nonempty-recovery-10000-confirmation`。专用注册并发2后，两批各5000账号及设备凭证均成功（1556.28秒、1559.63秒，均低于各自1800秒截止），但随后的刷新阶段0.05秒exit22：HTTP汇总刷新400共9次。刷新准备脚本遗漏现行必填的 `revocationCredential`，未进入Gateway warmup或离线恢复，因此10000容量仍无通过证据。私有服务与PG已清理。现已在刷新请求加入该凭证，并在刷新输出保留新的撤销凭证及到期字段，不恢复旧协议或放宽正式服务。后续77711两批各5000注册也均exit0，却在刷新前因harness错误要求撤销凭证为对象而实际exit1；私有资源已清理，仍未进入warmup/burst。91780的对象形状离线夹具不能证明现行合同；harness改为校验Core单值字符串后，80551规范字符串离线回归通过，但尚未重跑真实10k容量。为避免再花两批注册时间才发现wire错误，专用容量harness现先注册最多17名真实账号（min(count,16+1)）、以固定刷新并发16连续两次用轮换凭据跨批刷新，成功后才按原每批最多5000/注册并发2/1800秒注册余量；17名计入原10000，总量、TTL、最终全量期限校验和真实刷新均保留。39889历史轮仍只用2名早期哨兵，不被新策略追认。新流程10000轮39889已实际exit1（`/tmp/weak-network-nonempty-recovery-10000-wire-confirmation`）：前2名真实注册及连续两次刷新均exit0，后续两批余量注册exit0（1560.41秒、1561.34秒），总计10000；refresh-full仅0.086秒exit1，公开HTTP汇总仅17次刷新200、无拒绝状态，未进入warmup/burst；私有资源已清理。原始私有刷新日志随清理删除，不能确定本次具体后台失败原因。随后离线脚本合并回归 `/tmp/weak-network-refresh-drain-contract-regression.log` 已实际exit0：2项/3.448秒，含原单记录连续轮换及17条跨默认16并发边界；1条HTTP200坏body与同批迟到正常请求验证全部已启动请求排空、第17条未发送、安全stderr不含坏响应正文。随后仅补跑该新增函数 `/tmp/weak-network-refresh-batch-boundary-regression.log`，1项/3.728秒exit0：先17条全部成功并校验输出原身份顺序跨16批边界，再用同一替身验证坏body排空与第17条不发送。仅脚本替身，无真实网络或10k复验。已修脚本等待首次失败即提前清理后台任务、命令替换可能掩盖解析失败的确定缺陷，并让harness保存不含凭据的阶段/HTTP状态/curl退出码/解析类别聚合，尚未重跑。

10k最新隔离轮2745已实际exit1，输出 `/tmp/weak-network-nonempty-recovery-10000-batch-confirmation`。早期17名真实账号注册exit0（5.523秒），首次16并发刷新仅0.087秒exit1；公开汇总有13次刷新HTTP200，另有curl SSL连接错误35×2、连接失败7×1（均HTTP000）。未注册余下9983名，也未进入warmup/burst；私有服务与PG已清理。bundled Python 3.12.14 的 `SSLSocket.accept()` 使用默认同步握手，而原隔离HTTPS代理将监听socket整体包装、默认队列仅5，握手发生在 `ThreadingHTTPServer` 派生工作线程之前。现已改为原始accept后有界worker握手、10秒握手期限、128监听队列及无凭据的SSL原因汇总；源码静态核对通过，尚未重跑，不能据此宣称10k容量通过。

## 历史实施记录

以下按原检查点保留，文中的“正在执行”“尚未复验”只描述当时状态；当前状态以上表及统一回归范围为准，不从历史启动记录推断进程仍存活。

### 当前批量修复（confirmation8 之后，尚未复验）

84211 已实际终态 exit1：Server 953 项/202 suites，另 Contracts 1 项，共954项；188 issues 涉及60个失败函数。日志 `/tmp/weak-network-protocol44-server-regression-confirmation8.log`，聚合索引 `/tmp/weak-network-protocol44-server-confirmation8-failures.txt`。五座自有临时库已清理，专属PG保留。按用户最新要求，本轮之后没有追加测试或构建；以下源码改动等待本批集中完成后统一验证。

- 设备撤销：原永久回执优先，首次执行前验证实际数据库时间可表示性；直聊路由争用改为非阻塞获取事务锁，释放连接后在同一总期限内等待，继续审查正式池隔离。
- 邀请创建：比较创建请求与所有者回执的原始数据库时间戳绑定，移除浮点 Date 相减必须精确等于整数寿命的错误判断，保留原期限与不可变绑定。
- 成员控制夹具：恢复查询和回执校验使用包含 admission 的冻结命令指纹。
- 主数据库夹具：媒体正例登记真实 catalog/placement；转发期限场景先复制实际字节、持久化输出再验证租约边界；大群创建使用满足现行规则的5001名实际成员，继续覆盖大群提及与容量投影。
- 配置与合法设备握手已集中更新；资料头像改走真实展示租约/下载计划并保留双向屏蔽断言，投影领取使用实际持久 next_attempt_at 且保留原计数。两个Host取消/drain场景已迁到typed scalar真实SQL门；生产typed send已补foregroundWrite许可，内部granted batch不重复取得许可。正式Account/Gateway装配的路由与authority池已经隔离，静态核对无需增池。此前未受影响且已通过的App/Client范围不重跑。

### 批量修复收口与旧媒体入口清理

本批源码集中完成后，由Core启动唯一统一回归73854，日志 `/tmp/weak-network-protocol44-business-batch-regression.log`。按当前discovery去重选127函数（失败60及本批真实生产变更相关场景），索引 `/tmp/weak-network-protocol44-business-batch-ids.txt`。本轮编译102.24秒通过，已进入真实测试执行；127为选择数而非最终执行数，尚无整轮终态。不重复未变化的App/Client范围。

- Direct HTTP路由保留CancellationError，不转为503；router固定总deadline及正式独立authority池接线已核对。
- 删除无调用方的 `V2LocalFilesystemForwardMediaCopier`；保留在 `ForwardMediaFileIO.swift` 中被当前上传和资源存储使用的digest/fsync辅助。移除仅旧复制器使用的copy实现与provider旧forward专用verify/commit入口。purge并发/崩溃恢复场景迁到实际上传commit，保留kill checkpoint及不可复活断言。
- W1/W3正式公共work调用链静态核对未发现旧outbox构造、lane或自有重连扫描仍被装配；此为源码核对，不能代替最终故障验收。

### 合并批次73854终态与三项收尾

73854实际exit1：127项/23 suites，20issues仅在主Integration的5函数；配置、握手、设备时间边界、成员控制及两个typed Host场景本轮无issue。日志 `/tmp/weak-network-protocol44-business-batch-regression.log`，失败索引 `/tmp/weak-network-protocol44-business-batch-failures.txt`。三个skip（crash child辅助入口、显式环境HTTP上传场景、额外围栏场景）保持单列，未计通过。五库已清理。

剩余三项根因已合并修复：大群夹具handle符合32位小写约束；邀请将冻结整数毫秒直接编码为PG原生微秒，并在owner原生绑定完全匹配后发布原整数回执，避免Date往返改变期限，不放宽Core寿命合同；已绑定消息资源的转发按当前合同不受最初上传期限影响，夹具保留原ID单效果及其余lease精度断言。下一轮仅收集这5函数及必要时间边界，不重复本轮已通过且未受影响的范围。当前收尾改动尚未验证。

### 本批受影响回归完成，转入本机资源联调

10880真实exit0，编译39.49秒，8项/2 suites、87.032秒，0issues/0skip。5个剩余失败函数全部通过：大群提及与容量、邀请时间一致性30场景、邀请创建18场景、转发期限42场景；另有3个原生时间戳函数。日志 `/tmp/weak-network-final-precision-regression.log`。五座临时库已清理，本批Server已知失败均获得修复后证据；未重复App/Client已通过的组件范围。

父启动此前未执行的本机资源HTTPS联调23033：`TOOLCHAINS=XcodeDefault`、bundled OpenSSL Python执行 `scripts/verify_v2_live_resource_authors.py --output /tmp/weak-network-protocol44-resource-live-final`。总日志 `/tmp/weak-network-protocol44-resource-live-final.log`。23033实际exit1：生产构建完成，Account启动报missing_configuration，尚未执行客户端业务；所属PG日志确认正常shutdown。正在集中修联调与正式本地模板的缺失路由配置，未放宽生产校验。该轮仅本地参考provider，不代表外部provider、真机后台或容量验收。

### 本机资源联调配置修复

Account新增必需的 `IM_V2_DIRECT_ROOM_SHARD_ID` / `IM_V2_GROUP_ROOM_SHARD_ID` 已在两份native联调脚本及 `IMV2/docker-compose.local-account.yml` 的account环境明确绑定 `rooms-primary`，与实际registry一致。未改变生产校验。Python语法与必需配置静态比对通过；未因此重复服务端单元回归。

父已启动续跑25822，输出 `/tmp/weak-network-protocol44-resource-live-final2`、总日志 `/tmp/weak-network-protocol44-resource-live-final2.log`。25822实际exit1：配置解析已通过，但正式Account路由注册触发room/roomID同前缀参数名冲突而崩溃；同时记录social_direct_authorization_recovery的领域错误。客户端尚未启动，所属PG已正常关闭。正在并行修正式路由与worker装配，前次23033记录保留。

### 正式启动装配修复与第三次资源联调

25822暴露的两处生产错误已集中修复：ReadReceipt/MessageMutation/MessageSend/MessageReaction四组共享 `/v2/rooms` 路由动态参数统一为 `roomID` 并同步读取，不改变URL语义；Account社交授权恢复worker使用领域允许的100条批量，修复原128条在空库也被拒绝的问题。静态路由扫描无参数冲突，未重复单元测试。

父续跑10849：输出 `/tmp/weak-network-protocol44-resource-live-final3`、总日志 `/tmp/weak-network-protocol44-resource-live-final3.log`。10849实际exit1：Account/Gateway/独立Actor/HTTPS已真实启动，客户端完成构建并执行资源场景，但首个认证请求因TLS信任-1202失败，尚未上传资源。正在核对HTTP执行器的task delegate与注入session信任delegate组合；不跳过证书校验。旧日志保留。该轮同时验证正式Account启动、真实资源链路与自有进程清理，不能代替外部provider/真机/容量验收。

### 注入TLS信任策略与任务代理修复

资源10849进入真实客户端后首个认证TLS -1202失败，所属PG确认正常关闭。HTTP执行器、文件上传、Range下载的per-task代理此前没有传递注入session的认证策略；已集中接入 `v2ForwardAuthenticationChallenge`，优先task-level、其次session-level delegate，均缺省时系统正常校验。临时CA/localhost校验不变，不接受任意证书，不改重定向拒绝与取消排空。

父启动同一资源联调的新一轮，输出 `/tmp/weak-network-protocol44-resource-live-final4`，总日志 `/tmp/weak-network-protocol44-resource-live-final4.log`；73702实际exit1：TLS信任修复已获真实请求证据，注册/发凭据、资源capabilities/create/targets/上传/finalize/status、头像绑定与公开资料读取均成功（readyAvatars=1、variants=2）。后续昵称更新使用旧手写请求返回400，正在集中迁移整条live夹具到当前typed合同，尚未完成整条撤权验证。所属PG正常关闭。此前通过的组件范围未重复执行。

### 昵称合同迁移后实时通知链路定位

live suite昵称写入已迁正式typed client，冻结身份/期限/revision并验证原回执恢复；其余手写HTTP仅为测试seed、拒绝及隐私原响应断言。续跑29623实际exit1（`/tmp/weak-network-protocol44-resource-live-final5`）：注册、头像Ready/绑定、昵称提交/原proof恢复、social请求/接受、directRoom创建、typed消息发送均HTTP200，随后等待实时通知超时。所属PG正常关闭。当前并行核对服务端提交后通知与客户端订阅/author队列，未放宽超时或业务断言，未重新运行单元范围。

### typed消息提交后的实时通知补齐

29623超时定位为生产装配遗漏：原有bounded committed observer仅注入旧send batcher，typed send绕过后成功提交没有进入hint/接收者作者补充链路。已将既有observer经Gateway owner resources注入typed send；edit/withdraw/reaction的实际新事件同样接入原room-sequence hint入口。通知在外层领域事实与永久回执事务成功返回后发布，原proof恢复、拒绝、回滚和无新事件不发布；继续保留现有持久room-log/wake恢复，不新增lane。当前源码在最终复核，尚未构建或运行本批E2E。客户端已确认订阅响应与早到事件缓存路径，无需放宽超时；live夹具增加匿名阶段日志。

### protocol44 合并回归状态

Server首轮95678已exit1，唯一诊断为V2ActorMessagingMapperTests旧DTO/结果引用，未执行test body；三座自有库已清理。Core集中迁移该夹具后恢复同一合并范围。

生产编译收口后进入统一回归。Server由Core持有95678，日志 `/tmp/weak-network-protocol44-server-regression.log`；使用原1050未完成范围作基线、移除退休/缺失函数并合并15个实际受影响suite，生成 `/tmp/weak-network-protocol44-server-filter.txt`，不能把旧1050当本轮实际数量。专属PG55439真实可用，三座临时库由native脚本创建/清理。Client由HTTP持有45148，日志 `/tmp/weak-network-protocol44-client-regression.log`，独立native scratch，六个受影响suite合并执行；签名过期先核原session/status的业务断言已加入同一轮。App已通过且未受影响范围不重跑。

本地HTTPS使用现成OpenSSL3.5.8/TLS1.3 Python；默认Docker与已有colima-imv2-va-capacity context实际查询均为socket缺失，PATH未发现nats-server。未启动容器或安装组件。此为后续联调准备，不作为环境项目已验证的证据。本轮先收集完整诊断，不逐文件追加测试。

### 上传签名拒绝恢复增量（待合并复验）

设计中的重新鉴权边界补齐：仅上传字节阶段的mediaProvider 401/403进入已有有限恢复预算；claim已在I/O前保存status，所以下一步核对原session/已确认parts后再取签名。resourceUpload控制端403仍进入needsAttention，不当作签名失效自动循环。原ID、首次操作事实和本轮截止不变。

已将既有资源Step场景参数化为本地签名过期、provider401、provider403、control403，断言分别保留原session/预算恢复或停止自动恢复。本增量在Client45148通过之后落盘，此前32项通过不能覆盖新增分支。初轮50026因夹具浮点时钟SQLite往返导致未到期而exit1；仅将夹具时钟固定整秒，生产分类不变。复验47543真实exit0，四参数全部通过（1函数/1suite，0.098秒），日志 `/tmp/weak-network-protocol44-client-signature-confirmation2.log`，无skip/issue；其它Client/App范围未重复。

### protocol44 客户端合并回归终态

Client45148真实exit0：32 Swift Testing tests/6 suites通过、3.740秒，本filter没有XCTest执行项，无issue/skip。日志 `/tmp/weak-network-protocol44-client-regression.log`。新增 `expiredUploadTargetReconcilesOriginalSessionWithinPersistedBudget` 实际通过；暂存预算同类/异类业务错误两参数均通过。未重跑无关范围。

Server编译夹具与签名临时残留已收口。98053实际执行157项，3个失败函数/5issues、6个Host环境skip；已修退休字段59/58、unsubscribe Hello设备绑定和typed send独立回执策略预期。发现旧精确函数regex未覆盖主数据库Integration，已改函数名边界并重新按当前discovery选954项（原945未执行+3失败+6Host）。此前通过的其它函数不重复。

以下为84211执行中的历史检查点（现已exit1，见上文）：日志 `/tmp/weak-network-protocol44-server-regression-confirmation8.log`，生产测试编译27.66秒完成，已进入真实主Integration；forwardMediaImportBytesAndRecovery的19参数全通过21.276秒，证明此前short-source修复已执行。申请取消场景继续推进，尚无整轮终态。native脚本为两个Host suite另建独立actor_cancel/actor_overload空库，与primary/secondary/control共五座自有库，同一cleanup trap管理；不会借用开发库或共享已初始化schema。confirmation7仅准备阶段因调整独立库而中止，不作执行证据。

### protocol44 集中生产编译结果

App（含当前 ClientKit 生产依赖）已通过 generic iOS Simulator Debug、CODE_SIGNING_ALLOWED=NO 的 build；句柄84900真实exit0，日志 `/tmp/weak-network-protocol44-app-build.log`。Server全生产产品最终句柄29510真实exit0、11.39秒，日志 `/tmp/weak-network-protocol44-server-build-confirmation4.log`，包含 Account/Gateway/Operator、LocalGatewayProbe、GatewayLoadGenerator 和 VirtualActorBusinessProbe。此前失败诊断均为最后一个探针目标遗留的旧请求/结果引用，已集中迁当前typed操作与永久proof，未恢复旧接口。

探针跨进程重放保存并复用原首次提交截止；原proof消费核对身份与指纹。G6脚本两并发结果要求同一原回执，继续核对messageID、单次数据库效果、owner epoch和旧owner围栏；不伪造首次accepted/重放idempotent的不同状态。数据库故障探针拒绝把限流等deferred当故障证明。仅Python语法解析，未执行这些场景。

Protocol生成物、协议文档、文档链接和文档结构四项静态门禁真实exit0，日志 `/tmp/weak-network-protocol44-static-gates.log`；使用已有生成插件，没有为门禁构建依赖。本批没有构建测试target、运行业务测试或启动外部联调。生产编译证明当前装配可编译，不证明故障矩阵通过；后续按合并后的受影响范围统一回归。

### 本批业务与退役收口（尚未回归）

- 上传目标过期与非法目标分开处理。签名过期进入已有有限恢复预算，先核对原 session/确认分片，再获取新目标；复制分片后复核取消与期限。
- protocol44 删除旧 send/edit/withdraw/reaction/forward 请求及无消费者转发响应，保留 tags20/24/26/28/105/106 与 names 为 reserved。Client transport/codec、Server handler、RoomRef 和 Actor 旧入口同步移除；typed HTTP 操作、事实响应21/25/27/29、内部 granted-send batching 保留。
- Hello 不再接受空设备兼容桥；设备须为合法 UUID，Authenticate 与 Hello 严格绑定。相关既有握手夹具迁移到当前合同，不扩大测试范围。
- 本地 Gateway probe 与负载驱动发送改用 typed HTTP。每次操作冻结身份/指纹/截止，最多一次 submit 与四次 query；传输失败如实报告，不通过新身份重发。原并发槽与消息统计保留，但消息路径包含 Account HTTP 成本，旧 TCP-only 容量结果不证明当前能力。 HTTP send 由显式任务 owner 持有，关闭时取消、迟到回调先释放槽，退出前等待 HTTP 和事件循环回调排空，再关闭 EventLoop。固定消息 ID 必须携带原首次提交截止，两个调用脚本已同步。
- 独立容器脚本使用任务私有 Caddyfile 提供 account:8443，Probe 使用同一私有 CA 完整校验；用户开发配置不改。已删除退休 remote-batch 专场景和 HostSharedSendCommitAckLoss 套件，仅迁移受影响的既有合同/握手/路由夹具。旧 G3 报告标明仅证明其历史版本。
- 删除无生产调用的客户端30天重试年龄与到期失败码常量；服务端35天非权威记账下限仍保留。ADR-005改为原身份永久证明和领域首次提交期限，与实现一致。

本批只执行现有 protobuf 生成器、父负责三个工具文件的 Swift 语法解析及差异空白检查；没有构建或运行测试。语法解析不证明类型检查和端到端行为。已有通过证据只适用于未受这些改动影响的范围；最终回归必须合并当前协议/握手/工具与资源增量。

### 后台业务补全（统一回归前）

本批只做源码收口，未构建或运行测试。后台分片在源文件复制完成后、持久mapping写入后且系统task resume前，重新核对取消、账号关闭与授权截止；过期时沿既有cancelAndDrain、mapping收尾、文件清理和许可释放路径退出。后台回调失败达到上限时，不再将已经请求取消的job重新标记为needsAttention/paused；原身份取消仍遵守服务端冷却并使用取消执行预算。

Account正式装配再次核对：外层pair route的独立池、内部身份/授权/投影池、配置最小预算以及先排空再关闭资源均已接线，本轮未新增修改。资源共享暂存预算已有统一实现；真机系统拷贝峰值、后台事件与实际云provider能力仍未取得证据。

### 页面读取补全（统一回归前）

本批三处App生产修改尚未构建或测试：会话列表在同一范围内刷新失败时保留已有items并使用独立refresh feedback，切换归档范围仍清空旧窗口；邀请管理在权限拒绝或认证会话失效时同时清除managementBaseline与deadline，撤下管理资格；隐私设置已有成功本地快照时，刷新中及刷新失败保留表单，首次读取失败仍显示失败态。已核对的会话详情、名称编辑和资料读取不重复改造。

因此此前App336项与ClientKit已有通过结果仍是上一批证据，不能覆盖本批新增的三处页面和两处后台修改。后续统一回归合并覆盖这些增量，不逐项启动测试。

### 诊断接线补全（统一回归前）

本批未构建或测试。公共dispatcher在步骤失败或未结算后，重新读取最终持久状态再记录指标，避免记录更新前的claimed状态；无法读取时保留未知。新增按需accountWorkSnapshot复用准入SQL，从同一SQLite读取普通/控制预留数量与字节、三种未决状态、needsAttention数量及最老未决原操作年龄。App账号runtime安装完成时读取，恢复成功沿同入口采样；旧runtime/认证代次不发布，诊断失败不阻断业务，不增加逐wake扫描。

后台取消指标新增本进程单调时钟的取消请求至实际许可释放耗时，包含排空等待；无可测起点或许可则保持unknown，不用0替代。真实多余重传字节尚无确认区间对账证据，暂存占用峰值/拒绝量也尚未接入诊断，不能以重试标记或已实施额度宣称这些指标已完成。

后续执行范围见[统一回归范围](application-weak-network-regression-scope.md)。Server中断主target必须覆盖失败与未完成范围，其他已通过targets不重复；App/ClientKit按本批受影响suite集中执行。清单是准备产物，不是运行结果。

### 暂存额度诊断（统一回归前）

现有V2ResourceStagingBudget准入扫描已接进程级诊断：最近完整扫描的加权字节、已观察加权峰值、已准入预留峰值以及容量/根目录数量拒绝计数。snapshot只读取内存，未增加磁盘扫描；OSLog仅输出固定数字和拒绝类别。后台系统副本仍按预算权重计算，这不是实际磁盘峰值测量。计数饱和，业务复制闭包抛出的同类错误不计为准入拒绝。本批未构建或测试，待纳入统一资源回归。

### 下载重建前缀指标（统一回归前）

Range传输结果现在携带真实URLSession body计数。下载owner只在请求前已有校验过的本地前缀、服务器对Range返回200且强ETag不变、最终整文件摘要校验通过后，记录verifiedRangeRebuildPrefixBytes；计数不超过实际收到body字节。失败、换版本、无实际计数均保持unknown，最多暂存一条待验证指标。App现有资源日志消费该字段；不将其宣传为所有上传/下载的多余重传总量。上传未知响应后重传仍缺少与服务端已确认part的关联证据。本批尚未构建或测试。

### 当前生产组合编译（2026-09-28）

集中业务收口后，仅运行一次生产组合编译：App `xcodebuild build`（generic iOS Simulator、Debug、CODE_SIGNING_ALLOWED=NO）句柄9147已exit0，日志`/tmp/weak-network-sep28-app-production-build.log`为BUILD SUCCEEDED，包含当前ClientKit依赖；Account `xcrun --toolchain XcodeDefault swift build --package-path IMV2Server --product IMV2AccountServerApp --jobs 4`句柄19923已exit0，26.62秒，日志`/tmp/weak-network-sep28-account-production-build.log`。无需修复或重编。本批未运行测试，编译不证明业务故障矩阵通过。

上传重传口径核对：status从provider读取confirmedParts，生成每次part计划重新过滤已确认分片；客户端每片结束及后台完成均回原身份status。实际task body计数和retry标记可观察，但签发后并发确认、丢响应、进程结束前未保存计数及TCP/provider内部重传仍不可从现有数据推算。此为观测边界，不用新增持久日志制造精确度。

后续本地HTTPS环境预检：系统`/usr/bin/python3`为LibreSSL 2.8.3、不支持TLS1.3；已找到现成bundled Python（OpenSSL 3.5.8，TLS1.3=True），无需安装。只查询运行时能力，未启动E2E。命令入口补充在统一回归清单中。

### 本批统一回归启动（2026-09-28）

生产组合编译通过后进入集中验证。文档链接与结构门禁均exit0。Server由Core持有70800，日志`/tmp/weak-network-sep28-server-consolidated-final.log`，限定此前中断的IMV2ServerTests主模块，使用PG55439与脚本自有三库；尚未取得终态。App已有suite的三项页面行为断言已集中补齐，统一受影响范围句柄28140运行中，日志`/tmp/weak-network-sep28-app-consolidated-incremental.log`；ClientKit先补关键断言再运行合并范围。Server本轮编译77.90秒完成，日志已进入真实PostgreSQL主模块测试，filter并非零测试。均不逐项重启。

本段仅记录启动，不将构建输出或部分通过算作本批完成。平台、provider及容量验收仍独立，不与单元/数据库组件结果混算。

### 本批App增量回归终态（2026-09-28）

App句柄28140已exit0：135 tests/3 suites通过，4.702秒，日志`/tmp/weak-network-sep28-app-consolidated-incremental.log`为TEST SUCCEEDED。覆盖新增会话列表/隐私表单刷新失败保留、邀请权限/会话失效撤销操作资格及现有后台桥接suite。未重复运行；仍不是物理设备后台证据。

ClientKit受影响六suite已集中启动，句柄98978，日志`/tmp/weak-network-sep28-client-consolidated-incremental.log`。Server70800实际poll仍live，已进入真实数据库测试，暂未越过先前globalquota中断场景；两者均未取得终态，不将部分通过归为全部通过。

### 本批ClientKit增量回归终态（2026-09-28）

ClientKit98978真实终态exit0：17 XCTest通过，45 Swift Testing tests/6 suites通过，7.448秒，无skip/issue。日志`/tmp/weak-network-sep28-client-consolidated-incremental.log`。包含真实Range body计数与同ETag重建前缀成功计量、摘要失败/版本变化unknown、同SQLite快照聚合及准入口径、后台排空后单次取消耗时。

本轮后只将暂存业务错误计数场景扩为同类Budget.Failure.exceeded与异类fileSystemFailure两个参数；新增同类参数未执行，不能由本轮通过覆盖，留待下一次确有必要的受影响回归。未重跑App或ClientKit。Server70800仍执行原统一轮，尚无终态。

### Server原轮推进检查点（非终态）

70800实际poll仍live，日志持续推进且当前未报告issues。旧九项失败中八项已真实通过：specialAccountMessageClockBounds（2参数）、directAuxiliaryProjectionTimestampPrecision（7参数）、groupCreationResponseTimestampPrecision（2参数）、forwardDeliveryWorkerRecovery（18参数）、messageScopedMediaDownloads（14参数）、roomLogMediaAuthorization（16参数）、propagatesDisplayNameToExistingDirectPeers、invitationStoreClockBounds（2参数）。剩forwardMediaImportBytesAndRecovery及globalquota尚未到达。仅记录这些修复证据，不代表剩余旧失败、旧挂点或全模块通过。没有重启测试或并发运行同包E2E。

### Server越过旧挂点及新增诊断（非终态）

70800原轮已真实通过groupJoinGlobalQuotaAcrossOwners（3.568秒），旧配额等待环已越过。旧九失败中八项通过；forwardMediaImportBytesAndRecovery仅short-source参数4条issues，定位为SQL过滤placement字节不一致使显式terminal byteCountMismatch分支不可达，已删除该预筛并保留冻结对象和授权约束，待集中复验。

随后进入此前未执行范围，出现invitationApplicantCancellation(expired)违反expires_at>created_at约束的夹具写入；已改合法推进时钟3601秒并重新冻结cancel admission，原回执和quota断言不变。MembershipAndSync新增退休表引用、权限拒绝及借池超时诊断正在按文件集中修正；后续真实诊断增至60条issues，分布于Forwarding(4)、GroupJoinQuota(1)、MembershipAndSync(35)、MessagePolicyPrecision(4)、PasswordAndAccounts(2)、PreferencesAndAuthClocks(14)。已按文件分配三位负责人集中修复，不是整轮终态。未中断或重启原轮。

本地connection recovery专用脚本模式已落盘，先真实注册、核验/刷新凭据、真实开房预热及原设备映射，再进入恢复屏障；仅本地临时资源，明确不含离线注入积压/跨域或App公共work验收。Python AST解析通过；未启动服务、负载或该流程的构建，仍待执行验证。

### Server本轮真实终态与剩余范围

70800已真实exit1：60 issues/18失败函数，之后mutationReplayTimestampBounds(edit)触发Double转换Int64溢出trap（signal5），因此主模块未完整结束。脚本自有三库已清理，专属PG保留。PasswordAndAccounts两项已迁当前永久回执/独立协调池与持久next_attempt_at；其他已报告问题按文件集中修复，尚未复验。

使用当前构建的test discovery（list --skip-build，无test body）与本轮日志对照1377个主模块函数：322通过、5明确skip、18失败、1fatal、1031无完成证据。下一轮待选1050函数，参数化失败保留整函数，未映射display名保守纳入。父已静态核验生成正则恰好命中这1050项且不命中passed/skip；JSON与正则在`/tmp/weak-network-server-remaining-scope.json`及`/tmp/weak-network-server-remaining-filter.txt`。尚未启动下一轮，不再无区别重跑主target。

### 极值时间生产边界修复（待统一复验）

MessageMutation、Reaction、Membership、GroupCapability现有时间helper已增加v2PostgresTimestampCanEncode校验，防止毫秒仍合法但PostgreSQL微秒编码溢出导致进程trap。Mutation/Reaction还在原proof查询后校验领域body实际捕获的入参时间；GroupCapability四动作使用同一个已验证boundTime，不把另一次clock读取当作已验证值。原proof始终优先返回，极值测试保留。

MessagePolicyPrecision与PreferencesAndAuthClocks已报告夹具修正已落盘；PasswordAndAccounts先前已收口。MembershipAndSync已完成typed proof、退休表与维护断言迁移。readReceipt超时实际源于该用例后半段directRoom fixture的route/identity共享唯一连接，已分离身份池，未改读回执事务实现。尚未启动下一轮构建或测试，静态差异检查通过不等于验收。

## 集中回归待办

当前统一回归及剩余工作如下，不在每个修复后重跑整包：

- Server：第19轮九个失败函数对应的源码修复已落盘，另已修复globalquota夹具的嵌套借池等待环及Account正式连接池分区。尚未复验；后续集中回归必须覆盖实际失败与中断后未执行的范围，不能只复跑九个函数即宣称全包通过。
- 已知夹具源码已集中修正、待复验：DirectRoomLog两个场景将owner事务与identity读取分为同库独立连接池，沿用resources统一关闭；传播序列边界场景从目标事件持久化的`MAX(next_attempt_at)`获取准入时间。生产链证实typed preference计入提交耗时，outbox沿用其recordedAt，原固定起始时间会导致候选未到期。候选数、最大序列及重复投影断言均未放宽。
- 最近App读取变更集中覆盖`V2ConversationSearchConcurrencyTests`、`V2ContactsStoreTests`、`V2OfflineStartupTests`及设备页现有suite；搜索已有异常游标场景同步新局部错误语义，并补一个临时翻页失败后直接重试原游标的场景。这些suite已随App336项统一回归通过，源码未变化前不重复执行。
- 业务修复重点：临时入群限流保留原身份恢复；离群后重入的历史受众reaction授权；真实资源字节的Range、If-Range及流释放。已有修改不能由修改前的二进制结果证明。
- 集成和环境证据：本地HTTPS跨进程链路、真机后台、目标provider/CDN、10k恢复洪峰仍未完成。容量驱动源码新增的同步恢复模式尚未构建或运行。

### 业务生命周期补全（2026-09-28）

本批静态核对发现并修复账号切换的迟到副作用，未构建或测试：`V2AppStore`在清理前捕获并移除旧账号运行时，所有后续await只清理捕获对象，最终route更新校验原认证代次；只读升级关闭旧store后，先核对取消、认证代次及升级任务身份再清空离线字段。`stopRealtime`同样在await前捕获两个运行时。`V2AccountRuntime.runRealtime`在start及waitUntilStopped返回后复核closed和原realtimeGeneration，阻止旧连接刷新回调及旧循环停止后来复用的runtime。集中回归需覆盖这些挂起点发生账号切换、后台暂停及关闭的交错。

资源侧补齐一个生产触发缺口：`V2BackgroundTransferCoordinator.performEnqueue`在新mapping持久化并resume系统任务后触发现有wake，让对账建立新grant到期唤醒；此前初始化对账发生在mapping创建之前，系统无回调时可能遗漏到期取消。本批仅改触发接线，没有新增扫描循环或schema；尚未构建或运行，最终回归需覆盖无系统回调时到期取消及排空后释放许可。

服务端本批只读核对direct/moderation/invitation三组的生产注册、认证身份、owner围栏、原回执优先、query/close及永久证明清理边界，未发现该范围新增接线缺口。该结论限于源码核对范围，不替代完整W0–W6验收。

### 页面读取及专属安全流程收口（2026-09-28）

本批不编译、不测试：联系人读取失败立即收回敏感确认框，读取baseline后和确认冻结前再次核对stale/读取代次/取消；原持久提案保留。搜索翻页一般失败保留已加载结果和原游标，展示局部错误并允许继续加载；游标不前进或不匹配则停止翻页并提供重新搜索入口。索引building/failed仍撤下结果展示，不将索引不可用误标为正常分页失败。原有查询generation/筛选匹配检查保留。

远程撤销HTTP返回后，在成功处理和错误调度写journal前复核closed与取消，阻止已关闭activation改写新活动的Keychain元数据；write-ahead原身份未知记录仍用于恢复。Push/远程撤销共享账户executor和调度的实际构造已核对，专属恢复边界不变。上述增量集中回归待执行。操作清单同时纠正已退役lane和原回执接线的过时描述，区分32个kind与远程撤销专属journal。

### 统一回归准备完成项（2026-09-28）

对第17轮日志去重得到12个文件、36个失败函数、242条issues；已按实际函数与本轮各负责人交付核对，没有尚未分配的已报告失败。这里只证明已知问题有对应源码处理，不证明修复有效，也不包括中断后尚未运行的场景。SIGKILL等待中断点另有有界等待修复。

仅在已有suite补两处业务故障覆盖：后台新enqueue静默任务授权到期后被取消排空；远程service关闭后迟到成功/失败不能覆盖replacement owner已写入的journal。两者未运行；Client合并filter为`V2BackgroundTransferTests|V2HTTPDeviceSessionClientTests`，不能以旧设备UI测试代替journal验证。

后续执行沿用第10节去重原则：先冻结本批源码，再集中运行；收集完整诊断后批量修复，仅复跑受影响范围。App此机使用iOS27模拟器`842679DC-C3EF-49EF-8439-443AF7F60DB6`及`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`；当前`verify_unit_tests.sh`默认iOS26.2且禁用签名，不直接用于这次需要Keychain的回归。Client采用`run_v2_clientkit_native_tests.sh`保持XcodeDefault工具链，Server采用已有三库native脚本、PG55439专属实例。没有启动新构建、测试或外部负载。

### 当前整批执行（2026-09-28）

业务和已知夹具集中收口后启动一次组合回归，当前尚未全部取得终态：

- App：`xcodebuild test`，全部`IMAppTests`，iOS27模拟器842679DC，ad-hoc签名开启、禁并行测试；日志`/tmp/weak-network-sep28-app-consolidated.log`，父持有94727。
- ClientKit：`bash scripts/run_v2_clientkit_native_tests.sh --no-parallel`，XcodeDefault独立scratch全包；日志`/tmp/weak-network-sep28-client-consolidated.log`，HTTP负责人持有40866。
- Server：PG55439专属实例、三独立一次性库，native脚本加`-Xswiftc -continue-building-after-errors`；日志`/tmp/weak-network-sep28-server-regression18.log`，Core负责人持有85007。

文档链接与结构门禁本次均exit0。源码未改的空库bootstrap不重复运行。各包先汇总本轮实际诊断，不逐文件重启；最终结果以对应句柄终态与完整日志为准，不以启动或编译成功代替业务通过。

### 本批回归已取得终态（2026-09-28）

App父句柄94727已exit0：`/tmp/weak-network-sep28-app-consolidated.log`记录336 tests/50 suites全部通过，测试耗时50.829秒，覆盖最近搜索分页、联系人及账号生命周期源码；实际使用ad-hoc签名的iOS27模拟器。此结果仅为App unit范围，不是opt-in E2E或真机平台证据。源码未变化前不重跑该范围。

Server18句柄85007已exit1，未进入业务测试；集中编译诊断只有ConcurrentRoomWrites辅助函数参数仍要求旧具体扫描器类型，已交Core按当前协议修正，暂不立即启动19。三临时库已清理、无Server测试子进程。ClientKit40866仍由负责人维护，终态另记，不以日志已出现通过行推断全包通过。

### 集中回归继续（2026-09-28）

Server18的扫描器helper已改接当前`any V2MediaScanProvider`，故障注入与委托行为不变。确认无原进程后启动19，Core持有76555，日志`/tmp/weak-network-sep28-server-regression19.log`；最新实际poll仍live，编译已完成72.80秒，无编译error，继续原定业务回归。

Client40866仍live，报告`V2NetworkCommandRetryTests:28`回执计数失败。源码核对证实测试的`dueOperationWork.isEmpty`不包含claimed工作，因而可能在recover完成前返回；已将两处等待改为读取实际work ID的持久committed状态，重启后确认全部四个原ID。精确提交/恢复次数和原10秒等待上限不变；这项测试源码修改不由当前旧二进制验证，终态后只合并复跑实际失败范围。App336项通过结果保持有效，未重跑。

Client全批40866已exit1：38 XCTest全通过；Swift Testing970 tests/169 suites用时165.229秒，仅上述NetworkCommandRetry一处issue。后台授权到期和远程service关闭成功/失败参数化场景均通过；9个opt-in测试与3个live suite跳过，不能算端到端证据。已安排只复跑`V2NetworkCommandRetryTests`，日志`/tmp/weak-network-sep28-client-retry-confirmation.log`，不重跑完整Client包；复验终态另记。

Client唯一失败定向确认78320已exit0：`V2NetworkCommandRetryTests` 1 test/1 suite通过，耗时1.251秒，日志`/tmp/weak-network-sep28-client-retry-confirmation.log`。完整轮的失败记录仍保留；该复验解决唯一已报告issue，不将已跳过的端到端项目算作通过。Client当前无运行中测试，不再重复其余suite。Server19最新实际poll76555仍live，继续同一轮。

Server19继续执行时报告specialAccountMessageClockBounds两参数connectionRequestTimeout。已定位路由事务持有pair锁期间await回调，回调从同4连接池再申请handoff事务；8并发可耗尽全部连接并形成等待环。夹具已将route与handoff分池、保留原并发及断言；同时继续核对正式Account装配是否存在同池问题，不能用夹具分池证明生产不存在风险。当前轮不重启，修复复验待本轮终态后统一安排。

正式装配进一步核对：Account的handoff使用`.psql`、pair router使用`account-social-coordination`，两者虽已分池，但bootstrap owner的identity reader同样使用后者；外围route事务持连接等待owner，owner再借协调池，仍存在并发耗尽等待环。因此该项升级为生产接线缺口，正在按既有总连接预算分离最外层pair route与内部协调读取，尚未验收。不能仅以修正测试连接池宣布关闭此问题。

Server19当前实际诊断已分组处理，尚未取得终态：除special audit池等待外，Clock的direct payload仍有一处旧固定创建时间断言，已改取rooms真实持久毫秒；large群5000成员准备漏public_user_profiles两个必填时间，已补齐，容量及成员数不变。ConcurrentRoomWrites的forwardDeliveryWorkerRecovery与messageScopedMediaDownloads实际资源失败由资源负责人集中处理。现有修改未触发逐项重编或重跑；19继续执行修复前二进制，不能据当前通过行证明这些新修复。

生产池分区已落盘但尚未运行验证：Account将既有每EventLoop协调预算N拆成`account-direct-pair-route`的1条与`account-social-coordination`的N−1条，最外层pair route仅使用前者，身份/授权/投影仍使用后者，handoff仍使用原`.psql`。总连接预算不增加；Account配置明确拒绝N<2，两个分区均执行session readiness并由原resources关闭。ADR-016已同步职责和预算。需在本轮之后验证正式并发调用链及配置边界，当前19二进制不包含这项生产增量。

媒体增量源码收口：BoundMediaProvider现在显式持有时钟，签发返回后重新读取当前时间调用validateDownload；仍检查GET、字节数、SHA及不可扩大的授权截止，避免历史业务时钟被真实墙钟误判，也不使用签发时刻放过迟到过期结果。Concurrent真实资源fixture透传同一时钟域，两个已报告函数保持原字节及授权断言。Device房间媒体场景的缺失proof注入改复用仅一次性数据库允许的事务内故障helper，生产不可变触发器不改；avatar-gap按当前附件授权合同明确拒绝，profile头像引用不替代独立展示lease。上述改动均待本轮后合并复验。

Account现有配置suite补单个预算边界场景（1拒绝、2接受）；静态确认本地E2E的Account默认预算4，不存在1连接覆盖。新DirectRoomLog传播计数失败已交对应负责人检查持久事件准入时间，不直接降低计数。当前仍不另启构建或测试。

Server19后续诊断仍在集中处理：邀请坏时间场景的两处submit已命中永久group_join_submission_receipts，旧断言却要求读取损坏的可变request时间并抛错；负责人核对原proof绑定及无领域改写，展示/审批路径的坏时间拒绝仍保留。Forwarding真实短源/复制故障场景的新诊断由资源负责人收齐并核对错误映射，不恢复旧fake、不降低完整性检查。尚未启动失败范围复验。

邀请两处重放断言已收口，统一核验typed receipt身份/fingerprint及原request/invite绑定；坏时间展示与审批拒绝、无部分写入断言未改变。转发短源还定位到生产错误分类缺口：真实placement字节数与冻结附件不符时，在prepare output前明确抛byteCountMismatch，沿既有永久MEDIA_UNAVAILABLE拒绝路径处理，避免错误进入临时重试；其余正常/恢复参数的历史时钟问题由前述provider修复覆盖。上述源修尚未执行验证，Server19仍维持原进程。

## 历史检查点

2026-09-28 第17轮后续集中修复：typed reaction授权原先要求单条membership同时覆盖历史acceptance与当前revision，误拒绝离开再加入的原受众；已改为两个独立EXISTS，继续同时要求历史及当前成员资格，与领域授权一致。Device媒体授权夹具复用真实资源placement；Push两处手写偏好记录补revision=1（专属PG日志确认NOT NULL错误）。Concurrent四个媒体场景及DurableClock复制场景已迁当前资源链，原撤权/owner/重放/租约断言保留。上述源码仍待本轮结束后统一复验，未启动额外测试。

2026-09-28 第17轮运行中增量收口：presentation并发夹具改核对typed receipt实际字段和最大revision永久冲突，保留原ID重放/跨目标冲突；邀请配额夹具移除“等待第二操作返回才释放第一事务”的等待环；CrossStore手写投影补当前合同的正revision，身份读取改独立pool。现有load generator已补可选同步恢复屏障，显式支持10k workers并记录实际启动分布，见[容量说明](../../IMV2/docs/09-capacity/gateway-recovery-burst-driver.md)；未构建或运行容量负载。第17轮尚在执行修复前二进制，新增源码不由这轮自动验证。

2026-09-28 第16轮编译暴露ActorFactory两处新typed command缺必需limits，按原64字节预算集中补齐；第17轮日志 `/tmp/weak-network-sep28-server-regression17.log` 已完成编译并继续完整测试，此前quota与转发媒体失败场景已通过（不代表整包通过）。已新增源修：发送/已读各占一次写许可的统计断言、特殊账号8并发的独立control/identity连接池、审核typed proof替代旧primitive ledger计数。邀请并发仍有unavailable待分析，当前轮尚无终态；不并发启动复验。容量工具另在现有load generator补同步恢复模式，未执行负载、不构成F18容量证据。

2026-09-28 第15轮失败集中修复已落盘：临时入群限流不再写永久quota拒绝，原预留只延期而不换ID/代次/首次期限；真实既有场景补原身份限流后成功断言。邀请测试控制读取改用独立连接池，避免owner事务占满同池后嵌套等待，并移除旧文本游标v1兼容。转发夹具接当前真实存储/catalog/placement/扫描和复制链，授权切换时钟保持单调。特殊账号审计故障仅注入审计时钟，moderation经真实admission与原proof恢复；ActorFactory采用typed send，housekeeping验证永久direct proof不被TTL清理。第15轮脚本最终exit1（主Swift Testing被中止，后续targets36+3 tests通过），33条已报issues完成分组修正；开始第16轮统一复验，不能提前宣称修复通过。

2026-09-28 服务端统一回归：第14轮为新增Range断言可选Data解包编译失败，修正后第15轮完成组合编译并进入真实PostgreSQL业务测试。日志 `/tmp/weak-network-sep28-server-regression15.log` 已报告入群配额、Actor工厂、媒体转发和审计等失败；其中临时限流被保存为永久配额拒绝是生产缺口，其他已定位项包含旧夹具合同。Swift Testing在邀请分页场景连接池超时后停滞，实际进程采样 `/tmp/server15-hang-sample.txt` 与无数据库连接状态确认无推进，已中止该helper；该轮属于未完整执行，不得用其他target的通过抵消。修复集中在源码与现有场景，未并发启动新构建。

2026-09-28 空库门禁：`/tmp/weak-network-sep28-schema-bootstrap.log` 首次 exit 1 为脚本旧表数量期望；集中更新当前对象计数及13类退休表存在拒绝检查后，`/tmp/weak-network-sep28-schema-bootstrap2.log` exit 0。真实专属PostgreSQL实测168 relations、358 indexes、60 application triggers、36 functions；readiness覆盖、受控漂移及schema导出/恢复均通过，脚本自有数据库已清理。Server第13轮 `/tmp/weak-network-sep28-server-regression13.log` exit 1，唯一实际诊断为断言短路表达式中的throwing转换，已移出表达式修正；未执行业务测试。

2026-09-28 集中源码收口：第12轮暴露的6份Server测试文件已统一修正，包括必需issuer、特殊账号真实direct store、typed membership/邀请、不可变并发捕获和已退役返回字段；未启动第13轮。限定生产入口核对确认账户HTTP clients共用executor/scope，Push和设备撤销保留专属恢复边界；已检查的退休请求/旧表未发现可达生产残留。此项是源码核对，不代表编译或运行通过。新资源字节入口 `/v2/resource-bytes` 已补单Range、206/416、可信SHA强ETag和If-Range不匹配返回200；416、取消及写出失败释放流许可，正常范围响应仍顺序读至EOF完成全文摘要核验。本地参考实现每次Range仍有O(全文)读取成本，未宣称高效随机读或外部CDN能力。本批未运行构建与测试，统一回归待执行。

以下保留各批次实际结果。版本、schema快照、通过数及当时的待办只对应该批次；“最新”“正在”等历史措辞不覆盖上面的当前状态。失败整包和之后通过的定向回归分别保留，不合并为全量通过。

C1 旧协议删除检查点：禁言/移除成员 protobuf 请求类型、Gateway 私有处理器、Server codec 与旧 telemetry 映射已删除，原字段 53/55 reserved，保留领域同步事实。`/tmp/member-administration-gateway-retirement3.log` 终态 exit 0，3 tests / 1 suite 通过（退休字段两参数、redaction ownerChanged 和认证 actor）。前两轮编译发现并清除了旧 codec/telemetry 引用；不是保留旧请求后仅增加拒绝分支。

C1 服务端新增检查点：专属临时库 current60 bootstrap/SQL contract 通过；`/tmp/member-administration-real-pg2.log` 6 tests / 3 suites 通过，覆盖 HTTP→RoomRef→owner store、原确认截止、初始成员 revision 0、原回执/指纹冲突、关闭及离群重入、mute/remove 回执写入失败的全事务回滚。当前权限变更、关闭竞争扩展及旧 PostgreSQL 业务夹具仍在迁移；不代表最新全 Server 通过。

C1 客户端边界迁移：`/tmp/member-administration-client-boundaries4.log` 终态 exit 0，39 tests / 7 suites 通过。旧 TLS 提交夹具已删除，新增 HTTP 的冻结身份/理由/目标/原 admission 编码验证、UInt64 回执范围、原操作关闭证明的身份与指纹匹配；持久化 typed proof 验证 null、负数、0 与 Int64 上界。禁言成员 revision 0 合法，移除成功 revision 与事件序号必须为正。旧同步投影的极限毫秒读回仍有覆盖。当前生产源不再引用两个旧待发表、outbox 或 TLS API；App 旧 lane 剩 membership/groupCapabilities/social/groupCreation 四条。

C1 本地生命周期检查点：`/tmp/member-administration-retention-schema2.log` 终态 exit 0，10 tests / 4 suites 通过。最新 SQLite 实测 212 对象、指纹 `0xb27934a627facef2`，新意图表及两索引存在，两旧待发表不存在。禁言/移除 committed 历史满七天后同事务删除领域记录与公共 work；注入 public work DELETE 失败证明已删领域记录也回滚，重启后仍可恢复原命令。未知、未确认和 paused 草稿不清理，转发历史回归保持通过。冻结后超期转原身份权威关闭的公共 claim 修正是后续增量，不由本检查点证明。

指标新增检查点：`/tmp/operation-metrics-final.log` 终态 exit 0，13 XCTest + 22 Swift Testing 通过；`/tmp/projection-operation-metrics-native-final4.log` 32 tests / 4 suites 通过。步骤结果按 journal 证明读取；事务 observer 记录 willCommit→didCommit 回调边界，didCommit→会话快照赋值是独立阶段，均不等同于数据库纯 fsync 或屏幕呈现。App 新接线仍待联合验证。

最新资源准入检查点：上传和导入共享每账号 32 个活跃任务额度，所有创建及消息/群头像替换都经同一事务 helper。暂停、处理中、未知和预算耗尽继续占额；原身份重放不重复占额。Ready 后允许过期等终态变化，禁止迟到 processing 将其重新激活。满额附件发送保留输入并提示处理任务。

- `/tmp/resource-admission-final.log`：25 tests / 6 suites 通过，覆盖混合额度、重启、两连接竞争、多附件与替换回滚、群头像满额替换、原资源恢复和当前 schema。
- 最新实测 SQLite 为 221 对象，指纹 `0xda63227b4e1761f9`，包含新转发领域表和两个资源准入索引；此检查点不代表转发服务端或最新 App 已完成验收。
- `/tmp/resource-admission-consumers.log`：资源、群头像、资料意图和后台相关 86 tests / 16 suites 通过；上传取消、原会话恢复、资源过期及文件保护依赖均保持通过。真实设备和供应商验证仍未完成。

最新转发本地生命周期检查点：公共 work 入队预留完整进度上界 1 MiB、终态证明 64 KiB 和实际命令字节；详细进度只存领域表。活动列表优先返回未完成计划，避免完成历史遮住未知任务。超过七天的 committed 转发历史可与领域证明同事务清理；依赖引用、未知和部分完成保留。`/tmp/forward-history-retention4.log` 的 8 tests / 3 suites 通过，包含转发容量/可见性、清理及 reaction 清理回归。最新 ClientKit 全量另行记录，不以该专项代替。

最新 ClientKit 全量检查点：`/tmp/weak-network-forward-resource-client-full.log` 进程终态 exit 0，35 XCTest 与 956 Swift Testing / 165 suites 全部通过，后者耗时 168.364 秒。该检查点覆盖 protocol37、资源共享准入、转发进度预留/活动列表/历史清理、严格 HTTP 入口和 TCP 控制分流。服务端转发最终联调、最新 App 和真机能力仍分别验收，不能据此宣称整个方案完成。

后续增量检查点（先前全量不覆盖这些后续编辑）：

- 账户调度新增独立控制等待额度 64，普通等待额度仍 256。认证/确认执行槽繁忙且普通队列满时，控制请求仍可有界等待；取消、截止、关闭均释放等待记录，但不提前释放实际 I/O 槽。`/tmp/control-full-quota-final.log` 终态 exit 0：17 XCTest + 19 Swift Testing / 2 suites；含满业务计数与字节额度、重启、原身份核对和确定成功/关闭后的容量释放。
- 转发 Server `/tmp/forward-final-real-pg3.log`：7 tests / 4 suites 通过，包括独立源/目标数据库、账户 HTTP、提交后首次确认丢失、原证明恢复、取消未开始部分、owner fence、首次期限与活跃额度、current59 readiness。当前 protocol37 文档检查通过。真实跨进程部署仍未作完整故障演练。
- App `/tmp/forward-avatar-app-final.log` 终态 exit 0：139 tests / 4 suites，覆盖转发原计划继续/取消与群头像刷新失败保留未过期展示、stale 禁管理、权限/会话/lease 失效撤权、读取原持久操作。普通网络失败不被改写为业务未执行证明。

F18 客户端积压证据：`/tmp/operation-backlog-2000-final2.log` 终态 exit 0，真实 SQLite 公共执行 journal 的 2,000 项、20 个顺序键全部以一次尝试完成，模拟 I/O 无同键重叠/重复，最大并发不超过 6，最后无残留 claim。本机单用例耗时 8.089 秒。这是客户端调度验证，不是实际网络吞吐、业务权限验证或 10k 客户端恢复洪峰报告。

最新 App 全量组件检查点：`/tmp/weak-network-forward-app-full3.log` 终态 exit 0，333 tests / 49 suites 全部通过，耗时 28.146 秒；包含最新转发、群头像展示/权限隔离，以及 HTTP diagnostics 在账户运行时和 App 的生产装配编译。此检查点先于 C1 群管理客户端接线，opt-in 本地账户 E2E 未启用。前两轮编译分别暴露 HTTP 长表达式与新增 Core 操作未登记问题，修复后才完成本次全量验证。

真实本地账户 E2E 环境预检：Docker CLI 存在，但 daemon socket `/var/run/docker.sock` 不存在；当前未运行该套件。现有脚本依赖本地账户/Gateway/HTTPS compose 环境，不能以未启用的 opt-in 套件或组件测试冒充 E2E 通过。未改开发数据库、凭据或本地 compose 环境。

| 阶段 | 当前源码能力 | 尚缺工作与证据 |
| --- | --- | --- |
| W0 合同 | Core 强类型身份、指纹、结果、策略及入口清单 | 全领域策略与入口穷尽、性能基线 |
| W1 网络基础 | HTTP deadline/有界响应、账户调度、epoch 鉴权；AuthSession 直接 HTTP provider 已移除 | 最新组合与平台生命周期验收，全端点覆盖 |
| W2 资料 | 持久 preparation、资源依赖、原回执恢复与冲突 UI | 最新截止/取消竞争回归，真实账户端到端故障 |
| W3 命令 | 偏好/收藏、备注/群昵称、已读、发送/编辑/撤回、reaction 已接公共 work；转发客户端及测试已切新合同 | App 其余 6 条 lane 及其他写入口，另核实 redactions；转发账户 HTTP/worker/权威恢复正联合实现 |
| W4 读取 | QueryCoordinator、自身资料 local-first；App 独立只读启动及在线升级已接线 | 全页面查询策略和真机验证；只读不提供额外展示授权 |
| W5 资源 | 单步恢复、Range journal、真实本地 multipart；账户活动与到期唤醒；取消排空及独立服务端冷却已复验 | 后台授权/映射已有实现和专项验证；云 provider、共享磁盘容量与真机故障验收 |
| W6 收敛 | 有分批专项证据 | 最新全量构建/测试、静态入口穷尽、平台/端到端/容量报告 |

当前已核实的检查点（后续正在进行的消息与后台变更仍需重新验证）：

- App 全量 321 tests / 47 suites 通过，日志 `/tmp/weak-network-app-full-final.log`，包括已读显式继续同步及群头像冷却回归。
- 资源 native 41 tests / 7 suites 通过，日志 `/tmp/resource-preparation-native-final5.log`。
- ClientKit 全量 30 XCTest 通过；905 Swift Testing / 148 suites 有旧资源 Scope 测试的 2 个 issues，日志 `/tmp/weak-network-clientkit-read-full.log`。修复后资源 Scope、SQLite schema 与新增后台占槽准入组合通过：15 XCTest + 6 Swift Testing / 2 suites，日志 `/tmp/weak-network-background-admission.log`。不能将定向复验表述成最新全量通过。
- 群头像独立 server cooldown 字段后的 SQLite 快照为 239 对象、`0x122f6d66bb01d34f`；仅证明该检查点，后续消息/后台 schema 变更须重测。
- 账户活动状态观察、替换 generation 围栏、后台已有传输占槽接管与 HTTP 回归 30 XCTest 通过，日志 `/tmp/weak-network-activity-admission.log`。App 失败提示接线仍在实施；后台准入 API 通过不等于系统后台传输已经完成。
- 公共 committed 历史清理与展示冷却组合 55 tests / 7 suites 通过，日志 `/tmp/weak-network-retention-throttle.log`：7 天保留、每批 32、依赖/源文件保护、最新资料与名字成功边界保留；HTTP 秒数/日期 Retry-After、429/503 长冷却、页面替换不提前请求。拒绝/冲突草稿与未知结果未自动清理。App 头像等待改动尚待当前 App 组合构建覆盖。

- 持久操作预算耗尽后的服务端冷却保留复验 28 tests / 4 suites 通过，日志 `/tmp/weak-network-durable-cooldown-final.log`；覆盖重启、显式继续确认不会提前绕过 Retry-After。消息处理器已同步修正，待消息专项复验。
- read/send/edit/withdraw 真实 PostgreSQL 组合 3 tests / 1 suite（read 包含 direct/group 参数场景）通过，日志 `/tmp/message-operations-final-pg.log`。send/edit/withdraw 注入原回执 INSERT 失败证明领域修改、revision/event 与完成事实一起回滚；current57 SQL 契约检查通过。这不代表旧 PostgreSQL 全量夹具已迁完。

- 消息成功历史清理与最新 SQLite schema 在独立测试包中 17 tests / 2 suites 通过，日志 `/tmp/weak-network-message-retention-tests-final.log`；真实库为 228 对象、`0xa8b55d8073c28443`。新增测试验证已完成 edit/withdraw/无资源 send 七天清理、unknown/replacement/资源依赖保护，四个旧消息/已读表不存在。独立包直接编译当前产品源码，不代表完整 ClientKit 测试已通过；全量夹具迁移仍在收口。

- 消息最终专项 28 tests / 11 suites 通过，日志 `/tmp/message-work-tests-final4.log`：持久身份、未知核对、关闭证明、满额度移交、每房间 200 上限、HTTP/TCP 独立恢复、Retry-After 与 typed hint 取较晚时间及 90000 秒冷却重启保留。
- 服务端新增绑定身份的 deferred 限流合同后，真实 PostgreSQL/HTTP 4 tests / 2 suites 通过，日志 `/tmp/message-deferred-final-pg2.log`；含 direct control、quota、向上取整 Retry-After、no-store 和回执失败事务回滚。消息限流不是终态拒绝或裸 unresolved。
- 质量观测生产源在独立测试包 4 tests / 1 suite 通过，日志 `/tmp/weak-network-quality-focused.log`：稀疏窗口不复用旧样本降级、长间隔清旧样本、连接失败不视为健康、非法/倒退时钟忽略；完整客户端组合另验。
- 后台/资源独立组合 34 tests / 7 suites 通过，日志 `/tmp/background-focused-final4.log`，含 512 MiB 共享暂存预算、系统复制预留、锁定收件箱恢复、孤儿占槽、纯导入状态观察和页面取消不撤销意图。真实 iOS 文件保护与跨进程后台仍须独立证据。

- 消息/后台检查点的生命周期与网络组合 27 XCTest + 192 Swift Testing / 9 suites 全部通过，日志 `/tmp/weak-network-lifecycle-quality-final2.log`；包括账户存储/安装绑定/会话恢复、Push 意图、公共重试唤醒、同步重建、schema、历史清理、HTTP 准入及质量状态。此记录先于下一反应领域 schema 改动。
- App 最新完整 327 tests / 48 suites 中，仅后台文件保护实际属性的 2 个断言未通过，日志 `/tmp/weak-network-message-background-app-final2.log`；模拟器原件/inbox 均返回 nil，正在核实平台能力并拆分验证。设备列表旧回包围栏、失败保留内容及消息未知 UI 新测试已通过。opt-in 本地账户真实端到端套件未启用，不能算作执行通过。

- 消息/后台完整 ClientKit 检查点实际执行 35 XCTest 全过；920 Swift Testing / 154 suites 有 3 个 issues，日志 `/tmp/weak-network-message-background-client-full.log`：两处已删消息索引的旧期望及 ResourceStep 缺账号绑定。已修夹具并保留索引/原子回滚断言，定向复验进行中；下一反应领域 schema 改动后还须重新整合验证。

其他实现专项结果不得相互替代：

- 名字与授权展示：Core 8 tests/2 suites；Server 一次性 PostgreSQL 25 tests/7 suites，日志 `/tmp/core-authorized-alias-tests.log`、`/tmp/server-presentation-final2.log`。
- App 名字、备注展示与离线专项：26 tests/3 suites，日志 `/tmp/imv2-name-alias-offline-app-final.log`；离线 ClientKit 专项 32 tests/5 suites。
- 资料 preparation 的头像等待截止不会覆盖已取消意图；新增备注 revision 投影与 Repository 专项已经执行，实际平台双设备故障证据仍缺。

## 当前可复现的验证入口

- `bash scripts/run_v2_clientkit_native_tests.sh --filter 'V2OperationWorkTests|V2HTTPOwnProfileClientTests|V2AccountWorkSchedulerTests|V2HTTPExecutorTests'`：首次组合验证 18 XCTest + 11 Swift Testing 全部通过；后续资料/journal/resource 组合 26 项通过，包含新增共享未冻结意图容量测试。
- journal 用真实临时 SQLite 验证：同 key 退避不越序、跨 key 推进、原子容量回滚、账户/指纹冲突、重启 claim 恢复、迟到失败不覆盖成功、持久轮次预算。
- 资料服务端使用独立临时 PostgreSQL 验证提交/关闭竞争、原回执不受后续资料更新影响、拒绝回执及资源绑定；最终结果以服务端专项报告为准。
- App 通用模拟器构建通过；iPhone 17 / iOS 27 模拟器以本地 ad-hoc 签名运行完整 `IMAppTests`：300 tests / 45 suites 通过。原脚本 `CODE_SIGNING_ALLOWED=NO` 的首次运行出现 8 个 Keychain `-34018`；启用本地签名后同套测试通过，没有删除测试或降低断言。
- `bash scripts/run_v2_clientkit_native_tests.sh --no-parallel`：18 XCTest + 837 Swift Testing / 136 suites 全部通过，Swift Testing 耗时 159.518 秒。单个测试内部的并发/竞争未修改。首轮默认跨测试并行出现 43 issues；其中 schema 快照和群头像 JSON 稳定编码已修正，其余原失败组在串行运行通过，固定等待断言没有放宽。
- 整套运行后补充资料冷启动 UI 恢复入口：ClientKit 资料专项 6 项、App 资料专项 3 项均通过；新增检索索引后，schema 快照 + journal + 资料意图定向复验共 17 项通过（当前主库 243 对象、指纹 `0x0c63658485895777`）。

所有开发验证使用一次性数据库/目录，没有执行开发数据重置；没有旧 schema 迁移或双写路径。平台后台、真实供应商字节恢复及部署容量尚无完成证据。

## W3 / W4 / 下载续传增量

- wire 升至 protocol 33，canonical PostgreSQL 升至 `im-v2-current-55`；没有历史迁移或旧偏好 lane 双写。
- App 通用模拟器构建通过；取消操作、资料 local-first、会话/媒体专项共 122 tests / 3 suites 通过。
- SQLite 偏好意图验证队首冻结、跨 key 推进、共享容量、未知结果查询；投影旧 revision 不覆盖新状态。首次测试发现 claim 在 `Date` 与持久时间间转换的舍入差异，已统一 Unix 时间口径。
- 删除两旧 lane、增加个人意图/确认快照后，当前 SQLite 为 236 对象、指纹 `0xca2252bb8cd1965d`；历史 243 对象只描述上一批 W2 验证。
- W4 专项 XCTest 14 + Swift Testing 19 通过，包括查询取消/排空、资料 local-first 及离线 bootstrap 的退出、绑定、受保护存储与 epoch 检查。bootstrap 本身不等于 App 离线启动已完成。
- Range 原生 delegate 与资源 journal 最终专项 25 项 / 5 suites 通过。AsyncBytes 完成通知方案在原生取消测试中挂起，已替换为 dataTask delegate；仅在 didComplete 后结束物理传输并释放 byte permit。其后两处开始 I/O 前的截止检查已被 HTTP 最终专项全源码编译覆盖。
- HTTP 总截止专项：HTTPExecutor XCTest 9 + Swift Testing 113 / 22 suites 通过，覆盖全部 HTTP client suites、认证、真实 401 共享刷新、初始过期令牌刷新、本地 request 元数据复制、Timeline、Preference 和 schema。业务请求从读取凭据起默认 15 秒；逻辑超时后仍等待物理排空。AuthSession 直接 provider API 尚未删除，生产 App 已统一使用固定 epoch 的 SessionHTTPAuthorization。
- PostgreSQL / HTTP / Gateway 专项 73 项 / 4 suites 通过；Core 4 项 / 2 suites 通过。临时 PostgreSQL 已停止，开发库未修改。
- 本轮首次完整 ClientKit 23 XCTest + 862 Swift Testing 只发现 1 项旧 Timeline SQL 夹具缺少 revision，已修正并在上述最终专项复验通过；App 完整 302 项中 2 项同类旧投影夹具缺少 revision，已补齐并定向复验。最终整套结果另行追加，不能把修复前运行写成全过。

## 本轮最终验收结果

- `bash scripts/run_v2_clientkit_native_tests.sh --no-parallel`：23 XCTest + 865 Swift Testing / 142 suites 全部通过，Swift Testing 160.079 秒，日志 `/tmp/weak-network-final-clientkit.log`。
- 最后把个人偏好首次提交窗口改为读取 Core 登记策略（7 天）后，journal / personal preference / schema / native byte transport 共 18 项 / 4 suites 再验证通过，日志 `/tmp/weak-network-final-policy-range.log`。该项也覆盖最终 Range/upload 开始 I/O 前的截止检查。
- App 全量 302 tests / 45 suites 的两个旧投影夹具补齐 revision 后，受影响 7 项 / 2 suites 定向复验通过，日志 `/tmp/weak-network-w3-app-fixtures-final.log`；其余 300 项在完整运行通过。没有删除断言或放宽等待时间。
- `check_v2_protobuf_generated.sh`、文档链接、文档结构与 `git diff --check` 均通过。

## 下一批明确入口

按[实施计划 A–G](application-weak-network-implementation-plan.md#11-从当前工作区开始的实施顺序)执行：先验证最新工作区，再收敛剩余命令、全页面读取、资源后台与治理。历史批次中的“尚未接线”陈述仅描述当时版本；当前状态以本文件开头的矩阵为准。

### 最新定向复验与规划检查点

- `/tmp/weak-network-media-retention-recheck2.log`：29 tests / 4 suites 通过，覆盖公共 work 保留清理、待执行索引、资源步骤、质量观察。媒体发送历史只在资源 Ready/物理源释放条件满足后解除依赖；独立资源 job 保留。这是 reaction 删除旧 schema 前的检查点，不代替随后 schema 的回归。
- `/tmp/weak-network-device-bridge-targeted-final.log`：9 tests / 2 suites 通过，包含设备列表旧响应保护与后台文件保护策略桥接。模拟器验证策略调用；真机文件保护属性及锁屏恢复仍须独立验证。
- 本轮重新规划按源码更新为 protocol36 / current58；App 已删除 reaction 旧 lane，仍有 7 条旧 lane，另有独立入口。规划交付不代表 W0–W6 完成。

### Reaction 收敛、读取体验与满额移交检查点

- Reaction：客户端 17 tests / 6 suites、重试作用域 6 / 2；服务端真实 PostgreSQL 最终 5 / 3，覆盖提交关闭竞争、owner fence、原回执与回滚、HTTP 基线和 fresh readiness。App 全量检查点 328 / 48 通过；后续 ConversationStore 121 / 1 通过，包含 reaction 离线意图、未知后明确继续、群成员刷新两 case。详见 `/tmp/reaction-work-final.log`、`/tmp/reaction-final-pg5.log`、`/tmp/reaction-app-fault-final.log`。
- 联系人+Bridge：18 / 2；资源：42 / 8，均通过。日志 `/tmp/contacts-background-app-tests.log`、`/tmp/background-focused-protection-final7.log`。模拟器不证明真机锁屏及操作系统冷启动交接。
- 父代理公共清理/schema 21 / 4 通过，reaction 未知不可清理，原 committed 历史可清理且后继保留。
- 随后修复资料/偏好草稿预留不足：入队按最终载荷上界占额，满额时原子移交执行。`/tmp/profile-preference-reservation-final.log` 34 tests / 5 suites 通过，包含两项满额回归。最新 SQLite 为 224 对象，fingerprint `0xec5c2d2a774e97db`；先前 schema 哈希仅是历史检查点。
- Forward、剩余管理/社交领域、独立入口与真实平台/容量验收仍未完成，W0–W6 继续进行。

### 邀请读取纵向

`V2HTTPGroupInvitationClient` 的 GET 列表通过账户作用域 QueryCoordinator 合并，键包含权限域/激活代次/查询代次和规范化 room/cursor/pageSize；订阅独立取消、退出排空。秘密 preview POST 和写入不合并。默认 URLSession adapter 接入有界 HTTPExecutor，生产仍由注入的 accountHTTP 拥有唯一传输许可。保留结构化 HTTP 失败及日期 Retry-After；权威会话终止清管理内容，临时失败保留内容。`/tmp/invitation-http-final.log` 7 / 1、`/tmp/invitation-app-final.log` 12 / 1，均 exit 0。默认设备/Push adapter 收敛仍在进行。

该检查点仍缺偏好 unfrozenTarget 合并和原未知操作用户处置；后续实现与证据见下文，不将容量修复单独视为 UI 完整闭环。

### 偏好用户处置、页面与 Push 冷却

偏好入队只合并未冻结且仍在原期限内的同 key 意图，保留原 ID/截止；冻结和未知操作不可改写。新增账户限定的 pending observation、原身份继续核对、未发送/确定终态显式处置。未知记录不能删除，继续核对不清服务端冷却下限。控件从最新本地意图、确认回执及同步投影 revision 解出目标，防止旧页面修改一字段时覆盖另一已保存字段；成功历史清理仍保留独立 confirmed 值。

- `/tmp/preference-actions-projection-final2.log`：27 tests / 2 suites，exit 0。
- App 的“待同步设置”入口可定位目标会话/消息、显示未知/冲突/拒绝并执行合法处置；收藏、置顶、归档、提醒采用明确目标选项。`/tmp/preference-activity-app-final2.log`：125 tests / 3 suites，exit 0，包含旧列表连续修改、未知不能移除及继续时保留原身份/冷却。
- DeviceSession、Push、下载授权 metadata 默认传输接入有界 executor，不追加重试或重复 permit。Push 冷启动保留预算和冷却，旧 flight 限流晚到也持久化服务下限，不覆盖新意图 revision。`/tmp/device-push-http-final8.log`：45 tests / 8 suites，exit 0。
- 生产端点策略 registry 和 forward 仍在实施。以上是纵向证据，不代表整个应用完成。

### ClientKit 全量通过检查点（上述偏好用户处置前）

`/tmp/weak-network-reaction-client-full.log`（session54532）最终 exit 0：35 项 XCTest 零失败，932 项 Swift Testing / 156 suites 通过（164.903 秒）。包含 reaction、资料/偏好最终载荷预留、资源完成清理、邀请共享查询及最新 SQLite 224 对象/hash `0xec5c2d2a774e97db`。这是 forward 下一纵向改动前的完整客户端检查点；后续改动仍须重新验证对应范围。App 最近全量与专项结果见上文，不把 ClientKit 回归扩称为真机后台/全系统验收。

### 当前实施节奏与群能力客户端接入（2026-09-27）

按用户要求，业务链路连续实施，阶段结束后统一回归；中途仅做必要的生产编译，不逐项启动专项测试。不保留历史兼容通道，旧实现待新生产入口接通后直接移除。

群能力新增 `V2HTTPGroupCapabilityOperationClient`、`V2GroupCapabilityConfirmationWindow`、`V2GroupCapabilityWork` 和 `V2GroupCapabilityOperationService`。四类操作保存强类型 action、观察版本、原点击截止及固定身份；置顶使用权威 roomSequence 保守 CAS。SQLite 意图表已注册并加入账户统一容量预算；冻结后到期转原身份查询/关闭，成功历史清理包含领域行。准备阶段重试有上限，恢复进程不能恢复旧的本地点击授权；重新确认只能更新同一提案的观察基线，不能静默改变目标。

`/tmp/group-capability-client-build.log`（session80286）生产 `swift build` exit 0，9.57 秒；之后增加 pin-baseline service 转发，尚未再次编译。此次没有运行测试。App 群能力入口/待处理 UI、旧 groupCapabilities outbox 和 wire 删除、服务端接线及整阶段回归仍在进行，不能据此认定完整落地。SQLite 正在随成员关系/群能力变更，不沿用旧 schema hash 宣称当前通过。

群能力 App 接线继续：四个生产 adapter 改用统一 operation service，注册四类 dispatcher 与账户准备任务，页面订阅持久化状态并支持原操作继续核对和未冻结确认取消。置顶先读取权威 baseline，再由用户明确确认目标；成员角色由 admission 绑定目标入群版本，客户端仅提交所见完整成员版本。旧 groupCapabilities outbox、队列表/index/trigger、retry lane、ClientKit TLS 四个写方法及旧 protocol 均已删除，同步领域投影保留。

首次 App 生产编译 `/tmp/group-capability-app-production.log` exit 65，原因是同时退役 protobuf 请求后 Client codec 五个旧枚举 mapping 残留；已清理。第二次 `/tmp/group-capability-app-production2.log`（session36537）exit 0 / BUILD SUCCEEDED，生产接线编译通过。本阶段仍未运行测试，旧测试夹具同步调整由对应实现负责人收敛。成员关系 committed 历史清理也已加入领域行先删、公共 work 后删的同事务路径。

### 剩余链路接续

成员关系的共享恢复边界夹具改为真实 typed intent/receipt JSON 解码，保留初始 revision=0 与正结果 revision 的区别；旧重试调度夹具仅覆盖仍存在的 social/groupCreation lane。只调整旧接口删除造成的失效夹具，未执行测试。实际业务旧 lane 数更新为 2。

后续分工：Core/Server 与 ClientKit/App 两侧并行推进 social；群能力服务端生产编译收敛后，服务端负责人接建群多阶段原身份恢复，父代理接对应客户端。建群必须保留成员分块上传与确认游标，不转换为超大单次请求；邀请/申请/审核现有独立 HTTP 写入口继续列为未完成项，不能由 membership 已接入推断已完成。

群能力补充未冻结草稿的显式重新确认流程：读取当前基线后展示原提案，用户再次确认才调用 replace；原服务端冷却下限保留。冻结或未知工作仍仅执行原身份核对，不替换。该 UI 增量尚待下一次合并生产编译，未运行测试。旧 TLS membership roundtrip 夹具已移除，其字段 22 与旧群能力字段 97/99/101/103 一并纳入不可执行的 reserved wire 解码断言；成员 revision 边界由新 typed intent/receipt 夹具覆盖，其他现存 TLS 领域边界保留。

建群下一合同已确定方向：固定完整 intent fingerprint 绑定规范化标题、capacity、成员数及严格排序名单 digest；append 必须绑定 offset/page fingerprint，恢复 cursor 必须带 acceptedPrefixDigest 供本地冻结名单核验。staging 可关闭，finalizing 只能查原结果；永久创建 proof 必须与实际房间 bootstrap 事务关联，控制面路由注册须有可恢复状态。仍在实现，不能据设计决定认定完成。

### 建群客户端新执行链首批实现

新增 `V2HTTPGroupCreationOperationClient`、`V2GroupCreationWork` 与 `V2GroupCreationOperationService`。本地同事务插入公共 work 与冻结名单，实际名单占账户总容量并为进度/回执预留字节；进度验证原身份、完整摘要、已接收前缀摘要、固定 roomID、游标不回退及 finalizing 不回 staging。每次 claim 最多一个 begin/page/finalize/recover，只有已验证的实际前进才重置该步骤重试预算，重复同一 progress 不补预算，原十分钟截止不续期。取消标志先落盘；结果未知查原身份，终态只消费匹配的服务器回执。

`/tmp/group-creation-client-production.log`（session53964）生产 swift build exit 0，11.00 秒，无测试运行。App 建群入口替换、待处理 UI、旧 groupCreation outbox/TLS/schema 清理、服务端跨库创建 proof 与路由恢复、阶段回归仍未完成；新文件可编译不能代表完整建群纵向已落地。

建群 App 已替换为 `V2OperationGroupConversationCreator`，先保存再调度；会话列表监听公共 work/domain 变更，显示取消核对/最终创建/需要继续确认状态，并支持按原 work ID 继续恢复。同账号存在未终结建群时仅复用完全相同名单与标题的请求，不新建一个操作身份。原 outbox、SQLite 待发建群表及索引/触发器、TLS begin/append/finalize/cancel 方法和旧 App fair scheduler 已移除；同步领域数据保留。成功 work 历史清理已加入领域行与公共行同事务删除。

新 progress 增加服务端房间复制游标 copiedMemberCount（含 owner）：本地不接受回退，只有真实前进才重置步骤预算。finalizing 即使原截止已过也只通过 recover 推进已冻结原操作，不能再获取新授权。最新 observer 的 Swift 6 Sendable 问题已修为数据库闭包内提取 Sendable 值；等待与社交/账号偏好合并生产编译，不另启测试。旧建群相关测试夹具迁移尚未完成。

建群旧 Client codec/TCP frame 分类的 8 个请求/响应 case 及无生产调用的旧房间/草稿 DTO 已删除，等待服务端同批 protocol 40 生成收敛；GroupEvent 同步事实未删除。新建群 receipt 入库在同一 DB 事务内读取并校验当前冻结 intent、指纹及已保存 roomID，再提交公共终态，避免仅依赖服务层先前读取的进度校验。此增量未单独启动编译或测试。

后续独立入口明确排队：私聊开启需要持久化原操作；邀请/申请/审批需要持久化秘密相关意图和原 ID；消息审核删除虽然无 App 构造，仍有 SDK/Gateway 能力，按新短期授权与永久回执合同收敛，保留 redacted 同步事实，不静默削去已有能力。

### 私聊创建持久化接续与验证节奏

按用户最新要求，停止按小包反复构建和测试，业务整批完成后统一回归；仅阻碍实现的编译问题中途处理。私聊创建 Core 合同已新增，客户端新增 `V2HTTPDirectRoomOperationClient`（提交/原身份查询关闭、回执和 processing proof 校验、4 KiB 请求边界）与 `V2DirectRoomWork`（账户绑定、同目标未知操作复用、固定原截止、公共容量计费及观察流），已注册本地 schema。服务执行器、App 状态入口和旧 TLS 退役仍待接通，不能视为完整纵向完成。此增量未运行构建或测试。

账号偏好新增草稿外键的清理顺序已接入：完成历史清理时先删除对应 intent，再删 operation 和公共 work；暂停和未知草稿不受该历史清理影响。

私聊创建执行器已接入账户公共 dispatcher：保存原命令与公开身份后再提交；processing 只查询，超时查询/关闭原 ID，成功回执先幂等写入独立会话缓存再完成 work，重启可重放。App 新建私聊与联系人入口换为持久化 service，待处理提示不提前导航到推测房间。旧 App realtime opener、Client TLS direct write protocol/method/DTO 已删除；协议字段 43/44 等待服务端同批生成退役。尚需补齐待处理列表/终态交互、对应旧夹具迁移及统一回归；本轮没有构建或测试。

私聊请求页面状态已接入持久化观察流，空会话列表仍显示请求；支持 needsAttention 原身份继续核对，匹配 opened 回执提供打开会话入口。processing proof 保存为公共 processing 状态，后续只查询，未知结果不重新提交已接受的操作。成功历史 7 天清理只删操作记录，独立会话缓存保留。账号社交 proposal 新增 FK 的历史清理顺序也已补齐。本轮未运行构建或测试，协议退役和统一回归仍待后续收敛。

私聊完成边界进一步收敛：会话缓存与原回执完成改为同一 SQLite 事务；重复终态回调仅校验回执，不重写会话缓存。原创建回执初始化授权时不覆盖已有授权投影，避免旧 proof 恢复覆盖之后的撤权。首次点击即捕获单调时钟截止，复用未知原 ID 不补十分钟预算。未运行构建/测试。

服务端进一步确认 opened 永久 proof 不代表当前授权，客户端缓存 helper 已移除对 v2_room_event_authorizations 的全部写入（不仅保留已有 false）；当前访问权限由同步/授权查询投影提供。

### 消息审核删除新合同

新增 `MessageModerationOperation.swift`：原确认绑定 message revision、membership revision、message ID 与原因码，120 秒授权绑定 actor incarnation；command 与 intent 共语义 fingerprint，丢失 admission 回复仍能按原 intent 查询/关闭。最小永久回执区分 redacted、alreadySatisfied、rejected、closed，应用结果强校验目标与结果 revision。新增 `V2HTTPMessageModerationClient` 的权威 baseline、admit、submit、recover，POST 4 KiB / response 64 KiB。Core/HTTP 只是本轮新增基础，持久化 service 和 Server RoomRef 事务、旧 SDK/Gateway 写退役尚在实施；没有新增 App 页面，也没有运行测试或构建。

消息审核删除新增 `V2MessageModerationWork` 与 `V2MessageModerationOperationService`，注册 schema 和账户 dispatcher。确认时先保存完整原 intent 并预留 admission/receipt 容量；同消息未知操作不可覆盖。每次 claim 只做一次 admission、submit 或 recover，admission 只可保存匹配原指纹的不可变值。重启且 admission 尚未落盘时只查询/关闭原 intent，不申请新授权。回执同事务校验并提交公共终态，不凭回执伪造 message.redacted 同步正文。committed 历史清理已加入。旧 SDK redaction outbox/TLS 写和服务端新 RoomRef 事务尚待收敛；本轮无构建/测试。

私聊 protocol41 reserved43/44 双端生成已由服务端负责人完成，客户端 codec 与 TCP policy 两个旧 case 已删除。生产 LocalGatewayProbe/GatewayLoadGenerator 仍需替换旧 wire 调用，后续由父代理处理。

工具迁移新增共享 `IMV2ToolHTTP` target，直接使用已解析的 AsyncHTTPClient 1.35.0 依赖：显式 CA 校验、禁用重定向、请求/响应有界、15 秒请求期限；私聊创建在单次工具调用内固定原 operation ID/截止，processing 只查询且最多 5 次。当前仅工具 HTTP 基础已落，两个 main.swift 的 NIO 回调接线和启动脚本 URL 配置尚待完成，不能视为旧调用迁移完成。未运行构建/测试。

两工具 source 接线已完成：LocalGatewayProbe 认证后使用认证响应 actor 调 typed HTTP 私聊/好友写；GatewayLoadGenerator 新开私聊改 HTTP 后继续原 TLS 消息/房间同步，移除旧 wire 响应分支与独立开房重试。NIO 回调通过 NIOLoopBound 回到原 event loop，连接关闭后不再提交响应到 handler；HTTP 客户端按调用范围关闭。探针可用 IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL，load 可用 --account-base-url，默认与本地 Caddy 一致；隔离 native harness 传随机 edge 端口，本地 smoke 与 partitioned load 透传账户地址。尚未构建/运行验证，统一回归时收敛编译及实际联调。

审核旧通道退役已落：删除 V2MessageRedactionOutbox、V2ClientMessageRedactionTransport/DTO/TLS方法、旧SQLite待发表/索引/触发器、GRDB旧命令lane查询和旧terminalTTL存储文件；App runtime不再调用旧prune。Client codec/TCP policy的51/52对应case删除，服务端protocol42生成已完成；message.redacted同步事实保留。旧测试夹具引用尚待阶段迁移，本轮没有测试/构建。

邀请committed历史清理新增secret安全条件：只有secret_reference为NULL且secret_release_pending=0才作为7天候选，并在同事务先删领域intent再删公共work；锁屏未释放记录继续保留。

连接runtime旧命令集成已退役：V2ClientRuntimeActivity/V2DefaultClientRuntimeActivity移除flush/resume/suspend/retry-loop能力和outbox/lane注入，V2ClientRuntime不再创建旧commandRetryTask。初次同步完成直接执行既有同步后维护并通知投影，availability同步后的维护保留。账号公共执行器继续独立管理业务写操作。无生产引用的FairDurableCommandScheduler、CommandFlushFlight、旧FlushResult/Flushing接口删除，仍使用的V2ClientCommandError独立为文件；旧SQLite重试行解码/递增helper删除，有限时间转换保留。旧runtime/scheduler测试夹具尚待统一迁移，本轮没有编译或测试。

统一回归夹具准备：runtime测试移除旧flush/lane假实现，保留连接共享、重启、初始同步失败与心跳独立性，availability改验证同步后维护顺序；已删除无生产对象的FairDurableCommandScheduler旧套件。审核outbox旧夹具替换为真实SQLite/publicwork的丢回复后重启查询、未admit重启关闭、未知目标不可替换三条合同；receipt数值边界切新typed receipt。terminal retention改调用公共7天清理，未知message/group保留、成功forward清理。以上仅修改测试源码，未运行任何测试或构建。

### 业务收口：请求期限与取消

按用户再次明确的节奏，暂停零散构建、测试执行及追加旧测试夹具迁移，待生产业务收口后统一回归。检查当前实际调用发现 V2HTTPRequestDeadline.run 会用内层期限覆盖外层任务期限；现改为取两者较早值，认证/子请求只能缩短而不能延长原预算，仍等待取消子任务退出。私聊创建与审核 HTTP 在异步取得凭据后增加取消检查，取消时不继续构造和发送业务请求。本次仅源码检查与编辑，未运行构建或测试；当前整批编译、协议接线和端到端结果仍未验证。

生产入口清单按当前源码刷新：记录92处Vapor直接路由注册，明确其不等同于动态注册穷尽或可达性验收；删除旧邀请五写入口的过期条目，补入私聊/审核/邀请的当前状态。实施计划改为业务整批收口后统一构建/测试，避免历史施工节奏与用户要求冲突。实际复核发现Push默认HTTP执行器未共享账号准入/诊断，已交HTTP负责人修生产构造；群头像/资源仍由专属持久引擎接账户生命周期，不能因不在普通dispatcher里判为漏接。工具HTTP作用域收尾改为只关闭一次，shutdown失败不再触发第二次shutdown。以上未运行测试或构建。

账号生命周期源码复核：Core32 kind 对应App30公共handler+2资源/群头像专属引擎；当前activity失败经状态流展示accountWorkPaused，用户resumeAccountWork会排空并重建账号而不删除未知journal。旧私聊/审核/邀请/群创建写API搜索未发现生产残留调用（同名新HTTP工具和独立sync投影保留）。据此更新实施计划中activity缺口为待整批验证，未宣称已测通过。Push共享executor/scheduler接线由HTTP负责人落盘；额外发现设备列表403后仍保留管理操作资格，已交其修正真实撤权与普通网络失败的区别。无构建/测试。

私聊/审核执行器的原授权窗口补齐双时钟收紧：每次执行取已保存单调截止与原绝对截止剩余时间的较早值，后续时钟回拨不能重新放宽已观察到的截止；完成DB读取后、发请求前增加取消检查。公共claim敏感操作列表补入新moderation kind，过期未提交审核转原身份query/close，与审核服务原合同一致，不绕过恢复路径直接制造本地终态。本轮仅源码修改，无构建/测试。

私聊结果展示的生产读取复核：directRoomIdentities与分页GRDBV2ListWindows均以direct_room_profile权威投影覆盖本地查询缓存；完成回执的cache helper不写房间授权。已修正helper仍称服务端无同步投影的过期注释，保留缓存关联与当前资料/访问授权的区分。本次检查没有把永久opened证明提升为当前访问权限；未运行构建/测试。设备远程撤销的专属原ID恢复由HTTP负责人继续实施，在线抑制和配置由另两负责人收口。

### 整批验证开始

远程设备撤销生产链路已完成首轮装配，开始集中编译与失效夹具迁移。App production xcodebuild build：/tmp/weak-network-final-app-production.log，session67076 exit0 / BUILD SUCCEEDED；此结果在后续DeviceSessions迟到分页失效修正之前，不冒充最新源码全部验证，后续App测试编译覆盖该增量。Server production build由Core负责人单独执行，尚待结果。

协议生成物检查首次因implementation-status仍声明旧版本失败；改为当前protocol43/current63并更新退役说明后，/tmp/weak-network-final-protocol.log exit0。schema readiness关系检查 /tmp/weak-network-final-schema.log exit0。文档链接首次发现历史审计引用已删除文件，将历史文件名保留为非链接退役说明后，/tmp/weak-network-final-documents.log 的链接/结构检查均exit0。未运行任何业务测试套件；Server/Client/App失效夹具正在一次性收敛，后续不重复已通过且未受源码变更影响的门禁。

Core集中回归：首次编译发现GroupMessagingTests仍引用退役V2CreateGroupRoomCommand，改为当前canonical audience + V2GroupCreationIntent，保留容量、排序、标题、重复/owner名单边界。整包随后执行168项/53suite，仅GroupCapabilityRevisionBoundsTests的旧zero-membership断言失败；新成员基线允许0，已改对应断言并修生产注释（无行为变更）。/tmp/weak-network-final-core-tests.log为整包exit1原记录；/tmp/weak-network-final-core-revision-recheck.log定向3项/1suite exit0。其余167项本轮已过，不重复整包；不得把原整包日志标为exit0。Server编译仍由Core负责人收敛实际诊断，Client/App/Server fixture迁移继续。

Server全生产构建经实际诊断修复后通过：/tmp/weak-network-server-production-build10.log，session52929 exit0（负责人提供终态）。修复覆盖毫秒checked转换、throwing fingerprint、邀请查询穷尽、presence lease接口、trusted special原deadline wire及正式probe依赖；不包含业务测试。父代理开始独占PG CleanupSchemaAndInvites/CrossStoreOperations，首个旧inline/staged建群时间用例迁为真实GroupCreationOperationStore+BootstrapOwner：无效时钟不写入、page原摘要/room不变、完成proof可在异常时钟下重放、不同意图冲突、只有一份房间和原回执。尚未执行PG用例；其余旧接口迁移继续，不能以生产build通过认定Tests已编译。


### 业务优先收口：入口登记、资源遗留与已读归档

按用户最新要求，本批未启动构建或测试，旧夹具迁移暂停。生产源码复核发现实际漏接并修复：direct/moderation 的6条账户HTTP路由与2个builder补入统一登记；邀请baseline限64KiB且admission使用不可合并的authorityRead；邀请/远程撤销凭据等待后检查取消。远程设备schema readiness补齐baseline ID/expiry与receipt ID类型和有效expiry索引，SQL门禁同步，未执行门禁。

资源启动清理补齐：旧账号owner排空、新前台任务启动前，立即删除从不被持久引用的严格`.part-UUID`/`.partial-UUID`普通文件；现有durable源仍按引用与宽限期保留。后台孤儿清理改为每轮最多128个并通过已有wake继续，避免超过128个孤儿就永远初始化失败。尚无真机/崩溃恢复执行证据。

已读未知归档新增真实生产闭环：SQLite独立有界归档、原命令/ID保留、仅currentUnavailable已提交暂停项可移入、依赖检查、容量不足事务回滚；归档参与本地去重但不伪造权威watermark。服务与App会话页面提供归档记录和按原ID恢复核对；恢复先query，仍使用公共调度，不新建替代ID。上限256条/1MiB、单条4KiB；不自动清理未知历史。本批包括新的本地建库定义与App协议方法，需后续统一编译和回归，尚未证明运行正确。


### 后续生产调用链收口（未运行构建或测试）

已读归档观察改为同一SQLite快照返回活跃work与归档列表，删除页面先读work再异步读归档的组合；归档变化即使不改变当前队首也会触发观察。归档原阅读位置纳入两条本地未读投影查询和变更通知，避免移出活跃work后未读数回跳；不写服务器watermark或伪造原回执。

HTTP负责人逐个追踪App实际构造到registered leaf，未发现新增漏登路径；资料presentation合法2MiB上限与leaf对齐，其余已定义adapter限额同步到注册表，Push叶子收至原合同1KiB。Server邀请admission补原proof优先：先恢复原回执与control/quota收敛，再对尚无终态的新受理校验当前invite/secret，防止邀请后来撤销遮蔽本人历史完成事实。以上为源码修改与静态核对，不构成运行验证。


后台孤儿清理进一步收紧每轮256扫描/128删除/5秒边界；到扫描或时间上限时，仅在已有删除进展的情况下触发下一轮，零进展返回明确容量错误，防止异常目录杂项使账号循环空转。活跃映射和creating源继续保留，系统孤儿task先cancelAndDrain再清文件。此为源码结果，未运行平台或文件故障测试。


### 集中退休夹具迁移准备

本批不运行构建或测试。父代理把CrossStore旧GroupAudienceImport暂存/TTL用例改向当前GroupCreationOperationStore：关闭与超期释放pages，原终态长期可读，无新房间；保留无效时钟事务回滚。私聊时间边界改真实submitDirectRoomOperation与原proof，不再调用已退役open；偏好domain reducer的事务边界保留。在线偏好时间用例改当前AccountPreferenceCommand/永久receipt，并按现合同验证user_sync_log唯一投影。两个父代理PG文件的presence admission显式给publicationSuppressed；housekeeping TTL用例使用仍合法的当前设备自撤销ledger，删除对已退役隐私短期ledger的依赖。

迁移中发现DirectRoom生产submit/close将有符号毫秒直接转UInt64，在负时间会trap。新增正数、PostgreSQL范围和checked转换helper；原proof仍在时钟校验之前返回。现有时间边界补核对负时间close/submit，未运行。

Client/App负责人完成当前退休接口和工程引用静态检查，仅发现LiveResourceAuthor旧block调用并迁为typed social原命令/回执；其余已完成迁移保留，不等同于测试包编译通过。Server其余夹具仍并行迁移，父代理CrossStore/Cleanup中的部分旧social/membership/invitation接口尚待收口。


### 跨库与授权夹具继续集中迁移

CrossStore personalProjectionSequenceBoundary已改账户偏好、社交、私聊的真实typed原回执；回滚快照切当前receipt/revision表，保留序列耗尽事务原子性、分库outbox暂停恢复、重放不增投影断言。Social时钟用例同样比较不可变proof。Membership与四类GroupCapability时钟用例已切真实room activation +短期admission +原命令，保留无效时钟不落副作用与原proof无新时钟可重放。ReadReceipt preference改当前账户偏好合同，presence-only夹具直接使用当前domain reducer设置场景。本批未运行构建或测试。

所有权调整：CleanupSchemaAndInvites整文件由Client/App已完成迁移的WS负责人接手邀请/成员夹具，父代理继续CrossStore审核段；Core其余PG、HTTP非PG及PasswordAndAccounts不变。Core另外指出split部署私聊owner可能直接读control公开资料的问题，已交HTTP负责人核正式装配；尚属待确认生产边界，不通过向房间库补测试数据绕过。


### 私聊分库生产接线与整批清理

私聊创建必需注入control身份reader，owner不再查询公开资料或账号停用表。原proof先返回；新执行在操作锁/用户对锁后读取当前身份，每次事务重试重新读取，等待计入原首次期限。Account共库部署改用已有独立social-coordination连接池，Gateway使用已有authorization-resolution池，避免持owner事务再等待同一池的读取连接。该快照只用于本次建房与资料投影，不替代当前发送授权。以上为源码核对，尚未构建/运行验证。

父代理CrossStore审核时钟段与4处必需reader构造已切当前入口；MessagePolicyPrecision的私聊场景、群能力和社交/偏好精度段改为真实typed admission/冻结命令/永久proof，不再依赖退役ledger。保留原ID重放、事件/投影时间一致与重复无副作用；负时间拒绝继续由边界用例负责。其余退休夹具引用按文件所有权收口。遵循用户要求，本批没有启动构建或测试。

### 退休接口清单最后收口（未构建/测试）

ClockAndMediaPrecision成员精度函数已用真实activation、admission和永久membership proof替换三条退休入口；用户审核精度段使用当前冻结审核命令，保留event/audit时间一致与原proof重放，trusted safety路径保留。已读presence场景明确publication_suppressed=false并通过当前账户偏好入口设置。MessagePolicyPrecision与PreferencesAndAuthClocks综合函数由HTTP负责人完成当前合同迁移。

末次明确引用清单发现测试构造缺参，父代理已为53处Direct store补齐必需identityReader/projectionDelivery；split Forwarding目标库读取source/control身份，其余既有split reader保留，生产构造无需再改。两份共享建房fixture同时补齐。Core负责旧audience import测试已切真实manifest/quota/close；WS邀请6函数已完成。仍在收口的明确项目是GroupJoinQuota/ActorAuthentication邀请入口和主集成文件、DurableClock的三个邀请时间函数；完成后进入统一编译，以实际诊断修正，不继续扩展猜测性检查。

### 集中编译与首轮真实回归

App build-for-testing 首轮发现两个测试文件仍用旧调用/缺scope参数，修复后 `/tmp/weak-network-consolidated-app-build2.log`、session89145 exit0。随后 App 单元首轮记录334 tests/50 suites、28 issues（`/tmp/weak-network-consolidated-app-tests.log`，session61511；业务测试已结束，Xcode附加diagnose仍在收尾，不能改写为通过）。问题分为：12处当前SQLite缺`v2_profile_invalidations`、8处过期测试断言/非法查询上限、8处未签名模拟器Keychain -34018。已恢复仍被资料同步使用的建库表，修测试断言；正常签名模拟器build session26749 exit0，不改项目签名配置。受影响五组App用例在session43628定向重跑，日志`/tmp/weak-network-consolidated-app-recheck.log`，未判定结果。

ClientKit集中整包由Core负责人执行：38 XCTest通过；967 Swift Testing/169 suites记录9 issues，原日志`/tmp/weak-network-consolidated-client-tests-full.log`。实际生产问题是建群staging被保存为processing，使后续submit不能claim；已改为staging awaitingConfirmation、finalizing processing。其余为schema快照、group role零revision和同步payload旧断言。受影响四组正在定向复测，未重复整包，尚未宣布通过。

Server独立临时PG cluster `/tmp/imv2-consolidated-pg.LPhTbQ`、127.0.0.1:55439、role im_v2_test；只供本任务，完成后停止该cluster。`scripts/test_v2_server_native_postgres.sh`首轮session80195 exit1（`/tmp/weak-network-consolidated-server-tests.log`），尚未运行测试，编译诊断为一个参数顺序和两处退役membership类型。参数已修，复制旧路由栈的测试正在退休并迁真实调用；保持有效trusted safety路径。每轮脚本只创建/清理自己命名的三个临时数据库，不使用开发库。

集中复测结果：App session43628 exit0，`/tmp/weak-network-consolidated-app-recheck.log`记录148 tests/5 suites通过（Contacts、ConversationPresentation、ConversationStore、真实Keychain、CancelledSocial）。Keychain恢复由正常模拟器签名验证，不修改项目entitlement。Client负责人session85113 exit0，受影响9 tests/4 suites通过，最终日志`/tmp/weak-network-consolidated-client-tests.log`；原整包9 issues未改写为绿灯。Live服务、崩溃子进程和规模环境用例仍未执行，不计通过。

Server首轮退役复制栈的测试已删除，原PG membership owner epoch用例改为真实RoomRef/control route/activation/永久proof，保留停用后的原proof、新操作失权、错owner/物理库与epoch断言。第二次整包命令继续用同一专属cluster、每次新建三个临时库，日志`/tmp/weak-network-consolidated-server-tests2.log`，结果待收。

服务端集中编译第3–6次均在Tests阶段失败，尚未执行业务用例：依次修复远程设备DTO显式JSON编码、退役moderation复制栈、特殊账号命令原deadline、成员/群能力owner-fence夹具，以及presence suppression签名与身份隔离fake。未恢复旧生产API；保留当前trustedSafety领域能力。第7次仍通过一次性三库脚本运行，session25317，日志`/tmp/weak-network-consolidated-server-tests7.log`。前六份失败日志保留。App首轮session61511已最终exit65，受影响148项的后续exit0记录保持独立。

本批额外执行的短门禁：schema-readiness关系覆盖、runtime环境示例、文档链接与文档结构全部exit0。协议生成物未改，不重复此前通过的生成检查。联调入口只读盘点发现live-account脚本及两个真实App调用者仍使用退役remote revoke路径，WS负责将这些已知场景迁到baseline/submit/query；未启动live服务，不把本地参考provider验证等同外部provider或真机后台证据。


### 恢复业务优先节奏（暂停分散验证）

按用户最新反馈，先完成业务实现和旧路径清理，再统一构建与回归；本批未启动测试、构建或服务。已确认上轮第7次服务端命令终止，日志保留：失败点为`V2ModerationServiceTests`仍引用退役`V2ModerationStore/V2ModerationService/V2AuthenticatedModeration`，未进入业务测试。此项登记为最终回归的夹具迁移项，不恢复旧生产API。专属PostgreSQL cluster `/tmp/imv2-consolidated-pg.LPhTbQ/data`已正常停止。

此前已知live-account脚本及两个App联调调用者的remote revoke迁移已完成源码交付：读取有界baseline，冻结原命令提交，随后按原命令查询永久回执；原终止、Push失败和重启清理场景保持。未启动联调，不能记为通过。

本轮生产收口分工：资源provider/后台能力装配、远程撤销账号生命周期、已读归档实际入口与恢复。已读归档源码调用链复核未发现新缺口，保留现有实现；源码核对不作为运行验收证据。


本批实际业务修复：远程设备撤销服务新增activation关闭边界，App退出和构造回滚精确关闭对应旧页面/service；关闭后不能读取新baseline、保存新intent或resume，观察终止且迟到反馈不再写回。关闭不删除Keychain原journal/proof，正常离开页面仅结束UI观察，仍由账号activity核对原操作。本批未构建或测试。

容量源码核对结论：普通原操作claim/reconcile/close/complete及cleanup均原地更新或删除，不依赖新增普通operation准入；远程安全journal及后台任务有独立界限。目前并无通用持久化64项/1MiB控制池，scheduler的64个内存等待者不能充当该条款证据。保留设计第9.2条款为待收口差异，不为不存在的业务消费者添加空表，也不宣称按字面完成。


本地文件provider续传边界补齐：下载先以128KiB块计算强内容ETag，`If-Range`失配在解析Range前去除旧范围，只创建一次响应流；因此旧偏移超过新对象长度时也不会先被范围解析阻断。禁用FileIO默认mtime/size条件缓存比较并返回no-store对象，避免错误304；hash任务显式转发取消并等待退出。当前本地provider没有持久权威hash，每次请求仍需完整读文件，这项成本及实际协议行为留待集中回归；不将本地provider当成外部存储供应商能力证明。本轮未构建或运行测试。


### 当前合同与退役残留集中收口

删除`V2ModerationServiceTests`的两条旧转发壳断言及私有fake；当前真实成员管理HTTP/权限/原回执覆盖位于`PostgresV2MemberAdministrationTests`，非法action shape仍由Core `ModerationTests`覆盖。仅清理已知第7轮诊断，没有运行新编译或测试。

当前系统图、implementation-status、设备撤销HTTP合同、durable retry合同已与现有接线同步；资源provider合同和本地部署说明补齐真实multipart、带授权后台资格、任务adopt及If-Range行为，注明全文hash成本与平台证据缺失。本状态页新增当前交付摘要，将历史检查点单独归类；保留完整W0–W6范围及尚未交付的控制持久预留、组合/故障/平台/容量证据。本批未启动测试、构建或服务。


### 控制预留实际消费者落地（2026-09-28）

已读归档恢复是确实需要新增活跃记录的控制入口，现保留原ID/指纹/命令并以`readReceiptControl`类别进入同一公共work和dispatcher；普通额度统计排除它，控制额度独立最多64项且累计1MiB。每项按编码命令加64KiB终态证明上界及2KiB固定控制元数据预留，因此字节上限可先于条数上限生效。没有第二执行队列或复制命令。

SQLite约束、claim/defer及service共同禁止control直接submit。原查询返回unresolved时，仅在同事务取得普通额度后才切回普通房间顺序键并允许原命令再次提交；普通满额则保留control+needsAttention，用户继续仍先query。控制核对使用原ID独立顺序键，不被同房间普通暂停head阻挡；转普通后仍遵守房间写顺序。完成、重新归档及成功转普通释放活跃控制额度；控制满额使归档恢复事务回滚，原归档不变。

需要普通额度但满额的控制记录允许重新归档；页面和resume查询一致优先展示需处理的控制记录，提供容量反馈，避免被旧普通head遮挡。仅最新建库定义变更，不增加历史兼容。未构建、未测试、未修改schema快照期望；合并运行验证集中到实现收口后的回归。

另收口已知PasswordAndAccounts成员移除场景的退役服务调用，改真实typed admission/冻结命令/原proof重放，保留审计、事件和目标成员个人投递断言；未运行该场景。


### 实现收口后的统一回归（2026-09-28）

Server session14712：`PGHOST=127.0.0.1 PGPORT=55439 PGUSER=im_v2_test bash scripts/test_v2_server_native_postgres.sh`，日志`/tmp/weak-network-sep28-server-regression.log`；为该次命令创建三个独立临时数据库，结束由脚本清理。恢复专属cluster时第一次未带端口选项，默认5432被占而立即退出，随后显式127.0.0.1:55439启动成功，未干预既有数据库。Server既有Range用例补同ETag 206及失配越界200完整文件断言。

App session13246运行DeviceSessionsStore与ConversationStore两组，日志`/tmp/weak-network-sep28-app-regression.log`，使用正常ad-hoc模拟器签名，避免重复此前未签名Keychain问题。仅补关闭旧页面后迟到反馈不能恢复状态的一条场景。Client负责人集中覆盖ReadReceipt、SchemaContract与DeviceSession，控制预留仅补必要事务场景；均以实际终态登记，不把启动视为通过。


统一回归进展：App首轮session13246 exit65因HeadlessPush联调夹具同scope `result`重名，父改为`revocationResult`后session33027 exit0；`/tmp/weak-network-sep28-app-regression2.log`记录132 tests/2 suites通过，包含新增关闭设备页面迟到反馈围栏。原失败日志保留。

Client首次session81089在新增fixture的identity.scope引用处编译失败，修复后session30589运行20 tests/4 suites，19项通过，仅旧schema hash期望1issue。真实SQLite对象数仍207，hash为`0xbf0b5e9b44fd80c1`；仅据实际新admission_class/约束更新期望，session6100单独复跑schema。原第二轮日志保留`/tmp/weak-network-sep28-client-regression-2.log`，复跑日志`/tmp/weak-network-sep28-client-regression-3.log`。业务通过包含两个真实SQLite控制预留/原子转移场景及远程service.close后metadata不变；不重复已通过业务。

Server父持有的session14712/56654/61488/19731/23062均已确认exit1，尚未运行测试；修复依次为Request值语义、共享测试fake可见性、两Gateway退休wire/fake、撤销worker suppression参数及nickname wire冻结command构造。Core负责人接管后缀6，自己的session6927继续同一三库脚本；不并发Server编译。文档链接和结构门禁本轮均exit0；未重复未变的协议生成物检查。设备发现只读结果显示存在paired物理设备，但未安装/运行或重启任何真机，不把发现设备记为平台验证。


Client schema复验session6100已确认exit0，2 tests/1suite通过；业务19项与schema2项分开记录，不将原20项整组的失败日志改为通过。本轮无Client/App运行中进程，未发现Client生产诊断。

Server后缀6 session6927已确认exit1，仍为测试包编译、0业务测试：五个夹具文件残留旧membership、groupCreation、invitation、remote revoke调用，以及时间数组类型/局部变量重名。Core收口MembershipAndSync与两处小诊断，WS主Integration的group/invite，HTTP收口PreferencesAndAuthClocks的remote路径；五文件同批完成后由Core独占启动后缀7，不在每个文件修改后单独重编。未重复App/Client已通过范围，专属PG仍保留供同批Server验证使用。


后缀6五文件已一次性收口并进入后缀7：Core修membership真实admission/永久proof及两处Swift类型/命名诊断；HTTP迁remote/others撤销时钟场景，保留异常时钟、回执写入失败回滚、8路并发原proof及副作用一次；WS迁主Integration四处group creation和邀请expiry，保留roomlog/push/capacity/readwatermark及微秒截止断言。Core独占session49541，日志`/tmp/weak-network-sep28-server-regression7.log`，继续同三库脚本，未提前宣称测试通过。

后续真实provider/CDN验收的目标环境已向用户询问；本地参考provider不是生产供应商能力证明。该选择不阻碍当前Server及本地跨进程回归，不以等待回复停止独立工作。


后缀7 session49541 exit1：nickname Core初始化参数顺序修正；后缀8 session15522 exit1：Activation夹具special-account命令补原确认deadline。两轮仍在Tests编译，没有业务执行。Core继续独占后缀9 session4706（`/tmp/weak-network-sep28-server-regression9.log`）；要求同一已诊断接口的其余调用点批量收口，避免逐文件重复编译。后续本地HTTPS/App harness已静态确认显式选择安装的iOS27 runtime、使用独立库/模拟器，7443/8443预检无占用；尚未启动该联调，不与Server构建争用同一包。


后缀9 session4706 exit1仍为特殊账号request参数顺序。Core按实际initializer核对同DTO全部4处构造，修Activation顺序并补AuthorizationRecovery同类遗漏。后缀10 session66883已启动（`/tmp/weak-network-sep28-server-regression10.log`），未与其他Server命令并发。后续若仍有编译诊断，使用本机已确认支持的`-continue-building-after-errors`集中收集，降低逐错误重编次数；不扩大测试范围。


### 执行节奏调整：业务实现优先（2026-09-28）

用户再次明确后续统一回归：业务修改先成批收口，期间只做必要静态核对与阻塞诊断，不逐项启动测试。此前已运行的 resource-live-final6 已结束（exit 1）：服务与客户端编译完成，HTTPS 头像上传及绑定完成，但 direct availability hint 等待超时；保留 `/tmp/weak-network-protocol44-resource-live-final6/client.log` 作为待统一回归的问题证据，不记为通过，不立即启动下一轮联调。

用户明确要求不在每处业务改动后反复测试，后续集中回归。自本条起，不再逐项启动构建或测试，也不继续扩展测试夹具；先完成业务实现和必要的静态核对，已知验证问题统一留待回归收口。Server 后缀17已进入业务测试但停滞，已通知持有进程的负责人终止本轮所属测试并记录终态，不启动后缀18。现有源码修复保留；本轮中断不能视为整包通过，尚未重跑的改动仍标注未验证。

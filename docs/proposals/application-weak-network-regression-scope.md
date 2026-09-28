# 应用级弱网当前验收映射

当前 F18 单机验收以用户最新指定的 **1000 条真实连接**为目标，原2k非空积压、稳定身份、TTL与逐订阅游标追赶合同不变。此前10000轮仅保留历史诊断。最新一轮在17名注册及双刷新通过后，因目标调整主动 SIGINT 停止（exit130），自有服务、PostgreSQL、临时凭据均已清理；它不构成1000连接结果，已清理凭据不得复用。

随后唯一1000连接本地轮73969已真实exit0（`/tmp/weak-network-nonempty-recovery-1000-bounded-confirmation`）：1000名真实注册、全量刷新及warmup通过，峰值在线1000；1000个唯一房间各有真实离线写入，全部1000原订阅满足 `before < injectedThrough <= recoveryTarget <= applied` 且gap0。恢复连接尝试1000次、认证1000、失败0、尝试放大系数1、最后启动偏移16.949毫秒；房间事件拉取1929次且929次收到可重试拒绝，不能误称无业务重试。HTTPS代理TLS失败摘要为空，隔离服务与私有PG/凭据已清理。仅证明本地1000连接非空追赶，scope仍明确 `fullF18Passed:false`；App持久工作、2k积压完整故障矩阵、真机及外部部署仍需独立证据。

## 当前新增实现批次（生产编译与定向统一回归已通过）

遵循用户“业务改动集中完成、后续统一回归”的要求，前几批集中实现后完成一次生产组合编译，再统一运行受影响范围：App149项、Client45项、Server11项及Client3个补查函数均通过；未重跑未受影响的既有全套。以下为选择范围及仍须区分的证明边界：

- 公共dispatcher：大量旧恢复下的新首尝试派发、3:1持续公平、默认恢复5槽/总6槽、单槽可前进、两类SQL候选总计<=32、最早时间不变的新插入唤醒，以及取消/关闭排空。60秒近期窗口和控制预留边界均按当前生产合同。
- 隐私设置：移除离线草稿、原操作确定拒绝后从确认值重算；新服务器revision不被旧成功command覆盖；离线本地投影更新不等网络；已读保存取消不发布迟到结果。
- Server同批8类typed业务路由和共享administration caller：明确取消透传，unknown保留、真实过载仍按既有503/429与RetryAfter合同。

- 失败处置增量：消息closed/rejected原负回执约束、本地过期且从未开始的三重处置条件、重新发送新身份与原proof保留、丢弃后的附件引用释放、未知禁止假取消；个人头像移交/丢弃预览与重新应用最高revision；名称committed历史不还原旧输入；邀请只恢复work在窗口内claim并真实close；群管理拒绝后编辑基线失效。与上面的新增实现合并回归，不逐项运行。

- 建群与设备会话增量：groupRoom到期进入原身份恢复而非本地结束；设备列表在明确会话失效后撤下权限与内容，取消读取基线不显示普通失败。消息管理移除已接线；57981中的新增场景只直接证明本地状态先显示、离页后双确认不入队和原work保留。可配置moderateMessages权限、确认期限及真实对话框交互仍不能由该场景冒称完整覆盖。

本批生产组合编译12122/14863及行为回归57981/46445/44984/73460均exit0，实际覆盖与日志见实施进度；选定suite通过不代表以下全平台条件已满足。本地1000连接非空恢复证据如上；真机系统行为、外部provider及2k积压完整矩阵仍独立验收，不能由组件范围替代。


日期：2026-09-28；当前协议 protocol44。本文件记录验收边界，不以源码存在、编译成功或启动命令代替行为通过。[实施进度](application-weak-network-progress.md)记录实施状态，[实施计划](application-weak-network-implementation-plan.md)定义完整要求。

## 新增发送展示收敛批次（定向集中验证）

后续待处理发送分页改动整批收口后完成一次定向回归：App生产编译79784通过；Client98762的一个SQLite函数通过0.953秒，证明201条终态历史加1条活跃发送的优先展示与完整分页；App28444的一个参数化函数通过0.180秒，证明第65条准备任务按精确ID重试/取消。首次App22654筛选漏掉参数签名，实际0测试，不计通过；28444复用编译产物仅补漏该函数。日志分别为 `/tmp/weak-network-pending-pagination-app-build.log`、`/tmp/weak-network-pending-pagination-client-regression.log`、`/tmp/weak-network-pending-pagination-app-filter-confirmation.log`。本轮启动的模拟器已关机。跨房间积压、旧页迟到、附件查询期间handoff/投影收敛及滚动交互未由这两个函数直接证明，不扩大为完整UI验收。

刷新脚本早期离线回归91780虽以一个测试3.138秒通过，但替身将撤销凭据错造为对象，不能证明现行字符串wire合同，日志 `/tmp/weak-network-refresh-contract-regression.log`。修正后的80551一个测试3.154秒exit0：隔离curl替身连续调用脚本两次，并验证规范字符串凭据轮换和harness解析，日志 `/tmp/weak-network-refresh-wire-shape-regression.log`。两者均不访问网络或真实账号；80551不证明10k容量。

HTTP 原回执 accepted 与本地消息投影到达之间保留明确的等待同步行；覆盖公共发送意图中的文本和附件。持久展示收敛标记与执行终态分离，不能重新发送已受理的身份，不能把 accepted 当作送达。同步投影、合法隐藏事实及 snapshot 激活须原子结束等待，缓存裁剪不能复活旧等待行。

App生产编译32929通过。Client仅新增一个参数化函数，46627中的回执先到、投影先到、snapshot准备后回执再ACK三种交错全部通过0.384秒，同时证明等待时禁止替代/丢弃、未收敛保留容量与历史、收敛后释放并可清理、trim后不复活。该轮schema旧期望失败仍保留；fresh DB实测209对象和hash `0xd64604e42567c696`，更新期望后仅schema复验85348，实际exit0，2项/1suite通过0.080秒。真实撤回/隐藏、App观察流交互未由这三个参数直接证明，不扩大为全组合通过。未重跑此前45/205项已通过范围。

## 证据基线与本轮边界

| 证据 | 可以证明 | 不能证明 |
| --- | --- | --- |
| `/tmp/weak-network-protocol44-static-gates.log`，四项退出码0 | 当前协议生成物一致；协议声明、文档链接与结构通过 | 业务行为、真实网络或平台能力 |
| `/tmp/weak-network-protocol44-app-build.log`，BUILD SUCCEEDED | 当前 App 生产产品编译 | App 单元、真实账户与后台行为 |
| `/tmp/weak-network-protocol44-server-build-confirmation4.log`，exit0 | Server 全生产产品编译通过 | 主测试 target 全量通过 |
| `/tmp/weak-network-sep28-client-consolidated-incremental.log`，17 XCTest、45 Swift Testing/6 suites通过 | 当时版本后台、dispatcher、指标与 Range 的组件行为 | 此后上传签名恢复、protocol44退役后的当前行为 |
| `/tmp/weak-network-sep28-app-consolidated-incremental.log`，135 tests/3 suites，TEST SUCCEEDED | 当时版本页面失败保留、邀请撤权、后台桥组件行为 | 真机系统后台执行与真实 provider |
| `/tmp/weak-network-sep28-client-regression-2.log`与`-3.log` | 控制预留/原子转移与远程关闭业务19项通过；schema另2项通过 | 原失败整组变成通过；其他领域覆盖 |

Server 已结束的回归分批记录：84211执行954项并失败；73854集中复验127项后剩5个失败函数；10880以8项收尾复验关闭这5函数及原生时间戳边界，0issue/skip，日志 `/tmp/weak-network-final-precision-regression.log`。原失败和跳过记录保留，不能合成为一次全量通过。此前五座自有数据库已清理。

Client45148通过32项/6 suites（`/tmp/weak-network-protocol44-client-regression.log`）；上传签名恢复47543通过1函数4场景（`/tmp/weak-network-protocol44-client-signature-confirmation2.log`）。这些结果不覆盖此后TLS任务代理和暂存诊断的修改。

最近本机HTTPS联调resource-live-final8已exit0：1项完整业务场景3.296秒通过，日志 `/tmp/weak-network-protocol44-resource-live-final8/client.log`。实际链路包含头像上传/处理/绑定、直聊与大群作者补充、128px字节/非法能力拒绝、昵称更新与屏蔽撤权、附件撤回停止新能力签发、精确发现和入群审核权限；Account、Gateway、独立Actor及本地参考provider真实运行，自有PG正常关闭。此前final7已证明通知修复，剩余撤回夹具24小时期限违反现行10分钟合同，修正后续验通过；保留原失败记录。

暂存准入84779已exit0：10项/1suite、1.241秒，日志 `/tmp/weak-network-staging-budget-regression.log`。覆盖未知根拒绝、重叠根两种注册顺序的OS副本计额、并发预算，以及既有后台任务接管/排空；不是实际磁盘或真机系统副本峰值测量。

消息取消与表态GET错误分类67522真实通过4项/2suite、0.018秒，日志 `/tmp/weak-network-message-route-classification-tests.log`。原filter的两个send/mutation独立suite名不存在，未计通过；74696用实际V2VaporMessageOperationRoutesTests、skip-build仅补漏1项/1suite，0.009秒通过，日志 `/tmp/weak-network-message-operation-routes-tests.log`。不重跑未受影响的App/Client范围。

账号联调26270已真实exit0（`/tmp/weak-network-protocol44-account-live-final8`）：Client5项通过；App3项通过，包括两次响应中断后的冷启动恢复、Gateway与HTTP远程撤销后回登录及重启保持；headless Push1项通过。App类内未启用的pending-message后台场景skip1单列，不计通过。`app-summary.json` 为3passed/0failed/1skipped，`headless-summary.json` 为1passed/0failed/0skipped；脚本真实终止issued响应和cancel响应各一次并验证原取消证明。私有服务、PG、证书/密钥和模拟器已清理，模拟器删除另经simctl核对。

该联调此前的启动配置、旧fixture与链接阻断已修。全部E2E目标已通过build-for-testing，但本批未选择的规模、慢TLS及目录恢复场景只能记为编译通过，不能记运行通过；模拟器结果不证明真机锁屏、后台URLSession或外部provider。

F19本地慢上传92151已真实exit0（`/tmp/weak-network-slow-resource-control.log`）：新场景1项/1suite通过1.408秒；`summary.json` 与 `slow-resource-gate.json` 记录实际读取262144字节、hits1/completed1、expired0/active0/released=true。客户端断言原HTTP回执/query等值与TCP投影在gate仍waiting时完成，随后原上传完成并释放许可；私有服务和PG已清理。这是本地参考provider的单个隔离场景，不是外部provider故障或真机后台验收。

## W0–W6交付与剩余验收

| 工作包 | 当前可确认边界 | 仍需验收 |
| --- | --- | --- |
| W0 合同/清单 | protocol44静态门禁通过；旧消息请求与转发响应退役 | 合并回归确认当前 discovery、端点登记与真实调用者一致 |
| W1 执行/准入/运行时 | 既有组件证据覆盖取消排空、共享调度与deadline；生产编译通过不等于本轮行为通过 | 上述账号HTTPS刷新/撤销/响应丢失已有真服务+模拟器证据；其他断连组合按F矩阵另验 |
| W2 资料/头像意图 | 已有本地持久与展示组件证据；本轮未提供新的完整业务结论 | 本地资源整链已覆盖头像Ready及展示撤权；资料未知核对等未覆盖交错另验 |
| W3 持久命令 | 普通/控制容量恢复已有真实SQLite证据；旧wire清理已有受影响编译与32项/6suite组件回归 | 当前typed提交/原proof/query-close、事务回滚与并发目标结果；真实丢响应/进程重启 |
| W4 读取/展示/同步 | App页面增量通过；失败保留与撤权覆盖仅限已运行场景 | 本地只读启动→在线升级、真实cursor/ACK恢复、跨设备revision收敛联调 |
| W5 资源/后台 | 本地Range与后台组件有证据；资源字节路由已有resource-live-final8真实整链及92151慢上传证据，上传签名恢复组件已通过 | 外部provider能力、真机后台URLSession/锁屏/重启；本地参考provider本条资源链路已通过；更完整的故障注入另列 |
| W6 删除/正式装配 | protocol44生成与文档一致；当前生产产品编译记录 | 删除后的受影响typed业务回归、工具真实调用与无旧协议消费者验证 |

当前直聊通知及暂存准入修复已有上述受影响证据，消息错误分类与相邻消息路由也已按实际3个suite通过；完整W0–W6/F01–F20仍按对应证明层级验收。

## F01–F20证明层级

下表“已有组件证据”只指上述日志及实施进度中可追溯的具体场景，不表示整个编号已经验收；protocol44受影响部分仍以本轮结果为准。

| 编号 | 当前已取得的范围证据 | 完整目标仍缺的环境证据 |
| --- | --- | --- |
| F01 入队失败/磁盘满 | SQLite准入与原子保留组件已通过；新增等待展示容量交错及209对象schema复验已终态通过 | 实际磁盘耗尽下App输入/附件保留 |
| F02 发送前崩溃 | 持久writeahead组件及选定typed链路已有证据，未提供普通写入发送前真实进程kill证明 | 真进程kill/restart原身份恢复 |
| F03 提交后丢响应 | 原proof组件与Server本轮回归 | 账号发凭据/取消丢响应已有本批证明；普通业务写入的跨进程丢响应副作用一次仍待对应场景 |
| F04 本地完成写失败 | 当前store/dispatcher定向45项及3个补查函数已通过，涵盖原身份和未知保留的具体场景 | 真账户重复核对，不能改成失败或替代ID |
| F05 close/execute竞争 | Server永久proof组件及已结束的分批回归有范围证据，不等于各领域全部并发交错通过 | 跨进程/owner故障时同一终态 |
| F06 迟到回调 | 生命周期与取消组件已有范围证据 | 真连接/token替换与系统晚回调 |
| F07 换号/同账号重登 | App/后台隔离组件已有范围证据 | 真机文件、Keychain和OS task映射隔离 |
| F08 同key顺序/跨key推进 | scheduler/公共work组件与1999旧恢复下第2000个新交互、2000工作滚动排空已通过 | 有积压的真实账户恢复 |
| F09 revision冲突 | typed领域及App定向组件已通过；资料补查证明迟到低revision不降低新意图基线 | 两真实设备并发，显式重基线 |
| F10 unresolved/403/在途 | 控制预留、未知保留及原身份继续/禁止假取消的定向组件已通过 | 真实失权同时原请求仍在途 |
| F11 时钟/deadline/Retry-After | 组件及10880时间边界分批收尾已通过；原失败记录保留，不合成为整包通过 | 真实等待/重启，不提前重试或续权 |
| F12 刷新单飞/Keychain锁 | 签名模拟器与auth组件已有范围证据 | 真实30并发401、丢刷新响应、真机锁屏 |
| F13 全部网络失败 | App135项包含页面保留/撤权 | 离线冷启动与lease自然失效联调 |
| F14 cursor/ACK/快照 | Server/Client已有组件证据；smallN2真实原游标追赶和本地slow-resource投影推进已通过 | 真进程边界kill/restart及恢复投影 |
| F15 上传中断/finalize丢响应 | multipart组件；签名过期恢复组件本轮通过 | 真provider会话/part/finalize及后台中断 |
| F16 Range/版本/完整性 | Client Range组件通过；本地参考provider字节入口已有resource-live-final8真实联调 | 外部CDN/provider 206/200/416与摘要核验 |
| F17 owner迁移/分库 | 临时PG/Actor组件及本机独立Actor联调已有范围证据，非跨故障域迁移证明 | 真实多owner/故障域迁移及旧worker围栏 |
| F18 单机1k连接/2k backlog | 2k SQLite滚动排空及1999旧恢复下新交互已有证据；smallN2真实非空恢复52165通过；73969本地1000 TLS与1000唯一房间真实离线注入、原游标追赶全部gap0、连接尝试1000/失败0 | 2k积压完整故障矩阵、App持久工作及外部部署仍待证据；房间拉取有929次可重试拒绝，不把连接尝试放大系数1解释为全业务无重试 |
| F19 慢资源不挡控制 | 92151本地真实gate场景1项通过1.408秒；同上传账号共享scheduler，字节阻塞时HTTP原回执及TCP→SQLite投影完成，释放后上传与许可排空 | 外部provider故障及真实平台环境不能由本地参考adapter替代 |
| F20 系统挂起/强退/锁屏 | 后台bridge组件通过范围 | 真机OS执行窗口、重启、锁屏及晚完成 |

## 下一步执行顺序与环境

1. 直聊通知、暂存准入与消息HTTP错误分类已收口并取得上述受影响终态证据。此前Server已知失败已由73854与10880分批关闭；下一次统一回归仅合并此后实际变更及未通过范围，保留原失败日志和skip，不再执行已通过且未变化的App/Client范围。
2. 本机一次性 HTTPS/TLS 联调：复用 `scripts/verify_v2_live_account_authorization.py` 与 `scripts/verify_v2_live_resource_authors.py`。使用新输出目录、自有临时PG/TLS进程；App模式显式指定已安装iOS27 runtime。账户脚本的 interrupted-issuance、gateway/private-hint 等既有开关提供真实丢响应与重启入口。系统Python不支持所需TLS1.3，使用已确认的bundled Python；不触开发compose或开发库。
3. 本地连接恢复容量：账户脚本 `--gateway-recovery-connections N` 专用模式真注册、校验/刷新凭据、typed directRoom warmup，再按connectionIndex绑定原身份和目标房间运行driver；当前专用入口先注册min(count,17)名真实账号，以固定刷新并发16按当前wire连续两次跨批刷新，成功后再注册余量；17名计入原10000，最终仍对全量凭据校验期限并按需真实刷新，目标数、TTL和各批截止不变。该哨兵在39889中已真实通过：2名注册及连续两次刷新均exit0；同轮剩余两批各5000以内的注册均exit0，但后续全量刷新失败，不能据此计10k连接通过。smallN2已验证旧入口，10000按下述独立运行记录。首次2连接执行在driver编译阶段失败；修复后52165整体exit0，1条离线新增消息、两原订阅均0→1且gap0，独立服务已清理。该结果仅证明smallN2；10k尝试39469在账号注册准备阶段退出。专用准备并发按生产密码哈希2槽修正后，复验2564两批各5000账号注册均exit0，但刷新阶段0.05秒exit22，HTTP刷新400共9次，未进入warmup/burst；私有服务与PG已清理。刷新脚本已补现行必填撤销凭证并保留轮换输出。后续77711同样两批各5000注册exit0，却在刷新前因harness将当前字符串凭证误判为对象而exit1；隔离资源已清理，仍无连接/离线积压结果。错误形状的91780不构成现行合同证据；修正后离线80551通过。10k复验39889已实际exit1（`/tmp/weak-network-nonempty-recovery-10000-wire-confirmation`）：早期wire哨兵通过、总计10000注册成功；refresh-full 0.086秒exit1，公开HTTP汇总仅有刷新200共17次，无拒绝状态，私有服务与PG已清理。阶段原始日志随清理删除，无法从现有证据确定是哪项后台请求失败；确定的脚本缺陷是首次wait失败提前清理仍运行的后台任务、且解析命令替换可能掩盖失败。现已改为全任务排空并保存只含阶段、数字HTTP/curl状态和解析类别的安全摘要；离线脚本合并回归 `/tmp/weak-network-refresh-drain-contract-regression.log` 2项/3.448秒exit0，覆盖原单记录两次轮换与17条跨16并发边界的坏body/迟到请求排空、第17条不发送、无正文泄漏。随后新增函数单项补跑 `/tmp/weak-network-refresh-batch-boundary-regression.log` 1项/3.728秒exit0，先证明17条正常跨16边界按原身份顺序输出，再验证坏body排空。仍未重跑真实10k。报告需保留工作区dirty与源码hash、凭据有效期、实际连接数/启动分布/积压追赶；它不证明App公共work或跨故障域完整F18。
   最新2745隔离轮实际exit1：早期17名注册成功，首次16并发刷新13次HTTP200、curl SSL连接错误35×2及连接失败7×1（HTTP000）；余下账号、warmup、burst均未执行，owned资源已清理。bundled Python 3.12.14 的原代理在监听socket `accept()` 同步TLS握手，默认队列5；已将握手移至有界worker并加超时、清理和无敏感值的SSL原因计数，尚未复验，仍无10k通过证据。
4. 真机平台联调：需可用签名/entitlements与明确设备，覆盖Keychain、后台URLSession、锁屏、强退/重启、晚完成；发现paired设备不等于已执行。
5. 真实provider/CDN与部署容量：需目标provider及bucket/endpoint、鉴权方式、实际multipart/Range/background能力、部署拓扑和安全容量窗口。当前本地参考provider不能代替此项；Range逐请求全文hash/流排空成本应随环境记录，不宣称高效seek。

所有运行须记录命令、版本/dirty与范围、终态退出码、跳过原因和自有临时资源清理。当前已执行的smallN2非空恢复和F19本地慢上传仅按上述限定范围记录；仍未宣称10k通过、真机或远程部署环境已验收。

当前环境预检：bundled Python 为 OpenSSL3.5.8/TLS1.3=True；PATH 未发现 `nats-server`。Docker CLI 已安装，但 default 与既有 colima-imv2-va-capacity context 的 daemon socket 均不可用，未启动或切换环境。容器/NATS联调需先准备其运行环境；本地 native HTTPS 不必依赖 Docker。

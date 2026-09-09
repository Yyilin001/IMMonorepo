# B15 账号存储生命周期实施合同

目标是完整实现修复方案 B15，同时与 B08/B09 的退出检查点及 D04 的媒体生命周期衔接。当前为部分实施，基础组件通过不等于 App 退出/换号已经具备整条清理链路。

## 已实施

- `V2LocalDatabaseArtifacts` 统一主数据库及其搜索库、两者 WAL/SHM 共六个精确文件路径。保留现有命名：`V2.sqlite` 对应 `V2Search.sqlite`，其他主库对应 `<primary>.search.sqlite`。安装绑定擦除和 App E2E 清理使用同一集合；App 文件保护验证也覆盖搜索库。
- `GRDBV2LocalSyncStore.close()` 在非 MainActor 的 store actor 上显式关闭两个 GRDB pool。GRDB barrier 排空既有访问，关闭后的旧 store 引用访问失败；关闭抛错时不允许删除文件。初始化中迁移、安装绑定验证或备份策略失败，也先显式关闭已经打开的 pool，再向 bootstrap 返回错误，避免随后擦除仍打开的句柄。
- `V2AccountStorageScope` 为一次存储生命周期提供随机 UUID 目录；主库、搜索库、媒体 staging/cache 与 partial/派生文件归属这一目录。账号名不参与删除目标的拼接。
- `V2AccountStorageDirectory` 是文件系统目录管理组件。`active.json` 选择当前 incarnation，`retired/<UUID>.json` 是待清理记录。先原子写入待清理记录，再撤去 active 指针；active 即使因进程中断残留，也不能越过已存在的清理记录重新打开。
- `completeCleanup` 必须经过调用方提供的成功关闭边界后才能移除旧目录。关闭失败保留文件和清理记录；重复已完成的 cleanup 无副作用。等待旧关闭时允许创建新 incarnation，旧 cleanup 只删除旧 UUID 路径。
- 新进程在首次发放 scope 前恢复清理记录；当前 manager 发放 scope 后禁止再调用“启动恢复”入口，避免把它当作运行中关闭操作。未知版本/无效记录失败，记录内不接受任意路径。
- 切换到不同账号不会隐式删除旧 scope，返回 cleanupRequired，要求外层按产品规则处理。组件没有擅自改变未发送 outbox 的保留/放弃语义。

## 已接入的生产启动与普通退出

- `V2ClientSessionBootstrapper` 接收 `accountStorageRoot`，生产 App 使用 `<legacyDatabaseURL>.accounts`。每账号以 UserID 的 SHA-256 选择 catalog，catalog 内再以随机 UUID incarnation 选择文件目录。UserID 不作为任意路径组件使用。普通退出保留账号主库和未发送 outbox，重新登录通过新数据库对象打开原 scope；显式擦除仍是单独动作。
- `V2AccountLocalStoreOwner` 串行所有 open/close transition，包括跨 actor await；同账号 20 个并发 open 共用一对 pool。切换账号先关闭原对象，迟到 close 使用调用者捕获的对象，不能按当前 userID 找到并关闭新 A。已关闭对象的 SQLite 读写失败。
- 旧固定路径主库先验证安装绑定，再读取主库中已经保存的账号。即使首先登录的是 B，旧 A 数据也只迁入 A 的 scope，保留 A outbox；无账号归属的可信旧库不自动归给当前登录者。缺失/失效安装锚点仍按原导入策略丢弃不可信文件，暂不可用则保持原文件不动。
- `legacy-import.json` 在移动文件前提交，绑定原账号和目标 incarnation。每次启动先恢复已提交的移动前缀，冲突或缺失主库失败，不覆盖目标主库。主库及其附属文件从已关闭的源句柄移动；旧全局 FTS 及其附属文件不导入，随后从已验证主库重建。
- 删除旧 FTS 前，主库先持久标记索引 building，避免启动后错误复用 ready 状态。迁移中断后继续使用这个 building 状态，新的 indexer 再完成重建。
- App 新 runtime、stager、media downloader 使用 scope 中的主库和媒体路径，移除旧全局媒体路径生成函数。生产主库和搜索库的 iOS 文件保护继续对实际 scoped 路径执行；随机 E2E cleanup 同时清理它自己的 scoped root。
- App signOut 先推进认证尝试代次并隐藏账号视图；restore 成功/失败与 activate 检查该代次。`discardAuthenticatedPresentation` 捕获当前 indexer/store，取消并等待 indexer，停止 runtime 后关闭精确 store 对象。runtime 的 public stop 取消任务、断开连接后等待启动任务和 owned loops 完全结束，避免仅 cancel/nil 后即认为数据库可关闭。

## 仍需完成的关闭条件

1. 当前接线包含普通退出的双库关闭和生产迁移，但显式擦除仍需由完整账号生命周期拥有者驱动 retire → 停止接纳工作 → drain → completeCleanup。安装绑定失配的重建仍采用精确六文件集合，尚未把所有派生文件一起纳入目录 retire。
2. 认证尝试代次阻止旧结果覆盖新 UI，不能替代 B08/B09 所需的完整 auth-session epoch。进程内凭据 IO 顺序、迟到账号 provider 和认证状态观察已补实现及测试；持久账号 checkpoint、离线 Push 撤销补偿和完整组合验收仍未完成。
3. 旧全局 media-staging/media-cache 不再供新 runtime 使用，但旧目录的可靠删除、在途媒体操作取消/排空、迟到写回的账号/安装代次检查仍属于 D04，尚未完成。不能因为换了目录就声明旧正文或附件已从磁盘全部清除。
4. 页面观察取消依赖旧视图移除，数据库关闭保证旧句柄不能继续写；仍需验证全部页面/下载任务的显式生命周期及受保护数据恢复，不只以任务取消为证明。
5. 当前迁移/清理测试构造各持久边界并重建 owner；仍需实际 kill App/子进程、冷启动和 A→B→A 的完整链路证据，以及 legacy WAL/SHM 与媒体历史文件的迁移组合。
6. 普通退出不擅自丢弃未发送业务命令。若产品提供显式擦除/放弃 outbox，需要沿用明确规则，不能为简化清理而启动时直接删除已验证主库。锁屏/Keychain 暂不可用不属于可擦除的安装失效，目录删除也不等于物理磁盘覆写。

## 已验证证据

- 针对性 15 tests / 3 suites，日志 `/private/tmp/im-remediation-account-storage-foundation-2.log`。
- 覆盖三个主库命名、主库/搜索库/partial 目录删除、关闭失败保留清理记录、进程在清理记录落盘后/active 移除后/目录移除后恢复三个时序、A→B→A 的延迟旧 cleanup、新账号文件不被旧任务删除、同一 manager 禁止运行中调用启动恢复、无效记录不选择外部路径。
- 真实 GRDB pool 覆盖索引维护和 ValueObservation 取消后排空、两个 pool 关闭后删除、旧读写与旧 indexer 访问失败，不重建已删除文件；安装绑定缺失/不匹配擦除旧搜索内容，暂不可用保留原文件。
- 这些恢复测试重建 manager 并构造已提交边界，不是实际 kill App 的端到端测试。生产 App 账号切换/目录迁移/任务生命周期仍需第 1–7 项的组合证据。
- 全量客户端 257 tests / 45 suites，日志 `/private/tmp/im-remediation-account-storage-client-full.log`。App iPhone 17 / iOS 26.2：129 tests / 12 suites，日志 `/private/tmp/im-remediation-account-storage-app.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_15-04-14-+0800.xcresult`。

## 生产接线后的验证

- 针对性 31 tests / 5 suites，通过账号存储所有权、旧数据迁移、目录清理、session bootstrap、runtime 与安装绑定场景；日志 `/private/tmp/im-remediation-account-owner-tests.log`。
- 新 owner 覆盖旧 A 主库/outbox 在 B 首先登录时仍归 A、全局 FTS 不被导入、索引 building 保留、20 并发 open 共用 pool、旧 A 关闭不关闭新 A、三个 migration 持久前缀恢复、安装锚点缺失重新启动和 Keychain 暂不可用保留原文件。
- session bootstrap 测试直接使用生产 accountStorageRoot 接口，验证关闭/重新登录保留命令且返回新对象。runtime 测试在 stop 返回时直接断言四个测试循环已退出，不再靠随后等待取消通知证明。
- 最终客户端全量 264 tests / 46 suites，日志 `/private/tmp/im-remediation-account-owner-client-full.log`；App 全量 129 tests / 12 suites，日志 `/private/tmp/im-remediation-account-owner-app-final.log`，xcresult `/Users/yyl/Library/Developer/Xcode/DerivedData/IMApp-cjlmjtyfhinneffrzbtwrknpoomw/Logs/Test/Test-IMApp-2026.09.05_15-17-41-+0800.xcresult`。
- App 全量通过是编译和现有回归证据；不是带真实账号服务的 logout/kill/relaunch 端到端验收。B15 继续实施中。

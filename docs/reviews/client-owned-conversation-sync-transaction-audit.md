# 房间恢复事务边界审计

本页按实际 `databasePool.write` 边界核对强杀证据，不用参数总数替代覆盖。当前实现状态见 [验收矩阵](client-owned-conversation-sync-acceptance.md)。

## 2026-09-20 资格与代次修改后的专项复验

本次对实际改动的 recovery、state、unavailable、retryWork、finishWork、summary 六条入口，各运行提交前/后 SIGKILL，12 个参数全部通过。
父进程校验当前加载测试 bundle 与子进程路径相同；重开 SQLite 检查提交原子性及相应恢复动作。
这是本次源码下六入口的证据，不把下面历史 62 参数的结果重标为本轮全矩阵通过，见[复验记录](verification-records.md#20260920-recovery-work-fence-crash)。

测试支持 IMV2_CLIENT_CRASH_TRANSACTIONS 逗号分隔的显式事务名；不设置时保留原完整矩阵，非法/重复/空选择直接失败。当前默认有 32 类事务（含后续加入的 memberRemoval），不将默认可运行数量当作实际通过数量。

## 新增房间恢复与摘要模块

源码位于 `IMV2ClientKit/Sources/IMV2ClientKit`。下表“通过”指真实子进程在提交前后分别 SIGKILL，重新打开 SQLite 验证；证据为 `/tmp/imv2-snapshot-cleanup-crash-v2.log`，62 个参数通过。

| 写事务入口 | 当前证据 | 仍需补充 |
| --- | --- | --- |
| GRDBV2RoomRecoveryStore.beginRoomRecoveryScan | beginScan / replaceScan 强杀通过；首次插入、扫描替换、旧 scope 写入拒绝、待办保留及重启继续 | 账号/安装绑定变化与真实生命周期组合 |
| restartRoomRecoveryDirectory | restartDirectory 强杀通过 | 系统后台期限组合 |
| commitRoomRecoveryDirectoryPage | directory / emptyDirectory / finalDirectory 强杀通过；分页游标、终页标记与待办原子变化，旧页重复拒绝 | 真实系统后台期限组合 |
| enqueueRoomRecovery | enqueue / mergeTarget 强杀通过；新目标、请求身份、最高优先级及调度时间原子提交，旧重试不推迟新任务 | 系统后台期限组合 |
| enqueueRoomLatestVisible | enqueueSummary / enqueueExistingSummary 强杀通过，首次摘要需求及已有正文目标与任务原子提交 | 系统后台期限组合 |
| ensureRoomLatestVisible | ensureFreshSummary / ensureSummary / ensurePendingSummary 强杀通过，首次需求、正文任务合并、既有摘要身份及退避保留 | 系统后台期限组合 |
| GRDBV2RoomRecoveryWork.commitRoomRecoveryState | state 强杀通过 | 无新增独立写入口；陈旧状态分支另由竞态检查 |
| commitRoomRecoveryUnavailable | unavailable 强杀通过，权限撤销/状态/任务一致 | 与真实成员变化的跨组件组合仍待执行 |
| retryRoomRecoveryWork | retryWork 强杀通过，延期和公平序号一致 | 无新增独立写入口 |
| finishRoomRecoveryWork | recovery 同事务完成及 finishWork 独立完成强杀通过；正文/游标保留，重启可清理且重复完成返回 false | 系统后台期限组合 |
| GRDBV2RoomLatestVisible.commitRoomLatestVisible | summary / summaryWithoutWork 强杀通过；有/无关联任务两种提交均不推进正文游标，无关联任务时保留待办 | 陈旧响应提前返回无写入，由 latestVisibleCacheIsDisplayOnlyAndFenced 及 summaryCompletionPreservesNewRequestsAndRaisesContentTarget 覆盖；系统期限组合仍待验收 |

`beginRoomLatestVisibleRequest`、`roomRecoveryProgress`、`roomRecoveryCompletionCandidate`、`verifyRoomRecoveryCompletion` 和各查询入口使用读事务，不新增提交前后强杀项。完成状态仍须结合个人流水位及持久待办核对，读事务不代表无需竞态测试。

## 相邻持久化边界

`applyGroupEventPageReportingChanges` 与 `applyRoomRecoveryPage` 已分别由 body/recovery 覆盖；成员撤销由 removal 覆盖；新的自身成员授予与恢复待办、个人流水位同事务提交由 personalGrant 强杀覆盖，重启重放保持请求身份。快照初始化、分页、激活准备、空/非空激活、重置开始与取消均有真实强杀参数。

上述清单只审计本次恢复改造及其直接依赖，**不是整个 ClientKit 每个 SQLite 写事务的完整枚举**。个人事件分支及系统后台期限还需继续核对，不能把普通单元测试或上述 62 个参数扩大为全部事务覆盖。

## 有限恢复的取消与续跑

有页数上限的恢复取消后续跑已通过：`/tmp/imv2-bounded-recovery-cancel-resume.log`，1 测试、2.434 秒。已提交目录待办后，在下一次目录请求处取消 runner，确认 CancellationError、引擎 idle、正文游标仍为 0、待办仍为 1；新 runner 在 4 页预算内恢复两个房间至游标 5 并清空待办。此测试使用受控传输和真实 SQLite，正文页为空，不等同系统后台期限耗尽或非空消息恢复。

## 快照旧表回收

快照旧表回收新增提交前/后 SIGKILL 验证通过：`/tmp/imv2-snapshot-cleanup-crash-v2.log` 退出 0，31 类场景、62 参数，9.960 秒。非空快照先完成激活，再单独在生产清理事务提交边界强杀；重开 SQLite 后，提交前保留旧表、提交后旧表清空，当前消息和已确认游标保持一致，重复清理安全。DDL 不提供普通行变更回调，因此该场景在事务外安装 observer，只观察接下来的清理事务。仍不替代系统后台期限或真实 TLS 快照重置验收。


## 2026-09-20 目录请求栅栏修改后的复验

目录提交改为携带请求前捕获的扫描信息后，directory、emptyDirectory、finalDirectory、restartDirectory 四事务提交前/后共 8 个真实 SIGKILL 参数通过，见[记录](verification-records.md#20260920-directory-flight-fence)。
本次使用显式事务筛选与同一当前测试 bundle，不扩展为其他事务或真实系统后台通过。

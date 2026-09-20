# B23 申请人配额：单库事务修复

> 本文保留 2026-09-06 单库阶段的实现与验收。后续 schema 39 已完成全局接线及 B23 验收，
> 当前合同见[跨 owner 全局配额](group-join-global-quota-contract.md)，不再以本文的“仍需完成”判断现状。

当前生产邀请入口仍将邀请和申请写入一个 PostgreSQL 数据库。本批修复该入口已存在的并发超额提交；B23 保持实施中，修复方案要求的跨 owner 全局配额尚未完成。

## 已实现

`PostgresV2GroupInvitationStore.submit` 在事务内先取得申请人级 advisory lock，再查询已有 operation、锁邀请、检查额度和插入申请。锁由解析后的 UUID 构造，同一申请人的不同 operation/invite 共用一个锁；不同申请人的锁键不同。原来的 operation 锁被这个更大的互斥范围替代，没有增加第二把重复锁。

默认 READ COMMITTED 下，等待申请人锁的事务在获得锁后重新读取已提交申请，因此 19 条占位时，两个不同邀请并发申请只能再提交一条。pending 与 approving 均占位。重复 operation 在额度检查前返回原结果，不重复扣额；同 operation 不同输入仍冲突。同邀请的重复申请返回原请求。拒绝成为终态后，后续提交可使用释放的名额。

未增加持久计数器或 schema，也未改变审批、取消和过期策略。已存在的超额历史不会在本批被静默删除；达到或超过上限的申请人继续拒绝新申请，直到原有请求完成。

## 验证

[证据](../../docs/reviews/verification-records.md#20260906-invitation-applicant-quota)使用真实 PostgreSQL 16.13 和专用数据库 56440。测试在 INSERT 前安装数据库锁屏障，并观察两个真实事务进入等待，再释放屏障。

旧实现下，两种初始状态（19 条 pending；18 条 pending 加 1 条 approving）最终均提交为 **21 条**，回归失败。修复版两种状态均保持 **20 条**，其中一条新申请成功、另一条被限额拒绝；另验证 10 个并发原 operation 重试、同邀请新 operation、相同 operation 输入冲突、拒绝后的名额重用。

最终 **6 项服务端测试 / 2 套件**通过，同时覆盖原邀请游标及耗尽链接创建配额。失败和通过日志均保留。测试 schema 已删除，连接归零，专用 PostgreSQL 已停止。ClientKit/App/Core 没有源码变更，本批未重新运行其全量测试。

## 仍需完成的全局合同

申请人锁只在当前数据库有效。B27 将房间分到不同 owner 后，必须以 control 的幂等 reservation 作为唯一占位单位，并让 owner 使用同一个 reservation ID 提交申请；不得把 reservation 与对应 owner pending 相加计数，也不能在每个 owner 各给 20 格。

完整接线还需要 token 到 room 的最小目录、owner epoch 检查、同 operation 和同邀请重复提交的稳定映射，以及 owner 终态 outbox 的幂等释放。模糊超时不能直接释放 control 占位，否则迟到 owner 提交会造成超额；释放必须有 owner 确定终态或带代次的持久取消事实。B26 原子审批及 D06 取消/过期仍是这条链路的必要工作。

本批没有双 owner 配额证明，不能关闭 B23。旧写进程不遵守新的申请人锁键，部署时须协调替换所有邀请写进程；新旧写实现混跑不具备该并发保证。protocol 25、PostgreSQL 19、SQLite 173/5 保持不变。

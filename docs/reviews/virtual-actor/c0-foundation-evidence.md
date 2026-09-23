# C0 基础契约证据

业务基线 f1cdd78d6a21bf0ae23da627c0710c65115236aa；本记录仅覆盖公共身份/lease/错误语义/容量配置与本地容量计数，不代表 G1 全部契约或完整 Virtual Actor 完成。

## 已实现

- IMV2ActorContracts 单独目标，仅依赖 IMV2Core。身份、租约观测值和错误 envelope 具有明确 Codable 格式及解码验证。
- 数据 ownerEpoch 保留 main 的非负范围和 shard 规范化；activationEpoch 为正 PostgreSQL bigint，不混用两种身份。
- Lease store / data-owner resolver 端口区分持久数据归属、当前激活和进程 incarnation；当前尚未提供实际 PostgreSQL lease 实现。
- 未接受、确定回滚和结果未知分别表示；只有具备持久幂等及稳定 ID 的写才能在未知结果后分类为同操作重试。该分类不代替业务持久幂等或调用总时限。
- 配置限制队列数/字节、待激活房间数、房间与节点等待者、恢复/解析并发、定位缓存、微批、reservation 和生命周期时限。有限默认值只是工程起点，尚未有容量基线批准；配置字段存在不代表对应调度器都已实施。
- IMV2ActorRuntime 的 V2RoomCommandBudget 同时限制房间与节点容量，直接测量并保留不可变编码请求，不接受调用者自报字节数；额度一直计入直到完成/核对后释放。它不会在容量耗尽时再创建等待队列；重复或其他预算实例的 release 不减少计数。后续 dispatch 必须执行 permit 中的同一份请求。

## 实际验证

环境：Apple Swift 6.4，arm64 macOS；不计为 Linux 运行证据。

    swift build --disable-automatic-resolution --package-path IMV2Server \
      --target IMV2ActorContracts --jobs 4
    swift test --disable-automatic-resolution --package-path IMV2Server --jobs 2 \
      --filter 'V2RoomActivationContractTests|V2RoomCommandBudgetTests'

退出码均为 0。契约测试 7 项、容量测试 4 项，共 11 项通过：

- 畸形 wire 不能绕过 epoch、时长、owner、lease 观测时间校验；lease 观测窗口也受一小时时长硬上限约束。
- 完整 token 编解码，owner/activation 代次和 host 重启身份互不替代。
- main 兼容的零 ownerEpoch 与 shard trim 行为。
- 未知写结果、无幂等 ID、只读、授权拒绝、取消和过载的重试分类。
- 配置拒绝无界容量和无法满足的续租/事务时限。
- 热房间满额后健康房间仍能取得余量；100 个并发房间不能超过节点上限。
- 字节限制生效，错误申请不占额。
- 并发 20 次 release 只成功一次，其他预算实例不能归还该 permit。

完整测试输出在本任务宿主 /tmp/imv2-va-c0-runtime-tests.log；可用以上命令重现。构建同时编译了现有 Server 测试依赖，但过滤器只执行这 11 项，不应宣称既有数据库或业务回归已经运行。

## 仍需交付

完整业务 DTO/映射、可信传输、逻辑引用、factory/executor、FIFO/microbatch/lifecycle、真实数据库 lease/fence、所有业务及后台接线和 G2–G5 均待继续。当前生产 composition 尚未启用新目标。

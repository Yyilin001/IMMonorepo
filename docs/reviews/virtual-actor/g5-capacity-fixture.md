# G5 可复现容量夹具（待采样）

> 历史记录说明（2026-10-13）：本文的代码路径、数据库租约/续期描述及测试结论属于文中固定的旧版本，保留作历史证据。当前房间执行使用原生分布式 Actor activation，在线授权使用主动权限传播与 Host–Gateway 共享控制会话；旧房间租约及 Host dirty-head 控制查询链已移除。历史通过或失败不代表当前版本的验证结果。

`IMV2/scripts/prepare_v2_virtual_actor_capacity_fixture.py` 只生成文件，不连接数据库，也不启动默认 local-account Compose。它给现有 `IMV2GatewayLoadGenerator` 写出 `targetRoomIDs`，避免稳态阶段重新 `openDirectRoom`。一份输出供 main 与 candidate 复用；不要分别重新生成密钥/凭证。业务行按各自 checkout 的 `IMV2/sql/schema.sql` 安装到全新 disposable 数据库后，逻辑 UUID、房间成员、owner 分布和凭证映射相同。

示例（输出目录必须不存在）：

```sh
umask 077
python3 IMV2/scripts/prepare_v2_virtual_actor_capacity_fixture.py \
  --output-dir /private/tmp/va-capacity-fixture-v1 \
  --seed 22f741c0-6ebe-4e35-9bc3-23e3c2c3b89a \
  --users 10000 --targets 3 --owners 2 \
  --members-per-room 32 --cold-members-per-room 4 \
  --capacity-profile va-capacity --shard-prefix va-capacity-owner \
  --user-bucket va-capacity-users --command-window-limit 100000000 \
  --expires-at 2030-01-01T00:00:00Z
```

`manifest.json` 记录 seed、计数、owner 分布、每个 layout 的 `credentialMappingSHA256`、`credentialFileSHA256` 和 SQL 摘要。比较 main/candidate 时应复制同一目录并核对 manifest SHA-256；不要用旧 credential prepare/refresh 脚本，它们会丢弃 `targetRoomIDs`。目录是 0700，所有生成文件是 0600。`access-token-hmac-key.base64` 与四个 `credentials.jsonl` 是私密材料；日志、性能报告和 Git 中不得收录它们。把 key 文件内容作为 Gateway 的 `IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64`，不可打印到证据。SQL 仅含 HMAC-SHA256 token 摘要，算法与 `V2AccessTokenHMACKey.digest` 相同。令牌及设备均在固定 `--expires-at` 到期，两个版本须使用同一固定到期日和同一任务私有密钥。

四种 layout 使用同一 user/device/token 身份：`hot` 每个 target 槽位一个共享群；`same-owner` 把多个群放在 owner 00；`mixed` 按群轮转到各 owner；`cold` 用小群产生多房间激活批次。每个连接恰好有 `--targets` 个不同 room ID，并且都是该群成员。`hot` 的最大群是 10,000 人，必须配置足够的 `IM_V2_MAX_ELIGIBLE_MEMBERS`；生成器为超过 5,000 人的群选 `large`。`--capacity-profile`、`--user-bucket`、`--shard-prefix` 须和两版 Gateway/Actor 配置完全一致，`--command-window-limit` 必须等于 `IM_V2_MAX_COMMANDS_PER_WINDOW`，否则业务准入会正常拒绝。manifest 的 `ownerRoomCounts` 用来核对主从库映射及每台 Host 的最大房间数；默认 10,000 用户、3 targets、4 人冷群为 7,500 个房间。

每个 layout、每个 revision 都使用全新数据库，不复用上一轮数据。先用该 revision 的 canonical schema 初始化各数据库。数据库名称必须匹配 `imv2_va_*`；每个数据库再人工写入同一 seed 的 disposable 标记，生成的每份 SQL 都会核查它，缺标记或名称不符即在写入前失败：

```sql
CREATE TABLE public.imv2_disposable_fixture_guard (fixture_id uuid PRIMARY KEY);
INSERT INTO public.imv2_disposable_fixture_guard
VALUES ('85a0e1da-af35-599a-b0ea-b6f4f745bacd');
```

控制库按 `common.sql`、`auth-control.sql`、`<layout>/control.sql` 顺序导入。每个 owner 库按 `common.sql`、`<layout>/owner-NN.sql` 导入。如果控制和 owner 物理共库，`common.sql` 只导入一次，之后导入其余相关文件。通过 `psql -X -v ON_ERROR_STOP=1 -f ...` 执行；标记不由生成器创建，以防意外指向用户数据库。控制库保存认证、设备、public profile、用户路由及 room owner route；owner 库保存 room/group/membership/admission 与相同 public profile/router 初始行。这里的群是容量测试专用直接 SQL fixture，**不代表 TCP create-group 流程验收**。

混合 send/roomLog/receipt 的独立场景是 `IMV2/scripts/virtual-actor-fixtures/mixed-send-roomlog-receipt-canary.json`，不更改既有五个场景的 digest。现有负载器运行时传 `--credentials <layout>/credentials.jsonl --targets-per-connection 3 --peer-topology ring --room-log-reads 1 --scenario <canary JSON>`；`--connections` 不得超过 fixture 用户数，且至少为 targets+1。冷热对照应各自使用全新 schema 和相同身份、连接数、rate 参数。采样窗口、ABBA 顺序与通过阈值仍以 `v1-baseline-protocol.md` 和 `capacity-main-v1.json` 为准，本夹具不提供任何性能通过结论。

真实 Gateway 小型功能 canary 使用 `send-one-canary.json`，在已经接好同一 disposable 数据库的独立 TLS Gateway 栈中运行 **native** `IMV2GatewayLoadGenerator`，不以该报告评估性能：

```sh
IMV2Server/.build/debug/IMV2GatewayLoadGenerator \
  --host localhost --port 7443 --server-name localhost --ca-path "$TASK_CA" \
  --credentials "$FIXTURE/hot/credentials.jsonl" --report "$TASK_PRIVATE_DIR/one-send-report.json" \
  --connections 4 --targets-per-connection 3 --peer-topology ring \
  --ramp-per-second 4 --ramp-batch-size 4 --workload-ramp-per-second 4 \
  --sync-reads 0 --room-log-reads 0 --max-failure-percent 0 \
  --scenario IMV2/scripts/virtual-actor-fixtures/send-one-canary.json
jq -e '.authenticated == 4 and .messagesSent == 1 and .messagesAcknowledged == 1 and .workloadFailed == 0 and .directRoomAttempted == 0' \
  "$TASK_PRIVATE_DIR/one-send-report.json"
```

这项 canary 还应在所选 owner 数据库核对 `im_v2.messages` 总新增恰好一行、`room_id` 在 manifest 的 hot 房间集合内；先前装入的群 SQL 本身不能算真实发送。它故意只排程一条消息，给诊断留出明确的业务边界。

轻量验证：`python3 IMV2/scripts/test_prepare_v2_virtual_actor_capacity_fixture.py`。在任务专属 PG16 中用 main `f1cdd78` 和 candidate `62046f6` 的 canonical schema 分别装入四个 layout，均得到 8 auth devices、16 memberships；room/route 数依次是 hot 2、same-owner 8、mixed 8、cold 4。未加 disposable 标记的同名前缀数据库拒绝 SQL。真实 Gateway 发送与容量数值尚待独占 App 栈/VM 窗口验证。

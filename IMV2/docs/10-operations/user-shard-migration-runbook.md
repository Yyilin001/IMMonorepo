# 用户分片部署范围

新建环境时，用 `IM_V2_USER_SHARD_STORES_JSON` 配置逻辑桶对应的数据库及 schema，并核对默认路由和用户路由覆盖。按[部署准备](../../../IMV2Server/README.md#部署准备)安装当前结构，确认 readiness 后再接入用户。个人状态投递、同步和设备撤销共用这份归属。

运行期间保持映射稳定。当前版本支持新库静态分片；存量用户在线换桶、双写切换及其回滚没有可执行的迁移流程。[当前问题状态](../../../docs/reviews/status.md)

## 固定分片与停机搬迁

本地全新部署预置两个用户桶（users-primary、users-01）和两个房间分片（rooms-primary、rooms-01）。每片占用独立的 PostgreSQL database，初始共享同一主实例。控制库保存用户桶配置、房间归属和各片的 journal source UUID。账户认证等控制数据仍在控制库。首次部署即冻结用户桶清单；扩大物理写入容量时只调整现有分片的数据库地址。首次初始化脚本只适用于空环境，不能直接用它升级已有混合库。

1. 备份控制库和待迁分片，在另一台 PostgreSQL 实例创建空目标库并准备角色、扩展及访问权限。通过 libpq service 文件配置 control、source 和 target 三个连接。生产目标库应先具备所需的副本和故障切换能力。
2. 停止所有应用和后台写入，阻止应用重新连接源库与目标库，将源库默认事务设置为只读并排空连接。迁移期间只允许迁移账户访问这两个库。
3. 执行下列命令。用户片采用 user: 加桶名，房间片直接使用房间分片 ID。脚本核对源身份，整库复制，校验 im_v2 表数据、序列及 journal 身份。失败时保持停机，调查后使用新的空目标库重试。

   ```sh
   python3 IMV2/scripts/copy_v2_offline_shard.py --control control --source source --target target --shard user:users-01
   ```

4. 在所有使用该片的进程中统一修改 IM_V2_USER_SHARD_STORES_JSON 或 IM_V2_ROOM_SHARD_STORES_JSON 中该 ID 对应的 database_url。运维作业也应指向新地址。保留桶清单、房间归属、控制库身份记录及投票节点状态。保持源库封写，重启服务，检查 readiness，并用原账户读取迁移前的房间、发送新消息并验证对端同步后再开放流量。
5. 目标库接受新写入前可停服务并切回源库。目标库接受新写入后，应以它为最新数据源重新停机搬迁；直接切回旧库会遗漏新写入。

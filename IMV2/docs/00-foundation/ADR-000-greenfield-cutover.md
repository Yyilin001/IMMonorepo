# ADR-000：V2 绿地单一当前合同

状态：已接受  
日期：2026-07-23  
最后审阅：2026-08-16
所有者：V2 架构负责人

## 背景

项目尚未上线，没有需要承载的真实用户、设备、本地缓存、数据库记录或已发布客户端。
因此当前代码只维护一个目标合同，不实现旧协议、旧凭据、旧配置或旧 schema 的升级路径。

## 决策

- V2 使用独立 Core、Server、ClientKit、PostgreSQL schema、SQLite schema 和 TLS/protobuf contract。
- PostgreSQL 首次启动只允许在空数据库执行 `IMV2/sql/schema.sql`；仓库不定义其他建库入口。
- ClientKit 只创建当前主 SQLite 与派生搜索 schema；已有布局不升级，由认证同步重建。
- `.env.local` 必须完整匹配当前生成格式；脚本不会追加缺失 secret 或修改旧文件。
- protobuf、数据库字段、DTO 与协议要求缺失时必须失败，禁止以默认值、自由 JSON、双读或降级
  消息猜测当前领域事实。
- 破坏性调整必须在同一提交中更新 schema、Core/protobuf、Server、ClientKit、App、测试和文档。
- 绿地政策不放宽当前合同本身：授权、幂等、事务、持久化、重试、容量 fence 和隐私仍是硬要求。

## 验证与回滚

当前验证以全新状态为边界：

```sh
bash scripts/test_v2_postgres_schema_bootstrap.sh
bash IMV2/scripts/test_v2_local_environment_contract.sh
bash scripts/verify_v2.sh
```

PostgreSQL gate 在一次性空库执行 canonical schema、与规范化 `pg_dump` 精确对比，并确认再次对
非空库执行会失败。SQLite contract test 只验证全新当前 schema。开发环境不匹配时的回滚方式是
显式删除一次性/本地 volume 和本地数据库后重建，不尝试保留未发布数据。

## 后果

- 代码与文档不需要承载已经删除的演进时间线，测试矩阵只覆盖当前合同和故障恢复。
- 任何 retained local volume 都不是升级输入；脚本必须输出明确 reset 命令而非自动修补。
- 首次真实外部测试版或生产用户出现后，本 ADR 的绿地权限终止。届时所有 schema/wire 破坏性
  变更必须由新的 ADR 定义数据迁移、客户端窗口、滚动发布、回滚和兼容验证。

## 复审条件

首次外部测试分发、首次真实数据、需要导入外部数据，或提出多版本并存时立即复审。

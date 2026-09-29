# 服务端模块迁移清单

[JSON 清单](server-module-inventory.json) 当前覆盖 575 个 Swift 文件。运行 `python3 scripts/analyze_v2_server_module_dependencies.py --sync-inventory` 可在搬迁后更新路径和归属。

| 实际 target | 文件数 |
| --- | ---: |
| `IMV2Server` | 15 |
| `IMV2ServerApplication` | 133 |
| `IMV2ServerContracts` | 82 |
| `IMV2ServerGateway` | 27 |
| `IMV2ServerHTTP` | 49 |
| `IMV2ServerInfrastructure` | 269 |

旧 `IMV2Server` target 现只保留配置与组装文件。全部清单条目均按当前实际 target 路径归属；[静态依赖图](server-dependency-graph.md) 用于检查跨层引用，最终仍以 Swift 编译器为准。

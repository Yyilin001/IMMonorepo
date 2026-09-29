# 服务端模块依赖图

运行 `python3 scripts/analyze_v2_server_module_dependencies.py --output docs/proposals/server-dependency-graph.json` 可重建[逐边 JSON](server-dependency-graph.json)；加上 `--sync-inventory` 可同步[迁移清单](server-module-inventory.json)。当前扫描 576 个文件、1951 个唯一顶层声明和 1958 条跨文件符号边。

| 静态检查 | 数量 |
| --- | ---: |
| 分类与实际路径不符 | 0 |
| 禁止的跨层引用 | 0 |
| 跨 target 强连通组 | 0 |

分析会排除注释和字符串，但不执行 Swift 类型检查、动态分派或扩展解析。当前没有静态逆向边；完整文件、符号和首次引用行号见 JSON。编译器仍需验证访问级别与模块导入。

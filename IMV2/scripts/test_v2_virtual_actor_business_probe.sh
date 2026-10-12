#!/usr/bin/env bash
set -Eeuo pipefail

# 原生 Actor 的真实 TCP/SQL 正常退役与重启验收。
# 使用独立控制进程和新建 PostgreSQL；不再运行租约过期接管。
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$script_dir/test_v2_native_actor_business.py" "$@"

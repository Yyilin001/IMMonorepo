#!/usr/bin/env bash
# 仅使用本脚本新建的 PostgreSQL 集群；不会读取业务 DATABASE_URL。
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_bin="${IMV2_ADMIN_TEST_PG_BIN:-/opt/homebrew/opt/postgresql@16/bin}"
for tool in initdb pg_ctl createdb psql; do
  test -x "${pg_bin}/${tool}" || { echo "缺少 ${pg_bin}/${tool}；设置 IMV2_ADMIN_TEST_PG_BIN 指向 PostgreSQL 16 bin" >&2; exit 1; }
done
scratch="$(mktemp -d "/tmp/imv2-admin-test.XXXXXX")"
cleanup() {
  "${pg_bin}/pg_ctl" -D "${scratch}/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "${scratch}"
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
"${pg_bin}/initdb" -D "${scratch}/data" --auth=trust --no-locale --encoding=UTF8 > "${scratch}/init.log"
"${pg_bin}/pg_ctl" -D "${scratch}/data" -l "${scratch}/server.log" -o "-h 127.0.0.1 -p ${port} -k ${scratch}" start >/dev/null
"${pg_bin}/createdb" -h 127.0.0.1 -p "${port}" im_admin_test
"${pg_bin}/psql" -h 127.0.0.1 -p "${port}" -d im_admin_test -v ON_ERROR_STOP=1 -f "${repo_root}/IMV2/sql/schema.sql" > "${scratch}/schema.log"
"${pg_bin}/psql" -h 127.0.0.1 -p "${port}" -d im_admin_test -v ON_ERROR_STOP=1 -f "${repo_root}/IMV2/sql/admin-schema.sql" >> "${scratch}/schema.log"
export IMV2_ADMIN_TEST_DATABASE_URL="postgres://$(id -un)@127.0.0.1:${port}/im_admin_test?sslmode=disable"
export IMV2_ADMIN_TEST_DATABASE_IS_DISPOSABLE=1
swift test --package-path "${repo_root}/IMV2Server" --jobs "${IMV2_ADMIN_TEST_JOBS:-4}" --filter IMV2AdminTests "$@"

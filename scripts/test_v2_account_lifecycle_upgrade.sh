#!/usr/bin/env bash
set -Eeuo pipefail
# Native PostgreSQL only. Uses PGHOST/PGPORT/PGUSER; never opens an existing app DB.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_db="im_v2_account_upgrade_${$}"
upgrade_work="$(mktemp -d)"
created=0
cleanup() {
  if [[ "$created" == 1 ]]; then dropdb --if-exists "$test_db" >/dev/null; fi
  rm -rf "$upgrade_work"
}
trap cleanup EXIT
createdb "$test_db"
created=1
python3 - "$repo_root/IMV2/sql/schema.sql" "$upgrade_work/prior.sql" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('im-v2-current-47', 'im-v2-current-35')
source = '\n'.join(line for line in source.splitlines() if not line.startswith('    credential_revision bigint') and not line.startswith('    recovery_code_hmac text'))
source = source.replace(", 'recovery_code_changed'::text, 'password_changed'::text, 'password_recovered'::text", '')
Path(sys.argv[2]).write_text(source)
PY
psql -X -v ON_ERROR_STOP=1 -d "$test_db" -f "$upgrade_work/prior.sql" >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$test_db" <<'SQL' >/dev/null
INSERT INTO im_v2.account_password_credentials(account_handle, user_id, password_hash, created_at)
VALUES ('upgrade-fixture', '00000000-0000-0000-0000-000000009999', repeat('x', 60), CURRENT_TIMESTAMP);
SQL
psql -X -v ON_ERROR_STOP=1 -d "$test_db" -f "$repo_root/IMV2/sql/upgrades/account-lifecycle-35-to-36.sql" >/dev/null
# This historical 35→36 fixture checks the account change only; it does not
# claim readiness for the current greenfield schema.
[[ "$(psql -X -At -d "$test_db" -c "SELECT count(*) FROM im_v2.account_password_credentials WHERE account_handle='upgrade-fixture' AND password_hash=repeat('x',60) AND credential_revision=1 AND recovery_code_hmac IS NULL")" == 1 ]]
if psql -X -v ON_ERROR_STOP=1 -d "$test_db" -f "$repo_root/IMV2/sql/upgrades/account-lifecycle-35-to-36.sql" >"$upgrade_work/reapply.log" 2>&1; then
  echo 'Upgrade unexpectedly accepted an already upgraded schema' >&2
  exit 1
fi
[[ "$(psql -X -At -d "$test_db" -c "SELECT schema_id FROM im_v2.schema_contract")" == im-v2-current-36 ]]
echo 'Account lifecycle upgrade preserves credentials and rejects reapplication.'

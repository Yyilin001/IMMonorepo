#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

if [[ -f ".env.local" ]]; then
  set -a
  source ".env.local"
  set +a
fi

export DATABASE_HOST="${DATABASE_HOST:-127.0.0.1}"
export DATABASE_PORT="${DATABASE_PORT:-5432}"
export DATABASE_NAME="${DATABASE_NAME:-vapor_auth}"
export DATABASE_USERNAME="${DATABASE_USERNAME:-$(whoami)}"
export DATABASE_PASSWORD="${DATABASE_PASSWORD:-}"
export JWT_SECRET="${JWT_SECRET:-dev-jwt-secret-change-me}"
export SEED_USER_EMAIL="${SEED_USER_EMAIL:-demo@example.com}"
export SEED_USER_PASSWORD="${SEED_USER_PASSWORD:-password1234}"

cat <<EOF
Starting Vapor with:
  DATABASE_HOST=$DATABASE_HOST
  DATABASE_PORT=$DATABASE_PORT
  DATABASE_NAME=$DATABASE_NAME
  DATABASE_USERNAME=$DATABASE_USERNAME
  DATABASE_PASSWORD=${DATABASE_PASSWORD:+***}
  SEED_USER_EMAIL=$SEED_USER_EMAIL
EOF

exec swift run

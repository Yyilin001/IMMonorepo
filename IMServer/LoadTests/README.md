# IMServer Load Tests

These load tests target the private-chat and small-group text IM path only. They do not claim large-group/channel or media delivery capacity.

## Profiles

- `local-smoke`: 100 virtual users, roughly 10 msg/s.
- `staging-baseline`: 10k virtual users, roughly 300 msg/s.
- `capacity-target`: 50k-100k TCP connections and 3k msg/s; run only against isolated capacity infrastructure.

## One-command Baseline

```bash
cd IMServer
./scripts/staging_baseline.sh --profile staging-baseline --env-file LoadTests/staging-baseline.env
```

Create `LoadTests/staging-baseline.env` from `LoadTests/staging-baseline.env.example`. Do not commit real credentials.

## HTTP k6

```bash
cd IMServer/LoadTests/k6
k6 run -e PROFILE=local-smoke -e BASE_URL=http://127.0.0.1:8080 http-small-group.js
```

Required environment:

- `BASE_URL`
- `IM_EMAIL`
- `IM_PASSWORD`
- `IM_MEMBER_EMAILS` as a comma-separated list

Optional environment:

- `IM_CONVERSATION_ID` to reuse an existing conversation
- `IM_INTERNAL_SECRET` to exercise `/internal/im/messages/send`

## TCPDriver

```bash
cd IMServer/LoadTests/TCPDriver
swift run IMTCPLoadDriver \
  --profile local-smoke \
  --base-url http://127.0.0.1:8080 \
  --tcp-host 127.0.0.1 \
  --tcp-port 9001 \
  --email "$IM_EMAIL" \
  --password "$IM_PASSWORD" \
  --conversation-id "$IM_CONVERSATION_ID"
```

Required options:

- `--email`
- `--password`
- `--conversation-id`

## Go/No-Go

- HTTP/TCP error rate below 0.1%.
- `conversations/changes` convergence P95 below 2s.
- Outbox backlog returns to zero or continuously drains after load stops.
- Reconnect `messages/since` success above 99.9%.
- `capacity-target` is not a CI job; it must run in a dedicated environment with a capacity report.

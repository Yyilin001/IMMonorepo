# IM V2

IM V2 is a greenfield messaging system. Its current runtime is composed from
the V2 modules below; no historical protocol, data store, credentials or local
cache participates in this path.

## Components

| Path | Responsibility |
| --- | --- |
| `IMApp/` | iOS SwiftUI application and V2 dependency composition. |
| `IMV2Core/` | Domain types, frame/command rules, admission, fan-out and sync invariants. |
| `IMV2ClientKit/` | Device Keychain session, SQLite sync projection, durable client outboxes and TLS/HTTPS transports. |
| `IMV2Server/` | TLS gateway, PostgreSQL stores, account/device service and loopback-only operator service. |
| `IMV2/` | Numbered SQL migrations, isolated test/local-stack Compose files, scripts, alert rules and design/operations docs. |

## Documentation

- [Current V2 architecture](docs/current-system-map.md): component boundaries,
  durable delivery path, group semantics and NATS limitations.
- [V2 document entry](IMV2/docs/README.md): ADRs, implementation evidence,
  capacity contract and operations runbooks.
- [iOS application](IMApp/README.md): native client workflow and release
  configuration.
- [V2 gateway](IMV2Server/README.md): gateway, account service and operator
  configuration.

## Local development

Run the native iOS client from Xcode. Its isolated local dependencies are
started separately:

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

The stack publishes only `https://localhost:8443` and `localhost:7443` on the
Mac loopback interface. It creates local-only keys and a local CA under
`IMV2/`; import `IMV2/local-ca/root.crt` into the selected simulator before
testing the HTTPS account flow.

## Verification

```sh
# Native ClientKit compile/test target
xcrun --toolchain XcodeDefault swift build --build-tests \
  --package-path IMV2ClientKit --jobs 4

# Core + Server + disposable PostgreSQL regression
docker compose -f IMV2/docker-compose.isolated-tests.yml \
  run --rm --build swift-tests
```

Current release evidence, including limits of local, CI and capacity checks, is
maintained in [implementation status](IMV2/docs/implementation-status.md).

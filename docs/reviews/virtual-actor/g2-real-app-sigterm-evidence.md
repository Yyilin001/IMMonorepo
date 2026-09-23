# G2: busy Actor Host SIGTERM in the real application stack

The opt-in `--remote-gateway --busy-sigterm` mode in
`IMV2/scripts/test_v2_virtual_actor_application_stack.py` runs the existing
Account/Gateway/Operator HTTPS, TLS, and protobuf smoke with Gateway configured
only as a Room Actor caller. An independent Actor Host owns the room lease.

The runner receives a disposable device credential through a private `0600`
fixture, acquires a PostgreSQL row lock on the active room, and observes the
Actor Host's backend blocked by that lock in `pg_stat_activity`. The lock is on
`room_admission`: a `rooms` row lock blocks Gateway's own control lookup before
the request enters the Actor Host. It sends
SIGTERM to the Actor Host at that barrier, immediately cancels its own lock
holder, then checks one durable message and send completion for a stable
client message ID. It observes process exit and the old lease cease to be
live, restarts the Actor Host, and resends the identical operation through the
real Gateway. The replay must return the original message ID without a second
message or completion. The existing Account and HTTP path checks then finish.

The lock holder has a 20-second PostgreSQL sleep as a fail-safe, and each phase
has a bounded wait. The test leaves production SQL lock and call deadlines
unchanged. All credentials, Compose configuration, and database state are
private to the disposable run; the test reports only UUIDs, process/backend
IDs, lease epochs, and phase timestamps. The default runner mode is unchanged.

Execution evidence from the unmodified production binaries at source
`5765185e21ce36fa192ceda782b4eaa3906aa488` plus a rebuilt test probe at
`11b25fd1b9c8736c229d13310e730c61401cc609`:

- Runner `b915ee6e4c97a97da74bf4e53d74d97703a84fb3`, disposable Linux
  `colima-imv2-vapor5` run
  `/Users/yyl/.codex/virtual-actor-builds/application/run-625257c40d6f4cc3816404afb95ef517/result.json`:
  `ACTOR_APPLICATION_STACK_OK`, all Account/Gateway/Operator and HTTP checks
  passed, private project and volumes cleaned. PostgreSQL showed backend 151
  from Actor Host address `172.20.0.5/32` blocked by test backend 242 on the
  admission row. SIGTERM occurred at Unix time `1790181869.400`; the test
  released its row lock at `.466`, observed exactly one message and one send
  completion at `.526`, then observed Actor Host exit code 0 at `.595` and a
  released lease with epoch 1 at `.660`. The Host restart reacquired the room
  at epoch 2. The original Gateway container and process start time were
  unchanged. Its eighteenth request using the same client message ID returned
  the original message ID after `33.28` seconds; the durable counts remained
  one each.
- An earlier 25-second replay window failed after Host restart, with the
  original Gateway returning `UNAVAILABLE` and repeated `Missing Member`
  gossip deserialization warnings. A 120-second window subsequently succeeded
  on the nineteenth attempt in
  `/Users/yyl/.codex/virtual-actor-builds/application/run-190be8b17d934593a72ae84007cf1437/result.json`.
  Thus these runs establish eventual recovery, while exposing a roughly
  30-second recovery tail. They do not establish that gossip decoding alone
  caused that tail.

The frozen build with the gossip fix was rerun from checkout and binary source
`fb7ffdf1c56ff7f3247b0e71c553ef22344a8cf6`. The disposable run
`/Users/yyl/.codex/virtual-actor-builds/application/run-303dc3576e734bcd9bb2967e7fc64a91/result.json`
passed the same complete App stack and cleaned its private project. Actor Host
backend 141 at `172.20.0.5/32` was blocked by admission-lock holder 222 when
SIGTERM was sent at Unix time `1790182606.852`; one message and completion
were visible after unlock, Host exited 0, and the old lease was released at
epoch 1. The original Gateway process stayed running; after Host restart its
eighteenth same-ID retry returned the original message ID in `30.412` seconds,
with one durable message and completion and a new live lease at epoch 2.
`services.log` contains zero `Missing Member for unique node id` errors, versus
two in the comparable prior passing run and 270 in an earlier passing run.

The gossip patch eliminated the observed decode errors in this run. The
original caller still took about 30 seconds to recover, compared with
`33.28` seconds before the patch. This single-run comparison does not prove a
latency improvement. The earlier diagnostic in which Gateway was restarted
before replay is deliberately excluded from acceptance evidence.

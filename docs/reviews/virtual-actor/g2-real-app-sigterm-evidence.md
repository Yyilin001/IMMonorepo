# G2: busy Actor Host SIGTERM in the real application stack

The opt-in `--remote-gateway --busy-sigterm` mode in
`IMV2/scripts/test_v2_virtual_actor_application_stack.py` runs the existing
Account/Gateway/Operator HTTPS, TLS, and protobuf smoke with Gateway configured
only as a Room Actor caller. An independent Actor Host owns the room lease.

The runner receives a disposable device credential through a private `0600`
fixture, acquires a PostgreSQL row lock on the active room, and observes the
Actor Host's backend blocked by that lock in `pg_stat_activity`. It sends
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

Execution evidence: pending the Linux probe rebuild and disposable run.

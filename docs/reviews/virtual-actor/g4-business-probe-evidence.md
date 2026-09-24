# G4 real business probe

Run from the repository root:

    DOCKER_CONTEXT=colima-imv2-vapor5 IMV2/scripts/test_v2_virtual_actor_business_probe.sh

The script builds VirtualActorBusinessProbe with two SwiftPM jobs, starts a
private PostgreSQL 16 container and two separate native OS processes, and
removes only its own container, network and temporary signing/TLS secrets.
Every wait and the build have finite deadlines. The host and caller use the
production V2RoomActorApplication composition, the concrete
V2RoomServerActivationFactory, V2RoomDirectory/V2RoomRef, a temporary CA
with TLS verification, signed Cluster sessions and receptionist discovery.
The database is created from IMV2/sql/schema.sql and one room fixture.

Successful run on 2026-09-23, source base
4281cd1bdde8217a1bbe4be92f3677afa094c3c5:

    G4_BUSINESS_PROBE_OK evidence=/tmp/imv2-va-g4-1790173168-92462-evidence
    G4_EVIDENCE_DIR=/tmp/imv2-va-g4-1790173168-92462-evidence exit=0

The client remained alive while the first host process was SIGKILLed. The
orchestrator waited until PostgreSQL's clock_timestamp() passed the old
lease's expires_at, then started a replacement on the same Cluster endpoint.
The same logical room reference sent a message, pulled its room log and
checked subscription eligibility before the crash. After restart, replay of
the same clientMessageID returned the original messageID; the subscription
still had membership revision 1 and high watermark 1. The replacement had
activation epoch 2 and a different incarnation. A brand-new send bound to
epoch 1 through PostgresV2RoomWriteStore.usingActivationScope was rejected
by the business transaction's SQL fence. PostgreSQL still contained one
message.

The retained evidence directory contains result.json with the room,
operation and message IDs, both epochs and incarnations, subscription
revision/watermark, row count and stale-write rejection flag. old-token.json
contains the first token; lease-expiry.txt records the database-clock wait;
final-sql.txt independently records the final lease row and message count;
processes.txt records native PIDs and SIGKILL. The script checks these files
against each other before printing success. client.log, host-old.log,
host-last.log, fixture/schema install logs and the build log provide the
underlying process output.

This run validates two native macOS processes with real PostgreSQL and Cluster
TLS. It does not claim a Linux Release build, a lost COMMIT acknowledgement, or
the later multi-node fault matrix. The first attempt using an IP literal for
Cluster discovery could not establish TLS: NIOSSL rejects an IP address as
SNI. The successful run uses DNS localhost with a matching private-CA
certificate and retains full certificate verification.

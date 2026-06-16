# IM TCP Realtime Protocol v12

## Scope

HTTP still owns registration, login, refresh, logout, file upload, and normal business DTOs. TCP carries realtime IM presence, delivery, acknowledgements, and server push.

TCP clients authenticate with an HTTP-issued access token during the first packet. Refresh tokens are never sent over TCP.

## Transport

- Protocol: plain TCP behind the existing deployment boundary
- Framing: 4-byte big-endian unsigned length prefix followed by one Protobuf packet
- Encoding: `Protocol/im_realtime/v1/im_realtime.proto`
- Current protocol version: `12`
- Direction: full duplex

Each frame is:

```text
uint32_be payload_length
payload_length bytes of im.realtime.v1.Packet
```

The server rejects frames larger than `IM_TCP_MAX_FRAME_BYTES`, closes malformed streams, closes idle connections after `IM_TCP_IDLE_TIMEOUT`, and sends `kick(protocol_error)` when possible.

## Packet Envelope

Every payload is wrapped in `Packet`:

```proto
message Packet {
  optional string request_id = 1;
  int64 timestamp_ms = 2;
  uint32 protocol_version = 3;

  oneof body {
    AuthRequest auth = 10;
    AuthAccepted auth_ok = 11;
    AuthError auth_error = 12;
    Heartbeat heartbeat = 20;
    Heartbeat heartbeat_ack = 21;
    Ack ack = 31;
    SendMessageCommand send_message = 30;
    ChatDomainEvent domain_event = 40;
    MessageStreamSignal stream_signal = 41;
    Kick kick = 50;
  }
}
```

UUIDs are strings, timestamps are `int64 timestamp_ms`, and `server_sequence` is `uint64`. `Packet.protocol_version` is the only wire protocol version source. Message media fields contain asset references only; uploads stay on the existing HTTP/file path.

## Packet Types

Client to server:

- `auth`: initial authentication handshake
- `heartbeat`: keepalive ping
- `send_message`: client-sent message command
- `ack`: acknowledgement for server-delivered message

Server to client:

- `auth_ok`: authentication succeeded
- `auth_error`: authentication failed and the server will close the connection
- `heartbeat_ack`: keepalive response
- `ack`: acknowledgement for client-sent message
- `domain_event`: server-delivered `ChatDomainEvent` projection from durable outbox
- `stream_signal`: best-effort realtime stream chunk signal, not a durable domain event
- `kick`: server-initiated disconnect notice

## Handshake

The client must send `auth` as the first packet before the auth timeout. `Packet.protocol_version` must be `12`; unsupported versions are rejected. `AuthRequest` does not carry a second protocol version.

On success, the server binds the TCP channel to the resolved `userID`, `sessionID`, and connection metadata, then sends `auth_ok`. On failure, it sends `auth_error` and closes.

## Realtime Relay

Local fanout writes `domain_event` PB packets to active TCP channels. Client commands only receive `ack`; realtime message, conversation, member, and contact changes are emitted by the conversation/contact outbox consumers after durable projection and owner delivery logging. High-frequency AI stream chunks use `stream_signal` and are intentionally excluded from the durable outbox, delivery log, applied-event cache, and owner cursor.

Cross-node Redis dispatch and gateway HTTP relay keep a JSON envelope for observability and routing metadata, but realtime payload data is `packetBase64`, a base64 encoded serialized PB `Packet`. Message content is modeled from the protobuf schema; HTTP/REST still transports JSON DTOs with the same rich-text content shape.

Large active conversations use lightweight realtime events:

- `conversation_activity_hint` carries message identity, sender, sequence targets, optional bounded preview text, and `updated_at_ms`. It is the only active-chat compact message-lite hint for hot rooms. Clients already viewing the conversation can render immediately and then reconcile through targeted `timeline/since`; inactive or list-only clients use conversation changes plus `timeline/since` instead of realtime message fanout.

## Server Structure

1. `IMTCPFrameDecoder`: turns TCP bytes into length-prefixed PB packet bytes.
2. `IMTCPProtobufCodec`: maps PB wire DTOs to existing internal realtime payload structs.
3. `IMTCPConnectionHandler`: owns per-connection state and auth/message dispatch.
4. `IMTCPAuthenticator`: reuses HTTP access-token validation.
5. `IMConnectionRegistry`: maps authenticated connections and writes PB packets to local channels.
6. `ConnectionRoutingService`: fans out locally and relays base64 PB packets across Redis/gateway boundaries.

# IM TCP Protocol Draft

## Scope

This draft keeps the current HTTP authentication model:

- HTTP handles `register`, `login`, `refresh`, `logout`, and session management.
- TCP handles long-lived IM presence, delivery, acknowledgements, and server push.

The TCP layer never receives a refresh token. Clients authenticate the TCP connection
with an HTTP-issued access token during the initial handshake.

## Transport

- Protocol: plain TCP
- Framing: newline-delimited JSON (`NDJSON`)
- Encoding: UTF-8
- Direction: full duplex

Each frame is a single JSON object:

```json
{
  "type": "auth",
  "requestID": "8F8D7A17-635A-41E8-AF1D-74F77CF8981F",
  "timestamp": "2026-04-22T11:00:00Z",
  "payload": {}
}
```

## Packet Types

### Client -> Server

- `auth`: initial authentication handshake
- `heartbeat`: keepalive ping
- `message`: client-sent IM message
- `ack`: acknowledgement for server-delivered message

### Server -> Client

- `auth_ok`: authentication succeeded
- `auth_error`: authentication failed and the server will close the connection
- `heartbeat_ack`: keepalive response
- `message`: server-delivered IM message
- `ack`: acknowledgement for client-sent message
- `kick`: server-initiated disconnect notice

## Handshake

The client must send `auth` as the first packet within a short timeout window.

Example:

```json
{
  "type": "auth",
  "requestID": "8F8D7A17-635A-41E8-AF1D-74F77CF8981F",
  "timestamp": "2026-04-22T11:00:00Z",
  "payload": {
    "accessToken": "<http-access-token>",
    "deviceID": "iphone-yy-main",
    "deviceName": "yy iPhone",
    "platform": "iOS",
    "appVersion": "1.0.0",
    "protocolVersion": 1
  }
}
```

The server validates the access token with the existing HTTP auth service and binds
the TCP connection to the resolved `userID` and `sessionID`.

Success response:

```json
{
  "type": "auth_ok",
  "requestID": "8F8D7A17-635A-41E8-AF1D-74F77CF8981F",
  "timestamp": "2026-04-22T11:00:00Z",
  "payload": {
    "connectionID": "47A5A1D0-0615-4064-8A51-7D2D3BEE5F4C",
    "userID": "F7A56A2A-5A7B-45AB-83E2-6173E11D0E06",
    "sessionID": "24F3E8B6-283E-42D9-B070-8A81E8D1FC3E",
    "heartbeatIntervalSeconds": 30,
    "serverTime": "2026-04-22T11:00:00Z"
  }
}
```

Failure response:

```json
{
  "type": "auth_error",
  "requestID": "8F8D7A17-635A-41E8-AF1D-74F77CF8981F",
  "timestamp": "2026-04-22T11:00:00Z",
  "payload": {
    "code": "invalid_token",
    "message": "当前登录已失效，请重新登录。"
  }
}
```

After `auth_error`, the server closes the connection.

## Keepalive

The client should periodically send:

```json
{
  "type": "heartbeat",
  "requestID": "0F6B1B6B-5B24-48F6-8D5B-063F49C7E3E1",
  "timestamp": "2026-04-22T11:00:30Z",
  "payload": {
    "sequence": 42
  }
}
```

The server responds with `heartbeat_ack` and updates the connection's last-seen time.

## Message Delivery

Client send:

```json
{
  "type": "message",
  "requestID": "C5F3ED8A-6A97-47C1-9E46-2A8A94A4A32C",
  "timestamp": "2026-04-22T11:01:00Z",
  "payload": {
    "clientMessageID": "msg-client-1001",
    "conversationID": "conv-42",
    "kind": "text",
    "body": {
      "text": "hello"
    }
  }
}
```

Server acknowledgement:

```json
{
  "type": "ack",
  "requestID": "C5F3ED8A-6A97-47C1-9E46-2A8A94A4A32C",
  "timestamp": "2026-04-22T11:01:00Z",
  "payload": {
    "messageID": "srv-msg-9001",
    "conversationID": "conv-42",
    "status": "accepted"
  }
}
```

Server push uses the same `message` packet type, and the client returns an `ack`
for delivery confirmation.

## Kicks

The server may send a `kick` before closing a connection:

- `session_revoked`
- `logout_current`
- `logout_all`
- `duplicate_connection`
- `server_shutdown`
- `protocol_error`

This bridges existing HTTP session management with the TCP channel lifecycle.

## Server Structure

The server should be split into these layers:

1. `IMTCPServer`
   Accepts TCP connections and owns the `ServerBootstrap`.
2. `IMTCPFrameCodec`
   Turns inbound bytes into packet envelopes and outbound packets into NDJSON frames.
3. `IMConnectionHandler`
   Maintains per-connection state: unauthenticated, authenticated, closing.
4. `IMTCPAuthenticator`
   Reuses the current `AuthService.authenticateAccessToken(...)` path.
5. `IMConnectionRegistry`
   Maps `connectionID -> connection metadata` and `sessionID -> active connections`.
6. `IMSessionRevocationBridge`
   Allows HTTP logout/logout-all to locate and disconnect matching TCP connections.
7. `IMMessageService`
   Owns domain logic such as send, fanout, ack processing, and delivery state.

## Recommended First Implementation

- Start one TCP port dedicated to IM, separate from Vapor HTTP.
- Require auth as the first packet.
- Bind one authenticated connection to one server-side `sessionID`.
- On HTTP logout of the current device, disconnect connections for that `sessionID`.
- On HTTP logout-all, disconnect every connection for that `userID`.
- Do not refresh tokens over TCP. Keep refresh on HTTP only.

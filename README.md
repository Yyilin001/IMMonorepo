# IM Monorepo

This repository contains the iOS client, reusable client SDK package, and Vapor backend for the IM system.

## Projects

| Path | Purpose |
| --- | --- |
| `IMApp/` | iOS application. Keeps SwiftUI screens, TabView, app lifecycle, and app-level orchestration such as `AuthManager`. |
| `IMClientKit/` | Swift Package SDK used by `IMApp`. Contains authentication/session models, HTTP/TCP networking, contacts, friend requests, IM conversation state, SwiftData cache, and file transfer clients. |
| `IMServer/` | Vapor backend. Provides authentication, contacts/friend requests, conversation APIs, TCP IM server, message persistence, read state, and file APIs. |

## Local Development

Default local endpoints:

- HTTP API: `http://127.0.0.1:8080`
- IM TCP: `127.0.0.1:9000`

Run the backend:

```sh
cd IMServer
swift run
```

Run package tests:

```sh
cd IMClientKit
swift test
```

Build the iOS app for testing:

```sh
xcodebuild \
  -project IMApp/IMApp.xcodeproj \
  -scheme IMApp \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build-for-testing
```

Run backend tests:

```sh
cd IMServer
swift test --no-parallel
```

## Architecture Boundary

`IMClientKit` is the reusable client SDK boundary. It should not import SwiftUI and should not depend on app-only constants. App-specific configuration is injected from `IMApp`.

`IMApp` owns UI and application orchestration. Views and `AuthManager` consume public SDK APIs from `IMClientKit`.

`IMServer` remains the protocol and persistence authority. Client package extraction must not change HTTP/TCP protocol semantics unless a backend change is planned in the same phase.

## Monorepo Rules

- Keep cross-project changes in one branch when a feature requires client SDK, app, and server changes together.
- Do not reintroduce copied SDK source files into `IMApp`; shared client logic belongs in `IMClientKit`.
- Keep generated build outputs out of git.
- Prefer adding tests in the layer that owns the behavior:
  - SDK/network/store tests in `IMClientKit/Tests`.
  - App orchestration/UI-adjacent tests in `IMApp/IMAppTests`.
  - API/service/database tests in `IMServer/Tests`.


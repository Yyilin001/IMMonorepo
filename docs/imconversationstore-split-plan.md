# IMConversationStore Split Plan

`IMClientKit/Sources/IMClientKit/Features/IM/IMConversationStore.swift` is a
legacy merged read-model store. The production governance budget records the
current baseline so CI can enforce no further growth while the split is done in
reviewable steps.

## Current Baseline

- Current size: 4728 lines.
- Active budget: 4800 lines.
- Owner: `imclientkit-im-store-owner`.
- Category: `domain-store`.

## Split Targets

1. Move domain-event projection orchestration into a dedicated store extension
   or helper that owns event cursor, deferral, replay, and high-watermark state.
2. Move outgoing-message queue and acknowledgement handling behind a focused
   outgoing message coordinator.
3. Move timeline catch-up diagnostics and timeline sync bookkeeping behind a
   small timeline catch-up state object.
4. Keep SwiftUI-facing accessors on `IMConversationStore`; do not move TCP
   packet parsing, HTTP DTO mapping, or persistence details into UI code.

## Review Rules

- Do not raise the 4800-line budget for feature work.
- New IM conversation behavior should first land in existing reducers,
  coordinators, or small helpers.
- Each split step must keep public `IMConversationStore` APIs compatible and run
  the IMClientKit or iOS build/test target that covers the touched surface.

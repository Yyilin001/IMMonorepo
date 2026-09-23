# Local Swift 6.4 compatibility patch

This directory preserves PostgresNIO 1.33.1 at revision
`39ce38a93408937bcd27f521f3cdf88266136b80`. `UPSTREAM.json` records the included
files and their SHA-256 checksums. Original `LICENSE` and `NOTICE.txt` apply.

Only `AuthContext.==` in `ConnectionStateMachine.swift` differs from the
upstream source. Swift Collections 1.6's experimental `BorrowingSequence_`
introduces an `elementsEqual(_:by:)` overload that is ambiguous on the released
Swift 6.4 Linux toolchain. After the existing count check, an explicit loop
compares every ordered key/value pair and returns false on the first difference.
It preserves equality semantics, including ordering and duplicate keys.

Collections 1.7 is not an alternative for this dependency graph: its preview
API changes remove `Optional.borrow()`, still used by AsyncStreaming 1.1.5.
All other upstream source, manifest and tests are unchanged. SwiftPM's root
local dependency overrides the remote PostgresNIO identity transitively, so
normal builds require no edits to `.build` or network-hosted fork.

Remove this directory and restore the remote dependency when a tagged upstream
version compiles with the pinned Vapor dependency graph. Re-run Linux builds,
PostgreSQL session/transaction tests and the application compatibility gates
before changing the pin.

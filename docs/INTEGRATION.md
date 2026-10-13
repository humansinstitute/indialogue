# Future Tower integration seam

No networking, authentication, Tower configuration, or upload behavior is implemented.

The durable local boundary is `RecordingStore` and the version-1 `Recording` manifest. Each record owns a UUID directory containing `metadata.json` and ordered AAC segments. UUID identity survives rename, recovery, transcription and export. Metadata includes schema version, title, creation time, lifecycle state, segment paths, readable audio duration, human-readable route/interruption/recovery events, and optional transcript/locale. Relative segment paths remain internal to the sandbox.

A future adapter should read a saved/interrupted recording by UUID, snapshot its manifest, and request an export through the audio assembly boundary currently exposed by `RecorderModel.export`. The adapter must preserve local source files and retain the UUID as its idempotency key. Export may omit unreadable segments with a notice: future upload must record this incompleteness explicitly and obtain the intended user's decision. Do not upload active captures or use a display title as identity.

Define transport and workspace credentials only from the future authoritative Tower contract. Keep connection configuration separate from recording metadata. Add a separate durable transfer ledger keyed by local recording UUID plus export/content version, with workspace/remote identity, attempt/result timestamps, checksum and retry state. A local rename/transcript change should not implicitly duplicate audio upload. Treat deletion and remote retention as distinct explicit user operations. Nothing in this release defines endpoint URLs, authorization headers, service accounts, tokens or remote deletion policy.

Before integration, introduce a typed snapshot/export service independent of SwiftUI and version the manifest schema with migration tests. Existing `schemaVersion: 1` and stable UUIDs are the compatibility anchors. Capture and local library use must continue working without a workspace connection.

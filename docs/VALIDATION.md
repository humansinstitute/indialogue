# Validation

Use Xcode 26.3 with iOS 26.3 simulator runtime. Build output and operational evidence are ignored; do not commit private device data or recordings.

```sh
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

Use an existing suitable simulator. The UI tests never tap Record or import real identities; the transcript-review fixture is DEBUG/simulator-only and uses a fresh isolated temporary library.

```sh
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -derivedDataPath build-v2 \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES -parallel-testing-enabled NO \
  -resultBundlePath tmp/docs/handoffs/Tests.xcresult test
```

Coverage includes v1 manifest migration with byte-for-byte audio retention, queue recovery without losing edits/drafts/vocabulary, capture/export/interruption recovery, deterministic correction boundaries/case/punctuation/non-cascade, exact word occurrence edits and long Unicode chunk retention, draft accept/reject with raw text retention, vocabulary CRUD, synthetic nsec validation and vault encryption/unlock/wrong-PIN/tamper/replacement/removal, fake-speech automatic save/installed-only/failure/manual-download/cancel/delete/capture-priority/relaunch/foreground/concurrent-edit lifecycles, and minimal home/menu/secure-field/review UI smoke. Vault tests inject an in-memory secret store and only public synthetic scalar fixtures; they never read user Keychain data. Speech tests use fake services and generated silent AAC rather than microphone hardware or actual downloaded models.

Build 12 adds injected background-session coverage without user data or live storage: a foreground presigned PUT survives the app background transition without cancellation; ordered file callbacks update the correct ledger entry and finalize once; relaunch attaches the existing task without another prepare or PUT; interruption persists a retryable same-object state; locked and mismatched identities pause signed finalization until the correct unlock; stale/unknown callbacks are harmless; and the app delegate completion gate waits for event draining. The full suite continues to cover foreground fallback uploads, stable object/request IDs, completed-object reuse and ambiguous message recovery.

Run a passing suite again only for changes, failures or unresolved concerns. Build logs, xcresult attachments, screenshots and device evidence belong in ignored `tmp/docs/handoffs/`. Xcode's AppIntents metadata extraction warning is expected without an AppIntents dependency; unsigned tests may report that Apple-signed XCTest libraries are not stripped.

Required physical checks remain unverified:

- Start after first unlock; lock for several minutes and background across multiple 15-second boundaries. Listen to the entire shared m4a, noting possible segment-boundary gaps.
- Test built-in mic and supported Bluetooth/wired inputs; verify actual route and data source match iOS routing, including connect/disconnect during capture.
- Trigger a phone/Siri/alarm interruption and media-services reset where practical; confirm visible warning, retained files and explicit restart behavior.
- Test near-full storage, write failures and abrupt termination while capturing; recover earlier segments and inspect incomplete final segments. Force quit is not a continuation guarantee.
- Install a model only after explicit consent; transcribe a long recording on a supported iOS 26 device, then repeat offline with the installed model. Test unsupported locale/device behavior.
- Exercise word tapping, vocabulary, draft accept/reject, synthetic identity import/lock/background retention/unlock/remove, playback, share, rename/delete confirmation, VoiceOver, large Dynamic Type, and landscape on the phone. Simulator smoke is not a full accessibility audit.
- Start an automatic upload on a physical phone with a realistically long recording, immediately lock/background the app, and verify the file reaches private storage without reopening. Repeat through temporary network loss, then unlock/reopen and verify completion/readback and exactly one channel message. Force-quit separately and confirm the UI honestly reports recovery/retry after relaunch; force-quit is not expected to continue or relaunch background delivery.

Rick owns signed installation and physical review. The implementation worker performs no phone installation, microphone capture, real-secret import, model reset, or service restart.

NStack tests use URLProtocol mocks and injected public synthetic signers. Coverage includes exact authentication URL/method/payload bytes, immutable reviewed-text snapshots, old-library exclusion, automatic transcription/vocabulary ordering, kind33358 body/hash/mention construction, private prepares, completion read-back, ambiguous message recovery with stable object/request IDs, uncertain prepare refusal, locked/identity pauses and incomplete-source refusal. A synthetic scalar-one signed Nostr event is retained as an xcresult attachment for independent nostr-tools verification. Menu setup/history smoke captures screenshots without importing secrets or using the microphone.

Build 9 adds focused coverage for persistent Normal / Channel / Agent selection, immutable capture-route round trips, channel payloads without agent mentions, canonical agent visible/structured mentions, initial thread creation, exact signed `thread_id` follow-ups, stable same-conversation IDs, newest reply/audio attachment parsing, and locked foreground-only reply reads. The minimal home UI smoke requires the mode selector and route control without tapping Record. Live agent response timing, private audio download, synthesized speech quality and repeated Respond turns remain phone/workspace checks.

Build 10 adds the live Tower message envelope to reply regressions: `deleted_at: null`, active/deleted record state, recorder metadata, fractional timestamps, inherited/read-only provenance, encoded multi-page cursors, authorized audio selection, empty pages and malformed active rows. A contract failure must show an error; only a valid empty effective thread may show “No new reply yet.”

Build 11 adds deterministic reply-poll lifecycle coverage with injected scheduling: immediate activation/resume reads, bounded 20-second scheduling, inactive stop, single-read overlap exclusion and reply-ID deduplication. Played reply IDs persist across restart so auto-play happens once. Response lifecycle coverage holds a same-thread post in flight and verifies pending/sending are not treated as success, a failed post remains unsent and retryable, and only the accepted retry persists Responded across restart. Shared-setup coverage starts from a legacy Normal-only ledger, reuses only a valid matching signer/origin/workspace for new Channel/Agent setup, preserves an existing mode route, and confirms no implicit route persistence or conversation retargeting.

The pinned package uses a build plugin to copy shared Swift sources. Review the pinned plugin before using `-skipPackagePluginValidation` in unattended builds; interactive Xcode can approve it normally. Keep Package.resolved tracked. Use separate derived-data directories for concurrent destinations to avoid mixed-architecture package artifacts. Live permissions, presigned S3 behavior, receiving-agent execution, phone signing and signed in-place installation require managerial validation.


Upload repair coverage includes strict numeric/string byte-count boundaries, malformed/bool/fraction/overflow refusal, size/checksum/completion errors, local snapshot tamper refusal, and restart of a failed job whose audio is already completed remotely. The retry fixture verifies no second audio PUT or prepare, unchanged snapshot request/body/destination/object IDs, and string metadata on the transcript upload completion read-back. Recording Upload retries an existing snapshot without another export. Injected identity tests reopen the unchanged vault envelope, reject wrong PINs and require authentication. Simulator-only synthetic unlock UI checks launch prompting, optional dismissal without a loop, foreground over an existing menu, wrong/correct PIN, navigation retaining unlock and background retaining authentication, explicit lock and cold launch requiring PIN. Synthetic secrets use memory storage and an isolated vault; no user Keychain or phone credentials are used.

Discovery regressions cover canonical agent identity overriding legacy presentation actors, visibility/instruction/archive flags, title/name fields, generated DM participant names, multiple scopes, more than the default 50 channels, encoded continuation cursors, cursor loops, capped unpageable responses, directory failure versus empty success, optional member-label denial, and saved selection IDs/labels. Protocol tests use mocks; broker-authorized reads confirm only the broker identity's accessible records. They do not verify the imported phone identity's permissions or agent execution.

Additional discovery coverage exercises 251 channels from sync metadata while message snapshot pagination remains incomplete, directly granted `/me.visible` channels omitted from scope traversal, intentional DM names, and keeping a successful agent directory when later channel reads fail.

Build 7 recorder feedback regressions cover delayed preferred-input selection, a one-second bounded fallback that retains the actual input, interruption during selection, duplicate actual-route notifications, stopped/empty-input detection even on duplicates, data-source changes, and bounded level history across segment samples, pause, stop and restart. The DEBUG/simulator-only `--synthetic-meter` fixture uses an isolated temporary library and deterministic levels without microphone capture. Its UI test retains a screenshot and checks the actual-input label and absence of routine alerts.

For physical review of this update, select AirPods before starting and confirm the visible actual route and `Started with` diagnostic agree with the recorded sound. Repeat with AirPods unavailable and disconnect/reconnect during capture; distinct routes should remain in diagnostics without routine alerts, while lost capture must warn and retain segments. Speak and pause across several 15-second boundaries, checking the level history and exported audio. Background/lock must continue capture with visual metering suspended; foreground starts fresh history. Check VoiceOver, Reduce Motion, large text and landscape. Simulator regressions do not establish Bluetooth timing, power consumption, audio pickup, or background continuity on the phone.

Apple references: [recorder metering](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/ismeteringenabled) and [microphone selection](https://developer.apple.com/library/archive/qa/qa1799/_index.html). Input preference is a request; the current route is the source of truth.

Build 8 retention coverage uses isolated temporary libraries and isolated preferences: disabled default, saved enabled/day count, strict 1–3650 validation, corrupt preference fail-closed, exact creation-time cutoff, future timestamps, protected-data/background/capture/playback/sharing exclusions, queued/running speech, cancelled-but-still-running speech/cleanup, all unfinished upload states and intents, unreadable-ledger refusal, local artifact removal including transcript-bearing finished delivery ledger entries, and deletion failure/retry. No tests delete user recordings or make cloud deletion requests. A DEBUG/simulator-only `--synthetic-retention` fixture verifies Settings validation, save, navigation persistence and local/workspace wording, with a screenshot attached to xcresult. Rick's signed device review should verify saved preferences survive cold launch, disabled settings preserve the library, and protected-data/lifecycle behavior on the phone; actual library deletion requires Pete's chosen policy.

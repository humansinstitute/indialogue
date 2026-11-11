# Android validation

Run local JVM checks, lint and both APK builds:

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease
```

Unit fixtures use only public synthetic scalars, the official BIP340 vectors, temporary directories and a local TLS MockWebServer. They never access a user's identity or a live NStack workspace. ACINQ's API accepts 32-byte digests: the original 15 BIP340 positive/negative vectors exercise signing/verification; later variable-length-message vectors explicitly verify this API rejects unsupported lengths. Nostr always signs a 32-byte SHA-256 event ID.

Checks cover correction boundaries/case/phrases/noncascade and occurrence edits, Unicode chunk retention, atomic recovery with corrupt-manifest isolation, retention cutoffs/exclusions, nsec/scalar/PIN validation, encryption/tamper/wrong-PIN/cold-launch behavior, exact NIP-98 payload signatures, canonical agent mentions and kind33358, immutable exports, strict storage size metadata, private prepares, completion readback, completed-object reuse on message retry, stable request IDs, uncertain-prepare refusal, altered snapshots and redirect refusal.

Run native tests on an isolated emulator, never a personal device:

```sh
./gradlew connectedDebugAndroidTest
```

Native tests decode and concatenate a synthetic spoken AAC asset, check complete-export refusal versus explicitly partial sharing, and exercise the real Android Keystore with isolated test envelopes. The asset is generated speech: “The quick brown fox jumps over the lazy dog. One two three four five. This is a test of offline speech recognition.” It contains no personal audio.

## Explicit real-model check

The model test is opt-in and uses installed model files, with no network fallback. On an isolated emulator, download the exact public model URLs and hashes from `Models.kt`, then stage the two files in the target app's `no_backup/validation-fixtures/` as `dialogue-vosk.zip` and `dialogue-qwen.gguf`. Use `adb push` into `/data/local/tmp`, then `run-as com.wingmanbefree.indialogue` to copy them into that app-private fixture directory. Grant read access only to the synthetic test files. Run:

```sh
./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.modelSmoke=true
```

This verifies model digests, installs only into a unique isolated test directory, runs actual Vosk across two spoken AAC segments, and runs actual JNI llama.cpp/Qwen cleanup. `MODEL_EVIDENCE` output contains the real transcript/draft. Fixtures are removed from the test directory on completion. Delete the staged validation fixtures separately after review. Passing mocked queue/UI checks does not count as model inference evidence.

## Runtime review

On a fresh emulator install, check first-run permission denial/grant, actual input, elapsed timer, level history, 15-second segment rotation, notification Stop and save, background capture, library playback/export, app force stop/reopen recovery, model absence/failure/retry, settings persistence, identity locked launch/unlock/wrong PIN/background retention/manual lock and NStack setup/history. Capture UI hierarchy and screenshots in an ignored evidence directory. Screenshots may be protected by Android's secure-window policy; hierarchy/native assertions remain available.

Emulator results do not establish Bluetooth routing timing, phone interruptions, battery/OEM background restrictions, hardware power use or physical microphone quality. Live authenticated NStack permissions, presigned object storage and receiving-agent execution require a separate authorized review with a user's test identity. Release certificate creation, in-place signed upgrade, public repository and Zapstore publication belong to the release owner.

For an explicit real network download/cancel/removal check on the isolated emulator, enable networking and run `ModelDownloadTest` with `-e downloadSmoke true`. It downloads the pinned speech ZIP through the actual application downloader, validates installation, removes it, starts the pinned cleanup model download and cancels after receiving bytes. It asserts no incomplete cleanup model is installed. `DOWNLOAD_EVIDENCE` is operational output; do not add it to product source.

Lifecycle tests use real Android app/controller coroutines with injected slow speech and delivery engines. They establish selected-job cancellation ownership, cancellation across foreground cycles, explicit retry of the same immutable transfer through both entry points, active-record metadata protection and pending-playback invalidation. They are separate from real offline model inference and from real authenticated NStack delivery.

## iPhone parity regressions

`ParityTest` covers old manifest/ledger defaults, independent route persistence, immutable audio-only artifacts, microphone selection verification, automatic-upload opt-in in all modes, cancelled/failed/accepted response lifecycle, eligible accepted-thread polling, shared TTS initialization after a cancelled waiter, and bounded closed-schema private diagnostics with durable retry and deletion of finished local reports. `NStackTest` also covers thread-bound follow-up signatures, reply pagination preserving the effective thread query, authenticated audio fetch, locked-identity refusal and redirect refusal.

`ParityUiTest` captures the home/menu/setup/settings/voice/recording screens and exercises missing-route recovery and explicit audio-only stop without requiring a speech model. `ReplyLifecycleTest` uses synthetic replies and generated speech audio with the real Android MediaPlayer to exercise preferred audio, stop/background cleanup, unique playback cache ownership, persisted autoplay history, locked/pending-capture gates and refresh through a failed follow-up. Synthetic loading hooks are internal and default to the real authenticated NStack transport. These tests do not establish live receiving-agent execution.

For a screenshot review, instrumentation temporarily clears `FLAG_SECURE` only on the isolated emulator activity and restores it in `finally`. Production app windows retain secure capture protection. Compare with the unchanged SwiftUI app on a separate simulator; reference tests include minimal home/menu, NStack setup/history and large conversation controls. Android retains its native system insets, dialogs, back behavior and installed TTS engines.

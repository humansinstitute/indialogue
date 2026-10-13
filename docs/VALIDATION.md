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

Run a passing suite again only for changes, failures or unresolved concerns. Build logs, xcresult attachments, screenshots and device evidence belong in ignored `tmp/docs/handoffs/`. Xcode's AppIntents metadata extraction warning is expected without an AppIntents dependency; unsigned tests may report that Apple-signed XCTest libraries are not stripped.

Required physical checks remain unverified:

- Start after first unlock; lock for several minutes and background across multiple 15-second boundaries. Listen to the entire shared m4a, noting possible segment-boundary gaps.
- Test built-in mic and supported Bluetooth/wired inputs; verify actual route and data source match iOS routing, including connect/disconnect during capture.
- Trigger a phone/Siri/alarm interruption and media-services reset where practical; confirm visible warning, retained files and explicit restart behavior.
- Test near-full storage, write failures and abrupt termination while capturing; recover earlier segments and inspect incomplete final segments. Force quit is not a continuation guarantee.
- Install a model only after explicit consent; transcribe a long recording on a supported iOS 26 device, then repeat offline with the installed model. Test unsupported locale/device behavior.
- Exercise word tapping, vocabulary, draft accept/reject, synthetic identity import/lock/background/unlock/remove, playback, share, rename/delete confirmation, VoiceOver, large Dynamic Type, and landscape on the phone. Simulator smoke is not a full accessibility audit.

Rick owns signed installation and physical review. The implementation worker performs no phone installation, microphone capture, real-secret import, model reset, or service restart.

NStack tests use URLProtocol mocks and injected public synthetic signers. Coverage includes exact authentication URL/method/payload bytes, immutable reviewed-text snapshots, old-library exclusion, automatic transcription/vocabulary ordering, kind33358 body/hash/mention construction, private prepares, completion read-back, ambiguous message recovery with stable object/request IDs, uncertain prepare refusal, locked/identity pauses and incomplete-source refusal. A synthetic scalar-one signed Nostr event is retained as an xcresult attachment for independent nostr-tools verification. Menu setup/history smoke captures screenshots without importing secrets or using the microphone.

The pinned package uses a build plugin to copy shared Swift sources. Review the pinned plugin before using `-skipPackagePluginValidation` in unattended builds; interactive Xcode can approve it normally. Keep Package.resolved tracked. Use separate derived-data directories for concurrent destinations to avoid mixed-architecture package artifacts. Live permissions, presigned S3 behavior, receiving-agent execution, phone signing and signed in-place installation require managerial validation.

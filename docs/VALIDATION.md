# Validation

Use Xcode 26.3 with iOS 26.3 simulator runtime. Build output and operational evidence are ignored; do not commit private device data or recordings.

```sh
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  CODE_SIGNING_ALLOWED=NO build
```

Create/boot a suitable simulator or use an existing one. For the denial smoke test, revoke microphone permission explicitly before running tests; this test intentionally captures no microphone audio:

```sh
xcrun simctl privacy SIMULATOR_ID revoke microphone studio.otherstuff.PeteRecorder
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath tmp/docs/handoffs/Tests.xcresult test
```

Tests cover atomic intent recovery/idempotence and retained unreadable segment references, saved metadata/rename/transcript/deletion, corrupt manifest isolation without destructive cleanup, playable m4a export from two synthetic one-second AAC segments, plus duration recovery and export salvage with a missing final segment, stop finalization, simulated interruption persistence, and UI launch/microphone denial/relaunch. Synthetic silence tests validate container assembly, not microphone hardware, route quality or SpeechTranscriber accuracy. UI attachments remain in ignored result bundles.

Initial implementation validation passed unsigned simulator/device builds and all 7 focused simulator tests (6 persistence/audio/lifecycle tests and 1 UI smoke test), with zero failures. Operational logs and screenshots stay in ignored handoffs. Xcode's AppIntents metadata extraction warning is expected because this app has no AppIntents dependency; unsigned test builds may also report that Apple-signed XCTest libraries are not stripped.

Required physical checks remain unverified:

- Start after first unlock; lock for several minutes and background across multiple 15-second boundaries. Listen to the entire shared m4a, noting possible segment-boundary gaps.
- Test built-in mic and supported Bluetooth/wired inputs; verify actual route and data source match iOS routing, including connect/disconnect during capture.
- Trigger a phone/Siri/alarm interruption and media-services reset where practical; confirm visible warning, retained files and explicit restart behavior.
- Test near-full storage, write failures and abrupt termination while capturing; recover earlier segments and inspect incomplete final segments. Force quit is not a continuation guarantee.
- Install a model only after explicit consent; transcribe a long recording on a supported iOS 26 device, then repeat offline with the installed model. Test unsupported locale/device behavior.
- Exercise playback, share, rename/delete confirmation, VoiceOver, large Dynamic Type, and landscape on the phone. Simulator smoke is not a full accessibility audit.

The paired physical phone was inspected read-only. It was not installed onto or launched.

# In Dialogue for Android

Native Kotlin / Jetpack Compose app, package `com.wingmanbefree.indialogue`, Android version 1.1.0 (version code 2). Android 9 (API 28) or newer, arm64 and x86_64. Targets Android 16 (API 36). iOS remains a separate native app.

## Build

Install JDK 17+, Android SDK platform 36, build tools 35.0.0, NDK 28.2.13676358 and CMake 3.22.1. Set `ANDROID_HOME` to the SDK or write an ignored `local.properties` with `sdk.dir=...`.

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug assembleRelease
```

Gradle 8.13 wrapper checks the distribution SHA-256. Direct dependencies are pinned in `app/build.gradle.kts`. CMake downloads llama.cpp commit `a7a98e0fffed794396b3fbad4dcdbbc184963645` and validates its archive SHA-256. The first build needs network access to Maven/Google/GitHub. Release APK is unsigned unless the release owner supplies all four environment variables: `IN_DIALOGUE_KEYSTORE`, `IN_DIALOGUE_STORE_PASSWORD`, `IN_DIALOGUE_KEY_PASSWORD`, and `IN_DIALOGUE_KEY_ALIAS`. These configure signing without saving secrets in Gradle/source. The release owner keeps the durable certificate outside this tree. Never include a publisher nsec, user nsec, keystore, signing password, operational recording or model binary in source or APK.

Install debug on an isolated emulator with `./gradlew installDebug`. Instrumented tests use `./gradlew connectedDebugAndroidTest`; see `VALIDATION.md` for model testing prerequisites.

## Local data and Android limits

The library, vault, models and delivery ledger use app-private `noBackupFilesDir`. Android backup is disabled. Export/share uses temporary app cache and scoped FileProvider URI grants. Uninstall deletes all app data. Update in place with the same package and certificate. Export important audio/transcripts and keep your own Nostr key backup separately.

Start microphone capture while the activity is visible and grant microphone permission. A foreground microphone service and notification continue capture in the background. AAC mono segments rotate about every 15 seconds; boundary gaps can occur. Manifests name segments atomically before opening audio files. The app stops on interruption, disconnection, recorder errors or storage below 20 MiB and retains earlier segments. Force stop, reboot, OS termination and final-segment corruption do not guarantee continued capture. Recovery retains references and isolates corrupt manifests without deleting audio. Android chooses the actual input; a selected input must be verified against that route or capture stops and retains audio. System default is an explicit opt-in to default routing.

Speech, cleanup, downloads and authenticated delivery run only while foreground and capture is idle. Their cancellation yields to capture. Speech queue and upload ledger survive process death. Failed work requires explicit retry. Downloads are never automatic. Interrupted downloads discard incomplete models. Model removal retains recordings. Optional cleanup produces an untrusted draft with explicit accept/reject; raw transcript and current edits remain separate. Review all names, numbers and meaning.

Retention is disabled by default. An enabled 1–3650 day policy applies to existing eligible recordings after an explicit warning. Age uses creation time. Capture, playback, export, speech/cleanup and unfinished uploads/intents protect local data. Corrupt ledgers/settings fail closed. Only local data and finished snapshots are deleted; remote storage/messages remain. Android does not run retention while closed.

Identity import validates Bech32 checksum, padding and secp256k1 scalar; PIN is 4–12 ASCII digits. AES-256-GCM encrypts the user secret using PBKDF2-HMAC-SHA256 (210,000 iterations, random salt, PIN plus random installation secret). The installation secret is separately encrypted by a nonexportable Android Keystore AES-GCM key. No PIN or plaintext nsec is persisted or logged. Wrong PIN leaves vault unchanged. Process-memory unlock survives background until explicit Lock, removal or process exit. Android/JVM temporary copies cannot be guaranteed physically erased. No publisher identity is bundled.

## NStack

Use your own imported identity, an HTTPS origin, a discovered workspace and channel/DM, and a meaningful prompt. Canonical receiving agents come from the workspace agents directory; member labels only name DMs. A directory denial exposes an explicit canonical npub field. Automatic delivery is opt-in and applies only to future saved recordings; existing library items require Upload.

Immutable exports contain full raw and reviewed transcripts, full AAC audio, capture metadata, checksums, original destination and stable request ID. Unaccepted cleanup drafts stay local. Private workspace prepare is persisted before PUT; ambiguous prepare refuses duplicate allocation. API fallback upload is limited to 8 MiB. Presigned PUT carries no Nostr auth. Complete requires metadata readback with exact size and SHA-256; these checksums are server lifecycle metadata, not an independent remote byte digest. Signed calls stay at the selected HTTPS origin and refuse redirects. Kind 27235 binds exact URL/method/body bytes; kind 33358 binds exact instruction/body hash/workspace/channel. Visible canonical mentions and structured mentions derive from the same identity.

Retry retains the original snapshot, destination, signer, object IDs and message request ID. Completed remote objects are revalidated and reused. Cancellation cannot retract a remote commit. Expired presigned URLs have no refresh API in the existing backend and need operator review. Uploads require foreground, idle capture and the matching unlocked identity. No background upload or remote deletion guarantee exists.

## Licenses and model provenance

- [Vosk](https://alphacephei.com/vosk/android), `vosk-android` 0.3.75, Apache-2.0. [Small US English 0.15 model](https://alphacephei.com/vosk/models), Apache-2.0. Explicit 40 MiB download, SHA-256 in `Models.kt`, about 300 MiB runtime memory.
- [llama.cpp](https://github.com/ggml-org/llama.cpp), MIT, exact source commit/archive hash in CMake. CPU-only JNI bridge; no server/API inference.
- [Qwen2.5 0.5B Instruct GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF), Apache-2.0. Q4_K_M, repository revision `9217f5db79a29953eb74d5343926648285ec7e67`, 491,400,032 bytes. Explicit download; pinned SHA-256 in `Models.kt`. Budget roughly 1.5 GiB available memory; unsupported/resource errors retain original text.
- [ACINQ secp256k1-kmp](https://github.com/ACINQ/secp256k1-kmp), Apache-2.0 wrapper with Bitcoin Core libsecp256k1 (MIT), version 0.24.0. Official BIP340 public test vectors are included under test resources.
- AndroidX, Kotlin, kotlinx.serialization/coroutines, OkHttp: Apache-2.0. JNA: LGPL-2.1-or-later or Apache-2.0 dual license (Apache option).

Model files are downloaded by consent, not redistributed in the APK. Upstream license notices must accompany any independently distributed model or native binary. Runtime dependency license texts remain in packaged dependency resources where supplied.

## Android 1.1 capture and conversation parity

The SwiftUI iPhone app is the interaction reference: a white capture page, Normal / Channel / Agent selector, compact microphone control, red New recording and audio-publish actions, two large conversation controls, and a grouped menu containing recordings and settings. Android uses native Compose typography, navigation and permission UI. System dialogs and platform chrome differ from iOS.

Normal retains ordinary automatic/manual delivery. Channel and Agent save independent destinations and reuse the matching identity's saved connection/workspace during setup. Channel requires a channel; Agent requires a canonical receiving agent. Discovery validates retained selections against current accessible results. The complete route is copied into recording metadata before microphone capture begins. Changing setup, mode or identity never retargets existing recordings, follow-ups or transfer snapshots. Old 1.0 manifests and ledgers decode with default Normal routing and remain readable without moving data.

Stop, upload & publish audio bypasses local transcription. The immutable artifact explicitly says no transcript is attached and asks the receiving agent/server to transcribe the original audio. The audio and its metadata remain local if setup or delivery fails; use the saved recording's audio upload action to retry. Stop and transcribe locally uses the installed Vosk model and retains durable failure/retry status if absent. Every mode respects its saved automatic-upload opt-in after local transcription. Only the explicit audio-publish action forces delivery to its captured route.

Conversation checks run immediately and every 20 seconds only while the latest card is expanded, visible, foreground and idle with its matching identity unlocked. Refresh checks recent conversations. Replies prefer attached audio downloaded through the original authenticated HTTPS origin (redirects refused, 32 MiB limit); text-only replies use an installed offline Android TTS voice. Menu → Reply voice supports system default, installed offline voice selection, preview, stop and opt-out of automatic listening. Missing voices are reported with a system-settings action. Bounded, signer/conversation-scoped autoplay history survives process restart. Manual Listen remains available. Leaving the screen, starting capture, locking or backgrounding stops playback and removes temporary reply audio. Respond records into the original conversation/thread. Local pending/failed responses remain pending until Tower accepts their stable message request; only accepted responses display Responded. Older deliveries without a returned thread retain history but cannot refresh/respond until a new conversation is started.

A selected microphone must remain available and match Android's actual routed input after a one-second startup grace. Refusal or substitution stops capture and retains earlier segments. Choose System default explicitly to permit Android's default routing. Bluetooth/USB device behavior still needs physical-device verification.

Android does not provide Apple's SpeechAnalyzer, Apple-managed model installation or Foundation Models APIs. It uses the documented Vosk and optional llama.cpp/Qwen engines. Android system TTS voices and languages depend on the installed engine/data; network-only voices are excluded. Menu → Diagnostics explicitly queues a private JSON report of up to 500 operational events from the last hour. Events use a fixed enum with timestamps: no raw errors, audio, transcript, messages, device names or key material are accepted. Reports use the selected immutable NStack destination, require matching unlock, and survive relaunch for retry in NStack uploads. No automatic telemetry runs. Finished local reports can be removed from upload history; remote copies remain. Unreadable event files fail closed and are retained. Recorder notices, recording events and upload history remain available locally. Live receiving-agent execution, real Bluetooth/USB routing, interruptions and OEM background behavior require separate release-owner/device validation.

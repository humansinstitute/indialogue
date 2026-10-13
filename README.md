# Pete Recorder

A native, dependency-free SwiftUI iPhone recorder for iOS 18+. Open `Recorder.xcodeproj` in Xcode 26.3 and select the shared `PeteRecorder` scheme. No generator or package installation is required.

- Start/stop local mono AAC capture, with audio background mode and files accessible after first unlock.
- See the actual AVAudioSession input route and choose among inputs supported by iOS. Find available microphones requests permission and activates the audio session; selecting a preference does not guarantee the requested route. The actual route remains authoritative.
- Save recordings with stable UUIDs, rename, delete with confirmation, play segments in order, and share a combined AAC `.m4a` through the system share sheet.
- Optionally transcribe saved audio locally using iOS 26 SpeechAnalyzer/SpeechTranscriber. Installed models can be used without a download; downloading requires a separate confirmation. Unsupported OS/device/language is reported without affecting capture. There is no cloud recognition fallback. See Apple’s [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) and [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory) documentation.

Capture intent and each segment path are written atomically before capture begins. AVAudioRecorder caps each AAC segment at 15 seconds, and a completion callback starts the next segment. Small gaps at boundaries are possible: this is a durability-first voice memo recorder, not a gapless production audio recorder. On launch, unfinished manifests become interrupted, readable durations are recovered, and unreadable files are retained with visible history. A corrupt manifest is isolated and reported rather than deleted. Sharing/playback skip unreadable segments with a notice; original files remain available for recovery.

Interruption begins and media-services reset stop capture and save its state. Route changes are shown and logged; lost input or stopped capture finalizes an interrupted recording. A new recording requires an explicit start. Storage is checked before every segment with a 20 MB reserve. Write/encode failures show a notice and preserve earlier audio. Recovery after process termination is best effort: the current segment can be incomplete or missing. Force quit, reboot, power loss, full storage, and OS termination do not guarantee continued capture or final-segment recovery.

Audio, transcripts, and metadata live in Application Support/Recordings, excluded from device/iCloud backup. Deleting the app deletes the library. Export important recordings using Share. Exported temporary files also remain in the app sandbox until iOS removes them. The app makes no upload/auth/workspace requests. Explicit speech-model installation may contact Apple; Apple manages installed models and subsequent system updates.

See [installation](docs/INSTALLATION.md), [validation](docs/VALIDATION.md), and [future integration](docs/INTEGRATION.md).

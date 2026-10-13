# Install on an iPhone

Requires iOS 18+, Xcode 26.3 (iOS 26 SDK for compiling the optional transcription path), an Apple development team with a usable certificate/profile, and a paired device with Developer Mode enabled. iOS 26 transcription additionally requires a supported device/language and installed speech model. Capture works on iOS 18 without speech.

1. Open `Recorder.xcodeproj`.
2. Select `PeteRecorder` target → Signing & Capabilities → your existing development team. Automatic signing is enabled, but the repository deliberately has no hard-coded team, credentials or provisioning profile. Confirm the bundle ID `studio.otherstuff.PeteRecorder` is available to that team, and preserve this ID for updates to the existing installation. Do not change it when updating.
3. Select the paired iPhone as the run destination. Enable Developer Mode on the phone and complete any existing trust prompts. Do not create credentials as part of this repository workflow.
4. With the owner's authorization, use Xcode Product → Run to build, install and launch. Allow microphone access when starting the first recording.
5. Install updates in place with the same bundle ID/signing identity. Never uninstall or reset the library, identity vault, or Apple-managed speech models. Version 1.1 reads v1 manifests and keeps the Application Support/Recordings storage root and UUIDs.
6. Test lock/background capture and every connected microphone before relying on the recorder. Share an m4a and listen to it in another app. Stop and save automatically tries the installed speech model. Retry or explicitly approve Download model & transcribe when needed. Apple Intelligence cleanup is a separate optional feature and returns a reviewable draft.

Read-only inspection during initial implementation found an Apple Development identity and a paired iPhone 15 Pro. Read-only profile inspection found five profiles, no unexpired exact bundle-ID match, and one unexpired wildcard profile. The supervisor separately verified a signed build with an existing wildcard profile; its run-specific team/device evidence stays in ignored handoffs. That artifact predates the final source and must be rebuilt before installation. A certificate alone does not establish that this bundle ID has a matching profile, that team membership is active, or that Developer Mode is enabled. This implementation worker performed unsigned builds and read-only signing inspection, with no provisioning change, physical install or physical launch. No secrets were exported. Signing team/profile selection remains an installation prerequisite.

An unsigned device build is produced at:

`build-device/Build/Products/Debug-iphoneos/PeteRecorder.app`

That unsigned artifact cannot be installed on a normal iPhone. The supervisor's existing signed artifact path is:

`build-signed/Build/Products/Debug-iphoneos/PeteRecorder.app`

Rebuild this path from the reviewed final commit before any authorized install. After selecting an existing team/profile, an authorized CLI path is:

```sh
xcodebuild -project Recorder.xcodeproj -scheme PeteRecorder -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-signed \
  DEVELOPMENT_TEAM=YOUR_EXISTING_TEAM build
xcrun devicectl device install app --device YOUR_PAIRED_DEVICE_IDENTIFIER \
  build-signed/Build/Products/Debug-iphoneos/PeteRecorder.app
```

No `-allowProvisioningUpdates` is used: missing signing assets should be handled deliberately in Xcode. Installation and launch are separate actions; this guide does not imply either was performed. Private device identifiers and run evidence belong only in ignored `tmp/docs/handoffs/`. Add any custom build output path to local ignores before building.

Microphone denial: Settings → Privacy & Security → Microphone → Pete Recorder. An active recording must start after first unlock following reboot. Subsequent locking is supported by the audio background mode and file protection policy, subject to physical-device validation.

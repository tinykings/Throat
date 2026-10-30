# Throat

A tiny native macOS menu-bar dictation app. Swift + AppKit + Apple's speech recognition. No third-party dependencies, accounts, AI rewriting, telemetry, history files, or background audio capture.

## Try it

Requires macOS 14+ and Xcode Command Line Tools to build.

```sh
./build.sh --run
```

1. Click into a text field in another app.
2. Press **⌥Space**. On first use, grant Microphone and Speech Recognition permissions. Recording works even without Accessibility. To enable automatic paste, choose **Allow Pasting…** in the menu; this opens the Accessibility settings page.
3. Speak. A small, non-focus-stealing box shows the live transcript.
4. Keep clicking, switching apps, and working while dictation runs in the background. Pauses don't clear the transcript or stop recording.
5. Click the destination text field, then press **⌥Space** again to stop and paste there. Final recognition may take up to two seconds.
6. Click **Cancel** in the box to discard without pasting.

The microphone icon in the menu bar contains **Change Shortcut…**, **Copy Last Transcript**, and **Quit**. There are no other preferences. The most recent transcript is held only in memory until quit and is available for recovery if an app doesn't accept paste. There is no automatic launch at login.

## Privacy and behavior

- Uses your current system language. Prefers on-device recognition when Apple supports it; otherwise Apple's speech service may process audio online. No separate models or API keys to configure.
- Microphone runs only during dictation. Audio isn't saved by this app.
- The floating box never takes keyboard focus. Clicking away does not stop recording. The app/field focused when you stop receives the paste.
- Pasting uses a normal Command-V; it never sends Return. Known password fields are rejected. Focus changes during delivery abort the paste rather than redirecting it. If Accessibility is not granted, stopping copies the transcript instead; press ⌘V manually. Denied microphone/speech permissions each have an explicit menu link to the appropriate System Settings page.
- Dictation replaces the clipboard and stays there for recovery. Throat does not read or restore other apps' clipboard contents, avoiding extra clipboard/data-access prompts. Some apps don't accept synthetic paste; use **Copy Last Transcript** if needed.
- Apple's recognizer can stall after a long pause or hit its session limit. Throat closes the current recognition segment after about two seconds of silence (and before the online limit) and opens a new one while the microphone keeps running, so speech after a pause isn't lost. Unexpected recognition failures preserve the partial transcript in the menu.
- Only the shortcut or **Stop & Paste** menu command finishes dictation. Make sure a text field is focused before stopping.

## Development

```sh
swift test
./build.sh
open build/Throat.app
```

Quit the running app before rebuilding. The build script automatically uses an available Apple Development certificate to keep macOS permission grants stable across rebuilds; `SIGNING_IDENTITY` overrides this choice. Without a certificate, it falls back to ad-hoc signing and prints a warning. Switching from an old ad-hoc build may require removing/re-adding the app in Accessibility once. Use the same app path for each launch.

## Releases

Pushing a version tag builds a universal `Throat-<version>.dmg` on GitHub Actions and attaches it to a GitHub Release ([.github/workflows/release.yml](.github/workflows/release.yml)):

```sh
git tag v1.0.0
git push origin v1.0.0
```

To build the same DMG locally: `UNIVERSAL=1 VERSION=1.0.0 ./build.sh && ./make-dmg.sh`.

Without signing secrets the release is ad-hoc signed: macOS blocks it on first launch (right-click → Open, or **Open Anyway** in Privacy & Security), and each update needs its permissions granted again. Adding a Developer ID certificate and notarization credentials as repository secrets (listed at the top of the workflow) removes both problems; this requires a paid Apple Developer Program membership.

This is an independent minimal implementation, inspired by FluidVoice's dictation workflow; it does not copy or bundle FluidVoice code or dependencies.

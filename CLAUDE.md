# CLAUDE.md

Holo is a native macOS app (Swift, SwiftUI, AVFoundation) that turns the desk around a
MacBook into four tap zones using the built-in microphone. Taps are detected and
classified fully on-device and trigger user-assigned actions.

This fork is being developed into a commercial product. Feature work is planned in
`docs/plan/ROADMAP.md`. Implement one spec at a time, in roadmap order, unless told
otherwise.

## Build and test

- Requires macOS 14+, Xcode. Project is generated from `project.yml` via XcodeGen:
  `xcodegen generate` after any target/file changes, then build the `Holo` app target.
- SwiftPM targets (`Package.swift`) cover the non-UI code. Run unit tests with
  `swift test` (HoloCoreTests, HoloReplayTests) or via Xcode for HoloAppTests.
- Never break the DSP test suite. If a change affects detection/classification,
  run the replay tests before and after.

## Architecture map

- `Sources/HoloCore/` — framework, no UI. Key files:
  - `StreamingTapDetector.swift` — streaming onset detection (noise floor, pre-roll,
    90 ms analysis window). Allocation-sensitive; runs on every audio callback.
  - `TapFeatureExtractor.swift`, `TapClassifier.swift` — features + regularized linear
    zone model with OOD/ambiguity rejection (`RejectionReason` in `Zone.swift`).
  - `Zone.swift` — `DeskZone` (leftTop/leftBottom/rightTop/rightBottom),
    `SensingStrategy` (passive/active/hybrid), `RejectionReason`.
  - `Profile.swift` — `HoloProfile` (versioned, Codable), `ZoneConfiguration`,
    `ZoneActionKind`, `CalibrationSummary`, profile store.
  - `ActiveProbe.swift` — ultrasonic chirp for active/hybrid sensing.
- `Sources/HoloApp/` — the app:
  - `AudioCaptureService.swift` — AVAudioEngine capture, 512-frame tap on a
    `.userInteractive` queue, route validation (built-in mic required).
  - `AppModel.swift` — central `@MainActor` state machine (~1000 lines); wires
    capture → classification → action execution.
  - `CalibrationView.swift`, `RootView.swift` — SwiftUI.
  - `SensingStrategyResolver.swift`, `SystemAudioRoute.swift` — route policy.
- `Tests/` — HoloCoreTests, HoloAppTests, HoloReplayTests.

## Hard constraints (do not violate)

1. **All audio processing stays on-device.** Never add networking to any audio path.
   The app must keep working with zero network entitlements.
2. **Audio never persists.** Only the ~12 ms pre-roll + 90 ms analysis window may
   exist in memory; raw audio is never written to disk except the existing opt-in
   debug WAV capture. Zero/reuse buffers rather than retaining them.
3. **Profile schema changes must be versioned.** `HoloProfile.version` exists for
   this. Old profiles must load (migrate or clearly fail with `schemaMismatch`),
   never silently misbehave.
4. **The audio callback path is hot.** No new per-callback allocations, locks, or
   Objective-C dispatch in `StreamingTapDetector.process` or the tap closure.
5. **Never execute zone actions while the screen is locked or the session is
   inactive.** (Enforced by spec 01; preserve it in all later work.)
6. Keep the MIT license file and original copyright notice intact.

## Conventions

- Swift concurrency: UI state on `@MainActor`; audio work on the existing
  dedicated queue. Match the surrounding style; no new dependencies without a
  spec saying so.
- New user-facing strings follow the existing tone: plain, instructional,
  sentence case.
- Each spec lists acceptance criteria. A feature is done when its criteria pass,
  its tests exist, and `swift test` is green.

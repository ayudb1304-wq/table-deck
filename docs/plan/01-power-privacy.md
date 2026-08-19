# Spec 01 — Tiered listening: Doze / Armed / Paused

## User value
Holo stops draining the battery and stops feeling like a hot mic. It sleeps when idle,
turns fully off when you lock the screen or join a call, and can never run an action
while you're away from the machine.

## Design

Introduce a `ListeningTier` state machine owned by `AppModel`, driven by
`AudioCaptureService`:

- **Armed** — current behavior: 512-frame buffers, full detect→classify→act pipeline.
- **Doze** — entered after N minutes (default 3, user-configurable) with no accepted
  tap. Reinstall the input tap with 4096-frame buffers and downgrade the processing
  queue to `.utility`. In doze, run ONLY the RMS gate and noise-floor adaptation in
  `StreamingTapDetector` — skip feature extraction and classification entirely.
  Exit to Armed on: (a) an onset candidate whose peak exceeds a wake threshold
  (default: 2 strong transients within 1 s — a deliberate double tap), or
  (b) the user clicking Resume/menu-bar arm.
- **Paused** — engine stopped, mic released (`AVAudioEngine.stop()`, remove tap).
  Entered on ANY of: screen lock, system sleep/display sleep, Low Power Mode,
  thermal state `.serious` or worse, battery below a user threshold (default off),
  another process actively using the input device (see below), or manual pause.
  Exit only when the triggering condition clears AND the session is unlocked.

System hooks (new file `Sources/HoloApp/PowerStateObserver.swift`):
- `NSWorkspace.willSleepNotification` / `didWakeNotification`
- DistributedNotificationCenter `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"`
- `ProcessInfo.thermalStateDidChangeNotification`, `isLowPowerModeEnabled` (KVO/notification)
- Battery level via IOKit `IOPSCopyPowerSourcesInfo` (poll on a slow timer, e.g. 60 s)
- Mic contention: CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
  built-in input device; if another process holds it, Pause with a "Paused during
  your call" status.

Action gating (in `AppModel` where actions execute):
- Never execute any action unless tier == Armed and the session is unlocked.
- Classify `ZoneActionKind` into safe (visual, sound, copy/speak text) vs privileged
  (shell command, Shortcut, open app/item/website, screenshot). Privileged actions
  additionally require a user-visible confirmation the FIRST time each is armed per
  profile, and are rate-limited to 1 per 2 s.

Active probe duty cycling:
- In hybrid mode, do not emit the chirp continuously. Emit a single confirmation
  chirp only within 150 ms after a passive onset candidate. Active-only mode keeps
  its current behavior but is unavailable in Doze.

Hot-path cleanup in `StreamingTapDetector.process`:
- Preallocate scratch buffers for channel normalization, mixdown, and the onset
  low-pass. Replace `map`-based RMS/peak with Accelerate (`vDSP_rmsqv`,
  `vDSP_maxmgv`). Behavior must be bit-identical or within test tolerance —
  the replay tests are the referee.

## UI
- Menu bar/status area shows the tier: "Listening", "Dozing — measuring loudness
  only", "Paused (locked / call / low power / manual)". One click toggles arm/pause.
- Settings: idle-doze timeout, battery threshold toggle, wake-gesture on/off.

## Acceptance criteria
1. With no taps for the timeout, callback rate drops from ~94/s to ≤15/s (assert via
   the existing `CallbackTimingAccumulator` diagnostics) and queue QoS is `.utility`.
2. Locking the screen stops the engine within 1 s; no `TapObservation` is produced
   and no action executes while locked (unit-testable via injected notifications).
3. A double tap in Doze transitions to Armed and the NEXT tap classifies normally.
4. Joining a call (simulate: another process flag on the device property) pauses
   capture; ending it resumes the previous tier.
5. Hybrid mode emits zero probe audio when no onset candidate occurred (assert via
   probe player scheduling in tests).
6. Replay test suite passes unchanged after the vDSP/preallocation refactor.
7. No new allocations in `process()` steady state (verify with a simple allocation
   counter test or Instruments note in the PR description).

## Out of scope
Any UI redesign beyond the status/menu items; auto-recalibration; MIDI.

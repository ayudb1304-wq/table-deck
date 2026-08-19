# Spec 02 — 60-second Quick Calibration

## User value
Setup drops from 40 accepted taps across a multi-step flow to under a minute with
live feedback. First-run completion rate is the single biggest driver of conversion.

## Design

Add a **Quick** calibration mode alongside the existing full flow (keep the full
flow as "Precise" for power users; it produces better models and stays the
recommended path in Settings).

- Quick mode: 4 accepted taps per zone (16 total), collected in one continuous
  guided pass: the UI highlights a zone, user taps until 4 accept, auto-advance.
  Reuse `GuidedCaptureQuality` acceptance rules unchanged — do not loosen signal
  quality checks; loosen only the count.
- Train the same `TrainedTapClassifier` on 16 examples but flag the profile as
  `calibrationQuality: .quick` (new field on `CalibrationSummary`, bump
  `HoloProfile.version` with a migration default of `.precise` for old profiles).
- Quick profiles get a stricter ambiguity-rejection threshold in `TapClassifier`
  (prefer rejecting over misfiring with less training data). Expose the threshold
  as a classifier parameter rather than hard-coding a second code path.
- Live feedback during capture: after each tap show accept/reject instantly with
  the existing `RejectionReason` display names, plus a per-zone strength meter.
- After Quick calibration, show a non-blocking banner: "Working with a quick
  profile. Add 6 more taps per zone anytime to improve accuracy" → deep-links into
  a top-up flow that appends examples to the existing profile and retrains
  (reuse the guided session machinery in `GuidedSessions.swift`).

## Acceptance criteria
1. A new user can go from launch to a working 2-zone profile in ≤60 s of tapping
   (manual QA note in PR; automated: flow requires exactly 4 accepted taps/zone).
2. Old profiles load unchanged and report `.precise`.
3. Replay-based test: a classifier trained on 4 examples/zone with the stricter
   threshold rejects ambiguous taps at a higher rate than the default threshold
   (assert relative ordering, not absolute accuracy).
4. Top-up flow appends to the same profile id, retrains, and flips quality to
   `.precise` once ≥10 examples/zone exist.
5. `swift test` green; no changes to detector or feature extraction.

## Out of scope
Background/continual learning; changing the feature set or model class.

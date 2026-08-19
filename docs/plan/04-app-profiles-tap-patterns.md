# Spec 04 — Per-app zone profiles + tap patterns (Pro)

## User value
Four desk zones become dozens of actions: zones remap automatically per app, and
double/triple taps triple the actions per zone. This is the Stream-Deck-without-
hardware promise and the reason to buy Pro.

## Part A — Per-app action sets

Keep ONE acoustic model per desk profile (calibration is about the desk, not the
app). Layer action mapping on top:

- New type `ActionSet`: `{ id, name, bundleIdentifiers: [String], zones: [ZoneConfiguration] }`.
- `HoloProfile` gains `actionSets: [ActionSet]` and keeps its existing `zones` as
  the Default set (migration: wrap existing zones into a Default `ActionSet`;
  bump `HoloProfile.version`).
- An `ActiveAppMonitor` (NSWorkspace `didActivateApplicationNotification`) resolves
  the current set: first `ActionSet` whose bundle ids contain the frontmost app,
  else Default. Resolution happens at action-execution time on the main actor —
  no audio-path involvement.
- UI: in zone settings, a set picker ("Default", "+ New set for an app…"), choosing
  an app from running apps or a file picker for /Applications. Editing a set edits
  only its zone→action table.

## Part B — Tap patterns

Distinguish single, double, and triple taps per zone. Detection lives in a new
`TapPatternAggregator` in HoloCore, AFTER classification (input: accepted
classified taps with timestamps; output: `(zone, pattern)` events):

- Window: taps in the same zone within 400 ms chain into a pattern (configurable
  350–500 ms). Emit the pattern event when the window expires with no further tap.
- Consequence: single-tap actions on a zone that ALSO has a double/triple action
  fire after the window delay (~400 ms). If a zone has only a single-tap action,
  fire immediately (zero added latency) — resolve this per zone at arm time.
- Cross-zone taps inside the window break the chain and emit what was accumulated.
- `ZoneConfiguration` becomes keyed by pattern: `{ zone, pattern: .single|.double|.triple, action }`
  (migration: existing entries become `.single`).
- The classifier's refractory period must allow taps ~150 ms apart; verify against
  `StreamingTapDetector`'s refractory constant and expose it if it currently blocks
  double taps.

## Pro gating
Both features are Pro (see Spec 05): creating a second `ActionSet` or assigning a
non-single pattern requires an active license; existing configs keep working
read-only if a license is deactivated.

## Acceptance criteria
1. Migration: v(N-1) profile loads, produces a Default ActionSet, round-trips.
2. With Figma frontmost and a Figma set defined, a tap runs the Figma action;
   switching to Finder runs Default (unit test resolution with injected frontmost).
3. `TapPatternAggregator` unit tests: single fires immediately when no multi-tap
   action exists; double within 400 ms fires double action once (no single); triple
   works; cross-zone interruption emits accumulated pattern; timing is injectable.
4. Two taps 150 ms apart in the same zone both pass the detector refractory in a
   replay test.
5. Action execution still respects all Spec 01 gating.

## Out of scope
Knock-rhythm passwords, per-website sets, pattern actions in the free tier.

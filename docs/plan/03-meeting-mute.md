# Spec 03 — Meeting Mute (tap your desk to mute/unmute)

## User value
The instantly-understandable flagship: in a Zoom/Meet/Teams call, tap the desk to
toggle mute. No hunting for the button while everyone waits. This is the free tier's
headline and the shareable demo.

## Design

New `ZoneActionKind` case: `meetingMute` (schema-versioned; older apps reading a
newer profile must hit the existing `schemaMismatch` path, so bump
`HoloProfile.version`).

Implementation: a `MeetingMuteService` in `Sources/HoloApp/` that toggles mute in
the frontmost supported app by sending that app's own global/in-app shortcut via a
`CGEvent` keystroke targeted at the app (activate app if needed, post key event):
- Zoom: Cmd+Shift+A
- Google Meet (Chrome/Safari/Arc tab frontmost): Cmd+D
- Microsoft Teams: Cmd+Shift+M
- Fallback (no supported app frontmost): toggle macOS system input mute instead,
  and show a HUD saying which happened.

Detection of the active meeting app: check frontmost app bundle id first; if the
frontmost app isn't a meeting app but exactly one supported meeting app is running
AND currently holds the microphone (`kAudioDevicePropertyDeviceIsRunningSomewhere`
plus per-process check where available), target that app without switching focus
when possible (Zoom's global shortcut works unfocused if the user enabled it —
document this in the HUD hint).

Feedback is mandatory: every trigger shows a large, brief HUD overlay ("Muted" /
"Unmuted" / "Muted system input") because the user must never be unsure of mic
state. If state can't be verified, say "Sent mute toggle to Zoom".

Interaction with Spec 01: a meeting normally means another app holds the mic, which
Pauses Holo. Add a carve-out: when any armed zone's action is `meetingMute`, mic
contention does NOT pause listening (this is the one intended coexistence case).
Everything else about tier gating still applies.

Permissions: sending keystrokes requires Accessibility permission. Add a one-time
guided prompt (open the right Settings pane) the first time a `meetingMute` action
is assigned; degrade gracefully to system-input mute if not granted.

## UI
- In zone action picker, "Mute/unmute meeting" appears first, with a one-line
  explanation and the Accessibility prompt if needed.
- First-run suggestion after calibration: "Make your front-left zone a meeting mute
  button?" one-tap accept.

## Acceptance criteria
1. With Zoom frontmost, triggering the zone posts Cmd+Shift+A to Zoom (unit test the
   event construction + target resolution with the app-detection logic injected).
2. With no meeting app running, the same tap toggles system input mute and the HUD
   reflects it.
3. Mic-contention pause is bypassed only when a `meetingMute` zone is armed.
4. Without Accessibility permission, the action falls back to system mute and the
   HUD explains why.
5. Older profile files still load; new profiles with `meetingMute` fail cleanly on
   the pre-bump schema (existing `schemaMismatch` behavior).

## Out of scope
Per-app plugins/SDKs, Webex/Discord (add later), verifying actual mute state inside
the target app.

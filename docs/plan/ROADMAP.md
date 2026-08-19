# Roadmap

Goal: a trustworthy, sellable utility. Free tier earns trust and virality; Pro tier
(one-time purchase) earns revenue. Build in this order — each spec assumes the ones
before it are done.

| # | Spec | Why it's first-order | Tier |
|---|------|----------------------|------|
| 01 | `01-power-privacy.md` — tiered listening (Doze/Armed/Paused), lock-screen hard stop, action gating | Battery drain and "always-on mic" are the top objections; also fixes a real security hole (actions firing while locked). Nothing sells until this is solid. | Free |
| 02 | `02-quick-calibration.md` — 60-second guided calibration | The current 40-tap setup is the adoption killer. Nobody pays for an app they never finish setting up. | Free |
| 03 | `03-meeting-mute.md` — tap-to-mute for Zoom/Meet/Teams | The one feature normal people instantly understand; the marketing engine and the whole free tier's value. | Free |
| 04 | `04-app-profiles-tap-patterns.md` — per-app zone profiles + double/triple-tap patterns | Multiplies 4 zones into dozens of actions. This is what people pay for. | Pro |
| 05 | `05-pro-licensing.md` — offline license key + feature gating | Turns 04 into revenue. | — |

## Free / Pro split

- **Free:** 2 active zones, passive sensing, meeting mute, all reliability/privacy work.
- **Pro (one-time key):** all 4 zones, hybrid sensing, per-app profiles, tap patterns,
  Shortcut/shell/open actions beyond the basic set.

## Out of scope for v1 (do not build yet)

MIDI output, accessibility mode, analytics, auto-recalibration, App Store build.
Direct distribution (notarized DMG) only.

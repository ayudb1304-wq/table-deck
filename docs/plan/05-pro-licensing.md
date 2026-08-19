# Spec 05 — Pro licensing (offline key + feature gating)

## User value
One-time purchase, no subscription, no account — consistent with the privacy story.
"Verifiably offline" includes the license check.

## Design

- **Key format:** Ed25519-signed license. Payload: `{ email, purchaseDate, product: "pro", v: 1 }`,
  base64 payload + signature, formatted as a paste-able key string. The app embeds
  only the PUBLIC key and verifies signatures locally with CryptoKit. No network
  call, ever (keys are generated at purchase time by the payment provider's
  webhook/CLI — out of app scope; provide `scripts/generate-license.swift` for
  the seller side, keep the PRIVATE key out of the repo).
- **Storage:** validated key + payload stored in app support alongside profiles.
  Loaded and verified at launch; invalid/missing → Free tier.
- **Gating:** a single `EntitlementStore` (`@MainActor`, observable) with booleans:
  `allZones`, `hybridSensing`, `perAppSets`, `tapPatterns`, `privilegedActions`.
  All Free-tier limits check this store — never scatter `isPro` checks:
  - Free: 2 zones armable (leftTop, rightTop), passive sensing only, actions
    limited to visual/sound/copy-speak/meetingMute.
  - Pro: everything.
- **Degradation:** removing a license never deletes config. Pro-only config becomes
  visible-but-inert with an "upgrade to re-enable" badge.
- **UI:** Settings → "Holo Pro": key entry field, validation feedback, what's
  included list, Buy link (constant URL). Locked features show a small lock badge
  that opens this pane.

## Acceptance criteria
1. Unit tests: a key signed by a test private key validates against the test public
   key; tampered payload or signature fails; malformed strings fail cleanly.
2. Free tier: attempting to arm a third zone or select hybrid sensing is blocked in
   the UI and in `AppModel` (defense in depth), with the upgrade affordance shown.
3. Entering a valid key flips all entitlements without relaunch; removing it reverts
   without data loss.
4. Zero networking: no URLSession/network symbols added anywhere by this spec.
5. The private key and license generation stay outside the app bundle; the repo
   contains only the generator script and a TEST keypair for unit tests.

## Out of scope
Payment provider integration, trial timers, device counting/activation limits,
App Store receipt validation.

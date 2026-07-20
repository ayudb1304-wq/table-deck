# Contributing to Holo

Holo is a research prototype, so the easiest contributions to review are ones
that keep the DSP test suite green and respect the four-zone design.

## Setup

You need macOS 14 or later, Xcode (26 recommended), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
```

The Xcode project is generated from `project.yml`. After changing `project.yml`
— or adding or removing source files — regenerate it:

```sh
xcodegen generate
```

## Build and test

A non-signing command-line build is the quickest way to verify a change:

```sh
xcodebuild \
  -project Holo.xcodeproj \
  -scheme Holo \
  -configuration Debug \
  -derivedDataPath /tmp/HoloDerived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the unit suite with the same invocation, replacing `build` with `test`.

To run the app itself, use Xcode's normal **Sign to Run Locally** build. The
`CODE_SIGNING_ALLOWED=NO` bundle lacks the audio-input entitlement and should
not be launched (see the README's Build section).

## Soak runner

The synthetic DSP stress runner exercises detection, feature extraction,
classification, and rejection without the GUI or a microphone:

```sh
xcodebuild \
  -project Holo.xcodeproj \
  -scheme HoloSoak \
  -configuration Release \
  -derivedDataPath /tmp/HoloSoakDerived \
  CODE_SIGNING_ALLOWED=NO \
  build

DYLD_FRAMEWORK_PATH=/tmp/HoloSoakDerived/Build/Products/Release \
  /tmp/HoloSoakDerived/Build/Products/Release/HoloSoak --duration 1800
```

## Route check

Check the current built-in hardware routes without opening Holo or requesting
microphone access:

```sh
xcodebuild \
  -project Holo.xcodeproj \
  -scheme HoloRouteCheck \
  -configuration Debug \
  -derivedDataPath /tmp/HoloRouteDerived \
  CODE_SIGNING_ALLOWED=NO \
  build

DYLD_FRAMEWORK_PATH=/tmp/HoloRouteDerived/Build/Products/Debug \
  /tmp/HoloRouteDerived/Build/Products/Debug/HoloRouteCheck
```

## Where things live

- `Sources/HoloCore` — the detection engine: streaming detector, impact gate,
  FFT and feature extraction, classifier, persistence models, diagnostics, and
  evaluation reporting. No SwiftUI dependency. Covered by `Tests/HoloCoreTests`.
- `Sources/HoloApp` — audio capture, app state, local action dispatch, and the
  SwiftUI interface.
- `Sources/HoloSoak` and `Sources/HoloRouteCheck` — non-GUI verification tools.

## Notes for pull requests

- Keep changes small, and run the unit suite before opening a PR.
- The four-zone topology is intentional. Six- and nine-zone layouts were tried
  and abandoned (see the README), so PRs should not reopen that decision.
- DSP changes should preserve the behavior pinned by `Tests/HoloCoreTests`
  unless the PR is explicitly about changing that behavior.

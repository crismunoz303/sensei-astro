# Sensei Astro — development checkpoint

Native SwiftUI iPhone planning companion for S30 Pro on a standard tripod. No widgets and no telescope control.

Includes a red tonight dashboard, 23 ranked targets, search, favorites,
weather and Moon data, and target-specific suggested capture instructions.
The app deliberately does not launch or operate Seestar. It produces a concise
plan that the observer enters and follows in the official Seestar app.

## Build status

This repository produces an unsigned IPA for signing with the user's existing
App+ workflow. GitHub Actions compiles the app and runs deterministic planner
tests before packaging. Physical-device testing and App+ installation still
require the user's iPhone.

## Build workflow

Upload this folder's contents to a dedicated GitHub repository, retaining
project.yml at its root and the .github/workflows directory.
Every push to main (or a manual Actions run) generates the Xcode project, runs
the tests, compiles an unsigned iPhone build, and uploads the IPA artifact.

Build tools: https://github.com/yonaskolb/XcodeGen
Artifacts: https://github.com/actions/upload-artifact

App+ can import an IPA according to the user's screenshots, but installation
of this app remains unverified. Turn off optional tweak injection and old-iOS
modifications when testing. Do not enter credentials in the source.

## Accuracy work still required before release

- Validate Moon coordinates, horizon effects, target catalog coordinates,
  S30 Pro framing and settings against authoritative sources and live equipment.
- Separate accepted integration from elapsed session duration and mosaic time.
- Validate weather time zones and incomplete/null response handling.
- Add persistent offline cache with visible age and source status.
- Add API decoding fixtures and simulator/device UI tests.
- Finish app icon, accessibility and small-screen layout review.

Current scores are heuristic, Moon coordinates approximate, and durations
starting recommendations—not guaranteed optimal settings. No direct telescope
control is implemented. Unknown weather now shows CHECK CONDITIONS, and sample
placeholder targets are hidden while initial data loads.

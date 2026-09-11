# Sensei Astro — development checkpoint

Native SwiftUI iPhone app for S30 Pro on a standard tripod. No widgets.

Includes a red tonight dashboard, 23 ranked targets, search, favorites,
weather and Moon data, and target-specific suggested capture instructions.

## Build status

This is source code, NOT an installable IPA. Xcode and Swift are unavailable
in the authoring environment. Native compilation, simulator layout tests,
device tests and App+ installation have NOT been completed.

## Build workflow

Upload this folder's contents to a dedicated GitHub repository, retaining
project.yml at its root and the .github/workflows directory.
Run Actions > Build Sensei Astro > Run workflow. The workflow generates an
Xcode project and attempts an unsigned iPhone build, then uploads the IPA.
No workflow has been run yet. A successful build is required before signing.

Build tools: https://github.com/yonaskolb/XcodeGen
Artifacts: https://github.com/actions/upload-artifact

App+ can import an IPA according to the user's screenshots, but installation
of this app remains unverified. Turn off optional tweak injection and old-iOS
modifications when testing. Do not enter credentials in the source.

The Open Seestar button runs a Shortcut named Open Seestar containing
the Open App action with Seestar selected.

## Accuracy work still required before release

- Replace the civil-twilight/fixed-hour fallback with validated astronomical
  darkness intervals, including polar and date-boundary cases.
- Rank continuous usable capture windows, not just individual peak samples.
- Exclude elapsed windows when opened partway through the night.
- Validate Moon coordinates, horizon effects, target catalog coordinates,
  S30 Pro framing and settings against authoritative sources and live equipment.
- Separate accepted integration from elapsed session duration and mosaic time.
- Validate weather time zones and incomplete/null response handling.
- Add persistent offline cache with visible age and source status.
- Add automated astronomy/decoding tests and simulator/device UI tests.
- Finish app icon, accessibility and small-screen layout review.

Current scores are heuristic, Moon coordinates approximate, and durations
starting recommendations—not guaranteed optimal settings. No direct telescope
control is implemented. Unknown weather now shows CHECK CONDITIONS, and sample
placeholder targets are hidden while initial data loads.

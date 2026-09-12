# Sensei Astro Studio

Native SwiftUI iPhone companion for a Seestar S30 Pro on a standard tripod.
Tonight and Targets provide locally ranked capture plans. True Edit provides
conventional photo processing while preserving the imported source bytes.

## Version 1.5.0

True Edit now builds a deterministic astrophotography development plan from each imported image: sigma-clipped cubic background correction, per-channel sky neutralization, conservative black placement, measured display gain, two-stage background-only denoise, protected multiscale contrast, and signal-masked color enhancement. Existing projects are reanalyzed when opened so they do not retain the weaker 1.4 plan. It never uses generative AI or replacement imagery, and the imported bytes remain checksum-verified and unchanged.

True Edit now keeps recoverable projects, applies a conservative starting edit
from measured image statistics, supports undo and comparison, protects bright source pixels, and
offers both preview zoom and source-resolution detail inspection. It exports
full-resolution PNG or 16-bit TIFF with a reproducible JSON edit record, and
reports Photos saves only after PhotoKit confirms them.

The planner rejects stale/missing weather and sessions beyond astronomical
darkness. It distinguishes estimated ranking from statistical confidence and
does not invent night windows when calculation fails. No widget or direct
telescope control is included.

See [the specification](SENSEI_ASTRO_STUDIO_SPEC.md) for supported formats,
integrity guarantees, technical limits, test coverage and primary references.

## Build and verification

Pushes to main run Shared SwiftPM image/planner tests on macOS, generate the
Xcode project with XcodeGen, exercise the photo workflow in iPhone Simulator,
compile an iPhone Release build and package an unsigned IPA. Test charts and
automation launch hooks are DEBUG-only and absent from Release.

Workflow artifacts contain the IPA, simulator results and screenshots.
Physical-device installation, PhotoKit permissions on the user's device,
memory use with real large images and live Seestar results require device
verification; simulator success does not establish those outcomes.

The IPA must be signed before installation. Keep the existing bundle identity
when updating. The existing Andromeda icon is embedded in the app. Preserve
independent source backups before deleting the app or changing its identity.

## Deliberate boundaries

No trained AI specialist or image generator is bundled. FITS/RAW development,
stacking/calibration, scientific noise estimation and learned editing preferences
remain future work. Conventional filtering can alter fine detail, so inspection
and recovery are built into the workflow. Planner scores and collection times
are estimates, not promises of optimal results.

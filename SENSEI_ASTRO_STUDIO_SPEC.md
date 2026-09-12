# Sensei Astro Studio 1.3.0

Native iPhone companion for Seestar S30 Pro capture planning and conventional,
original-preserving photo editing. Red/dark interface and Sensei's existing
Andromeda icon. The user operates the telescope in the Seestar app.

## True Edit

- Import JPEG, PNG, HEIC and single-image TIFF through Photos or Files.
- Keep the imported bytes unchanged in Application Support; verify SHA-256 on
  import, reopening, source backup, detail inspection and export.
- Save recipes atomically and recover the most recent project on relaunch.
- Start neutral. Measure a sampled sRGB histogram, median, percentile 99,
  near-clipping, regional brightness spread and fine variation.
- Apply a conservative measured starting recipe on first import and explain it.
  The user can compare, undo, reset, or refine it before export.
- Astro advice never infers light pollution from color or treats all dark sky
  as underexposure. Fine variation is not called pure noise or scientific SNR.
- Exposure, midtone curve, contrast, saturation, relative red/blue adjustment;
  optional conventional denoise and luminance sharpening, initially off.
- Source-derived highlight mask blends bright original pixels into the result.
- Undo/redo, neutral reset, original comparison, pinch/pan inspection, and nine
  source-resolution detail regions rendered from the original image.
- Full-resolution sRGB PNG (8-bit) or TIFF (16-bit). Orientation is baked in;
  edited exports omit source location metadata. No crop or geometric warp.
- Verify output dimensions and TIFF bit depth; produce JSON audit of recipe,
  engine version, source identity and output checksum.
- Wait for PhotoKit confirmation before reporting success. Failed permission or
  save leaves the verified export available for Files sharing.
- Photo operations run through a serialized actor, with debounced cancellable
  previews and generation checks to reject obsolete preview results.

## Capture planner

- Preserve the existing local target ranking, favorites, filters, estimated
  accepted-stack goals, standard tripod / Alt-Az plans and shareable sequence.
- Require consecutive usable sample endpoints. Sessions never extend beyond
  the selected astronomical night or invent a 15-minute session in 14 minutes.
- Reject missing, invalid, or distant weather rather than treating it as clear.
  Incomplete weather windows remain provisional and their scores are capped.
- Identify scores as planning heuristics; distinguish the best sampled time
  from exact astronomical culmination. No confidence percentages are implied.
- Photo editor remains available while astronomy data loads.

## Verification

Shared SwiftPM tests execute the same Core Image processing code compiled into
the iPhone app. Tests cover corrupted inputs, original-byte integrity, project
recovery, repeat import, real 16-bit export, stripped GPS, EXIF orientations,
neutral reset, the complete filter chain, highlight protection, source-detail
rendering, weather parsing, stale forecasts and bounded observing sessions.

An iPhone Simulator UI test exercises compare, source inspection, recommendation,
export and project recovery using a deterministic DEBUG-only chart. It does not
use or modify Sensei's real photographs. Release excludes the chart and launch
hooks. Simulator results do not replace testing on Sensei's physical iPhone or
with his live Seestar session.

## Explicit limits and future work

No trained specialist AI, generative image model, synthetic stars, background
replacement, object removal or learned reconstruction exists in this build.
Conventional processing can still suppress detail or create artifacts; the
original remains recoverable and comparisons are provided.

Import is limited to 25 MP / 100 MB. FITS calibration/stacking, Bayer demosaicing,
camera RAW development, scientific color calibration, star classification,
gradient subtraction and learned personal preferences remain future work.
16-bit output cannot recover lost input precision. sRGB export is not an HDR or
wide-gamut archival workflow. Do not delete the app without backing up projects.

Planner coordinates, lunar model and 15-minute sampling are approximate. It has
no measured local horizon, seeing, transparency, live telescope feedback or
guarantee of accepted-frame efficiency. Forecast cloud percentages are not a
measurement of the sky above the telescope. Check conditions before capture.

## Primary references

- https://www.seestar.com/blogs/faq/seestar-s30-pro-faq
- https://open-meteo.com/en/docs
- https://aa.usno.navy.mil/data/api
- https://developer.apple.com/documentation/coreimage
- https://developer.apple.com/documentation/photokit/phphotolibrary

These establish API and equipment behavior. App-specific recommendation weights
and exposure/integration starting points are heuristics, not manufacturer-certified
optimal settings.

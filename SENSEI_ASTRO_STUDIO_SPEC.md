# Sensei Astro Studio — Product Blueprint

## Product promise

One private iPhone workflow for planning a Seestar S30 Pro capture and finishing
the resulting real photograph. The editor is not an image generator.

## Non-negotiable integrity rules

1. Never overwrite or destructively modify the imported source.
2. Never use generative fill, inpainting, object replacement, synthetic stars,
   hallucinated detail, or pixels borrowed from a generic image.
3. Preserve composition and object placement unless the user explicitly crops.
4. Store edits as a reversible recipe and export only a separate copy.
5. Clearly label ORIGINAL and EDITED COPY and provide instant comparison.
6. Display the source hash so a session remains tied to the exact input file.
7. Explain every automated recommendation in photographic language.

## App structure

- Tonight: local ranked targets and complete S30 Pro capture plans.
- Targets: searchable ranked catalog and favorites.
- True Edit: import, analyze, preview, manually refine, compare, reset, and save.

## True Edit version 1

- Photos import with the original bytes retained unchanged in memory.
- Deterministic measurement of average luminance and color distribution.
- Conservative exposure, contrast, saturation, vibrance, denoise, and luminance
  sharpening recommendations.
- Conventional Core Image filters only; no generative image model.
- Press-and-hold original comparison and a reset-to-original control.
- Separate-copy export to Photos.

## Higher-power completion roadmap

1. Add histogram, clipping map, star-core protection, and background-gradient map.
2. Add dedicated Astro, Night, Portrait, and General analyzers while retaining
   the same integrity rules.
3. Add FITS/TIFF import and high-bit-depth processing for Seestar source data.
4. Add local edit history, named recipes, batch processing, and metadata reports.
5. Learn preferences only from accepted slider changes; never train a generator.
6. Add unit tests for recipe limits and golden-image tests that verify geometry
   and dimensions never change unexpectedly.
7. Add a final export audit listing every operation applied to the copy.

## Definition of done

The user can plan tonight's S30 Pro session, import the resulting real image,
receive an explainable conservative recommendation, compare it with the locked
original, adjust it, and save a separate finished copy without any generative
or replacement imagery entering the pipeline.

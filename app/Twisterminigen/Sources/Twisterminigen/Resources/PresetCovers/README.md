# Verified local preset covers

This directory may contain only covers generated locally by Twisterminigen from the complete
built-in Krea 2 Turbo catalog. Third-party samples, cloud images, hand-authored substitutes, and
unverified Gallery exports are not accepted.

## Curation contract

`BuiltinPresetCoverCurator.publish` is the only supported import path. Give it one Gallery
generation UUID for every stable `builtin.*` preset ID and a new, non-existing output directory.
The service:

1. requires every unique built-in preset ID and an equally complete set of unique generation UUIDs;
2. obtains PNG bytes through Gallery's sidecar/SHA-256 verification API;
3. requires `recipeCapture == exact`, an exact full `GenerationRecipe`, the exact fixed seed, and
   matching UUID/seed components in the managed PNG filename;
4. requires PNG pixel dimensions to match the recipe canvas;
5. applies the category's sealed display policy without changing the Gallery original: ordinary
   cards use a center-square crop, while Character Sheet cards preserve the complete 16:9 frame
   inside a letterboxed 256 x 256 JPEG; every emitted JPEG is no larger than 128 KiB;
6. uses the private Gallery UUID, managed filename, and source-PNG checksum only transiently while
   verifying the selection, then writes a privacy-safe public manifest containing only the stable
   preset ID, recipe hash, fixed seed, display policy, dimensions, byte count, and JPEG checksum;
   and
7. validates the complete staged set before atomically moving the new directory into place.

The publisher refuses partial sets and never replaces an existing directory. After review, replace
this resource directory with the sealed output as one filesystem operation. The app displays a
built-in JPEG only when its manifest entry, exact recipe digest, seed, byte count, dimensions, and
checksum validate; otherwise it keeps the honest `production pending` placeholder.

No manifest or JPEG is checked in until the complete exact local Gallery selection exists. This
avoids silently presenting synthetic or unrelated artwork as a Krea result.

## Character Sheet covers

The Character Sheet category contains ten independent one-prompt, one-render recipes. Their cards
use `full-frame-letterbox`, and the Presets grid displays the inner image at 16:9 so the front,
back, and close-up panels remain visible instead of being cut down to a square crop.

The retired outlier card is intentionally absent because its park-backed composition did not match
the visual language of the section. The ten remaining covers retain verifiable recipe and asset
integrity without publishing local Gallery identifiers or filenames.

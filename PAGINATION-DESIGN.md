# Pagination design

This document records the durable implementation invariants behind pagination.
User-facing commands, options, defaults, and compatibility rules belong in
`README.md` and the executable help.

## Geometry

Pagination preserves the preprocessed screenshot pixels. It never stretches
the image or crops it horizontally to fit a paper size.

Let:

```text
PW = paper width in PDF points
PH = paper height in PDF points
MT = effective top margin in output pixels
MR = effective right margin in output pixels
MB = effective bottom margin in output pixels
ML = effective left margin in output pixels
W  = preprocessed screenshot width in pixels
H  = preprocessed screenshot height in pixels
CW = W + ML + MR
CH = round(CW * PH / PW)
HB = header-band height in pixels, or 0
FB = footer-band height in pixels, or 0
S  = CH - MT - MB - HB - FB
O  = overlap in source pixels
T  = S - O
```

Each effective side margin is the uniform `--margin` plus that side's optional
additional margin. `CW` and `CH` are the output canvas dimensions. `S` is the
number of source rows on a full page and `T` is the source-row advance. Both
must be positive; overlap must therefore be smaller than `S`.

Header and footer bands are 24 PDF points high. Their text inset is 12 points
and separator rules are 0.25 points. Convert these physical measurements to
pixels using the corresponding canvas dimension and paper dimension.

Page source ranges are half-open intervals:

```text
page 1: [0, min(S, H))
page 2: [T, min(T + S, H))
page 3: [2T, min(2T + S, H))
...
```

Stop after the first range ending at `H`. The page count is:

```text
1                              when H <= S
1 + ceil((H - S) / T)          when H > S
```

These rules guarantee full source-row coverage and avoid an extra page when
the source ends exactly on a page boundary.

## Raster construction and physical size

Every page is an opaque white `CW` by `CH` PNG. Place each unscaled screenshot
slice at `(ML, MT + HB)`. White canvas space supplies the outer margins,
decoration bands, and final-page padding. Never trim a generated page.
Disable alpha when writing the completed page because compositing onto the
white canvas makes every page opaque by definition. This prevents redundant
PDF soft masks.

Decode the prepared source once and clone all calculated slices from that
in-memory image. Render static header labels once per document, then construct
each page with a single canvas/compositing operation. This avoids repeatedly
decoding the full-height source or reading and rewriting a completed page for
each decoration.

Use independent horizontal and vertical density values:

```text
x_density = 72 * CW / PW
y_density = 72 * CH / PH
```

Apply that density to temporary PNG pages and PDF assembly. It maps integer
pixel dimensions to the selected physical paper dimensions without resampling
the screenshot.

Named paper sizes supply their standard PDF dimensions. A custom portrait
`WIDTHxHEIGHT` paper value supplies only an aspect ratio: normalize its PDF
width to 612 points and derive its height from that ratio. Equivalent ratios
must therefore produce identical canvas geometry and physical PDF dimensions.

## Validation and publication

Both output forms are first rendered as ordered, lossless temporary PNG pages.
Before publication, verify that every page has the expected `CW` by `CH`
dimensions.

For PDF output, assemble those pages with ZIP/Flate compression and validate
the candidate before publication. It must be a nonempty regular file with a
PDF header and end marker, the expected page count, and the selected physical
page dimensions within one PDF point in each direction.

Publish only validated output:

- Build a hidden temporary PDF file inside its destination directory, then
  rename it over the destination atomically. Using a file rather than a
  temporary directory avoids leaving empty folders in File Provider-backed
  locations such as Dropbox.
- Build PNG pages in a hidden sibling directory, then rename the completed
  directory to its fresh final name.

On failure or interruption, cleanup removes temporary artifacts without
altering a pre-existing destination. Generated pages do not pass through the
montage trim, border, or shadow finalization path.

## Intentional non-goals

Pagination does not provide:

- OCR or searchable text;
- whitespace-aware or content-aware page breaks;
- automatic avoidance of split text or images;
- landscape orientation;
- watermarks or transparent page backgrounds;
- multiple-input or batch PDF production;
- replacement or merging of an existing PNG page directory; or
- an additional required PDF dependency such as Ghostscript.

# Screenshot pagination specification

## Status and scope

This document specifies the first version of screenshot pagination for
`screenshots.sh`. It is an implementation specification, not user documentation.

The feature converts one long, single-frame raster image into either:

- one multipage, raster-only PDF; or
- a directory containing the same pages as lossless PNG files.

The first version uses fixed geometric page breaks. It does not perform OCR,
inspect page content, search for whitespace, or move a break to avoid splitting
text or images.

## Command forms

PDF output is the default:

```text
screenshots.sh -i IMAGE --paginate [-o FILE.pdf] [pagination options]
```

PNG-page output is selected with a separate output option:

```text
screenshots.sh -i IMAGE --paginate --output-pages [-o DIR] [pagination options]
```

Examples:

```bash
screenshots.sh -i article.png --paginate
screenshots.sh -i article.png --paginate -o article-letter.pdf
screenshots.sh -i article.png --paginate --paper a4 --margin 40 -o article.pdf
screenshots.sh -i article.png --paginate --overlap 40 -o article.pdf
screenshots.sh -i article.png --paginate --output-pages
screenshots.sh -i article.png --paginate --output-pages -o exports
screenshots.sh -i article.png --paginate -ct 120 -cb 80 --width 1600 -o article.pdf
```

## New options

`--paper`, `--margin`, `--overlap`, `--output-pages`, `--header`, `--footer`,
`--header-line`, `--footer-line`, `--title`, and `--page-font-size` are
pagination-only options. Supplying any of them without `--paginate` is an
error.

### `-p`, `--paginate`

Select pagination mode. Pagination is mutually exclusive with montage, zip,
and each modes.

### `--paper SIZE`

Select the physical page size. Accepted values are case-insensitive:

| Value | Width | Height | PDF points |
| --- | ---: | ---: | ---: |
| `letter` | 8.5 in | 11 in | 612 x 792 |
| `a4` | 210 mm | 297 mm | 595.2756 x 841.8898 |
| `legal` | 8.5 in | 14 in | 612 x 1008 |

The default is `letter`. Version one supports portrait orientation only.

### `--margin PIXELS`

Add the same white margin to all four sides of every page. The default is zero.
The value is a non-negative integer number of output pixels. Unit suffixes,
fractions, and negative values are rejected. The margin does not crop or scale
the source image; it increases the output canvas around it.

The margin must leave a positive content height after the selected paper aspect
ratio is applied. This is validated after preprocessing determines the source
width.

### `--overlap PIXELS`

Repeat content between consecutive pages. The value is a non-negative integer
number of pixels in the preprocessed source image. The default is `0`, meaning
that every source row appears on exactly one page.

Overlap is opt-in. It does not affect the paper dimensions or margins. It only
changes the starting source row of pages after the first.

The overlap must be smaller than the calculated full-page source slice height.

### `--output-pages`

Write the paginated result as individual PNG files instead of a PDF. Create a
fresh `pages-<timestamp>` directory in the current directory. If `-o DIR` is
present, create the timestamped directory inside that parent instead, creating
the parent recursively when it does not exist.
The trailing slash on `DIR` is optional.

The files are named `page-001.png`, `page-002.png`, and so on. Use at least
three digits and expand the width when the page count exceeds 999. All page
images have identical pixel dimensions. The final page is padded with white.

In PNG mode, `-o/--output` names a writable parent directory. Create a missing
directory recursively; reject an existing symbolic link or non-directory.
Without `--output-pages`, pagination continues to
interpret `-o/--output` as a PDF filename. Publish the completed temporary
directory with one rename only after every page has been generated and
validated. If the timestamped name already exists, append the first available
numeric suffix rather than replacing or merging it.

`-O/--overwrite` is invalid with `--output-pages`; version one never replaces
or merges an existing directory.

### Header and footer options

`--header` reserves a 24-point white band below the top outer margin. It
renders a 6-point sans-serif creation timestamp at left in a format such as
`Sep 10, 2026 · 11:52 PM`. Timestamp priority is embedded EXIF capture time,
a recognized GoFullPage filename timestamp, filesystem creation time, then
filesystem modification time. Filesystem times use the machine's local time.

`--title TEXT` adds right-aligned literal text to that header and requires
`--header`. The timestamp has layout priority. Shorten an overflowing title
with an ellipsis, or omit it if no meaningful text fits; never dynamically
shrink the font or truncate the timestamp.

`--footer` reserves a matching 24-point white band above the bottom outer
margin and renders `page/total-pages` at right. Its left side is empty.
Headers and footers are independently optional and use an automatically
discovered system sans-serif font. Decoration text has an automatic 12-point
horizontal inset in addition to `--margin`.

`--page-font-size N` overrides the 6-point decoration font and requires
`--header` or `--footer`. It accepts a positive numeric point size below 24;
repeating it is an error.

`--header-line` draws a 0.25-point `#d0d0d0` horizontal rule between an enabled
header band and the screenshot. `--footer-line` draws the same rule between
the screenshot and an enabled footer band. Each option requires its matching
header or footer. Rules are disabled by default and span the same automatic
12-point horizontal inset as the decoration text.

## Existing options in pagination mode

The following existing options are supported:

- `-i`, `--input`
- `-o`, `--output` for a PDF filename, or for the PNG parent directory when
  `--output-pages` is present
- `-O`, `--overwrite` for PDF output only
- `-v`, `--verbose`
- `-w`, `--width`
- `-H`, `--height`
- `-c`, `--crop`
- `-ct`, `--crop-top`
- `-cb`, `--crop-bottom`
- `-cl`, `--crop-left`
- `-cr`, `--crop-right`
- `-h`, `--help`

Cropping and resizing retain their current syntax, validation, and shrink-only
behavior. They run once on the complete source image, in the existing order:
crop first, resize second. Pagination runs after both operations.

The following options are invalid in pagination mode and must produce a clear
error before creating output:

- `-e`, `--each`
- repeated `-i`, `--input` options
- `-t`, `--tile`
- `-g`, `--gap`
- `-G`, `--gravity`
- `--background`
- `--trim`
- `--no-trim`
- `--trim-fuzz`
- `-s`, `--shadow`
- `--shadow-color`
- `-b`, `--border`
- `--border-color`
- `--font`

An option is considered specified even if its supplied value equals the normal
default. For example, `--paginate --gap 15x15` is still invalid.

Pagination mode requires ImageMagick's `magick` command. It never requires the
separate `montage` command. Font discovery is required only when `--header` or
`--footer` is enabled.

## Input selection and validation

Pagination accepts exactly one `-i/--input` occurrence. Its literal path or
quoted glob pattern must resolve to exactly one regular, readable file.

Before any output is created, ImageMagick must confirm that the input:

- is a readable raster image;
- contains exactly one frame; and
- has a positive width and height after auto-orientation, cropping, and
  resizing.

Directories, symbolic links, PDFs, vector formats, and animated or other
multi-frame images are rejected. If a pattern resolves to zero files or more
than one file, the error states the number of matches and explains that
pagination requires exactly one image.

Apply ImageMagick auto-orientation before user-requested pixel cropping so the
crop directions refer to the visually oriented image.

## PDF destination behavior

When `-o/--output` is omitted, derive the output beside the input by replacing
its final extension with `.pdf`. For example:

```text
/path/article.png -> /path/article.pdf
```

If the input name has no extension, append `.pdf`. An explicit PDF output must
have a case-insensitive `.pdf` extension. Its parent directory must already
exist and be writable. The output itself must not be a symbolic link.

If the destination exists:

- `-O/--overwrite` permits atomic replacement;
- without `-O`, an interactive terminal offers the existing overwrite or
  keep-both choice;
- choosing keep-both uses the existing `next_available_name` behavior; and
- without `-O` in a non-interactive process, fail instead of waiting for input.

Create the PDF as a temporary regular file in the destination directory,
validate it, and rename it over the final destination only after success. A
failure must leave an existing destination unchanged.

## Page geometry

Let:

```text
PW = paper width in PDF points
PH = paper height in PDF points
M  = uniform margin in output pixels
W  = preprocessed source width in pixels
H  = preprocessed source height in pixels
CW = W + 2M                          page canvas width in pixels
CH = round(CW * PH / PW)             page canvas height in pixels
HB = header band height in pixels, or 0
FB = footer band height in pixels, or 0
S  = CH - 2M - HB - FB               source rows on a full page
O  = overlap in source pixels
T  = S - O                           source-row advance per page
```

`S` and `T` must both be positive integers. The screenshot remains at its
preprocessed pixel dimensions. Never stretch the image and never crop it
horizontally as part of pagination.

For enabled decorations, convert the physical layout measurements to pixels
using the page density: each band is 24 points high and text is inset 12 points
horizontally beyond `M`.

Page source ranges are half-open intervals:

```text
page 1: [0, min(S, H))
page 2: [T, min(T + S, H))
page 3: [2T, min(2T + S, H))
...
```

Stop after the first page whose ending row is `H`. This guarantees complete
coverage and prevents an extra page when `H` lands exactly on a page boundary.

The page count is:

```text
1                                      when H <= S
1 + ceil((H - S) / T)                  when H > S
```

All calculations that determine canvas dimensions and crop coordinates use the
integer values above. The `CH` calculation may use `awk` with a
locale-independent decimal point and must round to the nearest integer.

## Raster page construction

Use lossless PNG temporary pages for both output modes. Use the `CW`, `CH`, and
`S` values calculated above. Place each unscaled source slice at `(M, M + HB)`
on an opaque white canvas.

```text
page_width_px  = CW
page_height_px = CH
left_px        = M
top_px         = M + HB
```

Every full page has exactly `M` pixels of white margin on all four sides. The
source pixels must not be resampled during slicing or placement.

Every page uses the full canvas dimensions. Pad unused space after the final
source row with white. Do not trim any page.

Set separate horizontal and vertical PNG density values:

```text
x_density = 72 * CW / PW
y_density = 72 * CH / PH
```

This maps the integer canvas dimensions to the selected physical paper size
without resampling its pixels. Pass the same density explicitly during PDF
assembly instead of relying only on rounded PNG density metadata.

## PDF construction and validation

Assemble the ordered temporary PNG pages into one PDF with ImageMagick, using
ZIP/Flate compression rather than JPEG compression so page pixels remain
lossless. The PDF must contain only raster page images; do not invoke OCR or add
a text layer.

If ImageMagick is unable to write PDF because of its security policy or missing
delegate support, fail with an actionable message that says PDF writing is not
available and suggests `--output-pages` as a usable fallback. Do not add a
new required dependency in version one.

Before publication, validate the PDF structure directly with standard shell
tools so reopening the PDF does not introduce a Ghostscript dependency. Confirm
that:

- the candidate is a nonempty regular file and not a symbolic link;
- it has a PDF header and end marker;
- its page count equals the number of generated PNG pages; and
- each PDF page has the selected physical dimensions within one PDF point in
  each direction.

## Logging and cleanup

Normal successful output remains concise. Print the same final heading used by
the existing script:

```text
Output file(s):
/absolute/path/to/article.pdf
```

For PNG output, list the destination directory once rather than printing every
page filename.

With `-v/--verbose`, additionally report:

- selected paper size and margin;
- preprocessed source dimensions;
- calculated source slice height and overlap;
- calculated page count;
- each source row range as it is written; and
- PDF assembly and validation, when applicable.

Temporary files and directories must use the existing cleanup trap or an
equivalent trap-safe extension. On interruption or failure, remove temporary
artifacts but do not remove or alter a previously existing destination.

## Mode selection refactor

Implementation should select one explicit internal mode after parsing:

```text
paginate  when --paginate is present
each      when --each is present
zip       when more than one -i is present
montage   otherwise
```

Pagination-specific validation runs after mode selection and before dependency
checks, font discovery, temporary-directory creation, or output creation. Track
whether mode-specific options were explicitly supplied so invalid combinations
can be rejected reliably.

Existing montage, zip, and each behavior must remain unchanged.

## Suggested implementation units

The implementation may use different function names, but it should isolate the
following responsibilities:

```text
validate_paginate_options validate paper, margin, overlap, and mode conflicts
probe_single_image        validate format, frame count, orientation, dimensions
prepare_paginate_source   auto-orient, crop, then resize once
calculate_page_geometry  calculate S, T, page count, canvas, density
render_page_png           crop a source range and place it on a white canvas
validate_pdf              verify PDF markers, page count, and page sizes
run_paginate              coordinate rendering and atomic publication
```

Do not route generated pages through montage finalization. In particular, do
not apply final trim, border, or shadow processing to paginated output.

## Automated acceptance tests

Add tests to the existing test suite for at least these cases:

1. A source shorter than one page produces one padded PDF page.
2. A source exactly two slice heights tall produces exactly two pages, not
   three.
3. A source slightly taller than one slice produces two pages.
4. Every page has the selected Letter dimensions within one point.
5. A4 produces A4 dimensions and a different slice height from Letter.
6. A uniform margin expands the page canvas according to the specified formula
   and leaves exactly the requested number of white pixels on all four sides of
   every full page.
7. `--overlap 0` includes every source row exactly once.
8. Positive overlap repeats exactly the requested number of source rows.
9. Overlap equal to or greater than the slice height is rejected.
10. Existing uniform and side-specific crops are applied before page geometry.
11. Existing width and height constraints are applied after cropping and
    preserve aspect ratio.
12. `--output-pages` writes ordered, lossless `page-NNN.png` files with equal
    canvas dimensions.
13. The final PNG page is white below its remaining source content.
14. PNG output creates a fresh timestamped directory in the current directory,
    or beneath the parent selected by `-o`, creating that parent recursively
    when missing and without merging output.
15. An existing PDF remains unchanged when candidate generation fails.
16. `-O` atomically replaces an existing PDF after successful validation.
17. A non-interactive existing-PDF collision without `-O` fails promptly.
18. Zero matches, multiple matches, a directory, a symlink, a PDF, and a
    multi-frame image are each rejected before output creation.
19. Every incompatible existing option listed above is rejected when explicitly
    supplied.
20. Pagination succeeds without `montage` or a discoverable font when `magick`
    is available.
21. A simulated ImageMagick PDF-policy failure reports the PNG fallback and
    leaves no partial PDF.
22. Existing montage, zip, each, crop, resize, font, and output-collision tests
    continue to pass unchanged.

Use synthetic images with distinct horizontal color bands or numbered patterns
so tests can prove page order, exact source-row coverage, and overlap rather
than checking only page counts.

## Explicit non-goals for version one

- OCR or searchable text
- whitespace-aware or content-aware page breaks
- automatic avoidance of split text, images, or other elements
- landscape orientation
- custom paper dimensions
- different margins for individual sides
- watermarks, borders, or shadows
- transparent PDF pages or configurable margin colors
- multiple input images or batch PDF production
- replacing or merging an existing PNG output directory
- adding Ghostscript, `img2pdf`, or another required dependency

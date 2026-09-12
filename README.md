# screenshots

`screenshots.sh` is a small Bash utility for preparing and combining screenshot
images with ImageMagick. It can create one montage, pair corresponding images
from several sets, process every image independently, or split one long
screenshot into page-sized PDF or PNG output.

## Requirements

- Bash 3.2 or newer
- [ImageMagick](https://imagemagick.org/) with `magick` on `PATH`
- The separate ImageMagick `montage` command for montage and zip modes
- A discoverable system font for montage and zip modes, and for pagination
  when a header or footer is enabled

On macOS with Homebrew:

```bash
brew install imagemagick
```

## Installation

Clone the repository and put the script somewhere on your `PATH`:

```bash
git clone https://github.com/stansult/screenshots.git
cd screenshots
ln -s "$PWD/screenshots.sh" /usr/local/bin/screenshots.sh
```

You can also run it directly from the cloned directory with
`./screenshots.sh`.

## Usage

```text
screenshots.sh -i PATTERN -o FILE [options]                  # montage
screenshots.sh -i PATTERN -i PATTERN [-o DIR] [options]      # zip
screenshots.sh -i PATTERN --each [-o DIR] [options]          # each
screenshots.sh -i IMAGE --paginate [-o FILE.pdf] [options]   # paginated PDF
screenshots.sh -i IMAGE --paginate --output-pages [-o DIR]   # PNG pages
```

Always quote input patterns so the script, rather than the calling shell,
expands them.

Use the short general help for discovery, or open a complete mode reference:

```bash
screenshots.sh --help
screenshots.sh --help montage
screenshots.sh --help zip
screenshots.sh --help each
screenshots.sh --help paginate
```

`-h` is an exact alias for `--help`, including topic forms such as
`screenshots.sh -h paginate`.

### Montage mode

One input pattern produces a single grid image. Matches are pathname-sorted.
The default output is `output.png`; when the output itself matches the input
pattern, it is excluded from the inputs.

```bash
screenshots.sh -i "usage*.png" -o usage-grid.png
screenshots.sh -i "usage*.png" -c 50 --width 750 --shadow
screenshots.sh -i "*.png" --tile 5x0 --gap 20x20
```

### Zip mode

Two or more input patterns enable zip mode. Each pattern is independently
sorted bytewise, then files at matching positions are placed together in a
montage. Every pattern must match the same number of files, and pattern order
determines the left-to-right order within each montage.

```bash
screenshots.sh \
  -i "android/*.png" \
  -i "ios/*.png" \
  -o comparisons
```

Results are written as `1.png`, `2.png`, and so on in a new timestamped
`zip-*` directory. Its default tile layout is `Nx1` for N patterns. An explicit
tile layout overrides that default, but its column count is capped at N.

### Each mode

Each mode transforms every matched image separately without creating a
montage:

```bash
screenshots.sh -i "usage/*.png" --each -c 50 --width 750
```

Results retain their original filenames and are written to a new timestamped
`each-*` directory.

### Paginate mode

Paginate mode accepts exactly one single-frame raster image. It slices the
image from top to bottom into portrait Letter, A4, or Legal pages. Output is
raster-only and no OCR or text layer is added.

Without an explicit output, the PDF is written beside the source using the
source basename:

```bash
screenshots.sh -i long-article.png --paginate
# creates long-article.pdf
```

Choose a paper size, add uniform white pixel margins, or repeat source rows
between pages:

```bash
screenshots.sh -i long-article.png --paginate --paper a4 \
  --margin 40 --overlap 20 -o article.pdf
```

Optional print-style headers and footers reserve space inside the fixed-ratio
page. The header shows the image creation date and time on the left, with
optional title text on the right. The footer shows `page/total-pages` on the
right:

```bash
screenshots.sh -i long-article.png --paginate --header --footer \
  --header-line --footer-line --title "Article title" -o article.pdf
```

Creation time is selected from embedded capture metadata, a recognized
GoFullPage filename timestamp, filesystem creation time, then filesystem
modification time. The header uses a compact format such as
`Sep 10, 2026 · 11:52 PM`. Long titles are shortened with an ellipsis.

Use `--output-pages` to create lossless PNG pages instead of a PDF. A fresh
`pages-<timestamp>` directory is created in the current directory:

```bash
screenshots.sh -i long-article.png --paginate \
  --output-pages
```

Use `-o` to select a parent directory. It is created when missing:

```bash
screenshots.sh -i long-article.png --paginate \
  --output-pages -o exports
```

Pages are named `page-001.png`, `page-002.png`, and so on. Every page has the
selected paper ratio and identical pixel dimensions; unused space on the final
page is white. Page breaks are fixed geometrically and do not inspect content.

Existing crop and resize options work in paginate mode. Auto-orientation,
cropping, and resizing happen before margins and page slicing. Montage and
appearance options cannot be combined with `--paginate`.

## Option reference

The mode-specific help pages are the authoritative command-line reference.
This section summarizes every public option and the important compatibility
rules.

| Option group | Montage | Zip | Each | Paginate |
| --- | :---: | :---: | :---: | :---: |
| Crop and resize | Yes | Yes | Yes | Yes |
| Tile, gap, gravity, background | Yes | Yes | Rejected | Rejected |
| Trim, border, shadow | Yes | Yes | Yes | Rejected |
| `--font` | Yes | Yes | Rejected | Header/footer |
| Pagination options | Rejected | Rejected | Rejected | Yes |
| `-O`, `--overwrite` | Yes | Rejected | Rejected | PDF only |

Supplying two or more `-i` patterns selects zip mode. `--each` requires exactly
one input pattern. `--paginate` requires exactly one input occurrence resolving
to one readable, regular, non-symlink, single-frame raster image.

### Input and output

- `-i`, `--input PATTERN` selects files with a quoted glob. Repeat it to use
  zip mode.
- `-o`, `--output FILE|DIR` has mode-specific meaning: montage output file;
  zip/each parent directory; pagination PDF filename; or PNG parent directory
  with `--output-pages`. It must be a literal path and cannot be repeated.
- `-e`, `--each` processes matched files separately instead of creating a
  montage.
- `-p`, `--paginate` slices exactly one long image into pages.
- `--output-pages` writes PNG pages to a fresh `pages-<timestamp>` directory
  instead of a PDF. With this option, `-o DIR` selects its parent directory,
  which is created recursively when missing.

### Sizing and cropping

- `-w`, `--width N` shrinks images to a maximum pixel width; omitted by
  default. It preserves aspect ratio and never enlarges.
- `-H`, `--height N` similarly sets an optional maximum pixel height. Width
  and height may be combined as a bounding box.
- `-c`, `--crop [N]` crops `N` pixels from every side before resizing.
- `-ct`/`--crop-top`, `-cb`/`--crop-bottom`, `-cl`/`--crop-left`, and
  `-cr`/`--crop-right` optionally add side-specific crop amounts. A bare crop
  flag or zero has no effect. Repeating the same crop flag causes that flag to
  be ignored with a notice.

### Pagination

- `--paper SIZE` selects `letter` (default), `a4`, or `legal`.
- `--margin N` adds `N` white output pixels on every side (default: `0`).
- `--overlap N` repeats `N` preprocessed source rows between pages (default:
  `0`); it must be smaller than the calculated slice height.
- `--header` adds a 6-point creation date/time header.
- `--footer` adds 6-point `page/total-pages` numbering.
- `--header-line` adds a 0.25-point `#d0d0d0` rule below an enabled header.
- `--footer-line` adds the same rule above an enabled footer.
- `--title TEXT` adds header-right text and requires `--header`.
- `--page-font-size N` overrides the 6-point header/footer font size with a
  positive value below 24 points and requires `--header` or `--footer`.
- `--font FILE` selects the visible header/footer font and requires `--header`
  or `--footer`; a system font is discovered automatically when omitted.

Headers and footers use 24-point bands and a 12-point horizontal text inset.
These reserved bands and the outer margin remain inside the selected paper
ratio.

All options in this subsection require `--paginate`. `-O` is invalid with
`--output-pages`; PNG page directories are never overwritten or merged.

### Montage layout

- `-t`, `--tile COLSxROWS` sets the montage grid. A zero lets ImageMagick
  determine that dimension automatically. The montage default is `10x0`; zip
  defaults to `Nx1`, where N is the number of input patterns.
- `-g`, `--gap XxY` sets horizontal and vertical pixel gaps (default:
  `15x15`).
- `-G`, `--gravity VALUE` sets tile alignment (default: `north`). Accepted
  values are `north`, `south`, `east`, `west`, `center`, `northeast`,
  `northwest`, `southeast`, and `southwest`.
- `--background COLOR` sets the montage background (default: `transparent`).
  ImageMagick color names and values such as `white` and `#ff0000` are valid.

### Appearance

- `--trim` enables final trimming; this is the montage and zip default.
- `--no-trim` disables final trimming; this is the each-mode default.
- `--trim-fuzz N` sets trim tolerance as a percentage (default: `0`) and is
  rejected when trimming is disabled.
- `-b`, `--border [N]` adds a border. A bare flag uses width `1`, and an
  explicit width must be positive; in montage and zip modes it is applied to
  individual tiles.
- `--border-color COLOR` sets border color (default: `black`) and requires
  `--border`.
- `-s`, `--shadow` adds a drop shadow; disabled by default. It is applied to
  the finalized montage in montage/zip mode and to each output in each mode.
- `--shadow-color COLOR` sets shadow color (default: `gray`) and requires
  `--shadow`.
- `--font FILE` selects the font used internally by ImageMagick in montage and
  zip modes, or the visible decoration font in pagination. A system font is
  discovered automatically when omitted. Each mode rejects it because it does
  not render text.

### Execution controls

- `-O`, `--overwrite` overwrites an existing montage or paginated PDF without
  prompting. It is rejected in zip/each mode, which always create fresh output
  directories, and with `--output-pages`.
- `-v`, `--verbose` prints processing details.
- `-h`, `--help` shows concise general help. Either spelling accepts
  `montage`, `zip`, `each`, or `paginate` for complete mode help.

### Output behavior

- Montage writes `output.png` by default and creates a missing output parent.
  If its destination exists, an interactive terminal offers overwrite or
  keep-both; `-O` skips that prompt.
- Zip and each output go into fresh timestamped directories. Their selected
  parent and any missing ancestors are created automatically; a same-second
  name collision receives a numeric suffix.
- Paginated PDF defaults beside the input and requires an existing writable
  parent. An existing PDF prompts in an interactive terminal, fails safely in
  non-interactive use, or is replaced atomically with `-O`.
- Paginated PNG output uses a fresh timestamped directory. Its parent is
  created automatically, but must be a real writable directory rather than a
  symbolic link. A collision receives a numeric suffix.

Crop and shrink-only resize run per input in every mode; pagination performs
auto-orientation first. Montage and zip then apply per-tile borders while
combining, followed by final trimming and shadows. Each mode applies trim,
border, and shadow to every independent output. Pagination instead slices the
preprocessed image and reserves margins and optional header/footer bands inside
the final fixed-ratio page rather than adding them outside it.

## Troubleshooting

### `montage: unable to read font`

Some ImageMagick installations have no registered default font. Even a montage
without visible labels can then fail while ImageMagick initializes text
rendering. The script works around this by discovering a readable system font
and passing it to ImageMagick explicitly.

To select a particular font instead:

```bash
screenshots.sh -i "usage/*.png" --font /path/to/font.ttf
```

If automatic discovery fails, the script exits with instructions to install a
system font or use `--font`.

### PDF writing is unavailable

Some ImageMagick installations disable PDF writing through their security
policy. Paginate mode reports this condition without leaving a partial PDF.
PNG pagination remains available without PDF support:

```bash
screenshots.sh -i long-article.png --paginate \
  --output-pages
```

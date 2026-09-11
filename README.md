# screenshots

`screenshots.sh` is a small Bash utility for preparing and combining screenshot
images with ImageMagick. It can create one montage, pair corresponding images
from several sets, process every image independently, or split one long
screenshot into page-sized PDF or PNG output.

## Requirements

- Bash 3.2 or newer
- [ImageMagick](https://imagemagick.org/) with the `magick` and `montage`
  commands available on `PATH`

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
screenshots.sh -i PATTERN -o FILE [options]                 # montage
screenshots.sh -i PATTERN -i PATTERN [-o DIR] [options]     # zip
screenshots.sh -i PATTERN --each [-o DIR] [options]          # each
screenshots.sh -i IMAGE --paginate [-o FILE.pdf] [options]   # paginated PDF
screenshots.sh -i IMAGE --paginate --output-pages [-o DIR]   # PNG pages
```

Always quote input patterns so the script, rather than the calling shell,
expands them.

### Montage mode

One input pattern produces a single grid image. The default output is
`output.png`.

```bash
screenshots.sh -i "usage*.png" -o usage-grid.png
screenshots.sh -i "usage*.png" -c 50 --width 750 --shadow
screenshots.sh -i "*.png" --tile 5x0 --gap 20x20
```

### Zip mode

Two or more input patterns enable zip mode. Each pattern is independently
sorted, then files at matching positions are placed together in a montage.
Every pattern must match the same number of files.

```bash
screenshots.sh \
  -i "android/*.png" \
  -i "ios/*.png" \
  -o comparisons
```

Results are written as `1.png`, `2.png`, and so on in a new timestamped
`zip-*` directory.

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

Use `--output-pages` to create lossless PNG pages instead of a PDF. A fresh
`pages-<timestamp>` directory is created in the current directory:

```bash
screenshots.sh -i long-article.png --paginate \
  --output-pages
```

Use `-o` to select an existing parent directory:

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

## Common options

### Input and output

- `-i`, `--input PATTERN` selects files with a quoted glob. Repeat it to use
  zip mode.
- `-o`, `--output FILE|DIR` sets the output file in montage mode or the parent
  directory in zip and each modes.
- `-e`, `--each` processes matched files separately instead of creating a
  montage.
- `-p`, `--paginate` slices exactly one long image into pages.
- `--output-pages` writes PNG pages to a fresh `pages-<timestamp>` directory
  instead of a PDF. With this option, `-o DIR` selects its parent directory.

### Sizing and cropping

- `-w`, `--width N` resizes images to a maximum width.
- `-H`, `--height N` resizes images to a maximum height.
- `-c`, `--crop N` crops `N` pixels from every side before resizing.
- `-ct`, `-cb`, `-cl`, and `-cr` add extra cropping to the top, bottom, left,
  and right sides respectively.

### Pagination

- `--paper SIZE` selects `letter` (default), `a4`, or `legal`.
- `--margin N` adds `N` white output pixels on every side.
- `--overlap N` repeats `N` preprocessed source rows between pages.

### Montage layout

- `-t`, `--tile COLSxROWS` sets the montage grid. A zero lets ImageMagick
  determine that dimension automatically.
- `-g`, `--gap XxY` sets the horizontal and vertical gaps between tiles.

### Appearance

- `-b`, `--border [N]` adds a border, optionally with a pixel width.
- `-s`, `--shadow` adds a drop shadow.
- `--font FILE` selects the font file used internally by ImageMagick in
  montage and zip modes. A system font is discovered automatically when this
  option is omitted.

### Execution controls

- `-O`, `--overwrite` overwrites an existing montage or paginated PDF without
  prompting. PNG page directories are never overwritten or merged.
- `-v`, `--verbose` prints processing details.
- `-h`, `--help` shows every option and additional examples.

Crop and resize are applied to each input before montaging. Final trimming,
borders, and shadows are applied afterward. Run `screenshots.sh --help` for the
complete option reference.

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

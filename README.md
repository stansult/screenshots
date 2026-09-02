# screenshots

`screenshots.sh` is a small Bash utility for preparing and combining screenshot
images with ImageMagick. It can create one montage, pair corresponding images
from several sets, or process every image independently.

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

## Common options

### Input and output

- `-i`, `--input PATTERN` selects files with a quoted glob. Repeat it to use
  zip mode.
- `-o`, `--output FILE|DIR` sets the output file in montage mode or the parent
  directory in zip and each modes.
- `-e`, `--each` processes matched files separately instead of creating a
  montage.

### Sizing and cropping

- `-w`, `--width N` resizes images to a maximum width.
- `-H`, `--height N` resizes images to a maximum height.
- `-c`, `--crop N` crops `N` pixels from every side before resizing.
- `-ct`, `-cb`, `-cl`, and `-cr` add extra cropping to the top, bottom, left,
  and right sides respectively.

### Montage layout

- `-t`, `--tile COLSxROWS` sets the montage grid. A zero lets ImageMagick
  determine that dimension automatically.
- `-g`, `--gap XxY` sets the horizontal and vertical gaps between tiles.

### Appearance

- `-b`, `--border [N]` adds a border, optionally with a pixel width.
- `-s`, `--shadow` adds a drop shadow.

### Execution controls

- `-O`, `--overwrite` overwrites an existing montage without prompting.
- `-v`, `--verbose` prints processing details.
- `-h`, `--help` shows every option and additional examples.

Crop and resize are applied to each input before montaging. Final trimming,
borders, and shadows are applied afterward. Run `screenshots.sh --help` for the
complete option reference.

## Troubleshooting

### `montage: unable to read font`

Some ImageMagick installations have no registered default font. Even a montage
without visible labels can then fail while ImageMagick initializes text
rendering. Confirm the problem with:

```bash
magick -list font
```

If that produces no font entries, repair the ImageMagick font configuration or
install a font package recognized by ImageMagick. Automatic font discovery in
the script is planned as a compatibility improvement.

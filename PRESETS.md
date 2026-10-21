# Presets

Presets are named bundles of existing `screenshots.sh` options. A preset may
select a processing mode. Explicit options override preset values regardless
of whether they appear before or after `--preset`. Only one preset may be used
per command.

```bash
screenshots.sh -i document.png --preset paginated-document
```

Use `screenshots.sh --help presets` or `screenshots.sh -h presets` for a
concise command-line summary.

When a preset is selected, the script prints a copyable, shell-escaped effective
command before processing. Simple title fields such as `{stem}` are shown
without unnecessary backslashes. The command shows the preset options that
remain after overrides, along with the command-line options; `--preset` itself
is omitted. With `--verbose`, the script also lists any preset options
superseded by explicit options and what replaced them. It omits that line when
no preset options were superseded.

Preset definitions live in `presets.conf` beside the script and are read each
time it starts. Keep that file with `screenshots.sh`. To add one, copy a
section, rename its heading, and edit the options:

```ini
[paginated-document]
--paginate
--header
--margin=100
--title={stem}
```

Use one long option per line. Write options that take a value as
`--option=VALUE`; everything after the first `=` is the value, so spaces are
allowed. Blank lines and lines beginning with `#` are ignored. Presets can
include existing processing and appearance options, but not input/output
paths, overwrite, verbosity, help, preset selection, or output type. The script
validates the configuration at startup and lists configured preset names in help and
missing/unknown-preset errors. This repository-maintained file is the place
to add presets; there is no separate per-user config or CLI creation feature.

## Title fields

Title fields work in every explicit `--title` value as well as preset-provided
titles:

| Field | Expansion for `report.final.png` |
| --- | --- |
| `{filename}` | `report.final.png` |
| `{stem}` | `report.final` |

Use `{{` for a literal `{` and `}}` for a literal `}`. Unknown fields and
unmatched braces are rejected rather than printed literally.

```bash
screenshots.sh -i report.final.png --paginate --header \
  --title "Copy of {filename}"
```

## `paginated-document`

Creates a paginated document with identifying header and footer decorations
and a small amount of repeated content across page breaks.

```bash
screenshots.sh -i document.png --preset paginated-document
```

The preset supplies:

```text
--paginate
--header
--footer
--header-line
--footer-line
--margin 100
--margin-left 100
--margin-right 100
--overlap 50
--title "{stem}"
```

The uniform `--margin 100` applies 100 output pixels to all four sides. The
additional `--margin-left 100` and `--margin-right 100` bring the left and
right margins to 200 pixels each. The preset does not select an output path or
type, paper size, font, crop, resize, or overwrite behavior.

### Overrides

Explicit values win in either argument order:

```bash
screenshots.sh -i document.png --preset paginated-document \
  --overlap 20 --title "Reviewed document"

screenshots.sh -i document.png --overlap 20 \
  --title "Reviewed document" --preset paginated-document
```

Explicit `--margin`, `--margin-left`, and `--margin-right` values each replace
the corresponding preset value. Side-specific margins remain additional to
the uniform margin:

```bash
screenshots.sh -i document.png --preset paginated-document --margin 30 -ml 20
```

Use the negative forms to disable preset-provided decorations:

```bash
screenshots.sh -i document.png --preset paginated-document \
  --no-header-line --no-footer-line
```

The available preset overrides are `--no-header`, `--no-footer`,
`--no-header-line`, and `--no-footer-line`. They are accepted only with a
preset because they otherwise have no effect. Disabling a preset-provided
header also removes its default title unless an explicit `--title` is given;
an explicit title still requires an enabled header.

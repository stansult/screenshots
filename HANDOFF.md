# Handoff for continuing `screenshots.sh` work

## Start here

This repository is `/Users/stansult/dev/screenshots`.

Before doing any work, read:

1. `~/.codex/AGENTS.md`
2. this file
3. `PAGINATION-SPEC.md` when changing pagination
4. `MODE-HELP-SPEC.md` when implementing the deferred help refactor

The global instructions require a realistic estimate of Codex elapsed time
before every task. If the estimate exceeds four minutes, wait for explicit
approval. Proofread user-facing text carefully before sending it. The preceding
thread produced several visibly corrupted sentences, so the user is starting a
new thread to determine whether the problem is isolated to that thread.

## Working-tree state

There are uncommitted changes. Do not discard them.

At handoff time, `git status --short` reports:

```text
 M README.md
 M screenshots.sh
 M tests/README.md
 M tests/test.sh
?? MODE-HELP-SPEC.md
?? PAGINATION-SPEC.md
```

`HANDOFF.md` itself will also appear as untracked after this handoff is created.
No commit or push has been made.

## Pagination implementation

The first version described by `PAGINATION-SPEC.md` has been implemented in
`screenshots.sh`. It accepts exactly one single-frame raster image, slices it
geometrically into portrait Letter, A4, or Legal pages, and produces either a
raster-only PDF or lossless PNG pages. It performs no OCR or content-aware page
breaking.

Supported preprocessing order is auto-orientation, crop, resize, then
pagination. Uniform margins and overlap are measured in pixels. The output page
ratio is calculated after margins are applied. The final partial page is padded
with white rather than stretched.

The four pagination output forms are:

```bash
screenshots.sh -i long.png -p
# PDF beside the input: long.pdf

screenshots.sh -i long.png -p -o result.pdf
# PDF at the explicit path

screenshots.sh -i long.png -p --output-pages
# PNGs in ./pages-<timestamp>/

screenshots.sh -i long.png -p --output-pages -o exports
# PNGs in exports/pages-<timestamp>/
```

For PNG output, `--output-pages` is a flag without an argument. With that flag,
`-o` names a writable parent directory and creates it recursively when missing.
A trailing slash is optional.
Without `--output-pages`, `-o` must name a `.pdf` file. The former
`--output-pages DIR` syntax is intentionally rejected.

Every PNG run creates a fresh `pages-<timestamp>` directory. If that name
already exists, the script adds the first available numeric suffix. Pages are
named `page-001.png`, `page-002.png`, and so on. Output is rendered in a hidden
sibling directory and published only after all pages validate; existing page
directories are never merged or replaced. `-O` remains invalid with PNG-page
output.

PDF output is also staged before publication. In an interactive terminal, an
existing PDF prompts the user to overwrite it or keep both files. In
non-interactive use, the command fails unless `-O` is supplied. ImageMagick
PDF-policy failures suggest `--output-pages` as the fallback.

The user manually tested PDF pagination with a 2670 x 8696 image. It produced
three Letter pages and exercised the interactive overwrite prompt successfully.

## Verification completed

After the automatic PNG-folder change, these checks passed:

```text
bash -n screenshots.sh
bash -n tests/test.sh
./tests/test.sh
git diff --check
```

The regression result was:

```text
29 passed, 0 failed, 0 skipped
```

Tests cover the four output forms, both `exports` and `exports/`, repeated PNG
runs, margins, overlap, preprocessing order, paper dimensions, PDF replacement,
invalid inputs, rejected legacy syntax, atomic publication, and the PDF-writer
fallback.

ShellCheck reports five warnings in older montage, zip, and each code. They are
the pre-existing intentional-globbing and arithmetic-style warnings; no new
pagination warning was introduced.

## Pagination headers and footers

Optional print-style headers and footers are implemented. `--header` renders a
6-point creation timestamp at top left; `--title TEXT` adds right-aligned text
and requires `--header`. `--footer` renders `page/total-pages` at bottom right.
Both use separate 24-point white bands inside the fixed-ratio page and outside
the screenshot slice. Text has an automatic 12-point horizontal inset in
addition to `--margin`. `--page-font-size N` overrides the 6-point default.
`--header-line` and `--footer-line` independently add thin gray separator
rules. Long titles are truncated with an ellipsis while the timestamp remains
intact.

Timestamp priority is embedded EXIF capture time, a recognized GoFullPage
filename timestamp, filesystem creation time, then filesystem modification
time. Filesystem creation and date formatting support macOS and GNU/Linux
forms, with local timezone display such as `Sep 10, 2026 · 11:52 PM`.

## Deferred mode-specific help

`MODE-HELP-SPEC.md` describes a separate help-system refactor: short general
help plus mode-specific help for montage, zip, each, and pagination. The user
agreed to defer that work until after pagination. It has not been implemented.
The specification now reflects the automatic `pages-<timestamp>` interface.

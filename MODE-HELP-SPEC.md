# Mode-specific help specification

## Status

Implemented after screenshot pagination. This document remains the acceptance
specification for the general and mode-specific help system.

This document specifies help behavior only. It must not change the established
runtime syntax or introduce subcommands.

## Objective

Replace the single large help page with:

- one concise general help page; and
- one detailed help page for each mode: `montage`, `zip`, `each`, and
  `paginate`.

The general page is for discovery. A mode page is the complete reference for
using that mode.

## Supported invocations

General help:

```text
screenshots.sh -h
screenshots.sh --help
```

Mode-specific help:

```text
screenshots.sh --help montage
screenshots.sh --help zip
screenshots.sh --help each
screenshots.sh --help paginate
screenshots.sh -h montage
screenshots.sh -h zip
screenshots.sh -h each
screenshots.sh -h paginate
```

For modes that already have an explicit selector, also support:

```text
screenshots.sh --each --help
screenshots.sh --paginate --help
```

Do not add `montage`, `zip`, `each`, or `paginate` as positional subcommands for
normal execution. Do not add separate flags such as `--help-paginate`.

Version one of this help restructuring does not need to support
`--help=paginate`.

## Help parsing and precedence

Recognize a help request before normal argument validation, input expansion,
dependency checks, font discovery, temporary-directory creation, prompts, or
output creation.

Apply these rules:

1. Bare `-h` or bare `--help` displays general help, unless the same command
   contains exactly one explicit mode selector: `--each` or `--paginate`.
2. `--each --help` and `--help --each` both display each-mode help.
3. `--paginate --help` and `--help --paginate` both display pagination help.
4. `-h TOPIC` and `--help TOPIC` display identical named mode help. Topic
   matching is case-sensitive and accepts only `montage`, `zip`, `each`, or
   `paginate`.
5. A named topic combined with a different explicit mode selector is an error.
   For example, `--paginate --help each` is invalid.
6. Both explicit selectors in one help request are an error. For example,
   `--each --paginate --help` is invalid.
7. More than one help occurrence is an error, including repeated identical
   requests.
8. Unknown topics and extra positional arguments after a help topic are errors.
9. Other ordinary execution options may appear before or after a valid help
   request and are ignored. Help must remain available even when those options
   are incomplete or invalid. For example, `--width nope --help paginate`
   still displays pagination help.

Valid help requests exit with status `0`. Invalid help requests print a concise
error, list the accepted topics, and exit with status `1`.

## General help page

Keep the general page short enough to scan in one terminal screen where
practical. It contains, in this order:

1. A one-sentence program description.
2. The four command forms:

   ```text
   screenshots.sh -i PATTERN [-o FILE] [options]                  # montage
   screenshots.sh -i PATTERN -i PATTERN [-o DIR] [options]       # zip
   screenshots.sh -i PATTERN --each [-o DIR] [options]           # each
   screenshots.sh -i IMAGE --paginate [output option] [options]  # paginate
   ```

3. One sentence describing each mode.
4. The options meaningful across all four modes:
   `-i/--input`, `-o/--output`, crop options, resize options,
   `-v/--verbose`, and `-h/--help`. The description of `-o/--output` must state
   that its meaning depends on the mode.
5. The four mode-help commands.
6. One short example per mode.

Do not put full option descriptions, detailed ordering rules, troubleshooting,
or every default on the general page.

## Montage help page

The montage page contains:

- its exact command form;
- quoted-glob input behavior and sorting;
- output filename and default behavior;
- overwrite and keep-both behavior;
- crop and resize ordering;
- tile, gap, gravity, background, trim, border, shadow, and font options;
- the order in which transformations are applied;
- output-file exclusion from the input glob;
- relevant font troubleshooting; and
- at least three examples, including a single-row montage.

Do not describe zip pairing, each-mode output directories, or pagination
geometry on this page.

## Zip help page

The zip page contains:

- its exact command form;
- activation through two or more `-i/--input` occurrences;
- independent expansion and bytewise sorting of each pattern;
- equal-list-length validation;
- positional pairing and left-to-right ordering;
- the default `Nx1` tile layout and explicit layout overrides;
- creation of a fresh timestamped `zip-*` directory beneath `-o` or the current
  directory;
- applicable crop, resize, montage-layout, and appearance options; and
- at least two examples, including Android/iOS comparison.

Do not describe montage overwrite prompts, each-mode processing, or pagination
geometry on this page.

## Each help page

The each page contains:

- its exact command form;
- activation through `-e/--each`;
- the requirement for exactly one input pattern;
- independent processing without montage;
- creation of a fresh timestamped `each-*` directory beneath `-o` or the
  current directory;
- preservation of input basenames;
- crop, resize, trim, border, and shadow behavior and ordering;
- the fact that montage-only options have no effect or are rejected, matching
  the runtime behavior at the time this help refactor is implemented; and
- at least two examples.

Do not describe zip pairing or pagination geometry on this page.

## Pagination help page

The pagination page must reflect the implemented pagination behavior rather
than copying an older draft of `PAGINATION-SPEC.md`. It contains:

- both PDF and PNG-page command forms;
- the exactly-one-image requirement;
- default PDF naming;
- `--output-pages` behavior, including automatic `pages-<timestamp>` folders
  and `-o DIR` selecting a parent directory that is created when missing;
- supported paper sizes and the default;
- pixel-based uniform margins;
- optional pixel overlap and its validation;
- crop and resize preprocessing order;
- optional 6-point creation-time headers, optional titles, page-count
  footers, and independent separator rules;
- optional explicit decoration font selection with automatic discovery as the
  default;
- raster-only output and the absence of OCR;
- fixed geometric breaks and final-page white padding;
- PDF overwrite behavior and PNG-directory collision behavior;
- options accepted and rejected in pagination mode;
- the ImageMagick PDF-writing failure message and PNG fallback; and
- at least four examples covering default PDF, A4 with margins, overlap, and
  PNG pages.

Do not mention deferred features.

## Implementation structure

Replace the current monolithic `usage()` function with focused renderers. Names
may differ, but responsibilities should correspond to:

```text
usage_general
usage_montage
usage_zip
usage_each
usage_paginate
usage_topics_error
handle_help_request
```

Avoid copying shared option text into five unrelated heredocs where practical.
Small shared rendering helpers are preferred for crop, resize, and common
execution options, provided each resulting help page remains easy to read in
the source.

`handle_help_request` must inspect arguments without mutating the argument list
used by normal execution when no help request is present.

The README may remain more narrative than command help, but its command forms,
defaults, and links to mode-specific help must agree with the executable.

## Compatibility requirements

- Existing non-help commands retain their syntax and behavior.
- Generic `-h` and `--help` remain successful and non-mutating.
- Help does not require ImageMagick, `montage`, a font, readable input files, or
  a writable output directory.
- Help output goes to standard output.
- Invalid help requests write their errors to standard error.
- No help request prompts for input.
- Bash 3.2 compatibility is retained.

## Automated acceptance tests

Add tests for at least these cases:

1. `-h` and `--help` show the same general page and exit `0`.
2. General help names all four modes and all four topic commands.
3. General help does not contain the detailed pagination formulas or extended
   font troubleshooting.
4. Each valid `-h TOPIC` and `--help TOPIC` command displays only the requested
   mode page, produces identical output, and exits `0`.
5. `--each --help` and `--help --each` display each-mode help.
6. `--paginate --help` and `--help --paginate` display pagination help.
7. An unknown topic prints the accepted topics and exits `1`.
8. Conflicting named and explicit modes are rejected identically for both help
   spellings.
9. `--each --paginate --help` is rejected.
10. Repeated help options are rejected.
11. Extra positional arguments after a named topic are rejected.
12. Invalid or incomplete ordinary options do not prevent valid help from
    displaying.
13. Every help form succeeds with `magick` and `montage` absent from `PATH`.
14. No help form creates a file or directory.
15. Existing non-help regression tests continue to pass unchanged.

## Completion criterion

This follow-up is complete when all five help pages are implemented, their
documented forms and defaults match runtime behavior, the README is consistent,
and all new and existing tests pass.

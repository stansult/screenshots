# Preset design notes

## Current: repository-maintained presets

`presets.conf` beside `screenshots.sh` is the canonical preset definition
file. Add a preset by copying a section, renaming it, and editing its option
lines. The script reads this file at startup; no preset-specific code should
be needed for options supported by the command-line parser.

## Deferred: validation of unused presets

The config loader performs basic format checks across the file, but semantic
validation follows the normal command-line path only for selected preset
options that are not superseded by explicit command-line options. As a result,
an unused preset with an invalid option value or incompatible options can
remain unnoticed until selected. This is accepted for now. If this becomes a
problem, consider validating all preset definitions through the main script's
existing option parsing and validation logic, rather than duplicating those
rules in a separate parser.

## Deferred: separate per-user preset overrides

There is no second, personal configuration path or CLI for creating presets.
If one is considered later, keep it small: preset names, inline option
definitions, and comments, with explicit precedence relative to the bundled
`presets.conf`.

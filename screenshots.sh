#!/bin/bash

set -euo pipefail

preset_names=()
preset_option_presets=()
preset_option_names=()
preset_option_values=()
preset_option_has_values=()
preset_config_file=""
preset_name=""
preset_args=()
expanded_argv=()
effective_args=()
superseded_preset_options=()
superseded_by_options=()

usage_common_transform_options() {
    cat <<'EOF'
  -w, --width N          Shrink to a maximum width, preserving aspect ratio
  -H, --height N         Shrink to a maximum height, preserving aspect ratio
  -c, --crop [N]         Crop N pixels from every side before resizing
EOF
    if [ "${1:-concise}" = "detailed" ]; then
        cat <<'EOF'
  -ct, --crop-top [N]    Add top crop before resizing
  -cb, --crop-bottom [N] Add bottom crop before resizing
  -cl, --crop-left [N]   Add left crop before resizing
  -cr, --crop-right [N]  Add right crop before resizing
EOF
    else
        cat <<'EOF'
  -ct/-cb/-cl/-cr [N]    Add top/bottom/left/right crop before resizing
EOF
    fi
    cat <<'EOF'
  -v, --verbose          Print additional timestamped actions
  -h, --help             General help; use either flag with MODE for details
EOF
}

usage_general() {
    cat <<'EOF'
screenshots.sh prepares, combines, or paginates screenshots with ImageMagick.

Usage:
  screenshots.sh -i PATTERN [-o FILE] [options]                 # montage
  screenshots.sh -i PATTERN -i PATTERN [-o DIR] [options]       # zip
  screenshots.sh -i PATTERN --each [-o DIR] [options]           # each
  screenshots.sh -i IMAGE --paginate [output option] [options]  # paginate

Modes:
  montage   Combine one sorted input set into a grid image.
  zip       Pair equally sized sorted input sets into comparison montages.
  each      Transform every matched image independently.
  paginate  Slice one raster screenshot into fixed-ratio PDF or PNG pages.

Common options:
  -i, --input PATTERN    Quoted input glob; repeat to select zip mode
  -o, --output FILE|DIR  Output meaning depends on the selected mode
  --preset NAME          Apply one named option bundle; explicit options win
EOF
    usage_common_transform_options
    cat <<'EOF'

Detailed help:
  screenshots.sh --help montage
  screenshots.sh --help zip
  screenshots.sh --help each
  screenshots.sh --help paginate
  screenshots.sh --help presets

Examples:
  screenshots.sh -i "*.png" -o grid.png
  screenshots.sh -i "android/*.png" -i "ios/*.png" -o comparisons
  screenshots.sh -i "*.png" --each --width 750
  screenshots.sh -i article.png --paginate -o article.pdf

Operational output uses local [HH:MM:SS] timestamps. A local [YYYY-MM-DD]
line appears before the first message and again at the end only if the date
changed. Help output remains undecorated.
EOF
}

usage_presets() {
    cat <<'EOF'
Presets

Usage:
  screenshots.sh -i IMAGE --preset NAME [explicit options]

Description:
  Apply one named bundle of existing options. A preset may select a mode.
  Explicit options override preset values regardless of argument order. Only
  one preset may be used per command.

Available presets:
EOF
    local preset
    for preset in "${preset_names[@]}"; do
        printf '  %s\n' "$preset"
    done
    cat <<'EOF'

Title fields:
  {filename}          Complete input filename, including its extension
  {stem}              Input filename without its final extension
  {{                  Literal opening brace
  }}                  Literal closing brace

Preset overrides:
  --no-header, --no-footer, --no-header-line, --no-footer-line

Examples:
  screenshots.sh -i document.png --preset NAME
  screenshots.sh -i document.png --preset NAME --overlap 20
  screenshots.sh -i document.png --title "Copy of {filename}" --paginate --header

See PRESETS.md for the complete preset catalog and expansion details.
EOF
}

resolve_preset_config_path() {
    local script_path="${BASH_SOURCE[0]}" script_dir link_target
    while [ -L "$script_path" ]; do
        script_dir="$(cd -P "$(dirname "$script_path")" >/dev/null 2>&1 && pwd)"
        link_target="$(readlink "$script_path")" || {
            echo "Unable to resolve screenshots.sh symlink: $script_path" >&2
            exit 1
        }
        case "$link_target" in
            /*) script_path="$link_target" ;;
            *) script_path="$script_dir/$link_target" ;;
        esac
    done
    script_dir="$(cd -P "$(dirname "$script_path")" >/dev/null 2>&1 && pwd)"
    preset_config_file="$script_dir/presets.conf"
    if [ ! -r "$preset_config_file" ]; then
        echo "Preset configuration is missing or unreadable: $preset_config_file" >&2
        exit 1
    fi
}

preset_config_error() {
    echo "Invalid preset configuration at $preset_config_file:$1: $2" >&2
    exit 1
}

load_preset_config() {
    local line line_number=0 section="" trimmed option value has_value index
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        trimmed="${line#"${line%%[!$' \t']*}"}"
        trimmed="${trimmed%"${trimmed##*[!$' \t']}"}"
        [ -n "$trimmed" ] || continue
        [[ "$trimmed" == \#* ]] && continue

        if [[ "$trimmed" =~ ^\[([a-zA-Z0-9][a-zA-Z0-9_-]*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            for index in "${!preset_names[@]}"; do
                [ "${preset_names[$index]}" != "$section" ] || \
                    preset_config_error "$line_number" "duplicate preset '$section'"
            done
            preset_names+=("$section")
            continue
        fi

        [ -n "$section" ] || preset_config_error "$line_number" "option appears before a preset section"
        if [[ "$trimmed" == *=* ]]; then
            option="${trimmed%%=*}"
            value="${trimmed#*=}"
            has_value=true
        else
            option="$trimmed"
            value=""
            has_value=false
        fi
        [[ "$option" =~ ^--[a-z][a-z0-9-]*$ ]] || \
            preset_config_error "$line_number" "expected a long option, optionally followed by '=VALUE'"

        case "$option" in
            --input|--output|--overwrite|--help|--preset|--verbose|--output-pages)
                preset_config_error "$line_number" "option '$option' cannot be included in a preset"
                ;;
            --width|--height|--tile|--gap|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz|--paper|--margin|--margin-top|--margin-right|--margin-bottom|--margin-left|--overlap|--title|--page-font-size)
                $has_value || preset_config_error "$line_number" "option '$option' requires '=VALUE'"
                ;;
            --crop|--crop-top|--crop-bottom|--crop-left|--crop-right|--border)
                ;;
            --each|--paginate|--trim|--no-trim|--shadow|--header|--no-header|--footer|--no-footer|--header-line|--no-header-line|--footer-line|--no-footer-line)
                ! $has_value || preset_config_error "$line_number" "option '$option' does not take a value"
                ;;
            *)
                preset_config_error "$line_number" "unknown preset option '$option'"
                ;;
        esac

        for index in "${!preset_option_presets[@]}"; do
            if [ "${preset_option_presets[$index]}" = "$section" ] && \
                [ "${preset_option_names[$index]}" = "$option" ]; then
                preset_config_error "$line_number" "option '$option' is repeated in preset '$section'"
            fi
        done
        preset_option_presets+=("$section")
        preset_option_names+=("$option")
        preset_option_values+=("$value")
        preset_option_has_values+=("$has_value")
    done < "$preset_config_file"

    [ ${#preset_names[@]} -gt 0 ] || {
        echo "Preset configuration contains no presets: $preset_config_file" >&2
        exit 1
    }
}

print_available_presets() {
    local destination="$1" preset
    if [ "$destination" = stderr ]; then
        printf 'Available presets:\n' >&2
        for preset in "${preset_names[@]}"; do printf '  %s\n' "$preset" >&2; done
    else
        printf 'Available presets:\n'
        for preset in "${preset_names[@]}"; do printf '  %s\n' "$preset"; done
    fi
}

preset_option_key() {
    case "$1" in
        -w|--width) echo --width ;;
        -H|--height) echo --height ;;
        -t|--tile) echo --tile ;;
        -g|--gap) echo --gap ;;
        -G|--gravity) echo --gravity ;;
        -b|--border) echo --border ;;
        -c|--crop) echo --crop ;;
        -ct|--crop-top) echo --crop-top ;;
        -cb|--crop-bottom) echo --crop-bottom ;;
        -cl|--crop-left) echo --crop-left ;;
        -cr|--crop-right) echo --crop-right ;;
        -e|--each) echo --each ;;
        -p|--paginate) echo --paginate ;;
        -mt|--margin-top) echo --margin-top ;;
        -mr|--margin-right) echo --margin-right ;;
        -mb|--margin-bottom) echo --margin-bottom ;;
        -ml|--margin-left) echo --margin-left ;;
        --trim|--no-trim) echo --trim ;;
        --header|--no-header) echo --header ;;
        --footer|--no-footer) echo --footer ;;
        --header-line|--no-header-line) echo --header-line ;;
        --footer-line|--no-footer-line) echo --footer-line ;;
        *) echo "$1" ;;
    esac
}

preset_option_is_superseded() {
    local preset_option="$1" explicit_option="$2"
    if [ "$(preset_option_key "$preset_option")" = \
        "$(preset_option_key "$explicit_option")" ]; then
        return 0
    fi
    case "$explicit_option" in
        --no-header)
            [[ "$preset_option" == --header-line || "$preset_option" == --title ]] && return 0
            ;;
        --no-footer)
            [[ "$preset_option" == --footer-line ]] && return 0
            ;;
    esac
    return 1
}

format_shell_words() {
    local result="" word quoted char index
    for word in "$@"; do
        if [[ "$word" =~ ^[a-zA-Z0-9_./:-]+$ ]] || \
            [[ "$word" =~ ^\{[[:alpha:]_][[:alnum:]_]*\}$ ]]; then
            quoted="$word"
        else
            quoted="'"
            for ((index = 0; index < ${#word}; index++)); do
                char="${word:index:1}"
                if [ "$char" = "'" ]; then
                    quoted+="'\\''"
                else
                    quoted+="$char"
                fi
            done
            quoted+="'"
        fi
        if [ -n "$result" ]; then result+=" "; fi
        result+="$quoted"
    done
    printf '%s' "$result"
}

prepare_preset_arguments() {
    local -a original=("$@") user_args=()
    local -a explicit_option_displays=() explicit_option_values=() explicit_option_has_values=()
    local index=0 token next count=0 option_index found=false overridden
    local explicit_option_index override_index preset_display
    while [ "$index" -lt "${#original[@]}" ]; do
        token="${original[$index]}"
        case "$token" in
            --)
                while [ "$index" -lt "${#original[@]}" ]; do
                    user_args+=("${original[$index]}")
                    index=$((index + 1))
                done
                break
                ;;
            --__screenshots-preset-boundary__)
                echo "Unknown option: $token" >&2
                echo "Run with --help for usage." >&2
                exit 1
                ;;
            --preset)
                count=$((count + 1))
                if [ $((index + 1)) -ge "${#original[@]}" ]; then
                    echo "Option --preset requires an argument." >&2
                    print_available_presets stderr
                    echo "Run with --help presets for details." >&2
                    exit 1
                fi
                if [ "$count" -gt 1 ]; then
                    echo "Option --preset given more than once." >&2
                    echo "Run with --help presets for usage." >&2
                    exit 1
                fi
                preset_name="${original[$((index + 1))]}"
                if [ -z "$preset_name" ]; then
                    echo "Option --preset requires a non-empty name." >&2
                    print_available_presets stderr
                    echo "Run with --help presets for details." >&2
                    exit 1
                fi
                index=$((index + 2))
                continue
                ;;
        esac

        user_args+=("$token")
        if [[ "$token" == -* ]]; then
            explicit_option_displays+=("$token")
            explicit_option_values+=("")
            explicit_option_has_values+=(false)
            explicit_option_index=$((${#explicit_option_displays[@]} - 1))
        else
            explicit_option_index=-1
        fi
        case "$token" in
            -i|--input|-o|--output|-w|--width|-H|--height|-t|--tile|-g|--gap|-G|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz|--paper|--margin|-mt|--margin-top|-mr|--margin-right|-mb|--margin-bottom|-ml|--margin-left|--overlap|--title|--page-font-size)
                if [ $((index + 1)) -lt "${#original[@]}" ]; then
                    next="${original[$((index + 1))]}"
                    user_args+=("$next")
                    if [ "$explicit_option_index" -ge 0 ]; then
                        explicit_option_values[$explicit_option_index]="$next"
                        explicit_option_has_values[$explicit_option_index]=true
                    fi
                    index=$((index + 2))
                else
                    index=$((index + 1))
                fi
                continue
                ;;
            -b|--border|-c|--crop|-ct|--crop-top|-cb|--crop-bottom|-cl|--crop-left|-cr|--crop-right)
                if [ $((index + 1)) -lt "${#original[@]}" ]; then
                    next="${original[$((index + 1))]}"
                    if [[ "$next" =~ ^[0-9]+$ ]]; then
                        user_args+=("$next")
                        if [ "$explicit_option_index" -ge 0 ]; then
                            explicit_option_values[$explicit_option_index]="$next"
                            explicit_option_has_values[$explicit_option_index]=true
                        fi
                        index=$((index + 2))
                        continue
                    fi
                fi
                ;;
        esac
        index=$((index + 1))
    done

    if [ -n "$preset_name" ]; then
        for index in "${!preset_names[@]}"; do
            if [ "${preset_names[$index]}" = "$preset_name" ]; then
                found=true
                break
            fi
        done
        if ! $found; then
            echo "Unknown preset: $preset_name" >&2
            print_available_presets stderr
            echo "Run with --help presets for details." >&2
            exit 1
        fi
        for option_index in "${!preset_option_presets[@]}"; do
            if [ "${preset_option_presets[$option_index]}" = "$preset_name" ]; then
                overridden=false
                override_index=-1
                for index in "${!explicit_option_displays[@]}"; do
                    if preset_option_is_superseded \
                        "${preset_option_names[$option_index]}" \
                        "${explicit_option_displays[$index]}"; then
                        overridden=true
                        override_index="$index"
                    fi
                done
                if $overridden; then
                    preset_display="$(format_shell_words \
                        "${preset_option_names[$option_index]}" \
                        "${preset_option_values[$option_index]}")"
                    if [ "${preset_option_has_values[$option_index]}" = false ]; then
                        preset_display="$(format_shell_words \
                            "${preset_option_names[$option_index]}")"
                    fi
                    if [ "${explicit_option_has_values[$override_index]}" = true ]; then
                        superseded_by_options+=("$(format_shell_words \
                            "${explicit_option_displays[$override_index]}" \
                            "${explicit_option_values[$override_index]}")")
                    else
                        superseded_by_options+=("$(format_shell_words \
                            "${explicit_option_displays[$override_index]}")")
                    fi
                    superseded_preset_options+=("$preset_display")
                    continue
                fi
                preset_args+=("${preset_option_names[$option_index]}")
                if [ "${preset_option_has_values[$option_index]}" = true ]; then
                    preset_args+=("${preset_option_values[$option_index]}")
                fi
            fi
        done
        expanded_argv=("${preset_args[@]+"${preset_args[@]}"}" \
            --__screenshots-preset-boundary__ "${user_args[@]+"${user_args[@]}"}")
        effective_args=("${preset_args[@]+"${preset_args[@]}"}" \
            "${user_args[@]+"${user_args[@]}"}")
    else
        expanded_argv=("${user_args[@]+"${user_args[@]}"}")
        effective_args=()
    fi
}

usage_montage() {
    cat <<'EOF'
Montage mode

Usage:
  screenshots.sh -i PATTERN [-o FILE] [montage options]

Description:
  Combine one pathname-sorted input set into a grid image. Quote PATTERN so
  screenshots.sh, rather than the calling shell, expands it.

Output:
  The default is output.png. If the output matches the input glob, it is
  excluded. Existing output prompts for overwrite or keep-both unless -O is
  used.

Processing and constraints:
  Exactly one input pattern is required. Crop runs per input before shrink-only
  resize. Images are then combined; final trim and shadow run afterward. A
  usable system font or explicit --font FILE is required.

Options:
  -i, --input PATTERN    Exactly one quoted input pattern
  -o, --output FILE      Output filename (default: output.png)
  -O, --overwrite        Replace an existing output without prompting
EOF
    usage_common_transform_options detailed
    cat <<'EOF'
  -t, --tile COLSxROWS   Grid layout (default: 10x0; 0 means automatic)
  -g, --gap XxY          Tile gaps in pixels (default: 15x15)
  -G, --gravity VALUE    north (default), south, east, west, center, or corner
  --background COLOR     Montage background (default: transparent)
  --trim / --no-trim     Enable (default) or disable final trim
  --trim-fuzz N          Trim tolerance percentage (default: 0; needs trim)
  -b, --border [N]       Per-tile border (default: 1; explicit N must be > 0)
  --border-color COLOR   Border color (default: black; requires --border)
  -s, --shadow           Add final drop shadows
  --shadow-color COLOR   Shadow color (default: gray; requires --shadow)
  --font FILE            ImageMagick font; otherwise discover a system font

Examples:
  screenshots.sh -i "*.png" -o grid.png
  screenshots.sh -i "*.png" --tile 5x0 --gap 20x20
  screenshots.sh -i "*.png" --tile 25x1 --width 750 --shadow
EOF
}

usage_zip() {
    cat <<'EOF'
Zip mode

Usage:
  screenshots.sh -i PATTERN -i PATTERN [-i PATTERN ...] [-o DIR] [options]

Description:
  Pair corresponding files from multiple input sets. Each quoted pattern is
  expanded and bytewise sorted independently; -i order determines the
  left-to-right order within each montage.

Output:
  Files 1.png, 2.png, ... go into a fresh zip-<timestamp> directory under
  -o DIR or the current directory.

Processing and constraints:
  Two or more -i options are required, and every list must have equal length.
  Crop and shrink-only resize run per input before montage processing. The
  default layout is Nx1 for N input lists; explicit tile columns are capped to
  N. A usable system font or explicit --font FILE is required. -O/--overwrite
  is rejected because output always uses a fresh directory.

Options:
  -i, --input PATTERN    Repeat two or more times
  -o, --output DIR       Parent of the new zip-* directory (default: .)
EOF
    usage_common_transform_options detailed
    cat <<'EOF'
  -t, --tile COLSxROWS   Montage layout (default: Nx1)
  -g, --gap XxY          Tile gaps (default: 15x15)
  -G, --gravity VALUE    Tile gravity (default: north)
  --background COLOR     Montage background (default: transparent)
  --trim / --no-trim     Enable (default) or disable final trim
  --trim-fuzz N          Trim tolerance percentage (default: 0; needs trim)
  -b, --border [N]       Per-tile border (default: 1; explicit N must be > 0)
  --border-color COLOR   Border color (default: black; requires --border)
  -s, --shadow           Add final drop shadows
  --shadow-color COLOR   Shadow color (default: gray; requires --shadow)
  --font FILE            Select ImageMagick font; otherwise auto-discover

Examples:
  screenshots.sh -i "android/*.png" -i "ios/*.png" -o comparisons
  screenshots.sh -i "before/*.png" -i "after/*.png" --gap 0x0 --shadow
EOF
}

usage_each() {
    cat <<'EOF'
Each mode

Usage:
  screenshots.sh -i PATTERN --each [-o DIR] [options]

Description:
  Transform every match independently without creating a montage. Quote
  PATTERN so screenshots.sh expands it.

Output:
  Basenames are preserved in a fresh each-<timestamp> directory under -o DIR
  or the current directory.

Processing and constraints:
  Exactly one input pattern is required. Processing order is crop, shrink-only
  resize, trim, border, then shadow. Trim is disabled by default. Montage-only
  Unsupported options -t/--tile, -g/--gap, -G/--gravity, --background, and
  --font are rejected, as is -O/--overwrite because output always uses a fresh
  directory.

Options:
  -i, --input PATTERN    Exactly one quoted input pattern
  -e, --each             Select each mode
  -o, --output DIR       Parent of the new each-* directory (default: .)
EOF
    usage_common_transform_options detailed
    cat <<'EOF'
  --trim / --no-trim     Enable or disable final trim (default: disabled)
  --trim-fuzz N          Trim tolerance percentage (default: 0; requires trim)
  -b, --border [N]       Add border (default: 1; explicit N must be > 0)
  --border-color COLOR   Border color (default: black; requires --border)
  -s, --shadow           Add a shadow to each output
  --shadow-color COLOR   Shadow color (default: gray; requires --shadow)

Examples:
  screenshots.sh -i "*.png" --each --width 750
  screenshots.sh -i "shots/*.png" --each --trim --border 2 --shadow -o exports
EOF
}

usage_paginate() {
    cat <<'EOF'
Paginate mode

Usage:
  screenshots.sh -i IMAGE --paginate [-o FILE.pdf] [pagination options]
  screenshots.sh -i IMAGE --paginate --output-pages [-o DIR] [options]

Description:
  Slice one long image from top to bottom into fixed-ratio portrait pages.
  Output is raster-only: no OCR or text layer is added.

Output:
  PDF defaults beside the input with a .pdf extension. Existing PDFs prompt
  for overwrite or keep-both; non-interactive replacement requires -O. PNG
  output creates page-NNN.png files in a fresh pages-<timestamp> directory
  under -o DIR or the current directory, creating a missing parent. Directory
  collisions receive a numeric suffix and are never replaced or merged.

Processing and constraints:
  Exactly one readable, single-frame raster image is required. Auto-orientation,
  crop, then shrink-only resize run before fixed geometric slicing. Final
  partial pages are white padded; every page retains the selected paper ratio.
  Montage and appearance options are rejected, as is -O with --output-pages.

Options:
  -i, --input IMAGE      One literal path or quoted pattern matching one image
  -p, --paginate         Select paginate mode
  -o, --output FILE|DIR  PDF file, or PNG parent with --output-pages
  -O, --overwrite        Atomically replace an existing PDF
  --output-pages         Write lossless PNG pages instead of PDF
  --paper SIZE           letter (default), a4, legal, or a custom WIDTHxHEIGHT
                         aspect ratio; portrait only
  --margin N             Uniform outer margin in output pixels (default: 0)
  -mt, --margin-top N    Additional top margin in pixels (default: 0)
  -mr, --margin-right N  Additional right margin in pixels (default: 0)
  -mb, --margin-bottom N Additional bottom margin in pixels (default: 0)
  -ml, --margin-left N   Additional left margin in pixels (default: 0)
  --overlap N            Repeated source rows between pages (default: 0;
                         must be smaller than the calculated slice height)
  --header               Add creation date/time at top left
  --title TEXT           Add header-right text; {filename} and {stem} expand;
                         requires --header
  --footer               Add page/total-pages at bottom right
  --header-line          Add a thin gray rule; requires --header
  --footer-line          Add a thin gray rule; requires --footer
  --page-font-size N     Decoration size in PDF points (default: 6; 0 < N < 24;
                         requires --header or --footer)
  --font FILE            Header/footer font; requires a header or footer;
                         otherwise auto-discover
EOF
    usage_common_transform_options detailed
    cat <<'EOF'

Decoration bands are 24 points tall with a 12-point horizontal text inset.
Rules are 0.25-point #d0d0d0. Creation-time priority is EXIF capture time,
recognized GoFullPage filename, filesystem creation time, then modification
time. Long titles use an ellipsis.

Rejected montage/appearance options include -e/--each, repeated -i/--input,
-t/--tile, -g/--gap, -G/--gravity, --background, --trim, --no-trim,
--trim-fuzz, -s/--shadow, --shadow-color, -b/--border, and --border-color.

If ImageMagick cannot write PDF, use --output-pages as the PNG fallback.

Examples:
  screenshots.sh -i article.png --paginate
  screenshots.sh -i article.png --paginate --paper a4 --margin 40 -o article.pdf
  screenshots.sh -i article.png --paginate --paper 2038x2807 -o article.pdf
  screenshots.sh -i article.png --paginate --margin 20 -ml 40 -mr 40
  screenshots.sh -i article.png --paginate --overlap 40 -o article.pdf
  screenshots.sh -i article.png --paginate --output-pages -o exports
  screenshots.sh -i article.png --paginate --header --footer --title "Article"
EOF
}

usage_topics_error() {
    echo "$1" >&2
    echo "Accepted help topics: montage, zip, each, paginate, presets" >&2
}

handle_help_request() {
    local -a argv=("$@") extras=()
    local count=${#argv[@]} i token next
    local help_count=0 help_index=-1 topic="" topic_index=-1
    local each_seen=false paginate_seen=false

    i=0
    while [ "$i" -lt "$count" ]; do
        token="${argv[$i]}"
        case "$token" in
            -h|--help)
                help_count=$((help_count + 1))
                help_index="$i"
                ;;
            -e|--each) each_seen=true ;;
            -p|--paginate) paginate_seen=true ;;
            -i|--input|-o|--output|-w|--width|-H|--height|-t|--tile|-g|--gap|-G|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz|--paper|--margin|-mt|--margin-top|-mr|--margin-right|-mb|--margin-bottom|-ml|--margin-left|--overlap|--title|--page-font-size|--preset)
                if [ $((i + 1)) -lt "$count" ]; then
                    next="${argv[$((i + 1))]}"
                    case "$next" in
                        -h|--help|-e|--each|-p|--paginate) ;;
                        *) i=$((i + 1)) ;;
                    esac
                fi
                ;;
            -b|--border|-c|--crop|-ct|--crop-top|-cb|--crop-bottom|-cl|--crop-left|-cr|--crop-right)
                if [ $((i + 1)) -lt "$count" ]; then
                    next="${argv[$((i + 1))]}"
                    if [[ "$next" =~ ^[0-9]+$ ]]; then i=$((i + 1)); fi
                fi
                ;;
        esac
        i=$((i + 1))
    done

    [ "$help_count" -gt 0 ] || return 0
    if [ "$help_count" -gt 1 ]; then
        usage_topics_error "Help may be requested only once."
        exit 1
    fi
    if $each_seen && $paginate_seen; then
        usage_topics_error "--each and --paginate cannot both select help."
        exit 1
    fi

    if [ $((help_index + 1)) -lt "$count" ]; then
        next="${argv[$((help_index + 1))]}"
        case "$next" in
            montage|zip|each|paginate|presets)
                topic="$next"
                topic_index=$((help_index + 1))
                ;;
            -*) ;;
            *)
                usage_topics_error "Unknown help topic: $next"
                exit 1
                ;;
        esac
    fi

    i=0
    while [ "$i" -lt "$count" ]; do
        if [ "$i" -eq "$help_index" ] || [ "$i" -eq "$topic_index" ]; then
            i=$((i + 1))
            continue
        fi
        token="${argv[$i]}"
        case "$token" in
            --)
                i=$((i + 1))
                while [ "$i" -lt "$count" ]; do
                    extras+=("${argv[$i]}")
                    i=$((i + 1))
                done
                continue
                ;;
            -i|--input|-o|--output|-w|--width|-H|--height|-t|--tile|-g|--gap|-G|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz|--paper|--margin|-mt|--margin-top|-mr|--margin-right|-mb|--margin-bottom|-ml|--margin-left|--overlap|--title|--page-font-size|--preset)
                if [ $((i + 1)) -lt "$count" ]; then
                    next="${argv[$((i + 1))]}"
                    if [ $((i + 1)) -ne "$help_index" ] && \
                       [ $((i + 1)) -ne "$topic_index" ]; then
                        case "$next" in
                            -h|--help|-e|--each|-p|--paginate) ;;
                            *) i=$((i + 1)) ;;
                        esac
                    fi
                fi
                ;;
            -b|--border|-c|--crop|-ct|--crop-top|-cb|--crop-bottom|-cl|--crop-left|-cr|--crop-right)
                if [ $((i + 1)) -lt "$count" ]; then
                    next="${argv[$((i + 1))]}"
                    if [[ "$next" =~ ^[0-9]+$ ]]; then i=$((i + 1)); fi
                fi
                ;;
            -*) ;;
            *) extras+=("$token") ;;
        esac
        i=$((i + 1))
    done

    if [ ${#extras[@]} -gt 0 ]; then
        usage_topics_error "Unexpected extra argument in help request: ${extras[0]}"
        exit 1
    fi

    if [ -n "$topic" ]; then
        if { $each_seen && [ "$topic" != "each" ]; } || \
           { $paginate_seen && [ "$topic" != "paginate" ]; }; then
            usage_topics_error "Help topic '$topic' conflicts with the explicit mode selector."
            exit 1
        fi
    elif $each_seen; then
        topic="each"
    elif $paginate_seen; then
        topic="paginate"
    else
        topic="general"
    fi

    case "$topic" in
        general) usage_general ;;
        montage) usage_montage ;;
        zip) usage_zip ;;
        each) usage_each ;;
        paginate) usage_paginate ;;
        presets) usage_presets ;;
    esac
    exit 0
}

next_available_name() {
    local path="$1"
    local dir base ext name candidate i

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if [[ "$base" == *.* ]]; then
        ext=".${base##*.}"
        name="${base%.*}"
    else
        ext=""
        name="$base"
    fi

    i=1
    while true; do
        candidate="${dir}/${name}-${i}${ext}"
        if [ ! -e "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
        i=$((i + 1))
    done
}

input_patterns=()
output_file="output.png"
width=""
height=""
tile="10x0"
tile_set=false
gap="15x15"
gravity="north"
background="transparent"
do_trim=true
trim_set=false
trim_fuzz="0"
do_shadow=false
crop_all_seen=0; crop_all_val=0
crop_top_seen=0; crop_top_val=0
crop_bottom_seen=0; crop_bottom_val=0
crop_left_seen=0; crop_left_val=0
crop_right_seen=0; crop_right_val=0
crop_all_explicit=false
crop_top_explicit=false
crop_bottom_explicit=false
crop_left_explicit=false
crop_right_explicit=false
force_overwrite=false
verbose=false
shadow_color="gray"
font_file=""
do_border=false
border_width="1"
border_color="black"
each_mode=false
paginate_mode=false
preset_loading=false
paper="letter"
paper_custom_width=""
paper_custom_height=""
margin="0"
margin_top_extra="0"
margin_right_extra="0"
margin_bottom_extra="0"
margin_left_extra="0"
overlap="0"
output_set=false
paper_set=false
margin_set=false
margin_top_set=false
margin_right_set=false
margin_bottom_set=false
margin_left_set=false
margin_top_explicit=false
margin_right_explicit=false
margin_bottom_explicit=false
margin_left_explicit=false
overlap_set=false
output_pages_set=false
header_set=false
footer_set=false
header_line_set=false
footer_line_set=false
header_choice=""
footer_choice=""
header_line_choice=""
footer_line_choice=""
header_choice_explicit=false
footer_choice_explicit=false
header_line_choice_explicit=false
footer_line_choice_explicit=false
title_from_preset=false
title=""
title_set=false
title_explicit=false
page_font_size="6"
page_font_size_set=false
page_font_size_explicit=false
gap_set=false
gravity_set=false
background_set=false
shadow_color_set=false
font_set=false
border_color_set=false
trim_fuzz_set=false

tmpdir=""
out_tmpdir=""
paginate_publish_tmp=""
operational_output_started=0
operational_start_date=""
operational_last_stream="stderr"

raw_output_line() {
    local stream="$1" line="$2"
    if [ "$stream" = "stdout" ]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "$line" >&2
    fi
}

begin_operational_output() {
    local stream="$1"
    if [ "$operational_output_started" -eq 0 ]; then
        operational_start_date="$(date '+%Y-%m-%d')" || operational_start_date="unknown-date"
        raw_output_line "$stream" "[$operational_start_date]"
        operational_output_started=1
    fi
    operational_last_stream="$stream"
}

operational_block() {
    local stream="$1" text="$2" line current_time timestamp_written=0
    begin_operational_output "$stream"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -z "$line" ]; then
            raw_output_line "$stream" ""
        elif [ "$timestamp_written" -eq 0 ]; then
            current_time="$(date '+%H:%M:%S')" || current_time="??:??:??"
            raw_output_line "$stream" "[$current_time] $line"
            timestamp_written=1
        else
            raw_output_line "$stream" "$line"
        fi
    done <<< "$text"
}

operational_message() {
    operational_block "$1" "$2"
}

finish_operational_output() {
    local end_date
    [ "$operational_output_started" -eq 1 ] || return 0
    end_date="$(date '+%Y-%m-%d')" || end_date="$operational_start_date"
    if [ "$end_date" != "$operational_start_date" ]; then
        raw_output_line "$operational_last_stream" "[$end_date]"
    fi
}

report_outputs() {
    local text="Output file(s):" out
    for out in "${all_output_list[@]}"; do
        text+=$'\n'"$out"
    done
    operational_block stdout "$text"
}

cleanup() {
    if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
        rm -rf "$tmpdir"
    fi
    if [ -n "$out_tmpdir" ] && [ -d "$out_tmpdir" ]; then
        rm -rf "$out_tmpdir"
    fi
    if [ -n "$paginate_publish_tmp" ] && \
        { [ -e "$paginate_publish_tmp" ] || [ -L "$paginate_publish_tmp" ]; }; then
        rm -rf "$paginate_publish_tmp"
    fi
    finish_operational_output
}
trap cleanup EXIT

log() {
    if $verbose; then
        operational_message stderr "$*"
    fi
}

resolve_preset_config_path
load_preset_config
handle_help_request "$@"
prepare_preset_arguments "$@"
if [ -n "$preset_name" ]; then preset_loading=true; fi
set -- "${expanded_argv[@]+"${expanded_argv[@]}"}"

if [ $# -eq 0 ]; then
    usage_general
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input|-o|--output|-w|--width|-H|--height|-t|--tile|-g|--gap|-G|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz|--paper|--margin|-mt|--margin-top|-mr|--margin-right|-mb|--margin-bottom|-ml|--margin-left|--overlap|--title|--page-font-size)
            if [ $# -lt 2 ]; then
                echo "Option $1 requires an argument." >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            ;;
    esac
    case "$1" in
        -h|--help)
            usage_general
            exit 0
            ;;
        --__screenshots-preset-boundary__)
            preset_loading=false
            shift
            ;;
        -i|--input)
            input_patterns+=("$2")
            shift 2
            ;;
        -o|--output)
            if $output_set; then
                echo "Option -o/--output given more than once." >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            case "$2" in
                *[*?\[]*)
                    echo "Option -o/--output must be a literal path, not a glob pattern: $2" >&2
                    echo "Run with --help for usage." >&2
                    exit 1
                    ;;
            esac
            output_file="$2"
            output_set=true
            shift 2
            ;;
        -w|--width)
            width="$2"
            shift 2
            ;;
        -H|--height)
            height="$2"
            shift 2
            ;;
        -t|--tile)
            tile="$2"
            tile_set=true
            shift 2
            ;;
        -g|--gap)
            gap="$2"
            gap_set=true
            shift 2
            ;;
        -G|--gravity)
            gravity="$2"
            gravity_set=true
            shift 2
            ;;
        --background)
            background="$2"
            background_set=true
            shift 2
            ;;
        -O|--overwrite)
            force_overwrite=true
            shift
            ;;
        -v|--verbose)
            verbose=true
            shift
            ;;
        --trim)
            do_trim=true
            trim_set=true
            shift
            ;;
        --no-trim)
            do_trim=false
            trim_set=true
            shift
            ;;
        --trim-fuzz)
            trim_fuzz="$2"
            trim_fuzz_set=true
            shift 2
            ;;
        -s|--shadow)
            do_shadow=true
            shift
            ;;
        --shadow-color)
            shadow_color="$2"
            shadow_color_set=true
            shift 2
            ;;
        --font)
            font_file="$2"
            font_set=true
            shift 2
            ;;
        -b|--border)
            do_border=true
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                border_width="$2"
                shift 2
            else
                shift
            fi
            ;;
        --border-color)
            border_color="$2"
            border_color_set=true
            shift 2
            ;;
        -c|--crop)
            if ! $preset_loading; then
                if ! $crop_all_explicit; then crop_all_seen=0; fi
                crop_all_explicit=true
            fi
            crop_all_seen=$((crop_all_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_all_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -ct|--crop-top)
            if ! $preset_loading; then
                if ! $crop_top_explicit; then crop_top_seen=0; fi
                crop_top_explicit=true
            fi
            crop_top_seen=$((crop_top_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_top_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cb|--crop-bottom)
            if ! $preset_loading; then
                if ! $crop_bottom_explicit; then crop_bottom_seen=0; fi
                crop_bottom_explicit=true
            fi
            crop_bottom_seen=$((crop_bottom_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_bottom_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cl|--crop-left)
            if ! $preset_loading; then
                if ! $crop_left_explicit; then crop_left_seen=0; fi
                crop_left_explicit=true
            fi
            crop_left_seen=$((crop_left_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_left_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cr|--crop-right)
            if ! $preset_loading; then
                if ! $crop_right_explicit; then crop_right_seen=0; fi
                crop_right_explicit=true
            fi
            crop_right_seen=$((crop_right_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_right_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -e|--each)
            each_mode=true
            shift
            ;;
        -p|--paginate)
            paginate_mode=true
            shift
            ;;
        --paper)
            paper="$2"
            paper_set=true
            shift 2
            ;;
        --margin)
            margin="$2"
            margin_set=true
            shift 2
            ;;
        -mt|--margin-top)
            if ! $preset_loading && $margin_top_explicit; then
                echo "Option -mt/--margin-top given more than once." >&2
                exit 1
            fi
            if ! $preset_loading; then margin_top_explicit=true; fi
            margin_top_extra="$2"
            margin_top_set=true
            shift 2
            ;;
        -mr|--margin-right)
            if ! $preset_loading && $margin_right_explicit; then
                echo "Option -mr/--margin-right given more than once." >&2
                exit 1
            fi
            if ! $preset_loading; then margin_right_explicit=true; fi
            margin_right_extra="$2"
            margin_right_set=true
            shift 2
            ;;
        -mb|--margin-bottom)
            if ! $preset_loading && $margin_bottom_explicit; then
                echo "Option -mb/--margin-bottom given more than once." >&2
                exit 1
            fi
            if ! $preset_loading; then margin_bottom_explicit=true; fi
            margin_bottom_extra="$2"
            margin_bottom_set=true
            shift 2
            ;;
        -ml|--margin-left)
            if ! $preset_loading && $margin_left_explicit; then
                echo "Option -ml/--margin-left given more than once." >&2
                exit 1
            fi
            if ! $preset_loading; then margin_left_explicit=true; fi
            margin_left_extra="$2"
            margin_left_set=true
            shift 2
            ;;
        --overlap)
            overlap="$2"
            overlap_set=true
            shift 2
            ;;
        --output-pages)
            output_pages_set=true
            shift
            ;;
        --header)
            header_set=true
            header_choice=true
            if ! $preset_loading; then header_choice_explicit=true; fi
            shift
            ;;
        --no-header)
            header_set=false
            header_choice=false
            if ! $preset_loading; then header_choice_explicit=true; fi
            shift
            ;;
        --footer)
            footer_set=true
            footer_choice=true
            if ! $preset_loading; then footer_choice_explicit=true; fi
            shift
            ;;
        --no-footer)
            footer_set=false
            footer_choice=false
            if ! $preset_loading; then footer_choice_explicit=true; fi
            shift
            ;;
        --header-line)
            header_line_set=true
            header_line_choice=true
            if ! $preset_loading; then header_line_choice_explicit=true; fi
            shift
            ;;
        --no-header-line)
            header_line_set=false
            header_line_choice=false
            if ! $preset_loading; then header_line_choice_explicit=true; fi
            shift
            ;;
        --footer-line)
            footer_line_set=true
            footer_line_choice=true
            if ! $preset_loading; then footer_line_choice_explicit=true; fi
            shift
            ;;
        --no-footer-line)
            footer_line_set=false
            footer_line_choice=false
            if ! $preset_loading; then footer_line_choice_explicit=true; fi
            shift
            ;;
        --title)
            if ! $preset_loading && $title_explicit; then
                echo "Option --title given more than once." >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            if ! $preset_loading; then title_explicit=true; else title_from_preset=true; fi
            title="$2"
            title_set=true
            shift 2
            ;;
        --page-font-size)
            if ! $preset_loading && $page_font_size_explicit; then
                echo "Option --page-font-size given more than once." >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            if ! $preset_loading; then page_font_size_explicit=true; fi
            page_font_size="$2"
            page_font_size_set=true
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -gt 0 ]; then
    echo "Unexpected extra arguments: $*" >&2
    echo "(if one of these looks like a filename, quote your -i pattern, e.g. -i \"*.png\", so the shell doesn't expand it)" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

if [ ${#input_patterns[@]} -eq 0 ]; then
    echo "Missing required option: -i/--input" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

zip_mode=false
if [ ${#input_patterns[@]} -gt 1 ]; then
    zip_mode=true
fi

mode="montage"
if $paginate_mode; then
    mode="paginate"
elif $each_mode; then
    mode="each"
elif $zip_mode; then
    mode="zip"
fi

if $header_choice_explicit && [ "$header_choice" = false ] && \
    ! $header_line_choice_explicit; then
    header_line_set=false
fi
if $footer_choice_explicit && [ "$footer_choice" = false ] && \
    ! $footer_line_choice_explicit; then
    footer_line_set=false
fi
if $title_from_preset && $header_choice_explicit && \
    [ "$header_choice" = false ] && ! $title_explicit; then
    title=""
    title_set=false
fi

if [ -z "$preset_name" ] && { [ "$header_choice" = "false" ] || \
    [ "$footer_choice" = "false" ] || [ "$header_line_choice" = "false" ] || \
    [ "$footer_line_choice" = "false" ]; }; then
    echo "Negative header/footer options are only used to override a preset." >&2
    exit 1
fi

if ! $paginate_mode && { $paper_set || $margin_set || $margin_top_set || \
    $margin_right_set || $margin_bottom_set || $margin_left_set || \
    $overlap_set || $output_pages_set || \
    $header_set || $footer_set || $header_line_set || $footer_line_set || \
    [ -n "$header_choice" ] || [ -n "$footer_choice" ] || \
    [ -n "$header_line_choice" ] || [ -n "$footer_line_choice" ] || \
    $title_set || $page_font_size_set; }; then
    echo "Pagination options such as --paper, margin options, --overlap, --output-pages, headers, and footers require --paginate." >&2
    exit 1
fi

if $title_set && ! $header_set; then
    echo "--title requires --header." >&2
    exit 1
fi

if $header_line_set && ! $header_set; then
    echo "--header-line requires --header." >&2
    exit 1
fi

if $footer_line_set && ! $footer_set; then
    echo "--footer-line requires --footer." >&2
    exit 1
fi

if $page_font_size_set && ! $header_set && ! $footer_set; then
    echo "--page-font-size requires --header or --footer." >&2
    exit 1
fi

if $paginate_mode && $font_set && ! $header_set && ! $footer_set; then
    echo "--font requires --header or --footer in pagination mode." >&2
    exit 1
fi

if $paginate_mode && $each_mode; then
    if [ -n "$preset_name" ]; then
        echo "Preset '$preset_name' conflicts with --each and --paginate." >&2
    else
        echo "--paginate and --each are mutually exclusive." >&2
    fi
    exit 1
fi

if $paginate_mode && [ ${#input_patterns[@]} -ne 1 ]; then
    echo "Pagination requires exactly one -i/--input option." >&2
    exit 1
fi

if $paginate_mode && { $tile_set || $gap_set || $gravity_set || $background_set || \
    $trim_set || $trim_fuzz_set || $do_shadow || $shadow_color_set || \
    $do_border || $border_color_set; }; then
    echo "Montage/appearance options cannot be used with --paginate." >&2
    exit 1
fi

if $paginate_mode && $output_pages_set && $force_overwrite; then
    echo "-O/--overwrite cannot be used with --output-pages." >&2
    exit 1
fi

if $each_mode && $zip_mode; then
    echo "--each requires exactly one -i pattern (use multiple -i for zip mode instead)." >&2
    exit 1
fi

if ! $trim_set; then
    if $each_mode; then
        do_trim=false
    else
        do_trim=true
    fi
fi

no_op_errors=()
if [ "$mode" = "each" ]; then
    each_no_ops=()
    $tile_set && each_no_ops+=("--tile")
    $gap_set && each_no_ops+=("--gap")
    $gravity_set && each_no_ops+=("--gravity")
    $background_set && each_no_ops+=("--background")
    $font_set && each_no_ops+=("--font")
    $force_overwrite && each_no_ops+=("-O/--overwrite")
    if [ ${#each_no_ops[@]} -gt 0 ]; then
        each_no_ops_text="${each_no_ops[0]}"
        each_no_ops_index=1
        while [ "$each_no_ops_index" -lt "${#each_no_ops[@]}" ]; do
            each_no_ops_text="$each_no_ops_text, ${each_no_ops[$each_no_ops_index]}"
            each_no_ops_index=$((each_no_ops_index + 1))
        done
        no_op_errors+=("Each mode does not use: $each_no_ops_text. Remove these options, or choose a mode that supports them.")
    fi
elif [ "$mode" = "zip" ] && $force_overwrite; then
    no_op_errors+=("Zip mode does not use -O/--overwrite because it always creates a fresh output directory.")
fi

if [ "$mode" != "paginate" ]; then
    if $shadow_color_set && ! $do_shadow; then
        no_op_errors+=("--shadow-color requires --shadow; add --shadow or remove --shadow-color.")
    fi
    if $border_color_set && ! $do_border; then
        no_op_errors+=("--border-color requires --border; add --border or remove --border-color.")
    fi
    if $trim_fuzz_set && ! $do_trim; then
        no_op_errors+=("--trim-fuzz requires trimming; add --trim or remove --trim-fuzz/--no-trim.")
    fi
    if $do_border && [ "$border_width" -eq 0 ]; then
        no_op_errors+=("--border 0 adds no border; omit --border or use a positive width.")
    fi
fi

if [ ${#no_op_errors[@]} -gt 0 ]; then
    echo "Options with no effect:" >&2
    for no_op_error in "${no_op_errors[@]}"; do
        echo "  $no_op_error" >&2
    done
    exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick 'magick' not found in PATH." >&2
    exit 1
fi

if { [ "$mode" = "montage" ] || [ "$mode" = "zip" ]; } && ! command -v montage >/dev/null 2>&1; then
    echo "ImageMagick 'montage' not found in PATH." >&2
    exit 1
fi

# ImageMagick's montage command initializes text rendering even when no labels
# are requested. Some installations have no registered default font, so pass a
# real font file explicitly. Prefer fontconfig, then common platform paths, and
# finally ImageMagick's own registry.
find_montage_font() {
    local candidate

    if command -v fc-match >/dev/null 2>&1; then
        candidate="$(fc-match -f '%{file}\n' sans 2>/dev/null | sed -n '1p')"
        if [ -n "$candidate" ] && [ -r "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    fi

    for candidate in \
        /System/Library/Fonts/Helvetica.ttc \
        /System/Library/Fonts/Supplemental/Arial.ttf \
        /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
        /usr/share/fonts/dejavu/DejaVuSans.ttf
    do
        if [ -r "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    candidate="$(magick -list font 2>/dev/null | sed -n 's/^[[:space:]]*glyphs: //p' | sed -n '1p')"
    if [ -n "$candidate" ] && [ -r "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

montage_font=""
paginate_font=""
if [ "$mode" = "montage" ] || [ "$mode" = "zip" ]; then
    if [ -n "$font_file" ]; then
        if [ ! -r "$font_file" ]; then
            echo "Font file does not exist or is not readable: $font_file" >&2
            exit 1
        fi
        montage_font="$font_file"
    else
        if ! montage_font="$(find_montage_font)"; then
            echo "No usable font found for ImageMagick montage." >&2
            echo "Install a system font or pass --font /path/to/font." >&2
            exit 1
        fi
    fi
    log "Montage font: $montage_font"
fi

if $paginate_mode && { $header_set || $footer_set; }; then
    if [ -n "$font_file" ]; then
        if [ ! -r "$font_file" ]; then
            echo "Font file does not exist or is not readable: $font_file" >&2
            exit 1
        fi
        paginate_font="$font_file"
    else
        if ! paginate_font="$(find_montage_font)"; then
            echo "No usable font found for pagination headers or footers." >&2
            echo "Install a system font or pass --font /path/to/font." >&2
            exit 1
        fi
    fi
    log "Pagination font: $paginate_font"
fi

if [ -n "$width" ] && ! [[ "$width" =~ ^[0-9]+$ ]]; then
    echo "Invalid --width value: $width" >&2
    exit 1
fi

if [ -n "$height" ] && ! [[ "$height" =~ ^[0-9]+$ ]]; then
    echo "Invalid --height value: $height" >&2
    exit 1
fi

if $paginate_mode; then
    paper="$(printf '%s' "$paper" | tr '[:upper:]' '[:lower:]')"
    case "$paper" in
        letter|a4|legal) ;;
        *)
            if [[ "$paper" =~ ^([1-9][0-9]{0,8})x([1-9][0-9]{0,8})$ ]]; then
                paper_custom_width="${BASH_REMATCH[1]}"
                paper_custom_height="${BASH_REMATCH[2]}"
                if ! LC_ALL=C awk -v width="$paper_custom_width" \
                    -v height="$paper_custom_height" 'BEGIN { exit !(width < height) }'; then
                    echo "Invalid --paper value: $paper (custom paper ratios must be portrait: WIDTH < HEIGHT)" >&2
                    exit 1
                fi
            else
                echo "Invalid --paper value: $paper (expected letter, a4, legal, or positive WIDTHxHEIGHT portrait ratio)" >&2
                exit 1
            fi
            ;;
    esac
    if ! [[ "$margin" =~ ^[0-9]+$ ]]; then
        echo "Invalid --margin value: $margin (expected non-negative pixels)" >&2
        exit 1
    fi
    if ! [[ "$margin_top_extra" =~ ^[0-9]+$ ]]; then
        echo "Invalid --margin-top value: $margin_top_extra (expected non-negative pixels)" >&2
        exit 1
    fi
    if ! [[ "$margin_right_extra" =~ ^[0-9]+$ ]]; then
        echo "Invalid --margin-right value: $margin_right_extra (expected non-negative pixels)" >&2
        exit 1
    fi
    if ! [[ "$margin_bottom_extra" =~ ^[0-9]+$ ]]; then
        echo "Invalid --margin-bottom value: $margin_bottom_extra (expected non-negative pixels)" >&2
        exit 1
    fi
    if ! [[ "$margin_left_extra" =~ ^[0-9]+$ ]]; then
        echo "Invalid --margin-left value: $margin_left_extra (expected non-negative pixels)" >&2
        exit 1
    fi
    if ! [[ "$overlap" =~ ^[0-9]+$ ]]; then
        echo "Invalid --overlap value: $overlap (expected non-negative pixels)" >&2
        exit 1
    fi
    margin=$((10#$margin))
    margin_top_extra=$((10#$margin_top_extra))
    margin_right_extra=$((10#$margin_right_extra))
    margin_bottom_extra=$((10#$margin_bottom_extra))
    margin_left_extra=$((10#$margin_left_extra))
    margin_top=$((margin + margin_top_extra))
    margin_right=$((margin + margin_right_extra))
    margin_bottom=$((margin + margin_bottom_extra))
    margin_left=$((margin + margin_left_extra))
    overlap=$((10#$overlap))
    if ! [[ "$page_font_size" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
        ! LC_ALL=C awk -v size="$page_font_size" 'BEGIN { exit !(size > 0 && size < 24) }'; then
        echo "Invalid --page-font-size value: $page_font_size (expected points greater than 0 and less than 24)" >&2
        exit 1
    fi
fi

if ! [[ "$trim_fuzz" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid --trim-fuzz value: $trim_fuzz" >&2
    exit 1
fi

# Resolves a crop flag's effective value, applying the "used more than once" and
# "0 has no effect" rules. Prints the effective value on stdout; prints any
# user-facing notice on stderr.
resolve_crop_flag() {
    local seen="$1" val="$2" label="$3"
    if [ "$seen" -gt 1 ]; then
        echo "Note: ${label} was specified more than once; ignoring it. Use it only once." >&2
        echo 0
        return
    fi
    if [ "$seen" -eq 1 ] && [ "$val" -eq 0 ]; then
        echo "Note: ${label} was given a 0px crop; ignoring it." >&2
        echo 0
        return
    fi
    echo "$val"
}

crop_all=$(resolve_crop_flag "$crop_all_seen" "$crop_all_val" "-c/--crop")
crop_top_extra=$(resolve_crop_flag "$crop_top_seen" "$crop_top_val" "-ct/--crop-top")
crop_bottom_extra=$(resolve_crop_flag "$crop_bottom_seen" "$crop_bottom_val" "-cb/--crop-bottom")
crop_left_extra=$(resolve_crop_flag "$crop_left_seen" "$crop_left_val" "-cl/--crop-left")
crop_right_extra=$(resolve_crop_flag "$crop_right_seen" "$crop_right_val" "-cr/--crop-right")

crop_needed=false
if [ "$crop_all" -gt 0 ] || [ "$crop_top_extra" -gt 0 ] || [ "$crop_bottom_extra" -gt 0 ] || \
   [ "$crop_left_extra" -gt 0 ] || [ "$crop_right_extra" -gt 0 ]; then
    crop_needed=true
fi

if $zip_mode && ! $tile_set; then
    tile="${#input_patterns[@]}x1"
fi

if ! [[ "$tile" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Invalid --tile value: $tile (expected COLSxROWS)" >&2
    exit 1
fi

if ! [[ "$gap" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Invalid --gap value: $gap (expected XxY)" >&2
    exit 1
fi

gap_x="${gap%x*}"
gap_y="${gap#*x}"

resize_arg=""
if [ -n "$width" ] && [ -n "$height" ]; then
    resize_arg="${width}x${height}>"
elif [ -n "$width" ]; then
    resize_arg="${width}>"
elif [ -n "$height" ]; then
    resize_arg="x${height}>"
fi

get_pixel_size() {
    local file="$1"
    # "[0]" selects just the first frame: identify -format prints its format string once
    # per frame with no separator, so a multi-frame file (animated PNG/GIF) would otherwise
    # come back as concatenated garbage, e.g. "800x600800x600". The crop box computed from
    # frame 0 is then applied to the whole file (all frames) during the actual crop below.
    magick identify -format "%wx%h" "${file}[0]"
}

# Crops one file per the resolved crop_all/crop_*_extra globals; copies through
# unchanged if the net crop is zero or gets fully dropped by the bounds guards.
crop_file() {
    local src="$1" dst="$2"
    local top=$((crop_all + crop_top_extra))
    local bottom=$((crop_all + crop_bottom_extra))
    local left=$((crop_all + crop_left_extra))
    local right=$((crop_all + crop_right_extra))

    local pixel_size img_width img_height crop_width crop_height
    pixel_size="$(get_pixel_size "$src")"
    img_width="${pixel_size%%x*}"
    img_height="${pixel_size##*x}"

    if [ $((left + right)) -gt 0 ] && [ $((left + right)) -ge "$img_width" ]; then
        echo "Note: left+right crop ($((left + right))px) meets or exceeds image width (${img_width}px) for $src; ignoring horizontal crop." >&2
        left=0
        right=0
    fi
    if [ $((top + bottom)) -gt 0 ] && [ $((top + bottom)) -ge "$img_height" ]; then
        echo "Note: top+bottom crop ($((top + bottom))px) meets or exceeds image height (${img_height}px) for $src; ignoring vertical crop." >&2
        top=0
        bottom=0
    fi

    if [ "$top" -eq 0 ] && [ "$bottom" -eq 0 ] && [ "$left" -eq 0 ] && [ "$right" -eq 0 ]; then
        cp "$src" "$dst"
        return
    fi

    crop_width=$((img_width - left - right))
    crop_height=$((img_height - top - bottom))
    log "Crop: $src -> $(basename "$dst") (${crop_width}x${crop_height}+${left}+${top})"
    magick "$src" -crop "${crop_width}x${crop_height}+${left}+${top}" +repage "$dst"
}

# Crops (if requested) then resizes (if requested) one source file into dst_dir,
# and prints the resulting path. Order is crop-then-resize so crop pixel values
# always refer to the original image, regardless of any -w/-H resize target.
prepare_source_file() {
    local src="$1" dst_dir="$2" idx="$3"
    local ext=""
    if [[ "$(basename "$src")" == *.* ]]; then
        ext=".${src##*.}"
    fi
    local working="$src"

    if $crop_needed; then
        local cropped="$dst_dir/${idx}-crop${ext}"
        crop_file "$working" "$cropped"
        working="$cropped"
    fi

    if [ -n "$resize_arg" ]; then
        local resized="$dst_dir/${idx}${ext}"
        magick "$working" -resize "$resize_arg" "$resized"
        working="$resized"
    fi

    echo "$working"
}

probe_single_image() {
    local source="$1" probe line_count format frames probe_width probe_height

    if [ ! -f "$source" ] || [ -L "$source" ] || [ ! -r "$source" ]; then
        echo "Pagination input must be a readable, regular, non-symlink image: $source" >&2
        return 1
    fi
    if ! probe="$(magick identify -quiet -format '%m|%n|%w|%h\n' "$source" 2>/dev/null)"; then
        echo "Pagination input is not a readable raster image: $source" >&2
        return 1
    fi
    line_count="$(printf '%s\n' "$probe" | awk 'NF { count++ } END { print count + 0 }')"
    IFS='|' read -r format frames probe_width probe_height <<EOF
$probe
EOF
    if [ "$line_count" -ne 1 ] || [ "$frames" != "1" ]; then
        echo "Pagination requires a single-frame image: $source" >&2
        return 1
    fi
    case "$format" in
        AI|EPDF|EPI|EPS|EPS2|EPS3|EPSF|EPSI|HTML|MVG|MSL|PDF|PS|PS2|PS3|SVG|SVGZ|TEXT|XPS)
            echo "Pagination input must be a raster image, not $format: $source" >&2
            return 1
            ;;
    esac
    if ! [[ "$probe_width" =~ ^[1-9][0-9]*$ ]] || ! [[ "$probe_height" =~ ^[1-9][0-9]*$ ]]; then
        echo "Pagination input has invalid dimensions: $source" >&2
        return 1
    fi
}

prepare_paginate_source() {
    local source="$1" work_dir="$2" oriented working prepared

    oriented="$work_dir/oriented.png"
    magick "$source" -auto-orient +repage "$oriented" || return 1
    working="$oriented"
    if $crop_needed || [ -n "$resize_arg" ]; then
        prepared="$(prepare_source_file "$working" "$work_dir" paginate)"
        if [ "$prepared" != "$oriented" ]; then
            working="$prepared"
        fi
    fi
    printf '%s\n' "$working"
}

format_timestamp_parts() {
    local year="$1" month="$2" day="$3" hour="$4" minute="$5"
    local month_name hour_number suffix
    case "$month" in
        01) month_name="Jan" ;; 02) month_name="Feb" ;; 03) month_name="Mar" ;;
        04) month_name="Apr" ;; 05) month_name="May" ;; 06) month_name="Jun" ;;
        07) month_name="Jul" ;; 08) month_name="Aug" ;; 09) month_name="Sep" ;;
        10) month_name="Oct" ;; 11) month_name="Nov" ;; 12) month_name="Dec" ;;
        *) return 1 ;;
    esac
    day=$((10#$day))
    hour_number=$((10#$hour))
    if [ "$hour_number" -ge 12 ]; then suffix="PM"; else suffix="AM"; fi
    hour_number=$((hour_number % 12))
    if [ "$hour_number" -eq 0 ]; then hour_number=12; fi
    printf '%s %d, %s · %d:%s %s\n' "$month_name" "$day" "$year" \
        "$hour_number" "$minute" "$suffix"
}

format_epoch_local() {
    local epoch="$1" parts
    if parts="$(date -r "$epoch" '+%Y %m %d %H %M' 2>/dev/null)"; then
        :
    elif parts="$(date -d "@$epoch" '+%Y %m %d %H %M' 2>/dev/null)"; then
        :
    else
        return 1
    fi
    # Intentional splitting of five numeric date fields.
    # shellcheck disable=SC2086
    format_timestamp_parts $parts
}

filesystem_epoch() {
    local source="$1" epoch=""
    epoch="$(stat -f '%B' "$source" 2>/dev/null || true)"
    if ! [[ "$epoch" =~ ^[1-9][0-9]*$ ]]; then
        epoch="$(stat -c '%W' "$source" 2>/dev/null || true)"
    fi
    if ! [[ "$epoch" =~ ^[1-9][0-9]*$ ]]; then
        epoch="$(stat -f '%m' "$source" 2>/dev/null || true)"
    fi
    if ! [[ "$epoch" =~ ^[1-9][0-9]*$ ]]; then
        epoch="$(stat -c '%Y' "$source" 2>/dev/null || true)"
    fi
    [[ "$epoch" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$epoch"
}

creation_timestamp() {
    local source="$1" embedded base epoch
    embedded="$(magick identify -quiet -format '%[EXIF:DateTimeOriginal]' \
        "${source}[0]" 2>/dev/null || true)"
    if [[ "$embedded" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})[[:space:]]+([0-9]{2}):([0-9]{2}):[0-9]{2} ]]; then
        format_timestamp_parts "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        return
    fi
    base="$(basename "$source")"
    if [[ "$base" =~ ^screencapture-.*-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})(\.[pP][nN][gG])?$ ]]; then
        format_timestamp_parts "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        return
    fi
    epoch="$(filesystem_epoch "$source")" || return 1
    format_epoch_local "$epoch"
}

expand_title_template() {
    local template="$1" source="$2" filename stem result=""
    local length index=0 pair field field_end

    filename="$(basename "$source")"
    stem="${filename%.*}"
    if [ -z "$stem" ]; then
        stem="$filename"
    fi
    length=${#template}

    while [ "$index" -lt "$length" ]; do
        pair="${template:$index:2}"
        case "$pair" in
            '{{')
                result+='{'
                index=$((index + 2))
                continue
                ;;
            '}}')
                result+='}'
                index=$((index + 2))
                continue
                ;;
        esac
        case "${template:$index}" in
            '{filename}'*)
                result+="$filename"
                index=$((index + 10))
                continue
                ;;
            '{stem}'*)
                result+="$stem"
                index=$((index + 6))
                continue
                ;;
        esac
        if [ "${template:$index:1}" = "{" ]; then
            field_end=$((index + 1))
            while [ "$field_end" -lt "$length" ] && \
                [ "${template:$field_end:1}" != "}" ]; do
                field_end=$((field_end + 1))
            done
            if [ "$field_end" -lt "$length" ]; then
                field="${template:$index:$((field_end - index + 1))}"
            else
                field="${template:$index}"
            fi
            echo "Unknown title field: $field" >&2
            return 1
        fi
        if [ "${template:$index:1}" = "}" ]; then
            echo "Unmatched closing brace in title template." >&2
            return 1
        fi
        result+="${template:$index:1}"
        index=$((index + 1))
    done

    printf '%s\n' "$result"
}

render_text_label() {
    local text="$1" destination="$2" density="$3"
    magick -background none -fill black -font "$paginate_font" \
        -pointsize "$page_font_size" -units PixelsPerInch -density "$density" \
        "label:$text" "$destination"
}

render_fitted_title() {
    local text="$1" destination="$2" density="$3" max_width="$4"
    local candidate length dimensions candidate_width
    [ -n "$text" ] && [ "$max_width" -gt 0 ] || return 1
    candidate="$text"
    length=${#candidate}
    while [ "$length" -gt 0 ]; do
        render_text_label "$candidate" "$destination" "$density" || return 1
        dimensions="$(get_pixel_size "$destination")"
        candidate_width="${dimensions%%x*}"
        if [ "$candidate_width" -le "$max_width" ]; then
            log "Header title: $candidate"
            return 0
        fi
        length=$((length - 1))
        candidate="${text:0:length}…"
    done
    rm -f "$destination"
    return 1
}

render_page_png() {
    local source="$1" destination="$2" canvas_width="$3"
    local canvas_height="$4" page_margin_top="$5" page_margin_right="$6"
    local page_margin_bottom="$7" page_margin_left="$8" density="$9"
    local header_height="${10}" footer_height="${11}" page_label="${12}"
    local labels_dir="${13}" decoration_inset="${14}" rule_width="${15}"
    local header_date_label="${16}" header_date_geometry="${17}"
    local header_title_label="${18}" header_title_geometry="${19}"
    local decoration_left decoration_right content_top rule_y
    local label dimensions label_width label_height label_x label_y
    local -a operations=()

    content_top=$((page_margin_top + header_height))
    decoration_left=$((page_margin_left + decoration_inset))
    decoration_right=$((canvas_width - page_margin_right - decoration_inset))

    if $header_line_set; then
        rule_y=$((content_top - 1))
        operations+=( -stroke '#d0d0d0' -strokewidth "$rule_width" \
            -draw "line ${decoration_left},${rule_y} ${decoration_right},${rule_y}" )
    fi
    if $footer_line_set; then
        rule_y=$((canvas_height - page_margin_bottom - footer_height))
        operations+=( -stroke '#d0d0d0' -strokewidth "$rule_width" \
            -draw "line ${decoration_left},${rule_y} ${decoration_right},${rule_y}" )
    fi

    if [ -n "$header_date_label" ]; then
        operations+=( "$header_date_label" -geometry "$header_date_geometry" -composite )
    fi
    if [ -n "$header_title_label" ]; then
        operations+=( "$header_title_label" -geometry "$header_title_geometry" -composite )
    fi
    if [ "$footer_height" -gt 0 ]; then
        label="$labels_dir/footer-page.png"
        render_text_label "$page_label" "$label" "$density"
        dimensions="$(get_pixel_size "$label")"; label_width="${dimensions%%x*}"; label_height="${dimensions##*x}"
        label_x=$((decoration_right - label_width))
        label_y=$((canvas_height - page_margin_bottom - footer_height + (footer_height - label_height) / 2))
        operations+=( "$label" -geometry "+${label_x}+${label_y}" -composite )
    fi

    magick -units PixelsPerInch -density "$density" \
        -size "${canvas_width}x${canvas_height}" xc:white \
        "$source" -geometry "+${page_margin_left}+${content_top}" -composite \
        ${operations[@]+"${operations[@]}"} -alpha off "$destination"
}

write_paginate_slices() {
    local source="$1" slices_dir="$2" source_width="$3"
    local source_height="$4" slice_height="$5" advance="$6"
    local page_count="$7" page_digits="$8"
    local page_number=1 start=0 end current_height slice_path
    local -a operations=()

    while [ "$page_number" -le "$page_count" ]; do
        end=$((start + slice_height))
        if [ "$end" -gt "$source_height" ]; then
            end="$source_height"
        fi
        current_height=$((end - start))
        slice_path="$(printf "%s/slice-%0*d.miff" "$slices_dir" "$page_digits" "$page_number")"
        operations+=( '(' +clone -crop "${source_width}x${current_height}+0+${start}" \
            +repage -write "$slice_path" +delete ')' )
        if [ "$end" -eq "$source_height" ]; then
            break
        fi
        start=$((start + advance))
        page_number=$((page_number + 1))
    done

    magick "$source" "${operations[@]}" null:
}

validate_generated_pages() {
    local expected_width="$1" expected_height="$2"
    shift 2
    local page dimensions

    for page in "$@"; do
        if [ ! -f "$page" ] || [ -L "$page" ] || [ ! -s "$page" ]; then
            echo "Pagination produced an invalid page image: $page" >&2
            return 1
        fi
        dimensions="$(magick identify -quiet -format '%wx%h' "${page}[0]" 2>/dev/null)" || return 1
        if [ "$dimensions" != "${expected_width}x${expected_height}" ]; then
            echo "Pagination page has unexpected dimensions: $page ($dimensions)" >&2
            return 1
        fi
    done
}

validate_paginated_pdf() {
    local candidate="$1" expected_count="$2" expected_width_points="$3"
    local expected_height_points="$4"

    if [ ! -f "$candidate" ] || [ -L "$candidate" ] || [ ! -s "$candidate" ]; then
        echo "Pagination produced no valid nonempty PDF." >&2
        return 1
    fi
    if ! LC_ALL=C awk -v expected_count="$expected_count" \
        -v expected_width="$expected_width_points" \
        -v expected_height="$expected_height_points" '
        function abs(value) { return value < 0 ? -value : value }
        NR == 1 && substr($0, 1, 5) == "%PDF-" { header=1 }
        index($0, "/Type /Page") && !index($0, "/Type /Pages") { pages++ }
        index($0, "/MediaBox [") {
            line=$0
            sub(/^.*\/MediaBox \[/, "", line)
            sub(/\].*$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            count=split(line, value, /[[:space:]]+/)
            if (count != 4 || abs(value[3] - expected_width) > 1 ||
                abs(value[4] - expected_height) > 1) bad=1
            boxes++
        }
        index($0, "%%EOF") { eof=1 }
        END {
            exit !(header && eof && pages == expected_count &&
                boxes == expected_count && !bad)
        }
    ' "$candidate"; then
        echo "Generated PDF failed page-count or page-size validation." >&2
        return 1
    fi
}

run_paginate() {
    local pattern source source_dir source_base source_stem paginate_work prepared
    local saved_ifs
    local dimensions source_width source_height paper_width paper_height
    local canvas_width canvas_height slice_height advance page_count density
    local header_height=0 footer_height=0 created_text="" decoration_height decoration_inset rule_width
    local page_digits page_number start end page_path slice_path slices_dir
    local header_date_label="" header_date_geometry="" header_title_label="" header_title_geometry=""
    local label_width label_height label_x label_y title_gap title_max
    local destination destination_dir destination_base destination_dir_abs out_parent_dir timestamp
    local staging candidate choice
    local -a matches=() pages=()

    pattern="${input_patterns[0]}"
    if [ -e "$pattern" ] || [ -L "$pattern" ]; then
        matches=("$pattern")
    else
        shopt -s nullglob
        saved_ifs="$IFS"
        IFS=
        # Intentional pathname expansion; disabling field splitting preserves
        # spaces, tabs, and newlines within each matched pathname.
        # shellcheck disable=SC2206
        matches=( $pattern )
        IFS="$saved_ifs"
        shopt -u nullglob
    fi
    if [ ${#matches[@]} -ne 1 ]; then
        echo "Pagination requires exactly one image; input matched ${#matches[@]} files: $pattern" >&2
        return 1
    fi
    source="${matches[0]}"
    probe_single_image "$source" || return 1
    if $title_set; then
        title="$(expand_title_template "$title" "$source")" || return 1
    fi

    paginate_work="$(mktemp -d "$tmpdir/paginate.XXXXXX")"
    prepared="$(prepare_paginate_source "$source" "$paginate_work")" || return 1
    dimensions="$(get_pixel_size "$prepared")"
    source_width="${dimensions%%x*}"
    source_height="${dimensions##*x}"
    if ! [[ "$source_width" =~ ^[1-9][0-9]*$ ]] || ! [[ "$source_height" =~ ^[1-9][0-9]*$ ]]; then
        echo "Pagination source has invalid dimensions after preprocessing." >&2
        return 1
    fi

    case "$paper" in
        letter) paper_width="612"; paper_height="792" ;;
        a4) paper_width="595.2756"; paper_height="841.8898" ;;
        legal) paper_width="612"; paper_height="1008" ;;
        *)
            paper_width="612"
            paper_height="$(LC_ALL=C awk -v width="$paper_custom_width" \
                -v height="$paper_custom_height" \
                'BEGIN { printf "%.8f", 612 * height / width }')"
            ;;
    esac
    canvas_width=$((source_width + margin_left + margin_right))
    canvas_height="$(LC_ALL=C awk -v width="$canvas_width" -v pw="$paper_width" \
        -v ph="$paper_height" 'BEGIN { printf "%d", (width * ph / pw) + 0.5 }')"
    density="$(LC_ALL=C awk -v width="$canvas_width" -v height="$canvas_height" \
        -v pw="$paper_width" -v ph="$paper_height" \
        'BEGIN { printf "%.8fx%.8f", 72 * width / pw, 72 * height / ph }')"
    decoration_height="$(LC_ALL=C awk -v height="$canvas_height" -v ph="$paper_height" \
        'BEGIN { printf "%d", (24 * height / ph) + 0.5 }')"
    decoration_inset="$(LC_ALL=C awk -v width="$canvas_width" -v pw="$paper_width" \
        'BEGIN { printf "%d", (12 * width / pw) + 0.5 }')"
    rule_width="$(LC_ALL=C awk -v width="$canvas_width" -v pw="$paper_width" \
        'BEGIN { printf "%.4f", 0.25 * width / pw }')"
    if $header_set; then
        header_height="$decoration_height"
        if ! created_text="$(creation_timestamp "$source")"; then
            echo "Could not determine a creation time for pagination header: $source" >&2
            return 1
        fi
    fi
    if $footer_set; then footer_height="$decoration_height"; fi
    if { $header_set || $footer_set; } && [ "$decoration_height" -lt 3 ]; then
        echo "Page dimensions are too small to render the requested header or footer." >&2
        return 1
    fi
    slice_height=$((canvas_height - margin_top - margin_bottom - header_height - footer_height))
    if [ "$slice_height" -le 0 ]; then
        echo "Margins and header/footer bands leave no usable screenshot area." >&2
        return 1
    fi
    if [ "$overlap" -ge "$slice_height" ]; then
        echo "--overlap ($overlap) must be smaller than the page slice height ($slice_height)." >&2
        return 1
    fi
    advance=$((slice_height - overlap))
    if [ "$source_height" -le "$slice_height" ]; then
        page_count=1
    else
        page_count=$((1 + (source_height - slice_height + advance - 1) / advance))
    fi
    page_digits=${#page_count}
    if [ "$page_digits" -lt 3 ]; then
        page_digits=3
    fi

    log "Paginate: paper=$paper margins=${margin_top}/${margin_right}/${margin_bottom}/${margin_left}px source=${source_width}x${source_height}"
    log "Paginate: canvas=${canvas_width}x${canvas_height} slice=${slice_height}px overlap=${overlap}px pages=$page_count"
    log "Paginate: header=${header_height}px footer=${footer_height}px font=${page_font_size}pt inset=${decoration_inset}px lines=${header_line_set}/${footer_line_set} created='${created_text}'"

    if $output_pages_set; then
        if $output_set; then
            out_parent_dir="$output_file"
        else
            out_parent_dir="."
        fi
        if [ ! -e "$out_parent_dir" ] && [ ! -L "$out_parent_dir" ]; then
            if ! mkdir -p "$out_parent_dir"; then
                echo "Could not create PNG page output parent directory: $out_parent_dir" >&2
                return 1
            fi
            log "Created PNG page output parent: $out_parent_dir"
        fi
        if [ ! -d "$out_parent_dir" ] || [ -L "$out_parent_dir" ] || [ ! -w "$out_parent_dir" ]; then
            echo "PNG page output parent must be a writable directory and not a symbolic link: $out_parent_dir" >&2
            return 1
        fi
        destination_dir_abs="$(cd "$out_parent_dir" && pwd -P)"
        timestamp="$(date +%Y%m%d-%H%M%S)"
        destination_base="pages-${timestamp}"
        destination="$destination_dir_abs/$destination_base"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            destination="$(next_available_name "$destination")"
            destination_base="$(basename "$destination")"
        fi
        paginate_publish_tmp="$(mktemp -d "$destination_dir_abs/.${destination_base}.XXXXXX")"
        staging="$paginate_publish_tmp"
    else
        if $output_set; then
            destination="$output_file"
        else
            source_dir="$(dirname "$source")"
            source_base="$(basename "$source")"
            source_stem="${source_base%.*}"
            if [ -z "$source_stem" ]; then
                source_stem="$source_base"
            fi
            destination="$source_dir/$source_stem.pdf"
        fi
        case "$destination" in
            *.[pP][dD][fF]) ;;
            *)
                echo "Pagination PDF output must have a .pdf extension: $destination" >&2
                return 1
                ;;
        esac
        if [ -L "$destination" ]; then
            echo "Pagination PDF output must not be a symbolic link: $destination" >&2
            return 1
        fi
        if [ -e "$destination" ] && [ ! -f "$destination" ]; then
            echo "Pagination PDF output must be a regular file path: $destination" >&2
            return 1
        fi
        if [ -e "$destination" ] && ! $force_overwrite; then
            if [ ! -t 0 ]; then
                echo "Output file exists; use -O/--overwrite in non-interactive mode: $destination" >&2
                return 1
            fi
            echo "Output file exists: $destination" >&2
            while true; do
                printf "Overwrite [o] or keep both [k]? " >&2
                read -r choice
                case "$choice" in
                    o|O|overwrite) break ;;
                    k|K|keep)
                        destination="$(next_available_name "$destination")"
                        echo "Using output file: $destination" >&2
                        break
                        ;;
                    *) echo "Please enter 'o' or 'k'." >&2 ;;
                esac
            done
        fi
        destination_dir="$(dirname "$destination")"
        destination_base="$(basename "$destination")"
        if [ ! -d "$destination_dir" ] || [ -L "$destination_dir" ] || [ ! -w "$destination_dir" ]; then
            echo "PDF output parent must be an existing writable directory: $destination_dir" >&2
            return 1
        fi
        destination_dir_abs="$(cd "$destination_dir" && pwd -P)"
        destination="$destination_dir_abs/$destination_base"
        paginate_publish_tmp="$(mktemp "$destination_dir_abs/.screenshots-pdf.XXXXXX.pdf")"
        candidate="$paginate_publish_tmp"
        staging="$paginate_work/pages"
        mkdir "$staging"
    fi

    if [ "$header_height" -gt 0 ]; then
        header_date_label="$paginate_work/header-date.png"
        render_text_label "$created_text" "$header_date_label" "$density" || return 1
        dimensions="$(get_pixel_size "$header_date_label")"
        label_width="${dimensions%%x*}"
        label_height="${dimensions##*x}"
        label_y=$((margin_top + (header_height - label_height) / 2))
        label_x=$((margin_left + decoration_inset))
        header_date_geometry="+${label_x}+${label_y}"
        if [ -n "$title" ]; then
            title_gap=$((label_height > 0 ? label_height : 1))
            title_max=$((canvas_width - margin_right - decoration_inset - margin_left - decoration_inset - label_width - title_gap))
            header_title_label="$paginate_work/header-title.png"
            if render_fitted_title "$title" "$header_title_label" "$density" "$title_max"; then
                dimensions="$(get_pixel_size "$header_title_label")"
                label_width="${dimensions%%x*}"
                label_height="${dimensions##*x}"
                label_x=$((canvas_width - margin_right - decoration_inset - label_width))
                label_y=$((margin_top + (header_height - label_height) / 2))
                header_title_geometry="+${label_x}+${label_y}"
            else
                header_title_label=""
            fi
        fi
    fi

    slices_dir="$paginate_work/slices"
    mkdir "$slices_dir"
    write_paginate_slices "$prepared" "$slices_dir" "$source_width" \
        "$source_height" "$slice_height" "$advance" "$page_count" "$page_digits" || return 1

    page_number=1
    start=0
    while [ "$page_number" -le "$page_count" ]; do
        end=$((start + slice_height))
        if [ "$end" -gt "$source_height" ]; then
            end="$source_height"
        fi
        page_path="$(printf "%s/page-%0*d.png" "$staging" "$page_digits" "$page_number")"
        slice_path="$(printf "%s/slice-%0*d.miff" "$slices_dir" "$page_digits" "$page_number")"
        log "Page $page_number: source rows [$start,$end)"
        render_page_png "$slice_path" "$page_path" "$canvas_width" "$canvas_height" \
            "$margin_top" "$margin_right" "$margin_bottom" "$margin_left" "$density" \
            "$header_height" "$footer_height" "${page_number}/${page_count}" \
            "$paginate_work" "$decoration_inset" "$rule_width" \
            "$header_date_label" "$header_date_geometry" \
            "$header_title_label" "$header_title_geometry" || return 1
        pages+=("$page_path")
        if [ "$end" -eq "$source_height" ]; then
            break
        fi
        start=$((start + advance))
        page_number=$((page_number + 1))
    done
    if [ ${#pages[@]} -ne "$page_count" ]; then
        echo "Pagination generated ${#pages[@]} pages; expected $page_count." >&2
        return 1
    fi
    validate_generated_pages "$canvas_width" "$canvas_height" "${pages[@]}" || return 1

    if $output_pages_set; then
        mv "$paginate_publish_tmp" "$destination"
        paginate_publish_tmp=""
        all_output_list+=("$destination")
        return 0
    fi

    log "PDF assembly: ${#pages[@]} page(s) -> $destination"
    if ! magick "${pages[@]}" -units PixelsPerInch -density "$density" \
        -compress Zip "$candidate"; then
        echo "ImageMagick PDF writing is unavailable. Use --output-pages as a PNG fallback." >&2
        return 1
    fi
    validate_paginated_pdf "$candidate" "$page_count" "$paper_width" "$paper_height" || return 1
    mv -f "$candidate" "$destination"
    all_output_list+=("$destination")
}

# Populates the global 'montage_files' array from the global 'source_files'
# array. Crops/resizes per-file (rather than batching by basename) because zip
# mode routinely combines files with identical basenames from different
# input lists (e.g. android/01.png and ios/01.png).
build_montage_inputs() {
    montage_files=()
    if $crop_needed || [ -n "$resize_arg" ]; then
        local call_tmpdir i=0 f
        call_tmpdir="$(mktemp -d "$tmpdir/r.XXXXXX")"
        for f in "${source_files[@]}"; do
            montage_files+=("$(prepare_source_file "$f" "$call_tmpdir" "$i")")
            i=$((i + 1))
        done
    else
        montage_files=("${source_files[@]}")
    fi
}

# Runs montage on the global 'montage_files' array, writes to 'output_file',
# and appends the resulting path(s) to the global 'all_output_list' array.
run_montage_and_finalize() {
    local out_dir out_dir_abs out_base out_ext out_name call_out_tmpdir
    local tmp_outputs=() matches=() match tmp_out
    local montage_border_args=()

    if $do_border; then
        montage_border_args=(-bordercolor "$border_color" -border "$border_width")
    fi

    out_dir="$(dirname "$output_file")"
    mkdir -p "$out_dir"
    out_dir_abs="$(cd "$out_dir" && pwd -P)"
    out_base="$(basename "$output_file")"
    if [[ "$out_base" == *.* ]]; then
        out_ext=".${out_base##*.}"
        out_name="${out_base%.*}"
    else
        out_ext=""
        out_name="$out_base"
    fi

    log "Montage: tile=$tile gap=${gap_x}x${gap_y} gravity=$gravity background=$background border=$do_border -> $out_dir_abs/$out_base"
    call_out_tmpdir="$(mktemp -d "$out_tmpdir/m.XXXXXX")"
    montage \
        -font "$montage_font" \
        -background "$background" \
        -gravity "$gravity" \
        -tile "$tile" \
        -geometry "+${gap_x}+${gap_y}" \
        "${montage_border_args[@]+"${montage_border_args[@]}"}" \
        "${montage_files[@]}" \
        "$call_out_tmpdir/$out_base"

    if [ -f "$call_out_tmpdir/$out_base" ]; then
        tmp_outputs+=("$call_out_tmpdir/$out_base")
        all_output_list+=("$out_dir_abs/$out_base")
    fi

    shopt -s nullglob
    matches=( "$call_out_tmpdir/${out_name}-"*"$out_ext" )
    shopt -u nullglob
    for match in "${matches[@]-}"; do
        if [ -f "$match" ]; then
            tmp_outputs+=("$match")
            all_output_list+=("$out_dir_abs/$(basename "$match")")
        fi
    done

    if [ ${#tmp_outputs[@]} -eq 0 ]; then
        echo "No output file was created for: $output_file" >&2
        exit 1
    fi

    for tmp_out in "${tmp_outputs[@]}"; do
        mv -f "$tmp_out" "$out_dir_abs/$(basename "$tmp_out")"
    done
}

all_output_list=()
tmpdir="$(mktemp -d /tmp/screenshots.XXXXXX)"
out_tmpdir="$(mktemp -d /tmp/screenshots.out.XXXXXX)"

if [ -n "$preset_name" ]; then
    effective_command="$(format_shell_words "$0" "${effective_args[@]}")"
    operational_message stdout "Effective command: $effective_command"

    if $verbose && [ ${#superseded_preset_options[@]} -gt 0 ]; then
        superseded_text=""
        for preset_index in "${!superseded_preset_options[@]}"; do
            superseded_text+=$'\n'"${superseded_preset_options[$preset_index]} → ${superseded_by_options[$preset_index]}"
        done
        log "Superseded preset options:$superseded_text"
    fi

    log "Preset: $preset_name -> paginate=$paginate_mode header=$header_set footer=$footer_set lines=${header_line_set}/${footer_line_set} overlap=${overlap}px title='$title'"
fi

case "$mode" in
    paginate) operational_message stdout "processing: ${input_patterns[0]}" ;;
    zip) operational_message stdout "processing: zip (${#input_patterns[@]} input patterns)" ;;
    each) operational_message stdout "processing: each (${input_patterns[0]})" ;;
    montage) operational_message stdout "processing: ${input_patterns[0]}" ;;
esac

if [ "$mode" = "paginate" ]; then
    run_paginate
    report_outputs
    exit 0
elif $zip_mode; then
    zip_n=${#input_patterns[@]}
    zip_all_files=()
    zip_offsets=()
    zip_counts=()
    offset=0
    shopt -s nullglob
    for idx in "${!input_patterns[@]}"; do
        pattern="${input_patterns[$idx]}"
        matched=( $pattern )
        if [ ${#matched[@]} -eq 0 ]; then
            echo "No files match pattern: $pattern" >&2
            exit 1
        fi
        sorted=()
        while IFS= read -r line; do
            sorted+=("$line")
        done < <(printf '%s\n' "${matched[@]}" | LC_ALL=C sort)
        zip_offsets[$idx]=$offset
        zip_counts[$idx]=${#sorted[@]}
        zip_all_files+=("${sorted[@]}")
        offset=$((offset + ${#sorted[@]}))
        log "Zip input #$((idx + 1)) ('$pattern'): ${#sorted[@]} file(s)"
    done
    shopt -u nullglob

    mismatch=false
    for idx in "${!zip_counts[@]}"; do
        if [ "${zip_counts[$idx]}" -ne "${zip_counts[0]}" ]; then
            mismatch=true
        fi
    done
    if $mismatch; then
        echo "Zip mode requires all input patterns to resolve to the same number of files:" >&2
        for idx in "${!input_patterns[@]}"; do
            echo "  '${input_patterns[$idx]}': ${zip_counts[$idx]} file(s)" >&2
        done
        exit 1
    fi
    zip_m=${zip_counts[0]}
    log "Zip mode: $zip_n input list(s), $zip_m montage(s) to produce"

    tile_cols="${tile%x*}"
    tile_rows="${tile#*x}"
    if [ "$tile_cols" -gt "$zip_n" ]; then
        log "Tile: capping columns from $tile_cols to $zip_n"
        tile_cols="$zip_n"
    fi
    tile="${tile_cols}x${tile_rows}"

    if $output_set; then
        out_parent_dir="$output_file"
    else
        out_parent_dir="."
    fi
    timestamp="$(date +%Y%m%d-%H%M%S)"
    zip_out_dir="${out_parent_dir}/zip-${timestamp}"
    if [ -e "$zip_out_dir" ]; then
        zip_out_dir="$(next_available_name "$zip_out_dir")"
    fi
    log "Zip output folder: $zip_out_dir"

    j=0
    while [ "$j" -lt "$zip_m" ]; do
        source_files=()
        for idx in "${!input_patterns[@]}"; do
            pos=$(( zip_offsets[idx] + j ))
            source_files+=("${zip_all_files[$pos]}")
        done
        build_montage_inputs
        output_file="${zip_out_dir}/$((j + 1)).png"
        run_montage_and_finalize
        j=$((j + 1))
    done
elif $each_mode; then
    shopt -s nullglob
    files=( ${input_patterns[0]} )
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        echo "No files match pattern: ${input_patterns[0]}" >&2
        exit 1
    fi
    log "Inputs: ${#files[@]} file(s) from pattern '${input_patterns[0]}'"

    if $output_set; then
        out_parent_dir="$output_file"
    else
        out_parent_dir="."
    fi
    timestamp="$(date +%Y%m%d-%H%M%S)"
    each_out_dir="${out_parent_dir}/each-${timestamp}"
    if [ -e "$each_out_dir" ]; then
        each_out_dir="$(next_available_name "$each_out_dir")"
    fi
    each_out_dir_created=false

    for file in "${files[@]}"; do
        src_base="$(basename "$file")"
        dst_base="$src_base"

        ext=""
        if [[ "$src_base" == *.* ]]; then
            ext=".${src_base##*.}"
        fi
        call_tmpdir="$(mktemp -d "$out_tmpdir/e.XXXXXX")"
        working="$file"
        if $crop_needed; then
            cropped="$call_tmpdir/crop$ext"
            crop_file "$working" "$cropped"
            working="$cropped"
        fi
        tmp_dst="$call_tmpdir/tmp$ext"
        if [ -n "$resize_arg" ]; then
            log "Resize: $file -> $dst_base"
            magick "$working" -resize "$resize_arg" "$tmp_dst"
        else
            log "Copy: $file -> $dst_base"
            cp "$working" "$tmp_dst"
        fi

        if ! $each_out_dir_created; then
            mkdir -p "$each_out_dir"
            each_out_dir_abs="$(cd "$each_out_dir" && pwd -P)"
            log "Each output folder: $each_out_dir_abs"
            each_out_dir_created=true
        fi
        dst="${each_out_dir_abs}/${dst_base}"
        mv -f "$tmp_dst" "$dst"
        all_output_list+=("$dst")
    done
else
    shopt -s nullglob
    files=( ${input_patterns[0]} )
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        echo "No files match pattern: ${input_patterns[0]}" >&2
        exit 1
    fi
    log "Inputs: ${#files[@]} file(s) from pattern '${input_patterns[0]}'"

    if [ -e "$output_file" ] && ! $force_overwrite; then
        echo "Output file exists: $output_file" >&2
        while true; do
            printf "Overwrite [o] or keep both [k]? " >&2
            read -r choice
            case "$choice" in
                o|O|overwrite)
                    break
                    ;;
                k|K|keep)
                    output_file="$(next_available_name "$output_file")"
                    echo "Using output file: $output_file" >&2
                    break
                    ;;
                *)
                    echo "Please enter 'o' or 'k'." >&2
                    ;;
            esac
        done
    fi

    filtered_files=()
    output_basename="$(basename "$output_file")"
    output_dir="$(dirname "$output_file")"
    for file in "${files[@]}"; do
        if [ "$(basename "$file")" = "$output_basename" ] && [ "$(dirname "$file")" = "$output_dir" ]; then
            continue
        fi
        filtered_files+=("$file")
    done

    if [ ${#filtered_files[@]} -eq 0 ]; then
        echo "No input files left after excluding output file." >&2
        exit 1
    fi
    if [ ${#filtered_files[@]} -ne ${#files[@]} ]; then
        log "Excluded output file from inputs (remaining: ${#filtered_files[@]})"
    fi

    tile_cols="${tile%x*}"
    tile_rows="${tile#*x}"
    if [ "$tile_cols" -gt "${#filtered_files[@]}" ]; then
        log "Tile: capping columns from $tile_cols to ${#filtered_files[@]}"
        tile_cols="${#filtered_files[@]}"
    fi
    tile="${tile_cols}x${tile_rows}"

    source_files=("${filtered_files[@]}")
    build_montage_inputs
    run_montage_and_finalize
fi

if [ ${#all_output_list[@]} -eq 0 ]; then
    echo "No output files were created." >&2
    exit 1
fi

if $do_trim; then
    log "Trim: enabled (fuzz=${trim_fuzz}%)"
    for out in "${all_output_list[@]}"; do
        magick "$out" -fuzz "${trim_fuzz}%" -trim "$out"
    done
else
    log "Trim: skipped"
fi

if $do_border && $each_mode; then
    log "Border: enabled (width=$border_width color=$border_color)"
    for out in "${all_output_list[@]}"; do
        magick "$out" -bordercolor "$border_color" -border "$border_width" "$out"
    done
elif $do_border; then
    log "Border: already applied per-tile during montage"
fi

if $do_shadow; then
    log "Shadow: enabled"
    for out in "${all_output_list[@]}"; do
        magick "$out" \
            \( -clone 0 -background "$shadow_color" -shadow 30x5+5+5 \) \
            \( -clone 0 -background "$shadow_color" -shadow 30x5-5-5 \) \
            -reverse -background none -layers merge +repage "$out"
    done
else
    log "Shadow: skipped"
fi

report_outputs

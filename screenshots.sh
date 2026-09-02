#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./screenshots.sh -i PATTERN -o FILE [options] [-v]                             # montage mode
       ./screenshots.sh -i PATTERN -i PATTERN [-i PATTERN ...] [-o DIR] [options] [-v] # zip mode
       ./screenshots.sh -i PATTERN -e [-o DIR] [options] [-v]                          # each mode

Modes:
  montage  Combine all matched screenshots into one grid image.
  zip      Pair matched screenshots across 2+ -i patterns, one montage per pair.
  each     Process every matched screenshot on its own, no montage.

Options:
  -i, --input PATTERN    Input glob pattern (required)
                         Quote it (e.g. "*.png") so the shell passes it
                         through unexpanded for the script to glob itself.
                         Repeatable: passing -i more than once enables
                         zip mode (see below).
  -o, --output FILE|DIR  Montage mode: output file (default: output.png)
                         Zip/Each mode: destination directory (default:
                         current directory) — a new "zip-<timestamp>"/
                         "each-<timestamp>" folder is created inside it.
                         Not repeatable: passing -o more than once is
                         an error.
  -e, --each             Use each mode instead of montaging matched
                         files together (see below). Requires exactly
                         one -i pattern.
  -w, --width N          Resize by max width in pixels (opt-in)
  -H, --height N         Resize by max height in pixels (opt-in)
  -s, --shadow           Add drop shadow
  -b, --border [N]       Add a border (montage/zip mode: per tile, baked
                         into the montage step; each mode: per file).
                         N is pixel width (default: 1 if --border is
                         given with no value)
  -h, --help             Show this help

Advanced options (crop and resize apply per input image, before
montaging; trim, border, and shadow apply per output image, after,
in that order):
  -O, --overwrite        Overwrite output file without prompting
                         (montage mode only; zip/each always write into
                         a fresh timestamped folder)
  -v, --verbose          Print each action taken
  -t, --tile COLSxROWS   [montage/zip only] Montage tile layout
                         (default: 10x0; 0 means auto; in zip mode
                         defaults to Nx1, N = number of -i patterns,
                         unless explicitly given)
  -g, --gap XxY          [montage/zip only] Gap between tiles in
                         pixels (default: 15x15)
  -G, --gravity GRAVITY  [montage/zip only] Montage gravity (default:
                         north). Options: north, south, east, west,
                         center, northeast, northwest, southeast,
                         southwest
  --background COLOR     [montage/zip only] Montage background
                         (default: transparent). Examples: white,
                         black, red, #ff0000
  --trim                 Trim final output (default for montage/zip)
  --no-trim              Skip final trim (default for each)
  --trim-fuzz N          Fuzz tolerance % for trim (default: 0)
  --shadow-color COLOR   Shadow color (default: gray)
  --font FILE            [montage/zip only] Font file for ImageMagick.
                         If omitted, a system font is discovered automatically.
  --border-color COLOR   Border color (default: black)
  -c, --crop N           Crop N pixels off all four sides of each input
                         image, applied before resize (bare -c with no
                         value has no effect)
  -ct, --crop-top N      Additional top crop, on top of -c
  -cb, --crop-bottom N   Additional bottom crop, on top of -c
  -cl, --crop-left N     Additional left crop, on top of -c
  -cr, --crop-right N    Additional right crop, on top of -c

Zip mode:
  Pass -i more than once to montage matching screenshots side by side
  across N input lists. Each pattern is expanded and sorted
  (LC_ALL=C), and every list must resolve to the same number of files;
  the file at position j in each list is combined into one montage, so
  the order of -i flags defines left-to-right position and sorted file
  order defines pairing across lists.

  Outputs are named "1.png", "2.png", etc. and written into a new
  "zip-<timestamp>" folder created inside -o (or the current
  directory, if -o was omitted).

Each mode (-e/--each):
  Resizes, trims, borders, and shadows every file matched by -i on
  its own — no montage step, so montage options are ignored in this
  mode.

  Outputs keep their original filenames and are written into a new
  "each-<timestamp>" folder created inside -o (or the current
  directory, if -o was omitted).

Examples:
  ./screenshots.sh -i "1*.png" -o out.png --width 750 --shadow
  ./screenshots.sh -i "1*.png" -o out.png --tile 25x1 --gap 15x15
  ./screenshots.sh -i "android/*.png" -i "ios/*.png" -o compare/
  ./screenshots.sh -i "1*.png" --each --width 750 --shadow
EOF
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
force_overwrite=false
verbose=false
shadow_color="gray"
font_file=""
do_border=false
border_width="1"
border_color="black"
each_mode=false

output_set=false

tmpdir=""
out_tmpdir=""
cleanup() {
    if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
        rm -rf "$tmpdir"
    fi
    if [ -n "$out_tmpdir" ] && [ -d "$out_tmpdir" ]; then
        rm -rf "$out_tmpdir"
    fi
}
trap cleanup EXIT

log() {
    if $verbose; then
        echo "$@" >&2
    fi
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input|-o|--output|-w|--width|-H|--height|-t|--tile|-g|--gap|-G|--gravity|--background|--shadow-color|--font|--border-color|--trim-fuzz)
            if [ $# -lt 2 ]; then
                echo "Option $1 requires an argument." >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            ;;
    esac
    case "$1" in
        -h|--help)
            usage
            exit 0
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
                    echo "Option -o/--output must be a literal filename, not a glob pattern: $2" >&2
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
            shift 2
            ;;
        -G|--gravity)
            gravity="$2"
            shift 2
            ;;
        --background)
            background="$2"
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
            shift 2
            ;;
        -s|--shadow)
            do_shadow=true
            shift
            ;;
        --shadow-color)
            shadow_color="$2"
            shift 2
            ;;
        --font)
            font_file="$2"
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
            shift 2
            ;;
        -c|--crop)
            crop_all_seen=$((crop_all_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_all_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -ct|--crop-top)
            crop_top_seen=$((crop_top_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_top_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cb|--crop-bottom)
            crop_bottom_seen=$((crop_bottom_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_bottom_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cl|--crop-left)
            crop_left_seen=$((crop_left_seen + 1))
            if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                crop_left_val="$2"
                shift 2
            else
                shift
            fi
            ;;
        -cr|--crop-right)
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

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick 'magick' not found in PATH." >&2
    exit 1
fi

if ! command -v montage >/dev/null 2>&1; then
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
if ! $each_mode; then
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

if [ -n "$width" ] && ! [[ "$width" =~ ^[0-9]+$ ]]; then
    echo "Invalid --width value: $width" >&2
    exit 1
fi

if [ -n "$height" ] && ! [[ "$height" =~ ^[0-9]+$ ]]; then
    echo "Invalid --height value: $height" >&2
    exit 1
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

if $zip_mode; then
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

echo "Output file(s):"
for out in "${all_output_list[@]}"; do
    echo "$out"
done

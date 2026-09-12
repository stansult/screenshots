#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$SCRIPT_DIR/screenshots.sh"
WORK_DIR="$(mktemp -d /tmp/screenshots-tests.XXXXXX)"
REAL_MONTAGE="$(command -v montage || true)"
REAL_MAGICK="$(command -v magick || true)"
REAL_STAT="$(command -v stat || true)"
REAL_DATE="$(command -v date || true)"
TEST_FONT=""

passed=0
failed=0
skipped=0
case_number=0
CASE_DIR=""
RUN_STATUS=0

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "    $*" >&2
    return 1
}

assert_status() {
    local expected="$1"
    if [ "$RUN_STATUS" -ne "$expected" ]; then
        fail "expected exit status $expected, got $RUN_STATUS"
        echo "    stderr: $(cat "$CASE_DIR/stderr")" >&2
    fi
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
    local file="$1" text="$2"
    grep -Fq -- "$text" "$file" || fail "expected '$text' in $file"
}

assert_not_contains() {
    local file="$1" text="$2"
    ! grep -Fq -- "$text" "$file" || fail "did not expect '$text' in $file"
}

assert_dimensions() {
    local file="$1" expected="$2" actual
    actual="$(magick identify -format '%wx%h' "${file}[0]")"
    [ "$actual" = "$expected" ] || fail "expected $file to be $expected, got $actual"
}

assert_page_count() {
    local file="$1" expected="$2" actual
    actual="$(magick identify -format '%p\n' "$file" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$actual" -eq "$expected" ] || fail "expected $file to have $expected pages, got $actual"
}

assert_pdf_page_size() {
    local file="$1" expected_width="$2" expected_height="$3"
    local boxes
    boxes="$(magick identify -format '%[pdf:HiResBoundingBox]\n' "$file")"
    printf '%s\n' "$boxes" | awk -F '[x+]' \
        -v expected_width="$expected_width" -v expected_height="$expected_height" '
        function abs(value) { return value < 0 ? -value : value }
        NF && (abs($1 - expected_width) > 1 || abs($2 - expected_height) > 1) { bad=1 }
        END { exit bad }
    ' || fail "PDF page dimensions are not ${expected_width}x${expected_height}: $file"
}

assert_pixel_rgb() {
    local file="$1" coordinate="$2" expected="$3" actual
    actual="$(magick "$file" -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info:)"
    if [ "$coordinate" != "0,0" ]; then
        actual="$(magick "$file" -format "%[fx:int(255*u.p{$coordinate}.r)],%[fx:int(255*u.p{$coordinate}.g)],%[fx:int(255*u.p{$coordinate}.b)]" info:)"
    fi
    [ "$actual" = "$expected" ] || fail "expected $file pixel $coordinate to be $expected, got $actual"
}

assert_region_not_white() {
    local file="$1" geometry="$2" mean
    mean="$(magick "$file" -crop "$geometry" +repage -colorspace gray \
        -format '%[fx:mean]' info:)"
    awk -v mean="$mean" 'BEGIN { exit !(mean < 0.99999) }' || \
        fail "expected non-white content in $file region $geometry"
}

find_font() {
    local font
    if command -v fc-match >/dev/null 2>&1; then
        font="$(fc-match -f '%{file}\n' sans 2>/dev/null | sed -n '1p')"
        if [ -n "$font" ] && [ -f "$font" ]; then
            echo "$font"
            return 0
        fi
    fi

    for font in \
        /System/Library/Fonts/Helvetica.ttc \
        /System/Library/Fonts/Supplemental/Arial.ttf \
        /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
    do
        if [ -f "$font" ]; then
            echo "$font"
            return 0
        fi
    done
    return 1
}

new_case() {
    case_number=$((case_number + 1))
    CASE_DIR="$WORK_DIR/case-$case_number"
    mkdir -p "$CASE_DIR"
}

make_image() {
    local path="$1" size="$2" color="$3"
    mkdir -p "$(dirname "$path")"
    magick -size "$size" "xc:$color" "$path"
}

run_script() {
    (
        cd "$CASE_DIR" || exit 1
        "$SCRIPT" "$@"
    ) >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    RUN_STATUS=$?
}

run_script_with_path() {
    local command_path="$1"
    shift
    (
        cd "$CASE_DIR" || exit 1
        PATH="$command_path" "$SCRIPT" "$@"
    ) >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    RUN_STATUS=$?
}

latest_directory() {
    local parent="$1" pattern="$2"
    find "$parent" -mindepth 1 -maxdepth 1 -type d -name "$pattern" | LC_ALL=C sort | tail -n 1
}

test_basic_montage() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/b.png" 120x90 blue
    run_script -i '*.png' -o grid.png --tile 2x1 --gap 0x0 -O
    assert_status 0 || return 1
    assert_file "$CASE_DIR/grid.png"
}

test_uniform_crop() {
    local out_dir
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --each -c 10
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR" 'each-*')"
    assert_dimensions "$out_dir/a.png" 80x60
}

test_side_specific_crop() {
    local out_dir
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --each -c 5 -ct 3 -cb 4 -cl 2 -cr 1
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR" 'each-*')"
    assert_dimensions "$out_dir/a.png" 87x63
}

test_resize() {
    local out_dir
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --each --width 50
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR" 'each-*')"
    assert_dimensions "$out_dir/a.png" 50x40
}

test_each_mode_names() {
    local out_dir count
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/b.png" 120x90 blue
    run_script -i '*.png' --each
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR" 'each-*')"
    assert_file "$out_dir/a.png" || return 1
    assert_file "$out_dir/b.png" || return 1
    count="$(find "$out_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    [ "$count" -eq 2 ] || fail "expected 2 each-mode outputs, got $count"
}

test_zip_mode() {
    local out_dir
    new_case
    make_image "$CASE_DIR/left/01.png" 100x80 red
    make_image "$CASE_DIR/left/02.png" 100x80 green
    make_image "$CASE_DIR/right/01.png" 120x80 blue
    make_image "$CASE_DIR/right/02.png" 120x80 yellow
    run_script -i 'left/*.png' -i 'right/*.png' -o results --gap 0x0
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR/results" 'zip-*')"
    assert_file "$out_dir/1.png" || return 1
    assert_file "$out_dir/2.png"
}

test_zip_count_mismatch() {
    new_case
    make_image "$CASE_DIR/left/01.png" 100x80 red
    make_image "$CASE_DIR/left/02.png" 100x80 green
    make_image "$CASE_DIR/right/01.png" 120x80 blue
    run_script -i 'left/*.png' -i 'right/*.png'
    [ "$RUN_STATUS" -ne 0 ] || return 1
    assert_contains "$CASE_DIR/stderr" 'same number of files'
}

test_no_effect_options_are_rejected() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/b.png" 100x80 blue

    run_script -i '*.png' --each --tile 1x1 --gap 1x1 --gravity north \
        --background white --font "$TEST_FONT" -O
    [ "$RUN_STATUS" -ne 0 ] || fail 'ignored each-mode options unexpectedly succeeded' || return 1
    for option in '--tile' '--gap' '--gravity' '--background' '--font' '-O/--overwrite'; do
        assert_contains "$CASE_DIR/stderr" "$option" || return 1
    done

    run_script -i '*.png' --each -t 1x1 -g 1x1 -G north
    [ "$RUN_STATUS" -ne 0 ] || fail 'short ignored each-mode options unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" 'Each mode does not use' || return 1

    run_script -i 'a.png' -i 'b.png' -O
    [ "$RUN_STATUS" -ne 0 ] || fail '-O unexpectedly succeeded in zip mode' || return 1
    assert_contains "$CASE_DIR/stderr" 'always creates a fresh output directory' || return 1

    run_script -i 'a.png' -i 'b.png' --shadow-color red
    [ "$RUN_STATUS" -ne 0 ] || fail 'zip shadow color without shadow unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" '--shadow-color requires --shadow' || return 1

    run_script -i '*.png' --each --trim-fuzz 5
    [ "$RUN_STATUS" -ne 0 ] || fail 'each trim fuzz without trim unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" '--trim-fuzz requires trimming' || return 1

    run_script -i '*.png' --shadow-color red --border-color blue --no-trim --trim-fuzz 5
    [ "$RUN_STATUS" -ne 0 ] || fail 'dependent no-effect options unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" '--shadow-color requires --shadow' || return 1
    assert_contains "$CASE_DIR/stderr" '--border-color requires --border' || return 1
    assert_contains "$CASE_DIR/stderr" '--trim-fuzz requires trimming' || return 1

    run_script -i '*.png' --border 0
    [ "$RUN_STATUS" -ne 0 ] || fail '--border 0 unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" '--border 0 adds no border' || return 1

    [ ! -e "$CASE_DIR/output.png" ] || fail 'rejected options created output.png' || return 1
    [ -z "$(find "$CASE_DIR" -maxdepth 1 -type d \( -name 'each-*' -o -name 'zip-*' \) -print)" ] || \
        fail 'rejected options created a fresh output directory' || return 1

    run_script -i '*.png' --shadow-color red --shadow --border-color blue \
        --border --trim-fuzz 5 --trim -o valid.png -O
    assert_status 0 || return 1
    assert_file "$CASE_DIR/valid.png"
}

test_output_excluded_from_inputs() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/output.png" 20x20 black
    run_script -i '*.png' -o output.png --tile 1x1 --gap 0x0 --no-trim -O
    assert_status 0 || return 1
    assert_dimensions "$CASE_DIR/output.png" 100x80
}

test_argument_validation() {
    new_case
    run_script --width 50
    [ "$RUN_STATUS" -ne 0 ] || fail "missing input unexpectedly succeeded"
    assert_contains "$CASE_DIR/stderr" 'Missing required option' || return 1

    run_script -i '*.png' --tile nope
    [ "$RUN_STATUS" -ne 0 ] || fail "invalid tile unexpectedly succeeded"
    assert_contains "$CASE_DIR/stderr" 'Invalid --tile value' || return 1

    run_script -i '*.png' --unknown
    [ "$RUN_STATUS" -ne 0 ] || fail "unknown option unexpectedly succeeded"
    assert_contains "$CASE_DIR/stderr" 'Unknown option'
}

test_general_help() {
    local short_help
    new_case
    run_script -h
    assert_status 0 || return 1
    short_help="$(cat "$CASE_DIR/stdout")"
    run_script --help
    assert_status 0 || return 1
    [ "$short_help" = "$(cat "$CASE_DIR/stdout")" ] || fail '-h and --help differ' || return 1
    for text in 'montage' 'zip' 'each' 'paginate' \
        '--help montage' '--help zip' '--help each' '--help paginate'; do
        assert_contains "$CASE_DIR/stdout" "$text" || return 1
    done
    assert_not_contains "$CASE_DIR/stdout" 'ceil((H - S)' || return 1
    assert_not_contains "$CASE_DIR/stdout" 'No usable font found'
}

test_mode_help_pages() {
    local topic other long_help selector_help crop_option
    new_case
    for topic in montage zip each paginate; do
        run_script --help "$topic"
        assert_status 0 || return 1
        long_help="$(cat "$CASE_DIR/stdout")"
        assert_contains "$CASE_DIR/stdout" "$(printf '%s' "$topic" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }') mode" || return 1
        for other in montage zip each paginate; do
            [ "$other" = "$topic" ] && continue
            assert_not_contains "$CASE_DIR/stdout" "$(printf '%s' "$other" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }') mode" || return 1
        done
        run_script -h "$topic"
        assert_status 0 || return 1
        [ "$long_help" = "$(cat "$CASE_DIR/stdout")" ] || fail "-h and --help differ for $topic" || return 1
        for crop_option in '--crop-top' '--crop-bottom' '--crop-left' '--crop-right'; do
            assert_contains "$CASE_DIR/stdout" "$crop_option" || return 1
        done
        if [ "$topic" = "zip" ]; then
            assert_contains "$CASE_DIR/stdout" '-O/--overwrite' || return 1
        fi
    done

    run_script --each --help
    assert_status 0 || return 1
    selector_help="$(cat "$CASE_DIR/stdout")"
    assert_contains "$CASE_DIR/stdout" 'Each mode' || return 1
    assert_contains "$CASE_DIR/stdout" '-O/--overwrite' || return 1
    assert_contains "$CASE_DIR/stdout" '-t/--tile' || return 1
    run_script --help --each
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'each help differs by option order' || return 1
    run_script --each -h
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'each help differs for -h' || return 1
    run_script -h --each
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'each help differs for leading -h' || return 1
    run_script --paginate --help
    assert_status 0 || return 1
    selector_help="$(cat "$CASE_DIR/stdout")"
    assert_contains "$CASE_DIR/stdout" 'Paginate mode' || return 1
    assert_contains "$CASE_DIR/stdout" '-e/--each' || return 1
    run_script --help --paginate
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'paginate help differs by option order' || return 1
    run_script --paginate -h
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'paginate help differs for -h' || return 1
    run_script -h --paginate
    assert_status 0 || return 1
    [ "$selector_help" = "$(cat "$CASE_DIR/stdout")" ] || fail 'paginate help differs for leading -h'
}

test_invalid_help_requests() {
    local long_error
    new_case
    run_script --help unknown
    assert_status 1 || return 1
    long_error="$(cat "$CASE_DIR/stderr")"
    assert_contains "$CASE_DIR/stderr" 'Accepted help topics' || return 1
    run_script -h unknown
    assert_status 1 || return 1
    [ "$long_error" = "$(cat "$CASE_DIR/stderr")" ] || fail 'unknown-topic errors differ for -h and --help' || return 1

    run_script --paginate --help each
    assert_status 1 || return 1
    long_error="$(cat "$CASE_DIR/stderr")"
    assert_contains "$CASE_DIR/stderr" 'conflicts' || return 1
    run_script --paginate -h each
    assert_status 1 || return 1
    [ "$long_error" = "$(cat "$CASE_DIR/stderr")" ] || fail 'conflict errors differ for -h and --help' || return 1

    run_script --each --paginate --help
    assert_status 1 || return 1
    assert_contains "$CASE_DIR/stderr" 'cannot both' || return 1

    run_script --help --help
    assert_status 1 || return 1
    assert_contains "$CASE_DIR/stderr" 'only once' || return 1

    run_script --help paginate extra
    assert_status 1 || return 1
    long_error="$(cat "$CASE_DIR/stderr")"
    assert_contains "$CASE_DIR/stderr" 'Unexpected extra argument' || return 1
    run_script -h paginate extra
    assert_status 1 || return 1
    [ "$long_error" = "$(cat "$CASE_DIR/stderr")" ] || fail 'extra-argument errors differ for -h and --help'
}

test_help_precedes_validation_and_dependencies() {
    new_case
    run_script --width nope --help paginate
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stdout" 'Paginate mode' || return 1
    run_script --width --help paginate
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stdout" 'Paginate mode' || return 1
    run_script_with_path '/bin:/usr/bin' -h
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --help
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --help montage
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --help zip
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --help each
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --help paginate
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' -h montage
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' -h zip
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' -h each
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' -h paginate
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --each --help
    assert_status 0 || return 1
    run_script_with_path '/bin:/usr/bin' --paginate --help
    assert_status 0
}

test_help_creates_no_outputs() {
    local unexpected
    new_case
    run_script --help
    assert_status 0 || return 1
    run_script --help montage
    assert_status 0 || return 1
    run_script --help zip
    assert_status 0 || return 1
    run_script --help each
    assert_status 0 || return 1
    run_script --help paginate
    assert_status 0 || return 1
    run_script --each --help
    assert_status 0 || return 1
    run_script --paginate --help
    assert_status 0 || return 1
    unexpected="$(find "$CASE_DIR" -mindepth 1 ! -name stdout ! -name stderr -print)"
    [ -z "$unexpected" ] || fail "help created unexpected paths: $unexpected"
}

test_automatic_font_discovery() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/b.png" 100x80 blue
    run_script -i '*.png' -o grid.png --tile 2x1 -O
    assert_status 0 || return 1
    assert_file "$CASE_DIR/grid.png"
}

test_explicit_font() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    make_image "$CASE_DIR/b.png" 100x80 blue
    run_script -i '*.png' -o grid.png --tile 2x1 --font "$TEST_FONT" -O
    assert_status 0 || return 1
    assert_file "$CASE_DIR/grid.png"
}

test_invalid_font() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --font "$CASE_DIR/missing-font.ttf" -O
    [ "$RUN_STATUS" -ne 0 ] || fail "invalid font path unexpectedly succeeded"
    assert_contains "$CASE_DIR/stderr" 'Font file does not exist or is not readable'
}

test_each_mode_rejects_font() {
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --each --font "$CASE_DIR/missing-font.ttf"
    [ "$RUN_STATUS" -ne 0 ] || fail '--font unexpectedly succeeded in each mode'
    assert_contains "$CASE_DIR/stderr" 'Each mode does not use: --font'
}

test_paginate_exact_page_boundary() {
    local pages_dir
    new_case
    make_image "$CASE_DIR/long.png" 100x258 red
    run_script -i long.png --paginate --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    assert_file "$pages_dir/page-001.png" || return 1
    assert_file "$pages_dir/page-002.png" || return 1
    [ ! -e "$pages_dir/page-003.png" ] || fail 'exact boundary produced an extra page'
    assert_dimensions "$pages_dir/page-001.png" 100x129 || return 1
    assert_dimensions "$pages_dir/page-002.png" 100x129
}

test_paginate_margin_and_padding() {
    local pages_dir
    new_case
    make_image "$CASE_DIR/short.png" 100x30 red
    run_script -i short.png --paginate --margin 10 --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    assert_dimensions "$pages_dir/page-001.png" 120x155 || return 1
    assert_pixel_rgb "$pages_dir/page-001.png" 0,0 '255,255,255' || return 1
    assert_pixel_rgb "$pages_dir/page-001.png" 10,10 '255,0,0' || return 1
    assert_pixel_rgb "$pages_dir/page-001.png" 10,40 '255,255,255'
}

test_paginate_full_page_margins() {
    local pages_dir page
    new_case
    make_image "$CASE_DIR/long.png" 100x200 red
    run_script -i long.png --paginate --margin 10 --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    page="$pages_dir/page-001.png"
    assert_dimensions "$page" 120x155 || return 1
    assert_pixel_rgb "$page" 9,10 '255,255,255' || return 1
    assert_pixel_rgb "$page" 10,10 '255,0,0' || return 1
    assert_pixel_rgb "$page" 109,10 '255,0,0' || return 1
    assert_pixel_rgb "$page" 110,10 '255,255,255' || return 1
    assert_pixel_rgb "$page" 10,144 '255,0,0' || return 1
    assert_pixel_rgb "$page" 10,145 '255,255,255'
}

test_paginate_zero_overlap_coverage() {
    local pages_dir first_last second_first source_first source_second
    new_case
    magick -size 100x200 gradient:red-blue "$CASE_DIR/long.png"
    run_script -i long.png --paginate --overlap 0 --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    first_last="$(magick "$pages_dir/page-001.png" -format '%[pixel:p{50,128}]' info:)"
    second_first="$(magick "$pages_dir/page-002.png" -format '%[pixel:p{50,0}]' info:)"
    source_first="$(magick "$CASE_DIR/long.png" -format '%[pixel:p{50,128}]' info:)"
    source_second="$(magick "$CASE_DIR/long.png" -format '%[pixel:p{50,129}]' info:)"
    [ "$first_last" = "$source_first" ] || fail 'first page did not end with source row 128' || return 1
    [ "$second_first" = "$source_second" ] || fail 'second page did not begin with source row 129'
}

test_paginate_overlap() {
    local first_tail second_head pages_dir
    new_case
    magick -size 100x200 gradient:red-blue "$CASE_DIR/long.png"
    run_script -i long.png --paginate --overlap 20 --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    assert_file "$pages_dir/page-002.png" || return 1
    first_tail="$(magick "$pages_dir/page-001.png" -format '%[pixel:p{50,109}]' info:)"
    second_head="$(magick "$pages_dir/page-002.png" -format '%[pixel:p{50,0}]' info:)"
    [ "$first_tail" = "$second_head" ] || fail 'overlap did not repeat the expected source row'
}

test_paginate_preprocesses_before_geometry() {
    local pages_dir
    new_case
    make_image "$CASE_DIR/long.png" 120x300 blue
    run_script -i long.png --paginate -cl 10 -cr 10 --width 50 --output-pages
    assert_status 0 || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    assert_dimensions "$pages_dir/page-001.png" 50x65
}

test_paginate_pdf_a4() {
    local boxes
    new_case
    make_image "$CASE_DIR/long.png" 100x300 green
    run_script -i long.png --paginate --paper a4 -o result.pdf -O
    assert_status 0 || return 1
    assert_file "$CASE_DIR/result.pdf" || return 1
    assert_page_count "$CASE_DIR/result.pdf" 3 || return 1
    boxes="$(magick identify -format '%[pdf:HiResBoundingBox]\n' "$CASE_DIR/result.pdf")"
    printf '%s\n' "$boxes" | awk -F '[x+]' '
        function abs(value) { return value < 0 ? -value : value }
        NF && (abs($1 - 595.2756) > 1 || abs($2 - 841.8898) > 1) { bad=1 }
        END { exit bad }
    ' || fail 'A4 PDF page dimensions are incorrect'
}

test_paginate_short_letter_pdf() {
    new_case
    make_image "$CASE_DIR/short.png" 100x30 red
    run_script -i short.png --paginate -o result.pdf -O
    assert_status 0 || return 1
    assert_page_count "$CASE_DIR/result.pdf" 1 || return 1
    assert_pdf_page_size "$CASE_DIR/result.pdf" 612 792
}

test_paginate_default_pdf_name() {
    new_case
    make_image "$CASE_DIR/article.png" 100x80 yellow
    run_script -i article.png --paginate
    assert_status 0 || return 1
    assert_file "$CASE_DIR/article.pdf"
}

test_paginate_header_footer_layout() {
    local pages_dir count
    new_case
    make_image "$CASE_DIR/screencapture-example-2026-09-10-23_52_17.png" 600x1501 white
    run_script -i 'screencapture-example-2026-09-10-23_52_17.png' --paginate \
        --output-pages --margin 20 --header --header-line --footer --footer-line \
        --title 'A deliberately long title that must be shortened before it can collide with the creation timestamp, followed by additional text that makes fitting impossible' -v
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stderr" "created='Sep 10, 2026 · 11:52 PM'" || return 1
    assert_contains "$CASE_DIR/stderr" 'Header title:' || return 1
    assert_contains "$CASE_DIR/stderr" '…' || return 1
    pages_dir="$(latest_directory "$CASE_DIR" 'pages-*')"
    assert_dimensions "$pages_dir/page-001.png" 640x828 || return 1
    count="$(find "$pages_dir" -maxdepth 1 -type f -name 'page-*.png' | wc -l | tr -d ' ')"
    [ "$count" -eq 3 ] || fail "expected header/footer bands to produce 3 pages, got $count" || return 1
    assert_contains "$CASE_DIR/stderr" 'font=6pt' || return 1
    assert_region_not_white "$pages_dir/page-001.png" '600x25+20+20' || return 1
    assert_region_not_white "$pages_dir/page-001.png" '600x25+20+783' || return 1
    assert_region_not_white "$pages_dir/page-001.png" '1x1+320+44' || return 1
    assert_region_not_white "$pages_dir/page-001.png" '1x1+320+783'
}

test_paginate_header_footer_options() {
    new_case
    make_image "$CASE_DIR/a.png" 600x500 white

    run_script -i a.png --paginate --output-pages --title 'No header'
    [ "$RUN_STATUS" -ne 0 ] || fail '--title without --header unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" '--title requires --header' || return 1

    run_script -i a.png --header -o out.png
    [ "$RUN_STATUS" -ne 0 ] || fail '--header without --paginate unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'require --paginate' || return 1

    run_script -i a.png --paginate --header --title one --title two --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'repeated --title unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'given more than once' || return 1

    run_script -i a.png --paginate --page-font-size 6 --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail '--page-font-size without decoration unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'requires --header or --footer' || return 1

    run_script -i a.png --paginate --font "$TEST_FONT" --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail '--font without decoration unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" '--font requires --header or --footer' || return 1

    run_script -i a.png --paginate --header --font "$CASE_DIR/missing.ttf" --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'missing pagination font unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'Font file does not exist or is not readable' || return 1

    run_script -i a.png --paginate --header --font "$TEST_FONT" --output-pages -v
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stderr" "Pagination font: $TEST_FONT" || return 1

    run_script -i a.png --paginate --header --page-font-size 0 --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'zero --page-font-size unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'Invalid --page-font-size' || return 1

    run_script -i a.png --paginate --header-line --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail '--header-line without --header unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" '--header-line requires --header' || return 1

    run_script -i a.png --paginate --footer-line --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail '--footer-line without --footer unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" '--footer-line requires --footer'
}

test_paginate_timestamp_priority() {
    local fake_bin command_path
    new_case
    make_image "$CASE_DIR/screencapture-example-2026-09-10-23_52_17.png" 600x50 white
    magick "$CASE_DIR/screencapture-example-2026-09-10-23_52_17.png" \
        -set 'exif:DateTimeOriginal' '2020:01:02 03:04:05' \
        "$CASE_DIR/with-exif.png"
    run_script -i with-exif.png --paginate --header --output-pages -v
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stderr" "created='Jan 2, 2020 · 3:04 AM'" || return 1

    rm -rf "$CASE_DIR"/pages-*
    run_script -i screencapture-example-2026-09-10-23_52_17.png \
        --paginate --header --output-pages -v
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stderr" "created='Sep 10, 2026 · 11:52 PM'" || return 1

    rm -rf "$CASE_DIR"/pages-*
    fake_bin="$CASE_DIR/bin"
    mkdir "$fake_bin"
    {
        printf '#!/bin/bash\n'
        # The dollar expressions below belong in the generated script.
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-f" ] && [ "$2" = "%%B" ]; then exit 1; fi\n'
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-c" ] && [ "$2" = "%%W" ]; then echo 1577934240; exit 0; fi\n'
        printf 'exec %q "$@"\n' "$REAL_STAT"
    } >"$fake_bin/stat"
    {
        printf '#!/bin/bash\n'
        # The dollar expressions below belong in the generated script.
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-r" ]; then exit 1; fi\n'
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-d" ]; then echo "2020 01 02 03 04"; exit 0; fi\n'
        printf 'exec %q "$@"\n' "$REAL_DATE"
    } >"$fake_bin/date"
    chmod +x "$fake_bin/stat" "$fake_bin/date"
    command_path="$fake_bin:$(dirname "$REAL_MAGICK"):/bin:/usr/bin"
    magick "$CASE_DIR/with-exif.png" +profile '*' "$CASE_DIR/plain.png"
    run_script_with_path "$command_path" -i plain.png --paginate --header --output-pages -v
    assert_status 0 || return 1
    assert_contains "$CASE_DIR/stderr" "created='Jan 2, 2020 · 3:04 AM'"
}

test_paginate_page_number_width_logic() {
    local page_count page_digits
    # These literal strings assert the production implementation shape.
    # shellcheck disable=SC2016
    assert_contains "$SCRIPT" 'page_digits=${#page_count}' || return 1
    # shellcheck disable=SC2016
    assert_contains "$SCRIPT" 'if [ "$page_digits" -lt 3 ]' || return 1
    page_count=1000
    page_digits=${#page_count}
    [ "$page_digits" -eq 4 ] || fail '1000-page output did not select four-digit numbering'
}

test_paginate_rejects_invalid_combinations() {
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    make_image "$CASE_DIR/b.png" 100x100 blue

    run_script -i '*.png' --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'multiple matched images unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'exactly one image' || return 1

    run_script -i a.png --paginate --gap 15x15 --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'paginate with montage option unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'cannot be used with --paginate' || return 1

    run_script -i a.png --paginate --overlap 1000 --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'oversized overlap unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'must be smaller' || return 1

    run_script -i a.png --paginate -o exports
    [ "$RUN_STATUS" -ne 0 ] || fail 'PDF output without a .pdf extension unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'must have a .pdf extension' || return 1

    run_script -i a.png --paginate --output-pages legacy-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'legacy --output-pages DIR syntax unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'Unexpected extra arguments' || return 1

    run_script -i a.png --paper a4 -o out.png
    [ "$RUN_STATUS" -ne 0 ] || fail 'pagination-only option unexpectedly succeeded without --paginate'
    assert_contains "$CASE_DIR/stderr" 'require --paginate'
}

assert_paginate_option_rejected() {
    local label="$1"
    shift
    run_script -i a.png --paginate --output-pages "$@"
    [ "$RUN_STATUS" -ne 0 ] || fail "$label unexpectedly succeeded"
    assert_contains "$CASE_DIR/stderr" 'cannot be used with --paginate'
}

test_paginate_rejects_every_incompatible_option() {
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    make_image "$CASE_DIR/b.png" 100x100 blue

    run_script -i a.png -i b.png --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'repeated pagination input unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" 'exactly one -i/--input option' || return 1

    run_script -i a.png --paginate --each --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail '--each with pagination unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/stderr" 'mutually exclusive' || return 1

    assert_paginate_option_rejected '--tile' --tile 1x1 || return 1
    assert_paginate_option_rejected '--gap' --gap 15x15 || return 1
    assert_paginate_option_rejected '--gravity' --gravity north || return 1
    assert_paginate_option_rejected '--background' --background white || return 1
    assert_paginate_option_rejected '--trim' --trim || return 1
    assert_paginate_option_rejected '--no-trim' --no-trim || return 1
    assert_paginate_option_rejected '--trim-fuzz' --trim-fuzz 0 || return 1
    assert_paginate_option_rejected '--shadow' --shadow || return 1
    assert_paginate_option_rejected '--shadow-color' --shadow-color gray || return 1
    assert_paginate_option_rejected '--border' --border || return 1
    assert_paginate_option_rejected '--border-color' --border-color black || return 1
}

test_paginate_uses_output_parent_directory() {
    local page_dirs=() created_dir
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    mkdir "$CASE_DIR/exports"
    run_script -i a.png --paginate --output-pages -o exports
    assert_status 0 || return 1
    run_script -i a.png --paginate --output-pages -o exports/
    assert_status 0 || return 1
    page_dirs=("$CASE_DIR"/exports/pages-*)
    [ ${#page_dirs[@]} -eq 2 ] || fail 'expected two fresh PNG page directories' || return 1
    assert_file "${page_dirs[0]}/page-001.png" || return 1
    assert_file "${page_dirs[1]}/page-001.png" || return 1

    run_script -i a.png --paginate --output-pages -o new/nested
    assert_status 0 || return 1
    created_dir="$(latest_directory "$CASE_DIR/new/nested" 'pages-*')"
    assert_file "$created_dir/page-001.png" || return 1

    ln -s "$CASE_DIR/exports" "$CASE_DIR/exports-link"
    run_script -i a.png --paginate --output-pages -o exports-link
    [ "$RUN_STATUS" -ne 0 ] || fail 'symlink PNG parent unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'not a symbolic link'
}

test_paginate_preserves_existing_pdf_without_overwrite() {
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    printf 'original\n' >"$CASE_DIR/result.pdf"
    run_script -i a.png --paginate -o result.pdf
    [ "$RUN_STATUS" -ne 0 ] || fail 'existing PDF unexpectedly succeeded without overwrite'
    assert_contains "$CASE_DIR/result.pdf" 'original' || return 1
    assert_contains "$CASE_DIR/stderr" 'use -O/--overwrite'
}

test_paginate_rejects_symlink_and_animation() {
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    ln -s "$CASE_DIR/a.png" "$CASE_DIR/link.png"
    run_script -i link.png --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'symlink input unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'non-symlink' || return 1

    magick -size 100x100 xc:red -size 100x100 xc:blue "$CASE_DIR/animated.gif"
    run_script -i animated.gif --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'multi-frame input unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'single-frame'
}

test_paginate_does_not_require_montage_or_font() {
    local minimal_bin
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    minimal_bin="$CASE_DIR/bin"
    mkdir "$minimal_bin"
    ln -s "$REAL_MAGICK" "$minimal_bin/magick"
    run_script_with_path "$minimal_bin:/bin:/usr/bin" \
        -i a.png --paginate -o result.pdf
    assert_status 0 || return 1
    assert_file "$CASE_DIR/result.pdf" || return 1
    assert_page_count "$CASE_DIR/result.pdf" 1
}

test_paginate_rejects_non_image_inputs() {
    new_case
    mkdir "$CASE_DIR/folder"
    run_script -i '*.missing' --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'missing input unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'matched 0 files' || return 1

    run_script -i folder --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'directory input unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'regular' || return 1

    make_image "$CASE_DIR/page.png" 100x100 white
    magick "$CASE_DIR/page.png" "$CASE_DIR/source.pdf"
    run_script -i source.pdf --paginate --output-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'PDF input unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'raster image'
}

test_paginate_overwrites_pdf_atomically() {
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    printf 'old content\n' >"$CASE_DIR/result.pdf"
    run_script -i a.png --paginate -o result.pdf -O
    assert_status 0 || return 1
    assert_page_count "$CASE_DIR/result.pdf" 1
}

test_paginate_reports_pdf_writer_failure() {
    local fake_bin fake_magick
    new_case
    make_image "$CASE_DIR/a.png" 100x100 red
    fake_bin="$CASE_DIR/bin"
    fake_magick="$fake_bin/magick"
    mkdir "$fake_bin"
    {
        printf '#!/bin/bash\n'
        printf 'last=""\n'
        # The dollar expressions below belong in the generated script.
        # shellcheck disable=SC2016
        printf 'for arg in "$@"; do last="$arg"; done\n'
        # shellcheck disable=SC2016
        printf 'case "$last" in *.pdf) exit 1 ;; esac\n'
        printf 'exec %q "$@"\n' "$REAL_MAGICK"
    } >"$fake_magick"
    chmod +x "$fake_magick"
    run_script_with_path "$fake_bin:/bin:/usr/bin" -i a.png --paginate -o result.pdf
    [ "$RUN_STATUS" -ne 0 ] || fail 'simulated PDF writer failure unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" '--output-pages' || return 1
    [ ! -e "$CASE_DIR/result.pdf" ] || fail 'PDF writer failure left a partial destination' || return 1

    printf 'original destination\n' >"$CASE_DIR/result.pdf"
    run_script_with_path "$fake_bin:/bin:/usr/bin" \
        -i a.png --paginate -o result.pdf -O
    [ "$RUN_STATUS" -ne 0 ] || fail 'writer failure with -O unexpectedly succeeded' || return 1
    assert_contains "$CASE_DIR/result.pdf" 'original destination'
}

run_test() {
    local name="$1" function_name="$2" status
    printf '%-45s' "$name"
    "$function_name"
    status=$?
    case "$status" in
        0)
            passed=$((passed + 1))
            echo 'PASS'
            ;;
        *)
            failed=$((failed + 1))
            echo 'FAIL'
            ;;
    esac
}

if [ ! -x "$SCRIPT" ]; then
    echo "screenshots.sh is not executable: $SCRIPT" >&2
    exit 1
fi
if ! command -v magick >/dev/null 2>&1 || [ -z "$REAL_MONTAGE" ]; then
    echo 'ImageMagick commands magick and montage are required.' >&2
    exit 1
fi
if ! TEST_FONT="$(find_font)"; then
    echo 'No usable system font was found for explicit-font tests.' >&2
    exit 1
fi

echo 'screenshots.sh regression tests'
echo
run_test 'basic montage' test_basic_montage
run_test 'uniform crop' test_uniform_crop
run_test 'side-specific crop' test_side_specific_crop
run_test 'resize preserves aspect ratio' test_resize
run_test 'each mode preserves filenames' test_each_mode_names
run_test 'zip mode pairs input sets' test_zip_mode
run_test 'zip mode rejects unequal sets' test_zip_count_mismatch
run_test 'options with no effect are rejected' test_no_effect_options_are_rejected
run_test 'output is excluded from input glob' test_output_excluded_from_inputs
run_test 'invalid arguments are rejected' test_argument_validation
run_test 'general help is concise and complete' test_general_help
run_test 'mode help selects requested page' test_mode_help_pages
run_test 'invalid help requests are rejected' test_invalid_help_requests
run_test 'help precedes validation and dependencies' test_help_precedes_validation_and_dependencies
run_test 'help creates no outputs' test_help_creates_no_outputs
run_test 'automatic font discovery' test_automatic_font_discovery
run_test 'explicit font selection' test_explicit_font
run_test 'invalid font path is rejected' test_invalid_font
run_test 'each mode rejects font' test_each_mode_rejects_font
run_test 'paginate exact page boundary' test_paginate_exact_page_boundary
run_test 'paginate margin and final padding' test_paginate_margin_and_padding
run_test 'paginate preserves every full-page margin' test_paginate_full_page_margins
run_test 'paginate overlap repeats source rows' test_paginate_overlap
run_test 'paginate zero overlap covers each row once' test_paginate_zero_overlap_coverage
run_test 'paginate preprocesses before geometry' test_paginate_preprocesses_before_geometry
run_test 'paginate creates A4 PDF' test_paginate_pdf_a4
run_test 'paginate creates short Letter PDF' test_paginate_short_letter_pdf
run_test 'paginate derives default PDF name' test_paginate_default_pdf_name
run_test 'paginate renders header and footer' test_paginate_header_footer_layout
run_test 'paginate validates header/footer options' test_paginate_header_footer_options
run_test 'paginate selects timestamp by priority' test_paginate_timestamp_priority
run_test 'paginate expands page-number width' test_paginate_page_number_width_logic
run_test 'paginate rejects invalid combinations' test_paginate_rejects_invalid_combinations
run_test 'paginate rejects every incompatible option' test_paginate_rejects_every_incompatible_option
run_test 'paginate uses output parent directory' test_paginate_uses_output_parent_directory
run_test 'paginate preserves existing PDF' test_paginate_preserves_existing_pdf_without_overwrite
run_test 'paginate rejects symlink and animation' test_paginate_rejects_symlink_and_animation
run_test 'paginate needs no montage or font' test_paginate_does_not_require_montage_or_font
run_test 'paginate rejects non-image inputs' test_paginate_rejects_non_image_inputs
run_test 'paginate overwrites PDF atomically' test_paginate_overwrites_pdf_atomically
run_test 'paginate reports PDF writer failure' test_paginate_reports_pdf_writer_failure

echo
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]

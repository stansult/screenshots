#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$SCRIPT_DIR/screenshots.sh"
WORK_DIR="$(mktemp -d /tmp/screenshots-tests.XXXXXX)"
REAL_MONTAGE="$(command -v montage || true)"
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

assert_dimensions() {
    local file="$1" expected="$2" actual
    actual="$(magick identify -format '%wx%h' "${file}[0]")"
    [ "$actual" = "$expected" ] || fail "expected $file to be $expected, got $actual"
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

test_each_mode_does_not_require_font() {
    local out_dir
    new_case
    make_image "$CASE_DIR/a.png" 100x80 red
    run_script -i '*.png' --each --font "$CASE_DIR/missing-font.ttf"
    assert_status 0 || return 1
    out_dir="$(latest_directory "$CASE_DIR" 'each-*')"
    assert_file "$out_dir/a.png"
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
run_test 'output is excluded from input glob' test_output_excluded_from_inputs
run_test 'invalid arguments are rejected' test_argument_validation
run_test 'automatic font discovery' test_automatic_font_discovery
run_test 'explicit font selection' test_explicit_font
run_test 'invalid font path is rejected' test_invalid_font
run_test 'each mode does not require a font' test_each_mode_does_not_require_font

echo
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]

#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$SCRIPT_DIR/screenshots.sh"
WORK_DIR="$(mktemp -d /tmp/screenshots-tests.XXXXXX)"
REAL_MONTAGE="$(command -v montage || true)"
REAL_MAGICK="$(command -v magick || true)"
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

assert_page_count() {
    local file="$1" expected="$2" actual
    actual="$(magick identify -format '%p\n' "$file" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$actual" -eq "$expected" ] || fail "expected $file to have $expected pages, got $actual"
}

assert_pixel_rgb() {
    local file="$1" coordinate="$2" expected="$3" actual
    actual="$(magick "$file" -format "%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]" info:)"
    if [ "$coordinate" != "0,0" ]; then
        actual="$(magick "$file" -format "%[fx:int(255*u.p{$coordinate}.r)],%[fx:int(255*u.p{$coordinate}.g)],%[fx:int(255*u.p{$coordinate}.b)]" info:)"
    fi
    [ "$actual" = "$expected" ] || fail "expected $file pixel $coordinate to be $expected, got $actual"
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

test_paginate_default_pdf_name() {
    new_case
    make_image "$CASE_DIR/article.png" 100x80 yellow
    run_script -i article.png --paginate
    assert_status 0 || return 1
    assert_file "$CASE_DIR/article.pdf"
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

    run_script -i a.png --paginate --output-pages -o missing-parent
    [ "$RUN_STATUS" -ne 0 ] || fail 'missing PNG parent directory unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'existing writable directory' || return 1

    run_script -i a.png --paginate --output-pages legacy-pages
    [ "$RUN_STATUS" -ne 0 ] || fail 'legacy --output-pages DIR syntax unexpectedly succeeded'
    assert_contains "$CASE_DIR/stderr" 'Unexpected extra arguments' || return 1

    run_script -i a.png --paper a4 -o out.png
    [ "$RUN_STATUS" -ne 0 ] || fail 'pagination-only option unexpectedly succeeded without --paginate'
    assert_contains "$CASE_DIR/stderr" 'require --paginate'
}

test_paginate_uses_output_parent_directory() {
    local page_dirs=()
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
    assert_file "${page_dirs[1]}/page-001.png"
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
    [ ! -e "$CASE_DIR/result.pdf" ] || fail 'PDF writer failure left a partial destination'
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
run_test 'paginate exact page boundary' test_paginate_exact_page_boundary
run_test 'paginate margin and final padding' test_paginate_margin_and_padding
run_test 'paginate overlap repeats source rows' test_paginate_overlap
run_test 'paginate preprocesses before geometry' test_paginate_preprocesses_before_geometry
run_test 'paginate creates A4 PDF' test_paginate_pdf_a4
run_test 'paginate derives default PDF name' test_paginate_default_pdf_name
run_test 'paginate rejects invalid combinations' test_paginate_rejects_invalid_combinations
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

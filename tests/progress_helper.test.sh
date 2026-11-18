#!/bin/bash

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TEST_TMP="$(mktemp -d /tmp/screenshots-progress-tests.XXXXXX)"
progress_test_updater_pid=""
cleanup() {
    if [ -n "$progress_test_updater_pid" ]; then
        kill "$progress_test_updater_pid" 2>/dev/null || true
        wait "$progress_test_updater_pid" 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# shellcheck disable=SC1091
source "$TEST_DIR/../progress.sh"

fail() {
    echo "progress helper test: $*" >&2
    exit 1
}

[ -z "$(progress_elapsed_label 0 4999999999)" ] || \
    fail 'elapsed seconds appeared before the 5-second threshold'
[ "$(progress_elapsed_label 0 5000000000)" = 'elapsed 5s' ] || \
    fail 'elapsed seconds did not appear at 5 seconds'
[ "$(progress_elapsed_label 0 5999999999)" = 'elapsed 5s' ] || \
    fail 'elapsed seconds do not use whole monotonic seconds'
[ -z "$(progress_duration_label 0 9999999999)" ] || \
    fail 'completion duration appeared before 10 seconds'
[ "$(progress_duration_label 0 10000000000)" = ' (took 10.0s)' ] || \
    fail 'completion duration did not appear at 10 seconds'

# `verbose` is read by progress helper functions from the caller's scope.
# shellcheck disable=SC2034
verbose=true
progress_test_messages=()
progress_test_dates=(23:59:58 00:00:08)

progress_now_ns() {
    if [ ! -e "$TEST_TMP/monotonic-used" ]; then
        : >"$TEST_TMP/monotonic-used"
        printf '0\n'
    else
        printf '10500000000\n'
    fi
}

date() {
    local index
    for index in 0 1; do
        if [ ! -e "$TEST_TMP/date-$index" ]; then
            : >"$TEST_TMP/date-$index"
            printf '%s\n' "${progress_test_dates[$index]}"
            return 0
        fi
    done
    return 1
}

operational_message_at() {
    progress_test_messages+=("[$2] $3")
}

progress_start 'clock test stage' || fail 'verbose stage start failed'
progress_finish || fail 'verbose stage completion failed'
[ "${progress_test_messages[0]}" = '[23:59:58] Stage started: clock test stage' ] || \
    fail 'verbose progress did not report the stage start timestamp'
[ "${progress_test_messages[1]}" = '[00:00:08] Stage complete: clock test stage (took 10.5s)' ] || \
    fail 'duration followed wall-clock changes instead of the monotonic clock'
# `progress_start_time` is assigned by progress_start in the sourced helper.
# shellcheck disable=SC2154
[ "$progress_start_time" = '23:59:58' ] || \
    fail 'stage start timestamp was not kept fixed'

progress_active=true
# `progress_live` is read by progress_abort in the sourced helper.
# shellcheck disable=SC2034
progress_live=true
sleep 30 &
progress_pid=$!
progress_test_updater_pid="$progress_pid"
progress_abort 2>"$TEST_TMP/abort.stderr"
if kill -0 "$progress_test_updater_pid" 2>/dev/null; then
    fail 'progress abort left its updater process running'
fi
progress_test_updater_pid=""
grep -Fq $'\033[' "$TEST_TMP/abort.stderr" || \
    fail 'progress abort did not clear the live terminal line'
[ "$progress_active" = false ] && [ -z "$progress_pid" ] || \
    fail 'progress abort did not reset helper state'

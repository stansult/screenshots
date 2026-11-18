# shellcheck shell=bash
# Shared live progress and monotonic timing helpers for screenshots.sh.
# Requires Perl with the core Time::HiRes module for CLOCK_MONOTONIC.

PROGRESS_ELAPSED_THRESHOLD_SECONDS=5
PROGRESS_DURATION_THRESHOLD_NS=10000000000

progress_active=false
progress_pid=""
progress_stage=""
progress_started_ns=0
progress_start_time=""
progress_live=false

progress_now_ns() {
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1_000_000_000'
}

progress_elapsed_tenths() {
    local start_ns="$1" end_ns="$2" duration_ns
    duration_ns=$((end_ns - start_ns))
    [ "$duration_ns" -ge 0 ] || duration_ns=0
    printf '%s\n' "$(((duration_ns + 50000000) / 100000000))"
}

progress_format_tenths() {
    local tenths="$1"
    printf '%s.%ss' "$((tenths / 10))" "$((tenths % 10))"
}

progress_elapsed_label() {
    local start_ns="$1" end_ns="$2" duration_ns elapsed_seconds
    duration_ns=$((end_ns - start_ns))
    [ "$duration_ns" -ge 0 ] || duration_ns=0
    if [ "$duration_ns" -ge "$((PROGRESS_ELAPSED_THRESHOLD_SECONDS * 1000000000))" ]; then
        elapsed_seconds=$((duration_ns / 1000000000))
        printf 'elapsed %ss' "$elapsed_seconds"
    fi
}

progress_duration_label() {
    local start_ns="$1" end_ns="$2" duration_ns elapsed_tenths
    duration_ns=$((end_ns - start_ns))
    [ "$duration_ns" -ge 0 ] || duration_ns=0
    if [ "$duration_ns" -ge "$PROGRESS_DURATION_THRESHOLD_NS" ]; then
        elapsed_tenths="$(progress_elapsed_tenths "$start_ns" "$end_ns")"
        printf ' (took %s)' "$(progress_format_tenths "$elapsed_tenths")"
    fi
}

progress_start() {
    local stage="$1" start_ns start_time
    progress_active=false

    # `verbose` is supplied by the calling script.
    # shellcheck disable=SC2154
    if $verbose; then
        progress_live=false
    elif [ -t 2 ] && [ "${TERM:-}" != "dumb" ]; then
        progress_live=true
    else
        return 0
    fi

    start_ns="$(progress_now_ns)" || {
        echo "Could not read the monotonic clock required for progress reporting." >&2
        return 1
    }
    start_time="$(date '+%H:%M:%S')" || start_time="??:??:??"
    progress_stage="$stage"
    progress_started_ns="$start_ns"
    # shellcheck disable=SC2034
    progress_start_time="$start_time"
    progress_active=true

    if $verbose; then
        operational_message_at stderr "$start_time" "Stage started: $stage"
    else
        printf '\r\033[K[%s] %s |' "$start_time" "$stage" >&2
        perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,sleep -e '
            my ($start_ns, $start_time, $stage, $threshold) = @ARGV;
            my @spinner = ("|", "/", "-", "\\");
            my $frame = 0;
            $SIG{TERM} = sub { exit 0 };
            $SIG{INT} = sub { exit 0 };
            while (1) {
                my $elapsed = clock_gettime(CLOCK_MONOTONIC) - ($start_ns / 1_000_000_000);
                my $message = "[$start_time] $stage $spinner[$frame % @spinner]";
                if ($elapsed >= $threshold) {
                    $message .= " elapsed " . int($elapsed) . "s";
                }
                print STDERR "\r\033[K$message";
                $frame++;
                sleep(0.15);
            }
        ' "$start_ns" "$start_time" "$stage" "$PROGRESS_ELAPSED_THRESHOLD_SECONDS" >&2 &
        progress_pid=$!
    fi
}

progress_stop_updater() {
    if [ -n "$progress_pid" ]; then
        kill "$progress_pid" 2>/dev/null || true
        wait "$progress_pid" 2>/dev/null || true
        progress_pid=""
    fi
}

progress_finish() {
    local end_ns end_time duration message
    $progress_active || return 0

    end_ns="$(progress_now_ns)" || end_ns="$progress_started_ns"
    end_time="$(date '+%H:%M:%S')" || end_time="??:??:??"
    duration="$(progress_duration_label "$progress_started_ns" "$end_ns")"

    progress_stop_updater
    if $progress_live; then
        printf '\r\033[K[%s] %s complete%s\n' \
            "$end_time" "$progress_stage" "$duration" >&2
    else
        message="Stage complete: $progress_stage$duration"
        operational_message_at stderr "$end_time" "$message"
    fi
    progress_active=false
    progress_live=false
}

progress_abort() {
    $progress_active || return 0
    progress_stop_updater
    if $progress_live; then
        printf '\r\033[K\n' >&2
    fi
    progress_active=false
    progress_live=false
}

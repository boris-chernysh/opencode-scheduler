#!/bin/bash
# Tests for parsecron / cron_next / cron_next_interval
# Uses mock date() to control time — no external deps.

set -euo pipefail

PASS=0
FAIL=0
TESTS=()

# ── Mock date ──────────────────────────────────────────────────
# Set these before calling functions:
#   _TS_HOUR, _TS_MIN, _TS_SEC — for date +%H/+%M/+%S
#   _TS_EPOCH — for date +%s (only used in cron_next/cron_next_interval for logging, not logic)

_TS_EPOCH=0
_TS_HOUR=0
_TS_MIN=0
_TS_SEC=0

date() {
    case "${1:-}" in
        +%s)  echo "$_TS_EPOCH" ;;
        +%H)  printf "%02d" "$_TS_HOUR" ;;
        +%M)  printf "%02d" "$_TS_MIN" ;;
        +%S)  printf "%02d" "$_TS_SEC" ;;
        *)    command date "$@" ;;
    esac
}
export -f date

# ── Functions under test (copied from daemon, minus unused deps) ──

cron_next() {
    local minute=$1 hour=$2
    local now_epoch=$(date +%s)  # unused in logic, but called
    local now_hour=$(date +%H | sed 's/^0//')
    local now_min=$(date +%M | sed 's/^0//')
    local now_total=$((10#$now_hour * 60 + 10#$now_min))

    if [ "$minute" = "*" ]; then minute=0; fi

    local candidates=()
    local target_h
    for target_h in $(echo "$hour" | tr ',' ' '); do
        for target_m in $(echo "$minute" | tr ',' ' '); do
            local t=$((10#$target_h * 60 + 10#$target_m))
            if [ $t -ge $now_total ]; then
                candidates+=($t)
            fi
        done
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        local first=$(( (10#$(echo "$hour" | cut -d, -f1)) * 60 + (10#$(echo "$minute" | cut -d, -f1)) ))
        echo $(( (1440 - now_total + first) * 60 ))
    else
        local min_t=${candidates[0]}
        for c in "${candidates[@]}"; do
            [ $c -lt $min_t ] && min_t=$c
        done
        echo $(( (min_t - now_total) * 60 ))
    fi
}

cron_next_interval() {
    local interval_hours=$1
    local now_epoch=$(date +%s)  # unused in logic
    local now_hour=$(date +%H | sed 's/^0//')
    echo $(( interval_hours * 3600 - (now_hour % interval_hours) * 3600 - $(date +%M | sed 's/^0//') * 60 - $(date +%S | sed 's/^0//') ))
}

parsecron() {
    local cron_expr=$1
    local minute=$(echo "$cron_expr" | awk '{print $1}')
    local hour=$(echo "$cron_expr" | awk '{print $2}')
    local dom=$(echo "$cron_expr" | awk '{print $3}')

    if [[ "$hour" =~ ^\*/([0-9]+)$ ]]; then
        local interval=${BASH_REMATCH[1]}
        cron_next_interval "$interval"
        return
    fi

    if [ "$minute" = "*" ] && [ "$dom" = "*" ]; then
        cron_next "0" "$hour"
    elif [ "$dom" = "*" ]; then
        cron_next "$minute" "$hour"
    else
        cron_next "$minute" "$hour"
    fi
}

# ── Test helpers ───────────────────────────────────────────────

set_time() { _TS_HOUR=$1 _TS_MIN=$2 _TS_SEC=${3:-0}; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        TESTS+=("PASS: $name")
        PASS=$((PASS + 1))
    else
        TESTS+=("FAIL: $name — expected $expected, got $actual")
        FAIL=$((FAIL + 1))
    fi
}

# ── cron_next tests ────────────────────────────────────────────

# Exact match at scheduled time (the -ge fix)
set_time 7 30
assert_eq "07:30 exact match for 7:30" \
    0 "$(cron_next 30 7)"

# 1 minute before
set_time 7 29
assert_eq "07:29 — 1 min before 7:30" \
    60 "$(cron_next 30 7)"

# 1 minute after → next day
set_time 7 31
assert_eq "07:31 — 1 min after 7:30, next day" \
    86340 "$(cron_next 30 7)"

# Midnight exact match
set_time 0 0
assert_eq "00:00 exact match for midnight" \
    0 "$(cron_next 0 0)"

# 1 minute after midnight → next midnight
set_time 0 1
assert_eq "00:01 — 1 min after midnight" \
    86340 "$(cron_next 0 0)"

# 23:59 → 60 seconds to midnight
set_time 23 59
assert_eq "23:59 → midnight in 60s" \
    60 "$(cron_next 0 0)"

# Multi-hour: 8,20 at 08:00 exact
set_time 8 0
assert_eq "08:00 exact for 8,20" \
    0 "$(cron_next 0 "8,20")"

# Multi-hour: 8,20 at 09:00 → next is 20:00 (11h)
set_time 9 0
assert_eq "09:00 → next 20:00 (11h)" \
    39600 "$(cron_next 0 "8,20")"

# Multi-hour: 8,20 at 21:00 → next is 08:00 tomorrow (11h)
set_time 21 0
assert_eq "21:00 → next 08:00 tomorrow (11h)" \
    39600 "$(cron_next 0 "8,20")"

# Multi-hour with minutes: 30 7,19 at 19:30 exact
set_time 19 30
assert_eq "19:30 exact for '30 7,19'" \
    0 "$(cron_next 30 "7,19")"

# Multi-hour with minutes: 30 7,19 at 20:00 → next 07:30 tomorrow
set_time 20 0
assert_eq "20:00 → next 07:30 tomorrow (11.5h)" \
    41400 "$(cron_next 30 "7,19")"

# ── cron_next_interval tests ───────────────────────────────────

# Every 4h at 00:00:00 → next at 04:00 (14400s)
set_time 0 0 0
assert_eq "4h interval at 00:00:00" \
    14400 "$(cron_next_interval 4)"

# Every 4h at 00:00:01 → still ~14400 (minus 1s)
set_time 0 0 1
assert_eq "4h interval at 00:00:01" \
    14399 "$(cron_next_interval 4)"

# Every 4h at 03:59 → next at 04:00 (60s)
set_time 3 59
assert_eq "4h interval at 03:59" \
    60 "$(cron_next_interval 4)"

# Every 4h at 04:00 exact → next at 08:00
set_time 4 0 0
assert_eq "4h interval at 04:00:00" \
    14400 "$(cron_next_interval 4)"

# Every 4h at 04:00:30 → 14370 (still 08:00)
set_time 4 0 30
assert_eq "4h interval at 04:00:30" \
    14370 "$(cron_next_interval 4)"

# Every 4h at 23:59 → next at 00:00 (60s)
set_time 23 59
assert_eq "4h interval at 23:59" \
    60 "$(cron_next_interval 4)"

# Every 6h at 00:00
set_time 0 0 0
assert_eq "6h interval at 00:00" \
    21600 "$(cron_next_interval 6)"

# Every 6h at 05:59 → next at 06:00
set_time 5 59
assert_eq "6h interval at 05:59" \
    60 "$(cron_next_interval 6)"

# Every 6h at 11:30 → next at 12:00 (30 min = 1800s)
set_time 11 30
assert_eq "6h interval at 11:30" \
    1800 "$(cron_next_interval 6)"

# ── parsecron tests (integration) ──────────────────────────────

# Fixed time via parsecron
set_time 7 30
assert_eq "parsecron '30 7 * * *' at 07:30" \
    0 "$(parsecron "30 7 * * *")"

# Interval via parsecron
set_time 0 0 0
assert_eq "parsecron '0 */4 * * *' at 00:00" \
    14400 "$(parsecron "0 */4 * * *")"

# Interval via parsecron at 03:59
set_time 3 59
assert_eq "parsecron '0 */4 * * *' at 03:59" \
    60 "$(parsecron "0 */4 * * *")"

# Multi-hour via parsecron
set_time 8 0
assert_eq "parsecron '0 8,20 * * *' at 08:00" \
    0 "$(parsecron "0 8,20 * * *")"

set_time 9 0
assert_eq "parsecron '0 8,20 * * *' at 09:00" \
    39600 "$(parsecron "0 8,20 * * *")"

# Midnight via parsecron
set_time 23 59
assert_eq "parsecron '0 0 * * *' at 23:59" \
    60 "$(parsecron "0 0 * * *")"

set_time 0 0
assert_eq "parsecron '0 0 * * *' at 00:00 exact" \
    0 "$(parsecron "0 0 * * *")"

# With day-of-month field filled but = * (should still work)
set_time 0 0
assert_eq "parsecron '0 0 * * *' midnight exact" \
    0 "$(parsecron "0 0 * * *")"

# ── Edge cases ─────────────────────────────────────────────────

# Hour-only cron (minute=*): treated as minute=0
set_time 8 0
assert_eq "hour-only '0 8 * * *' at 08:00" \
    0 "$(parsecron "0 8 * * *")"

set_time 8 1
assert_eq "hour-only '0 8 * * *' at 08:01" \
    86340 "$(parsecron "0 8 * * *")"

# ── Report ─────────────────────────────────────────────────────

echo "========================================"
echo "  Test Results"
echo "========================================"
for t in "${TESTS[@]}"; do echo "$t"; done
echo "========================================"
echo "  PASS: $PASS  FAIL: $FAIL  TOTAL: $((PASS + FAIL))"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1

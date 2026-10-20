#!/usr/bin/env bash
#
# load-test.sh — quick HTTP load test wrapper.
#
# Uses `wrk` when available, falls back to ApacheBench (`ab`).
# Validates the target with curl first (fail fast), runs the test,
# then prints a clean summary table. With --compare, two URLs are
# tested back-to-back and shown side-by-side.
#
#   ./load-test.sh --url https://example.com/
#   ./load-test.sh --url https://example.com/ --duration 30s --concurrency 100
#   ./load-test.sh --url https://a.example.com/ --compare https://b.example.com/ --output report.md
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
URL=""
COMPARE_URL=""
DURATION="15s"
CONCURRENCY="50"
THREADS="2"
OUTPUT=""
HEADERS=()

usage() {
    cat <<'EOF'
Usage: load-test.sh --url URL [options]

Options:
  --url URL            Target to test (required)
  --compare URL2       Second target: run both back-to-back, side-by-side table
  --duration 15s       Test duration per target (e.g. 15s, 1m)
  --concurrency 50     Concurrent connections
  --threads 2          Threads (wrk only)
  --header "Name: v"   Extra request header (repeatable)
  --output FILE       Save a Markdown report to FILE
  -h, --help           Show this help

Examples:
  ./load-test.sh --url https://example.com/
  ./load-test.sh --url https://example.com/api --duration 1m --concurrency 100 \
      --header "Authorization: Bearer TOKEN" --output report.md
  ./load-test.sh --url https://staging.example.com/ --compare https://example.com/
EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --url)         URL="${2:?--url needs a value}"; shift 2 ;;
        --compare)     COMPARE_URL="${2:?--compare needs a value}"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --threads)     THREADS="$2"; shift 2 ;;
        --header)      HEADERS+=("$2"); shift 2 ;;
        --output)      OUTPUT="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -n "$URL" ] || { echo "Error: --url is required." >&2; usage 1; }
case "$CONCURRENCY$THREADS" in
    *[!0-9]*) echo "Error: --concurrency and --threads must be integers." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Pre-flight: target(s) must answer before we burn time testing
# ---------------------------------------------------------------------------
check_reachable() {
    local url="$1" code="000"
    # The `if !` guard keeps `set -e` from aborting on curl failure.
    if ! code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)"; then
        code="000"
    fi
    case "$code" in
        2*|3*) return 0 ;;  # 2xx/3xx = reachable (redirects count)
        *)
            echo "Error: target unreachable: $url (HTTP ${code})." >&2
            return 1
            ;;
    esac
}

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
check_reachable "$URL" || exit 1
if [ -n "$COMPARE_URL" ]; then
    check_reachable "$COMPARE_URL" || exit 1
fi

# ---------------------------------------------------------------------------
# Pick the engine: wrk preferred, ab fallback
# ---------------------------------------------------------------------------
if command -v wrk >/dev/null 2>&1; then
    TOOL="wrk"
elif command -v ab >/dev/null 2>&1; then
    TOOL="ab"
else
    echo "Error: need 'wrk' or 'ab' installed (see README)." >&2
    exit 1
fi

# Convert 15s / 1m / 90 into plain seconds for ab's -t flag.
duration_seconds() {
    case "$DURATION" in
        *s) echo "${DURATION%s}" ;;
        *m) echo "$(( ${DURATION%m} * 60 ))" ;;
        *)  echo "$DURATION" ;;
    esac
}

LT_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$LT_TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Runners — each writes raw tool output to $2 and fills the RPS/LAT_* globals
# ---------------------------------------------------------------------------
RPS=""; LAT_AVG=""; LAT_STDEV=""; P50=""; P99=""

run_wrk() {
    local url="$1" out="$2"
    local args=(--latency "-t$THREADS" "-c$CONCURRENCY" "-d$DURATION")
    if [ "${#HEADERS[@]}" -gt 0 ]; then
        local h
        for h in "${HEADERS[@]}"; do args+=(-H "$h"); done
    fi
    if ! wrk "${args[@]}" "$url" >"$out" 2>&1; then
        echo "Warning: wrk reported an error for $url (raw output kept)." >&2
    fi
}

parse_wrk() {
    local file="$1"
    RPS="$(awk '/^Requests\/sec:/ {print $2}' "$file")"
    # "    Latency     1.12ms    3.45ms  123.45ms   96.54%" — NF==5 avoids the
    # "Latency Distribution" heading (NF==2).
    LAT_AVG="$(awk '$1=="Latency" && NF==5 {print $2}' "$file")"
    LAT_STDEV="$(awk '$1=="Latency" && NF==5 {print $3}' "$file")"
    P50="$(awk '$1=="50%" {print $2}' "$file")"
    P99="$(awk '$1=="99%" {print $2}' "$file")"
}

run_ab() {
    local url="$1" out="$2"
    local secs; secs="$(duration_seconds)"
    local args=(-t "$secs" -c "$CONCURRENCY")
    if [ "${#HEADERS[@]}" -gt 0 ]; then
        local h
        for h in "${HEADERS[@]}"; do args+=(-H "$h"); done
    fi
    # ab -t caps the run at ~$secs seconds.
    if ! ab "${args[@]}" "$url" >"$out" 2>&1; then
        echo "Warning: ab reported an error for $url (raw output kept)." >&2
    fi
}

parse_ab() {
    local file="$1"
    RPS="$(awk '/^Requests per second:/ {print $4}' "$file")"
    # First "Time per request" line is the mean; the second is per-connection.
    LAT_AVG="$(awk '/^Time per request:/ {print $3"ms"; exit}' "$file")"
    LAT_STDEV=""  # ab does not report a single stdev figure
    P50="$(awk '$1=="50%" {print $2"ms"; exit}' "$file")"
    P99="$(awk '$1=="99%" {print $2"ms"; exit}' "$file")"
}

# Run one target end-to-end: engine -> parse -> copy globals into A_/B_ vars.
run_target() {
    local url="$1" prefix="$2" out="$LT_TMPDIR/raw-${prefix}.txt"
    echo "Testing $url ($TOOL, ${DURATION}, c=${CONCURRENCY})…"
    if [ "$TOOL" = "wrk" ]; then
        run_wrk "$url" "$out"; parse_wrk "$out"
    else
        run_ab "$url" "$out"; parse_ab "$out"
    fi
    # Copy into prefixed vars via eval (keeps the table code simple).
    eval "${prefix}_RPS=\"\$RPS\" ${prefix}_LAT_AVG=\"\$LAT_AVG\" ${prefix}_LAT_STDEV=\"\$LAT_STDEV\" ${prefix}_P50=\"\$P50\" ${prefix}_P99=\"\$P99\""
}

val() {  # print metric or n/a
    if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf 'n/a'; fi
}

print_table_single() {
    # args: label rps lat_avg lat_stdev p50 p99
    local label="$1"; shift
    printf '\nTarget:      %s\nTool:        %s\nDuration:    %s   Concurrency: %s\n\n' \
        "$label" "$TOOL" "$DURATION" "$CONCURRENCY"
    printf '%-16s %s\n' "Metric" "Value"
    printf '%-16s %s\n' "----------------" "--------"
    printf '%-16s %s\n' "Requests/sec"  "$(val "$1")"
    printf '%-16s %s\n' "Latency avg"   "$(val "$2")"
    printf '%-16s %s\n' "Latency stdev" "$(val "$3")"
    printf '%-16s %s\n' "p50"           "$(val "$4")"
    printf '%-16s %s\n' "p99"           "$(val "$5")"
    printf '\n'
}

print_table_compare() {
    # args: a_rps a_avg a_stdev a_p50 a_p99 b_rps b_avg b_stdev b_p50 b_p99
    printf '\nTool:      %s\nDuration:  %s   Concurrency: %s\n\n' "$TOOL" "$DURATION" "$CONCURRENCY"
    printf '%-16s %-26s %-26s\n' "Metric" "A: $URL" "B: $COMPARE_URL"
    printf '%-16s %-26s %-26s\n' "----------------" "--------------------------" "--------------------------"
    printf '%-16s %-26s %-26s\n' "Requests/sec"  "$(val "$1")"  "$(val "$6")"
    printf '%-16s %-26s %-26s\n' "Latency avg"   "$(val "$2")"  "$(val "$7")"
    printf '%-16s %-26s %-26s\n' "Latency stdev" "$(val "$3")" "$(val "$8")"
    printf '%-16s %-26s %-26s\n' "p50"           "$(val "$4")"  "$(val "$9")"
    printf '%-16s %-26s %-26s\n' "p99"           "$(val "$5")"  "$(val "${10}")"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
run_target "$URL" "A"

if [ -n "$COMPARE_URL" ]; then
    run_target "$COMPARE_URL" "B"
    print_table_compare "$A_RPS" "$A_LAT_AVG" "$A_LAT_STDEV" "$A_P50" "$A_P99" \
                        "$B_RPS" "$B_LAT_AVG" "$B_LAT_STDEV" "$B_P50" "$B_P99"
else
    print_table_single "$URL" "$A_RPS" "$A_LAT_AVG" "$A_LAT_STDEV" "$A_P50" "$A_P99"
fi

# ---------------------------------------------------------------------------
# Optional Markdown report
# ---------------------------------------------------------------------------
if [ -n "$OUTPUT" ]; then
    {
        echo "# Load test report"
        echo
        echo "- Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- Tool: $TOOL"
        echo "- Duration: $DURATION, concurrency: $CONCURRENCY, threads: $THREADS"
        echo
        echo "## $URL"
        echo
        echo "| Metric | Value |"
        echo "|---|---|"
        echo "| Requests/sec | $(val "$A_RPS") |"
        echo "| Latency avg | $(val "$A_LAT_AVG") |"
        echo "| Latency stdev | $(val "$A_LAT_STDEV") |"
        echo "| p50 | $(val "$A_P50") |"
        echo "| p99 | $(val "$A_P99") |"
        if [ -n "$COMPARE_URL" ]; then
            echo
            echo "## $COMPARE_URL"
            echo
            echo "| Metric | Value |"
            echo "|---|---|"
            echo "| Requests/sec | $(val "$B_RPS") |"
            echo "| Latency avg | $(val "$B_LAT_AVG") |"
            echo "| Latency stdev | $(val "$B_LAT_STDEV") |"
            echo "| p50 | $(val "$B_P50") |"
            echo "| p99 | $(val "$B_P99") |"
        fi
    } > "$OUTPUT"
    echo "Report saved to $OUTPUT"
fi

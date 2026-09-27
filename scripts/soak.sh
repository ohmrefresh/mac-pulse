#!/usr/bin/env bash
# Idle soak test for the PRD §18 overhead budgets. Run at the M1 gate and before each release.
#   scripts/soak.sh            # 1 hour
#   DURATION=300 scripts/soak.sh
# Measures the app's own CPU time (not the short-lived /bin/ps children, which add roughly 0.2%)
# and resident memory. Network is not measured: probes use short-lived ICMP sockets that nettop
# cannot attribute, so the budget is checked analytically below.
# Keep the machine otherwise idle: concurrent builds or tests can push the app onto efficiency
# cores and inflate its CPU time.
set -euo pipefail

DURATION="${DURATION:-3600}"
WARMUP="${WARMUP:-15}"
INTERVAL=10
CPU_BUDGET_PERCENT=1.0
RSS_BUDGET_MB=150

cd "$(dirname "$0")/.."
APP=".build/xcode/Build/Products/Release/MacPulse.app"

xcodegen generate >/dev/null
xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath .build/xcode build >/dev/null

pkill -x MacPulse 2>/dev/null || true
open "$APP"
sleep "$WARMUP"
PID="$(pgrep -x MacPulse)"
trap 'kill "$PID" 2>/dev/null || true' EXIT

cpu_seconds() { ps -o time= -p "$PID" | awk -F'[:.]' '{ print $1 * 60 + $2 + $3 / 100 }'; }

start_cpu="$(cpu_seconds)"
window_cpu="$start_cpu"
WINDOW=600
peak_rss_kb=0
elapsed=0
while (( elapsed < DURATION )); do
  sleep "$INTERVAL"
  elapsed=$(( elapsed + INTERVAL ))
  kill -0 "$PID" 2>/dev/null || { echo "FAIL: MacPulse exited during soak"; exit 1; }
  rss_kb="$(ps -o rss= -p "$PID" | tr -d ' ')"
  (( rss_kb > peak_rss_kb )) && peak_rss_kb="$rss_kb"
  # Per-window CPU exposes drift (a growing cost) that a single average hides.
  if (( elapsed % WINDOW == 0 )); then
    now_cpu="$(cpu_seconds)"
    awk -v a="$window_cpu" -v b="$now_cpu" -v w="$WINDOW" -v e="$elapsed" -v r="$rss_kb" \
      'BEGIN { printf "window %5ds  CPU %.2f%%  RSS %.1f MB\n", e, (b - a) / w * 100, r / 1024 }'
    window_cpu="$now_cpu"
  fi
done
end_cpu="$(cpu_seconds)"

# 2 targets every 5 s; ICMP echo request + reply of 36 bytes each (20 IP + 8 ICMP + 8 payload).
probe_bytes_per_hour=$(( 3600 / 5 * 2 * 2 * 36 ))

awk -v a="$start_cpu" -v b="$end_cpu" -v d="$DURATION" -v rss="$peak_rss_kb" \
    -v cpub="$CPU_BUDGET_PERCENT" -v rssb="$RSS_BUDGET_MB" -v net="$probe_bytes_per_hour" '
BEGIN {
  cpu = (b - a) / d * 100
  mb = rss / 1024
  printf "duration      %d s\n", d
  printf "avg CPU       %.2f%%   (budget < %.1f%%, app only)\n", cpu, cpub
  printf "peak RSS      %.1f MB  (budget < %d MB)\n", mb, rssb
  printf "network       ~%.0f KB/h probes, calculated (budget < 1024 KB/h)\n", net / 1024
  fail = 0
  if (cpu >= cpub) { print "FAIL: CPU budget exceeded"; fail = 1 }
  if (mb >= rssb)  { print "FAIL: memory budget exceeded"; fail = 1 }
  if (!fail) print "PASS"
  exit fail
}'

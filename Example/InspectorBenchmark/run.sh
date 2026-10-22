#!/bin/zsh
# Runs the installed InspectorBenchmark app 2 × <pairs> times on a simulator or a device, with and without
# SWIFTUI_VIEW_DEBUG in alternating (ABBA) order, and writes one JSON line per run to <output>.
#
#   ./run.sh <simulator-or-device-udid> [pairs=6] [output=results.jsonl]
#   python3 report.py results.jsonl
#
# Devices must be unlocked; the app keeps the screen on while it runs.
set -u
udid=${1:?usage: run.sh <simulator-or-device-udid> [pairs=6] [output=results.jsonl]}
pairs=${2:-6}
out=${3:-results.jsonl}
bundle=dev.layoutinspector.benchmark
if xcrun simctl list devices | grep -q "$udid"; then kind=simulator; else kind=device; fi

: > "$out"
for i in $(seq 1 $pairs); do
  if (( i % 2 )); then order=(on off); else order=(off on); fi
  for cfg in $order; do
    if [[ $kind == simulator ]]; then
      if [[ $cfg == on ]]; then export SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=27; else unset SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG; fi
      line=$(xcrun simctl launch --console-pty --terminate-running-process "$udid" $bundle 2>/dev/null | grep -o 'BENCH.*')
    else
      # devicectl rejects an empty environment, so "off" passes an unrelated variable.
      env='{"BENCH_CONFIG":"off"}'
      [[ $cfg == on ]] && env='{"SWIFTUI_VIEW_DEBUG":"27"}'
      line=$(xcrun devicectl device process launch --device "$udid" --terminate-existing --console -e "$env" $bundle 2>/dev/null | grep -o 'BENCH.*')
    fi
    if [[ -z $line ]]; then
      echo "run $i, $cfg: no result (app not installed? device locked?)" >&2
    else
      echo "${line#BENCH }" >> "$out"
      echo "run $i, $cfg: ok"
    fi
    sleep 3
  done
done

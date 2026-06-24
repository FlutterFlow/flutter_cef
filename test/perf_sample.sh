#!/usr/bin/env bash
#
# Sample cef_host process count + total RSS + the host-app fd count while the
# stress probe (example/lib/stress_probe.dart) runs. Pair the CSV here with the
# CEF_STRESS frame-timing rows the probe writes to /tmp/cef_stress.jsonl.
#
# Usage: ./test/perf_sample.sh [seconds] [interval]
#
SECS="${1:-30}"; IV="${2:-2}"
echo "t,cef_procs,cef_rss_mb,cef_cpu,app_fds"
for ((t=0; t<=SECS; t+=IV)); do
  pids=$(pgrep -f cef_host 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  procs=$(printf '%s' "$pids" | awk -F, '{print ($1==""?0:NF)}')
  if [ -n "$pids" ]; then
    rss=$(ps -o rss= -p "$pids" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
    cpu=$(ps -o %cpu= -p "$pids" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s}')
  else
    rss=0; cpu=0
  fi
  app=$(pgrep -f flutter_cef_example 2>/dev/null | head -1)
  fds=$([ -n "$app" ] && lsof -p "$app" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  echo "$t,${procs:-0},${rss:-0},${cpu:-0},${fds:-0}"
  sleep "$IV"
done

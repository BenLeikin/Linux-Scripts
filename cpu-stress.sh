#!/usr/bin/env bash
set -euo pipefail

max_cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
echo "Detected online CPU cores: $max_cores"

read -r -p "How many cores do you want to stress (1-$max_cores)? " cores
if [[ ! "$cores" =~ ^[0-9]+$ ]] || (( cores < 1 || cores > max_cores )); then
  echo "ERROR: enter an integer between 1 and $max_cores"
  exit 1
fi

read -r -p "How long (seconds) should the test run? [60] " duration
duration="${duration:-60}"
if [[ ! "$duration" =~ ^[0-9]+$ ]] || (( duration < 1 )); then
  echo "ERROR: duration must be a positive integer"
  exit 1
fi

echo
echo "Stressing $cores core(s) for $duration second(s)."
echo "Press Ctrl+C to stop early."
echo

pids=()

cleanup() {
  # Kill workers if still running
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo
  echo "Stopped."
}
trap cleanup INT TERM EXIT

# A tight loop to burn CPU. One process ~= one core when scheduler allows.
burn() {
  local x=0
  while :; do
    x=$((x + 1))
  done
}

for ((i=1; i<=cores; i++)); do
  burn &
  pids+=("$!")
done

sleep "$duration"
exit 0

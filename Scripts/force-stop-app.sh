#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTABLE="$ROOT/build/VoxRouter.app/Contents/MacOS/VoxRouter"
PIDS=()
PROCESSES="$(ps -axo pid=,command=)"

while read -r pid command; do
  if [[ "$command" == "$EXECUTABLE" || "$command" == "$EXECUTABLE "* ]]; then
    PIDS+=("$pid")
  fi
done <<< "$PROCESSES"

if [ "${#PIDS[@]}" -eq 0 ]; then
  echo "VoxRouter is not running."
  exit 0
fi

kill -9 "${PIDS[@]}"
echo "Force-stopped VoxRouter (${PIDS[*]})."

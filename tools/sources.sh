#!/bin/bash
# Print the absolute paths of the sources for one binary: helper | encoder.
#
#   swiftc -O -o thing $(bash tools/sources.sh helper)
#
# Single source of truth for what each binary is made of. See
# wacom-helper/sources.txt.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  helper)  LIST="$REPO/wacom-helper/sources.txt" ;;
  encoder) LIST="$REPO/timelapse-encoder/sources.txt" ;;
  *) echo "usage: sources.sh helper|encoder" >&2; exit 2 ;;
esac
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  printf '%s\n' "$REPO/$line"
done < "$LIST"

#!/usr/bin/env bash
# The live tour: the real app drives itself through the features no test can
# see (LiveTour.swift), screenshots each step and writes a report, then quits.
#
#   scripts/live-tour.sh [--debug] [--out <dir>] <noisy.ARW> <pair-a.ARW> <pair-b.ARW>
#
# The three RAWs are COPIED into <dir>/photos (never opened in place): the
# first is the noise-reduction subject (the higher its ISO the better), the
# other two each get a JPEG beside them (sips) to make two RAW+JPEG pairs,
# and three small plain JPEGs are made from them for the trash and search
# steps. The app reads and writes nothing outside <dir>: its stores, its
# settings (a UserDefaults suite of its own, cleared) and its Trash are
# redirected there. It takes the screen for about two minutes.
#
# --debug runs .build/debug/PhotoLab (fast to rebuild); the default builds
# and runs build/PhotoLab.app (scripts/bundle.sh), the app you would ship.
# <dir> defaults to a new folder under $TMPDIR; it is kept, read
# <dir>/report.md and <dir>/shots/. Exit 0 when no step FAILs.
set -euo pipefail
cd "$(dirname "$0")/.."

debug=0
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) debug=1; shift ;;
    --out) out="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
if [[ $# -ne 3 ]]; then
  echo "usage: scripts/live-tour.sh [--debug] [--out <dir>] <noisy.ARW> <pair-a.ARW> <pair-b.ARW>" >&2
  exit 2
fi
for f in "$@"; do [[ -f "$f" ]] || { echo "no such file: $f" >&2; exit 2; }; done

out="${out:-${TMPDIR:-/tmp}/photolab-live-tour-$(date +%Y%m%d-%H%M%S)}"
if [[ -e "$out" && -n "$(ls -A "$out" 2>/dev/null)" ]]; then
  echo "refusing: $out exists and is not empty" >&2
  exit 2
fi
photos="$out/photos"
mkdir -p "$photos"

cp "$1" "$photos/"
for raw in "$2" "$3"; do
  name="$(basename "$raw")"
  cp "$raw" "$photos/"
  sips -s format jpeg -Z 2048 "$raw" --out "$photos/${name%.*}.JPG" >/dev/null
done
n=1
for raw in "$2" "$3" "$2"; do
  sips -s format jpeg -Z 1200 "$raw" --out "$photos/IMG_000$n.jpg" >/dev/null
  n=$((n + 1))
done
echo "staged $(ls "$photos" | wc -l | tr -d ' ') files in $photos"

if [[ $debug -eq 1 ]]; then
  swift build
  bin=.build/debug/PhotoLab
else
  scripts/bundle.sh
  bin=build/PhotoLab.app/Contents/MacOS/PhotoLab
fi

set +e
PHOTOLAB_LIVE_TOUR="$out" "$bin" > "$out/app.log" 2>&1
status=$?
set -e
grep '^LIVE-TOUR' "$out/app.log"
echo
echo "report: $out/report.md"
echo "shots:  $out/shots/"
exit "$status"

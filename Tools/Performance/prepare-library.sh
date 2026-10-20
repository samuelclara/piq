#!/bin/zsh
# Prepares a simulator for Piq's real-library performance runs (PiqUITests/PerformanceSortingTests).
#
#   prepare-library.sh <SIM> <WS> <DD> [generate|import|grant|reset|all]
#
#   generate  renders 450 photos into $DD/media with tools/genlibrary (about 2 GB, ~30 s):
#             12 MP JPEG (4032x3024 / 3024x4032, 3.4-4.9 MB), 45 HEIC at 12 MP, 10 at 48 MP
#             (8064x6048, 2 of them HEIC), distinct EXIF capture dates over 9-11 Oct 2026.
#   import    adds them to the simulator's photo library, 50 per `simctl addmedia` call.
#             (The simulator's 6 sample photos stay: Recents then lists 456 photos.)
#   grant     records Photos access for Piq (the app must be installed: run any xcodebuild test
#             first). On iOS 26 simulators PhotoKit ignores it; PerformanceSortingTests taps
#             "Allow Full Access" on the system prompt instead, so run that class first.
#   reset     terminates Piq and deletes its SwiftData store, so Recents opens on "Start sorting".
#             Run it before each measured run.
#   all       generate + import + grant + reset (default).
set -euo pipefail
SIM=${1:?SIM}
WS=${2:?WS}
DD=${3:?DD}
STEP=${4:-all}
TOOLS=${0:A:h}

generate() {
  mkdir -p "$DD/logs"
  [[ -x "$DD/genlibrary" ]] || xcrun swiftc -O -o "$DD/genlibrary" "$TOOLS/genlibrary.swift"
  rm -rf "${DD:?}/media"
  "$DD/genlibrary" "$WS/Piq/Preview Content/Preview Assets.xcassets" "$DD/media" > "$DD/logs/genlibrary.log"
  tail -1 "$DD/logs/genlibrary.log"
}

import_media() {
  local files=("$DD"/media/IMG_6*(.N))
  (( ${#files} > 0 )) || { echo "no media in $DD/media: run generate first"; exit 1; }
  local i
  for (( i = 1; i <= ${#files}; i += 50 )); do
    xcrun simctl addmedia "$SIM" "${(@)files[i,i+49]}"
    echo "imported $(( i + 49 < ${#files} ? i + 49 : ${#files} ))/${#files}"
  done
}

grant() {
  xcrun simctl privacy "$SIM" grant photos io.belleville.piq
  echo "granted Photos access"
}

reset_store() {
  xcrun simctl terminate "$SIM" io.belleville.piq 2>/dev/null || true
  local data
  data=$(xcrun simctl get_app_container "$SIM" io.belleville.piq data)
  rm -f "${data:?}/Library/Application Support/default.store" \
        "${data:?}/Library/Application Support/default.store-shm" \
        "${data:?}/Library/Application Support/default.store-wal"
  echo "reset Piq's session store"
}

case "$STEP" in
  generate) generate ;;
  import) import_media ;;
  grant) grant ;;
  reset) reset_store ;;
  all) generate; import_media; grant; reset_store ;;
  *) echo "unknown step $STEP"; exit 2 ;;
esac

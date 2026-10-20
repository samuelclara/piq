#!/bin/zsh
# Prepares a simulator's photo library for Piq's PhotoKit end-to-end tests
# (PiqTests/PhotoKitIntegrationTests, PiqUITests/PhotoKitEndToEndTests). Safe to run again.
#
#   SIM=<udid> DD=<derived data dir> [WS=<project dir>] [MEDIA=<dir>] Tools/PhotoKitE2E/prepare-library.sh
#
# WS defaults to the project this script is in, MEDIA to $DD/media.
#
# 1. Generates the media once (gen_media.swift, compiled into $DD/PhotoKitE2E): 60 photos
#    E2E_1001...E2E_1060 with distinct EXIF capture dates over 10-11 Oct 2026 (six converted to
#    HEIC with sips, one 48 MP), a small 1200x900 photo E2E_SMALL, and two short videos.
# 2. Builds Piq and its tests if needed and installs Piq (so iPadOS knows its bundle id).
# 3. Imports with `xcrun simctl addmedia` every E2E file the library doesn't show (checked by
#    original filename on a copy of Photos.sqlite, ignoring Recently Deleted and hidden photos,
#    except E2E_1056, which the tests hide on purpose). Running it again after the deleting tests
#    brings the deleted photos back as new assets. A fresh simulator also has 6 sample photos
#    (2009-2018); the tests account for them.
#
# Then grant full access and arrange the albums (run-e2e.sh, next to this script, does it all):
#   - `xcrun simctl privacy grant photos` does NOT work for PhotoKit on iOS 26.5 (it writes a
#     version-1 TCC record that PhotoKit reports as notDetermined), so full access is granted by
#     answering the real prompt: PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess.
#   - Albums and favorites: PiqTests/PhotoKitIntegrationTests/test00PrepareLibrary (idempotent).
set -euo pipefail

SIM=${SIM:?set SIM to the simulator udid}
DD=${DD:?set DD to the derived data directory}
TOOLS=${0:A:h}
WS=${WS:-${TOOLS:h:h}}
MEDIA=${MEDIA:-$DD/media}
BIN="$DD/PhotoKitE2E"
APP="$DD/Build/Products/Debug-iphonesimulator/Piq.app"
LIBRARY=~/Library/Developer/CoreSimulator/Devices/$SIM/data/Media/PhotoData

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null

# 1. Media
if [[ ! -f "$MEDIA/import-order.txt" ]]; then
    mkdir -p "$BIN"
    swiftc -O -o "$BIN/gen_media" "$TOOLS/gen_media.swift"
    "$BIN/gen_media" "$MEDIA"
    for name in $(cat "$MEDIA/heic.txt"); do
        sips -s format heic "$MEDIA/$name.JPG" --out "$MEDIA/$name.HEIC" >/dev/null
        rm -f "$MEDIA/$name.JPG"
    done
fi

# 2. App
if [[ ! -d "$APP" ]]; then
    xcodebuild -project "$WS/Piq.xcodeproj" -scheme Piq -destination "platform=iOS Simulator,id=$SIM" \
        -derivedDataPath "$DD" build-for-testing > "$DD/e2e-prepare-build.log" 2>&1 \
        || { grep -E "error:" "$DD/e2e-prepare-build.log" | sort -u; echo "Building Piq failed (see $DD/e2e-prepare-build.log)"; exit 1; }
fi
xcrun simctl install "$SIM" "$APP"

# 3. Import what's missing
mkdir -p "$BIN/db"
cp "$LIBRARY"/Photos.sqlite* "$BIN/db/"
present=$(sqlite3 "$BIN/db/Photos.sqlite" "select b.ZORIGINALFILENAME from ZASSET a join ZADDITIONALASSETATTRIBUTES b on b.ZASSET = a.Z_PK where b.ZORIGINALFILENAME like 'E2E_%' and a.ZTRASHEDSTATE = 0 and (a.ZHIDDEN = 0 or b.ZORIGINALFILENAME = 'E2E_1056.JPG')")
files=()
for name in $(cat "$MEDIA/import-order.txt"); do
    if ! print -r -- "$present" | grep -qx "$name"; then
        files+=("$MEDIA/$name")
    fi
done
if (( ${#files} > 0 )); then
    xcrun simctl addmedia "$SIM" "${files[@]}"
    echo "Imported ${#files} files: ${files[@]:t}"
else
    echo "The library already holds every E2E file; nothing imported."
fi

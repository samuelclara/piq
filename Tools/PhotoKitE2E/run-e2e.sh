#!/bin/zsh
# Prepares a simulator and runs Piq's PhotoKit end-to-end tests on its real photo library, then
# leaves the library the way the tests expect it. Exits non-zero when the build or a test fails,
# or when a gated test skips (past the PIQ_E2E gate, a skip means something wasn't prepared).
#
#   SIM=<udid> DD=<derived data dir> [WS=<project dir>] Tools/PhotoKitE2E/run-e2e.sh [all|unit|ui]
#
#   unit  PiqTests/PhotoKitIntegrationTests (hosted in Piq, real PhotoKit)
#   ui    PiqUITests/PhotoKitEndToEndTests (Piq launched without -PiqMockLibrary)
#   all   both (the default)
#
# WS defaults to the project this script is in. Steps:
# 1. prepare-library.sh: generates the media once (gen_media.swift, into $DD/media), builds and
#    installs Piq if needed, and imports with `xcrun simctl addmedia` whatever E2E media the
#    library is missing (photos earlier runs deleted come back as new copies).
# 2. build-for-testing.
# 3. PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess: resets Piq's Photos permission and
#    answers its prompt with Allow Full Access, and answers the test runner's own prompt (the
#    runner changes the library "outside Piq"). `xcrun simctl privacy grant photos` is not used:
#    on iOS 26.5 it writes a TCC record that PhotoKit still reports as notDetermined.
# 4. PiqTests/PhotoKitIntegrationTests (all, unit), or just its test00PrepareLibrary (ui), which
#    arranges E2E Trip (25 photos and a video), E2E Empty, E2E Folder > E2E Nested and the
#    favorites. Idempotent.
# 5. PiqUITests/PhotoKitEndToEndTests (all, ui). The trash test and the deletion test each move 2
#    of E2E Trip's photos to Recently Deleted; the first-launch tests reset Piq's Photos
#    permission and grant full access again when they end.
# 6. After step 5: steps 1 and 4 again, so E2E Trip is back to 25 photos.
#
# Logs and result bundles: $DD/e2e-*.log and $DD/e2e-*.xcresult; UI screenshots: $DD/e2e-shots.
set -uo pipefail

SIM=${SIM:?set SIM to the simulator udid}
DD=${DD:?set DD to the derived data directory}
TOOLS=${0:A:h}
WS=${WS:-${TOOLS:h:h}}
export SIM DD WS
WHAT=${1:-all}
DEST="platform=iOS Simulator,id=$SIM"
failures=()

case $WHAT in
    all|unit|ui) ;;
    *) print -u2 "usage: run-e2e.sh [all|unit|ui]"; exit 2 ;;
esac

# Runs gated tests without building. Notes a failure when xcodebuild fails, a test skips, or no
# test ran at all; returns xcodebuild's status.
run() {
    local name=$1; shift
    local log="$DD/$name.log"
    rm -rf "${DD:?}/$name.xcresult"
    TEST_RUNNER_PIQ_E2E=1 xcodebuild test-without-building -project "$WS/Piq.xcodeproj" -scheme Piq \
        -destination "$DEST" -derivedDataPath "$DD" -resultBundlePath "$DD/$name.xcresult" "$@" \
        > "$log" 2>&1
    local exit_status=$?
    grep -E "^Test Case .*(passed|failed|skipped)" "$log" | sed -E "s/^Test Case '-\[[A-Za-z]+\.([A-Za-z]+) ([A-Za-z0-9]+)\]' /  \1.\2 /"
    local skipped ran
    skipped=$(grep -cE "^Test Case .* skipped" "$log")
    ran=$(grep -cE "^Test Case .* (passed|failed|skipped)" "$log")
    (( exit_status == 0 )) || failures+=("$name: xcodebuild exited $exit_status (see $log)")
    (( skipped == 0 )) || failures+=("$name: $skipped test(s) skipped (see $log)")
    (( ran > 0 )) || failures+=("$name: no test ran (see $log)")
    return $exit_status
}

finish() {
    if (( ${#failures} )); then
        print "FAILED:"
        for failure in "${failures[@]}"; do print "  $failure"; done
        exit 1
    fi
    print "Every E2E test passed."
    exit 0
}

"$TOOLS/prepare-library.sh" || { print "FAILED: prepare-library.sh"; exit 1; }

print "Building for testing"
if ! xcodebuild -project "$WS/Piq.xcodeproj" -scheme Piq -destination "$DEST" -derivedDataPath "$DD" \
        build-for-testing > "$DD/e2e-build.log" 2>&1; then
    grep -E "error:" "$DD/e2e-build.log" | sort -u
    print "FAILED: build-for-testing (see $DD/e2e-build.log)"
    exit 1
fi
grep -E "warning:" "$DD/e2e-build.log" | grep -v appintents | sort -u

print "Granting full Photos access (Piq and the test runner)"
run e2e-grant -only-testing:PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess
(( ${#failures} )) && finish

if [[ $WHAT == ui ]]; then
    print "Arranging the albums"
    run e2e-arrange -only-testing:PiqTests/PhotoKitIntegrationTests/test00PrepareLibrary
else
    print "PhotoKitIntegrationTests"
    run e2e-unit -only-testing:PiqTests/PhotoKitIntegrationTests
fi

if [[ $WHAT != unit ]]; then
    print "PhotoKitEndToEndTests"
    run e2e-ui -only-testing:PiqUITests/PhotoKitEndToEndTests \
        -skip-testing:PiqUITests/PhotoKitEndToEndTests/test00GrantFullAccess
    rm -rf "${DD:?}/e2e-shots"
    xcrun xcresulttool export attachments --path "$DD/e2e-ui.xcresult" --output-path "$DD/e2e-shots" >/dev/null 2>&1 \
        && print "Screenshots: $DD/e2e-shots (manifest.json names them)"

    print "Putting E2E Trip back"
    if "$TOOLS/prepare-library.sh"; then
        run e2e-restore -only-testing:PiqTests/PhotoKitIntegrationTests/test00PrepareLibrary
    else
        failures+=("restore: prepare-library.sh failed")
    fi
fi

finish

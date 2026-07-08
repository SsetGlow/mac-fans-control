#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Fan Control"
EXECUTABLE="MacFanControl"
HELPER_ID="local.mac-fan-control.smc-helper"
SOURCE_APP="build/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"

./build.sh

pkill -x "${EXECUTABLE}" 2>/dev/null || true
pkill -f "${HELPER_ID}" 2>/dev/null || true
rm -rf "${TARGET_APP}"
ditto "${SOURCE_APP}" "${TARGET_APP}"
codesign --force --deep --sign - "${TARGET_APP}" >/dev/null 2>&1 || true

echo "Installed fresh app at ${TARGET_APP}"
"${TARGET_APP}/Contents/MacOS/${EXECUTABLE}" --install-helper || true
open "${TARGET_APP}"

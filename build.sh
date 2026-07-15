#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Fan Control"
EXECUTABLE="MacFanControl"
APP_BUNDLE_ID="local.mac-fan-control"
HELPER_ID="local.mac-fan-control.smc-helper"
ARCH="$(uname -m)"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
LAUNCH_SERVICES_DIR="${CONTENTS_DIR}/Library/LaunchServices"
LAUNCH_DAEMONS_DIR="${CONTENTS_DIR}/Library/LaunchDaemons"
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

rm -rf build
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${LAUNCH_SERVICES_DIR}" "${LAUNCH_DAEMONS_DIR}"

swiftc \
  -target "${ARCH}-apple-macos13.0" \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework IOKit \
  Sources/MacFanControl/*.swift \
  -o "${MACOS_DIR}/${EXECUTABLE}"

swiftc \
  -target "${ARCH}-apple-macos13.0" \
  -parse-as-library \
  -O \
  -framework Foundation \
  -framework IOKit \
  Sources/MacFanControl/SMCClient.swift \
  Sources/MacFanControl/AppleSiliconTemperatureReader.swift \
  Sources/MacFanControl/SMCHelperProtocol.swift \
  Sources/MacFanControlHelper/main.swift \
  -o "${LAUNCH_SERVICES_DIR}/${HELPER_ID}"

HELPER_PLIST="${LAUNCH_DAEMONS_DIR}/${HELPER_ID}.plist"
plutil -create xml1 "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :Label string ${HELPER_ID}" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :BundleProgram string Contents/Library/LaunchServices/${HELPER_ID}" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :MachServices dict" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :MachServices:${HELPER_ID} bool true" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :AssociatedBundleIdentifiers array" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :AssociatedBundleIdentifiers:0 string ${APP_BUNDLE_ID}" "${HELPER_PLIST}"

cp MacFanControl/Info.plist "${CONTENTS_DIR}/Info.plist"
cp MacFanControl/Resources/MacFanControl.icns "${RESOURCES_DIR}/MacFanControl.icns"
cp MacFanControl/local.mac-fan-control.smc-helper.plist "${RESOURCES_DIR}/${HELPER_ID}.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${APP_BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
codesign --force --sign "${CODE_SIGN_IDENTITY}" --identifier "${HELPER_ID}" "${LAUNCH_SERVICES_DIR}/${HELPER_ID}"
codesign --force --deep --sign "${CODE_SIGN_IDENTITY}" "${BUNDLE_DIR}"
codesign --verify --deep --strict "${BUNDLE_DIR}"

echo "Built ${BUNDLE_DIR} (${BUILD_NUMBER})"
if [[ "${CODE_SIGN_IDENTITY}" == "-" ]]; then
  echo "Note: ad-hoc build will install its privileged helper with administrator approval on first launch."
fi

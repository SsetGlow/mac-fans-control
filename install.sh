#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Mac Fan Control"
EXECUTABLE="MacFanControl"
HELPER_ID="local.mac-fan-control.smc-helper"
SOURCE_APP="build/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [[ -z "${CODE_SIGN_IDENTITY}" || "${CODE_SIGN_IDENTITY}" == "-" ]]; then
  echo "Error: installing the privileged helper requires CODE_SIGN_IDENTITY to be an Apple code-signing identity." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "${CODE_SIGN_IDENTITY}"; then
  echo "Error: code-signing identity not found: ${CODE_SIGN_IDENTITY}" >&2
  exit 1
fi

export CODE_SIGN_IDENTITY

./build.sh

pkill -x "${EXECUTABLE}" 2>/dev/null || true
pkill -f "${HELPER_ID}" 2>/dev/null || true
rm -rf "${TARGET_APP}"
ditto "${SOURCE_APP}" "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

echo "Installed fresh app at ${TARGET_APP}"
"${TARGET_APP}/Contents/MacOS/${EXECUTABLE}" --install-helper --force-helper
open "${TARGET_APP}"

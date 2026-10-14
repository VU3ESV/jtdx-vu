#!/bin/bash
# Developer ID sign + notarise + staple the macOS zips CI builds.
#
#   ./macos-notarize.sh JTDX-VU-0.7.5-macos-arm64.zip JTDX-VU-0.7.5-macos-x86_64.zip
#
# CI (.github/workflows/macos.yml) builds ad-hoc signed apps; the Developer
# ID certificate and the notary credentials stay in this Mac's keychain,
# never in GitHub secrets. Each zip is replaced in place by the signed,
# notarised, stapled one (same name) and its .sha256 rewritten. Upload them
# to the release afterwards:
#   gh release upload vX.Y.Z JTDX-VU-*-macos-*.zip* --clobber
#
# Adapted from MSHV-Mac's macos/notarize.sh and the signing step of its
# build-standalone.sh. The notary profile is the one MSHV uses (same Apple
# ID and team); override with JTDXVU_NOTARY_PROFILE, the identity with
# DEVELOPER_ID_APPLICATION. Profile setup, once per Mac:
#   xcrun notarytool store-credentials MSHV-NOTARY \
#       --apple-id you@example.com --team-id ABCD123456 --password xxxx-xxxx-xxxx-xxxx
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENT="$ROOT/Darwin/JTDX-VU.entitlements"
PROFILE="${JTDXVU_NOTARY_PROFILE:-MSHV-NOTARY}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

[ $# -gt 0 ] || { echo "usage: $0 JTDX-VU-<ver>-macos-<arch>.zip ..." >&2; exit 1; }
[ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate in the keychain" >&2; exit 1; }
echo "identity: $IDENTITY"
echo "profile:  $PROFILE"

for Z in "$@"; do
  Z="$(cd "$(dirname "$Z")" && pwd)/$(basename "$Z")"
  [ -f "$Z" ] || { echo "$Z not found" >&2; exit 1; }
  echo "==> $(basename "$Z")"
  W="$(mktemp -d)"
  trap 'rm -rf "$W"' EXIT
  ditto -x -k "$Z" "$W/in"
  # copy without xattrs: codesign refuses FinderInfo / provenance "detritus"
  ditto --noextattr --norsrc --noacl "$W/in/JTDX-VU.app" "$W/JTDX-VU.app"
  APP="$W/JTDX-VU.app"
  xattr -cr "$APP" 2>/dev/null || true

  # --deep signs every helper (jtdxjt9, rigctld-jtdx ...) and dylib with the
  # same identity, hardened runtime and entitlements; --timestamp is
  # required by notarisation
  codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENT" "$APP"
  codesign --verify --deep --strict "$APP"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input \
    || { echo "audio-input entitlement missing" >&2; exit 1; }

  ditto -c -k --norsrc --keepParent "$APP" "$W/submit.zip"
  echo "    submitting to Apple (usually 1-15 min)"
  OUT="$(xcrun notarytool submit "$W/submit.zip" --keychain-profile "$PROFILE" --wait --output-format json)"
  ID="$(printf '%s' "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  ST="$(printf '%s' "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  echo "    $ID: $ST"
  if [ "$ST" != Accepted ]; then
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"

  # --norsrc: no ._ AppleDouble files, which break the seal after unzip
  ditto -c -k --norsrc --keepParent "$APP" "$Z"
  (cd "$(dirname "$Z")" && shasum -a 256 "$(basename "$Z")" > "$(basename "$Z").sha256")
  echo "    OK: $Z"
  rm -rf "$W"
  trap - EXIT
done

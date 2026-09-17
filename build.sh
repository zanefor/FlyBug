#!/bin/bash
set -euo pipefail
FLYBUG_ROOT="$(cd "$(dirname "$0")" && pwd)"
FLYBUG_APP="$FLYBUG_ROOT/FlyBug.app"
FLYBUG_ARCH="$(uname -m)"
FLYBUG_CACHE="${TMPDIR:-/tmp}/flybug-swift-module-cache"
FLYBUG_SIGN_IDENTITY="${FLYBUG_SIGN_IDENTITY:-$(cat "$FLYBUG_ROOT/signing-identity.txt")}"

# A stable signing identity preserves the application's identity across local
# rebuilds. Ad-hoc signing identifies a single binary and can lose TCC grants.
if [[ ! "$FLYBUG_SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "FlyBug requires a valid 40-character code-signing identity SHA-1 hash." >&2
  echo "Set FLYBUG_SIGN_IDENTITY using an identity listed by: security find-identity -v -p codesigning" >&2
  exit 1
fi
FLYBUG_SIGN_IDENTITY="$(printf '%s' "$FLYBUG_SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')"
FLYBUG_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
if ! printf '%s\n' "$FLYBUG_IDENTITIES" | /usr/bin/awk -v selected="$FLYBUG_SIGN_IDENTITY" '$2 == selected { found = 1 } END { exit !found }'; then
  echo "The configured FlyBug code-signing identity is unavailable or invalid on this Mac." >&2
  echo "Set FLYBUG_SIGN_IDENTITY to your own valid code-signing identity SHA-1 hash." >&2
  echo "The existing app was preserved. FlyBug will not fall back to ad-hoc signing." >&2
  exit 1
fi

# Build and seal a separate bundle on the same volume. A failed compile/sign
# leaves the installed bundle untouched; its executable is never truncated.
FLYBUG_STAGE="$(mktemp -d "$FLYBUG_ROOT/.flybug-build.XXXXXX")"
FLYBUG_STAGED_APP="$FLYBUG_STAGE/FlyBug.app"
FLYBUG_PREVIOUS_APP="$FLYBUG_STAGE/previous-FlyBug.app"
cleanup() {
  if [[ -d "$FLYBUG_PREVIOUS_APP" && ! -e "$FLYBUG_APP" ]]; then
    /bin/mv "$FLYBUG_PREVIOUS_APP" "$FLYBUG_APP"
  fi
  /bin/rm -rf -- "${FLYBUG_STAGE:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$FLYBUG_STAGED_APP/Contents/MacOS" "$FLYBUG_STAGED_APP/Contents/Resources" "$FLYBUG_CACHE"
echo "Building FlyBug for macOS 14+ ($FLYBUG_ARCH)…"
xcrun swiftc -swift-version 5 -O \
  -target "$FLYBUG_ARCH-apple-macosx14.0" \
  -module-cache-path "$FLYBUG_CACHE" \
  "$FLYBUG_ROOT"/Sources/*.swift \
  -framework AppKit -framework WebKit -framework Network \
  -framework ApplicationServices -framework Vision -framework ScreenCaptureKit \
  -o "$FLYBUG_STAGED_APP/Contents/MacOS/FlyBug"
cp "$FLYBUG_ROOT"/Resources/* "$FLYBUG_STAGED_APP/Contents/Resources/"
cp "$FLYBUG_ROOT/Info.plist" "$FLYBUG_STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign "$FLYBUG_SIGN_IDENTITY" --timestamp=none \
  --identifier local.flybug.desktop "$FLYBUG_STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$FLYBUG_STAGED_APP"

# Quit FlyBug before running this build. This script never terminates apps.
# Directory renames publish only the verified bundle, with rollback on failure.
if [[ -e "$FLYBUG_APP" ]]; then
  /bin/mv "$FLYBUG_APP" "$FLYBUG_PREVIOUS_APP"
fi
/bin/mv "$FLYBUG_STAGED_APP" "$FLYBUG_APP"
echo "Built and verified: $FLYBUG_APP"

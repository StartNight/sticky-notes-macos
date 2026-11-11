#!/bin/bash
# Re-sign a built Release "Sticky Notes.app" with the local self-signed identity.
# Contains only the identity name / SHA1 (public), no secrets. Does NOT use --deep, does NOT
# touch trust settings, and never exports or deletes the identity.
# Usage: scripts/sign-local.sh "/path/to/Sticky Notes.app"
set -euo pipefail

IDENTITY_NAME="StickyNotes Local Code Signing"
IDENTITY_SHA1="5C13B938CFE75F5FE2675014DD189D0FB001DA6C"
APP="${1:?usage: sign-local.sh <path to .app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS_SRC="$ROOT/StickyNotes/StickyNotes.entitlements"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# Fail fast (no bypass) if the identity is not present.
security find-identity -p codesigning | grep -q "$IDENTITY_SHA1" || {
  echo "ERROR: identity $IDENTITY_NAME ($IDENTITY_SHA1) not found in keychain search list" >&2; exit 2; }

# Entitlements: keep the source entitlements, always strip get-task-allow.
ENT="$(mktemp -t sn-entitlements).plist"
trap 'rm -f "$ENT"' EXIT
cp "$ENTITLEMENTS_SRC" "$ENT"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ENT" >/dev/null 2>&1 || true

sign() { # <path> <identifier> [entitlements]
  local path="$1" ident="$2"; shift 2
  /usr/bin/codesign --force --sign "$IDENTITY_SHA1" --identifier "$ident" --timestamp=none "$@" "$path"
}

# 1) Nested code first (innermost first, deepest paths first). The main executable is excluded.
MAIN_EXEC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
while IFS= read -r item; do
  [ -z "$item" ] && continue
  [ "$item" = "$MAIN_EXEC" ] && continue
  case "$item" in
    *.framework|*.app|*.appex|*.xpc) id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$item/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$item/Resources/Info.plist" 2>/dev/null || basename "$item")" ;;
    *) id="$BUNDLE_ID.$(basename "$item" | sed 's/[^A-Za-z0-9.-]/-/g')" ;;
  esac
  echo "signing nested: $item ($id)"
  sign "$item" "$id"
done < <(find "$APP/Contents" \( -name "*.framework" -o -name "*.appex" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.app" \) -not -path "$APP" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

# 2) Main app last, with entitlements (no get-task-allow).
echo "signing main: $APP ($BUNDLE_ID)"
sign "$APP" "$BUNDLE_ID" --entitlements "$ENT"

# 3) Verify.
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
if /usr/bin/codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
  echo "ERROR: get-task-allow still present" >&2; exit 3; fi
echo "DR: $(/usr/bin/codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "cdhash: $(/usr/bin/codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"

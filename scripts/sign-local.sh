#!/bin/bash
# Re-sign a built Release "Sticky Notes.app" with the local self-signed identity.
# Contains only the identity name / SHA1 (public), no secrets. Does NOT use --deep, does NOT
# touch trust settings, and never exports or deletes the identity.
# Usage: scripts/sign-local.sh "/path/to/Sticky Notes.app"
set -euo pipefail

IDENTITY_NAME="${IDENTITY_NAME:-StickyNotes Local Code Signing}"
IDENTITY_SHA1="${IDENTITY_SHA1:-5C13B938CFE75F5FE2675014DD189D0FB001DA6C}"
APP="${1:?usage: sign-local.sh <path to .app>}"
APP="${APP%/}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS_SRC="$ROOT/StickyNotes/StickyNotes.entitlements"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# Fail fast (no bypass) if the identity is not present.
# Capture output first to avoid SIGPIPE under `set -o pipefail` with `grep -q`.
IDENTITIES="$(security find-identity -p codesigning)"
grep -Fq "$IDENTITY_SHA1" <<<"$IDENTITIES" || {
  echo "ERROR: identity $IDENTITY_NAME ($IDENTITY_SHA1) not found in keychain search list" >&2; exit 2; }

# Entitlements: keep the source entitlements, always strip get-task-allow.
TMP_DIR="$(mktemp -d -t sn-entitlements)"
trap 'rm -rf "$TMP_DIR"' EXIT
ENT="$TMP_DIR/entitlements.plist"
cp "$ENTITLEMENTS_SRC" "$ENT"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ENT" >/dev/null 2>&1 || true

sign() { # <path> <identifier> [entitlements]
  local path="$1" ident="$2"; shift 2
  /usr/bin/codesign --force --options runtime --sign "$IDENTITY_SHA1" --identifier "$ident" --timestamp=none "$@" "$path"
}

# 1) Nested code first (innermost first, deepest paths first). The main executable is excluded.
MAIN_EXEC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
while IFS= read -r item; do
  [ -z "$item" ] && continue
  [ "$item" = "$MAIN_EXEC" ] && continue
  case "$item" in
    *.framework|*.app|*.appex|*.xpc|*.bundle|*.plugin) id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$item/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$item/Resources/Info.plist" 2>/dev/null || basename "$item")" ;;
    *) id="$BUNDLE_ID.$(basename "$item" | sed 's/[^A-Za-z0-9.-]/-/g')" ;;
  esac
  echo "signing nested: $item ($id)"
  sign "$item" "$id"
done < <(find "$APP/Contents" \( -name "*.framework" -o -name "*.appex" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.so" -o -name "*.bundle" -o -name "*.plugin" -o -name "*.app" \) -not -path "$APP" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

# Sign any extra standalone Mach-O helpers under Contents/MacOS besides the main executable.
while IFS= read -r helper; do
  [ -z "$helper" ] && continue
  [ "$helper" = "$MAIN_EXEC" ] && continue
  if file "$helper" | grep -Fq "Mach-O"; then
    id="$BUNDLE_ID.$(basename "$helper" | sed 's/[^A-Za-z0-9.-]/-/g')"
    echo "signing helper: $helper ($id)"
    sign "$helper" "$id"
  fi
done < <(find "$APP/Contents/MacOS" -maxdepth 1 -type f 2>/dev/null)

# 2) Main app last, with entitlements (no get-task-allow) and Hardened Runtime.
echo "signing main: $APP ($BUNDLE_ID)"
sign "$APP" "$BUNDLE_ID" --entitlements "$ENT"

# 3) Verify strictly including nested code and verify get-task-allow is absent (without pipefail+grep SIGPIPE).
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGNED_ENT="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>&1)"
if grep -Fq "get-task-allow" <<<"$SIGNED_ENT"; then
  echo "ERROR: get-task-allow still present" >&2; exit 3; fi
echo "DR: $(/usr/bin/codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "cdhash: $(/usr/bin/codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"

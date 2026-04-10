#!/usr/bin/env bash
set -euo pipefail

# Sync auth.json from authSource into the profile's codexHome.
# If authLink is already a symlink pointing to authSource, re-create it.
# If authSource is a directory, copy auth.json from inside it.

if [ "$#" -lt 1 ]; then
  echo "Usage: sync-auth.sh <profile-dir>" >&2
  exit 1
fi

PROFILE_DIR="$(readlink -f "$1")"
PROFILE_JSON="$PROFILE_DIR/profile.json"

if [ ! -f "$PROFILE_JSON" ]; then
  echo "profile.json not found in: $PROFILE_DIR" >&2
  exit 1
fi

read_field() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$PROFILE_JSON" "$1" 2>/dev/null
}

AUTH_SOURCE="$(read_field authSource)"
AUTH_LINK="$(read_field authLink)"
CODEX_HOME="$(read_field codexHome)"

if [ -z "$AUTH_SOURCE" ] || [ -z "$AUTH_LINK" ] || [ -z "$CODEX_HOME" ]; then
  echo "Missing required fields in $PROFILE_JSON" >&2
  exit 1
fi

mkdir -p "$CODEX_HOME"

if [ ! -e "$AUTH_SOURCE" ] && [ ! -L "$AUTH_SOURCE" ]; then
  echo "Auth source not found: $AUTH_SOURCE" >&2
  exit 1
fi

resolve_auth_file() {
  if [ -d "$AUTH_SOURCE" ]; then
    for candidate in "$AUTH_SOURCE/auth.json" "$AUTH_SOURCE/.auth.json"; do
      if [ -f "$candidate" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
    echo "No auth.json found in directory: $AUTH_SOURCE" >&2
    return 1
  else
    printf '%s' "$AUTH_SOURCE"
  fi
}

SOURCE_FILE="$(resolve_auth_file)"

RESOLVED_SOURCE="$(readlink -f "$SOURCE_FILE" 2>/dev/null || printf '%s' "$SOURCE_FILE")"
RESOLVED_LINK="$(readlink -f "$AUTH_LINK" 2>/dev/null || printf '%s' "$AUTH_LINK")"

if [ "$RESOLVED_SOURCE" = "$RESOLVED_LINK" ]; then
  echo "Auth already synced for profile: $(basename "$PROFILE_DIR")"
  exit 0
fi

rm -f "$AUTH_LINK"
ln -sfn "$SOURCE_FILE" "$AUTH_LINK"
echo "Synced auth for profile: $(basename "$PROFILE_DIR")"

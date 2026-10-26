#!/bin/sh
set -eu

TARGET=${1:?target required}
shift
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
RUNTIME="$ROOT/runtimes/$TARGET"
ARCHIVE="$ROOT/packages/bootstrap/$TARGET/node.tar.xz"
NODE="$RUNTIME/node/bin/node"

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}';
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}';
  else fail "sha256sum or shasum is required for initial setup"; fi
}
download() {
  url=$1 out=$2
  mkdir -p "$(dirname -- "$out")"
  if have curl; then curl -fL --retry 3 -C - -o "$out.part" "$url";
  elif have wget; then wget -c -O "$out.part" "$url";
  else fail "curl or wget is required for initial setup"; fi
  mv -f "$out.part" "$out"
}

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) ACTUAL=linux-x64 ;;
  Darwin:arm64) ACTUAL=macos-arm64 ;;
  Linux:*) fail "Unsupported Linux CPU. Version 1 supports x86_64 only." ;;
  Darwin:*) fail "Unsupported Mac CPU. Version 1 supports Apple Silicon only." ;;
  *) fail "Unsupported operating system: $(uname -s) $(uname -m)." ;;
esac
[ "$ACTUAL" = "$TARGET" ] || fail "Use the launcher for $ACTUAL, not $TARGET."

if [ "$TARGET" = linux-x64 ]; then
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 || fail "glibc Linux is required; musl is not supported in version 1."
  if have findmnt && findmnt -no OPTIONS --target "$ROOT" 2>/dev/null | tr ',' '\n' | grep -qx noexec; then
    fail "The drive is mounted noexec. Remount it with exec before running DeepSeek Harness."
  fi
  URL='https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-x64.tar.xz'
  HASH='6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6'
else
  URL='https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-arm64.tar.xz'
  HASH='654ba79de6155647e22321932b45f2a1ccb705976cc337c9b8e278beb085a628'
fi

if [ ! -x "$NODE" ]; then
  printf 'Preparing portable Node.js for %s...\n' "$TARGET"
  [ -f "$ARCHIVE" ] || download "$URL" "$ARCHIVE"
  [ "$(sha256 "$ARCHIVE")" = "$HASH" ] || { archive_bad="$ARCHIVE.bad"; mv -f "$ARCHIVE" "$archive_bad"; fail "Node.js checksum mismatch; moved to $archive_bad"; }
  STAGE="$ROOT/temp/node-$TARGET-$$"
  mkdir -p "$STAGE" "$RUNTIME"
  # npm/npx/corepack are archive symlinks. Omit them for exFAT; portable.mjs
  # invokes npm's JavaScript entry point directly through node.
  tar -xJf "$ARCHIVE" -C "$STAGE" --strip-components=1 \
    --exclude='*/bin/npm' --exclude='*/bin/npx' --exclude='*/bin/corepack' \
    || fail "Cannot extract .tar.xz. Install xz-utils once on this Linux host."
  [ -x "$STAGE/bin/node" ] || fail "Node.js archive has an unexpected layout."
  [ "$(find "$STAGE" -type l -print -quit)" = "" ] || fail "Node.js extraction produced a symlink; exFAT-safe setup was refused."
  [ ! -e "$RUNTIME/node" ] || mv "$RUNTIME/node" "$ROOT/temp/old-node-$TARGET-$$"
  mv "$STAGE" "$RUNTIME/node"
fi

exec "$NODE" "$SCRIPT_DIR/portable.mjs" --root "$ROOT" --target "$TARGET" "$@"

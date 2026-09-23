#!/usr/bin/env bash
set -euo pipefail

DEST_ROOT="${1:-}"
[[ -n "$DEST_ROOT" ]] || { echo 'Usage: prepare-v4l2loopback.sh <bundle-kernel-dir>' >&2; exit 2; }

VERSION='0.15.4'
ARCHIVE="v4l2loopback-${VERSION}.tar.gz"
URL="https://github.com/v4l2loopback/v4l2loopback/archive/refs/tags/v${VERSION}.tar.gz"
SHA256='21a17702648aa6a937b88a93bd71ef9f547815ead28719cafcfcc247396643dc'
KERNEL_RELEASE="${REMOLD_KERNEL_RELEASE:-$(uname -r)}"
KERNEL_BUILD="/lib/modules/${KERNEL_RELEASE}/build"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/kinect360-remold/v4l2loopback"
TARBALL="$CACHE_ROOT/$ARCHIVE"

[[ -r "$KERNEL_BUILD/Makefile" ]] || {
  echo "Linux kernel headers are missing for $KERNEL_RELEASE ($KERNEL_BUILD)." >&2
  echo 'The build stage must install the exact running-kernel headers before compiling v4l2loopback.' >&2
  exit 2
}

sha256_file(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'; return; fi
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print tolower($1)}'; return; fi
  python3 - "$1" <<'PY'
import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],'rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''):
        h.update(block)
print(h.hexdigest())
PY
}

mkdir -p "$CACHE_ROOT"
if [[ -f "$TARBALL" && "$(sha256_file "$TARBALL")" != "$SHA256" ]]; then
  echo 'Discarding cached v4l2loopback archive with unexpected integrity.' >&2
  rm -f "$TARBALL"
fi
if [[ ! -f "$TARBALL" ]]; then
  tmp="$TARBALL.part"
  rm -f "$tmp"
  echo "Downloading v4l2loopback v$VERSION for offline driver installation..."
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 --output "$tmp" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=30 --output-document="$tmp" "$URL"
  else
    echo 'curl or wget is required during the build stage.' >&2
    exit 2
  fi
  [[ "$(sha256_file "$tmp")" == "$SHA256" ]] || {
    rm -f "$tmp"
    echo 'v4l2loopback source integrity verification failed.' >&2
    exit 3
  }
  mv -f "$tmp" "$TARBALL"
fi
[[ "$(sha256_file "$TARBALL")" == "$SHA256" ]] || { echo 'Cached v4l2loopback source integrity verification failed.' >&2; exit 3; }

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/kinect360-remold-v4l2.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
tar -xzf "$TARBALL" -C "$tmpdir"
src="$tmpdir/v4l2loopback-$VERSION"
[[ -f "$src/Makefile" ]] || { echo 'Unexpected v4l2loopback source archive layout.' >&2; exit 3; }

make -C "$src" \
  KERNELRELEASE="$KERNEL_RELEASE" \
  KERNEL_DIR="$KERNEL_BUILD" \
  v4l2loopback.ko

module="$src/v4l2loopback.ko"
[[ -s "$module" ]] || { echo 'v4l2loopback module was not produced.' >&2; exit 3; }

out="$DEST_ROOT/$KERNEL_RELEASE"
mkdir -p "$out"
install -m 0644 "$module" "$out/v4l2loopback.ko"
printf '%s\n' "$KERNEL_RELEASE" >"$DEST_ROOT/KERNEL-RELEASE"
printf '%s\n' "$VERSION" >"$DEST_ROOT/V4L2LOOPBACK-VERSION"
printf '%s\n' "$SHA256" >"$DEST_ROOT/V4L2LOOPBACK-SOURCE-SHA256"
printf '%s\n' "$(sha256_file "$out/v4l2loopback.ko")" >"$DEST_ROOT/V4L2LOOPBACK-MODULE-SHA256"

if command -v modinfo >/dev/null 2>&1; then
  built_version="$(modinfo -F version "$out/v4l2loopback.ko" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [[ -z "$built_version" || "$built_version" == "$VERSION" ]] || {
    echo "Unexpected compiled v4l2loopback version: $built_version" >&2
    exit 3
  }
fi

echo "v4l2loopback v$VERSION compiled for Linux $KERNEL_RELEASE and bundled for offline installation."

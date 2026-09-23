#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-}"
[[ -n "$DEST" ]] || { echo 'Usage: prepare-uac-firmware.sh <output-file>' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SOURCE_ROOT/../../.." && pwd)"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/kinect360-remold/firmware"
RUNTIME="$CACHE_ROOT/KinectRuntime-v1.8-Setup.exe"
CACHE_FIRMWARE="$CACHE_ROOT/UACFirmware-01.02.709.00"
RUNTIME_URL='https://download.microsoft.com/download/E/C/5/EC50686B-82F4-4DBF-A922-980183B214E6/KinectRuntime-v1.8-Setup.exe'
RUNTIME_SHA256='f4d4143fb0f0a8d276889c077bfc8af42bfe99c128cadab5e316bf015a9858e9'
FIRMWARE_SHA256='4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9'
FIRMWARE_VERSION='01.02.709.00'

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

valid_firmware(){
  [[ -f "$1" ]] || return 1
  local size hash
  size="$(wc -c < "$1" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size >= 65536 && size <= 1048576 )) || return 1
  hash="$(sha256_file "$1")"
  [[ "$hash" == "$FIRMWARE_SHA256" ]]
}

publish_firmware(){
  local source="$1"
  valid_firmware "$source" || return 1
  mkdir -p "$(dirname "$DEST")"
  if [[ "$(readlink -f "$source")" != "$(readlink -m "$DEST")" ]]; then
    install -m 0644 "$source" "$DEST"
  fi
  echo "Microsoft Kinect UACFirmware $FIRMWARE_VERSION: READY"
  return 0
}

candidates=()
[[ -n "${KINECT_UAC_FIRMWARE:-}" ]] && candidates+=("$KINECT_UAC_FIRMWARE")
candidates+=(
  "$CACHE_FIRMWARE"
  "$SOURCE_ROOT/firmware/UACFirmware-$FIRMWARE_VERSION"
  "$PROJECT_ROOT/drivers/windows/source/components/device/firmware/UACFirmware-$FIRMWARE_VERSION"
)
for candidate in "${candidates[@]}"; do
  if [[ -f "$candidate" ]]; then
    if publish_firmware "$candidate"; then exit 0; fi
    echo "Ignoring firmware candidate with unexpected integrity: $candidate" >&2
  fi
done

for tool in python3 cabextract msiextract; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Required firmware extraction tool is missing: $tool" >&2
    echo 'Install Python 3, cabextract and msitools, then rebuild.' >&2
    exit 2
  }
done

mkdir -p "$CACHE_ROOT"
if [[ -f "$RUNTIME" && "$(sha256_file "$RUNTIME")" != "$RUNTIME_SHA256" ]]; then
  echo 'Discarding cached Kinect Runtime package with unexpected integrity.' >&2
  rm -f "$RUNTIME"
fi

if [[ ! -f "$RUNTIME" ]]; then
  tmp_download="$RUNTIME.part"
  rm -f "$tmp_download"
  echo 'Downloading Microsoft Kinect for Windows Runtime v1.8 for the Kinect audio firmware...'
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 \
      --output "$tmp_download" "$RUNTIME_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=30 --output-document="$tmp_download" "$RUNTIME_URL"
  else
    echo 'curl or wget is required to download the Microsoft Kinect Runtime.' >&2
    exit 2
  fi
  [[ "$(sha256_file "$tmp_download")" == "$RUNTIME_SHA256" ]] || {
    rm -f "$tmp_download"
    echo 'Microsoft Kinect Runtime v1.8 integrity verification failed.' >&2
    exit 3
  }
  mv -f "$tmp_download" "$RUNTIME"
fi

[[ "$(sha256_file "$RUNTIME")" == "$RUNTIME_SHA256" ]] || {
  echo 'Microsoft Kinect Runtime v1.8 cache integrity verification failed.' >&2
  exit 3
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/kinect360-remold-fw.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cabs" "$tmp/payloads" "$tmp/msi"

# WiX Burn v3 stores its UX and attached payload containers as CAB archives in
# the executable. Carve only structurally plausible CAB headers; cabextract
# performs the full archive validation before a payload is trusted.
python3 - "$RUNTIME" "$tmp/cabs" <<'PY'
import os,struct,sys
src,out=sys.argv[1:]
data=open(src,'rb').read()
pos=0
written=0
seen=set()
while True:
    pos=data.find(b'MSCF',pos)
    if pos < 0: break
    if pos+36 <= len(data):
        size=struct.unpack_from('<I',data,pos+8)[0]
        files=struct.unpack_from('<H',data,pos+28)[0]
        folders=struct.unpack_from('<H',data,pos+26)[0]
        major=data[pos+25]
        coff=struct.unpack_from('<I',data,pos+16)[0]
        end=pos+size
        if major==1 and 36 <= size <= len(data)-pos and 0 < folders < 4096 and files < 65535 and 36 <= coff < size:
            key=(pos,size)
            if key not in seen:
                seen.add(key)
                written+=1
                with open(os.path.join(out,f'container-{written:02d}.cab'),'wb') as f:
                    f.write(data[pos:end])
    pos+=4
if written == 0:
    raise SystemExit('No valid WiX CAB container was found in the verified Microsoft Runtime package.')
print(written)
PY

cab_index=0
while IFS= read -r -d '' cab; do
  cab_index=$((cab_index+1))
  out="$tmp/payloads/$cab_index"
  mkdir -p "$out"
  cabextract -q -d "$out" "$cab" >/dev/null 2>&1 || true
done < <(find "$tmp/cabs" -type f -name '*.cab' -print0 | sort -z)

find_matching_firmware(){
  local root="$1" file
  while IFS= read -r -d '' file; do
    if valid_firmware "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done < <(find "$root" -type f -size +65535c -size -1048577c -print0 2>/dev/null)
  return 1
}

if match="$(find_matching_firmware "$tmp/payloads")"; then
  install -m 0644 "$match" "$CACHE_FIRMWARE"
  publish_firmware "$CACHE_FIRMWARE"
  exit 0
fi

msi_index=0
while IFS= read -r -d '' payload; do
  # MSI databases are OLE compound files. Avoid feeding every Burn payload to
  # msiextract; this also keeps extraction fast on low-power systems.
  magic="$(od -An -tx1 -N8 "$payload" 2>/dev/null | tr -d ' \n')"
  [[ "$magic" == d0cf11e0a1b11ae1 ]] || continue
  msi_index=$((msi_index+1))
  out="$tmp/msi/$msi_index"
  mkdir -p "$out"
  if msiextract -C "$out" "$payload" >/dev/null 2>&1; then
    if match="$(find_matching_firmware "$out")"; then
      install -m 0644 "$match" "$CACHE_FIRMWARE"
      publish_firmware "$CACHE_FIRMWARE"
      exit 0
    fi
  fi
done < <(find "$tmp/payloads" -type f -print0)

echo 'UACFirmware was not found in the verified Microsoft Kinect Runtime v1.8 package.' >&2
echo 'You can provide the exact raw image with KINECT_UAC_FIRMWARE=/path/to/UACFirmware and rebuild.' >&2
exit 4

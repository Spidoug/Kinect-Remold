#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink -- "$SOURCE")"
  [[ "$TARGET" = /* ]] && SOURCE="$TARGET" || SOURCE="$DIR/$TARGET"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
find_project_root(){
  local current="$SCRIPT_DIR" parent depth=0
  while (( depth < 8 )); do
    if [[ -f "$current/VERSION" && -d "$current/drivers/modules" && -d "$current/applications/processing/SynKinectStudio" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
    ((depth++))
  done
  return 1
}
ROOT="$(find_project_root)" || { echo "Kinect Remold project root not found from: $SCRIPT_DIR" >&2; exit 2; }
PROJECT_VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
SKETCH="$ROOT/applications/processing/SynKinectStudio"
MODULE_SDK="$ROOT/applications/studio-module-sdk"
MODULE_API_SRC="$MODULE_SDK/src/main/java"
TEMPLATES="$ROOT/applications/runtime-templates"
LINUX_APP="$ROOT/binaries/linux/applications/SynKinectStudio"
LINUX_LIB="$LINUX_APP/lib"
LINUX_MODULES="$LINUX_APP/modules"
ENV_HELPER="$ROOT/scripts/linux/lib/remold-env.sh"
BUILD_CONFIG="$ROOT/config/build.env"
[[ -r "$ENV_HELPER" ]] || { echo "Missing environment resolver: $ENV_HELPER" >&2; exit 2; }
[[ -r "$BUILD_CONFIG" ]] || { echo "Missing build dependency metadata: $BUILD_CONFIG" >&2; exit 2; }
# shellcheck source=scripts/linux/lib/remold-env.sh
source "$ENV_HELPER"
# Preserve explicit environment overrides while loading project defaults.
while IFS='=' read -r key value; do
  [[ "$key" =~ ^REMOLD_[A-Z0-9_]+$ ]] || continue
  [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$value"
done < "$BUILD_CONFIG"
CACHE_ROOT="$(remold_xdg_cache_root)" || { echo 'Could not resolve the cache directory.' >&2; exit 2; }
DOWNLOAD_ROOT="$(remold_download_root)" || { echo 'Could not resolve the dependency download directory.' >&2; exit 2; }
CACHE="$CACHE_ROOT/build/linux/studio"
DOWNLOADS="$DOWNLOAD_ROOT/studio"

mkdir -p "$LINUX_LIB" "$LINUX_MODULES" "$CACHE" "$DOWNLOADS"

for tool in bash awk grep sed find sort sha256sum tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required build tool not found: $tool" >&2; exit 2; }
done

if command -v curl >/dev/null 2>&1; then
  downloader=curl
elif command -v wget >/dev/null 2>&1; then
  downloader=wget
else
  echo 'curl or wget is required to bootstrap Studio dependencies and Java.' >&2
  exit 2
fi

download_to(){
  local url="$1" out="$2" attempt
  rm -f "$out"
  for attempt in 1 2 3 4 5; do
    echo "Downloading $(basename "$out") (attempt $attempt/5)..." >&2
    if [[ "$downloader" == curl ]]; then
      curl -fL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
    else
      wget --timeout=20 --tries=3 -O "$out" "$url" && return 0
    fi
    rm -f "$out"
    sleep $((attempt*2))
  done
  echo "Could not download: $url" >&2
  return 1
}

sha256_file(){ sha256sum "$1" | awk '{print tolower($1)}'; }

published_sha256(){
  local url="$1"
  local tmp="$DOWNLOADS/$(basename "$url").download"
  local value
  download_to "$url" "$tmp"
  value="$(grep -Eio '[0-9a-f]{64}' "$tmp" | head -n1 | tr '[:upper:]' '[:lower:]')"
  rm -f "$tmp"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { echo "Published SHA-256 was not found: $url" >&2; return 1; }
  printf '%s\n' "$value"
}

fetch_pinned(){
  local name="$1" url="$2" expected="${3,,}"
  local cached="$DOWNLOADS/$name"
  local tmp="$DOWNLOADS/$name.download"
  if [[ -f "$cached" && "$(sha256_file "$cached")" == "$expected" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi
  rm -f "$cached" "$tmp"
  download_to "$url" "$tmp"
  local actual
  actual="$(sha256_file "$tmp")"
  [[ "$actual" == "$expected" ]] || {
    rm -f "$tmp"
    echo "SHA-256 mismatch for $name. Expected $expected, got $actual." >&2
    return 1
  }
  mv "$tmp" "$cached"
  printf '%s\n' "$cached"
}

stage(){
  local name="$1" url="$2" sha="$3" target="$4" source
  source="$(fetch_pinned "$name" "$url" "$sha")"
  mkdir -p "$target"
  install -m 0644 "$source" "$target/$name"
}

jdk_feature(){
  local home="$1" version feature
  version="$("$home/bin/javac" -version 2>&1 | awk '{print $2; exit}')"
  feature="${version%%.*}"
  if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
  [[ "$feature" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$feature"
}

valid_jdk_home(){
  local home="${1:-}" feature
  [[ -n "$home" && -x "$home/bin/java" && -x "$home/bin/javac" && -x "$home/bin/jar" && -x "$home/bin/jlink" && -f "$home/jmods/java.base.jmod" ]] || return 1
  feature="$(jdk_feature "$home")" || return 1
  (( feature >= REMOLD_JAVA_FEATURE ))
}

bootstrap_jdk(){
  local arch archive url checksum_url jdk_cache archive_path checksum_path expected actual extract javac_path extracted_home portable_home
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) archive="microsoft-jdk-${REMOLD_JDK_VERSION}-linux-${REMOLD_JDK_LINUX_ARCH}.tar.gz" ;;
    *)
      echo "SynKinect Studio Linux runtime currently targets x86-64; unsupported build architecture: $arch" >&2
      return 2
      ;;
  esac

  url="${REMOLD_MICROSOFT_JDK_BASE_URL%/}/$archive"
  checksum_url="$url.sha256sum.txt"
  jdk_cache="$CACHE/jdk"
  jdk_downloads="$DOWNLOADS/jdk"
  archive_path="$jdk_downloads/$archive"
  checksum_path="$jdk_downloads/$archive.sha256sum.txt"
  portable_home="$jdk_cache/microsoft-jdk-${REMOLD_JDK_VERSION}"
  mkdir -p "$jdk_cache" "$jdk_downloads"

  if valid_jdk_home "$portable_home"; then
    echo "Portable Microsoft OpenJDK ${REMOLD_JDK_VERSION}: READY (cached)" >&2
    printf '%s\n' "$portable_home"
    return 0
  fi

  # Microsoft publishes a SHA-256 file beside the archive. Refresh the checksum,
  # then accept a cached archive only if it still matches that published value.
  download_to "$checksum_url" "$checksum_path"
  expected="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]+$/ && length($i)==64) {print tolower($i); exit}}' "$checksum_path")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "Could not parse the published SHA-256 for $archive." >&2; return 1; }

  if [[ ! -f "$archive_path" || "$(sha256_file "$archive_path")" != "$expected" ]]; then
    download_to "$url" "$archive_path.download"
    actual="$(sha256_file "$archive_path.download")"
    [[ "$actual" == "$expected" ]] || {
      rm -f "$archive_path.download"
      echo "SHA-256 mismatch for $archive. Expected $expected, got $actual." >&2
      return 1
    }
    mv "$archive_path.download" "$archive_path"
  fi

  extract="$(mktemp -d)"
  tar -xzf "$archive_path" -C "$extract"
  javac_path="$(find "$extract" -type f -path '*/bin/javac' -print -quit)"
  [[ -n "$javac_path" ]] || { echo "javac was not found inside $archive." >&2; return 1; }
  extracted_home="$(cd "$(dirname "$javac_path")/.." && pwd)"
  rm -rf "$portable_home"
  mkdir -p "$portable_home"
  cp -a "$extracted_home/." "$portable_home/"
  rm -rf "$extract"

  valid_jdk_home "$portable_home" || { echo 'Portable Microsoft OpenJDK was extracted but is not usable.' >&2; return 1; }
  echo "Portable Microsoft OpenJDK ${REMOLD_JDK_VERSION}: READY" >&2
  printf '%s\n' "$portable_home"
}

resolve_jdk(){
  local candidate javac_path
  for candidate in "${JDK_HOME:-}" "${JAVA_HOME:-}"; do
    if valid_jdk_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  javac_path="$(command -v javac || true)"
  if [[ -n "$javac_path" ]]; then
    candidate="$(cd "$(dirname "$javac_path")/.." && pwd)"
    if valid_jdk_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    # Resolve /usr/bin alternatives/symlinks as well.
    if command -v readlink >/dev/null 2>&1; then
      javac_path="$(readlink -f "$javac_path" 2>/dev/null || printf '%s' "$javac_path")"
      candidate="$(cd "$(dirname "$javac_path")/.." && pwd)"
      if valid_jdk_home "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  echo "Complete JDK ${REMOLD_JAVA_FEATURE}+ with javac/jar/jlink/jmods was not found; bootstrapping verified Microsoft OpenJDK..." >&2
  bootstrap_jdk
}

PROCESSING_BASE="${REMOLD_PROCESSING_MAVEN_BASE_URL%/}/${REMOLD_PROCESSING_VERSION}"
JOGL_BASE="${REMOLD_JOGL_MAVEN_BASE_URL%/}/${REMOLD_JOGL_VERSION}"
GLUEGEN_BASE="${REMOLD_GLUEGEN_MAVEN_BASE_URL%/}/${REMOLD_GLUEGEN_VERSION}"
ONNXRUNTIME_BASE="${REMOLD_ONNXRUNTIME_MAVEN_BASE_URL%/}/${REMOLD_ONNXRUNTIME_VERSION}"

stage "core-${REMOLD_PROCESSING_VERSION}.jar" "$PROCESSING_BASE/core-${REMOLD_PROCESSING_VERSION}.jar" "$REMOLD_PROCESSING_SHA256" "$LINUX_LIB"
stage "jogl-all-${REMOLD_JOGL_VERSION}.jar" "$JOGL_BASE/jogl-all-${REMOLD_JOGL_VERSION}.jar" "$REMOLD_JOGL_SHA256" "$LINUX_LIB"
stage "gluegen-rt-${REMOLD_GLUEGEN_VERSION}.jar" "$GLUEGEN_BASE/gluegen-rt-${REMOLD_GLUEGEN_VERSION}.jar" "$REMOLD_GLUEGEN_SHA256" "$LINUX_LIB"
stage "jogl-all-${REMOLD_JOGL_VERSION}-natives-linux-${REMOLD_JOGL_NATIVE_ARCH}.jar" "$JOGL_BASE/jogl-all-${REMOLD_JOGL_VERSION}-natives-linux-${REMOLD_JOGL_NATIVE_ARCH}.jar" "$REMOLD_JOGL_LINUX_NATIVE_SHA256" "$LINUX_LIB"
stage "gluegen-rt-${REMOLD_GLUEGEN_VERSION}-natives-linux-${REMOLD_JOGL_NATIVE_ARCH}.jar" "$GLUEGEN_BASE/gluegen-rt-${REMOLD_GLUEGEN_VERSION}-natives-linux-${REMOLD_JOGL_NATIVE_ARCH}.jar" "$REMOLD_GLUEGEN_LINUX_NATIVE_SHA256" "$LINUX_LIB"
onnx_name="onnxruntime-${REMOLD_ONNXRUNTIME_VERSION}.jar"
onnx_sha="$(published_sha256 "$ONNXRUNTIME_BASE/$onnx_name.sha256")"
stage "$onnx_name" "$ONNXRUNTIME_BASE/$onnx_name" "$onnx_sha" "$LINUX_LIB"
echo 'Processing/JOGL/GlueGen/ONNX Runtime dependencies: READY'

install -m 0755 "$TEMPLATES/${REMOLD_LINUX_RUNTIME_TEMPLATE}/SynKinectStudio.sh" "$LINUX_APP/SynKinectStudio.sh"
install -m 0644 "$TEMPLATES/${REMOLD_LINUX_RUNTIME_TEMPLATE}/SynKinectStudio.desktop" "$LINUX_APP/SynKinectStudio.desktop"
install -m 0644 "$SKETCH/data/studio/resources/synkinect-studio-icon.png" "$LINUX_APP/synkinect-studio-icon.png"
install -m 0644 "$MODULE_SDK/MODULES.txt" "$LINUX_MODULES/README.txt"

JDK_HOME_RESOLVED="$(resolve_jdk)"
JAVAC="$JDK_HOME_RESOLVED/bin/javac"
JAR="$JDK_HOME_RESOLVED/bin/jar"
JLINK="$JDK_HOME_RESOLVED/bin/jlink"
feature="$(jdk_feature "$JDK_HOME_RESOLVED")"
echo "JDK $feature+: READY [$JDK_HOME_RESOLVED]"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/classes" "$WORK/module-api-classes"
mapfile -t MODULE_API_SOURCES < <(find "$MODULE_API_SRC" -type f -name '*.java' -print | sort)
((${#MODULE_API_SOURCES[@]} > 0)) || { echo "SynKinect Studio Module API sources were not found: $MODULE_API_SRC" >&2; exit 1; }
"$JAVAC" -encoding UTF-8 --release "$REMOLD_JAVA_FEATURE" -Xlint:all -cp "$LINUX_LIB/core-${REMOLD_PROCESSING_VERSION}.jar" -d "$WORK/module-api-classes" "${MODULE_API_SOURCES[@]}"
cat > "$WORK/MODULE-API.MF" <<MANIFEST
Manifest-Version: 1.0
Implementation-Title: SynKinect Studio Module API
Implementation-Version: $PROJECT_VERSION
Automatic-Module-Name: org.synkinect.studio.moduleapi
MANIFEST
"$JAR" --create --file "$WORK/SynKinectStudio-module-api.jar" --manifest "$WORK/MODULE-API.MF" -C "$WORK/module-api-classes" .
install -m 0644 "$WORK/SynKinectStudio-module-api.jar" "$LINUX_LIB/SynKinectStudio-module-api.jar"
echo 'SynKinect Studio Module API: READY'
JAVA_SRC="$WORK/SynKinectStudio.java"
# Processing tabs may arrive with an UTF-8 BOM after editor/ZIP round-trips.
# A BOM is legal only at byte zero of a source file; once PDE tabs are merged
# into one Java compilation unit, an embedded BOM becomes illegal U+FEFF.
# Strip it from the first line of every tab while assembling the Java source.
strip_pde_bom() {
  LC_ALL=C sed $'1s/^\xEF\xBB\xBF//' "$1"
}
{
  printf '%s\n' 'import processing.core.*;' 'import processing.data.*;' 'import processing.event.*;' 'import processing.opengl.*;'
  strip_pde_bom "$SKETCH/SynKinectStudio.pde" | grep '^import ' || true
  printf '%s\n' 'public class SynKinectStudio extends PApplet {'
  strip_pde_bom "$SKETCH/SynKinectStudio.pde" | sed '/^import /d'
  while IFS= read -r source_file; do strip_pde_bom "$source_file" | sed '/^import /d'; done < <(find "$SKETCH" -maxdepth 1 -type f -name '*.pde' ! -name 'SynKinectStudio.pde' -print | sort -f)
  printf '%s\n' 'public static void main(String[] args){PApplet.main(SynKinectStudio.class.getName());}' '}'
} > "$JAVA_SRC"

CP="$LINUX_LIB/core-${REMOLD_PROCESSING_VERSION}.jar:$LINUX_LIB/jogl-all-${REMOLD_JOGL_VERSION}.jar:$LINUX_LIB/gluegen-rt-${REMOLD_GLUEGEN_VERSION}.jar:$LINUX_LIB/onnxruntime-${REMOLD_ONNXRUNTIME_VERSION}.jar:$WORK/SynKinectStudio-module-api.jar"
"$JAVAC" -encoding UTF-8 --release "$REMOLD_JAVA_FEATURE" -Xlint:all -cp "$CP" -d "$WORK/classes" "$JAVA_SRC"
cp "$SKETCH/data/studio/resources/synkinect-studio-icon.png" "$WORK/classes/synkinect-studio-icon.png"
cat > "$WORK/MANIFEST.MF" <<MANIFEST
Manifest-Version: 1.0
Main-Class: SynKinectStudio
Implementation-Title: SynKinect Studio
Implementation-Version: $PROJECT_VERSION
MANIFEST
"$JAR" --create --file "$WORK/SynKinectStudio.jar" --manifest "$WORK/MANIFEST.MF" -C "$WORK/classes" .

install -D -m 0644 "$WORK/SynKinectStudio.jar" "$LINUX_APP/lib/SynKinectStudio.jar"
rm -rf "$LINUX_APP/data"
cp -a "$SKETCH/data" "$LINUX_APP/data"

# Studio and the native runtimes are packaged as sibling product components.
DRIVER_DIST="$ROOT/binaries/linux/drivers/kinect-xbox-360-remold"
K1_DRIVER_DIST="$ROOT/binaries/linux/drivers/kinect-one-remold"
if [[ "${REMOLD_FULL_BUILD:-0}" == 1 ]]; then
  required_driver=(
    "$DRIVER_DIST/bin/kinect360-remoldctl"
    "$DRIVER_DIST/libexec/kinect360-remold/kinect360-remold-broker"
    "$DRIVER_DIST/libexec/kinect360-remold/kinect360-remold-camera"
    "$DRIVER_DIST/libexec/kinect360-remold/kinect360-remold-audio"
    "$DRIVER_DIST/libexec/kinect360-remold/kinect360-remold-v4l2"
    "$DRIVER_DIST/libexec/kinect360-remold/kinect360-remold-camera-ip"
    "$DRIVER_DIST/KINECT.sh"
    "$DRIVER_DIST/INSTALL.sh"
    "$DRIVER_DIST/UNINSTALL.sh"
    "$DRIVER_DIST/VERSION"
    "$DRIVER_DIST/support/firmware/UACFirmware-01.02.709.00"
    "$DRIVER_DIST/support/kernel/KERNEL-RELEASE"
    "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-VERSION"
    "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-SOURCE-SHA256"
    "$DRIVER_DIST/support/kernel/V4L2LOOPBACK-MODULE-SHA256"
    "$DRIVER_DIST/support/kernel/$(uname -r)/v4l2loopback.ko"
  )
  required_kinect_one=(
    "$K1_DRIVER_DIST/kinect-one-remold"
    "$K1_DRIVER_DIST/KINECT.sh"
    "$K1_DRIVER_DIST/INSTALL.sh"
    "$K1_DRIVER_DIST/UNINSTALL.sh"
    "$K1_DRIVER_DIST/90-kinect-one-remold.rules"
    "$K1_DRIVER_DIST/kinect-one-remold.service"
  )
  for artifact in "${required_driver[@]}" "${required_kinect_one[@]}"; do
    [[ -e "$artifact" ]] || { echo "Full build requested but Linux driver artifact is missing: $artifact" >&2; exit 3; }
  done
fi

linux_hash="$(sha256_file "$LINUX_APP/lib/SynKinectStudio.jar")"

modules='ALL-MODULE-PATH'
module_path="$JDK_HOME_RESOLVED/jmods"
[[ -f "$module_path/java.base.jmod" ]] || { echo "JDK module set not found: $module_path/java.base.jmod" >&2; exit 1; }
rm -rf "$LINUX_APP/java"
if (( feature >= 21 )); then
  "$JLINK" --module-path "$module_path" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages --compress=zip-6 --output "$LINUX_APP/java"
else
  "$JLINK" --module-path "$module_path" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages --compress=2 --output "$LINUX_APP/java"
fi

[[ -x "$LINUX_APP/java/bin/java" ]] || chmod 0755 "$LINUX_APP/java/bin/java" 2>/dev/null || true
[[ -x "$LINUX_APP/java/bin/java" ]] || { echo 'Linux Java runtime was generated but java/bin/java is not executable.' >&2; exit 1; }
runtime_version="$("$LINUX_APP/java/bin/java" -version 2>&1 | head -n1)"
echo "Embedded Linux Java runtime: READY ($runtime_version)"
echo "SynKinect Studio rebuilt. SHA-256: $linux_hash"
echo "Linux runtime: $LINUX_APP"

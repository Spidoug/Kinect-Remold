#!/usr/bin/env bash
set -euo pipefail

LABEL='Kinect Xbox 360 Camera'
CONFIG='/etc/kinect360-remold/remold.conf'
RUNTIME_DIR='/run/kinect360-remold'
RUNTIME_PATH="$RUNTIME_DIR/v4l2-device"
DEFAULT_DEVICE='/dev/video42'

log(){ printf 'kinect360-remold-v4l2: %s\n' "$*" >&2; }

configured_device(){
  local value=''
  if [[ -r "$CONFIG" ]]; then
    value="$(awk -F= '$1=="v4l2.device"{sub(/^[^=]*=/,""); print; exit}' "$CONFIG" | tr -d '\r' | xargs 2>/dev/null || true)"
  fi
  [[ "$value" == /dev/video* ]] || value="$DEFAULT_DEVICE"
  printf '%s\n' "$value"
}

node_name(){
  local node="$1" base
  base="$(basename "$node")"
  [[ -r "/sys/class/video4linux/$base/name" ]] || return 1
  cat "/sys/class/video4linux/$base/name"
}

find_labeled(){
  local p name
  for p in /sys/class/video4linux/video*; do
    [[ -r "$p/name" ]] || continue
    name="$(cat "$p/name" 2>/dev/null || true)"
    if [[ "$name" == "$LABEL" && -e "/dev/${p##*/}" ]]; then
      printf '/dev/%s\n' "${p##*/}"
      return 0
    fi
  done
  return 1
}

is_loopback_node(){
  local node="$1" base driver
  base="$(basename "$node")"
  [[ -e "/sys/class/video4linux/$base" ]] || return 1
  driver="$(readlink -f "/sys/class/video4linux/$base/device/driver/module" 2>/dev/null || true)"
  [[ "${driver##*/}" == v4l2loopback ]]
}

remember(){
  local node="$1"
  install -d -m0755 "$RUNTIME_DIR"
  printf '%s\n' "$node" > "$RUNTIME_PATH.tmp"
  chmod 0644 "$RUNTIME_PATH.tmp"
  mv -f "$RUNTIME_PATH.tmp" "$RUNTIME_PATH"
}

create_with_modprobe(){
  local preferred="$1" nr
  nr="${preferred#/dev/video}"
  [[ "$nr" =~ ^[0-9]+$ ]] || nr=42
  modprobe v4l2loopback video_nr="$nr" card_label="$LABEL" exclusive_caps=1 max_buffers=4
}

find_free_video_node(){
  local preferred="$1" nr start=42
  if [[ "$preferred" =~ ^/dev/video([0-9]+)$ ]]; then start="${BASH_REMATCH[1]}"; fi
  for ((nr=start; nr<256; ++nr)); do
    [[ -e "/dev/video$nr" ]] || { printf '/dev/video%s\n' "$nr"; return 0; }
  done
  for ((nr=0; nr<start; ++nr)); do
    [[ -e "/dev/video$nr" ]] || { printf '/dev/video%s\n' "$nr"; return 0; }
  done
  return 1
}

create_dynamic(){
  local preferred="${1:-}" help=''
  command -v v4l2loopback-ctl >/dev/null 2>&1 || return 1
  help="$(v4l2loopback-ctl add -h 2>&1 || true)"
  local -a args=(add -n "$LABEL")
  # v4l2loopback-utils 0.14+/0.15+ exposes -x/--exclusive-caps and
  # -b/--buffers for dynamic devices. Detect before use for distro portability.
  if grep -q -- '--exclusive-caps' <<<"$help"; then args+=(-x 1); fi
  if grep -q -- '--buffers' <<<"$help"; then args+=(-b 4); fi
  [[ -n "$preferred" ]] && args+=("$preferred")
  v4l2loopback-ctl "${args[@]}"
}

main(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { log 'must run as root'; exit 2; }
  local preferred existing name third_party=0 node
  preferred="$(configured_device)"
  mkdir -p "$RUNTIME_DIR"

  if existing="$(find_labeled 2>/dev/null)"; then
    remember "$existing"
    log "using existing $existing ($LABEL)"
    return 0
  fi

  # If the requested number is occupied by an unrelated physical/virtual
  # camera, never replace it. A dynamically allocated Remold node is safer.
  if [[ -e "$preferred" ]]; then
    name="$(node_name "$preferred" 2>/dev/null || true)"
    log "$preferred is already occupied by '${name:-unknown device}'"
    third_party=1
  fi

  if ! lsmod 2>/dev/null | awk '{print $1}' | grep -qx v4l2loopback; then
    # Remold owns module creation when v4l2loopback is not already in use. Do
    # not rely on boot-time video_nr=42 policy: select a collision-free node now
    # and create it with the stable label/exclusive-caps interface in one step.
    local target="$preferred"
    if (( third_party != 0 )); then target="$(find_free_video_node "$preferred" || true)"; fi
    if [[ -n "$target" ]]; then
      if ! create_with_modprobe "$target" 2>/dev/null; then
        log "module creation at $target failed; trying dynamic allocation"
      fi
    else
      log 'no free /dev/videoN slot found for fixed module creation; trying dynamic allocation'
    fi
  else
    # Module parameters cannot be changed in place. If no loopback device is in
    # use, reload once so the Remold label/exclusive-caps policy is deterministic.
    local have_other_loopback=0
    for node in /dev/video*; do
      [[ -e "$node" ]] || continue
      if is_loopback_node "$node"; then have_other_loopback=1; break; fi
    done
    if (( have_other_loopback == 0 && third_party == 0 )); then
      if modprobe -r v4l2loopback 2>/dev/null; then
        if ! create_with_modprobe "$preferred" 2>/dev/null; then
          log "module reload did not create the preferred node; trying dynamic allocation"
        fi
      fi
    fi
  fi

  if existing="$(find_labeled 2>/dev/null)"; then
    remember "$existing"
    log "created $existing ($LABEL)"
    return 0
  fi

  # Do not unload another application's loopback devices. Ask the upstream
  # control utility to add only our node when available.
  if command -v v4l2loopback-ctl >/dev/null 2>&1; then
    local dynamic_target="$preferred"
    if [[ -e "$dynamic_target" ]]; then dynamic_target=''; fi
    if create_dynamic "$dynamic_target" >/dev/null 2>&1; then
      if existing="$(find_labeled 2>/dev/null)"; then
        remember "$existing"
        log "dynamically created $existing ($LABEL)"
        return 0
      fi
    fi
  fi

  log 'unable to create the virtual camera device.'
  log "expected label: $LABEL; preferred node: $preferred"
  log 'Check DKMS/Secure Boot status: modinfo v4l2loopback; journalctl -k | grep -i v4l2loopback'
  return 1
}

main "$@"

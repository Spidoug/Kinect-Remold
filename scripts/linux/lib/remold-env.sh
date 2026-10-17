#!/usr/bin/env bash
# Shared environment/path discovery for Kinect Remold Linux scripts.
# This file intentionally contains no account names or checkout-specific paths.

remold_user_home() {
  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then printf '%s\n' "$HOME"; return 0; fi
  local h=''
  if command -v getent >/dev/null 2>&1; then h="$(getent passwd "$(id -u)" 2>/dev/null | awk -F: 'NR==1{print $6}')"; fi
  [[ -n "$h" && -d "$h" ]] || return 1
  printf '%s\n' "$h"
}

remold_temp_root() {
  if [[ -n "${REMOLD_TEMP_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_TEMP_ROOT"; return 0; fi
  if [[ -n "${TMPDIR:-}" ]]; then printf '%s\n' "$TMPDIR"; return 0; fi
  if command -v systemd-path >/dev/null 2>&1; then
    local p; p="$(systemd-path temporary 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  # Let mktemp choose the host default when no environment/API provides one.
  local probe; probe="$(mktemp -d 2>/dev/null)" || return 1
  local parent; parent="$(dirname "$probe")"; rmdir "$probe" 2>/dev/null || true
  printf '%s\n' "$parent"
}

remold_xdg_cache_root() {
  if [[ -n "${REMOLD_CACHE_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_CACHE_ROOT"; return 0; fi
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then printf '%s/Kinect Remold\n' "$XDG_CACHE_HOME"; return 0; fi
  local h; h="$(remold_user_home)" || return 1
  printf '%s/.cache/Kinect Remold\n' "$h"
}

remold_xdg_state_root() {
  if [[ -n "${REMOLD_STATE_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_STATE_ROOT"; return 0; fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then printf '%s/Kinect Remold\n' "$XDG_STATE_HOME"; return 0; fi
  local h; h="$(remold_user_home)" || return 1
  printf '%s/.local/state/Kinect Remold\n' "$h"
}

remold_download_root() {
  if [[ -n "${REMOLD_DOWNLOAD_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_DOWNLOAD_ROOT"; return 0; fi
  local c; c="$(remold_xdg_cache_root)" || return 1
  printf '%s/Downloads/dependencies\n' "$c"
}

remold_resolve_prefix() {
  if [[ -n "${REMOLD_PREFIX:-}" ]]; then printf '%s\n' "$REMOLD_PREFIX"; return 0; fi
  local exe
  exe="$(command -v env 2>/dev/null || command -v sh 2>/dev/null || true)"
  [[ -n "$exe" ]] || return 1
  if command -v readlink >/dev/null 2>&1; then exe="$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")"; fi
  dirname "$(dirname "$exe")"
}

remold_system_config_root() {
  if [[ -n "${REMOLD_SYSCONFDIR:-}" ]]; then printf '%s\n' "$REMOLD_SYSCONFDIR"; return 0; fi
  if command -v systemd-path >/dev/null 2>&1; then
    local p; p="$(systemd-path system-configuration 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  return 1
}

remold_system_state_root() {
  if [[ -n "${REMOLD_LOCALSTATEDIR:-}" ]]; then printf '%s\n' "$REMOLD_LOCALSTATEDIR"; return 0; fi
  if command -v systemd-path >/dev/null 2>&1; then
    local p; p="$(systemd-path system-state-private 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  return 1
}

remold_runtime_root() {
  if [[ -n "${REMOLD_RUNDIR:-}" ]]; then printf '%s\n' "$REMOLD_RUNDIR"; return 0; fi
  if command -v systemd-path >/dev/null 2>&1; then
    local p; p="$(systemd-path system-runtime 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  return 1
}

remold_systemd_unit_dir() {
  if [[ -n "${REMOLD_SYSTEMD_UNIT_DIR:-}" ]]; then printf '%s\n' "$REMOLD_SYSTEMD_UNIT_DIR"; return 0; fi
  if command -v pkg-config >/dev/null 2>&1; then
    local p; p="$(pkg-config --variable=systemdsystemunitdir systemd 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  local c; c="$(remold_system_config_root)" || return 1
  printf '%s/systemd/system\n' "$c"
}

remold_udev_rules_dir() {
  if [[ -n "${REMOLD_UDEV_RULES_DIR:-}" ]]; then printf '%s\n' "$REMOLD_UDEV_RULES_DIR"; return 0; fi
  if command -v pkg-config >/dev/null 2>&1; then
    local p; p="$(pkg-config --variable=udevdir udev 2>/dev/null || true)"
    if [[ -n "$p" ]]; then printf '%s/rules.d\n' "$p"; return 0; fi
  fi
  local c; c="$(remold_system_config_root)" || return 1
  printf '%s/udev/rules.d\n' "$c"
}

remold_sysfs_root() {
  if [[ -n "${REMOLD_SYSFS_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_SYSFS_ROOT"; return 0; fi
  if command -v findmnt >/dev/null 2>&1; then
    local p; p="$(findmnt -n -t sysfs -o TARGET 2>/dev/null | head -n1)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  fi
  return 1
}


remold_find_command() {
  local name="${1:-}" resolved='' candidate=''
  [[ -n "$name" ]] || return 1
  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if command -v whereis >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" && -x "$candidate" ]] || continue
      [[ "$(basename "$candidate")" == "$name" ]] || continue
      printf '%s\n' "$candidate"
      return 0
    done < <(whereis -b "$name" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | tr ' ' '\n')
  fi
  return 1
}

remold_kernel_modules_root() {
  if [[ -n "${REMOLD_KERNEL_MODULES_ROOT:-}" ]]; then printf '%s\n' "$REMOLD_KERNEL_MODULES_ROOT"; return 0; fi
  local release="${1:-$(uname -r)}" candidate='' modinfo_bin='' proc_root='' modules_file='' module=''
  modinfo_bin="$(remold_find_command modinfo 2>/dev/null || true)"
  if [[ -n "$modinfo_bin" ]]; then
    if command -v findmnt >/dev/null 2>&1; then
      proc_root="$(findmnt -n -t proc -o TARGET 2>/dev/null | head -n1)"
    fi
    modules_file="${proc_root:+$proc_root/modules}"
    if [[ -r "$modules_file" ]]; then
      while read -r module _; do
        [[ -n "$module" ]] || continue
        candidate="$("$modinfo_bin" -k "$release" -n "$module" 2>/dev/null || true)"
        [[ -f "$candidate" ]] || continue
        case "$candidate" in
          */"$release"/*)
            printf '%s\n' "${candidate%%/$release/*}"
            return 0
            ;;
        esac
      done < "$modules_file"
    fi
  fi
  return 1
}

remold_kernel_build_dir_from_package_db() {
  local release="${1:-$(uname -r)}" entry='' dir='' pkg=''

  if command -v dpkg-query >/dev/null 2>&1; then
    while IFS= read -r entry; do
      [[ "$entry" == */Makefile ]] || continue
      dir="${entry%/Makefile}"
      [[ -r "$dir/Makefile" && -d "$dir/include" ]] || continue
      printf '%s\n' "$dir"
      return 0
    done < <(dpkg-query -L "linux-headers-$release" 2>/dev/null || true)
  fi

  if command -v rpm >/dev/null 2>&1; then
    for pkg in "kernel-devel-$release" "kernel-headers-$release"; do
      while IFS= read -r entry; do
        [[ "$entry" == */Makefile ]] || continue
        dir="${entry%/Makefile}"
        [[ -r "$dir/Makefile" && -d "$dir/include" ]] || continue
        printf '%s\n' "$dir"
        return 0
      done < <(rpm -ql "$pkg" 2>/dev/null || true)
    done
  fi

  if command -v pacman >/dev/null 2>&1; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      while IFS= read -r entry; do
        entry="${entry#* }"
        [[ "$entry" == */Makefile ]] || continue
        dir="${entry%/Makefile}"
        [[ -r "$dir/Makefile" && -d "$dir/include" ]] || continue
        printf '%s\n' "$dir"
        return 0
      done < <(pacman -Ql "$pkg" 2>/dev/null || true)
    done < <(pacman -Qq 2>/dev/null | grep -E '(^|-)headers$' || true)
  fi

  return 1
}

remold_kernel_build_dir() {
  if [[ -n "${REMOLD_KERNEL_BUILD:-}" ]]; then
    [[ -r "$REMOLD_KERNEL_BUILD/Makefile" ]] || return 1
    printf '%s\n' "$REMOLD_KERNEL_BUILD"
    return 0
  fi

  local release="${1:-$(uname -r)}" root='' candidate=''
  root="$(remold_kernel_modules_root "$release" 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    candidate="$root/$release/build"
    if [[ -r "$candidate/Makefile" ]]; then
      if command -v readlink >/dev/null 2>&1; then
        candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
      fi
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  remold_kernel_build_dir_from_package_db "$release"
}

remold_install_paths() {
  local prefix sysconf state runtime
  prefix="$(remold_resolve_prefix)" || return 1
  sysconf="$(remold_system_config_root)" || return 1
  state="$(remold_system_state_root)" || return 1
  runtime="$(remold_runtime_root)" || return 1
  REMOLD_BINDIR="${REMOLD_BINDIR:-$prefix/bin}"
  REMOLD_LIBEXECDIR="${REMOLD_LIBEXECDIR:-$prefix/libexec}"
  REMOLD_DATADIR="${REMOLD_DATADIR:-$prefix/share}"
  REMOLD_SYSCONFDIR="${REMOLD_SYSCONFDIR:-$sysconf}"
  REMOLD_LOCALSTATEDIR="${REMOLD_LOCALSTATEDIR:-$state}"
  REMOLD_RUNDIR="${REMOLD_RUNDIR:-$runtime}"
  REMOLD_SYSTEMD_UNIT_DIR="${REMOLD_SYSTEMD_UNIT_DIR:-$(remold_systemd_unit_dir)}"
  REMOLD_UDEV_RULES_DIR="${REMOLD_UDEV_RULES_DIR:-$(remold_udev_rules_dir)}"
  export REMOLD_BINDIR REMOLD_LIBEXECDIR REMOLD_DATADIR REMOLD_SYSCONFDIR REMOLD_LOCALSTATEDIR REMOLD_RUNDIR REMOLD_SYSTEMD_UNIT_DIR REMOLD_UDEV_RULES_DIR
}

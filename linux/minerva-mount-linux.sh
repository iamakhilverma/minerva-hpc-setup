#!/usr/bin/env bash
# Manage a libfuse sshfs mount of a Minerva (Sinai HPC) path at a local mountpoint.
# LINUX / WSL2 port of the macOS minerva-mount.sh. Config-driven; bash (no zsh dep).
#
#   *** UNTESTED as of 2026-06-01 — written for Linux/WSL2 but not yet run on one.
#       Validate before relying on it; see port/linux/README.md. ***
#
# Config (sourced): $MINERVA_CONFIG or ~/.config/minerva/minerva.conf, providing
#   MINERVA_MOUNT, MINERVA_REMOTE_PATH, MINERVA_NODES (array), MINERVA_LOG.
#
# Subcommands:  [mount] (default) | status (read-only, can't hang) | clear (force-unmount)
#
# Differences from the macOS version: plain libfuse sshfs (no FUSE-T), `fusermount`
# instead of `diskutil`, and only the sshfs daemon to track (no go-nfsv4). The
# phantom health check is the same idea — mount-table + sshfs liveness + the bound
# node's SSH ControlMaster liveness — none of which read into the mount, so status
# never hangs.
set -u

CONFIG="${MINERVA_CONFIG:-$HOME/.config/minerva/minerva.conf}"
[ -r "$CONFIG" ] && . "$CONFIG"

MOUNT="${MINERVA_MOUNT:-$HOME/minerva}"
REMOTE_PATH="${MINERVA_REMOTE_PATH:-}"
LOG="${MINERVA_LOG:-$HOME/.local/state/minerva/minerva-mount.log}"
CANDIDATES=(minerva13 minerva11 minerva12 minerva14 minerva)
if [ "${MINERVA_NODES+set}" = set ] && [ "${#MINERVA_NODES[@]}" -gt 0 ]; then CANDIDATES=("${MINERVA_NODES[@]}"); fi
MOUNT_TIMEOUT=20
CLEAR_TIMEOUT=15

SSHFS="$(command -v sshfs 2>/dev/null || true)"
# Args: [mode] [mountpoint] [remote_path]. Pass a mountpoint (+ remote) to manage a
# SECOND directory, e.g.:  minerva-mount ~/minerva-crc /sc/arion/.../crc_atlas
case "${1:-}" in
  mount|status|clear) MODE="$1"; shift ;;
  *)                  MODE="mount" ;;
esac
[ -n "${1:-}" ] && { MOUNT="$1"; REMOTE_PATH="${2:-}"; }
mkdir -p "$MOUNT" "$(dirname "$LOG")"

log_line() { printf '%s\n' "$*" >>"$LOG"; }
say()      { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }

kill_orphans()        { pkill -9 -f "sshfs .*${MOUNT}" 2>/dev/null || true; }
orphan_daemons_exist(){ pgrep -f "sshfs .*$MOUNT" >/dev/null 2>&1; }

# Login node sshfs is bound to (from its args). sshfs multiplexes on that node's
# SSH ControlMaster, so the master's liveness == the mount's connection liveness.
bound_node() {
  local pid; pid=$(pgrep -f "sshfs .*$MOUNT" 2>/dev/null | head -1)
  [ -n "$pid" ] || return 0
  ps -p "$pid" -o args= 2>/dev/null | grep -oE '[A-Za-z0-9._-]+:/?' | head -1 | sed 's,:/*$,,'
}

# 1=not mounted, 2=phantom (sshfs dead, OR connection severed, OR wedged), 0=healthy.
probe_state() {
  mount | grep -q " on $MOUNT " || { echo 1; return; }
  orphan_daemons_exist || { echo 2; return; }                 # sshfs daemon dead
  local node; node=$(bound_node)                              # connection severed
  if [ -n "$node" ] && ! ssh -O check "$node" >/dev/null 2>&1; then echo 2; return; fi
  ( stat "$MOUNT" >/dev/null 2>&1 ) &                         # wedged (watchdogged)
  local pid=$! i=0
  while [ "$i" -lt 6 ]; do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; echo 0; return; }
    i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null; echo 2
}

force_unmount() {
  ( fusermount -uz "$MOUNT" 2>>"$LOG" || umount -l "$MOUNT" 2>>"$LOG" || umount -f "$MOUNT" 2>>"$LOG" ) &
  local pid=$! i=0
  while [ "$i" -lt "$CLEAR_TIMEOUT" ]; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null
}

live_master() {
  local h
  for h in "${CANDIDATES[@]}"; do
    ssh -O check "$h" >/dev/null 2>&1 && { echo "$h"; return 0; }
  done
  return 1
}

if [ "$MODE" = "status" ]; then
  st=$(probe_state); bnode=$(bound_node); master=$(live_master || echo "")
  echo "=== minerva mount status (linux) ==="
  echo "mountpoint:      $MOUNT"
  case "$st" in
    0) echo "state:           HEALTHY (mounted, daemon + connection alive)" ;;
    1) echo "state:           NOT MOUNTED" ;;
    2) echo "state:           PHANTOM/STALE  ->  run: minerva-clear" ;;
  esac
  echo "our daemon:      $(pgrep -fl "sshfs .*$MOUNT" 2>/dev/null || echo '(none)')"
  if [ -n "$bnode" ]; then
    if ssh -O check "$bnode" >/dev/null 2>&1; then echo "sshfs bound to:  $bnode (master LIVE — connection up)"
    else echo "sshfs bound to:  $bnode (master DEAD — connection severed)"; fi
  fi
  if [ -n "$master" ]; then echo "live SSH master: $master  (available for minerva-mount)"
  else echo "live SSH master: none  (log into a node first, e.g. 'minerva13')"; fi
  log_line "--- status -> state=$st bound=${bnode:-none} master=${master:-none} ---"
  exit 0
fi

if [ "$MODE" = "clear" ]; then
  log_line "--- clear ---"
  case "$(probe_state)" in
    1) say "not mounted." ;;
    0) say "healthy mount present; force-unmounting on request."; force_unmount ;;
    2) say "phantom/stale mount; force-unmounting."; force_unmount ;;
  esac
  orphan_daemons_exist && { say "reaping orphan sshfs."; kill_orphans; }
  if mount | grep -q " on $MOUNT "; then say "WARNING: still mounted after clear — try again."; exit 1; fi
  say "clear OK — $MOUNT is unmounted. Remount with: minerva-mount"
  exit 0
fi

# mount (default)
exec >>"$LOG" 2>&1
printf -- '--- %s minerva-mount-linux.sh ---\n' "$(date '+%Y-%m-%d %H:%M:%S')"
if [ -z "$SSHFS" ]; then
  echo "ERROR: sshfs not found. Install it:  sudo apt install sshfs"
  exit 1
fi
case "$(probe_state)" in
  0) echo "already mounted and responsive, nothing to do."; exit 0 ;;
  2) echo "stale/phantom mount detected, force-unmounting + clearing"; force_unmount; kill_orphans ;;
  1) orphan_daemons_exist && { echo "orphan sshfs with no mount; clearing"; kill_orphans; } ;;
esac
NODE="$(live_master || true)"
if [ -z "$NODE" ]; then
  echo "no live Minerva SSH master; skipping mount (on-demand by design)."
  echo "  -> log into a node first (e.g. 'minerva13'), then run: minerva-mount"
  exit 0
fi
echo "mounting via live master on $NODE (remote: '${REMOTE_PATH:-<home>}')"
"$SSHFS" "${NODE}:${REMOTE_PATH}" "$MOUNT" \
  -o reconnect \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o cache_timeout=300 \
  -o compression=yes \
  -o follow_symlinks &
sshpid=$!
( sleep "$MOUNT_TIMEOUT"; kill -9 "$sshpid" 2>/dev/null ) & watch=$!
wait "$sshpid" 2>/dev/null; rc=$?
kill "$watch" 2>/dev/null || true
if mount | grep -q " on $MOUNT "; then
  echo "mount OK via $NODE (sshfs rc=$rc)"
  grep -qi microsoft /proc/version 2>/dev/null && \
    echo "  (WSL note: browse via the WSL terminal or \\\\wsl\$; Windows Explorer may not see FUSE mounts)"
  exit 0
else
  echo "mount FAILED via $NODE (sshfs rc=$rc); clearing"; kill_orphans; exit 1
fi

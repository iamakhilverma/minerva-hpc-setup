#!/usr/bin/env bash
# minerva-setup.sh — set up Minerva (Sinai HPC) convenience tooling on a Mac.
#
# Installs, for the CURRENT user:
#   * FUSE-T (via Homebrew; Apple Silicon and Intel both supported)
#   * ~/.ssh/config block: host aliases minerva, minerva11..14; X11; an N-hour
#     passwordless ControlMaster window
#   * ~/.config/minerva/minerva.conf — all tunable settings
#   * ~/bin/minerva-mount.sh — the on-demand FUSE-T mount manager
#   * ~/.zshrc block: minerva / minerva11..14 (login), minerva-mount/-status/-clear,
#     minerva-scratch, rsync helpers (mpull/mpush/mget/mput),
#     minerva-forget, minerva-uninstall
#
# Auth model: plain ssh + an N-hour ControlMaster. You type your SSO password and
# approve the Duo push ONCE per window; everything else reuses the live master. We
# do NOT use sshpass or store your password — that kept your SSO password in
# cleartext and, because sshpass cannot answer Duo/MFA, sprayed the server with
# background failed-login attempts.
#
# Idempotent: re-running replaces the managed blocks in place AND reuses your saved
# settings as defaults (username, mount paths, persist hours, password) so you don't
# re-enter everything. Before editing ~/.zshrc and ~/.ssh/config it backs them up to
# timestamped .bak files for clean rollback.
#
# Usage:
#   ./minerva-setup.sh                  # interactive (reuses saved values as defaults)
#   ./minerva-setup.sh --defaults       # accept all defaults (still needs a username once)
#   ./minerva-setup.sh --wipe-credentials [--all]
#                                       # remove saved password (--all also wipes settings)
#   ./minerva-setup.sh --uninstall [--purge]
#                                       # remove all tooling & restore (--purge also offers
#                                       # to remove the brew deps)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> minerva-setup >>>"
END="# <<< minerva-setup <<<"
STAMP="$(date +%Y%m%d%H%M%S)"

USE_DEFAULTS=0; MODE="install"; PURGE=0; FORGET_ALL=0
for arg in "$@"; do
  case "$arg" in
    --defaults|-y)             USE_DEFAULTS=1 ;;
    --uninstall)               MODE="uninstall" ;;
    --wipe-credentials|--forget) MODE="forget" ;;
    --purge)                   PURGE=1 ;;
    --all)                     FORGET_ALL=1 ;;
    -h|--help)                 MODE="help" ;;
    *) printf 'Unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" "default"  — sets VAR. In --defaults mode, always takes the
# default (even an empty one) without prompting. Otherwise prompts, falling back
# to the default on empty input.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  if (( USE_DEFAULTS )); then printf -v "$__var" '%s' "$__default"; return; fi
  if [[ -n "$__default" ]]; then read -r -p "$__prompt [$__default]: " __reply || true
  else                            read -r -p "$__prompt: " __reply || true; fi
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# yesno "Prompt" "Y"|"N"  — return 0 for yes. In --defaults mode, takes the default.
yesno() {
  local __prompt="$1" __def="${2:-Y}" __reply=""
  if (( USE_DEFAULTS )); then [[ "$__def" =~ ^[Yy]$ ]]; return; fi
  read -r -p "$__prompt " __reply || true
  __reply="${__reply:-$__def}"
  [[ "$__reply" =~ ^[Yy]$ ]]
}

# Replace (or append) the managed block in a file, atomically.
write_block() {
  local file="$1" content="$2" tmp
  touch "$file"; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  { cat "$tmp"; printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END"; } >"$file.new"
  mv "$file.new" "$file"; rm -f "$tmp"
}

# Remove the managed block from a file (idempotent; leaves the rest untouched).
# Match the FULL marker lines exactly (not a substring range) — the block body
# itself mentions the markers inside _minerva_strip, which would trip a substring
# range-delete and truncate early.
remove_block() {
  local file="$1" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Back up a file once per run before we first edit it (clean rollback point).
backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local b="$f.minerva-bak.$STAMP"
  [[ -e "$b" ]] || cp -p "$f" "$b"
}

# True if PATH (or, if it doesn't exist yet, its nearest existing ancestor) is writable.
path_writable() { local p="$1"; while [ ! -e "$p" ]; do p="$(dirname "$p")"; done; [ -w "$p" ]; }

[[ "$(uname -s)" == "Darwin" ]] || die "This installer is for macOS."

# ---- load any previous install (for reuse-as-defaults and for forget/uninstall) ----
CONF="$HOME/.config/minerva/minerva.conf"
PRIOR_USER=""; PRIOR_MOUNT=""; PRIOR_REMOTE=""; PRIOR_SCRATCH=""; PRIOR_PERSIST=""; PRIOR_PWFILE=""
if [[ -r "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF" 2>/dev/null || true
  PRIOR_USER="${MINERVA_USER:-}"
  PRIOR_MOUNT="${MINERVA_MOUNT:-}"
  PRIOR_REMOTE="${MINERVA_REMOTE_PATH:-}"
  PRIOR_SCRATCH="${MINERVA_SCRATCH_MOUNT:-}"
  PRIOR_PERSIST="${MINERVA_PERSIST:-}"
  PRIOR_PWFILE="${MINERVA_PWFILE:-}"
fi
PWFILE="${PRIOR_PWFILE:-$HOME/.minerva_password}"

# ============================ help / forget / uninstall ============================
if [[ "$MODE" == "help" ]]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ "$MODE" == "forget" ]]; then
  bold "Forget saved Minerva credentials"
  if (( FORGET_ALL )); then
    warn "This removes the saved password AND saved settings (username, mount paths),"
    warn "and the SSH identity block. The mount tooling stays installed."
    yesno "Proceed? [y/n]:" "N" || die "Aborted."
    rm -f "$PWFILE"; ok "Removed saved password."
    rm -rf "$HOME/.config/minerva"; ok "Removed saved settings (minerva.conf)."
    backup_once "$HOME/.ssh/config"; remove_block "$HOME/.ssh/config"; ok "Removed SSH identity block."
    info "Re-run ./minerva-setup.sh to reconfigure."
  else
    yesno "Remove the saved Minerva password? [y/n]:" "N" || die "Aborted."
    rm -f "$PWFILE"; ok "Removed legacy cleartext password file ($PWFILE)."
    info "Settings kept. (Logins no longer use a stored password — plain ssh + ControlMaster.)"
  fi
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  bold "Uninstall Minerva tooling"
  info "Removes: ~/.zshrc & ~/.ssh/config managed blocks, ~/bin/minerva-mount.sh,"
  info "         $PWFILE, ~/.config/minerva/  (backups of the two configs are kept)."
  yesno "Proceed? [y/n]:" "N" || die "Aborted."
  [[ -x "$HOME/bin/minerva-mount.sh" ]] && "$HOME/bin/minerva-mount.sh" clear >/dev/null 2>&1 || true
  backup_once "$HOME/.zshrc"; backup_once "$HOME/.ssh/config"
  remove_block "$HOME/.zshrc"
  remove_block "$HOME/.ssh/config"
  rm -f "$HOME/bin/minerva-mount.sh" "$PWFILE"
  rm -rf "$HOME/.config/minerva"
  ok "Removed managed blocks, mount script, saved password, and config."
  info "Backups: ~/.zshrc.minerva-bak.$STAMP, ~/.ssh/config.minerva-bak.$STAMP"
  if (( PURGE )); then
    echo
    if yesno "Also remove Homebrew deps sshpass + FUSE-T? [y/n]:" "N"; then
      brew uninstall sshpass >/dev/null 2>&1 || true
      brew uninstall --cask fuse-t-sshfs fuse-t >/dev/null 2>&1 || true
      ok "Removed brew deps (where present)."
    else
      info "Kept brew deps (sshpass, FUSE-T)."
    fi
  fi
  echo; info "Open a new terminal for the removal to take full effect."
  exit 0
fi

# ================================== install ==================================
bold "Minerva setup"
[[ -n "$PRIOR_USER" ]] && ok "Found a previous setup for '$PRIOR_USER' — its values are the defaults below."
echo

# ---- preflight --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install it first:
     /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
   then re-run this script."
fi
BREW_PREFIX="$(brew --prefix)"
ok "Homebrew at $BREW_PREFIX ($(uname -m))"
[[ -f "$SCRIPT_DIR/minerva-mount.sh" ]] || die "minerva-mount.sh not found next to this script ($SCRIPT_DIR)."

# Catch a home folder with root-owned files UP FRONT — one fix instead of many.
unwritable=()
for t in "$HOME" "$HOME/.zshrc" "$HOME/.config" "$HOME/.ssh"; do
  path_writable "$t" || unwritable+=("${t/#$HOME/~}")
done
if (( ${#unwritable[@]} )); then
  die "Not writable by you (likely root-owned): ${unwritable[*]}
   Your home folder has ownership issues. Fix it all at once, then re-run:
     sudo chown -R \"\$(whoami)\" \"\$HOME\""
fi

# ---- prompts ----------------------------------------------------------------
echo; bold "Your Minerva account"
if [[ -n "$PRIOR_USER" ]]; then
  if (( USE_DEFAULTS )); then MUSER="$PRIOR_USER"
  else read -r -p "Sinai HPC username [$PRIOR_USER]: " MUSER || true; MUSER="${MUSER:-$PRIOR_USER}"; fi
else
  (( USE_DEFAULTS )) && die "No saved username to default to — run once interactively first."
  read -r -p "Sinai HPC username (e.g. smithj01): " MUSER || true
fi
[[ -n "$MUSER" ]] || die "Username is required."

# No password is stored: auth is plain ssh + the ControlMaster window. If a prior
# install left a cleartext password file behind, remove it now.
if [[ -e "$PWFILE" ]]; then
  rm -f "$PWFILE" && ok "Removed legacy cleartext password file ($PWFILE)"
fi

echo; bold "Settings (press Enter to accept the default)"
info "• Local mountpoint = a folder on THIS Mac where Minerva shows up in Finder."
info "• Remote path = which folder ON MINERVA to show there (blank = your home dir)."
info "    example remote path:  /sc/arion/projects/Smith_Lab/users/jdoe"
ask MMOUNT  "Local mountpoint (folder on this Mac)" "${PRIOR_MOUNT:-$HOME/minerva}"
ask MREMOTE "Remote path on Minerva (blank = home, e.g. /sc/arion/projects/<lab>/users/<you>)" "$PRIOR_REMOTE"
ask MPERSIST "Keep the login alive (passwordless) for how many hours" "${PRIOR_PERSIST:-8}"
[[ "$MPERSIST" =~ ^[0-9]+$ ]] || die "Hours must be a whole number (got '$MPERSIST')."

# Scratch mount — on Minerva it's always /sc/arion/scratch/<username>, so we only
# ask for the local mountpoint and derive the remote.
echo; bold "Scratch mount (optional)"
info "Minerva scratch is always /sc/arion/scratch/<username>."
SMOUNT=""; SREMOTE=""
# Default to No only if a prior config exists but had no scratch (respect that
# earlier choice); otherwise default Yes. (Casing is uniform repo-wide; the coded
# default below — not the label — decides what an empty Enter does.)
if [[ -r "$CONF" && -z "$PRIOR_SCRATCH" ]]; then _scratch_def="N"; else _scratch_def="Y"; fi
if yesno "Also set up a scratch mount? [y/n]:" "$_scratch_def"; then
  ask SMOUNT "Local mountpoint for scratch" "${PRIOR_SCRATCH:-$HOME/minerva-scratch}"
  SREMOTE="/sc/arion/scratch/$MUSER/"
  info "scratch remote → $SREMOTE"
fi

echo; bold "About to apply:"
info "username:        $MUSER"
info "auth:            plain ssh + ${MPERSIST}h ControlMaster (no stored password)"
info "mountpoint:      $MMOUNT"
info "remote path:     ${MREMOTE:-<your Minerva home>}"
info "scratch mount:   ${SMOUNT:-<none>}${SMOUNT:+  ←  $SREMOTE}"
info "login persists:  ${MPERSIST}h"
info "files touched:   ~/.ssh/config, ~/.zshrc, ~/bin/minerva-mount.sh, ~/.config/minerva/minerva.conf"
info "                 (~/.zshrc and ~/.ssh/config backed up to .minerva-bak.$STAMP first)"
if (( ! USE_DEFAULTS )); then
  read -r -p "Proceed? [y/n]: " GO || true
  [[ "${GO:-Y}" =~ ^[Yy]?$ ]] || die "Aborted."
fi

# ---- dependencies -----------------------------------------------------------
echo; bold "Installing dependencies"
# sshpass is intentionally NOT installed or used: it stored the SSO password in
# cleartext and could not satisfy Duo/MFA, which generated background failed-login
# attempts. Logins are plain ssh — you type your password once per ControlMaster
# window, then approve the Duo push.
HAVE_SSHFS=0
if command -v sshfs >/dev/null 2>&1 || [[ -x "$BREW_PREFIX/bin/sshfs" ]]; then HAVE_SSHFS=1; ok "FUSE-T sshfs present"
else
  info "installing FUSE-T (may prompt for your Mac password / a macOS approval)…"
  brew tap macos-fuse-t/cask >/dev/null 2>&1 || true
  if brew install --cask fuse-t fuse-t-sshfs; then HAVE_SSHFS=1; ok "FUSE-T installed"
  else
    warn "Could not install FUSE-T automatically — continuing without it."
    warn "Logins will still work; only the mount is disabled until you run:"
    warn "  brew tap macos-fuse-t/cask && brew install --cask fuse-t fuse-t-sshfs"
    warn "then re-run ./minerva-setup.sh  (needs admin rights on this Mac)."
  fi
fi

# ---- writable dirs (fail fast with guidance if ~/.config is root-owned) ------
echo; bold "Writing config"
if ! mkdir -p "$HOME/.config/minerva" 2>/dev/null; then
  die "Can't create ~/.config/minerva — '$HOME/.config' isn't writable by you (often root-owned).
   Fix it, then re-run this installer:
     sudo chown -R \"\$(whoami)\" ~/.config && chmod u+rwx ~/.config"
fi
mkdir -p "$HOME/bin" "$HOME/.ssh/sockets" "$MMOUNT"
[[ -n "$SMOUNT" ]] && mkdir -p "$SMOUNT"
chmod 700 "$HOME/.ssh/sockets"

# ---- config file ------------------------------------------------------------
cat >"$CONF" <<EOF
# Minerva tooling settings — edit freely, then open a new shell.
MINERVA_USER="$MUSER"
MINERVA_MOUNT="$MMOUNT"
MINERVA_REMOTE_PATH="$MREMOTE"
MINERVA_SCRATCH_MOUNT="$SMOUNT"
MINERVA_SCRATCH_REMOTE="$SREMOTE"
MINERVA_PERSIST="$MPERSIST"
MINERVA_NODES=(minerva13 minerva11 minerva12 minerva14 minerva)
MINERVA_LOG="\$HOME/Library/Logs/minerva-mount.log"
EOF
ok "wrote ~/.config/minerva/minerva.conf"

# ---- mount script -----------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/minerva-mount.sh" "$HOME/bin/minerva-mount.sh"
ok "installed ~/bin/minerva-mount.sh"

# ---- ssh config -------------------------------------------------------------
SSH_BLOCK="# Minerva (Sinai HPC) — managed by minerva-setup.sh
Host minerva minerva11 minerva12 minerva13 minerva14
    HostName %h.hpc.mssm.edu
Host minerva*
    User $MUSER
    ForwardX11 yes
    ForwardX11Trusted yes
    PreferredAuthentications keyboard-interactive,password
    NumberOfPasswordPrompts 1
    PasswordAuthentication yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist ${MPERSIST}h"
backup_once "$HOME/.ssh/config"
write_block "$HOME/.ssh/config" "$SSH_BLOCK"; chmod 600 "$HOME/.ssh/config"
ok "updated ~/.ssh/config (User $MUSER, ControlPersist ${MPERSIST}h)"

# ---- zshrc ------------------------------------------------------------------
# Plain ssh — type your SSO password ONCE per ControlMaster window, then approve
# the Duo push. (No sshpass: it stored the SSO password in cleartext and could not
# answer Duo/MFA, which produced background failed-login attempts.)
LOGIN_ALIASES="# Log in (type your password once per ControlMaster window; then approve Duo).
alias minerva='ssh -Y minerva'
alias minerva11='ssh -Y minerva11'
alias minerva12='ssh -Y minerva12'
alias minerva13='ssh -Y minerva13'
alias minerva14='ssh -Y minerva14'"
ZSHRC_BLOCK="# Minerva (Sinai HPC) — managed by minerva-setup.sh. Settings: ~/.config/minerva/minerva.conf
[ -r \"\$HOME/.config/minerva/minerva.conf\" ] && source \"\$HOME/.config/minerva/minerva.conf\"

$LOGIN_ALIASES

# Mount management (on-demand — run AFTER you've logged into a node).
# With no args, minerva-mount brings up the primary mount and, if configured, scratch.
# Drop any older alias-based definitions first, so re-sourcing this file in a live
# shell doesn't collide with the functions below (zsh expands an existing alias
# while parsing \`name()\`, which is a parse error).
unalias minerva-mount minerva-status minerva-clear minerva-scratch 2>/dev/null
minerva-mount() {
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/bin/minerva-mount.sh\" \"\$@\"; return; fi
  \"\$HOME/bin/minerva-mount.sh\"
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/bin/minerva-mount.sh\" mount \"\$MINERVA_SCRATCH_MOUNT\" \"\$MINERVA_SCRATCH_REMOTE\"
}
minerva-status() {
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/bin/minerva-mount.sh\" status \"\$@\"; return; fi
  \"\$HOME/bin/minerva-mount.sh\" status
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/bin/minerva-mount.sh\" status \"\$MINERVA_SCRATCH_MOUNT\"
}
minerva-clear() {
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/bin/minerva-mount.sh\" clear \"\$@\"; return; fi
  \"\$HOME/bin/minerva-mount.sh\" clear
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/bin/minerva-mount.sh\" clear \"\$MINERVA_SCRATCH_MOUNT\"
}
# Mount ONLY the scratch directory.
minerva-scratch() {
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] || { echo 'No scratch mount configured — re-run minerva-setup.sh.'; return 1; }
  \"\$HOME/bin/minerva-mount.sh\" mount \"\$MINERVA_SCRATCH_MOUNT\" \"\$MINERVA_SCRATCH_REMOTE\"
}

# rsync/scp helpers against your Minerva tree (reuse the live master, no extra auth).
MINERVA_BASE=\"minerva:\${MINERVA_REMOTE_PATH:-.}\"
mpull() { rsync -avh --progress \"\$MINERVA_BASE/\$1\" \"\$2\"; }
mpush() { rsync -avh --progress \"\$1\" \"\$MINERVA_BASE/\$2\"; }
alias mput='scp -r'
alias mget='scp -r'

# Remove the marker-delimited block from a file. Match the FULL marker lines
# exactly (this function's own body mentions the markers, so a substring range
# delete would truncate the block early).
_minerva_strip() {
  [ -f \"\$1\" ] || return 0
  awk '\$0==\"# >>> minerva-setup >>>\"{s=1;next} \$0==\"# <<< minerva-setup <<<\"{s=0;next} !s{print}' \"\$1\" > \"\$1.mtmp\" && mv \"\$1.mtmp\" \"\$1\"
}

# Forget saved credentials. --all also wipes settings + SSH identity (tooling stays).
minerva-forget() {
  local all=0; [ \"\${1:-}\" = '--all' ] && all=1
  if [ \$all -eq 1 ]; then printf 'Remove saved password AND settings (username, mount paths)? [y/n]: '
  else printf 'Remove the saved Minerva password? [y/n]: '; fi
  local r; read -r r; case \"\$r\" in [Yy]*) ;; *) echo 'Aborted.'; return 1;; esac
  rm -f \"\${MINERVA_PWFILE:-\$HOME/.minerva_password}\"; echo 'Removed saved password.'
  if [ \$all -eq 1 ]; then
    rm -rf \"\$HOME/.config/minerva\"; echo 'Removed saved settings.'
    cp -p \"\$HOME/.ssh/config\" \"\$HOME/.ssh/config.minerva-bak.\$(date +%Y%m%d%H%M%S)\" 2>/dev/null
    _minerva_strip \"\$HOME/.ssh/config\"; echo 'Removed SSH identity block. Re-run minerva-setup.sh to reconfigure.'
  fi
}

# Remove ALL Minerva tooling and restore shell/ssh config (backs both up first).
# --purge also offers to remove the Homebrew deps.
minerva-uninstall() {
  local purge=0; [ \"\${1:-}\" = '--purge' ] && purge=1
  printf 'Remove ALL Minerva tooling and restore your shell/ssh config? [y/n]: '
  local r; read -r r; case \"\$r\" in [Yy]*) ;; *) echo 'Aborted.'; return 1;; esac
  \"\$HOME/bin/minerva-mount.sh\" clear >/dev/null 2>&1
  local s; s=\$(date +%Y%m%d%H%M%S)
  cp -p \"\$HOME/.zshrc\" \"\$HOME/.zshrc.minerva-bak.\$s\" 2>/dev/null
  cp -p \"\$HOME/.ssh/config\" \"\$HOME/.ssh/config.minerva-bak.\$s\" 2>/dev/null
  _minerva_strip \"\$HOME/.ssh/config\"
  rm -f \"\$HOME/bin/minerva-mount.sh\" \"\${MINERVA_PWFILE:-\$HOME/.minerva_password}\"
  rm -rf \"\$HOME/.config/minerva\"
  if [ \$purge -eq 1 ]; then
    printf 'Also remove Homebrew deps sshpass + FUSE-T? [y/n]: '; local p; read -r p
    case \"\$p\" in [Yy]*) brew uninstall sshpass >/dev/null 2>&1; brew uninstall --cask fuse-t-sshfs fuse-t >/dev/null 2>&1; echo 'Removed brew deps.';; *) echo 'Kept brew deps.';; esac
  fi
  _minerva_strip \"\$HOME/.zshrc\"
  echo \"Uninstalled. Backups: ~/.zshrc.minerva-bak.\$s and ~/.ssh/config.minerva-bak.\$s\"
  echo 'Open a new terminal for removal to take full effect.'
}"
backup_once "$HOME/.zshrc"
write_block "$HOME/.zshrc" "$ZSHRC_BLOCK"
ok "updated ~/.zshrc"

# ---- verify -----------------------------------------------------------------
echo; bold "Verifying"
ssh -G minerva 2>/dev/null | grep -qi "user $MUSER" && ok "ssh resolves minerva -> user $MUSER" || warn "ssh config not picked up yet (open a new shell)"
"$HOME/bin/minerva-mount.sh" status >/dev/null 2>&1 && ok "minerva-mount.sh runs" || warn "minerva-mount.sh status returned nonzero (fine if not yet mounted)"

echo
bold "Done. Next steps:"
info "1. Open a new terminal tab  (or:  source ~/.zshrc)"
info "2. Log in:    minerva13      → approve the MFA push on your phone"
if (( HAVE_SSHFS )); then
  info "3. Mount:     minerva-mount   ${SMOUNT:+(brings up primary + scratch)}"
  info "4. Check:     minerva-status  (HEALTHY?)"
else
  info "3. (mount disabled — install FUSE-T per the note above, then re-run, to enable mounting)"
fi
echo
info "Diagnose: minerva-status   •   Recover a wedged mount: minerva-clear"
info "Forget password: minerva-forget [--all]   •   Remove everything: minerva-uninstall [--purge]"
info "Change settings:  edit ~/.config/minerva/minerva.conf"

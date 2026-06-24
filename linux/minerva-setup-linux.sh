#!/usr/bin/env bash
# minerva-setup-linux.sh — Minerva (Sinai HPC) tooling for Linux / WSL2.
#
#   *** UNTESTED as of 2026-06-23 — written for Debian/Ubuntu & WSL2 but not yet
#       run on one. Validate before relying on it; see ./README.md. ***
#
# Mirrors the macOS installer, adapted for Linux:
#   * deps from apt (sshpass, sshfs) — HYBRID model: detect; if missing, show the
#     exact command and offer to run it; never abort the whole setup over a dep.
#   * writes the shell block to the RIGHT rc file(s): ~/.bashrc and/or ~/.zshrc.
#   * libfuse sshfs mount via ~/.local/bin/minerva-mount.sh (this dir's _linux.sh).
#
# Re-running reuses your saved settings as defaults (username, mount paths,
# persist hours, password) and backs up the rc file(s) + ~/.ssh/config first.
#
# Usage:
#   ./minerva-setup-linux.sh                 # interactive (reuses saved values)
#   ./minerva-setup-linux.sh --defaults      # accept defaults (needs a username once)
#   ./minerva-setup-linux.sh --wipe-credentials [--all]
#   ./minerva-setup-linux.sh --uninstall [--purge]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> minerva-setup >>>"
END="# <<< minerva-setup <<<"
STAMP="$(date +%Y%m%d%H%M%S)"

USE_DEFAULTS=0; MODE="install"; PURGE=0; FORGET_ALL=0
for arg in "$@"; do
  case "$arg" in
    --defaults|-y)               USE_DEFAULTS=1 ;;
    --uninstall)                 MODE="uninstall" ;;
    --wipe-credentials|--forget) MODE="forget" ;;
    --purge)                     PURGE=1 ;;
    --all)                       FORGET_ALL=1 ;;
    -h|--help)                   MODE="help" ;;
    *) printf 'Unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }; info(){ printf '  %s\n' "$*"; }
warn(){ printf '\033[33m  ! %s\033[0m\n' "$*"; }; ok(){ printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ask(){ local __v="$1" __p="$2" __d="${3:-}" __r=""
  if (( USE_DEFAULTS )); then printf -v "$__v" '%s' "$__d"; return; fi
  if [[ -n "$__d" ]]; then read -r -p "$__p [$__d]: " __r || true; else read -r -p "$__p: " __r || true; fi
  printf -v "$__v" '%s' "${__r:-$__d}"; }

# yesno "Prompt [y/n]:" "Y"|"N"  — uniform [y/n] casing repo-wide; the default arg
# (not the label) decides what an empty Enter does.
yesno(){ local __p="$1" __def="${2:-Y}" __r=""
  if (( USE_DEFAULTS )); then [[ "$__def" =~ ^[Yy]$ ]]; return; fi
  read -r -p "$__p " __r || true; __r="${__r:-$__def}"; [[ "$__r" =~ ^[Yy]$ ]]; }

write_block(){ local file="$1" content="$2" tmp; touch "$file"; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  { cat "$tmp"; printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END"; } >"$file.new"
  mv "$file.new" "$file"; rm -f "$tmp"; }

# Remove the managed block (exact full-line marker match — the block body mentions
# the markers inside _minerva_strip, which would trip a substring range-delete).
remove_block(){ local file="$1" tmp; [[ -f "$file" ]] || return 0; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  mv "$tmp" "$file"; }

backup_once(){ local f="$1"; [[ -f "$f" ]] || return 0; local b="$f.minerva-bak.$STAMP"; [[ -e "$b" ]] || cp -p "$f" "$b"; }

path_writable() { local p="$1"; while [ ! -e "$p" ]; do p="$(dirname "$p")"; done; [ -w "$p" ]; }

# rc files we manage: those that exist (both bash and zsh), else default to ~/.bashrc.
rc_files(){ local out=(); for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do [[ -f "$rc" ]] && out+=("$rc"); done
  (( ${#out[@]} )) || out=("$HOME/.bashrc"); printf '%s\n' "${out[@]}"; }

[[ "$(uname -s)" == "Linux" ]] || die "This installer is for Linux/WSL. On macOS use minerva-setup.sh."

# ---- load any previous install (reuse-as-defaults; also used by forget/uninstall) ----
CONF="$HOME/.config/minerva/minerva.conf"
PRIOR_USER=""; PRIOR_MOUNT=""; PRIOR_REMOTE=""; PRIOR_SCRATCH=""; PRIOR_PERSIST=""; PRIOR_PWFILE=""
if [[ -r "$CONF" ]]; then
  # shellcheck disable=SC1090
  . "$CONF" 2>/dev/null || true
  PRIOR_USER="${MINERVA_USER:-}"; PRIOR_MOUNT="${MINERVA_MOUNT:-}"; PRIOR_REMOTE="${MINERVA_REMOTE_PATH:-}"
  PRIOR_SCRATCH="${MINERVA_SCRATCH_MOUNT:-}"; PRIOR_PERSIST="${MINERVA_PERSIST:-}"; PRIOR_PWFILE="${MINERVA_PWFILE:-}"
fi
PWFILE="${PRIOR_PWFILE:-$HOME/.minerva_password}"

# ============================ help / forget / uninstall ============================
if [[ "$MODE" == "help" ]]; then sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi

if [[ "$MODE" == "forget" ]]; then
  bold "Forget saved Minerva credentials"
  if (( FORGET_ALL )); then
    warn "Removes the saved password AND settings (username, mount paths) + SSH identity. Tooling stays."
    yesno "Proceed? [y/n]:" "N" || die "Aborted."
    rm -f "$PWFILE"; ok "Removed saved password."
    rm -rf "$HOME/.config/minerva"; ok "Removed saved settings."
    backup_once "$HOME/.ssh/config"; remove_block "$HOME/.ssh/config"; ok "Removed SSH identity block."
    info "Re-run ./minerva-setup-linux.sh to reconfigure."
  else
    yesno "Remove the saved Minerva password? [y/n]:" "N" || die "Aborted."
    rm -f "$PWFILE"; ok "Removed saved password ($PWFILE)."
    info "Settings kept. Re-run setup (or minerva-update-password) to set a new one."
  fi
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  bold "Uninstall Minerva tooling (Linux)"
  info "Removes the managed blocks from ~/.bashrc & ~/.zshrc & ~/.ssh/config,"
  info "~/.local/bin/minerva-mount.sh, $PWFILE, ~/.config/minerva/ (configs backed up first)."
  yesno "Proceed? [y/n]:" "N" || die "Aborted."
  [[ -x "$HOME/.local/bin/minerva-mount.sh" ]] && "$HOME/.local/bin/minerva-mount.sh" clear >/dev/null 2>&1 || true
  while IFS= read -r rc; do backup_once "$rc"; remove_block "$rc"; done < <(rc_files)
  backup_once "$HOME/.ssh/config"; remove_block "$HOME/.ssh/config"
  rm -f "$HOME/.local/bin/minerva-mount.sh" "$PWFILE"
  rm -rf "$HOME/.config/minerva"
  ok "Removed managed blocks, mount script, saved password, and config (backups: *.minerva-bak.$STAMP)."
  if (( PURGE )); then
    echo
    if yesno "Also remove apt deps sshpass + sshfs? [y/n]:" "N"; then
      sudo apt-get remove -y sshpass sshfs >/dev/null 2>&1 || true; ok "Removed apt deps (where present)."
    else info "Kept apt deps (sshpass, sshfs)."; fi
  fi
  echo; info "Open a new terminal for the removal to take full effect."
  exit 0
fi

# ================================== install ==================================
bold "Minerva setup (Linux / WSL2)"
[[ -n "$PRIOR_USER" ]] && ok "Found a previous setup for '$PRIOR_USER' — its values are the defaults below."
echo
IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && { IS_WSL=1; ok "WSL2 detected"; }
command -v apt-get >/dev/null 2>&1 || warn "This installer assumes apt (Debian/Ubuntu). Install sshpass+sshfs your way, then it'll detect them."
[[ -f "$SCRIPT_DIR/minerva-mount-linux.sh" ]] || die "minerva-mount-linux.sh not found next to this script."

unwritable=()
for t in "$HOME" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config" "$HOME/.local" "$HOME/.ssh"; do
  [ -e "$t" ] || continue
  path_writable "$t" || unwritable+=("${t/#$HOME/~}")
done
if (( ${#unwritable[@]} )); then
  die "Not writable by you (likely root-owned): ${unwritable[*]}
   Fix it all at once, then re-run:   sudo chown -R \"\$(whoami)\" \"\$HOME\""
fi

# ---- dependencies (HYBRID: detect -> show command -> offer to run -> degrade) --
echo; bold "Dependencies"
HAVE_SSHPASS=0; HAVE_SSHFS=0
command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1
command -v sshfs   >/dev/null 2>&1 && HAVE_SSHFS=1
need=()
(( HAVE_SSHPASS )) && ok "sshpass present" || need+=("sshpass")
(( HAVE_SSHFS ))   && ok "sshfs present"   || need+=("sshfs")
if (( ${#need[@]} )); then
  cmd="sudo apt-get update && sudo apt-get install -y ${need[*]}"
  info "Missing: ${need[*]}"; info "Install command:  $cmd"
  if yesno "Run it now (needs sudo)? [y/n]:" "Y"; then
    if sudo apt-get update -y && sudo apt-get install -y "${need[@]}"; then
      command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1
      command -v sshfs   >/dev/null 2>&1 && HAVE_SSHFS=1
      ok "installed: ${need[*]}"
    else warn "apt install failed — continuing. Run later:  $cmd"; fi
  else warn "Skipped. Run later:  $cmd"; fi
fi
(( HAVE_SSHPASS )) || warn "Without sshpass, logins will prompt for your password (once per session)."
(( HAVE_SSHFS ))   || warn "Without sshfs, mounting is disabled until you install it (logins still work)."

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

KEEP_PW=0
if [[ -s "$PWFILE" ]]; then
  if (( USE_DEFAULTS )); then KEEP_PW=1; ok "Keeping saved password (••••••••)"
  elif yesno "Saved password found (••••••••). Keep it? [y/n]:" "Y"; then KEEP_PW=1; ok "Keeping saved password."; fi
fi
if (( ! KEEP_PW )); then
  while :; do
    read -r -s -p "Sinai SSO password: " PW1; echo
    read -r -s -p "Confirm password:   " PW2; echo
    [[ -n "$PW1" ]] || { warn "Empty — try again."; continue; }
    [[ "$PW1" == "$PW2" ]] || { warn "Did not match — try again."; continue; }; break
  done
fi

echo; bold "Settings (Enter = default)"
info "• Local mountpoint = a folder on THIS machine where the Minerva tree appears."
info "• Remote path = which folder ON MINERVA to mount there (blank = your home dir)."
ask MMOUNT  "Local mountpoint (folder on this machine)" "${PRIOR_MOUNT:-$HOME/minerva}"
ask MREMOTE "Remote path on Minerva (blank = home, e.g. /sc/arion/projects/<lab>/users/<you>)" "$PRIOR_REMOTE"
ask MPERSIST "Keep the login alive for how many hours" "${PRIOR_PERSIST:-8}"
[[ "$MPERSIST" =~ ^[0-9]+$ ]] || die "Hours must be a whole number."

echo; bold "Scratch mount (optional)"
info "Minerva scratch is always /sc/arion/scratch/<username>."
SMOUNT=""; SREMOTE=""
if [[ -r "$CONF" && -z "$PRIOR_SCRATCH" ]]; then _scratch_def="N"; else _scratch_def="Y"; fi
if yesno "Also set up a scratch mount? [y/n]:" "$_scratch_def"; then
  ask SMOUNT "Local mountpoint for scratch" "${PRIOR_SCRATCH:-$HOME/minerva-scratch}"
  SREMOTE="/sc/arion/scratch/$MUSER/"; info "scratch remote → $SREMOTE"
fi

echo; bold "About to apply:"
info "username:       $MUSER";  info "mountpoint:     $MMOUNT"
info "remote path:    ${MREMOTE:-<your Minerva home>}"
info "scratch mount:  ${SMOUNT:-<none>}${SMOUNT:+  ←  $SREMOTE}"
info "login persists: ${MPERSIST}h"
info "files touched:  ~/.ssh/config, ~/.bashrc and/or ~/.zshrc, ~/.local/bin/minerva-mount.sh, ~/.config/minerva/minerva.conf"
info "                (rc file(s) and ~/.ssh/config backed up to .minerva-bak.$STAMP first)"
if (( ! USE_DEFAULTS )); then yesno "Proceed? [y/n]:" "Y" || die "Aborted."; fi

# ---- write config -----------------------------------------------------------
echo; bold "Writing config"
if ! mkdir -p "$HOME/.config/minerva" "$HOME/.local/bin" "$HOME/.local/state/minerva" 2>/dev/null; then
  die "Can't create ~/.config or ~/.local — not writable by you (often root-owned).
   Fix it, then re-run:   sudo chown -R \"\$(whoami)\" ~/.config ~/.local && chmod u+rwx ~/.config ~/.local"
fi
mkdir -p "$HOME/.ssh/sockets" "$MMOUNT"; [[ -n "$SMOUNT" ]] && mkdir -p "$SMOUNT"
chmod 700 "$HOME/.ssh/sockets"
if (( ! KEEP_PW )) && [[ -n "${PW1:-}" ]]; then ( umask 077; printf '%s\n' "$PW1" >"$PWFILE" ); chmod 600 "$PWFILE"; ok "password saved to $PWFILE (0600)"; fi
unset PW1 PW2 || true
cat >"$CONF" <<EOF
# Minerva tooling settings (Linux/WSL) — edit freely, then open a new shell.
MINERVA_USER="$MUSER"
MINERVA_MOUNT="$MMOUNT"
MINERVA_REMOTE_PATH="$MREMOTE"
MINERVA_SCRATCH_MOUNT="$SMOUNT"
MINERVA_SCRATCH_REMOTE="$SREMOTE"
MINERVA_PERSIST="$MPERSIST"
MINERVA_NODES=(minerva13 minerva11 minerva12 minerva14 minerva)
MINERVA_LOG="\$HOME/.local/state/minerva/minerva-mount.log"
MINERVA_PWFILE="$PWFILE"
EOF
ok "wrote ~/.config/minerva/minerva.conf"
install -m 0755 "$SCRIPT_DIR/minerva-mount-linux.sh" "$HOME/.local/bin/minerva-mount.sh"
ok "installed ~/.local/bin/minerva-mount.sh"

# ---- ssh config (ControlMaster works on Linux OpenSSH) ----------------------
backup_once "$HOME/.ssh/config"
write_block "$HOME/.ssh/config" "# Minerva (Sinai HPC) — managed by minerva-setup-linux.sh
Host minerva minerva11 minerva12 minerva13 minerva14
    HostName %h.hpc.mssm.edu
Host minerva*
    User $MUSER
    PreferredAuthentications keyboard-interactive,password
    NumberOfPasswordPrompts 2
    PasswordAuthentication yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist ${MPERSIST}h"
chmod 600 "$HOME/.ssh/config"; ok "updated ~/.ssh/config (User $MUSER, ControlPersist ${MPERSIST}h)"

# ---- shell rc(s) ------------------------------------------------------------
if (( HAVE_SSHPASS )); then
  LOGIN_ALIASES="# Log in (password auto-fed via sshpass; approve the MFA push on your phone).
alias minerva='sshpass -f \"\$MINERVA_PWFILE\" ssh -o ForwardX11=yes minerva'
alias minerva11='sshpass -f \"\$MINERVA_PWFILE\" ssh minerva11'
alias minerva12='sshpass -f \"\$MINERVA_PWFILE\" ssh minerva12'
alias minerva13='sshpass -f \"\$MINERVA_PWFILE\" ssh minerva13'
alias minerva14='sshpass -f \"\$MINERVA_PWFILE\" ssh minerva14'"
else
  LOGIN_ALIASES="# Log in (type your password when asked — once per ControlMaster window; then MFA).
alias minerva='ssh minerva'
alias minerva11='ssh minerva11'
alias minerva12='ssh minerva12'
alias minerva13='ssh minerva13'
alias minerva14='ssh minerva14'"
fi
SHELL_BLOCK="# Minerva (Sinai HPC) — managed by minerva-setup-linux.sh. Settings: ~/.config/minerva/minerva.conf
[ -r \"\$HOME/.config/minerva/minerva.conf\" ] && . \"\$HOME/.config/minerva/minerva.conf\"
: \"\${MINERVA_PWFILE:=\$HOME/.minerva_password}\"

$LOGIN_ALIASES

# Mount management (on-demand — run AFTER logging into a node).
# With no args, minerva-mount brings up the primary mount and, if configured, scratch.
minerva-mount(){
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/.local/bin/minerva-mount.sh\" \"\$@\"; return; fi
  \"\$HOME/.local/bin/minerva-mount.sh\"
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/.local/bin/minerva-mount.sh\" mount \"\$MINERVA_SCRATCH_MOUNT\" \"\$MINERVA_SCRATCH_REMOTE\"
}
minerva-status(){
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/.local/bin/minerva-mount.sh\" status \"\$@\"; return; fi
  \"\$HOME/.local/bin/minerva-mount.sh\" status
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/.local/bin/minerva-mount.sh\" status \"\$MINERVA_SCRATCH_MOUNT\"
}
minerva-clear(){
  if [ \"\$#\" -gt 0 ]; then \"\$HOME/.local/bin/minerva-mount.sh\" clear \"\$@\"; return; fi
  \"\$HOME/.local/bin/minerva-mount.sh\" clear
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] && \"\$HOME/.local/bin/minerva-mount.sh\" clear \"\$MINERVA_SCRATCH_MOUNT\"
}
minerva-scratch(){
  [ -n \"\${MINERVA_SCRATCH_MOUNT:-}\" ] || { echo 'No scratch mount configured — re-run minerva-setup-linux.sh.'; return 1; }
  \"\$HOME/.local/bin/minerva-mount.sh\" mount \"\$MINERVA_SCRATCH_MOUNT\" \"\$MINERVA_SCRATCH_REMOTE\"
}

MINERVA_BASE=\"minerva:\${MINERVA_REMOTE_PATH:-.}\"
mpull(){ rsync -avh --progress \"\$MINERVA_BASE/\$1\" \"\$2\"; }
mpush(){ rsync -avh --progress \"\$1\" \"\$MINERVA_BASE/\$2\"; }
minerva-update-password(){ local p; printf 'New Minerva password: '; read -rs p; printf '\\n'
  [ -z \"\$p\" ] && { echo 'Aborted (empty).'; return 1; }
  ( umask 077; printf '%s\\n' \"\$p\" > \"\$MINERVA_PWFILE\" ); chmod 600 \"\$MINERVA_PWFILE\"; echo \"Updated \$MINERVA_PWFILE.\"; }

# Strip the marker-delimited block from a file (exact full-line match).
_minerva_strip(){ [ -f \"\$1\" ] || return 0
  awk '\$0==\"# >>> minerva-setup >>>\"{s=1;next} \$0==\"# <<< minerva-setup <<<\"{s=0;next} !s{print}' \"\$1\" > \"\$1.mtmp\" && mv \"\$1.mtmp\" \"\$1\"; }

# Forget saved credentials. --all also wipes settings + SSH identity (tooling stays).
minerva-forget(){
  local all=0; [ \"\${1:-}\" = '--all' ] && all=1
  if [ \$all -eq 1 ]; then printf 'Remove saved password AND settings (username, mount paths)? [y/n]: '
  else printf 'Remove the saved Minerva password? [y/n]: '; fi
  local r; read -r r; case \"\$r\" in [Yy]*) ;; *) echo 'Aborted.'; return 1;; esac
  rm -f \"\${MINERVA_PWFILE:-\$HOME/.minerva_password}\"; echo 'Removed saved password.'
  if [ \$all -eq 1 ]; then
    rm -rf \"\$HOME/.config/minerva\"; echo 'Removed saved settings.'
    cp -p \"\$HOME/.ssh/config\" \"\$HOME/.ssh/config.minerva-bak.\$(date +%Y%m%d%H%M%S)\" 2>/dev/null
    _minerva_strip \"\$HOME/.ssh/config\"; echo 'Removed SSH identity block. Re-run minerva-setup-linux.sh to reconfigure.'
  fi
}

# Remove ALL Minerva tooling and restore shell/ssh config (backs them up first).
minerva-uninstall(){
  local purge=0; [ \"\${1:-}\" = '--purge' ] && purge=1
  printf 'Remove ALL Minerva tooling and restore your shell/ssh config? [y/n]: '
  local r; read -r r; case \"\$r\" in [Yy]*) ;; *) echo 'Aborted.'; return 1;; esac
  \"\$HOME/.local/bin/minerva-mount.sh\" clear >/dev/null 2>&1
  local s; s=\$(date +%Y%m%d%H%M%S)
  for rc in \"\$HOME/.bashrc\" \"\$HOME/.zshrc\"; do [ -f \"\$rc\" ] && cp -p \"\$rc\" \"\$rc.minerva-bak.\$s\" 2>/dev/null; done
  cp -p \"\$HOME/.ssh/config\" \"\$HOME/.ssh/config.minerva-bak.\$s\" 2>/dev/null
  _minerva_strip \"\$HOME/.ssh/config\"
  rm -f \"\$HOME/.local/bin/minerva-mount.sh\" \"\${MINERVA_PWFILE:-\$HOME/.minerva_password}\"
  rm -rf \"\$HOME/.config/minerva\"
  if [ \$purge -eq 1 ]; then
    printf 'Also remove apt deps sshpass + sshfs? [y/n]: '; local p; read -r p
    case \"\$p\" in [Yy]*) sudo apt-get remove -y sshpass sshfs >/dev/null 2>&1; echo 'Removed apt deps.';; *) echo 'Kept apt deps.';; esac
  fi
  for rc in \"\$HOME/.bashrc\" \"\$HOME/.zshrc\"; do _minerva_strip \"\$rc\"; done
  echo \"Uninstalled. Backups: *.minerva-bak.\$s\"
  echo 'Open a new terminal for removal to take full effect.'
}"

while IFS= read -r rc; do backup_once "$rc"; write_block "$rc" "$SHELL_BLOCK"; ok "updated ${rc/#$HOME/~}"; done < <(rc_files)

# ---- done -------------------------------------------------------------------
echo; bold "Done. Next steps:"
info "1. Open a new terminal  (or: source ~/.bashrc  /  source ~/.zshrc)"
info "2. Log in:   minerva13      → approve the MFA push on your phone"
(( HAVE_SSHFS )) && info "3. Mount:    minerva-mount   ${SMOUNT:+(primary + scratch)}   →   minerva-status   →   browse $MMOUNT" \
                 || info "3. (mounting disabled until you install sshfs:  sudo apt install sshfs)"
(( IS_WSL )) && info "WSL note: use the mount from the terminal / \\\\wsl\$; Windows Explorer may not see FUSE mounts."
echo
info "Forget password: minerva-forget [--all]   •   Remove everything: minerva-uninstall [--purge]"
info "Change settings: edit ~/.config/minerva/minerva.conf   •   New password: minerva-update-password"

#!/usr/bin/env bash
# minerva-setup-linux.sh — Minerva (Sinai HPC) tooling for Linux / WSL2.
#
#   *** UNTESTED as of 2026-06-01 — written for Debian/Ubuntu & WSL2 but not yet
#       run on one. Validate before relying on it; see port/linux/README.md. ***
#
# Mirrors the macOS installer, adapted for Linux:
#   * deps from apt (sshpass, sshfs) — HYBRID model: detect; if missing, show the
#     exact command and offer to run it; never abort the whole setup over a dep
#     (logins work without sshpass; only mounting needs sshfs).
#   * writes the shell block to the RIGHT rc file(s): ~/.bashrc and/or ~/.zshrc.
#   * libfuse sshfs mount via ~/.local/bin/minerva-mount.sh (this dir's _linux.sh).
#
# Usage:  ./minerva-setup-linux.sh [--defaults]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> minerva-setup >>>"
END="# <<< minerva-setup <<<"
USE_DEFAULTS=0
[[ "${1:-}" == "--defaults" || "${1:-}" == "-y" ]] && USE_DEFAULTS=1

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }; info(){ printf '  %s\n' "$*"; }
warn(){ printf '\033[33m  ! %s\033[0m\n' "$*"; }; ok(){ printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

ask(){ local __v="$1" __p="$2" __d="${3:-}" __r=""
  if (( USE_DEFAULTS )); then printf -v "$__v" '%s' "$__d"; return; fi
  if [[ -n "$__d" ]]; then read -r -p "$__p [$__d]: " __r || true; else read -r -p "$__p: " __r || true; fi
  printf -v "$__v" '%s' "${__r:-$__d}"; }

write_block(){ local file="$1" content="$2" tmp; touch "$file"; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  { cat "$tmp"; printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END"; } >"$file.new"
  mv "$file.new" "$file"; rm -f "$tmp"; }

# True if PATH (or, if it doesn't exist yet, its nearest existing ancestor) is writable.
path_writable() { local p="$1"; while [ ! -e "$p" ]; do p="$(dirname "$p")"; done; [ -w "$p" ]; }

bold "Minerva setup (Linux / WSL2)"; echo
[[ "$(uname -s)" == "Linux" ]] || die "This installer is for Linux/WSL. On macOS use minerva-setup.sh."
IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && { IS_WSL=1; ok "WSL2 detected"; }
command -v apt-get >/dev/null 2>&1 || warn "This installer assumes apt (Debian/Ubuntu). Install sshpass+sshfs your way, then it'll detect them."
[[ -f "$SCRIPT_DIR/minerva-mount-linux.sh" ]] || die "minerva-mount-linux.sh not found next to this script."

# Catch a home folder with root-owned files UP FRONT — one fix instead of many.
unwritable=()
for t in "$HOME" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config" "$HOME/.local" "$HOME/.ssh"; do
  [ -e "$t" ] || continue          # only existing-but-unwritable paths matter here
  path_writable "$t" || unwritable+=("${t/#$HOME/~}")
done
if (( ${#unwritable[@]} )); then
  die "Not writable by you (likely root-owned): ${unwritable[*]}
   Your home folder has ownership issues. Fix it all at once, then re-run:
     sudo chown -R \"\$(whoami)\" \"\$HOME\""
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
  info "Missing: ${need[*]}"
  info "Install command:  $cmd"
  do_install=1
  if (( ! USE_DEFAULTS )); then read -r -p "Run it now (needs sudo)? [y/n]: " a || true; [[ "${a:-Y}" =~ ^[Yy]?$ ]] || do_install=0; fi
  if (( do_install )); then
    if sudo apt-get update -y && sudo apt-get install -y "${need[@]}"; then
      command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1
      command -v sshfs   >/dev/null 2>&1 && HAVE_SSHFS=1
      ok "installed: ${need[*]}"
    else
      warn "apt install failed — continuing. Run later:  $cmd"
    fi
  else
    warn "Skipped. Run later:  $cmd"
  fi
fi
(( HAVE_SSHPASS )) || warn "Without sshpass, logins will prompt for your password (once per session)."
(( HAVE_SSHFS ))   || warn "Without sshfs, mounting is disabled until you install it (logins still work)."

# ---- prompts ----------------------------------------------------------------
echo; bold "Your Minerva account"
read -r -p "Sinai HPC username (e.g. smithj01): " MUSER || true
[[ -n "$MUSER" ]] || die "Username is required."
PWFILE="$HOME/.minerva_password"
if (( USE_DEFAULTS )) && [[ -s "$PWFILE" ]]; then ok "keeping existing password file"
else
  while :; do
    read -r -s -p "Sinai SSO password: " PW1; echo
    read -r -s -p "Confirm password:   " PW2; echo
    [[ -n "$PW1" ]] || { warn "Empty — try again."; continue; }
    [[ "$PW1" == "$PW2" ]] || { warn "Did not match — try again."; continue; }; break
  done
fi
echo; bold "Settings (Enter = recommended default)"
info "• Local mountpoint = a folder on THIS machine where the Minerva tree appears."
info "• Remote path = which folder ON MINERVA to mount there (blank = your home dir)."
info "    example remote path:  /sc/arion/projects/Smith_Lab/users/jdoe"
info "    i.e. the form:         /sc/arion/projects/<your-lab>/users/<your-username>"
ask MMOUNT  "Local mountpoint (folder on this machine)" "$HOME/minerva"
ask MREMOTE "Remote path on Minerva (blank = home, e.g. /sc/arion/projects/<lab>/users/<you>)" ""
ask MPERSIST "Keep the login alive for how many hours" "8"
[[ "$MPERSIST" =~ ^[0-9]+$ ]] || die "Hours must be a whole number."

echo; bold "About to apply:"
info "username:       $MUSER";          info "mountpoint:     $MMOUNT"
info "remote path:    ${MREMOTE:-<your Minerva home>}"; info "login persists: ${MPERSIST}h"
info "files touched:  ~/.ssh/config, ~/.bashrc and/or ~/.zshrc, ~/.local/bin/minerva-mount.sh, ~/.config/minerva/minerva.conf"
if (( ! USE_DEFAULTS )); then read -r -p "Proceed? [y/n]: " GO || true; [[ "${GO:-Y}" =~ ^[Yy]?$ ]] || die "Aborted."; fi

# ---- write config (fail fast with guidance if ~/.config or ~/.local is root-owned) --
echo; bold "Writing config"
if ! mkdir -p "$HOME/.config/minerva" "$HOME/.local/bin" "$HOME/.local/state/minerva" 2>/dev/null; then
  die "Can't create ~/.config or ~/.local — not writable by you (often root-owned).
   Fix it, then re-run this installer:
     sudo chown -R \"\$(whoami)\" ~/.config ~/.local && chmod u+rwx ~/.config ~/.local"
fi
mkdir -p "$HOME/.ssh/sockets" "$MMOUNT"
chmod 700 "$HOME/.ssh/sockets"
if [[ -n "${PW1:-}" ]]; then ( umask 077; printf '%s\n' "$PW1" >"$PWFILE" ); chmod 600 "$PWFILE"; ok "password saved to $PWFILE (0600)"; fi
unset PW1 PW2 || true
cat >"$HOME/.config/minerva/minerva.conf" <<EOF
# Minerva tooling settings (Linux/WSL) — edit freely, then open a new shell.
MINERVA_USER="$MUSER"
MINERVA_MOUNT="$MMOUNT"
MINERVA_REMOTE_PATH="$MREMOTE"
MINERVA_NODES=(minerva13 minerva11 minerva12 minerva14 minerva)
MINERVA_LOG="\$HOME/.local/state/minerva/minerva-mount.log"
MINERVA_PWFILE="$PWFILE"
EOF
ok "wrote ~/.config/minerva/minerva.conf"
install -m 0755 "$SCRIPT_DIR/minerva-mount-linux.sh" "$HOME/.local/bin/minerva-mount.sh"
ok "installed ~/.local/bin/minerva-mount.sh"

# ---- ssh config (ControlMaster works on Linux OpenSSH) ----------------------
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
alias minerva-mount=\"\$HOME/.local/bin/minerva-mount.sh\"
alias minerva-status=\"\$HOME/.local/bin/minerva-mount.sh status\"
alias minerva-clear=\"\$HOME/.local/bin/minerva-mount.sh clear\"

MINERVA_BASE=\"minerva:\${MINERVA_REMOTE_PATH:-.}\"
mpull(){ rsync -avh --progress \"\$MINERVA_BASE/\$1\" \"\$2\"; }
mpush(){ rsync -avh --progress \"\$1\" \"\$MINERVA_BASE/\$2\"; }
minerva-update-password(){ local p; printf 'New Minerva password: '; read -rs p; printf '\\n'
  [ -z \"\$p\" ] && { echo 'Aborted (empty).'; return 1; }
  ( umask 077; printf '%s\\n' \"\$p\" > \"\$MINERVA_PWFILE\" ); chmod 600 \"\$MINERVA_PWFILE\"; echo \"Updated \$MINERVA_PWFILE.\"; }"

wrote_any=0
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] && { write_block "$rc" "$SHELL_BLOCK"; ok "updated ${rc/#$HOME/~}"; wrote_any=1; }
done
if (( ! wrote_any )); then write_block "$HOME/.bashrc" "$SHELL_BLOCK"; ok "created ~/.bashrc"; fi

# ---- done -------------------------------------------------------------------
echo; bold "Done. Next steps:"
info "1. Open a new terminal  (or: source ~/.bashrc  /  source ~/.zshrc)"
info "2. Log in:   minerva13      → approve the MFA push on your phone"
(( HAVE_SSHFS )) && info "3. Mount:    minerva-mount   →   minerva-status   →   browse $MMOUNT" \
                 || info "3. (mounting disabled until you install sshfs:  sudo apt install sshfs)"
(( IS_WSL )) && info "WSL note: use the mount from the terminal / \\\\wsl\$; Windows Explorer may not see FUSE mounts."

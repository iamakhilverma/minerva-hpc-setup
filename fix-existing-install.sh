#!/usr/bin/env bash
# fix-existing-install.sh — retrofit an EXISTING Minerva install to the no-storm
# design, in place, on a machine that was set up with an older version.
#
# Why this exists: older installs (and hand-customized ones WITHOUT the
# "# >>> minerva-setup >>>" markers) can't be fixed by re-running minerva-setup.sh
# — it would append a fresh managed block beside the old hand-edited one. This
# script edits whatever is actually there, so it works for both layouts.
#
# It makes the same changes that stopped the failed-login storm (see the repo
# README / git log):
#   1. login aliases:   sshpass -p/-f "…" ssh -Y minervaN   →   ssh -Y minervaN
#   2. drops the  export MINERVA_PASSWORD=…  line and the minerva-update-password fn
#   3. ~/.ssh/config:   NumberOfPasswordPrompts  →  1
#   4. installs the fixed ~/bin/minerva-mount.sh (no -o reconnect; BatchMode pin)
#   5. deletes the cleartext password file (~/.minerva_password / $MINERVA_PWFILE)
#   6. reaps any old "sshfs … -o reconnect" mounts (the background storm source)
#
# Safe + idempotent: every edited file is backed up to <file>.minerva-bak.<stamp>
# first, and re-running when there's nothing left to change is a no-op.
#
# Usage:
#   ./fix-existing-install.sh             # apply the fixes
#   ./fix-existing-install.sh --dry-run   # show what WOULD change, touch nothing
#   ./fix-existing-install.sh --keep-mounts  # don't unmount old reconnect mounts
#   ./fix-existing-install.sh -h
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d%H%M%S)"
DRY_RUN=0
KEEP_MOUNTS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)   DRY_RUN=1 ;;
    --keep-mounts)  KEEP_MOUNTS=1 ;;
    -h|--help)      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
note() { (( DRY_RUN )) && printf '\033[36m  [dry-run] %s\033[0m\n' "$*" || info "$*"; }

CHANGED=0   # whether we actually changed anything (for the final summary)

backup_once() {
  local f="$1" b="$1.minerva-bak.$STAMP"
  [[ -f "$f" && ! -e "$b" ]] || return 0
  (( DRY_RUN )) && { note "would back up $f → $b"; return 0; }
  cp -p "$f" "$b"
}

# Apply the zshrc/bashrc transforms to a file, writing the result to stdout.
# (Pure text transform; the caller decides whether to write it back.)
transform_rc() {
  local f="$1"
  # 1. strip the sshpass wrapper from any  sshpass [-p|-f "…"] ssh  invocation
  # 2. delete the password export line
  # 3. delete the whole minerva-update-password function (header … line with just "}")
  sed -E \
    -e 's/sshpass[[:space:]]+-[pf][[:space:]]+"[^"]*"[[:space:]]+ssh/ssh/g' \
    -e 's/sshpass[[:space:]]+-[pf][[:space:]]+[^[:space:]]+[[:space:]]+ssh/ssh/g' \
    -e 's/sshpass[[:space:]]+-e[[:space:]]+ssh/ssh/g' \
    -e 's/sshpass[[:space:]]+ssh/ssh/g' \
    -e '/^[[:space:]]*export[[:space:]]+MINERVA_PASSWORD=/d' \
    "$f" \
  | awk '
      skip==1 { if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) skip=0; next }
      $0 ~ /^[[:space:]]*minerva-update-password[[:space:]]*\(\)/ { skip=1; next }
      { print }
    '
}

# Fix one shell rc file in place (if it needs it). Returns 0 if changed.
fix_rc_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Only act on ACTIONABLE content — a sshpass-wrapped ssh, the password export,
  # or the update-password function — NOT a bare mention in a comment.
  grep -qE 'sshpass[[:space:]]+(-[a-z][[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+)?ssh' "$f" \
    || grep -qE '^[[:space:]]*export[[:space:]]+MINERVA_PASSWORD=' "$f" \
    || grep -qE '^[[:space:]]*minerva-update-password[[:space:]]*\(\)' "$f" \
    || return 1
  local tmp; tmp="$(mktemp)"
  transform_rc "$f" >"$tmp"
  if diff -q "$f" "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
  if (( DRY_RUN )); then
    note "would update ${f/#$HOME/~}:"
    diff -u "$f" "$tmp" | sed -n '4,40p' | sed 's/^/      /' || true
    rm -f "$tmp"; return 0
  fi
  backup_once "$f"
  cat "$tmp" >"$f"; rm -f "$tmp"
  ok "fixed ${f/#$HOME/~}  (sshpass aliases → plain ssh; removed password export / update-password)"
  return 0
}

[[ "$(uname -s)" == "Darwin" ]] || warn "Not macOS — proceeding anyway, but this tool targets the macOS install."
[[ -f "$SCRIPT_DIR/minerva-mount.sh" ]] || die "minerva-mount.sh not found next to this script ($SCRIPT_DIR). Run it from the repo."
# Sanity: make sure the mount script we're about to install is the FIXED one.
grep -q 'BatchMode=yes' "$SCRIPT_DIR/minerva-mount.sh" \
  || die "$SCRIPT_DIR/minerva-mount.sh looks like an OLD version (no BatchMode). Pull the latest 'main' first."

bold "Minerva — retrofit existing install $([[ $DRY_RUN -eq 1 ]] && echo '(dry-run)')"
echo

# ---- 1–3. shell rc files + ssh config --------------------------------------
bold "1. Shell login aliases (remove sshpass + stored password)"
rc_fixed=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile"; do
  if fix_rc_file "$rc"; then rc_fixed=1; CHANGED=1; fi
done
(( rc_fixed )) || ok "login aliases already clean (no sshpass / MINERVA_PASSWORD found)"

echo; bold "2. ~/.ssh/config — NumberOfPasswordPrompts → 1"
SSHCFG="$HOME/.ssh/config"
if [[ -f "$SSHCFG" ]] && grep -qE '^[[:space:]]*NumberOfPasswordPrompts[[:space:]]+[2-9]' "$SSHCFG"; then
  if (( DRY_RUN )); then
    note "would set NumberOfPasswordPrompts → 1 in ~/.ssh/config"
  else
    backup_once "$SSHCFG"
    sed -E -i '' 's/^([[:space:]]*NumberOfPasswordPrompts[[:space:]]+)[0-9]+/\11/' "$SSHCFG"
    ok "set NumberOfPasswordPrompts 1 in ~/.ssh/config"
  fi
  CHANGED=1
elif [[ -f "$SSHCFG" ]] && grep -qE '^[[:space:]]*NumberOfPasswordPrompts[[:space:]]+1' "$SSHCFG"; then
  ok "NumberOfPasswordPrompts already 1"
else
  warn "No NumberOfPasswordPrompts line found in ~/.ssh/config (default is 3)."
  warn "  Add  'NumberOfPasswordPrompts 1'  under your  Host minerva*  block to cap failed tries."
fi

# ---- 4. fixed mount script --------------------------------------------------
echo; bold "4. ~/bin/minerva-mount.sh — install the no-reconnect / BatchMode version"
DEST="$HOME/bin/minerva-mount.sh"
if [[ -f "$DEST" ]] && cmp -s "$SCRIPT_DIR/minerva-mount.sh" "$DEST"; then
  ok "already up to date"
else
  if (( DRY_RUN )); then
    note "would install $SCRIPT_DIR/minerva-mount.sh → $DEST (backing up the old one)"
  else
    mkdir -p "$HOME/bin"
    [[ -f "$DEST" ]] && cp -p "$DEST" "$DEST.minerva-bak.$STAMP"
    install -m 0755 "$SCRIPT_DIR/minerva-mount.sh" "$DEST"
    ok "installed fixed ~/bin/minerva-mount.sh"
  fi
  CHANGED=1
fi

# ---- 5. cleartext password file --------------------------------------------
echo; bold "5. Remove the cleartext SSO password file"
PWFILE="$HOME/.minerva_password"
# also honor a custom path if the config recorded one
[[ -r "$HOME/.config/minerva/minerva.conf" ]] && \
  PWFILE="$(. "$HOME/.config/minerva/minerva.conf" 2>/dev/null; echo "${MINERVA_PWFILE:-$PWFILE}")"
if [[ -e "$PWFILE" ]]; then
  if (( DRY_RUN )); then note "would delete $PWFILE"; else rm -f "$PWFILE" && ok "deleted $PWFILE"; fi
  CHANGED=1
else
  ok "no cleartext password file present"
fi

# ---- 6. reap old reconnect mounts (the background storm source) -------------
echo; bold "6. Old 'sshfs … -o reconnect' mounts (background storm source)"
recon_pids=()
while IFS= read -r _p; do [[ -n "$_p" ]] && recon_pids+=("$_p"); done \
  < <(pgrep -f 'sshfs .*reconnect' 2>/dev/null || true)
if (( ${#recon_pids[@]} == 0 )); then
  ok "none running"
elif (( KEEP_MOUNTS )); then
  warn "${#recon_pids[@]} found, but --keep-mounts given — leaving them."
  warn "  These keep re-authing after the master expires. Clear them later with: minerva-clear"
else
  warn "${#recon_pids[@]} reconnect mount(s) found — these are what spray failed logins."
  for pid in "${recon_pids[@]}"; do
    mp="$(ps -p "$pid" -o args= 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//){print $i; exit}}')"
    [[ -n "$mp" ]] || continue
    if (( DRY_RUN )); then
      note "would force-unmount + reap: $mp (pid $pid)"
    else
      diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp" >/dev/null 2>&1 || true
      pkill -9 -f "sshfs .*$mp"    2>/dev/null || true
      pkill -9 -f "go-nfsv4 .*$mp" 2>/dev/null || true
      ok "cleared $mp"
    fi
  done
  CHANGED=1
fi

# ---- summary / verify -------------------------------------------------------
echo; bold "Result"
if (( DRY_RUN )); then
  info "Dry run only — nothing was changed. Re-run without --dry-run to apply."
  exit 0
fi
if (( ! CHANGED )); then
  ok "Nothing to fix — this machine is already on the no-storm design."
else
  ok "Done. Backups (if any) are at <file>.minerva-bak.$STAMP"
fi
echo
bold "Verify (should all be clean):"
left_sshpass=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile"; do
  [[ -f "$rc" ]] && grep -qE 'sshpass[[:space:]]+(-[a-z][[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+)?ssh' "$rc" \
    && { warn "$rc still has a sshpass-wrapped ssh — check it by hand"; left_sshpass=1; }
done
(( left_sshpass )) || ok "no sshpass left in shell rc files"
pgrep -f 'sshfs .*reconnect' >/dev/null 2>&1 && warn "a reconnect mount is still running — run: minerva-clear" || ok "no reconnect mounts running"
echo
bold "Next:"
info "1. Open a NEW terminal (or: source ~/.zshrc) so the plain-ssh aliases load."
info "2. Log in:   minerva13   → approve Duo   (opens the ControlMaster window)"
info "3. Mount:    minerva-mount   •   Check: minerva-status"

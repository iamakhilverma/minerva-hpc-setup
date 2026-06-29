#!/usr/bin/env bash
# verify-install.sh — read-only health check for a Minerva install.
#
# Confirms a machine is on the no-storm design and that minerva-setup.sh wrote
# everything it should. Changes NOTHING — safe to run anywhere, any time.
#
# Checks:
#   1. managed "# >>> minerva-setup >>>" blocks present (and not duplicated)
#      in ~/.ssh/config and ~/.zshrc
#   2. ~/bin/minerva-mount.sh installed + executable, ~/.config/minerva/minerva.conf
#      present, and the mount script matches the repo copy (no drift)
#   3. ssh hardening:  NumberOfPasswordPrompts 1  +  ControlPersist set
#   4. no storm leftovers: no sshpass / MINERVA_PASSWORD in shell rc, no cleartext
#      password file, no live "sshfs … -o reconnect" mounts, no sshpass processes
#   5. ~/.zshrc sources clean (no parse error), minerva-mount is a function (not an
#      alias), and the unalias guard is present
#
# Exit status: 0 if in order (warnings allowed), 1 if any hard check FAILED.
#
# Usage:
#   ./verify-install.sh
#   ./verify-install.sh -h
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HOME/.config/minerva/minerva.conf"
BEGIN="# >>> minerva-setup >>>"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

PASS=0; WARN=0; FAIL=0
pass() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
wrn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; WARN=$((WARN+1)); }
fail() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }

# Count managed-block opening markers in a file (0 = none, >1 = duplicated).
# grep -c exits non-zero on 0 matches, so capture and default rather than `|| echo`.
block_count() { local c; c="$(grep -cF "$BEGIN" "$1" 2>/dev/null)"; echo "${c:-0}"; }

bold "Minerva — verify install"

echo; bold "1. Managed blocks"
for pair in "$HOME/.ssh/config:ssh/config" "$HOME/.zshrc:.zshrc"; do
  f="${pair%%:*}"; label="${pair##*:}"
  n="$(block_count "$f")"
  if   (( n == 1 )); then pass "$label has the managed block"
  elif (( n == 0 )); then wrn "$label has no managed block — hand-customized? minerva-setup.sh can't manage it (fine if intentional)"
  else                    wrn "$label has $n managed blocks — duplicate; keep one"
  fi
done

echo; bold "2. Installed files"
if [[ -x "$HOME/bin/minerva-mount.sh" ]]; then pass "~/bin/minerva-mount.sh present + executable"
else fail "~/bin/minerva-mount.sh missing or not executable"; fi
if [[ -r "$CONF" ]]; then pass "~/.config/minerva/minerva.conf present"
else fail "~/.config/minerva/minerva.conf missing"; fi
if [[ -f "$SCRIPT_DIR/minerva-mount.sh" ]]; then
  if diff -q "$HOME/bin/minerva-mount.sh" "$SCRIPT_DIR/minerva-mount.sh" >/dev/null 2>&1; then
    pass "installed mount script matches repo copy (no drift)"
  else
    wrn "installed mount script differs from repo copy — re-run ./minerva-setup.sh to refresh"
  fi
else
  info "(repo minerva-mount.sh not found next to this script — skipped drift check)"
fi

echo; bold "3. SSH hardening"
if grep -q 'NumberOfPasswordPrompts 1' "$HOME/.ssh/config" 2>/dev/null; then pass "NumberOfPasswordPrompts 1"
else fail "NumberOfPasswordPrompts is not 1 (storm risk)"; fi
if grep -qi 'controlpersist' "$HOME/.ssh/config" 2>/dev/null; then pass "ControlPersist set (master reuse)"
else fail "no ControlPersist in ~/.ssh/config — mounts can't reuse the master"; fi

echo; bold "4. No storm leftovers"
# Match ACTUAL storm patterns, not mentions in comments (the clean managed block
# explains in a comment why sshpass was removed). Same patterns fix-existing-install
# uses: a sshpass-wrapped ssh, a MINERVA_PASSWORD export, or the update-password fn.
rc_dirty=""
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.bash_profile"; do
  [[ -f "$rc" ]] || continue
  if grep -qE 'sshpass[[:space:]]+(-[a-z][[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+)?ssh' "$rc" \
     || grep -qE '^[[:space:]]*export[[:space:]]+MINERVA_PASSWORD=' "$rc" \
     || grep -qE '^[[:space:]]*minerva-update-password[[:space:]]*\(\)' "$rc"; then
    rc_dirty="$rc_dirty ${rc/#$HOME/~}"
  fi
done
if [[ -n "$rc_dirty" ]]; then
  fail "sshpass-wrapped ssh / password export still in:$rc_dirty"
else
  pass "no sshpass-wrapped ssh / password export in shell rc files"
fi
if [[ -e "$HOME/.minerva_password" ]]; then fail "cleartext password file ~/.minerva_password present"
else pass "no cleartext password file"; fi
# Also honor a custom $MINERVA_PWFILE from the conf, if set.
pwfile="$( ( [[ -r "$CONF" ]] && . "$CONF" ); echo "${MINERVA_PWFILE:-}" )"
if [[ -n "$pwfile" && -e "$pwfile" ]]; then fail "cleartext password file $pwfile present"; fi
if pgrep -f 'sshfs .*reconnect' >/dev/null 2>&1; then fail "a 'sshfs … -o reconnect' mount is running — run: minerva-clear"
else pass "no reconnect mounts running"; fi
if pgrep -x sshpass >/dev/null 2>&1; then fail "an sshpass process is running"
else pass "no sshpass processes"; fi

echo; bold "5. Shell helpers"
if zsh -lic 'echo ok' 2>&1 | grep -qi 'parse error\|defining function'; then
  fail "~/.zshrc emits a parse error when sourced"
else
  pass "~/.zshrc sources clean (no parse error)"
fi
if zsh -lic 'whence -w minerva-mount' 2>/dev/null | grep -q 'function'; then
  pass "minerva-mount resolves to a function (not an alias)"
else
  fail "minerva-mount is not a function — helper block not loaded"
fi
if grep -q 'unalias minerva-' "$HOME/.zshrc" 2>/dev/null; then
  pass "unalias guard present (safe to re-source)"
else
  wrn "no 'unalias minerva-' guard in ~/.zshrc — harmless now, but re-run ./minerva-setup.sh to add it"
fi

echo; bold "Verdict"
if (( FAIL == 0 && WARN == 0 )); then
  printf '\033[32m  ✓ ALL CLEAR — install is in order and on the no-storm design.\033[0m\n'
elif (( FAIL == 0 )); then
  printf '\033[33m  ! OK with %d warning(s) — functional; review the ! lines above.\033[0m\n' "$WARN"
else
  printf '\033[31m  ✗ %d FAILURE(S), %d warning(s) — NOT in order; see the ✗ lines above.\033[0m\n' "$FAIL" "$WARN"
fi

echo; bold "Live test (manual — proves the single-Duo login path)"
info "exec zsh        # fresh shell so the managed block loads"
info "minerva13       # approve ONE Duo push → opens the ControlMaster window"
info "minerva-mount   # should mount with NO new prompt (reuses the master)"
info "minerva-status  # → state=0, bound=minervaNN"

(( FAIL == 0 ))

# Changelog

## 2026-06-25 — Stop the failed-login storm; make the mount auth-safe

A background loop on the macOS clients was generating large bursts of failed SSH
password attempts against Minerva — **~193 in one day from a single laptop**, which
tripped an HPC helpdesk abuse warning — with no user at the keyboard.

### Root causes (#12)
- **`sshfs -o reconnect`** — after the SSH `ControlMaster` window expired (sleep /
  Wi-Fi drop / 8h `ControlPersist`), any filesystem access (Finder, Spotlight —
  worst for a mount under `~/Desktop`) made `sshfs` re-establish the connection in
  the background. With no way to satisfy Duo/MFA, each retry was a failed auth,
  **doubled** by `NumberOfPasswordPrompts 2`.
- **`sshpass` login aliases** — `sshpass` cannot answer Duo/MFA and fed a **blank**
  password whenever its variable was empty; each such login failed. It also stored
  the SSO password in **cleartext** at `~/.minerva_password`.

### Changes
- **`minerva-mount.sh`** — removed `-o reconnect`; pinned `sshfs` to the existing
  master with `ssh_command="ssh -o BatchMode=yes -o ControlMaster=no"`, so it reuses
  the master only and can never initiate a fresh login. (#12, `386e4d7`)
- **`minerva-setup.sh`** — `NumberOfPasswordPrompts 1`; plain-`ssh` aliases (no
  sshpass); no stored password; removed `minerva-update-password`. (#12, `386e4d7`)
- **`fix-existing-install.sh`** — new idempotent retrofit for older / hand-customized
  installs that lack the managed-block markers; backs up every file, supports
  `--dry-run`. (#13, `6f36175`)
  - parse the real sshfs mountpoint when reaping reconnect mounts. (#14, `8c47a34`)
  - print a real "Nothing to fix" verdict in `--dry-run`. (#14, `0b12153`)
- **`minerva-setup.sh`** — `unalias` the `minerva-*` helpers before defining the
  functions, so re-sourcing `~/.zshrc` doesn't hit an alias→function parse error.
  (#15, `bd6659f`)

### Result
Mounts ride the live `ControlMaster` only and can never authenticate on their own.
The sole auth path is an interactive `ssh` login — password once per window, then
approve Duo. No `sshpass`, no stored password, no background reconnect.

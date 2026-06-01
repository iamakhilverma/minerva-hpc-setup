# Minerva tooling — Linux / WSL2 (variant A)

> ⚠️ **UNTESTED as of 2026-06-01.** Written for Debian/Ubuntu and WSL2, lint- and
> sandbox-checked on macOS, but **not yet run on a real Linux/WSL box**. Try it,
> report back, and we'll mark it tested. The macOS version (`../`) is the tested one.

Sets up Minerva (Sinai HPC) on Linux or WSL2: one-command SSH logins with an
N-hour passwordless `ControlMaster` window, plus an on-demand `sshfs` mount with
the same phantom-proof `status`/`clear` tooling as the Mac version.

## Prerequisites

- Debian/Ubuntu (or WSL2 with an Ubuntu distro). Other distros: install the two
  deps your way (below), then run the installer — it auto-detects them.
- The two dependencies — the installer offers to `apt install` them, or do it yourself:
  ```sh
  sudo apt update && sudo apt install -y sshpass sshfs
  ```
  Both are optional in the sense that the installer **won't abort** if they're
  missing: without `sshpass` logins just prompt for your password; without `sshfs`
  only the mount is disabled.

## Install

```sh
./minerva-setup-linux.sh            # interactive
# or
./minerva-setup-linux.sh --defaults # accept defaults (still prompts username + password)
```

Then open a new shell and:

```sh
minerva13        # log in, approve MFA → opens the passwordless window
minerva-mount    # mount ~/minerva
minerva-status   # HEALTHY?
```

Settings live in `~/.config/minerva/minerva.conf`; the shell block is written to
`~/.bashrc` and/or `~/.zshrc` (whichever you have).

## WSL2 caveat (important)

The mount works great **from inside WSL** (terminal, VS Code Remote). But a FUSE
mount inside WSL2 is generally **not visible in Windows Explorer** (`\\wsl$` does
not traverse FUSE mounts). If you want Explorer drive-letter browsing on Windows,
use the native-Windows route instead — see [`../windows/`](../windows/).

## Differences from the macOS version

- libfuse `sshfs` (not FUSE-T); `fusermount -u` (not `diskutil`); only the `sshfs`
  daemon to track (no `go-nfsv4`). Same health logic (mount table + daemon
  liveness + bound-node `ControlMaster` liveness), so `minerva-status` still can't hang.

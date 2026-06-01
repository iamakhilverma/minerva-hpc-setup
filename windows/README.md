# Minerva on native Windows — Explorer drive (variant B)

> ⚠️ **UNTESTED DRAFT as of 2026-06-01.** This is a guide, not an automated
> installer, and it has real caveats (below). Verify on your machine before
> relying on it. For terminal-only use, the WSL2 route ([`../linux/`](../linux/))
> is simpler and more faithful to the Mac setup.

Goal: mount your Minerva tree as a **drive letter visible in Windows Explorer**
(the closest analog to the macOS Finder mount), using **WinFsp + SSHFS-Win**.

## 1. Install WinFsp + SSHFS-Win

With [winget](https://learn.microsoft.com/windows/package-manager/) (Windows 10/11):

```powershell
winget install -e --id WinFsp.WinFsp
winget install -e --id SSHFS-Win.SSHFS-Win
```

(Or download the installers: WinFsp <https://winfsp.dev>, SSHFS-Win
<https://github.com/winfsp/sshfs-win>.)

## 2. Map Minerva as a drive

SSHFS-Win uses a UNC path of the form `\\sshfs\<user>@<host>[\path]`. To map it to
drive `Z:` (you'll be prompted for your password, then approve the MFA push):

```powershell
net use Z: \\sshfs\YOURUSER@minerva.hpc.mssm.edu
# a specific path instead of your home dir:
#   net use Z: "\\sshfs\YOURUSER@minerva.hpc.mssm.edu\sc\arion\projects\<...>"
```

Unmount:

```powershell
net use Z: /delete
```

`Z:` then shows up in Explorer like any drive.

## Caveats (read before trusting it)

1. **MFA:** SSHFS-Win authenticates over its own SSH library, and interactive
   MFA (push/keyboard-interactive) handling is inconsistent. If `net use` fails
   or hangs at the MFA step, this route may not work for Minerva's login flow —
   that's the main open question to test.
2. **No `ControlMaster`:** native Windows OpenSSH does **not** support the 8-hour
   passwordless multiplexing the Mac/Linux versions rely on. Each mount
   authenticates on its own; there's no shared "stay logged in for 8h" window.
3. **No phantom tooling:** the `minerva-status`/`minerva-clear` health checks are
   not ported here. Recovery is `net use Z: /delete` then re-map.

## Terminal SSH on Windows (optional)

For a shell on Minerva, use the built-in OpenSSH client:

```powershell
ssh YOURUSER@minerva13.hpc.mssm.edu     # type password, approve MFA
```

(Storing the password with `sshpass` isn't really a thing on native Windows; if
you want the `sshpass` + 8h-window experience, use WSL2 — see `../linux/`.)

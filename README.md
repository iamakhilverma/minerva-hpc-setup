# minerva-hpc-setup

One-command setup for **Minerva (Sinai HPC)** convenience tooling — SSH logins
with a long-lived passwordless session, MFA, and an on-demand network mount.
It prompts **you** for your own username and password; nothing is baked in.

## Pick your OS

| Your machine | Where to go | Status |
| --- | --- | --- |
| **macOS** (Apple Silicon or Intel) | this folder — instructions below | ✅ tested |
| **Linux / WSL2** | [`linux/`](linux/) | ⚠️ untested draft |
| **Windows** (Explorer drive) | [`windows/`](windows/) | ⚠️ untested draft |

---

# macOS

## What you get

- `minerva`, `minerva11`–`minerva14` — one-command SSH login. You type your SSO
  password **once per 8h window** and approve the MFA push; the first login opens a
  passwordless `ControlMaster` window that keeps every later login/mount/rsync
  password-free until it expires. No `sshpass`, no stored password — see
  [Security](#security).
- `minerva-mount` / `minerva-status` / `minerva-clear` — an **on-demand** FUSE-T
  mount of your Minerva tree at `~/minerva`, with a phantom-proof health check
  (`status` never touches the filesystem, so it can't hang; `clear` recovers a
  wedged mount without a reboot). With no args these act on your primary mount
  **and** your scratch mount (if you set one up).
- `minerva-scratch` — mount just your scratch tree (`/sc/arion/scratch/<you>`).
- `mpull` / `mpush` / `mput` / `mget` — rsync/scp helpers against your tree.
- `minerva-forget` / `minerva-uninstall` — clear any legacy saved files, or remove the
  whole setup and restore your shell (see [Credentials & uninstall](#credentials--uninstall)).

## Requirements

- macOS with [Homebrew](https://brew.sh) installed. FUSE-T is installed for you —
  and if it can't be installed, the setup continues anyway (logins still work; only
  the mount needs FUSE-T).
- A Sinai HPC (Minerva) account with SSO password + MFA (MS Authenticator).

## Install

```sh
git clone https://github.com/iamakhilverma/minerva-hpc-setup.git
cd minerva-hpc-setup
./minerva-setup.sh            # interactive — prompts for everything
# or:
./minerva-setup.sh --defaults # accept all recommended defaults (still prompts for username)
```

You'll be asked for (recommended defaults in brackets):

| Prompt | Default | Notes |
| --- | --- | --- |
| Sinai HPC username | *last used* | required first time, e.g. `smithj01` |
| Local mountpoint | `~/minerva` | where the Finder mount appears |
| Remote path | *your Minerva home* | blank = home dir, or a lab path like `/sc/arion/projects/Smith_Lab/users/jdoe` (form: `/sc/arion/projects/<lab>/users/<you>`) |
| Scratch mount | `~/minerva-scratch` | optional; remote is derived as `/sc/arion/scratch/<you>` — you only pick the local folder |
| Login persists | `8` hours | the passwordless `ControlMaster` window |

**Re-running is smart:** the installer detects a previous setup and offers your
saved values back as defaults — press Enter to keep each. Before it edits
`~/.zshrc` and `~/.ssh/config` it backs them up to timestamped
`.minerva-bak.<stamp>` files, so any change is reversible.

Then open a new terminal and:

```sh
minerva13        # log in, approve MFA → opens the 8h master
minerva-mount    # mount ~/minerva (reuses that master)
minerva-status   # HEALTHY?  Then browse ~/minerva in Finder.
```

## Retrofit an existing (older) install

If a machine was set up with an older version — especially one whose `~/.zshrc` was
hand-edited (no `# >>> minerva-setup >>>` markers, so re-running the installer would
just *append* a second block) — use the retrofit helper. It converts `sshpass` login
aliases to plain `ssh`, drops the stored password and `NumberOfPasswordPrompts 2`,
installs the no-`reconnect` / `BatchMode` mount script, and reaps any old reconnect
mounts. It backs up every file it touches (`<file>.minerva-bak.<stamp>`) and is safe
to re-run.

```sh
cd minerva-hpc-setup
git pull                              # get the fixed scripts first
./fix-existing-install.sh --dry-run   # preview every change, touch nothing
./fix-existing-install.sh             # apply  (--keep-mounts leaves active mounts up)
```

Then open a new terminal so the plain-`ssh` aliases load.

## Mount a second directory

Working in two places at once? Pass a mountpoint + remote path to mount another
folder alongside the primary `~/minerva`:

```sh
minerva-mount  ~/minerva-crc  /sc/arion/projects/Smith_Lab/users/jdoe/crc_atlas
minerva-status ~/minerva-crc          # check just that one
minerva-clear  ~/minerva-crc          # unmount just that one
```

`minerva-mount` with no arguments still manages your primary `~/minerva`. To make a
second mount a one-word command, add an alias to `~/.zshrc`:

```sh
alias minerva-crc='minerva-mount ~/minerva-crc /sc/arion/projects/Smith_Lab/users/jdoe/crc_atlas'
```

## How it's wired

- **Code is identical for everyone**; only settings differ. All settings live in
  `~/.config/minerva/minerva.conf`. Edit it, open a new shell — no reinstall.
- `~/bin/minerva-mount.sh` (the mount manager) reads that config and auto-detects
  `sshfs` under either Homebrew prefix.
- The installer manages a clearly-marked block in `~/.ssh/config` and `~/.zshrc`
  (`# >>> minerva-setup >>>` … `# <<< minerva-setup <<<`). Re-running replaces just
  that block; everything else in those files is left untouched.

## Customize later

- **Any setting:** edit `~/.config/minerva/minerva.conf`, then open a new shell.
- **Persist hours / username:** re-run `./minerva-setup.sh`, or edit the
  `~/.ssh/config` block directly.

## Security

**No password is stored.** Logins are plain `ssh`: you type your SSO password once
per `ControlMaster` window and approve the Duo push; nothing is written to disk and
nothing is visible in `ps`. Earlier versions auto-fed the password with `sshpass`
from `~/.minerva_password` — that kept your SSO password in cleartext **and**,
because `sshpass` can't answer Duo/MFA (and fed a blank password whenever the
variable was empty), generated background **failed-login attempts** that trip HPC
lockout/abuse alarms. Both are gone.

The mount is equally conservative: `sshfs` is pinned to your existing
`ControlMaster` with `BatchMode=yes` and runs **without** `-o reconnect`, so it can
**never** start a fresh login on its own. If the connection drops (sleep, Wi-Fi,
master expiry) the mount just goes stale instead of retrying auth in the
background — rerun `minerva-mount` (which only mounts when a live master exists) to
restore it.

## Credentials & uninstall

One command each — both ship as shell commands *and* installer flags, and both
back up `~/.zshrc` and `~/.ssh/config` to timestamped `.minerva-bak.<stamp>`
files before changing anything.

**Forget saved credentials:**

```sh
minerva-forget                 # remove any legacy saved-password file (settings stay)
minerva-forget --all           # also wipe saved settings (username, mount paths) + SSH identity
# from the repo, equivalently:  ./minerva-setup.sh --wipe-credentials [--all]
```

**Remove the whole setup** (restores your shell to how it was):

```sh
minerva-uninstall              # remove managed blocks, mount script, config (+ any legacy password file)
minerva-uninstall --purge      # also offer to uninstall the brew deps (FUSE-T)
# from the repo, equivalently:  ./minerva-setup.sh --uninstall [--purge]
```

Both leave your Homebrew packages alone unless you pass `--purge` and confirm.

## Troubleshoot

- *"Not writable by you" / "Permission denied"* (e.g. `~/.config`, `~/.zshrc`) →
  files in your home are owned by `root` (something ran under `sudo`). The installer
  detects this upfront. Fix it all at once, then re-run: `sudo chown -R "$(whoami)" ~`
- **Too many failed logins / HPC abuse warning?** Make sure no machine still runs
  the old `sshpass` aliases or an `sshfs … -o reconnect` mount: `pgrep -fl sshpass`
  and `pgrep -fl 'sshfs.*reconnect'` should both be empty. Re-run `./minerva-setup.sh`
  to install the current (plain-`ssh`, no-reconnect) tooling.
- `minerva-mount` says *"no live Minerva SSH master"* → log into a node first
  (`minerva13`), then `minerva-mount`. Mounting is on-demand by design.
- `~/minerva` looks stuck → `minerva-status` (safe, never hangs). If `PHANTOM`,
  run `minerva-clear`, then `minerva-mount`. You never need to reboot.
- Logs: `~/Library/Logs/minerva-mount.log`.

## Notes — using VS Code with Minerva (optional)

*Only relevant if you use VS Code Remote-SSH. These are recommendations — the
installer changes none of this.*

Minerva caps each user to **256 processes per login node** (512 hard). VS Code's
Remote-SSH server spawns many processes and leaves orphans behind on unclean
disconnects (sleep, network drops), so they pile up past the cap — you'll see
`fork: Resource temporarily unavailable` (even `ll` can fail) and Remote-SSH stops
connecting. To keep it working:

- **Raise your limit.** Put this as the *first* line of your Minerva `~/.bashrc`,
  above any non-interactive `return` guard so VS Code's server inherits it too:
  ```sh
  ulimit -Su 512   # 256 → 512, the hard cap
  ```
- **Close cleanly:** Command Palette → *"Remote-SSH: Kill VS Code Server on Host"*
  when done. The orphans come from unclean disconnects, not normal use.
- **Trim the footprint:** disable remote extensions you don't need (each language
  server = processes), use one window, and exclude big trees from the file watcher
  in the remote `settings.json`:
  ```jsonc
  "files.watcherExclude": { "**/.git/**": true, "**/conda/**": true, "**/data/**": true }
  ```
- **Already wedged?** From your machine:
  `ssh -o ControlPath=none <user>@minerva.hpc.mssm.edu 'pkill -9 -u "$USER" -f vscode-server'`
  (or email hpchelp@mssm.edu to clear them).
- **Just browsing/editing the file tree?** Open `~/minerva` as a **local** folder in
  VS Code — it reads through the mount with **zero** processes on Minerva.
- For heavy work, the robust path is Remote-SSH onto a **compute node** (interactive
  LSF job), not the login node — see Minerva's docs.

## Notes — Claude Code login on Minerva (headless, optional)

*Only relevant if you run Claude Code on a Minerva login node. The installer
changes none of this.*

The browser-based `claude` login often fails over SSH on a headless node — the
OAuth link can return **"Invalid OAuth Request — Unknown scope: user:session"**.
The reliable fix is to skip the in-browser handshake entirely and authenticate
with a pre-generated token (requires a Claude Pro/Max account):

1. **On your laptop** (where a browser opens normally), in a *plain terminal*
   — not backgrounded — run:
   ```sh
   claude setup-token
   ```
   Approve in the browser, then copy the token it prints (looks like
   `sk-ant-oat01-…`, ~108 chars). It must run in the *foreground* so the token
   actually prints — backgrounding it loses the token.
2. **On Minerva**, save the token to `~/.bash_profile` — **not** `~/.bashrc`.
   SSH login shells read `~/.bash_profile`; `~/.bashrc` is skipped on login, so a
   token placed there is silently absent in fresh sessions (→ 401):
   ```sh
   echo 'export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-PASTE-YOURS-HERE"' >> ~/.bash_profile
   # make a login shell also pull in ~/.bashrc, so every shell type gets the token:
   grep -q 'bashrc' ~/.bash_profile || echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.bash_profile
   source ~/.bash_profile
   echo "len=${#CLAUDE_CODE_OAUTH_TOKEN}"   # must print len=108
   ```
3. **Clear any stale stored credential.** A leftover `~/.claude/.credentials.json`
   from earlier failed `/login` attempts *shadows* the env token and keeps the
   401 coming even when the token is valid and present. Move it aside:
   ```sh
   [ -f ~/.claude/.credentials.json ] && mv ~/.claude/.credentials.json ~/.claude/.credentials.json.bak
   ```
4. **Launch:** `claude` — it reads the token from the environment and skips the
   login link. Confirm persistence across a fresh login (without logging out):
   ```sh
   bash -lc 'echo "fresh login sees len=${#CLAUDE_CODE_OAUTH_TOKEN}"'   # want len=108
   ```
   After this, your routine is just: SSH in → `claude`.

Notes:
- This is *not* a version bug — it happens even on the latest `claude` (check
  `claude --version`), so **reinstalling won't help** (it also leaves `~/.claude`
  untouched, where the stale credential lives). The token path sidesteps it.
- The 401 shows as **"Invalid API key · Please run /login"** even though you used
  a *token*, not an API key — Claude prints that generic message for any 401.
  It does **not** mean an API key is configured.
- With token auth, `/status` shows a leaner panel than an interactive login does.
  That's expected — same access, different display.
- **Treat the token like a password.** Don't commit it to any repo or shared
  script. To revoke a token, manage active sessions/tokens in your Anthropic
  account settings (claude.ai → Settings → Claude Code), then generate a fresh one.
  Note: generating a new token does *not* invalidate old ones — revoke explicitly.

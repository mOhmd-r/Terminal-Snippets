# Terminal-Snippets

Safe, local-first terminal command snippets for **SRE, DevOps, Linux, Docker, SSH, and infrastructure operations**, powered by [navi](https://github.com/denisidoro/navi) and tmux.

The design goal is deliberately conservative:

- snippets stay local,
- `Ctrl-G` opens the local picker,
- the same local snippets remain usable inside SSH sessions,
- selected commands are **pasted only**,
- commands are **never auto-executed**,
- secrets do not belong in cheatsheets.

## How it works

```text
Local workstation
└── tmux
    └── local shell or SSH session
        └── Ctrl-G
            └── local navi popup
                └── select snippet
                    └── safety validation
                        └── paste into current pane
                            └── manual review + Enter
```

## Prerequisites

Install these tools from their official projects:

- [navi](https://github.com/denisidoro/navi)
- [fzf](https://github.com/junegunn/fzf)
- [tmux](https://github.com/tmux/tmux)

`install.sh` intentionally does **not** download or install third-party binaries. If a dependency is missing, it prints the official project links and exits.

## Install

```bash
git clone https://github.com/mOhmd-r/Terminal-Snippets.git
cd Terminal-Snippets
bash install.sh
```

The installer:

- verifies `navi`, `fzf`, and `tmux`,
- sets `NAVI_PATH` to the cloned repository,
- adds `~/.local/bin` to `PATH`,
- installs the hardened helper as `~/.local/bin/navi-safe-paste`,
- binds `Ctrl-G` in tmux,
- reloads an active tmux server when possible,
- validates the installed helper and SSH hardening script,
- cleans up configuration blocks created by older versions of this project.

The installer is idempotent. Re-running it replaces its managed blocks instead of duplicating them.

For safety, the installer refuses to rewrite symlinked shell or tmux configuration files. If your dotfile manager uses symlinks for `.bashrc`, `.zshrc`, `.profile`, or `.tmux.conf`, add the documented managed block to the real source file instead of running the automatic installer.

## Test

Start tmux locally:

```bash
tmux new -s sre
```

Press:

```text
Ctrl-G
```

Choose a harmless command such as:

```bash
df -h /
```

Expected behavior:

```text
df -h /
```

appears on the prompt, but **does not execute**. Review it and press `Enter` yourself.

### SSH test

Start SSH **from inside local tmux**:

```bash
ssh user@server
```

Then press `Ctrl-G`.

The picker still runs on the local workstation, while the selected command is pasted into the remote shell. It still does not execute automatically.

## Validate later

```bash
bash install.sh --check
```

## Included cheatsheets

```text
os.cheat
docker.cheat
ssh.cheat
```

### OS snippets

Includes:

- APT update through a per-command proxy
- workstation-wide maintenance for APT + Snap + Homebrew + pipx when present
- APT full maintenance
- hold-aware conservative APT upgrade
- individual APT / Snap / Homebrew / pipx / Flatpak update commands

The project intentionally avoids blanket `sudo pip` upgrades of Ubuntu's system Python.

### Docker snippets

Includes:

- find large Docker JSON logs by container
- prune unused images older than 24 hours
- download Docker's convenience installer with or without an HTTP proxy
- dry-run the installer before execution
- run the reviewed installer with temporary proxy environment variables
- install Docker Compose v2 from configured APT repositories
- install Docker packages after the official Docker APT repository has been configured

For production systems, prefer Docker's official repository installation guidance over the convenience script.

### SSH snippets

Includes a guarded SSH hardening helper:

```bash
sudo "$NAVI_PATH/scripts/harden_ssh.sh"
```

It:

- changes the SSH listening port,
- disables password authentication,
- disables keyboard-interactive authentication,
- explicitly keeps public-key authentication enabled,
- validates `sshd` before applying changes,
- requires a safe, non-empty `authorized_keys` file for the invoking sudo user,
- refuses direct root execution and must be run through `sudo` by the account whose key login will be tested,
- evaluates authentication and port settings with an `sshd -T -C` user/host/client context so applicable `Match` blocks are included,
- uses SSH and systemd drop-ins instead of editing vendor unit files,
- backs up the SSH configuration,
- adds the new UFW rule before switching listeners when UFW is active,
- deliberately keeps the old TCP/22 firewall rule,
- requires confirmation after a successful second login and automatically rolls
  back SSH configuration, the listener, and a newly added UFW rule on failure,
  interruption, disconnect, or confirmation timeout.

Keep the current SSH session open, verify the new connection from a second
terminal, then type the exact confirmation shown by the helper.

## Security

Never store secrets in cheatsheets:

- passwords
- API tokens
- private keys
- kubeconfig credentials
- database credentials
- Redis credentials
- cloud credentials

The paste helper rejects multiline selections, terminal control characters, invalid destination panes, and unexpectedly large selections. It never sends `Enter`.

Also treat navi dynamic variables and imported third-party cheatsheets as executable code. Review them before adding them.

See [SECURITY.md](SECURITY.md).

## Third-party software

This repository does not vendor or redistribute navi, fzf, or tmux. Their project links and license information are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE).

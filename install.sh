#!/usr/bin/env bash
set -Eeuo pipefail

APP="terminal-snippets"
START_MARKER="# >>> ${APP} >>>"
END_MARKER="# <<< ${APP} <<<"

# Previous project marker used by older releases. It is removed during migration.
LEGACY_START_MARKER="# >>> navi-safe-snippets >>>"
LEGACY_END_MARKER="# <<< navi-safe-snippets <<<"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NAVI_DIR="${REPO_DIR}"
LOCAL_BIN="${HOME}/.local/bin"
HELPER="${LOCAL_BIN}/navi-safe-paste"
TMUX_CONF="${HOME}/.tmux.conf"

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

show_refs() {
  cat <<'EOF'

Install missing prerequisites from their official projects:

  navi:
    https://github.com/denisidoro/navi

  fzf:
    https://github.com/junegunn/fzf

  tmux:
    https://github.com/tmux/tmux

This installer intentionally does not download or install third-party binaries.
After installing the missing prerequisite(s), run this script again.
EOF
}

check_prerequisites() {
  local missing=0 cmd

  for cmd in navi fzf tmux; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '[OK]      %-5s -> %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '[MISSING] %s\n' "$cmd" >&2
      missing=1
    fi
  done

  if (( missing )); then
    show_refs
    exit 2
  fi
}

validate_repo() {
  [[ -f "${REPO_DIR}/os.cheat" ]] || die "Missing os.cheat"
  [[ -f "${REPO_DIR}/docker.cheat" ]] || die "Missing docker.cheat"
  [[ -f "${REPO_DIR}/ssh.cheat" ]] || die "Missing ssh.cheat"
  [[ -f "${REPO_DIR}/scripts/harden_ssh.sh" ]] || die "Missing scripts/harden_ssh.sh"
}

choose_shell_rc() {
  case "$(basename "${SHELL:-}")" in
    bash) printf '%s\n' "${HOME}/.bashrc" ;;
    zsh)  printf '%s\n' "${HOME}/.zshrc" ;;
    *)
      warn "Unknown shell: ${SHELL:-unset}; using ${HOME}/.profile"
      printf '%s\n' "${HOME}/.profile"
      ;;
  esac
}

remove_block() {
  local file="$1"
  local start="$2"
  local end="$3"
  local tmp start_count end_count

  if [[ -L "$file" ]]; then
    die "Refusing to rewrite symlinked configuration file: ${file}"
  fi
  mkdir -p "$(dirname "$file")"
  touch "$file"
  [[ -f "$file" ]] || die "Configuration path is not a regular file: ${file}"

  start_count="$(grep -Fxc "$start" "$file" || true)"
  end_count="$(grep -Fxc "$end" "$file" || true)"
  if (( start_count != end_count || start_count > 1 )); then
    die "Managed markers are malformed in ${file}; refusing to rewrite it."
  fi

  tmp="$(mktemp "${file}.terminal-snippets.XXXXXX")"
  chmod --reference="$file" "$tmp"

  awk -v start="$start" -v end="$end" '
    $0 == start {
      if (skip || seen) bad=1
      skip=1
      seen=1
      next
    }
    $0 == end {
      if (!skip) bad=1
      skip=0
      next
    }
    !skip       { print }
    END {
      if (skip) bad=1
      if (bad) exit 42
    }
  ' "$file" > "$tmp" || {
    rm -f -- "$tmp"
    die "Managed marker order is invalid in ${file}; no changes were made."
  }

  mv -f -- "$tmp" "$file"
}

remove_managed_blocks() {
  local file="$1"

  remove_block "$file" "$START_MARKER" "$END_MARKER"
  remove_block "$file" "$LEGACY_START_MARKER" "$LEGACY_END_MARKER"
}

configure_shell() {
  local rc_file="$1"

  remove_managed_blocks "$rc_file"

  {
    printf '\n%s\n' "$START_MARKER"
    # HOME and PATH must expand when the user's shell loads this file.
    # shellcheck disable=SC2016
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    printf 'export NAVI_PATH="%s"\n' "$NAVI_DIR"
    printf '%s\n' "$END_MARKER"
  } >> "$rc_file"

  info "Configured shell environment in ${rc_file}"
}

install_helper() {
  local tmp navi_q

  mkdir -p "$LOCAL_BIN"
  tmp="$(mktemp)"
  printf -v navi_q '%q' "$NAVI_DIR"

  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

export NAVI_PATH=${navi_q}
target="\${NAVI_TARGET:-}"

if [[ ! "\$target" =~ ^%[0-9]+$ ]]; then
  printf 'Blocked: invalid or missing tmux target pane.\n' >&2
  exit 1
fi

resolved="\$(tmux display-message -p -t "\$target" '#{pane_id}' 2>/dev/null || true)"

if [[ "\$resolved" != "\$target" ]]; then
  printf 'Blocked: target pane no longer exists.\n' >&2
  exit 1
fi

if ! selected="\$(navi --print)"; then
  exit 0
fi

[[ -n "\$selected" ]] || exit 0

if [[ "\$selected" == *\$'\n'* || "\$selected" == *\$'\r'* ]]; then
  printf 'Blocked: multi-line snippets are not allowed.\n' >&2
  sleep 2
  exit 1
fi

if printf '%s' "\$selected" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  printf 'Blocked: snippet contains terminal control characters.\n' >&2
  sleep 2
  exit 1
fi

if (( \${#selected} > 16384 )); then
  printf 'Blocked: snippet is unexpectedly large.\n' >&2
  sleep 2
  exit 1
fi

buffer="terminal-snippets-\$\$"

cleanup() {
  tmux delete-buffer -b "\$buffer" 2>/dev/null || true
}

trap cleanup EXIT HUP INT TERM

printf '%s' "\$selected" | tmux load-buffer -b "\$buffer" -
tmux paste-buffer -p -t "\$target" -b "\$buffer" -d

trap - EXIT
EOF

  bash -n "$tmp"
  install -m 700 "$tmp" "$HELPER"
  rm -f "$tmp"

  info "Installed hardened helper: ${HELPER}"
}

configure_tmux() {
  remove_managed_blocks "$TMUX_CONF"

  {
    printf '\n%s\n' "$START_MARKER"
    printf '%s\n' '# Ctrl-G opens local Navi and only pastes the selected command.'
    # HOME and the tmux pane format are intentionally evaluated at runtime.
    # shellcheck disable=SC2016
    printf '%s\n' 'bind-key -n C-g run-shell '\''tmux display-popup -E -w 85% -h 85% "NAVI_TARGET=#{pane_id} $HOME/.local/bin/navi-safe-paste"'\'''
    printf '%s\n' "$END_MARKER"
  } >> "$TMUX_CONF"

  info "Configured tmux binding in ${TMUX_CONF}"

  if tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$TMUX_CONF"
    info "Reloaded active tmux server"
  else
    info "No active tmux server; config will load with the next tmux session"
  fi
}

run_checks() {
  local count

  printf '\n--- Validation ---\n'

  bash -n "$HELPER"
  bash -n "${REPO_DIR}/scripts/harden_ssh.sh"

  [[ -x "$HELPER" ]] || die "Helper is not executable"

  count="$(find "$NAVI_DIR" -maxdepth 1 -type f -name '*.cheat' | wc -l | tr -d ' ')"

  printf '[OK] helper syntax\n'
  printf '[OK] SSH helper syntax\n'
  printf '[OK] helper executable\n'
  printf '[OK] cheatsheets: %s\n' "$count"
  printf '[OK] navi: %s\n' "$(navi --version | head -n1)"
  printf '[OK] fzf:  %s\n' "$(fzf --version | head -n1)"
  printf '[OK] tmux: %s\n' "$(tmux -V)"

  if grep -Fq "$START_MARKER" "$TMUX_CONF"; then
    printf '[OK] tmux managed block\n'
  else
    die "tmux managed block not found"
  fi
}

print_next_steps() {
  cat <<'EOF'

Setup complete.

Reload your shell:

  bash:
    source ~/.bashrc

  zsh:
    source ~/.zshrc

Start local tmux:

  tmux new -s sre

Press Ctrl-G and select a harmless command.

Expected behavior:
  The command is pasted at the prompt but is NOT executed.
  Review it and press Enter manually.

SSH test:
  Start SSH from inside local tmux:

    ssh user@server

  Press Ctrl-G again.

Security:
  - Never store secrets in cheatsheets.
  - Multi-line selections and terminal control characters are blocked.
  - The helper never sends Enter.
EOF
}

main() {
  check_prerequisites
  validate_repo

  if [[ "${1:-}" == "--check" ]]; then
    [[ -f "$HELPER" ]] || die "Helper is not installed: ${HELPER}"
    run_checks
    exit 0
  fi

  local rc_file
  rc_file="$(choose_shell_rc)"

  configure_shell "$rc_file"
  chmod 700 "${REPO_DIR}/scripts/harden_ssh.sh"
  install_helper
  configure_tmux
  run_checks
  print_next_steps
}

main "$@"

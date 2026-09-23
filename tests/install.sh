#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home"

cat > "$TEST_ROOT/bin/navi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf 'navi test\n'
EOF
cat > "$TEST_ROOT/bin/fzf" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && printf 'fzf test\n'
EOF
cat > "$TEST_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -V) printf 'tmux test\n' ;;
  list-sessions) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$TEST_ROOT/bin/"*

export HOME="$TEST_ROOT/home"
export SHELL=/bin/bash
export PATH="$TEST_ROOT/bin:/usr/bin:/bin"

start='# >>> terminal-snippets >>>'
printf 'preserve me\n%s\nunterminated\n' "$start" > "$HOME/.bashrc"
before="$(sha256sum "$HOME/.bashrc")"
if bash "$PROJECT_DIR/install.sh" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
  printf 'Installer unexpectedly accepted an unmatched marker.\n' >&2
  exit 1
fi
after="$(sha256sum "$HOME/.bashrc")"
[[ "$before" == "$after" ]] || {
  printf 'Malformed-marker failure changed the shell configuration.\n' >&2
  exit 1
}

printf 'preserve me\n' > "$HOME/.bashrc"
bash "$PROJECT_DIR/install.sh" >/dev/null
grep -Fqx '# >>> terminal-snippets >>>' "$HOME/.bashrc"
grep -Fqx '# <<< terminal-snippets <<<' "$HOME/.bashrc"
bash "$PROJECT_DIR/install.sh" >/dev/null
[[ "$(grep -Fxc '# >>> terminal-snippets >>>' "$HOME/.bashrc")" == "1" ]]
[[ "$(grep -Fxc '# <<< terminal-snippets <<<' "$HOME/.bashrc")" == "1" ]]
grep -Fqx 'preserve me' "$HOME/.bashrc"

printf 'Installer safety tests passed.\n'

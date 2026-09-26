#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/ssh/sshd_config.d"
DROPIN="${CONFIG_DIR}/00-terminal-snippets-hardening.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN="${SOCKET_DROPIN_DIR}/00-terminal-snippets-port.conf"
BACKUP_ROOT="/var/backups/terminal-snippets-ssh"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR=""
CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-300}"

ROLLBACK_ARMED=false
SOCKET_MODE=0
SERVICE=""
UFW_RULE_ADDED=false

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo $0"
[[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && -n "${SUDO_UID:-}" ]] ||
  die "Run through sudo from the account whose key login you will test; direct root execution is refused."
command -v sshd >/dev/null 2>&1 || die "sshd was not found. Install OpenSSH server first."
command -v systemctl >/dev/null 2>&1 || die "systemd is required by this script."
command -v ss >/dev/null 2>&1 || die "ss is required by this script."
command -v tar >/dev/null 2>&1 || die "tar is required by this script."
command -v stat >/dev/null 2>&1 || die "stat is required by this script."
command -v getent >/dev/null 2>&1 || die "getent is required by this script."
if [[ ! "$CONFIRM_TIMEOUT" =~ ^[0-9]+$ ]] ||
   (( CONFIRM_TIMEOUT < 60 || CONFIRM_TIMEOUT > 900 )); then
  die "CONFIRM_TIMEOUT must be between 60 and 900 seconds."
fi

SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
[[ -n "$SUDO_HOME" ]] || die "Could not determine the invoking user's home directory."
SSHD_TEST_HOST="$(hostname -f 2>/dev/null || hostname)"
SSHD_TEST_ADDR="${SSH_CONNECTION%% *}"
if [[ -z "${SSH_CONNECTION:-}" || "$SSHD_TEST_ADDR" == "$SSH_CONNECTION" ]]; then
  SSHD_TEST_ADDR="127.0.0.1"
  warn "No SSH client address was detected; Match Address validation uses 127.0.0.1. The mandatory second-login test remains authoritative."
fi
SSHD_CONTEXT=(-C "user=${SUDO_USER},host=${SSHD_TEST_HOST},addr=${SSHD_TEST_ADDR}")

cat <<'EOF'
This script will:
  - change the SSH listening port,
  - disable PasswordAuthentication,
  - disable KbdInteractiveAuthentication,
  - explicitly keep PubkeyAuthentication enabled,
  - use drop-in files instead of editing vendor systemd units,
  - validate sshd before changing the listener,
  - add the new UFW port first when UFW is active,
  - keep the old TCP/22 firewall rule to reduce lockout risk.

Keep the current SSH session open until a second connection to the new port succeeds.
EOF

AUTH_KEYS="${SUDO_HOME}/.ssh/authorized_keys"
[[ -s "$AUTH_KEYS" && -f "$AUTH_KEYS" && ! -L "$AUTH_KEYS" ]] ||
  die "A regular, non-empty ${AUTH_KEYS} is required before password authentication can be disabled."
[[ "$(stat -c '%u' "$AUTH_KEYS")" == "${SUDO_UID}" ]] ||
  die "${AUTH_KEYS} must be owned by ${SUDO_USER}."
(( (8#$(stat -c '%a' "$AUTH_KEYS") & 8#022) == 0 )) ||
  die "${AUTH_KEYS} must not be group- or world-writable."

while true; do
  read -r -p "New SSH port [1024-65535, not 22]: " NEW_PORT
  if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] &&
     (( NEW_PORT >= 1024 && NEW_PORT <= 65535 )) &&
     (( NEW_PORT != 22 )); then
    break
  fi
  warn "Invalid port."
done

if ss -ltnH "sport = :${NEW_PORT}" 2>/dev/null | grep -q .; then
  die "TCP port ${NEW_PORT} is already listening."
fi

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/${STAMP}.XXXXXX")"
chmod 700 "$BACKUP_DIR"

tar -C / -czf "${BACKUP_DIR}/etc-ssh.tgz" etc/ssh

if [[ -d "$SOCKET_DROPIN_DIR" ]]; then
  tar -C / -czf "${BACKUP_DIR}/ssh-socket-dropins.tgz" etc/systemd/system/ssh.socket.d
fi

log "Backup created under ${BACKUP_DIR}"

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$ROLLBACK_ARMED" == "true" ]]; then
    set +e
    warn "Hardening was not confirmed; restoring the saved SSH configuration."
    rm -f -- "$DROPIN" "$SOCKET_DROPIN"
    tar -C / -xzf "${BACKUP_DIR}/etc-ssh.tgz"
    if [[ -f "${BACKUP_DIR}/ssh-socket-dropins.tgz" ]]; then
      tar -C / -xzf "${BACKUP_DIR}/ssh-socket-dropins.tgz"
    else
      rmdir "$SOCKET_DROPIN_DIR" 2>/dev/null || true
    fi
    systemctl daemon-reload
    if (( SOCKET_MODE )); then
      systemctl restart ssh.socket || warn "Automatic ssh.socket rollback restart failed."
    else
      if [[ -z "$SERVICE" ]]; then
        systemctl cat ssh.service >/dev/null 2>&1 && SERVICE="ssh.service"
        [[ -n "$SERVICE" ]] || { systemctl cat sshd.service >/dev/null 2>&1 && SERVICE="sshd.service"; }
      fi
      [[ -z "$SERVICE" ]] || systemctl restart "$SERVICE" ||
        warn "Automatic SSH service rollback restart failed."
    fi
    if [[ "$UFW_RULE_ADDED" == "true" ]]; then
      ufw --force delete allow "${NEW_PORT}/tcp" >/dev/null 2>&1 ||
        warn "Could not remove the newly added UFW rule for ${NEW_PORT}/tcp."
    fi
    warn "Rollback attempted. Backup retained at ${BACKUP_DIR}."
  fi
  exit "$status"
}

ROLLBACK_ARMED=true
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$CONFIG_DIR"

DROPIN_TMP="$(mktemp "${CONFIG_DIR}/.terminal-snippets.XXXXXX")"
cat > "$DROPIN_TMP" <<EOF
# Managed by Terminal-Snippets
Port ${NEW_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 600 "$DROPIN_TMP"
mv -f -- "$DROPIN_TMP" "$DROPIN"

if ! sshd -t; then
  rm -f "$DROPIN"
  die "sshd validation failed. New SSH drop-in was removed."
fi

EFFECTIVE_PASSWORD="$(sshd -T "${SSHD_CONTEXT[@]}" | awk '$1=="passwordauthentication"{print $2; exit}')"
EFFECTIVE_KBD="$(sshd -T "${SSHD_CONTEXT[@]}" | awk '$1=="kbdinteractiveauthentication"{print $2; exit}')"
EFFECTIVE_PUBKEY="$(sshd -T "${SSHD_CONTEXT[@]}" | awk '$1=="pubkeyauthentication"{print $2; exit}')"

if [[ "$EFFECTIVE_PASSWORD" != "no" ||
      "$EFFECTIVE_KBD" != "no" ||
      "$EFFECTIVE_PUBKEY" != "yes" ]]; then
  rm -f "$DROPIN"
  die "Effective SSH authentication settings do not match the requested hardening. No listener changes were made."
fi

if systemctl cat ssh.socket >/dev/null 2>&1 &&
   { systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; }; then
  SOCKET_MODE=1

  mkdir -p "$SOCKET_DROPIN_DIR"

  SOCKET_TMP="$(mktemp "${SOCKET_DROPIN_DIR}/.terminal-snippets.XXXXXX")"
  cat > "$SOCKET_TMP" <<EOF
[Socket]
ListenStream=
ListenStream=${NEW_PORT}
EOF

  chmod 644 "$SOCKET_TMP"
  mv -f -- "$SOCKET_TMP" "$SOCKET_DROPIN"
  log "Prepared ssh.socket override for TCP ${NEW_PORT}"
else
  mapfile -t EFFECTIVE_PORTS < <(sshd -T "${SSHD_CONTEXT[@]}" | awk '$1=="port"{print $2}')

  if [[ "${#EFFECTIVE_PORTS[@]}" -ne 1 || "${EFFECTIVE_PORTS[0]}" != "$NEW_PORT" ]]; then
    rm -f "$DROPIN"
    die "Effective sshd port configuration is not exactly ${NEW_PORT}. Check existing SSH configuration before retrying."
  fi
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log "UFW is active; allowing ${NEW_PORT}/tcp before changing the listener."
  if ! ufw status | grep -Eq "^${NEW_PORT}/tcp([[:space:]]|$)"; then
    ufw allow "${NEW_PORT}/tcp"
    UFW_RULE_ADDED=true
  else
    log "An existing UFW rule already allows ${NEW_PORT}/tcp."
  fi
  warn "TCP/22 was intentionally left allowed until a second SSH login is verified."
else
  warn "UFW is inactive or unavailable."
  warn "Verify nftables, cloud security groups, or external firewall rules manually."
fi

systemctl daemon-reload

if (( SOCKET_MODE )); then
  if ! systemctl restart ssh.socket; then
    die "Failed to restart ssh.socket. Keep this session open and inspect systemd state."
  fi
else
  SERVICE=""

  if systemctl cat ssh.service >/dev/null 2>&1; then
    SERVICE="ssh.service"
  elif systemctl cat sshd.service >/dev/null 2>&1; then
    SERVICE="sshd.service"
  else
    die "Neither ssh.service nor sshd.service was found."
  fi

  if ! systemctl reload "$SERVICE"; then
    warn "Reload failed; attempting restart."
    systemctl restart "$SERVICE"
  fi
fi

sleep 1

if ! ss -ltnH "sport = :${NEW_PORT}" 2>/dev/null | grep -q .; then
  warn "Could not verify a TCP listener on ${NEW_PORT}."
  warn "DO NOT close this session."
  warn "Inspect: systemctl status ssh.socket ssh.service sshd.service"
  die "Listener verification failed; automatic rollback will run."
fi

cat <<EOF

The new listener is active, but the change is not committed yet.
Open a second terminal now and verify:

  ssh -p ${NEW_PORT} <user>@<server>

After that login succeeds, type KEEP below. If you disconnect, interrupt this
script, or do not confirm within ${CONFIRM_TIMEOUT} seconds, the saved SSH
configuration and any newly added UFW rule will be restored automatically.
EOF

if ! read -r -t "$CONFIRM_TIMEOUT" -p "Type KEEP after a successful second login: " CONFIRMATION ||
   [[ "$CONFIRMATION" != "KEEP" ]]; then
  die "Confirmation was not received; automatic rollback will run."
fi

ROLLBACK_ARMED=false
trap - EXIT INT TERM

cat <<EOF

SSH hardening applied.

New port:
  ${NEW_PORT}

Authentication:
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PubkeyAuthentication yes

Backup:
  ${BACKUP_DIR}

TEST NOW FROM A SECOND TERMINAL:

  ssh -p ${NEW_PORT} <user>@<server>

Only after the new connection succeeds should you consider removing the old
TCP/22 firewall rule.

Useful checks:

  sshd -T -C 'user=${SUDO_USER},host=${SSHD_TEST_HOST},addr=${SSHD_TEST_ADDR}' | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
  ss -ltnp | grep ':${NEW_PORT}'

Keep this current SSH session open until the second login is confirmed.
EOF

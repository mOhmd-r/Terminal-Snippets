#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/ssh/sshd_config.d"
DROPIN="${CONFIG_DIR}/00-terminal-snippets-hardening.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN="${SOCKET_DROPIN_DIR}/00-terminal-snippets-port.conf"
BACKUP_ROOT="/var/backups/terminal-snippets-ssh"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo $0"
command -v sshd >/dev/null 2>&1 || die "sshd was not found. Install OpenSSH server first."
command -v systemctl >/dev/null 2>&1 || die "systemd is required by this script."
command -v ss >/dev/null 2>&1 || die "ss is required by this script."

SUDO_HOME=""
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
fi

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

if [[ -n "$SUDO_HOME" ]]; then
  AUTH_KEYS="${SUDO_HOME}/.ssh/authorized_keys"
  if [[ ! -s "$AUTH_KEYS" ]]; then
    warn "No non-empty ${AUTH_KEYS} found for sudo user ${SUDO_USER}."
    warn "Confirm key-based login works before continuing."
  fi
fi

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

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

tar -C / -czf "${BACKUP_DIR}/etc-ssh.tgz" etc/ssh

if [[ -d "$SOCKET_DROPIN_DIR" ]]; then
  tar -C / -czf "${BACKUP_DIR}/ssh-socket-dropins.tgz" etc/systemd/system/ssh.socket.d
fi

log "Backup created under ${BACKUP_DIR}"

mkdir -p "$CONFIG_DIR"

cat > "$DROPIN" <<EOF
# Managed by Terminal-Snippets
Port ${NEW_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 600 "$DROPIN"

if ! sshd -t; then
  rm -f "$DROPIN"
  die "sshd validation failed. New SSH drop-in was removed."
fi

EFFECTIVE_PASSWORD="$(sshd -T | awk '$1=="passwordauthentication"{print $2; exit}')"
EFFECTIVE_KBD="$(sshd -T | awk '$1=="kbdinteractiveauthentication"{print $2; exit}')"
EFFECTIVE_PUBKEY="$(sshd -T | awk '$1=="pubkeyauthentication"{print $2; exit}')"

if [[ "$EFFECTIVE_PASSWORD" != "no" ||
      "$EFFECTIVE_KBD" != "no" ||
      "$EFFECTIVE_PUBKEY" != "yes" ]]; then
  rm -f "$DROPIN"
  die "Effective SSH authentication settings do not match the requested hardening. No listener changes were made."
fi

SOCKET_MODE=0

if systemctl cat ssh.socket >/dev/null 2>&1 &&
   { systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; }; then
  SOCKET_MODE=1

  mkdir -p "$SOCKET_DROPIN_DIR"

  cat > "$SOCKET_DROPIN" <<EOF
[Socket]
ListenStream=
ListenStream=${NEW_PORT}
EOF

  chmod 644 "$SOCKET_DROPIN"
  log "Prepared ssh.socket override for TCP ${NEW_PORT}"
else
  mapfile -t EFFECTIVE_PORTS < <(sshd -T | awk '$1=="port"{print $2}')

  if [[ "${#EFFECTIVE_PORTS[@]}" -ne 1 || "${EFFECTIVE_PORTS[0]}" != "$NEW_PORT" ]]; then
    rm -f "$DROPIN"
    die "Effective sshd port configuration is not exactly ${NEW_PORT}. Check existing SSH configuration before retrying."
  fi
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log "UFW is active; allowing ${NEW_PORT}/tcp before changing the listener."
  ufw allow "${NEW_PORT}/tcp"
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
  exit 1
fi

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

  sshd -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
  ss -ltnp | grep ':${NEW_PORT}'

Keep this current SSH session open until the second login is confirmed.
EOF

#!/usr/bin/env bash
# ===========================================================================
#  entrypoint.sh -- pre-start configuration for the OpenSSH SFTP server
#
#  Responsibilities:
#    1. generate host keys (if missing)
#    2. create user account(s) from the provided uid/gid/home/ssh key
#    3. generate sshd_config with chroot + internal-sftp settings
#    4. start sshd (arguments are passed through from CMD)
# ===========================================================================
set -euo pipefail

# Preserve the CMD arguments (the parsing below must NOT overwrite them).
MAIN_CMD=("$@")

log() { printf '[sftp-init] %s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# 1. Defaults / environment variables
# --------------------------------------------------------------------------
# NOTE: ${VAR-default} (no colon) is used on purpose, so an explicitly empty
#       SFTP_USER stays empty and disables the built-in primary user. This is
#       the recommended mode for multiuser deployments driven by users.conf.
SFTP_USER="${SFTP_USER-sftpuser}"
SFTP_UID="${SFTP_UID:-1000}"
SFTP_GID="${SFTP_GID:-1000}"

# Base directory for chroots. Non-primary (extra) users live under:
#   <SFTP_CHROOT_BASE>/<user>/...
SFTP_CHROOT_BASE="${SFTP_CHROOT_BASE:-/sftp}"

# The actual home directory the user logs into and can write to.
# The chroot is its PARENT directory (the chroot root is root-owned and must
# not be writable by the user).
SFTP_HOME="${SFTP_HOME:-${SFTP_CHROOT_BASE}/${SFTP_USER}/data}"

# Login authentication
SFTP_PASSWORD="${SFTP_PASSWORD:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_AUTHORIZED_KEYS_FILE="${SSH_AUTHORIZED_KEYS_FILE:-}"

# Network / logging
SFTP_PORT="${SFTP_PORT:-22}"
SFTP_LISTEN="${SFTP_LISTEN:-0.0.0.0}"
SFTP_LOG_LEVEL="${SFTP_LOG_LEVEL:-INFO}"
SFTP_HOST_KEY_DIR="${SFTP_HOST_KEY_DIR:-/etc/ssh}"

# Persistent logging (daily files: <dir>/sshd-YYYYMMDD.log)
SFTP_LOG_DIR="${SFTP_LOG_DIR:-/var/log/sftp}"
SFTP_LOG_RETENTION_DAYS="${SFTP_LOG_RETENTION_DAYS:-14}"

# Output umask so files created by users get predictable permissions.
SFTP_UMASK="${SFTP_UMASK:-0022}"

# Directory holding the extra-users configuration
SFTP_CONF_DIR="${SFTP_CONF_DIR:-/etc/sftp}"

SSHD_CONFIG="/etc/ssh/sshd_config"

# Count of users actually created (used to fail fast on a misconfiguration)
USERS_CREATED=0

# --------------------------------------------------------------------------
# 2. Start logging (rsyslog -> daily files + stdout)
# --------------------------------------------------------------------------
RSYSLOG_OK=0
RSYSLOG_PID=""

start_logging() {
    mkdir -p "$SFTP_LOG_DIR" /var/spool/rsyslog /run

    # compress old logs + apply retention (before rsyslog starts)
    SFTP_LOG_DIR="$SFTP_LOG_DIR" \
    SFTP_LOG_RETENTION_DAYS="$SFTP_LOG_RETENTION_DAYS" \
        /usr/local/bin/rotate-logs.sh || true

    log "starting rsyslog (daily logs: ${SFTP_LOG_DIR}/sshd-YYYYMMDD.log, retention: ${SFTP_LOG_RETENTION_DAYS} days)"
    rsyslogd -n &
    RSYSLOG_PID=$!

    # wait for the /dev/log socket (up to ~5s)
    local i
    for i in $(seq 1 50); do
        [[ -S /dev/log ]] && break
        kill -0 "$RSYSLOG_PID" 2>/dev/null || break
        sleep 0.1
    done

    if [[ -S /dev/log ]] && kill -0 "$RSYSLOG_PID" 2>/dev/null; then
        RSYSLOG_OK=1
        log "rsyslog is running (pid $RSYSLOG_PID), /dev/log ready"
    else
        log "WARNING: rsyslog failed to start -- logs will go to stderr (docker logs) only"
    fi
}

# --------------------------------------------------------------------------
# 3. Host keys
# --------------------------------------------------------------------------
generate_host_keys() {
    local type key
    for type in ed25519 rsa; do
        key="${SFTP_HOST_KEY_DIR}/ssh_host_${type}_key"
        if [[ ! -f "$key" ]]; then
            log "generating host key: $type"
            ssh-keygen -q -t "$type" -N '' -f "$key"
        fi
        chmod 600 "$key"
    done
    # sshd requires the config to be owned by root.
    chown root:root "$SSHD_CONFIG" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# 4. Create a user
#    $1 name  $2 uid  $3 gid  $4 home (absolute path)
#    $5 public key(s) content ("" = none)
#    $6 password ("" = none)
# --------------------------------------------------------------------------
create_user() {
    local name="$1" uid="$2" gid="$3" home="$4" pubkey="$5" password="$6"
    local group chroot

    chroot="$(dirname "$home")"

    # ---- group ----
    if getent group "$gid" >/dev/null 2>&1; then
        group="$(getent group "$gid" | cut -d: -f1)"
        log "gid=$gid already exists, using group: $group"
    else
        addgroup -g "$gid" "$name"
        group="$name"
    fi

    # ---- user ----
    if id "$name" >/dev/null 2>&1; then
        log "user already exists: $name"
        usermod -u "$uid" -g "$group" -d "$home" "$name" 2>/dev/null || true
    else
        adduser -D -H -u "$uid" -G "$group" -s /sbin/nologin -h "$home" "$name"
    fi

    # ---- directories ----
    # The chroot root MUST be root-owned and not group/world writable, otherwise
    # sshd refuses to log the user in ("bad ownership or modes for chroot
    # directory").
    mkdir -p "$chroot" "$home"
    chown root:root "$chroot"
    chmod 0755 "$chroot"

    chown "${uid}:${gid}" "$home"
    chmod 0755 "$home"

    # ---- password / unlock the account ----
    # `adduser` creates a locked account by default ("!" in /etc/shadow), and
    # OpenSSH rejects a locked account EVEN for public-key logins
    # ("User ... not allowed because account is locked"). So we always set a
    # password: the user-provided one if any, otherwise a random, unknown value
    # (pubkey-only mode).
    if [[ -n "$password" ]]; then
        printf '%s:%s\n' "$name" "$password" | chpasswd
        log "password authentication configured: $name"
    else
        local rand_pw
        rand_pw="$(head -c 48 /dev/urandom | base64)"
        printf '%s:%s\n' "$name" "$rand_pw" | chpasswd
        log "account unlocked (pubkey-only, random password): $name"
    fi

    # ---- public key(s) ----
    if [[ -n "$pubkey" ]]; then
        install -d -m 0700 -o "$uid" -g "$gid" "$home/.ssh"
        : > "$home/.ssh/authorized_keys"
        printf '%s\n' "$pubkey" | sed '/^[[:space:]]*$/d' >> "$home/.ssh/authorized_keys"
        chown "${uid}:${gid}" "$home/.ssh/authorized_keys"
        chmod 0600 "$home/.ssh/authorized_keys"
        log "SSH key installed: $name"
    fi

    # ---- register the sshd Match block ----
    MATCH_BLOCKS+=$'\n'"Match User ${name}"$'\n'"    ChrootDirectory ${chroot}"$'\n'"    ForceCommand internal-sftp"$'\n'"    AllowTcpForwarding no"$'\n'"    AllowAgentForwarding no"$'\n'"    X11Forwarding no"$'\n'"    PermitTunnel no"

    USERS_CREATED=$((USERS_CREATED + 1))
}

# --------------------------------------------------------------------------
# 5. Collect users (primary + extra) and create them
# --------------------------------------------------------------------------
generate_host_keys
start_logging

MATCH_BLOCKS=""
ANY_PASSWORD_AUTH="no"

# --- primary user (skipped when SFTP_USER is empty) ---
if [[ -n "$SFTP_USER" ]]; then
    PRIMARY_KEY="$SSH_PUBLIC_KEY"
    if [[ -z "$PRIMARY_KEY" && -n "$SSH_AUTHORIZED_KEYS_FILE" && -f "$SSH_AUTHORIZED_KEYS_FILE" ]]; then
        PRIMARY_KEY="$(cat "$SSH_AUTHORIZED_KEYS_FILE")"
    fi
    if [[ -n "$PRIMARY_KEY" && -z "$SFTP_PASSWORD" ]]; then
        log "public key provided, password auth disabled for user $SFTP_USER"
    fi

    create_user "$SFTP_USER" "$SFTP_UID" "$SFTP_GID" "$SFTP_HOME" "$PRIMARY_KEY" "$SFTP_PASSWORD"
    [[ -n "$SFTP_PASSWORD" ]] && ANY_PASSWORD_AUTH="yes"
else
    log "SFTP_USER is empty -> no built-in primary user (config-file / multiuser mode)"
fi

# --- extra users (optional, from users.conf) ---
#   $SFTP_CONF_DIR/users.conf format (whitespace separated):
#       <name> [uid] [gid] [home]
#   optional files:
#       $SFTP_CONF_DIR/authorized_keys/<name>   -> public key(s)
#       $SFTP_CONF_DIR/passwords/<name>         -> password
if [[ -f "$SFTP_CONF_DIR/users.conf" ]]; then
    while read -r ex_name ex_uid ex_gid ex_home; do
        [[ -z "$ex_name" || "$ex_name" == \#* ]] && continue
        ex_uid="${ex_uid:-$SFTP_UID}"
        ex_gid="${ex_gid:-$SFTP_GID}"
        ex_home="${ex_home:-$SFTP_CHROOT_BASE/${ex_name}/data}"
        ex_key=""
        ex_pw=""
        [[ -f "$SFTP_CONF_DIR/authorized_keys/$ex_name" ]] && \
            ex_key="$(cat "$SFTP_CONF_DIR/authorized_keys/$ex_name")"
        [[ -f "$SFTP_CONF_DIR/passwords/$ex_name" ]] && \
            ex_pw="$(cat "$SFTP_CONF_DIR/passwords/$ex_name")"
        [[ -n "$ex_pw" ]] && ANY_PASSWORD_AUTH="yes"
        log "extra user: $ex_name (uid=$ex_uid gid=$ex_gid home=$ex_home)"
        create_user "$ex_name" "$ex_uid" "$ex_gid" "$ex_home" "$ex_key" "$ex_pw"
    done < "$SFTP_CONF_DIR/users.conf"
    chmod 600 "$SFTP_CONF_DIR/users.conf" 2>/dev/null || true
fi

if [[ "$USERS_CREATED" -eq 0 ]]; then
    log "ERROR: no users were created. Set SFTP_USER or provide ${SFTP_CONF_DIR}/users.conf"
    exit 1
fi

# --------------------------------------------------------------------------
# 6. Generate sshd_config
# --------------------------------------------------------------------------
log "writing sshd_config (port=$SFTP_PORT, password_auth=$ANY_PASSWORD_AUTH, users=$USERS_CREATED)"

cat > "$SSHD_CONFIG" <<EOF
# --- generated file, do not edit by hand ---
Port ${SFTP_PORT}
AddressFamily any
ListenAddress ${SFTP_LISTEN}
PidFile /run/sshd.pid

HostKey ${SFTP_HOST_KEY_DIR}/ssh_host_ed25519_key
HostKey ${SFTP_HOST_KEY_DIR}/ssh_host_rsa_key

# --- authentication ---
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication ${ANY_PASSWORD_AUTH}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 6

AuthorizedKeysFile .ssh/authorized_keys

# --- SFTP subsystem (runs inside the chroot, never spawns a shell) ---
Subsystem sftp internal-sftp

# --- hardening ---
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
StrictModes yes

# --- misc ---
LogLevel ${SFTP_LOG_LEVEL}
PrintMotd no
ClientAliveInterval 60
ClientAliveCountMax 3
AcceptEnv LANG LC_*
EOF

if [[ -n "$MATCH_BLOCKS" ]]; then
    printf '%s\n' "$MATCH_BLOCKS" >> "$SSHD_CONFIG"
fi

# sshd requires the config to be root-owned and not writable by others.
chown root:root "$SSHD_CONFIG"
chmod 0644 "$SSHD_CONFIG"

# validate the config -- abort on error
if ! /usr/sbin/sshd -t -f "$SSHD_CONFIG"; then
    log "ERROR: sshd_config is invalid!"
    exit 1
fi

# apply the output umask so files created via SFTP get predictable permissions
umask "$SFTP_UMASK"

log "configuration ready, starting sshd..."
if [[ "$RSYSLOG_OK" == "1" ]]; then
    # sshd logs to syslog (no -e) -> rsyslog -> daily file + stdout
    exec "${MAIN_CMD[@]}"
else
    # fallback: log directly to stderr (docker logs)
    exec "${MAIN_CMD[@]}" -e
fi

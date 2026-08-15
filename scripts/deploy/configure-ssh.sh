#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEPLOY_PORT=${DEPLOY_PORT:-22}

for name in DEPLOY_HOST DEPLOY_PORT DEPLOY_USER DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS; do
  [[ -n "${!name:-}" ]] || {
    printf '%s is required\n' "$name" >&2
    exit 1
  }
done

[[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || {
  printf '%s\n' 'DEPLOY_HOST must be a hostname or IPv4 address without a port' >&2
  exit 1
}
[[ "$DEPLOY_PORT" =~ ^[0-9]{1,5}$ ]] \
  && ((DEPLOY_PORT >= 1 && DEPLOY_PORT <= 65535)) || {
  printf '%s\n' 'DEPLOY_PORT must be between 1 and 65535' >&2
  exit 1
}
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  printf '%s\n' 'DEPLOY_USER is invalid' >&2
  exit 1
}

ssh_dir="$HOME/.ssh"
key_path="$ssh_dir/one-user-deploy-key"
known_hosts_path="$ssh_dir/one-user-known-hosts"
config_path="$ssh_dir/config"

install -d -m 0700 "$ssh_dir"
printf '%s\n' "$DEPLOY_SSH_KEY" | tr -d '\r' >"$key_path"
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" | tr -d '\r' >"$known_hosts_path"
chmod 0600 "$key_path" "$known_hosts_path"

ssh-keygen -y -P '' -f "$key_path" >/dev/null 2>&1 || {
  printf '%s\n' 'DEPLOY_SSH_KEY is not an unencrypted OpenSSH private key' >&2
  exit 1
}
awk '
  /^[[:space:]]*($|#)/ { next }
  $2 != "ssh-ed25519" { invalid = 1; next }
  { found = 1 }
  END { exit(found && !invalid ? 0 : 1) }
' "$known_hosts_path" \
  && ssh-keygen -lf "$known_hosts_path" -E sha256 >/dev/null 2>&1 || {
  printf '%s\n' 'DEPLOY_KNOWN_HOSTS must contain a valid ED25519 known_hosts entry' >&2
  exit 1
}

{
  printf '%s\n' 'Host one-user-deploy'
  printf '  HostName %s\n' "$DEPLOY_HOST"
  printf '  Port %s\n' "$DEPLOY_PORT"
  printf '  User %s\n' "$DEPLOY_USER"
  printf '  IdentityFile %s\n' "$key_path"
  printf '%s\n' \
    '  IdentitiesOnly yes' \
    '  BatchMode yes' \
    '  StrictHostKeyChecking yes' \
    '  PasswordAuthentication no' \
    '  KbdInteractiveAuthentication no' \
    '  HostKeyAlgorithms ssh-ed25519'
  printf '  UserKnownHostsFile %s\n' "$known_hosts_path"
  printf '%s\n' '  ConnectTimeout 15'
} >"$config_path"
chmod 0600 "$config_path"

ssh one-user-deploy 'printf "%s\n" one-user-ssh-ready'

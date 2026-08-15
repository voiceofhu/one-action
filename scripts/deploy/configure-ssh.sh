#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

for name in DEPLOY_HOST DEPLOY_PORT DEPLOY_USER DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS; do
  [[ -n "${!name:-}" ]] || {
    printf '%s is required\n' "$name" >&2
    exit 1
  }
done

[[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || {
  printf '%s\n' 'DEPLOY_HOST must be a hostname or IPv4 address' >&2
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
install -d -m 0700 "$ssh_dir"
printf '%s\n' "$DEPLOY_SSH_KEY" >"$ssh_dir/one-user-deploy-key"
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" >"$ssh_dir/known_hosts"
chmod 0600 "$ssh_dir/one-user-deploy-key" "$ssh_dir/known_hosts"

cat >"$ssh_dir/config" <<EOF
Host one-user-deploy
  HostName $DEPLOY_HOST
  Port $DEPLOY_PORT
  User $DEPLOY_USER
  IdentityFile $ssh_dir/one-user-deploy-key
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $ssh_dir/known_hosts
  ConnectTimeout 15
EOF
chmod 0600 "$ssh_dir/config"

ssh one-user-deploy 'printf "%s\n" one-user-ssh-ready'

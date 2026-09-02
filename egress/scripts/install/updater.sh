# shellcheck shell=bash

install_host_updater() {
  local update_owner update_group

  UPDATE_DIR=$INSTALL_DIR/update
  UPDATER_FILE=$INSTALL_DIR/updater.sh
  UPDATER_SERVICE_FILE=/etc/systemd/system/one-browser-egress-updater.service
  UPDATER_PATH_FILE=/etc/systemd/system/one-browser-egress-updater.path
  command -v systemctl >/dev/null ||
    die "Remote Egress upgrades require systemd"

  if [ "$INSTALL_MODE" = native ]; then
    ensure_native_user
    update_owner=one-browser-egress
    update_group=one-browser-egress
  else
    update_owner=65532
    update_group=65532
  fi
  install -d -m 0700 -o "$update_owner" -g "$update_group" "$UPDATE_DIR"

  cat >"$UPDATER_FILE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly install_dir=/opt/one-browser-egress
readonly update_dir=$install_dir/update
readonly request_file=$update_dir/request
readonly running_file=$update_dir/request.running
readonly status_file=$update_dir/status
readonly install_record=$install_dir/.installation
readonly installer_url=https://raw.githubusercontent.com/voiceofhu/one-action/main/egress/install.sh

fail() {
  printf '[one-browser-egress-updater] %s\n' "$*" >&2
  exit 1
}

read_field() {
  local file=$1 key=$2
  awk -F= -v wanted="$key" '$1 == wanted { if (found) exit 2; found=1; sub(/^[^=]*=/, ""); value=$0 } END { if (!found) exit 1; print value }' "$file"
}

validate_version() {
  local value=$1 part old_ifs=$IFS
  case "$value" in ''|*[!0-9.]*) return 1 ;; esac
  IFS=.; set -- $value; IFS=$old_ifs
  [ "$#" -eq 3 ] || return 1
  for part in "$@"; do
    case "$part" in 0|[1-9]|[1-9][0-9]*) ;; *) return 1 ;; esac
  done
}

status_owner() {
  case "$(read_field "$install_record" runtime)" in
    native) printf 'one-browser-egress:one-browser-egress' ;;
    docker) printf '65532:65532' ;;
    *) fail "installation runtime is invalid" ;;
  esac
}

write_status() {
  local state=$1 message=$2 temporary owner
  temporary=$(mktemp "$update_dir/.status.XXXXXX")
  printf '%s\n' \
    "upgrade_id=$upgrade_id" \
    "version=$version" \
    "state=$state" \
    "requested_at=$requested_at" \
    "updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "message=$message" >"$temporary"
  chmod 0600 "$temporary"
  owner=$(status_owner)
  chown "$owner" "$temporary"
  sync -f "$temporary"
  mv -f "$temporary" "$status_file"
  sync -f "$update_dir"
}

[ -f "$request_file" ] && [ ! -L "$request_file" ] || fail "upgrade request is missing or unsafe"
[ "$(stat -c %a "$request_file")" = 600 ] || fail "upgrade request permissions must be 0600"
[ "$(wc -l <"$request_file" | tr -d ' ')" = 6 ] || fail "upgrade request field count is invalid"
upgrade_id=$(read_field "$request_file" upgrade_id) || fail "upgrade_id is missing"
version=$(read_field "$request_file" version) || fail "version is missing"
state=$(read_field "$request_file" state) || fail "state is missing"
requested_at=$(read_field "$request_file" requested_at) || fail "requested_at is missing"
updated_at=$(read_field "$request_file" updated_at) || fail "updated_at is missing"
message=$(read_field "$request_file" message) || fail "message is missing"
case "$upgrade_id" in ''|*[!A-Za-z0-9._:-]*) fail "upgrade_id is invalid" ;; esac
[ "${#upgrade_id}" -le 64 ] || fail "upgrade_id is too long"
validate_version "$version" || fail "version is invalid"
[ "$state" = pending ] && [ -n "$requested_at" ] && [ -n "$updated_at" ] && [ -z "$message" ] ||
  fail "upgrade request metadata is invalid"
[ -f "$install_record" ] && [ ! -L "$install_record" ] || fail "installation record is missing"

mv -f "$request_file" "$running_file"
write_status running "升级开始"
if curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 60 "$installer_url" |
  /bin/bash -s -- --upgrade-existing --version "$version"; then
  write_status succeeded "升级完成"
  rm -f "$running_file"
  sync -f "$update_dir"
  exit 0
fi
write_status failed "升级失败"
rm -f "$running_file"
sync -f "$update_dir"
exit 1
EOF
  chown root:root "$UPDATER_FILE"
  chmod 0700 "$UPDATER_FILE"

  cat >"$UPDATER_SERVICE_FILE" <<EOF
[Unit]
Description=One Browser Egress host updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER_FILE
UMask=0077
EOF
  chown root:root "$UPDATER_SERVICE_FILE"
  chmod 0644 "$UPDATER_SERVICE_FILE"

  cat >"$UPDATER_PATH_FILE" <<EOF
[Unit]
Description=Watch for One Browser Egress upgrade requests

[Path]
PathExists=$UPDATE_DIR/request
Unit=one-browser-egress-updater.service

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "$UPDATER_PATH_FILE"
  chmod 0644 "$UPDATER_PATH_FILE"
  systemctl daemon-reload
  systemctl enable --now one-browser-egress-updater.path
}

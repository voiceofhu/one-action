# shellcheck shell=bash

install_host_updater() {
  local update_owner update_group updater_temporary

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

  updater_temporary=$(mktemp "$INSTALL_DIR/.updater.XXXXXX")
  cat >"$updater_temporary" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly install_dir=/opt/one-browser-egress
readonly update_dir=$install_dir/update
readonly request_file=$update_dir/request
readonly running_file=$update_dir/request.running
readonly status_file=$update_dir/status
readonly install_record=$install_dir/.installation
active=0

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

finish_interrupted() {
  local result=$?
  trap - EXIT INT TERM HUP
  if [ "$active" = 1 ]; then
    write_status failed "升级进程中断"
    rm -f "$running_file"
    sync -f "$update_dir"
  fi
  exit "$result"
}

# A separate root-owned lock also serializes manual recovery with systemd.
exec 8>"$install_dir/.updater.lock"
flock -n 8 || exit 0
source_file=$request_file
if [ -e "$running_file" ] || [ -L "$running_file" ]; then
  source_file=$running_file
elif [ ! -e "$request_file" ] && [ ! -L "$request_file" ]; then
  exit 0
fi
[ -f "$source_file" ] && [ ! -L "$source_file" ] || fail "upgrade request is missing or unsafe"
[ "$(stat -c %a "$source_file")" = 600 ] || fail "upgrade request permissions must be 0600"
[ "$(wc -l <"$source_file" | tr -d ' ')" = 6 ] || fail "upgrade request field count is invalid"
upgrade_id=$(read_field "$source_file" upgrade_id) || fail "upgrade_id is missing"
version=$(read_field "$source_file" version) || fail "version is missing"
state=$(read_field "$source_file" state) || fail "state is missing"
requested_at=$(read_field "$source_file" requested_at) || fail "requested_at is missing"
updated_at=$(read_field "$source_file" updated_at) || fail "updated_at is missing"
message=$(read_field "$source_file" message) || fail "message is missing"
case "$upgrade_id" in ''|*[!A-Za-z0-9._:-]*) fail "upgrade_id is invalid" ;; esac
[ "${#upgrade_id}" -le 64 ] || fail "upgrade_id is too long"
validate_version "$version" || fail "version is invalid"
[ "$state" = pending ] && [ -n "$requested_at" ] && [ -n "$updated_at" ] && [ -z "$message" ] ||
  fail "upgrade request metadata is invalid"
[ -f "$install_record" ] && [ ! -L "$install_record" ] || fail "installation record is missing"

if [ "$source_file" = "$running_file" ]; then
  # The installer commits its version only after the runtime passes health checks.
  # Never replay an interrupted installation without a new Server command.
  installed_version=$(read_field "$install_record" version)
  if [ "$installed_version" = "$version" ]; then
    write_status succeeded "升级已完成，中断后恢复状态"
  else
    write_status failed "升级中断，请重新发起升级"
  fi
  rm -f "$running_file"
  sync -f "$update_dir"
  exit 0
fi

trap finish_interrupted EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
active=1
mv -f "$request_file" "$running_file"
write_status running "升级开始"
if /bin/bash "$install_dir/install.sh" --upgrade "$version" >"$install_dir/last-upgrade.log" 2>&1; then
  write_status succeeded "升级完成"
  rm -f "$running_file"
  active=0
  sync -f "$update_dir"
  exit 0
fi
write_status failed "升级失败"
rm -f "$running_file"
active=0
sync -f "$update_dir"
exit 1
EOF
  chown root:root "$updater_temporary"
  chmod 0700 "$updater_temporary"
  mv -f "$updater_temporary" "$UPDATER_FILE"

  cat >"$UPDATER_SERVICE_FILE" <<EOF
[Unit]
Description=One Browser Egress host updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=15min
Restart=on-failure
RestartSec=5s
ExecStart=$UPDATER_FILE
UMask=0077

[Install]
WantedBy=multi-user.target
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
  systemctl enable one-browser-egress-updater.service
  systemctl enable --now one-browser-egress-updater.path
}

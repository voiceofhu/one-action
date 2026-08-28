#!/bin/sh

configure_host_updater() {
	UPDATER_FILE=${UPDATER_FILE:-${INSTALL_DIR}/updater.sh}
	UPDATER_SERVICE_FILE=${UPDATER_SERVICE_FILE:-/etc/systemd/system/one-node-updater.service}
	UPDATER_PATH_FILE=${UPDATER_PATH_FILE:-/etc/systemd/system/one-node-updater.path}
	if command -v systemctl >/dev/null 2>&1; then
		HOST_UPDATER_ENABLED="true"
	else
		HOST_UPDATER_ENABLED="false"
	fi
}

migrate_host_updater_environment() {
	[ "$HOST_UPDATER_ENABLED" = "true" ] || return 0
	updater_env_source=$(mktemp "${ENV_FILE}.updater.XXXXXX")
	chmod 0600 "$updater_env_source"
	sed '/^NODE_UPGRADE_REQUEST_FILE=/d' "$ENV_FILE" >"$updater_env_source"
	write_env_line="NODE_UPGRADE_REQUEST_FILE=\"${ONE_NODE_STATE_DIR}/update/request\""
	printf '%s\n' "$write_env_line" >>"$updater_env_source"
	replace_managed_file "$updater_env_source" "$ENV_FILE" 0600 || {
		rm -f -- "$updater_env_source"
		die "unable to enable the host updater in the One Node environment"
	}
	rm -f -- "$updater_env_source"
}

enable_host_updater_for_upgrade() {
	configure_host_updater
	[ "$HOST_UPDATER_ENABLED" = "true" ] || return 0
	migrate_host_updater_environment
	record_host_updater_manifest_paths
	manifest_write "$INSTALL_RECORD" || die "unable to record the host updater"
	install_host_updater
}

record_host_updater_manifest_paths() {
	[ "${HOST_UPDATER_ENABLED:-false}" = "true" ] || return 0
	for host_updater_path in \
		"$MANIFEST_UPDATER_PATH" \
		"$MANIFEST_UPDATER_SERVICE_PATH" \
		"$MANIFEST_UPDATER_PATH_UNIT_PATH"
	do
		if ! manifest_has_owned_path "$host_updater_path"; then
			manifest_append_owned_path "$host_updater_path" ||
				die "unable to record host updater path"
			MANIFEST_OWNED_COUNT=$((MANIFEST_OWNED_COUNT + 1))
		fi
	done
}

install_host_updater() {
	[ "${HOST_UPDATER_ENABLED:-false}" = "true" ] || return 0
	updater_temp_dir=$(mktemp -d "/tmp/one-node-host-updater.XXXXXX")
	chmod 0700 "$updater_temp_dir"
	updater_script_source="${updater_temp_dir}/updater.sh"
	updater_service_source="${updater_temp_dir}/one-node-updater.service"
	updater_path_source="${updater_temp_dir}/one-node-updater.path"

	cat >"$updater_script_source" <<'EOF'
#!/bin/sh
set -eu
umask 077

update_dir=${ONE_NODE_UPDATE_DIR:-/var/lib/one-node/update}
request_file="${update_dir}/request"
running_file="${update_dir}/request.running"
status_file="${update_dir}/status"
installer=${ONE_NODE_INSTALLER:-/opt/one-node/install.sh}

fail() {
	printf '%s\n' "[one-node-updater] $*" >&2
	rm -f -- "$request_file"
	sync -f "$update_dir" 2>/dev/null || true
	exit 1
}

write_status() {
	state=$1
	message=$2
	temporary=$(mktemp "${update_dir}/.status.XXXXXX")
	chmod 0600 "$temporary"
	printf '%s\n' \
		"command_id=${command_id}" \
		"version=${version}" \
		"state=${state}" \
		"requested_at=${requested_at}" \
		"updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"message=${message}" >"$temporary"
	sync -f "$temporary"
	mv -f -- "$temporary" "$status_file"
	sync -f "$update_dir"
}

[ -f "$request_file" ] && [ ! -L "$request_file" ] || fail "request is missing or unsafe"
[ "$(stat -c %a "$request_file")" = 600 ] || fail "request permissions must be 0600"
case $(wc -l <"$request_file" | tr -d ' ') in 6) ;; *) fail "request has an invalid field count" ;; esac
command_id=$(sed -n 's/^command_id=//p' "$request_file")
version=$(sed -n 's/^version=//p' "$request_file")
state=$(sed -n 's/^state=//p' "$request_file")
requested_at=$(sed -n 's/^requested_at=//p' "$request_file")
updated_at=$(sed -n 's/^updated_at=//p' "$request_file")
message=$(sed -n 's/^message=//p' "$request_file")
case "$command_id" in ''|*[!A-Za-z0-9._:-]*) fail "command_id is invalid" ;; esac
[ "${#command_id}" -le 128 ] || fail "command_id is too long"
case "$version" in ''|*[!0-9.]*) fail "version is invalid" ;; esac
old_ifs=$IFS
IFS=.
set -- $version
IFS=$old_ifs
[ "$#" -eq 3 ] || fail "version must have exactly three numeric components"
for version_part in "$@"; do
	case "$version_part" in 0|[1-9]|[1-9][0-9]*) ;; *) fail "version is not canonical" ;; esac
done
[ "$state" = pending ] || fail "request state must be pending"
[ -n "$requested_at" ] && [ -n "$updated_at" ] && [ -z "$message" ] || fail "request metadata is invalid"
[ -x "$installer" ] && [ ! -L "$installer" ] || fail "persistent installer is missing or unsafe"

mv -f -- "$request_file" "$running_file"
write_status running "upgrade started"
if "$installer" --upgrade "$version"; then
	write_status succeeded "upgrade completed"
	rm -f -- "$running_file"
	sync -f "$update_dir"
	exit 0
fi
write_status failed "upgrade failed"
rm -f -- "$running_file"
sync -f "$update_dir"
exit 1
EOF

	cat >"$updater_service_source" <<EOF
[Unit]
Description=One Node host updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="ONE_NODE_UPDATE_DIR=${ONE_NODE_STATE_DIR}/update"
ExecStart=/opt/one-node/updater.sh
UMask=0077
EOF

	cat >"$updater_path_source" <<EOF
[Unit]
Description=Watch for One Node host update requests

[Path]
PathExists=${ONE_NODE_STATE_DIR}/update/request
Unit=one-node-updater.service

[Install]
WantedBy=multi-user.target
EOF

	install -d -m 0700 "${ONE_NODE_STATE_DIR}/update"
	install -m 0700 "$updater_script_source" "$UPDATER_FILE"
	install -m 0644 "$updater_service_source" "$UPDATER_SERVICE_FILE"
	install -m 0644 "$updater_path_source" "$UPDATER_PATH_FILE"
	rm -rf -- "$updater_temp_dir"
	systemctl daemon-reload
	systemctl enable --now one-node-updater.path
}

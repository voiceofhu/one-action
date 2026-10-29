#!/bin/sh

# macOS lifecycle for monitor-only One Node hosts. install.sh, upgrade.sh and
# uninstall.sh load only this module on Darwin; the Linux modules assume
# systemd, nftables and GNU coreutils.
#
# Layout mirrors Linux so the shared bootstrap and the node agree on paths:
#   /opt/one-node            binary, retained install.sh, .env, .installation,
#                            updater.sh, previous/ (root:wheel)
#   /var/lib/one-node        node state (0700), update/ request and status
#   /var/log/one-node        node log (LOG_FILE) and launchd stderr
# Two root LaunchDaemons: the node (KeepAlive) and an updater that launchd
# starts whenever the node writes update/request (WatchPaths), the macOS
# counterpart of the Linux one-node-updater.path unit.

if ! command -v bootstrap_verify_checksums_signature >/dev/null 2>&1; then
	printf '%s\n' "[one-node] error: the macOS module must be loaded through install.sh" >&2
	exit 1
fi

darwin_configure() {
	DARWIN_ROOT=""
	# Tests stage the whole layout under a scratch root; never in production.
	if [ -n "${ONE_NODE_DARWIN_ROOT:-}" ]; then
		[ "${ONE_NODE_ALLOW_INSECURE:-false}" = "true" ] ||
			darwin_die "ONE_NODE_DARWIN_ROOT is only available for insecure development"
		DARWIN_ROOT=${ONE_NODE_DARWIN_ROOT%/}
	fi
	DARWIN_INSTALL_DIR="${DARWIN_ROOT}/opt/one-node"
	DARWIN_STATE_DIR="${DARWIN_ROOT}/var/lib/one-node"
	DARWIN_LOG_DIR="${DARWIN_ROOT}/var/log/one-node"
	DARWIN_DAEMON_DIR="${DARWIN_ROOT}/Library/LaunchDaemons"
	DARWIN_LABEL="com.voiceofhu.one-node"
	DARWIN_UPDATER_LABEL="com.voiceofhu.one-node-updater"
	DARWIN_PLIST="${DARWIN_DAEMON_DIR}/${DARWIN_LABEL}.plist"
	DARWIN_UPDATER_PLIST="${DARWIN_DAEMON_DIR}/${DARWIN_UPDATER_LABEL}.plist"
	DARWIN_BINARY="${DARWIN_INSTALL_DIR}/one-node"
	DARWIN_INSTALLER="${DARWIN_INSTALL_DIR}/install.sh"
	DARWIN_UPDATER="${DARWIN_INSTALL_DIR}/updater.sh"
	DARWIN_ENV_FILE="${DARWIN_INSTALL_DIR}/.env"
	DARWIN_RECORD="${DARWIN_INSTALL_DIR}/.installation"
	DARWIN_PREVIOUS_DIR="${DARWIN_INSTALL_DIR}/previous"
	DARWIN_BOOTSTRAP_ENV="${DARWIN_STATE_DIR}/bootstrap.env"
	DARWIN_IDENTITY_FILE="${DARWIN_STATE_DIR}/node-secret"
	DARWIN_UPDATE_DIR="${DARWIN_STATE_DIR}/update"
	DARWIN_LOG_FILE="${DARWIN_LOG_DIR}/one-node.log"
	DARWIN_ENROLL_TIMEOUT=${ONE_NODE_ENROLL_TIMEOUT:-120}
	# Seconds an upgraded node must stay up before the old binary is dropped.
	DARWIN_UPGRADE_SETTLE=${ONE_NODE_UPGRADE_SETTLE:-20}
	DARWIN_TEMP_DIR=""
}

darwin_log() {
	printf '%s\n' "[one-node] $*"
}

darwin_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

darwin_cleanup() {
	[ -z "${DARWIN_TEMP_DIR:-}" ] || rm -rf -- "$DARWIN_TEMP_DIR"
	DARWIN_TEMP_DIR=""
}

darwin_require_host() {
	[ "$(id -u)" -eq 0 ] || darwin_die "run the installer with sudo on macOS"
	for darwin_command in awk curl grep launchctl mktemp sed shasum stat uname; do
		command -v "$darwin_command" >/dev/null 2>&1 || darwin_die "$darwin_command is required"
	done
	case "$(uname -m)" in
	x86_64) DARWIN_ARCH="amd64" ;;
	arm64) DARWIN_ARCH="arm64" ;;
	*) darwin_die "only macOS amd64 and arm64 are supported" ;;
	esac
	DARWIN_BINARY_NAME="one-node-darwin-${DARWIN_ARCH}"
}

darwin_file_mode() {
	stat -f '%Lp' "$1" 2>/dev/null
}

darwin_sha256() {
	shasum -a 256 "$1" | awk '{ print tolower($1) }'
}

darwin_single_line() {
	case "$2" in
	*'
'*) darwin_die "$1 must be a single line" ;;
	esac
}

darwin_escape_dotenv() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g'
}

darwin_manifest_value() {
	sed -n "s/^${1}=//p" "$DARWIN_RECORD" 2>/dev/null | sed -n '1p'
}

darwin_installed() {
	[ -f "$DARWIN_RECORD" ] && [ ! -L "$DARWIN_RECORD" ] &&
		[ "$(darwin_manifest_value format)" = "one-node-darwin-v1" ]
}

darwin_validate_install_config() {
	ONE_NODE_SERVER=${ONE_NODE_SERVER:-}
	ONE_NODE_ID=${ONE_NODE_ID:-}
	ONE_NODE_BOOTSTRAP_TOKEN=${ONE_NODE_BOOTSTRAP_TOKEN:-}
	ONE_NODE_ALLOW_INSECURE=${ONE_NODE_ALLOW_INSECURE:-false}
	for darwin_pair in "ONE_NODE_SERVER|$ONE_NODE_SERVER" "ONE_NODE_ID|$ONE_NODE_ID" \
		"ONE_NODE_BOOTSTRAP_TOKEN|$ONE_NODE_BOOTSTRAP_TOKEN"; do
		darwin_name=${darwin_pair%%|*}
		darwin_value=${darwin_pair#*|}
		[ -n "$darwin_value" ] || darwin_die "${darwin_name} is required"
		darwin_single_line "$darwin_name" "$darwin_value"
	done
	case "$ONE_NODE_ID" in
	''|*[!0-9]*|0*) darwin_die "ONE_NODE_ID must be a positive integer" ;;
	esac
	case "$ONE_NODE_ALLOW_INSECURE" in
	true|false) ;;
	*) darwin_die "ONE_NODE_ALLOW_INSECURE must be true or false" ;;
	esac
	case "$DARWIN_ENROLL_TIMEOUT" in
	''|*[!0-9]*|0) darwin_die "ONE_NODE_ENROLL_TIMEOUT must be a positive integer" ;;
	esac
	case "$ONE_NODE_SERVER" in
	https://*|grpcs://*) ;;
	http://*|grpc://*|*:*)
		[ "$ONE_NODE_ALLOW_INSECURE" = "true" ] ||
			darwin_die "plaintext control connections require ONE_NODE_ALLOW_INSECURE=true"
		;;
	*) darwin_die "ONE_NODE_SERVER is invalid" ;;
	esac
}

darwin_parse_install_arguments() {
	darwin_mode="native"
	darwin_role="monitor"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mode)
			[ "$#" -ge 2 ] || darwin_die "--mode requires native"
			darwin_mode=$2
			shift 2
			;;
		--role)
			[ "$#" -ge 2 ] || darwin_die "--role requires monitor"
			darwin_role=$2
			shift 2
			;;
		--reset)
			# Development flag from the panel; every install already replaces.
			shift
			;;
		--help|-h)
			printf '%s\n' \
				"Install a monitor-only One Node on macOS (run with sudo)." \
				"" \
				"Usage: install.sh [--mode native] [--role monitor]" \
				"" \
				"  The node reports host metrics and probes, opens no ports, and runs" \
				"  as a launchd daemon. An existing installation is replaced."
			exit 0
			;;
		*) darwin_die "unknown argument: $1" ;;
		esac
	done
	[ "$darwin_mode" = "native" ] || darwin_die "macOS supports only --mode native"
	[ "$darwin_role" = "monitor" ] || darwin_die "macOS nodes support monitor mode only"
}

# Resolves, downloads and verifies the release binary for ONE_NODE_VERSION
# into the temporary workspace; sets DARWIN_STAGED_BINARY.
darwin_stage_release() {
	if [ -z "${ONE_NODE_VERSION:-}" ]; then
		ONE_NODE_VERSION=$(bootstrap_latest_version) || exit 1
		darwin_log "using latest published One Node version $ONE_NODE_VERSION"
	fi
	bootstrap_validate_version "$ONE_NODE_VERSION" ||
		darwin_die "ONE_NODE_VERSION must contain three numeric components"
	darwin_release_base="https://github.com/${ONE_NODE_ACTION_REPOSITORY}/releases/download/one-node-v${ONE_NODE_VERSION}"
	ONE_NODE_RELEASE_BASE_URL=${ONE_NODE_RELEASE_BASE_URL:-$darwin_release_base}
	case "$ONE_NODE_RELEASE_BASE_URL" in
	"$darwin_release_base") darwin_protocols='=https' ;;
	http://127.0.0.1:*|http://localhost:*|http://host.orb.internal:*)
		[ "${ONE_NODE_ALLOW_INSECURE:-false}" = "true" ] ||
			darwin_die "HTTP release assets require ONE_NODE_ALLOW_INSECURE=true"
		darwin_protocols='=http,https'
		;;
	*) darwin_die "ONE_NODE_RELEASE_BASE_URL must pin the central immutable One Node release" ;;
	esac
	darwin_sums="${DARWIN_TEMP_DIR}/SHA256SUMS"
	darwin_download "${ONE_NODE_RELEASE_BASE_URL%/}/SHA256SUMS" "$darwin_sums" "$darwin_protocols"
	bootstrap_verify_checksums_signature "${ONE_NODE_RELEASE_BASE_URL%/}/SHA256SUMS" "$darwin_sums"
	darwin_expected=$(awk -v name="$DARWIN_BINARY_NAME" '
		$2 == name || $2 == "*" name { if (found++) exit 1; value = tolower($1) }
		END { if (found != 1) exit 1; print value }
	' "$darwin_sums") || darwin_die "release checksums do not list ${DARWIN_BINARY_NAME} exactly once"
	DARWIN_STAGED_BINARY="${DARWIN_TEMP_DIR}/one-node"
	darwin_log "downloading ${DARWIN_BINARY_NAME}"
	darwin_download "${ONE_NODE_RELEASE_BASE_URL%/}/${DARWIN_BINARY_NAME}" "$DARWIN_STAGED_BINARY" "$darwin_protocols"
	[ "$(darwin_sha256 "$DARWIN_STAGED_BINARY")" = "$darwin_expected" ] ||
		darwin_die "binary SHA256 verification failed"
	chmod 0755 "$DARWIN_STAGED_BINARY"
	darwin_product=$("$DARWIN_STAGED_BINARY" version --product-name) ||
		darwin_die "downloaded binary cannot report its One Node product version"
	[ "$darwin_product" = "$ONE_NODE_VERSION" ] ||
		darwin_die "downloaded binary version $darwin_product does not match release $ONE_NODE_VERSION"
	[ -f "${ONE_NODE_INSTALLER_SOURCE:-}" ] && [ ! -L "$ONE_NODE_INSTALLER_SOURCE" ] ||
		darwin_die "installer source is missing or unsafe"
	DARWIN_STAGED_INSTALLER="${DARWIN_TEMP_DIR}/install.sh"
	cp -- "$ONE_NODE_INSTALLER_SOURCE" "$DARWIN_STAGED_INSTALLER"
	chmod 0755 "$DARWIN_STAGED_INSTALLER"
}

darwin_download() {
	curl -q --proto "$3" --proto-redir "$3" --tlsv1.2 \
		--fail --location --silent --show-error --retry 3 \
		--connect-timeout 15 --max-time 600 \
		--output "$2" "$1" || darwin_die "unable to download $1"
	[ -s "$2" ] || darwin_die "downloaded $1 is empty"
}

# Replaces target atomically: sh reads a running script incrementally, so the
# retained installer must never be rewritten in place.
darwin_replace_file() {
	darwin_replacement=$(mktemp "${2}.XXXXXX") || return 1
	if ! cp -- "$1" "$darwin_replacement" || ! chmod "$3" "$darwin_replacement" ||
		! mv -f -- "$darwin_replacement" "$2"; then
		rm -f -- "$darwin_replacement"
		return 1
	fi
}

darwin_write_env() {
	{
		printf 'NODE_NODE_ID="%s"\n' "$ONE_NODE_ID"
		printf '%s\n' 'NODE_ROLE="monitor"' 'NODE_HEARTBEAT_INTERVAL="60s"'
		printf 'NODE_STATE_DIR="%s"\n' "$DARWIN_STATE_DIR"
		printf 'NODE_UPGRADE_REQUEST_FILE="%s"\n' "${DARWIN_UPDATE_DIR}/request"
		printf 'CONTROL_ADDR="%s"\n' "$(darwin_escape_dotenv "$ONE_NODE_SERVER")"
		printf 'CONTROL_BOOTSTRAP_ENV_FILE="%s"\n' "$DARWIN_BOOTSTRAP_ENV"
		printf '%s\n' 'LOG_LEVEL="info"'
		printf 'LOG_FILE="%s"\n' "$DARWIN_LOG_FILE"
	} >"$1"
	chmod 0600 "$1"
}

darwin_write_manifest() {
	darwin_manifest_source="${DARWIN_TEMP_DIR}/.installation"
	printf '%s\n' \
		"format=one-node-darwin-v1" \
		"mode=launchd" \
		"role=monitor" \
		"current_version=$1" \
		"previous_version=$2" \
		"state_dir=${DARWIN_STATE_DIR}" >"$darwin_manifest_source"
	darwin_replace_file "$darwin_manifest_source" "$DARWIN_RECORD" 0600 ||
		darwin_die "unable to write the installation manifest"
}

darwin_node_plist() {
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${DARWIN_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${DARWIN_BINARY}</string>
		<string>start</string>
		<string>--env-file</string>
		<string>${DARWIN_ENV_FILE}</string>
		<string>--env-file</string>
		<string>${DARWIN_BOOTSTRAP_ENV}</string>
	</array>
	<key>WorkingDirectory</key>
	<string>${DARWIN_STATE_DIR}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>Umask</key>
	<integer>63</integer>
	<key>StandardOutPath</key>
	<string>${DARWIN_LOG_DIR}/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${DARWIN_LOG_DIR}/launchd.log</string>
</dict>
</plist>
EOF
}

darwin_updater_plist() {
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${DARWIN_UPDATER_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>${DARWIN_UPDATER}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>ONE_NODE_UPDATE_DIR</key>
		<string>${DARWIN_UPDATE_DIR}</string>
		<key>ONE_NODE_INSTALLER</key>
		<string>${DARWIN_INSTALLER}</string>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>WatchPaths</key>
	<array>
		<string>${DARWIN_UPDATE_DIR}/request</string>
	</array>
	<key>Umask</key>
	<integer>63</integer>
	<key>StandardOutPath</key>
	<string>${DARWIN_LOG_DIR}/updater.log</string>
	<key>StandardErrorPath</key>
	<string>${DARWIN_LOG_DIR}/updater.log</string>
</dict>
</plist>
EOF
}

# Port of the Linux host updater (scripts/install/updater.sh) to BSD tools.
darwin_updater_script() {
	cat <<'EOF'
#!/bin/sh
set -eu
umask 077

update_dir=${ONE_NODE_UPDATE_DIR:-/var/lib/one-node/update}
request_file="${update_dir}/request"
running_file="${update_dir}/request.running"
status_file="${update_dir}/status"
installer=${ONE_NODE_INSTALLER:-/opt/one-node/install.sh}

# launchd also fires WatchPaths when the request is consumed.
[ -e "$request_file" ] || exit 0

fail() {
	printf '%s\n' "[one-node-updater] $*" >&2
	rm -f -- "$request_file"
	exit 1
}

write_status() {
	temporary=$(mktemp "${update_dir}/.status.XXXXXX")
	chmod 0600 "$temporary"
	printf '%s\n' \
		"command_id=${command_id}" \
		"version=${version}" \
		"state=$1" \
		"requested_at=${requested_at}" \
		"updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"message=$2" >"$temporary"
	mv -f -- "$temporary" "$status_file"
	sync
}

[ -f "$request_file" ] && [ ! -L "$request_file" ] || fail "request is unsafe"
[ "$(stat -f '%Lp' "$request_file")" = 600 ] || fail "request permissions must be 0600"
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
trap 'write_status failed "upgrade was interrupted"; rm -f -- "$running_file"; exit 1' HUP INT TERM
output_file="${update_dir}/last-upgrade.log"
temporary_output=$(mktemp "${update_dir}/.upgrade-output.XXXXXX")
chmod 0600 "$temporary_output"
if "$installer" --upgrade "$version" >"$temporary_output" 2>&1; then
	cat "$temporary_output"
	mv -f -- "$temporary_output" "$output_file"
	write_status succeeded "upgrade completed"
	rm -f -- "$running_file"
	exit 0
fi
cat "$temporary_output" >&2
failure_message=$(sed -n 's/^\[one-node\] error: //p' "$temporary_output" | tail -n 1)
if [ -z "$failure_message" ]; then
	failure_message=$(awk 'NF { message = $0 } END { print message }' "$temporary_output")
fi
[ -n "$failure_message" ] || failure_message="upgrade failed"
failure_message=$(printf '%s' "$failure_message" | tr '\r\n' '  ' | cut -c 1-1000)
mv -f -- "$temporary_output" "$output_file"
write_status failed "$failure_message"
rm -f -- "$running_file"
exit 1
EOF
}

darwin_bootout() {
	launchctl bootout "system/$1" >/dev/null 2>&1 || true
}

darwin_bootstrap() {
	darwin_bootout "$1"
	launchctl enable "system/$1" >/dev/null 2>&1 || true
	launchctl bootstrap system "$2" || return 1
}

darwin_job_pid() {
	launchctl print "system/$DARWIN_LABEL" 2>/dev/null |
		awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

darwin_job_running() {
	launchctl print "system/$DARWIN_LABEL" 2>/dev/null | grep -Eq '^[[:space:]]*state = running$'
}

darwin_identity_active() {
	[ -f "$DARWIN_IDENTITY_FILE" ] && [ ! -L "$DARWIN_IDENTITY_FILE" ] || return 1
	[ "$(darwin_file_mode "$DARWIN_IDENTITY_FILE")" = "600" ] || return 1
	grep -Eq '"node_id"[[:space:]]*:[[:space:]]*"'"$1"'"' "$DARWIN_IDENTITY_FILE" || return 1
	grep -Eq '"state"[[:space:]]*:[[:space:]]*"active"' "$DARWIN_IDENTITY_FILE"
}

darwin_print_logs() {
	darwin_log "recent One Node logs:"
	for darwin_log_file in "$DARWIN_LOG_FILE" "${DARWIN_LOG_DIR}/launchd.log"; do
		[ -f "$darwin_log_file" ] && tail -n 120 "$darwin_log_file" >&2 || true
	done
}

darwin_wait_for_enrollment() {
	darwin_remaining=$DARWIN_ENROLL_TIMEOUT
	darwin_log "waiting up to ${DARWIN_ENROLL_TIMEOUT}s for node $ONE_NODE_ID to register"
	while [ "$darwin_remaining" -gt 0 ]; do
		if darwin_identity_active "$ONE_NODE_ID" && darwin_job_running &&
			! grep -Eq '^[[:space:]]*(export[[:space:]]+)?CONTROL_BOOTSTRAP_TOKEN[[:space:]]*=' "$DARWIN_BOOTSTRAP_ENV"; then
			return 0
		fi
		sleep 1
		darwin_remaining=$((darwin_remaining - 1))
	done
	darwin_print_logs
	return 1
}

# An upgraded node keeps its identity; it is healthy once launchd keeps the
# same process running for the settle window.
darwin_wait_for_settled_runtime() {
	darwin_node_id=$(sed -n 's/^NODE_NODE_ID="\([1-9][0-9]*\)"$/\1/p' "$DARWIN_ENV_FILE")
	darwin_settled_pid=""
	darwin_settled=0
	darwin_remaining=$((DARWIN_UPGRADE_SETTLE + 60))
	while [ "$darwin_remaining" -gt 0 ]; do
		darwin_pid=$(darwin_job_pid)
		if [ -n "$darwin_pid" ] && darwin_job_running && darwin_identity_active "$darwin_node_id"; then
			if [ "$darwin_pid" = "$darwin_settled_pid" ]; then
				darwin_settled=$((darwin_settled + 1))
			else
				darwin_settled_pid=$darwin_pid
				darwin_settled=0
			fi
			[ "$darwin_settled" -lt "$DARWIN_UPGRADE_SETTLE" ] || return 0
		else
			darwin_settled_pid=""
			darwin_settled=0
		fi
		sleep 1
		darwin_remaining=$((darwin_remaining - 1))
	done
	darwin_print_logs
	return 1
}

darwin_remove_installation() {
	darwin_bootout "$DARWIN_UPDATER_LABEL"
	darwin_bootout "$DARWIN_LABEL"
	rm -f -- "$DARWIN_PLIST" "$DARWIN_UPDATER_PLIST"
	rm -rf -- "$DARWIN_INSTALL_DIR" "$DARWIN_STATE_DIR" "$DARWIN_LOG_DIR"
}

darwin_install_daemons() {
	install -d -m 0755 "$DARWIN_DAEMON_DIR"
	darwin_node_plist >"${DARWIN_TEMP_DIR}/node.plist"
	darwin_updater_plist >"${DARWIN_TEMP_DIR}/updater.plist"
	if command -v plutil >/dev/null 2>&1; then
		plutil -lint "${DARWIN_TEMP_DIR}/node.plist" >/dev/null &&
			plutil -lint "${DARWIN_TEMP_DIR}/updater.plist" >/dev/null ||
			darwin_die "generated launchd definitions are invalid"
	fi
	darwin_replace_file "${DARWIN_TEMP_DIR}/node.plist" "$DARWIN_PLIST" 0644 &&
		darwin_replace_file "${DARWIN_TEMP_DIR}/updater.plist" "$DARWIN_UPDATER_PLIST" 0644 ||
		darwin_die "unable to install the launchd definitions"
	darwin_bootstrap "$DARWIN_UPDATER_LABEL" "$DARWIN_UPDATER_PLIST" ||
		darwin_die "launchd refused ${DARWIN_UPDATER_LABEL}"
	darwin_bootstrap "$DARWIN_LABEL" "$DARWIN_PLIST" ||
		darwin_die "launchd refused ${DARWIN_LABEL}"
}

# Moves an existing installation aside so a failed new one can be undone,
# the same transaction Linux runs in install/host.sh.
darwin_backup_existing() {
	DARWIN_BACKUP_DIR=""
	for darwin_path in "$DARWIN_INSTALL_DIR" "$DARWIN_STATE_DIR" "$DARWIN_PLIST" "$DARWIN_UPDATER_PLIST"; do
		[ -e "$darwin_path" ] || [ -L "$darwin_path" ] || continue
		if [ -z "$DARWIN_BACKUP_DIR" ]; then
			darwin_log "moving the existing installation aside before applying the new command"
			darwin_bootout "$DARWIN_UPDATER_LABEL"
			darwin_bootout "$DARWIN_LABEL"
			install -d -m 0755 "$(dirname "$DARWIN_INSTALL_DIR")"
			DARWIN_BACKUP_DIR=$(mktemp -d "$(dirname "$DARWIN_INSTALL_DIR")/.one-node-replace.XXXXXX") ||
				darwin_die "unable to create the previous installation backup directory"
			chmod 0700 "$DARWIN_BACKUP_DIR"
			: >"${DARWIN_BACKUP_DIR}/moved"
			darwin_backup_count=0
		fi
		darwin_backup_count=$((darwin_backup_count + 1))
		mv -f -- "$darwin_path" "${DARWIN_BACKUP_DIR}/${darwin_backup_count}" ||
			darwin_die "unable to move $darwin_path aside"
		printf '%s\n' "${darwin_backup_count}|${darwin_path}" >>"${DARWIN_BACKUP_DIR}/moved"
	done
	rm -rf -- "$DARWIN_LOG_DIR"
}

darwin_restore_backup() {
	[ -n "${DARWIN_BACKUP_DIR:-}" ] && [ -d "$DARWIN_BACKUP_DIR" ] || return 0
	darwin_restore_status=0
	while IFS='|' read -r darwin_index darwin_path; do
		rm -rf -- "$darwin_path"
		mv -f -- "${DARWIN_BACKUP_DIR}/${darwin_index}" "$darwin_path" || darwin_restore_status=1
	done <"${DARWIN_BACKUP_DIR}/moved"
	install -d -m 0700 "$DARWIN_LOG_DIR"
	if [ -f "$DARWIN_UPDATER_PLIST" ]; then
		darwin_bootstrap "$DARWIN_UPDATER_LABEL" "$DARWIN_UPDATER_PLIST" || darwin_restore_status=1
	fi
	if [ -f "$DARWIN_PLIST" ]; then
		darwin_bootstrap "$DARWIN_LABEL" "$DARWIN_PLIST" || darwin_restore_status=1
	fi
	if [ "$darwin_restore_status" -eq 0 ]; then
		rm -rf -- "$DARWIN_BACKUP_DIR"
		darwin_log "the previous installation was restored and restarted"
	else
		darwin_log "the previous installation could not be fully restored; its files are kept in ${DARWIN_BACKUP_DIR}"
	fi
}

darwin_on_install_exit() {
	darwin_install_status=$?
	trap - EXIT HUP INT TERM
	if [ "${DARWIN_INSTALL_STARTED:-false}" = "true" ]; then
		if [ "${DARWIN_INSTALL_COMMITTED:-false}" = "true" ]; then
			[ -z "${DARWIN_BACKUP_DIR:-}" ] || rm -rf -- "$DARWIN_BACKUP_DIR"
		else
			darwin_remove_installation
			darwin_log "installation did not become ready and was removed"
			darwin_restore_backup
		fi
	fi
	darwin_cleanup
	exit "$darwin_install_status"
}

darwin_install() {
	darwin_parse_install_arguments "$@"
	darwin_require_host
	darwin_validate_install_config
	DARWIN_TEMP_DIR=$(mktemp -d "/tmp/one-node-install.XXXXXX")
	chmod 0700 "$DARWIN_TEMP_DIR"
	DARWIN_INSTALL_STARTED="false"
	DARWIN_INSTALL_COMMITTED="false"
	trap darwin_on_install_exit EXIT
	trap 'exit 1' HUP INT TERM
	darwin_stage_release

	# The new installation command is authoritative, as on Linux; nothing is
	# touched until its artifacts are verified.
	DARWIN_INSTALL_STARTED="true"
	darwin_backup_existing

	install -d -m 0755 "$DARWIN_INSTALL_DIR"
	install -d -m 0700 "$DARWIN_STATE_DIR" "$DARWIN_UPDATE_DIR" "$DARWIN_LOG_DIR"
	install -m 0755 "$DARWIN_STAGED_BINARY" "$DARWIN_BINARY"
	install -m 0755 "$DARWIN_STAGED_INSTALLER" "$DARWIN_INSTALLER"
	darwin_updater_script >"${DARWIN_TEMP_DIR}/updater.sh"
	install -m 0700 "${DARWIN_TEMP_DIR}/updater.sh" "$DARWIN_UPDATER"
	darwin_write_env "${DARWIN_TEMP_DIR}/.env"
	install -m 0600 "${DARWIN_TEMP_DIR}/.env" "$DARWIN_ENV_FILE"
	printf 'CONTROL_BOOTSTRAP_TOKEN="%s"\n' "$(darwin_escape_dotenv "$ONE_NODE_BOOTSTRAP_TOKEN")" \
		>"${DARWIN_TEMP_DIR}/bootstrap.env"
	install -m 0600 "${DARWIN_TEMP_DIR}/bootstrap.env" "$DARWIN_BOOTSTRAP_ENV"
	darwin_write_manifest "$ONE_NODE_VERSION" ""
	darwin_install_daemons

	darwin_wait_for_enrollment ||
		darwin_die "Node registration did not complete through $ONE_NODE_SERVER; verify that the public gRPC route reaches the One Node control listener"
	DARWIN_INSTALL_COMMITTED="true"
	darwin_log "macOS monitor installation ${ONE_NODE_VERSION} is ready"
	darwin_log "manage it with: sudo ${DARWIN_INSTALLER} [--status|--logs|--upgrade|--rollback|--uninstall]"
}

darwin_require_installed() {
	darwin_require_host
	darwin_installed || darwin_die "no macOS One Node installation was found"
}

# Swaps the program in DARWIN_PREVIOUS_DIR back in and restarts it.
darwin_restore_previous() {
	[ -f "${DARWIN_PREVIOUS_DIR}/one-node" ] && [ -f "${DARWIN_PREVIOUS_DIR}/install.sh" ] || return 1
	darwin_replace_file "${DARWIN_PREVIOUS_DIR}/one-node" "$DARWIN_BINARY" 0755 &&
		darwin_replace_file "${DARWIN_PREVIOUS_DIR}/install.sh" "$DARWIN_INSTALLER" 0755 || return 1
	launchctl kickstart -k "system/$DARWIN_LABEL" >/dev/null 2>&1
}

darwin_upgrade() {
	darwin_require_installed
	darwin_target=$1
	darwin_current=$(darwin_manifest_value current_version)
	bootstrap_validate_version "$darwin_target" ||
		darwin_die "upgrade version must contain three numeric components"
	[ "$darwin_target" != "$darwin_current" ] || darwin_die "macOS upgrade target is already current"
	DARWIN_TEMP_DIR=$(mktemp -d "/tmp/one-node-upgrade.XXXXXX")
	chmod 0700 "$DARWIN_TEMP_DIR"
	trap darwin_cleanup EXIT
	trap 'exit 1' HUP INT TERM
	ONE_NODE_VERSION=$darwin_target
	darwin_stage_release

	install -d -m 0755 "$DARWIN_PREVIOUS_DIR"
	darwin_replace_file "$DARWIN_BINARY" "${DARWIN_PREVIOUS_DIR}/one-node" 0755 &&
		darwin_replace_file "$DARWIN_INSTALLER" "${DARWIN_PREVIOUS_DIR}/install.sh" 0755 ||
		darwin_die "unable to keep the current version for rollback"
	darwin_replace_file "$DARWIN_STAGED_BINARY" "$DARWIN_BINARY" 0755 &&
		darwin_replace_file "$DARWIN_STAGED_INSTALLER" "$DARWIN_INSTALLER" 0755 ||
		darwin_die "unable to install the upgraded program"
	darwin_updater_script >"${DARWIN_TEMP_DIR}/updater.sh"
	darwin_replace_file "${DARWIN_TEMP_DIR}/updater.sh" "$DARWIN_UPDATER" 0700 ||
		darwin_die "unable to refresh the host updater"
	darwin_write_manifest "$darwin_target" "$darwin_current"
	launchctl kickstart -k "system/$DARWIN_LABEL" >/dev/null 2>&1 ||
		darwin_die "launchd could not restart ${DARWIN_LABEL}"
	if ! darwin_wait_for_settled_runtime; then
		darwin_log "upgrade did not settle; restoring ${darwin_current}"
		darwin_restore_previous && darwin_write_manifest "$darwin_current" "" ||
			darwin_die "upgrade failed and the previous version could not be restored"
		darwin_die "upgrade to ${darwin_target} did not stay running and was rolled back"
	fi
	darwin_log "macOS upgrade to ${darwin_target} is ready"
}

darwin_rollback() {
	darwin_require_installed
	darwin_previous=$(darwin_manifest_value previous_version)
	darwin_current=$(darwin_manifest_value current_version)
	[ -n "$darwin_previous" ] || darwin_die "installation manifest has no previous version"
	DARWIN_TEMP_DIR=$(mktemp -d "/tmp/one-node-rollback.XXXXXX")
	chmod 0700 "$DARWIN_TEMP_DIR"
	trap darwin_cleanup EXIT
	darwin_restore_previous || darwin_die "the previous version could not be restored"
	darwin_write_manifest "$darwin_previous" ""
	darwin_wait_for_settled_runtime || darwin_die "rolled-back runtime did not stay running"
	darwin_log "rolled back from ${darwin_current} to ${darwin_previous}"
}

darwin_uninstall() {
	darwin_require_host
	darwin_remove_installation
	darwin_log "One Node was removed from this Mac"
}

main() {
	darwin_configure
	case "$ONE_NODE_ENTRYPOINT_KIND" in
	install)
		case "${1:-}" in
		--upgrade) darwin_upgrade "${ONE_NODE_VERSION:-}" ;;
		--rollback) darwin_rollback ;;
		--uninstall) darwin_uninstall ;;
		*) darwin_install "$@" ;;
		esac
		;;
	upgrade)
		if [ "${1:-}" = "--rollback" ]; then
			darwin_rollback
		else
			[ -n "${ONE_NODE_VERSION:-}" ] || darwin_die "ONE_NODE_VERSION is required"
			darwin_upgrade "$ONE_NODE_VERSION"
		fi
		;;
	uninstall) darwin_uninstall ;;
	*) darwin_die "unsupported entrypoint: ${ONE_NODE_ENTRYPOINT_KIND}" ;;
	esac
}

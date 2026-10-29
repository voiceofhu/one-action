#!/bin/sh

# Canonical One Node installer entrypoint.

set -eu
umask 077

ONE_NODE_INSTALL_MODULES="install/common.sh shared/manifest.sh uninstall/paths.sh uninstall/native.sh uninstall/docker.sh install/config.sh install/host.sh install/files.sh install/updater.sh install/firewall.sh install/tuning.sh install/native.sh install/native_reconfigure.sh install/docker.sh install/readiness.sh install/main.sh"
ONE_NODE_ENTRYPOINT_KIND="install"
ONE_NODE_ENTRYPOINT_MODULES=$ONE_NODE_INSTALL_MODULES
ONE_NODE_INSTALLER_SOURCE=""
ONE_NODE_INSTALL_DIR=${ONE_NODE_INSTALL_DIR:-/opt/one-node}
ONE_NODE_INSTALL_RECORD="${ONE_NODE_INSTALL_DIR}/.installation"

# >>> one-node bootstrap: generated from scripts/shared/bootstrap.sh by scripts/sync-bootstrap.sh; edit the source >>>
# Shared entrypoint bootstrap: resolve one signed One Node release, fetch the
# installer modules from that release's exact One Action commit, and refuse any
# file whose SHA-256 differs from the signed release manifest.
#
# install.sh, upgrade.sh, and uninstall.sh must still work when piped through
# `curl | sh`, so they cannot fetch this file before it has verified anything.
# scripts/sync-bootstrap.sh therefore inlines it between the generated markers
# of each entrypoint; edit this file and rerun that script, never the copies.
#
# Each entrypoint sets, before the generated block:
#   ONE_NODE_ENTRYPOINT_KIND     install | upgrade | uninstall
#   ONE_NODE_ENTRYPOINT_MODULES  module paths relative to node/scripts
# Modules may call bootstrap_verify_checksums_signature for later downloads.

# Ed25519 key whose private half signs every release SHA256SUMS (repository
# secret ONE_NODE_RELEASE_SIGNING_KEY). Assigned unconditionally so the
# environment cannot replace the trust root.
ONE_NODE_RELEASE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA7mYUrYzvr0ww9+0Jk3SenePddMSItqognahRMJs0fLc=
-----END PUBLIC KEY-----'
ONE_NODE_ACTION_REPOSITORY="voiceofhu/one-action"
ONE_NODE_ENTRYPOINT_TEMP_DIR=""
ONE_NODE_RELEASE_VERSION=""
ONE_NODE_RELEASE_SUMS=""

bootstrap_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

bootstrap_warn() {
	printf '%s\n' "[one-node] warning: $*" >&2
}

bootstrap_insecure() {
	[ "${ONE_NODE_ALLOW_INSECURE:-false}" = "true" ]
}

# A broken chain of trust is fatal unless the operator opted into development.
bootstrap_trust_fail() {
	if bootstrap_insecure; then
		bootstrap_warn "$* (continuing because ONE_NODE_ALLOW_INSECURE=true)"
		return 0
	fi
	bootstrap_die "$*"
}

bootstrap_cleanup() {
	[ -z "$ONE_NODE_ENTRYPOINT_TEMP_DIR" ] ||
		rm -rf -- "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
}

bootstrap_curl() {
	curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--fail --silent --show-error \
		--connect-timeout 10 --max-time 30 --max-filesize 8388608 \
		--user-agent "one-node-${ONE_NODE_ENTRYPOINT_KIND:-installer}" "$@"
}

bootstrap_validate_version() {
	case "$1" in
	''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
	esac
	[ "$(printf '%s' "$1" | tr -cd . | wc -c | tr -d ' ')" = 2 ]
}

bootstrap_validate_action_commit() {
	case "$1" in
	''|*[!0123456789abcdef]*) return 1 ;;
	esac
	[ "${#1}" -eq 40 ]
}

bootstrap_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	else
		openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
	fi
}

bootstrap_has_openssl3() {
	command -v openssl >/dev/null 2>&1 || return 1
	bootstrap_openssl_version=$(openssl version 2>/dev/null || true)
	case "$bootstrap_openssl_version" in
	"OpenSSL "[3-9].*|"OpenSSL "[1-9][0-9]*) return 0 ;;
	*) return 1 ;;
	esac
}

# Verifies an Ed25519 signature over the raw file against the embedded key.
bootstrap_verify_signature() {
	bootstrap_signed_file=$1
	bootstrap_signature_file=$2
	bootstrap_key_file=$(mktemp "${bootstrap_signed_file}.key.XXXXXX") || return 1
	printf '%s\n' "$ONE_NODE_RELEASE_PUBLIC_KEY" >"$bootstrap_key_file"
	bootstrap_verify_result=0
	if bootstrap_has_openssl3; then
		openssl pkeyutl -verify -pubin -inkey "$bootstrap_key_file" -rawin \
			-in "$bootstrap_signed_file" -sigfile "$bootstrap_signature_file" >/dev/null 2>&1 ||
			bootstrap_verify_result=$?
	elif command -v python3 >/dev/null 2>&1; then
		# Older distributions can verify the same Ed25519 signature without
		# replacing their system OpenSSL. Ignore user Python configuration.
		python3 -I - "$bootstrap_key_file" "$bootstrap_signed_file" "$bootstrap_signature_file" <<'PY' || bootstrap_verify_result=$?
import sys

try:
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
except ImportError:
    sys.exit("[one-node] error: install the system python3-cryptography package to verify Ed25519 release signatures with older OpenSSL")

with open(sys.argv[1], "rb") as source:
    public_key = load_pem_public_key(source.read(), backend=default_backend())
if not isinstance(public_key, Ed25519PublicKey):
    sys.exit("[one-node] error: release verification key is not Ed25519")
with open(sys.argv[2], "rb") as source:
    signed_data = source.read()
with open(sys.argv[3], "rb") as source:
    signature = source.read()
public_key.verify(signature, signed_data)
PY
	else
		printf '%s\n' "[one-node] error: signed release verification requires OpenSSL 3 or the system python3 and python3-cryptography packages" >&2
		bootstrap_verify_result=1
	fi
	rm -f -- "$bootstrap_key_file"
	return "$bootstrap_verify_result"
}

# Called after any SHA256SUMS download: fetch <url>.sig and verify it.
bootstrap_verify_checksums_signature() {
	bootstrap_sums_url=$1
	bootstrap_sums_file=$2
	case "$bootstrap_sums_url" in
	https://*) bootstrap_sig_protocols='=https' ;;
	*) bootstrap_sig_protocols='=http,https' ;;
	esac
	rm -f -- "${bootstrap_sums_file}.sig"
	if ! curl -q --proto "$bootstrap_sig_protocols" --proto-redir "$bootstrap_sig_protocols" --tlsv1.2 \
		--fail --silent --show-error --location \
		--connect-timeout 10 --max-time 30 --max-filesize 65536 \
		"${bootstrap_sums_url}.sig" --output "${bootstrap_sums_file}.sig"; then
		bootstrap_trust_fail "release checksums are unsigned: ${bootstrap_sums_url}.sig is unavailable"
		return 0
	fi
	bootstrap_verify_signature "$bootstrap_sums_file" "${bootstrap_sums_file}.sig" ||
		bootstrap_trust_fail "release checksum signature verification failed for ${bootstrap_sums_url}"
}

bootstrap_installed_version() {
	bootstrap_record="${ONE_NODE_INSTALL_DIR:-/opt/one-node}/.installation"
	[ -f "$bootstrap_record" ] && [ ! -L "$bootstrap_record" ] || return 1
	bootstrap_installed=$(sed -n 's/^current_version=//p' "$bootstrap_record" | sed -n '1p')
	bootstrap_validate_version "$bootstrap_installed" || return 1
	printf '%s\n' "$bootstrap_installed"
}

# Highest published version, not the most recently created release.
bootstrap_latest_version() {
	bootstrap_releases=$(bootstrap_curl --no-location \
		--header 'Accept: application/vnd.github+json' \
		--header 'X-GitHub-Api-Version: 2022-11-28' \
		"https://api.github.com/repos/${ONE_NODE_ACTION_REPOSITORY}/releases?per_page=100") ||
		bootstrap_die "unable to resolve the latest One Node release"
	bootstrap_latest=$(printf '%s' "$bootstrap_releases" |
		grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"one-node-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"' |
		sed 's/^.*"one-node-v\([^"]*\)"$/\1/' |
		sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)
	bootstrap_validate_version "$bootstrap_latest" ||
		bootstrap_die "latest One Node release was not found"
	printf '%s\n' "$bootstrap_latest"
}

# The release whose signed manifest vouches for the modules: the requested
# version, else the installed one (rollback, uninstall), else the latest.
bootstrap_resolve_release_version() {
	bootstrap_prefer_installed=$1
	if [ -n "${ONE_NODE_VERSION:-}" ]; then
		bootstrap_validate_version "$ONE_NODE_VERSION" ||
			bootstrap_die "ONE_NODE_VERSION must contain three numeric components"
		ONE_NODE_RELEASE_VERSION=$ONE_NODE_VERSION
		return 0
	fi
	if [ "$bootstrap_prefer_installed" = "true" ] &&
		ONE_NODE_RELEASE_VERSION=$(bootstrap_installed_version); then
		return 0
	fi
	ONE_NODE_RELEASE_VERSION=$(bootstrap_latest_version) || exit 1
	if [ "${ONE_NODE_ENTRYPOINT_KIND:-}" = "install" ]; then
		# Install the same release whose modules were verified.
		ONE_NODE_VERSION=$ONE_NODE_RELEASE_VERSION
		export ONE_NODE_VERSION
		printf '%s\n' "[one-node] using latest published One Node version $ONE_NODE_VERSION"
	fi
}

# The release tag's commit, so entrypoint, modules, and binary share one source.
bootstrap_resolve_action_commit() {
	bootstrap_response=$1
	bootstrap_inherited_commit=${ONE_ACTION_COMMIT:-}
	if [ -n "$bootstrap_inherited_commit" ]; then
		bootstrap_validate_action_commit "$bootstrap_inherited_commit" ||
			bootstrap_die "ONE_ACTION_COMMIT must be an exact lowercase commit SHA"
	fi
	bootstrap_status=$(bootstrap_curl --no-location \
		--header 'Accept: application/vnd.github.sha' \
		--header 'X-GitHub-Api-Version: 2022-11-28' \
		--write-out '%{http_code}' \
		"https://api.github.com/repos/${ONE_NODE_ACTION_REPOSITORY}/commits/one-node-v${ONE_NODE_RELEASE_VERSION}" \
		--output "$bootstrap_response") ||
		bootstrap_die "unable to resolve the One Action commit of one-node-v${ONE_NODE_RELEASE_VERSION}"
	[ "$bootstrap_status" = 200 ] || bootstrap_die "unexpected One Action commit response"
	bootstrap_commit=$(tr -d '\r\n' <"$bootstrap_response")
	bootstrap_validate_action_commit "$bootstrap_commit" ||
		bootstrap_die "One Action commit response must be an exact lowercase commit SHA"
	if [ -n "$bootstrap_inherited_commit" ] && [ "$bootstrap_inherited_commit" != "$bootstrap_commit" ]; then
		bootstrap_warn "using one-node-v${ONE_NODE_RELEASE_VERSION} commit ${bootstrap_commit} instead of inherited ONE_ACTION_COMMIT=${bootstrap_inherited_commit}"
	fi
	ONE_ACTION_COMMIT=$bootstrap_commit
	export ONE_ACTION_COMMIT
}

# Downloads and verifies the signed SHA256SUMS of the selected release.
bootstrap_fetch_release_sums() {
	bootstrap_sums_dir=$1
	bootstrap_release_url="https://github.com/${ONE_NODE_ACTION_REPOSITORY}/releases/download/one-node-v${ONE_NODE_RELEASE_VERSION}/SHA256SUMS"
	ONE_NODE_RELEASE_SUMS="${bootstrap_sums_dir}/release-SHA256SUMS"
	if ! bootstrap_curl --location "$bootstrap_release_url" --output "$ONE_NODE_RELEASE_SUMS"; then
		ONE_NODE_RELEASE_SUMS=""
		bootstrap_trust_fail "unable to download the signed manifest of one-node-v${ONE_NODE_RELEASE_VERSION}"
		return 0
	fi
	bootstrap_verify_checksums_signature "$bootstrap_release_url" "$ONE_NODE_RELEASE_SUMS"
}

# Resolves version, signed manifest, and commit for a release download.
bootstrap_prepare_release() {
	bootstrap_work_dir=$1
	bootstrap_prefer_installed=$2
	command -v curl >/dev/null 2>&1 || bootstrap_die "curl is required to load One Node"
	if [ -n "${ONE_ACTION_COMMIT:-}" ]; then
		bootstrap_validate_action_commit "$ONE_ACTION_COMMIT" ||
			bootstrap_die "ONE_ACTION_COMMIT must be an exact lowercase commit SHA"
	fi
	bootstrap_resolve_release_version "$bootstrap_prefer_installed"
	bootstrap_fetch_release_sums "$bootstrap_work_dir"
	bootstrap_resolve_action_commit "${bootstrap_work_dir}/one-action-commit.sha"
}

# Requires the downloaded file to match its signed manifest entry.
bootstrap_verify_release_file() {
	bootstrap_manifest_path=$1
	bootstrap_file=$2
	if [ -z "$ONE_NODE_RELEASE_SUMS" ]; then
		bootstrap_trust_fail "${bootstrap_manifest_path} cannot be verified without a signed release manifest"
		return 0
	fi
	bootstrap_expected=$(awk -v name="$bootstrap_manifest_path" '
		$2 == name { if (found++) exit 1; value = tolower($1) }
		END { if (found != 1) exit 1; print value }
	' "$ONE_NODE_RELEASE_SUMS") || {
		bootstrap_trust_fail "one-node-v${ONE_NODE_RELEASE_VERSION} does not sign ${bootstrap_manifest_path}"
		return 0
	}
	[ "$(bootstrap_sha256 "$bootstrap_file")" = "$bootstrap_expected" ] ||
		bootstrap_trust_fail "${bootstrap_manifest_path} does not match signed release one-node-v${ONE_NODE_RELEASE_VERSION}; ONE_ACTION_COMMIT must be that release's commit"
}

bootstrap_download_file() {
	bootstrap_url=$1
	bootstrap_output=$2
	bootstrap_description=$3
	case "$bootstrap_url" in
	https://*) bootstrap_protocols='=https' ;;
	*) bootstrap_protocols='=http,https' ;;
	esac
	curl -q --proto "$bootstrap_protocols" --proto-redir "$bootstrap_protocols" --tlsv1.2 \
		--fail --silent --show-error --no-location \
		--connect-timeout 10 --max-time 30 --max-filesize 1048576 \
		"$bootstrap_url" --output "$bootstrap_output" ||
		bootstrap_die "unable to download ${bootstrap_description}"
	[ -s "$bootstrap_output" ] || bootstrap_die "downloaded ${bootstrap_description} is empty"
	/bin/sh -n "$bootstrap_output" || bootstrap_die "downloaded ${bootstrap_description} has invalid syntax"
}

bootstrap_local_source_dir() {
	case "$0" in
	*/*) ;;
	*) return 1 ;;
	esac
	bootstrap_entry_dir=$(CDPATH='' cd -- "$(dirname "$0")" 2>/dev/null && pwd) ||
		return 1
	bootstrap_source="${bootstrap_entry_dir}/scripts"
	[ -f "${bootstrap_source}/${ONE_NODE_ENTRYPOINT_KIND}/main.sh" ] &&
		[ ! -L "${bootstrap_source}/${ONE_NODE_ENTRYPOINT_KIND}/main.sh" ] || return 1
	printf '%s\n' "$bootstrap_source"
}

# Development modules from a local HTTP server skip release verification.
bootstrap_development_base_url() {
	bootstrap_base=${ONE_NODE_SCRIPT_BASE_URL%/}
	case "$bootstrap_base" in
	http://127.0.0.1:*|http://localhost:*|http://host.orb.internal:*)
		bootstrap_insecure ||
			bootstrap_die "local HTTP modules require ONE_NODE_ALLOW_INSECURE=true"
		;;
	*) bootstrap_die "ONE_NODE_SCRIPT_BASE_URL is only available for local development" ;;
	esac
	case "$bootstrap_base" in
	*/scripts) ;;
	*) bootstrap_die "ONE_NODE_SCRIPT_BASE_URL must end in scripts" ;;
	esac
	printf '%s\n' "$bootstrap_base"
}

bootstrap_download_modules() {
	bootstrap_destination=$1
	bootstrap_with_installer=$2
	if [ -n "${ONE_NODE_SCRIPT_BASE_URL:-}" ]; then
		bootstrap_base=$(bootstrap_development_base_url) || exit 1
		bootstrap_verify=false
	else
		bootstrap_prefer_installed=true
		[ "$ONE_NODE_ENTRYPOINT_KIND" != "install" ] || bootstrap_prefer_installed=false
		bootstrap_prepare_release "$bootstrap_destination" "$bootstrap_prefer_installed"
		bootstrap_base="https://raw.githubusercontent.com/${ONE_NODE_ACTION_REPOSITORY}/${ONE_ACTION_COMMIT}/node/scripts"
		bootstrap_verify=true
	fi
	for bootstrap_module in $ONE_NODE_ENTRYPOINT_MODULES; do
		install -d -m 0700 "${bootstrap_destination}/${bootstrap_module%/*}"
		bootstrap_download_file "${bootstrap_base}/${bootstrap_module}" \
			"${bootstrap_destination}/${bootstrap_module}" "${ONE_NODE_ENTRYPOINT_KIND} module: ${bootstrap_module}"
		chmod 0600 "${bootstrap_destination}/${bootstrap_module}"
		[ "$bootstrap_verify" = false ] ||
			bootstrap_verify_release_file "node/scripts/${bootstrap_module}" "${bootstrap_destination}/${bootstrap_module}"
	done
	[ "$bootstrap_with_installer" = "true" ] || return 0
	bootstrap_download_file "${bootstrap_base%/scripts}/install.sh" \
		"${bootstrap_destination}/install.sh" "the persistent installer"
	chmod 0700 "${bootstrap_destination}/install.sh"
	[ "$bootstrap_verify" = false ] ||
		bootstrap_verify_release_file "node/install.sh" "${bootstrap_destination}/install.sh"
	ONE_NODE_INSTALLER_SOURCE="${bootstrap_destination}/install.sh"
	export ONE_NODE_INSTALLER_SOURCE
}

# Sources the entrypoint modules from a checkout next to $0 or, when piped or
# run from a temporary file, from the verified release commit. With
# with_installer=false the temporary modules are removed once sourced.
bootstrap_load_modules() {
	bootstrap_with_installer=$1
	bootstrap_source=$(bootstrap_local_source_dir 2>/dev/null || true)
	if [ -z "$bootstrap_source" ]; then
		ONE_NODE_ENTRYPOINT_TEMP_DIR=$(mktemp -d "/tmp/one-node-${ONE_NODE_ENTRYPOINT_KIND}.XXXXXX")
		chmod 0700 "$ONE_NODE_ENTRYPOINT_TEMP_DIR"
		trap bootstrap_cleanup EXIT HUP INT TERM
		bootstrap_download_modules "$ONE_NODE_ENTRYPOINT_TEMP_DIR" "$bootstrap_with_installer"
		bootstrap_source=$ONE_NODE_ENTRYPOINT_TEMP_DIR
	elif [ "$bootstrap_with_installer" = "true" ]; then
		ONE_NODE_INSTALLER_SOURCE="${bootstrap_source%/scripts}/install.sh"
		export ONE_NODE_INSTALLER_SOURCE
	fi
	for bootstrap_module in $ONE_NODE_ENTRYPOINT_MODULES; do
		bootstrap_module_path="${bootstrap_source}/${bootstrap_module}"
		[ -f "$bootstrap_module_path" ] && [ ! -L "$bootstrap_module_path" ] ||
			bootstrap_die "${ONE_NODE_ENTRYPOINT_KIND} module must be a regular file: ${bootstrap_module}"
		# shellcheck disable=SC1090
		. "$bootstrap_module_path"
	done
	if [ "$bootstrap_with_installer" != "true" ]; then
		bootstrap_cleanup
		ONE_NODE_ENTRYPOINT_TEMP_DIR=""
		trap - EXIT HUP INT TERM
	fi
}
# <<< one-node bootstrap <<<

manager_die() {
	printf '%s\n' "[one-node] error: $*" >&2
	exit 1
}

manager_require_root() {
	[ "$(id -u)" -eq 0 ] || manager_die "run ./install.sh as root"
}

manager_manifest_value() {
	manager_key=$1
	manager_matches=$(sed -n "s/^${manager_key}=//p" "$ONE_NODE_INSTALL_RECORD")
	[ -n "$manager_matches" ] || return 1
	[ "$(printf '%s\n' "$manager_matches" | wc -l | tr -d ' ')" = 1 ] || return 1
	printf '%s\n' "$manager_matches"
}

manager_env_value() {
	manager_key=$1
	sed -n "s/^${manager_key}=\"\(.*\)\"$/\1/p" "${ONE_NODE_INSTALL_DIR}/.env" | sed -n '1p'
}

manager_process_details() {
	manager_pid=$1
	MANAGER_MEMORY="-"
	MANAGER_UPTIME="-"
	case "$manager_pid" in
	''|*[!0-9]*|0) return ;;
	esac
	if [ -r "/proc/${manager_pid}/status" ]; then
		manager_rss=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB$/\1/p' "/proc/${manager_pid}/status")
		if [ -n "$manager_rss" ]; then
			MANAGER_MEMORY=$(awk -v kib="$manager_rss" 'BEGIN {
				if (kib >= 1048576) printf "%.2f GiB", kib / 1048576;
				else if (kib >= 1024) printf "%.1f MiB", kib / 1024;
				else printf "%d KiB", kib
			}')
		fi
	fi
	if command -v ps >/dev/null 2>&1; then
		MANAGER_UPTIME=$(ps -o etime= -p "$manager_pid" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
		[ -n "$MANAGER_UPTIME" ] || MANAGER_UPTIME="-"
	fi
}

manager_status() {
	manager_require_root
	[ -f "$ONE_NODE_INSTALL_RECORD" ] && [ ! -L "$ONE_NODE_INSTALL_RECORD" ] ||
		manager_die "One Node installation manifest was not found"
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	manager_version=$(manager_manifest_value current_version) || manager_die "current version is missing"
	manager_previous=$(manager_manifest_value previous_version 2>/dev/null || true)
	manager_node_id=$(manager_env_value NODE_NODE_ID 2>/dev/null || true)
	manager_pid=""
	manager_state="unknown"
	manager_memory="-"
	case "$manager_mode" in
	native)
		if command -v systemctl >/dev/null 2>&1; then
			manager_state=$(systemctl is-active one-node.service 2>/dev/null || true)
			manager_pid=$(systemctl show one-node.service -p MainPID --value 2>/dev/null || true)
		fi
		manager_process_details "$manager_pid"
		manager_memory=$MANAGER_MEMORY
		;;
	docker)
		if command -v docker >/dev/null 2>&1; then
			manager_state=$(docker inspect -f '{{.State.Status}}' one-node 2>/dev/null || true)
			manager_pid=$(docker inspect -f '{{.State.Pid}}' one-node 2>/dev/null || true)
			manager_memory=$(docker stats --no-stream --format '{{.MemUsage}}' one-node 2>/dev/null || true)
		fi
		manager_process_details "$manager_pid"
		[ -n "$manager_memory" ] || manager_memory=$MANAGER_MEMORY
		;;
	*) manager_die "unsupported installation mode: $manager_mode" ;;
	esac
	[ -n "$manager_state" ] || manager_state="unavailable"
	[ -n "$manager_pid" ] || manager_pid="-"
	[ -n "$manager_memory" ] || manager_memory="-"
	[ -n "$manager_node_id" ] || manager_node_id="-"
	[ -n "$manager_previous" ] || manager_previous="-"
	printf '%s\n' \
		"One Node status" \
		"  mode:             $manager_mode" \
		"  version:          $manager_version" \
		"  previous version: $manager_previous" \
		"  node id:          $manager_node_id" \
		"  state:            $manager_state" \
		"  pid:              $manager_pid" \
		"  memory:           $manager_memory" \
		"  uptime:           $MANAGER_UPTIME"
}

manager_doctor() {
	manager_status
	manager_mode=$(manager_manifest_value mode)
	[ -f "${ONE_NODE_INSTALL_DIR}/.env" ] && [ ! -L "${ONE_NODE_INSTALL_DIR}/.env" ] || manager_die "environment file is missing or unsafe"
	case "$manager_mode" in
	native)
		command -v systemctl >/dev/null 2>&1 || manager_die "systemctl is unavailable"
		systemctl is-active --quiet one-node.service || manager_die "one-node.service is not active"
		;;
	docker)
		command -v docker >/dev/null 2>&1 || manager_die "Docker is unavailable"
		docker compose version >/dev/null 2>&1 || manager_die "Docker Compose v2 is unavailable"
		docker inspect -f '{{.State.Running}}' one-node 2>/dev/null | grep -qx true || manager_die "One Node container is not running"
		;;
	esac
	command -v nft >/dev/null 2>&1 || manager_die "nftables is unavailable"
	command -v systemctl >/dev/null 2>&1 || manager_die "systemctl is unavailable"
	systemctl is-active --quiet one-node-firewall.path || manager_die "one-node-firewall.path is not active"
	nft -nn list table inet one_node >/dev/null 2>&1 || manager_die "One Node nftables table is unavailable"
	manager_warn_host_firewalls
	printf '%s\n' '[one-node] environment check passed'
}

# An accept in the One Node table cannot override a drop in another
# firewall's table, so runtime ports stay closed until that firewall allows them.
manager_warn_host_firewalls() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
		printf '%s\n' '[one-node] warning: ufw is active; allow the runtime inbound ports in ufw or clients cannot connect' >&2
	fi
	if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then
		printf '%s\n' '[one-node] warning: firewalld is running; allow the runtime inbound ports in firewalld or clients cannot connect' >&2
	fi
}

# Runs upgrade.sh or uninstall.sh from the exact commit of a signed release,
# after checking the downloaded entrypoint against that release's manifest.
manager_run_entrypoint() {
	manager_entrypoint=$1
	shift
	manager_temp_dir=$(mktemp -d "/tmp/one-node-manager.XXXXXX") ||
		manager_die "unable to create temporary directory"
	chmod 0700 "$manager_temp_dir"
	trap 'rm -rf -- "$manager_temp_dir"' EXIT HUP INT TERM
	bootstrap_prepare_release "$manager_temp_dir" true
	manager_script="${manager_temp_dir}/${manager_entrypoint}"
	bootstrap_download_file \
		"https://raw.githubusercontent.com/${ONE_NODE_ACTION_REPOSITORY}/${ONE_ACTION_COMMIT}/node/${manager_entrypoint}" \
		"$manager_script" "$manager_entrypoint"
	bootstrap_verify_release_file "node/${manager_entrypoint}" "$manager_script"
	chmod 0700 "$manager_script"
	manager_exit=0
	/bin/sh "$manager_script" "$@" || manager_exit=$?
	rm -rf -- "$manager_temp_dir"
	trap - EXIT HUP INT TERM
	return "$manager_exit"
}

manager_upgrade() {
	manager_target=${1:-latest}
	if [ "$manager_target" = latest ]; then
		manager_target=$(bootstrap_latest_version) || exit 1
	fi
	case "$manager_target" in
	''|*[!0-9.]*|.*|*.|*..*) manager_die "upgrade version must contain three numeric components" ;;
	esac
	[ "$(printf '%s' "$manager_target" | tr -cd . | wc -c | tr -d ' ')" = 2 ] ||
		manager_die "upgrade version must contain three numeric components"
	ONE_NODE_VERSION=$manager_target
	export ONE_NODE_VERSION
	manager_run_entrypoint upgrade.sh
}

manager_restart() {
	manager_require_root
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	case "$manager_mode" in
	native) systemctl restart one-node.service ;;
	docker) docker compose -f "${ONE_NODE_INSTALL_DIR}/docker-compose.yml" up -d --force-recreate ;;
	*) manager_die "unsupported installation mode: $manager_mode" ;;
	esac
	manager_status
}

manager_logs() {
	manager_require_root
	manager_follow=${1:-false}
	manager_mode=$(manager_manifest_value mode) || manager_die "installation mode is missing"
	case "$manager_mode:$manager_follow" in
	native:true) exec journalctl -u one-node.service -n 100 -f ;;
	native:false) journalctl -u one-node.service -n 100 --no-pager ;;
	docker:true) exec docker logs --tail 100 -f one-node ;;
	docker:false) docker logs --tail 100 one-node ;;
	*) manager_die "unsupported log request" ;;
	esac
}

manager_confirm_uninstall() {
	printf '%s' 'Remove One Node, its identity, and all runtime state? [y/N] '
	read -r manager_answer || return 1
	case "$manager_answer" in y|Y|yes|YES) return 0 ;; esac
	return 1
}

manager_help() {
	printf '%s\n' \
		'Manage the installed One Node runtime.' \
		'' \
		'Usage: ./install.sh [option]' \
		'' \
		'  --status' \
		'  --doctor' \
		'  --upgrade [latest|VERSION]' \
		'  --rollback' \
		'  --restart' \
		'  --logs [--follow]' \
		'  --uninstall [--yes]'
}

manager_interactive() {
	while :; do
		printf '%s\n' \
			'' \
			'One Node' \
			'  1. Status' \
			'  2. Doctor' \
			'  3. Upgrade to latest' \
			'  4. Upgrade to version' \
			'  5. Roll back' \
			'  6. Restart' \
			'  7. Logs' \
			'  8. Follow logs' \
			'  9. Uninstall' \
			'  0. Exit'
		printf '%s' 'Select: '
		read -r manager_choice || return 0
		case "$manager_choice" in
		1) manager_status ;;
		2) manager_doctor ;;
		3) manager_upgrade latest ;;
		4) printf '%s' 'Version: '; read -r manager_version; manager_upgrade "$manager_version" ;;
		5) manager_run_entrypoint upgrade.sh --rollback ;;
		6) manager_restart ;;
		7) manager_logs false ;;
		8) manager_logs true ;;
		9) manager_confirm_uninstall && manager_run_entrypoint uninstall.sh ;;
		0) return 0 ;;
		*) printf '%s\n' '[one-node] invalid selection' ;;
		esac
	done
}

manager_main() {
	manager_require_root
	if [ "$#" -eq 0 ]; then
		if [ -t 0 ] && [ -t 1 ]; then
			manager_interactive
		else
			manager_help
		fi
		return
	fi
	case "$1" in
	--status) [ "$#" -eq 1 ] || manager_die "--status takes no arguments"; manager_status ;;
	--doctor) [ "$#" -eq 1 ] || manager_die "--doctor takes no arguments"; manager_doctor ;;
	--upgrade) [ "$#" -le 2 ] || manager_die "--upgrade accepts one version"; manager_upgrade "${2:-latest}" ;;
	--rollback) [ "$#" -eq 1 ] || manager_die "--rollback takes no arguments"; manager_run_entrypoint upgrade.sh --rollback ;;
	--restart) [ "$#" -eq 1 ] || manager_die "--restart takes no arguments"; manager_restart ;;
	--logs) [ "$#" -le 2 ] || manager_die "--logs accepts only --follow"; [ "${2:-}" = --follow ] && manager_logs true || manager_logs false ;;
	--uninstall)
		if [ "${2:-}" = --yes ]; then manager_run_entrypoint uninstall.sh
		elif [ "$#" -eq 1 ] && [ -t 0 ]; then manager_confirm_uninstall && manager_run_entrypoint uninstall.sh
		else manager_die "--uninstall requires --yes outside an interactive terminal"
		fi
		;;
	--help|-h) manager_help ;;
	*) manager_die "unknown management option: $1" ;;
	esac
}

entrypoint_management_requested() {
	[ -f "$ONE_NODE_INSTALL_RECORD" ] && [ ! -L "$ONE_NODE_INSTALL_RECORD" ] || return 1
	[ "$#" -eq 0 ] && return 0
	case "$1" in
	--status|--doctor|--upgrade|--rollback|--restart|--logs|--uninstall|--help|-h) return 0 ;;
	esac
	return 1
}

if entrypoint_management_requested "$@"; then
	manager_main "$@"
	exit $?
fi

bootstrap_load_modules true

if [ "${ONE_NODE_INSTALLER_LIBRARY_ONLY:-0}" != "1" ]; then
	main "$@"
fi

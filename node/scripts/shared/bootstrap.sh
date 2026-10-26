#!/bin/sh

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

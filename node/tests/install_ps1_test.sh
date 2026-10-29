#!/bin/sh
# Windows installer (install.ps1) unit tests. They run under PowerShell 7 on
# Linux: a local pwsh when installed, else the official PowerShell image in
# Docker. Without either the test is skipped. A throwaway RSA-3072 key signs
# the fixture SHA256SUMS exactly as scripts/sign-release.sh signs releases.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PWSH_IMAGE=${ONE_NODE_PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}
# The image has no arm64 build; on Apple Silicon Docker would otherwise pick
# the 32-bit ARM one, which crashes under emulation.
PWSH_PLATFORM=${ONE_NODE_PWSH_PLATFORM:-linux/amd64}

skip() {
	printf '%s\n' "skip: install.ps1 tests: $*"
	exit 0
}

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

if command -v pwsh >/dev/null 2>&1; then
	runner=pwsh
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	runner=docker
else
	skip "neither pwsh nor a reachable Docker daemon is available"
fi
command -v openssl >/dev/null 2>&1 || fail "openssl is required to sign the test fixture"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/one-node-ps1-test.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM
FIXTURE="$TEST_TEMP_DIR/fixture"
mkdir -p "$FIXTURE"

openssl genrsa -out "$TEST_TEMP_DIR/release.pem" 3072 2>/dev/null
printf '%s\n' amd64 >"$TEST_TEMP_DIR/one-node-windows-amd64.exe"
printf '%s\n' arm64 >"$TEST_TEMP_DIR/one-node-windows-arm64.exe"
{
	printf '%s  %s\n' "$(sha256 "$TEST_TEMP_DIR/one-node-windows-amd64.exe")" one-node-windows-amd64.exe
	printf '%s  %s\n' "$(sha256 "$TEST_TEMP_DIR/one-node-windows-arm64.exe")" one-node-windows-arm64.exe
	printf '%s  %s\n' "$(sha256 "$ROOT_DIR/install.sh")" node/install.sh
	printf '%s  %s\n' "$(sha256 "$ROOT_DIR/install.ps1")" node/install.ps1
} >"$FIXTURE/SHA256SUMS"
openssl dgst -sha256 -sign "$TEST_TEMP_DIR/release.pem" \
	-out "$FIXTURE/SHA256SUMS.rsa.sig" "$FIXTURE/SHA256SUMS"
openssl rsa -in "$TEST_TEMP_DIR/release.pem" -noout -modulus 2>/dev/null |
	sed 's/^Modulus=//' >"$FIXTURE/modulus.hex"
[ -s "$FIXTURE/modulus.hex" ] || fail "unable to read the fixture RSA modulus"
chmod -R a+rX "$FIXTURE"

case "$runner" in
pwsh)
	ONE_NODE_PS_FIXTURE_DIR="$FIXTURE" \
		pwsh -NoProfile -NonInteractive -File "$ROOT_DIR/tests/install_ps1_test.ps1"
	;;
docker)
	# W^X off: .NET crashes (PAL_SEHException) under Rosetta emulation.
	docker run --rm --platform "$PWSH_PLATFORM" \
		-v "$ROOT_DIR:/work/node:ro" \
		-v "$FIXTURE:/fixture:ro" \
		-e ONE_NODE_PS_FIXTURE_DIR=/fixture \
		-e DOTNET_EnableWriteXorExecute=0 \
		"$PWSH_IMAGE" \
		pwsh -NoProfile -NonInteractive -File /work/node/tests/install_ps1_test.ps1
	;;
esac

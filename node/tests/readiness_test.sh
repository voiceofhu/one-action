#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT HUP INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

# shellcheck disable=SC1090
. "$ROOT_DIR/scripts/install/common.sh"
. "$ROOT_DIR/scripts/install/readiness.sh"

curl() {
	printf '%s' "$CONTROL_PROBE_STATUS"
}

ONE_NODE_SERVER='grpcs://control.example.test:443'
CONTROL_PROBE_STATUS=415
probe_control_endpoint

CONTROL_PROBE_STATUS=502
if (probe_control_endpoint) >"$TEST_TEMP_DIR/502.log" 2>&1; then
	fail "control preflight accepted an HTTP 502 response"
fi
grep -F 'verify its TLS/HTTP2 proxy and port 27519 upstream' \
	"$TEST_TEMP_DIR/502.log" >/dev/null

ONE_NODE_SERVER='grpc://control.example.test:27519'
curl() {
	fail "plaintext development control endpoint was probed"
}
probe_control_endpoint

INSTALL_MODE=native
ONE_NODE_ENROLL_TIMEOUT=120
journalctl() {
	printf '%s\n' "$*" >"$TEST_TEMP_DIR/journalctl.log"
}
print_runtime_logs
grep -F -- '--since -135 seconds' "$TEST_TEMP_DIR/journalctl.log" >/dev/null

ONE_NODE_READINESS_RETURN_ONLY=true
ONE_NODE_ENROLL_TIMEOUT=0
ONE_NODE_ID=41
ONE_NODE_SERVER='grpcs://control.example.test:443'
print_runtime_logs() {
	:
}
identity_is_active() {
	return 1
}
if wait_for_ready_heartbeat >"$TEST_TEMP_DIR/registration.log" 2>&1; then
	fail "readiness accepted a missing active identity"
fi
grep -F 'Node registration did not complete through grpcs://control.example.test:443' \
	"$TEST_TEMP_DIR/registration.log" >/dev/null

identity_is_active() {
	return 0
}
if wait_for_ready_heartbeat >"$TEST_TEMP_DIR/revision.log" 2>&1; then
	fail "readiness accepted missing runtime revisions"
fi
grep -F 'One Node did not reach the expected config and binding revisions' \
	"$TEST_TEMP_DIR/revision.log" >/dev/null

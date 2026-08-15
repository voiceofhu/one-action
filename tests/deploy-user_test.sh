#!/usr/bin/env bash

set -Eeuo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_args() {
  local expected_count="$1"
  shift
  [[ "$#" -eq "$expected_count" ]] || fail "unexpected argument count: $*"
}

log_call() {
  local program="$1"
  shift
  {
    printf '%s image=<%s>' "$program" "${DOCKER_IMAGE-<unset>}"
    printf ' <%s>' "$@"
    printf '\n'
  } >>"$FAKE_COMMAND_LOG"
}

fake_ssh() {
  assert_args 2 "$@"
  [[ "$1" == "$FAKE_SSH_HOST" ]] || fail "unexpected SSH host: $1"

  local remote_command="$2"
  local remote_dir_assignment="REMOTE_DIR=$FAKE_REMOTE_DIR"
  local fixture_assignment
  fixture_assignment="REMOTE_DIR=$(printf '%q' "$FAKE_SERVER_ROOT")"

  [[ "$remote_command" == *"$remote_dir_assignment"* ]] ||
    fail "remote command is missing the expected REMOTE_DIR"
  [[ "$remote_command" == *"LOG_TAIL=$FAKE_LOG_TAIL"* ]] ||
    fail "remote command is missing LOG_TAIL"

  printf 'ssh <%s> <%s>\n' "$1" "$remote_command" >>"$FAKE_COMMAND_LOG"
  remote_command="${remote_command/$remote_dir_assignment/$fixture_assignment}"
  PATH="$FAKE_BIN:$PATH" bash -c "$remote_command"
}

fake_compose() {
  if [[ "${1-}" == "version" ]]; then
    assert_args 1 "$@"
    return 0
  fi

  [[ "$#" -ge 9 ]] || fail "compose invocation is missing common arguments: $*"
  [[ "$1" == "--project-name" && "$2" == "$FAKE_PROJECT_NAME" ]] ||
    fail "unexpected compose project: $*"
  [[ "$3" == "--project-directory" && "$4" == "$FAKE_SERVER_ROOT" ]] ||
    fail "unexpected compose project directory: $*"
  [[ "$5" == "--env-file" && "$6" == "$FAKE_SERVER_ROOT/.env" ]] ||
    fail "unexpected compose env file: $*"
  [[ "$7" == "--file" && "$8" == "$FAKE_SERVER_ROOT/docker-compose.yml" ]] ||
    fail "unexpected compose file: $*"
  shift 8

  local subcommand="$1"
  shift
  case "$subcommand" in
    config)
      assert_args 1 "$@"
      case "$1" in
        --quiet)
          return 0
          ;;
        --environment)
          printf '%s\n' 'ONE_USER_CERT_DIR=./custom-cert'
          return 0
          ;;
        --images)
          printf '%s\n' "$FAKE_EXPECTED_IMAGE"
          return 0
          ;;
      esac
      ;;
    ps)
      assert_args 2 "$@"
      [[ "$1" == "-q" && "$2" == "$FAKE_SERVICE_NAME" ]] ||
        fail "unexpected compose ps arguments: $*"

      local count=0
      if [[ -f "$FAKE_PS_STATE" ]]; then
        read -r count <"$FAKE_PS_STATE"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_PS_STATE"
      if [[ "$count" -gt 1 ]]; then
        printf '%s\n' "$FAKE_CONTAINER_ID"
      fi
      return 0
      ;;
    pull)
      assert_args 1 "$@"
      [[ "$1" == "$FAKE_SERVICE_NAME" ]] || fail "unexpected pull service: $1"
      return 0
      ;;
    up)
      assert_args 6 "$@"
      [[ "$1" == "-d" && "$2" == "--no-deps" && "$3" == "--wait" &&
        "$4" == "--wait-timeout" && "$5" == "120" && "$6" == "$FAKE_SERVICE_NAME" ]] ||
        fail "unexpected compose up arguments: $*"
      return 0
      ;;
  esac

  fail "unexpected compose invocation: $subcommand $*"
}

fake_docker() {
  [[ "${DOCKER_IMAGE-}" == "$FAKE_EXPECTED_IMAGE" ]] ||
    fail "Docker did not receive the temporary DOCKER_IMAGE"
  log_call docker "$@"

  case "${1-}" in
    compose)
      shift
      fake_compose "$@"
      ;;
    image)
      assert_args 5 "$@"
      [[ "$2" == "inspect" && "$3" == "--format" && "$4" == "{{.Id}}" &&
        "$5" == "$FAKE_EXPECTED_IMAGE" ]] || fail "unexpected image inspect: $*"
      printf '%s\n' "$FAKE_EXPECTED_IMAGE_ID"
      ;;
    inspect)
      assert_args 4 "$@"
      [[ "$2" == "--format" && "$4" == "$FAKE_CONTAINER_ID" ]] ||
        fail "unexpected container inspect: $*"
      case "$3" in
        '{{.State.Running}}') printf 'true\n' ;;
        '{{.Image}}') printf '%s\n' "$FAKE_EXPECTED_IMAGE_ID" ;;
        *) fail "unexpected container inspect format: $3" ;;
      esac
      ;;
    *)
      fail "unexpected docker invocation: $*"
      ;;
  esac
}

fake_curl() {
  log_call curl "$@"
  assert_args 8 "$@"
  [[ "$1" == "--fail" && "$2" == "--silent" && "$3" == "--show-error" &&
    "$4" == "--connect-timeout" && "$5" == "2" && "$6" == "--max-time" &&
    "$7" == "5" && "$8" == "$FAKE_READY_URL" ]] || fail "unexpected curl invocation: $*"
}

fixture_snapshot() {
  local path mode checksum
  while IFS= read -r path; do
    if stat -f '%Lp' "$path" >/dev/null 2>&1; then
      mode="$(stat -f '%Lp' "$path")"
    else
      mode="$(stat -c '%a' "$path")"
    fi

    if [[ -d "$path" ]]; then
      printf 'directory %s %s\n' "${path#"$FAKE_SERVER_ROOT"/}" "$mode"
    elif [[ -f "$path" ]]; then
      checksum="$(cksum <"$path")"
      printf 'file %s %s %s\n' "${path#"$FAKE_SERVER_ROOT"/}" "$mode" "$checksum"
    else
      printf 'other %s %s\n' "${path#"$FAKE_SERVER_ROOT"/}" "$mode"
    fi
  done < <(find "$FAKE_SERVER_ROOT" -mindepth 1 -print | LC_ALL=C sort)
}

assert_no_transient_env_files() {
  [[ ! -e "$FAKE_SERVER_ROOT/.image.env" ]] || fail ".image.env was persisted"
  [[ ! -e "$FAKE_SERVER_ROOT/.env.tmp" ]] || fail ".env.tmp was persisted"
  if find "$FAKE_SERVER_ROOT" \( -name '.image.env' -o -name '.env.tmp' \) -print |
    grep -q .; then
    fail "a transient image env file was persisted"
  fi
}

invoke_deploy() {
  local image="$1"
  env \
    PATH="$FAKE_BIN:$PATH" \
    SSH_HOST="$FAKE_SSH_HOST" \
    REMOTE_DIR="$FAKE_REMOTE_DIR" \
    DOCKER_IMAGE="$image" \
    COMPOSE_PROJECT_NAME="$FAKE_PROJECT_NAME" \
    COMPOSE_SERVICE_NAME="$FAKE_SERVICE_NAME" \
    READY_URL="$FAKE_READY_URL" \
    USE_SUDO=0 \
    LOG_TAIL="$FAKE_LOG_TAIL" \
    bash "$DEPLOY_SCRIPT"
}

require_log() {
  local expected="$1"
  grep -F -- "$expected" "$FAKE_COMMAND_LOG" >/dev/null ||
    fail "missing command log entry: $expected"
}

expect_rejected_image() {
  local label="$1"
  local image="$2"
  local ssh_calls_before ssh_calls_after output

  ssh_calls_before="$(grep -c '^ssh ' "$FAKE_COMMAND_LOG" || true)"
  if output="$(invoke_deploy "$image" 2>&1)"; then
    fail "$label image unexpectedly passed validation"
  fi
  [[ "$output" == *"DOCKER_IMAGE must be"* ]] ||
    fail "$label image returned the wrong error: $output"
  ssh_calls_after="$(grep -c '^ssh ' "$FAKE_COMMAND_LOG" || true)"
  [[ "$ssh_calls_after" == "$ssh_calls_before" ]] ||
    fail "$label image reached SSH"
}

main() {
  local test_script project_root test_root fixture_before fixture_after output
  local digest

  test_script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  project_root="$(cd "$(dirname "$test_script")/.." && pwd)"
  DEPLOY_SCRIPT="$project_root/scripts/deploy/deploy-user.sh"
  [[ -f "$DEPLOY_SCRIPT" ]] || fail "deploy script not found: $DEPLOY_SCRIPT"

  test_root="$(mktemp -d)"
  trap "rm -rf -- $(printf '%q' "$test_root")" EXIT

  export FAKE_BIN="$test_root/bin"
  export FAKE_SERVER_ROOT="$test_root/server"
  export FAKE_COMMAND_LOG="$test_root/commands.log"
  export FAKE_PS_STATE="$test_root/ps-count"
  export FAKE_SSH_HOST="one-user-test"
  export FAKE_REMOTE_DIR="/opt/one-user-test"
  export FAKE_PROJECT_NAME="one-user"
  export FAKE_SERVICE_NAME="user"
  export FAKE_READY_URL="http://127.0.0.1:27510/readyz"
  export FAKE_LOG_TAIL="37"

  digest="$(printf 'a%.0s' {1..64})"
  export FAKE_EXPECTED_IMAGE="ghcr.io/voiceofhu/one-user:26.815.2001@sha256:$digest"
  export FAKE_EXPECTED_IMAGE_ID="sha256:$(printf 'b%.0s' {1..64})"
  export FAKE_CONTAINER_ID="$(printf 'c%.0s' {1..64})"

  mkdir -p "$FAKE_BIN" "$FAKE_SERVER_ROOT/custom-cert"
  : >"$FAKE_COMMAND_LOG"
  printf 'APP_ENV=production\nAPP_SECRET=fixture-only\nONE_USER_CERT_DIR=./custom-cert\n' \
    >"$FAKE_SERVER_ROOT/.env"
  printf 'services:\n  user:\n    image: ${DOCKER_IMAGE:?required}\n' >"$FAKE_SERVER_ROOT/docker-compose.yml"
  printf '%s\n' 'fixture certificate' >"$FAKE_SERVER_ROOT/custom-cert/server.crt"
  printf '%s\n' 'fixture private key' >"$FAKE_SERVER_ROOT/custom-cert/server.key"
  chmod 600 "$FAKE_SERVER_ROOT/.env" "$FAKE_SERVER_ROOT/custom-cert/server.key"
  ln -s "$test_script" "$FAKE_BIN/ssh"
  ln -s "$test_script" "$FAKE_BIN/docker"
  ln -s "$test_script" "$FAKE_BIN/curl"

  assert_no_transient_env_files
  fixture_before="$(fixture_snapshot)"
  output="$(invoke_deploy "$FAKE_EXPECTED_IMAGE" 2>&1)" ||
    fail "successful deployment path failed: $output"
  fixture_after="$(fixture_snapshot)"

  [[ "$fixture_after" == "$fixture_before" ]] || fail "server fixture changed during deployment"
  assert_no_transient_env_files
  [[ "$output" == *"Deployed One User image $FAKE_EXPECTED_IMAGE as container $FAKE_CONTAINER_ID"* ]] ||
    fail "success output is missing the deployed image and container ID: $output"

  require_log "docker image=<$FAKE_EXPECTED_IMAGE> <compose> <version>"
  require_log "<config> <--quiet>"
  require_log "<config> <--environment>"
  require_log "<config> <--images>"
  require_log "<pull> <$FAKE_SERVICE_NAME>"
  require_log "<image> <inspect> <--format> <{{.Id}}> <$FAKE_EXPECTED_IMAGE>"
  require_log "<up> <-d> <--no-deps> <--wait> <--wait-timeout> <120> <$FAKE_SERVICE_NAME>"
  require_log "<inspect> <--format> <{{.State.Running}}> <$FAKE_CONTAINER_ID>"
  require_log "<inspect> <--format> <{{.Image}}> <$FAKE_CONTAINER_ID>"
  require_log "curl image=<$FAKE_EXPECTED_IMAGE> <--fail> <--silent> <--show-error> <--connect-timeout> <2> <--max-time> <5> <$FAKE_READY_URL>"

  expect_rejected_image "tag-only" "ghcr.io/voiceofhu/one-user:26.815.2001"
  expect_rejected_image "latest" "ghcr.io/voiceofhu/one-user:latest@sha256:$digest"
  expect_rejected_image "wrong-package" "ghcr.io/voiceofhu/not-one-user:26.815.2001@sha256:$digest"

  printf 'deploy-user tests passed\n'
}

case "$(basename "$0")" in
  ssh) fake_ssh "$@" ;;
  docker) fake_docker "$@" ;;
  curl) fake_curl "$@" ;;
  *) main "$@" ;;
esac

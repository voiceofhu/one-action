#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$PROJECT_ROOT/tests/fixtures"
TEMP_ROOT=$(mktemp -d /tmp/one-egress-test.XXXXXX)
trap 'rm -rf -- "$TEMP_ROOT"' EXIT INT TERM HUP

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local description=$1
  shift
  if "$@" >"$TEMP_ROOT/failure.out" 2>&1; then
    fail "$description"
  fi
}

directory_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

make_test_root() {
  local name=$1
  local root="$TEMP_ROOT/$name"
  mkdir -p "$root/etc/one-browser-egress" "$root/etc/systemd/system"
  printf '%s\n' \
    'EGRESS_ID=test-egress' \
    'EGRESS_CONTROL_URL=https://browser.example.test' \
    'EGRESS_CONTROL_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789' \
    >"$root/etc/one-browser-egress/egress.env"
  printf '%s' "$root"
}

FAKE_BIN="$TEMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
ln -s "$PROJECT_ROOT/tests/fakes/egress-curl" "$FAKE_BIN/curl"
ln -s "$PROJECT_ROOT/tests/fakes/egress-docker" "$FAKE_BIN/docker"
ln -s "$PROJECT_ROOT/tests/fakes/egress-systemctl" "$FAKE_BIN/systemctl"
export PATH="$FAKE_BIN:$PATH"
export EGRESS_FIXTURE_DIR="$FIXTURES"
export EGRESS_FAKE_LOG="$TEMP_ROOT/fake.log"
export EGRESS_FAKE_DOCKER_STATE="$TEMP_ROOT/docker.state"
: >"$EGRESS_FAKE_LOG"

export ONE_EGRESS_LIBRARY_ONLY=true
# shellcheck source=../install.sh
# shellcheck disable=SC1091
. "$PROJECT_ROOT/install.sh"
unset ONE_EGRESS_LIBRARY_ONLY

parse_config() (
  load_config_env "$1"
)

injection_file="$TEMP_ROOT/injection.env"
dollar_sentinel="$TEMP_ROOT/dollar-executed"
backtick_sentinel="$TEMP_ROOT/backtick-executed"
# These literal command substitutions are malicious configuration test inputs.
# shellcheck disable=SC2016
printf 'EGRESS_ID=$(touch %s)\n' "$dollar_sentinel" >"$injection_file"
# shellcheck disable=SC2016
printf 'EGRESS_CONTROL_URL=`touch %s`\n' "$backtick_sentinel" >>"$injection_file"
printf '%s\n' 'EGRESS_CONTROL_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789' >>"$injection_file"
parse_config "$injection_file"
[[ ! -e "$dollar_sentinel" && ! -e "$backtick_sentinel" ]] ||
  fail 'strict configuration parser executed shell syntax'
(
  load_config_env "$injection_file"
  [[ "$EGRESS_ID" == "\$(touch $dollar_sentinel)" ]]
  [[ "$EGRESS_CONTROL_URL" == "\`touch $backtick_sentinel\`" ]]
) || fail 'strict configuration parser did not preserve shell syntax literally'

unknown_file="$TEMP_ROOT/unknown.env"
printf '%s\n' 'EGRESS_ID=test' 'DATABASE_URL=postgres://forbidden' >"$unknown_file"
expect_failure 'unknown configuration key must be rejected' parse_config "$unknown_file"
duplicate_file="$TEMP_ROOT/duplicate.env"
printf '%s\n' 'EGRESS_ID=one' 'EGRESS_ID=two' >"$duplicate_file"
expect_failure 'duplicate configuration key must be rejected' parse_config "$duplicate_file"
nul_file="$TEMP_ROOT/nul.env"
printf 'EGRESS_ID=one\000two\n' >"$nul_file"
expect_failure 'NUL configuration byte must be rejected' parse_config "$nul_file"

expect_failure 'latest must be rejected' \
  env DRY_RUN=true "$PROJECT_ROOT/install.sh" --mode native --version latest
expect_failure 'prerelease versions outside the public contract must be rejected' \
  env DRY_RUN=true "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3-rc.1
expect_failure 'missing confirmation must fail before network' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true \
    ONE_EGRESS_TEST_ROOT="$(make_test_root missing-confirm)" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3
[[ ! -s "$EGRESS_FAKE_LOG" ]] || fail 'missing confirmation reached a fake network/runtime command'

env DRY_RUN=true ONE_EGRESS_TESTING=true \
  ONE_EGRESS_TEST_ROOT="$(make_test_root dry-run)" \
  ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=aarch64 \
  "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
  >"$TEMP_ROOT/dry-run.out"
grep -F 'linux/arm64' "$TEMP_ROOT/dry-run.out" >/dev/null ||
  fail 'arm64 platform mapping was not reported'
[[ ! -s "$EGRESS_FAKE_LOG" ]] || fail 'dry-run performed a fake network/runtime command'

expect_failure 'Darwin lifecycle must fail closed without launchd source evidence' \
  env DRY_RUN=true ONE_EGRESS_TESTING=true \
    ONE_EGRESS_TEST_ROOT="$(make_test_root darwin)" \
    ONE_EGRESS_TEST_KERNEL=Darwin ONE_EGRESS_TEST_MACHINE=arm64 \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3

native_root=$(make_test_root native)
env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$native_root" \
  ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
  "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
  --confirm install:native:1.2.3 >"$TEMP_ROOT/native.out"
[[ -x "$native_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'native binary was not atomically installed in the isolated root'
grep -Fx 'mode=native' "$native_root/opt/one-browser-egress/installation.env" >/dev/null ||
  fail 'native installation record is missing mode'
grep -Fx 'version=1.2.3' "$native_root/opt/one-browser-egress/installation.env" >/dev/null ||
  fail 'native installation record is missing version'
grep -Fx 'action_commit=89abcdef0123456789abcdef0123456789abcdef' \
  "$native_root/opt/one-browser-egress/installation.env" >/dev/null ||
  fail 'native installation record is missing the exact Action commit'
grep -F 'image_index=ghcr.io/voiceofhu/one-browser-egress-next@sha256:' \
  "$native_root/opt/one-browser-egress/installation.env" >/dev/null ||
  fail 'native installation record is missing the multiarch index digest'
[[ "$(directory_mode "$native_root/var/lib/one-browser-egress")" == 700 ]] ||
  fail 'native state directory mode must be 0700'
grep -F 'egress-v1.2.3/manifest.json' "$EGRESS_FAKE_LOG" >/dev/null ||
  fail 'installer did not use the immutable release manifest URL'
grep -F 'egress-v1.2.3/SHA256SUMS' "$EGRESS_FAKE_LOG" >/dev/null ||
  fail 'native installer did not fetch SHA256SUMS'
grep -F 'https://release-assets.githubusercontent.com/[SIGNED_QUERY_REDACTED]/' \
  "$EGRESS_FAKE_LOG" >/dev/null ||
  fail 'installer did not use the fixed GitHub release asset CDN redirect'
if grep -E '[?]|latest|browser\.example|Authorization|TOKEN' "$EGRESS_FAKE_LOG" >/dev/null; then
  fail 'installer used a forbidden query, latest, backend, or credential-bearing request'
fi

: >"$EGRESS_FAKE_LOG"
env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$native_root" \
  ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
  "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
  --confirm install:native:1.2.3 >"$TEMP_ROOT/native-repeat.out"
[[ ! -s "$EGRESS_FAKE_LOG" ]] || fail 'idempotent reinstall performed network or runtime mutation'

expect_failure 'mode switch must fail before network' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$native_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    "$PROJECT_ROOT/install.sh" --mode docker --version 1.2.3 \
    --confirm install:docker:1.2.3
[[ ! -s "$EGRESS_FAKE_LOG" ]] || fail 'mode conflict reached network or Docker'

checksum_root=$(make_test_root checksum)
expect_failure 'checksum mismatch must fail closed' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$checksum_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_BAD_CHECKSUM=true \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
    --confirm install:native:1.2.3
[[ ! -e "$checksum_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'checksum mismatch installed a native binary'

version_root=$(make_test_root version)
expect_failure 'native binary version mismatch must fail before installation' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$version_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_BINARY_VERSION=9.9.9 \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
    --confirm install:native:1.2.3
[[ ! -e "$version_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'wrong-version Native binary was installed'

other_root=$(make_test_root other-repo)
expect_failure 'same-host other repository asset must be rejected' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$other_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_MANIFEST="$FIXTURES/manifest-other-repo.json" \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
    --confirm install:native:1.2.3
[[ ! -e "$other_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'other-repository manifest installed a native binary'

extra_field_root=$(make_test_root extra-field)
expect_failure 'unknown manifest fields must be rejected' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$extra_field_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_MANIFEST="$FIXTURES/manifest-extra-field.json" \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
    --confirm install:native:1.2.3
[[ ! -e "$extra_field_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'manifest with an unknown field installed a native binary'

redirect_root=$(make_test_root redirect-host)
expect_failure 'release redirect to another HTTPS host must be rejected' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$redirect_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_REDIRECT_HOST=objects.githubusercontent.com \
    "$PROJECT_ROOT/install.sh" --mode native --version 1.2.3 \
    --confirm install:native:1.2.3
[[ ! -e "$redirect_root/opt/one-browser-egress/bin/one-browser-egress" ]] ||
  fail 'alternate HTTPS redirect host installed a native binary'

: >"$EGRESS_FAKE_LOG"
docker_root=$(make_test_root docker)
env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_root" \
  ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
  "$PROJECT_ROOT/install.sh" --mode docker --version 1.2.3 \
  --confirm install:docker:1.2.3 >"$TEMP_ROOT/docker.out"
grep -F 'image: ghcr.io/voiceofhu/one-browser-egress-next@sha256:' \
  "$docker_root/opt/one-browser-egress/compose.yml" >/dev/null ||
  fail 'Docker compose contract does not use the fixed exact digest'
grep -F 'docker pull ghcr.io/voiceofhu/one-browser-egress-next@sha256:' \
  "$EGRESS_FAKE_LOG" >/dev/null || fail 'Docker did not pull the exact digest'
[[ "$(directory_mode "$docker_root/var/lib/one-browser-egress")" == 700 ]] ||
  fail 'Docker state directory mode must be 0700'
if grep -F ':latest' "$EGRESS_FAKE_LOG" >/dev/null; then
  fail 'Docker contract used latest'
fi

docker_version_root=$(make_test_root docker-version)
expect_failure 'Docker image version mismatch must fail before Compose up' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_version_root" \
    ONE_EGRESS_TEST_KERNEL=Linux ONE_EGRESS_TEST_MACHINE=x86_64 \
    EGRESS_FAKE_BINARY_VERSION=9.9.9 \
    "$PROJECT_ROOT/install.sh" --mode docker --version 1.2.3 \
    --confirm install:docker:1.2.3
[[ ! -e "$docker_version_root/opt/one-browser-egress/compose.yml" ]] ||
  fail 'wrong-version Docker image reached Compose installation'

expect_failure 'uninstall mode conflict must fail' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_root" \
    ONE_EGRESS_TEST_KERNEL=Linux \
    "$PROJECT_ROOT/uninstall.sh" --mode native --confirm uninstall:native

touch "$docker_root/etc/systemd/system/one-browser-egress.service"
expect_failure 'mixed Native and Docker artifacts must fail even with a valid record' \
  env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_root" \
    ONE_EGRESS_TEST_KERNEL=Linux \
    "$PROJECT_ROOT/uninstall.sh" --mode docker --confirm uninstall:docker
rm -f -- "$docker_root/etc/systemd/system/one-browser-egress.service"

env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_root" \
  ONE_EGRESS_TEST_KERNEL=Linux \
  "$PROJECT_ROOT/uninstall.sh" --mode docker --confirm uninstall:docker \
  >"$TEMP_ROOT/uninstall.out"
[[ -f "$docker_root/etc/one-browser-egress/egress.env" ]] ||
  fail 'default uninstall removed operator configuration'
[[ -d "$docker_root/var/lib/one-browser-egress" ]] ||
  fail 'default uninstall removed operator state'
[[ ! -e "$docker_root/opt/one-browser-egress/installation.env" ]] ||
  fail 'default uninstall retained the runtime record'

env DRY_RUN=false ONE_EGRESS_TESTING=true ONE_EGRESS_TEST_ROOT="$docker_root" \
  ONE_EGRESS_TEST_KERNEL=Linux \
  "$PROJECT_ROOT/uninstall.sh" --mode docker --purge --confirm purge:docker \
  >"$TEMP_ROOT/purge.out"
[[ ! -e "$docker_root/etc/one-browser-egress" ]] || fail 'purge retained configuration'
[[ ! -e "$docker_root/var/lib/one-browser-egress" ]] || fail 'purge retained state'

printf '%s\n' 'PASS: Egress installer/uninstaller contract tests'

#!/usr/bin/env bash

set -Eeuo pipefail
set +x

readonly ACTION_REPOSITORY='voiceofhu/one-action'
readonly RELEASE_BASE='https://github.com/voiceofhu/one-action/releases/download'
readonly RELEASE_ASSET_REDIRECT_PATTERN='^https://release-assets\.githubusercontent\.com/[A-Za-z0-9._~/%+-]+\?[A-Za-z0-9._~%=&:+/-]+$'
readonly EGRESS_IMAGE_REPOSITORY='ghcr.io/voiceofhu/one-browser-egress-next'
readonly DRY_RUN="${DRY_RUN:-true}"
TEMP_INSTALL_DIR=

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

cleanup() {
  set +e
  case "$TEMP_INSTALL_DIR" in
    /tmp/one-browser-egress-install.*|/private/tmp/one-browser-egress-install.*|*/T/one-browser-egress-install.*)
      rm -rf -- "$TEMP_INSTALL_DIR"
      ;;
  esac
}

show_help() {
  cat <<'EOF'
Install an immutable One Browser Egress runtime.

Usage:
  DRY_RUN=true ./install.sh --mode <native|docker> --version <version>
  DRY_RUN=false ./install.sh --mode <native|docker> --version <version> \
    --confirm install:<mode>:<version>

Options:
  --mode       Runtime mode: native or docker.
  --version    Required release version without an egress-v prefix or latest.
  --confirm    Required exact confirmation when DRY_RUN=false.
  -h, --help   Show this help.

The release is read only from voiceofhu/one-action tag
egress-v<version>. Native assets require manifest.json and SHA256SUMS. Docker
requires the manifest's exact ghcr.io/voiceofhu/one-browser-egress-next digest.
No backend download proxy, PAT, caller-supplied query URL, mutable tag, or latest
lookup is used. GitHub's one asset-CDN redirect is host-allowlisted explicitly.
EOF
}

validate_boolean() {
  [[ "${1-}" == true || "${1-}" == false ]]
}

validate_mode() {
  [[ "${1-}" == native || "${1-}" == docker ]]
}

validate_version() {
  local value=${1-}
  [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

validate_sha256() {
  [[ "${#1}" -eq 64 && "$1" =~ ^[a-f0-9]+$ ]]
}

validate_source_sha() {
  [[ "${#1}" -eq 40 && "$1" =~ ^[a-f0-9]+$ ]]
}

validate_safe_name() {
  [[ -n "${1-}" && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
    [[ "$1" != '.' && "$1" != '..' ]]
}

detect_platform() {
  local kernel machine
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]]; then
    kernel=${ONE_EGRESS_TEST_KERNEL:-$(uname -s)}
    machine=${ONE_EGRESS_TEST_MACHINE:-$(uname -m)}
  else
    kernel=$(uname -s)
    machine=$(uname -m)
  fi
  case "$kernel" in
    Linux) PLATFORM=linux ;;
    Darwin) PLATFORM=darwin ;;
    *) die "unsupported Egress platform: $kernel" ;;
  esac
  case "$machine" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) die "unsupported Egress architecture: $machine" ;;
  esac
}

require_supported_lifecycle() {
  [[ "$PLATFORM" == linux ]] ||
    die "$MODE lifecycle is not supported on $PLATFORM; no verified launchd or Docker Desktop service contract exists"
  if [[ "$MODE" == native ]]; then
    command -v systemctl >/dev/null 2>&1 ||
      die 'native installation requires systemd'
  fi
}

configure_paths() {
  local prefix=
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]]; then
    prefix=${ONE_EGRESS_TEST_ROOT:-}
    case "$prefix" in
      /tmp/one-egress-test.*|/private/tmp/one-egress-test.*) ;;
      *) die 'ONE_EGRESS_TEST_ROOT must be a narrow /tmp/one-egress-test.* path' ;;
    esac
  fi
  INSTALL_DIR="$prefix/opt/one-browser-egress"
  BINARY="$INSTALL_DIR/bin/one-browser-egress"
  RECORD="$INSTALL_DIR/installation.env"
  COMPOSE_FILE="$INSTALL_DIR/compose.yml"
  CONFIG_DIR="$prefix/etc/one-browser-egress"
  CONFIG_FILE="$CONFIG_DIR/egress.env"
  STATE_DIR="$prefix/var/lib/one-browser-egress"
  SERVICE_FILE="$prefix/etc/systemd/system/one-browser-egress.service"
}

assert_managed_paths_safe() {
  local path
  for path in "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"; do
    [[ ! -L "$path" ]] || die "managed directory must not be a symlink: $path"
  done
  [[ ! -L "$SERVICE_FILE" ]] || die "service file must not be a symlink: $SERVICE_FILE"
}

read_record() {
  local key=$1
  [[ -f "$RECORD" && ! -L "$RECORD" ]] || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted { if (seen++) exit 2; sub(/^[^=]*=/, ""); value=$0 }
    END { if (seen != 1) exit 1; print value }
  ' "$RECORD"
}

detect_existing_mode() {
  local recorded
  recorded=$(read_record mode 2>/dev/null || true)
  if validate_mode "$recorded"; then
    printf '%s' "$recorded"
  elif [[ -e "$SERVICE_FILE" || -e "$BINARY" ]]; then
    printf native
  elif [[ -e "$COMPOSE_FILE" ]]; then
    printf docker
  fi
}

runtime_complete() {
  if [[ "$MODE" == native ]]; then
    [[ -f "$BINARY" && -x "$BINARY" && ! -L "$BINARY" &&
      -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]
  else
    [[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]]
  fi
}

require_real_confirmation() {
  validate_boolean "$DRY_RUN" || die 'DRY_RUN must be true or false'
  if [[ "$DRY_RUN" == false ]]; then
    [[ "$CONFIRMATION" == "install:$MODE:$VERSION" ]] ||
      die "real installation requires --confirm install:$MODE:$VERSION"
    if [[ "${ONE_EGRESS_TESTING:-false}" != true && ${EUID:-$(id -u)} -ne 0 ]]; then
      die 'real installation must run as root'
    fi
  fi
}

release_url() {
  printf '%s/egress-v%s/%s' "$RELEASE_BASE" "$VERSION" "$1"
}

download() {
  local url=$1 output=$2 max_size=$3 header_file location redirect_count status
  [[ "$url" == "$(release_url "${url##*/}")" ]] ||
    die "refusing non-Action or non-release URL: $url"
  [[ "$max_size" =~ ^[1-9][0-9]*$ && "$max_size" -le 268435456 ]] ||
    die 'download size limit is invalid'
  header_file=$(mktemp "$TEMP_INSTALL_DIR/.release-headers.XXXXXX")
  status=$(
    curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error \
      --head --max-redirs 0 --connect-timeout 10 --max-time 30 \
      --dump-header "$header_file" --output /dev/null \
      --write-out '%{http_code}' "$url"
  )
  [[ "$(wc -c <"$header_file")" -le 65536 ]] ||
    die 'release redirect headers exceed 64 KiB'
  redirect_count=$(awk 'tolower($0) ~ /^location:/ { count++ } END { print count+0 }' "$header_file")
  case "$status" in
    200)
      [[ "$redirect_count" -eq 0 ]] || die 'direct release response included an unexpected redirect'
      location=$url
      ;;
    301|302|303|307|308)
      [[ "$redirect_count" -eq 1 ]] || die 'release asset must return exactly one redirect location'
      location=$(awk '
        tolower($0) ~ /^location:/ {
          sub(/^[^:]*:[[:space:]]*/, "")
          sub(/\r$/, "")
          print
        }
      ' "$header_file")
      [[ "${#location}" -le 8192 ]] || die 'release asset redirect URL is too long'
      [[ "$location" =~ $RELEASE_ASSET_REDIRECT_PATTERN ]] ||
        die 'release asset redirect is outside the fixed GitHub asset CDN contract'
      ;;
    *) die "release asset HEAD returned unexpected HTTP status: $status" ;;
  esac
  rm -f -- "$header_file"

  status=$(
    printf 'url = "%s"\n' "$location" |
      curl -q --config - --proto '=https' --tlsv1.2 \
        --fail --silent --show-error --max-redirs 0 \
        --connect-timeout 10 --max-time 300 --max-filesize "$max_size" \
        --output "$output" --write-out '%{http_code}'
  )
  [[ "$status" == 200 ]] || die "release asset GET returned unexpected HTTP status: $status"
  [[ -s "$output" ]] || die "downloaded file is empty: ${url##*/}"
  [[ "$(wc -c <"$output")" -le "$max_size" ]] ||
    die "downloaded file exceeds its size limit: ${url##*/}"
}

load_manifest() {
  local manifest=$1
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  jq -e \
    --arg repository "$ACTION_REPOSITORY" \
    --arg image_repository "$EGRESS_IMAGE_REPOSITORY" \
    --arg release_base "$RELEASE_BASE" \
    --arg version "$VERSION" \
    --arg tag "egress-v$VERSION" '
      def exact_image_reference:
        type == "string" and
        startswith($image_repository + "@sha256:") and
        (ltrimstr($image_repository + "@sha256:") | test("^[0-9a-f]{64}$"));
      type == "object" and
      (keys | sort) ==
        (["actionCommit", "actionRepository", "artifacts", "imageIndex", "images",
          "releaseTag", "schemaVersion", "sourceCommit", "version"] | sort) and
      .schemaVersion == 1 and
      .actionRepository == $repository and
      (.actionCommit | type == "string" and test("^[0-9a-f]{40}$")) and
      .version == $version and
      .releaseTag == $tag and
      (.sourceCommit | type == "string" and test("^[0-9a-f]{40}$")) and
      (.artifacts | type == "array" and length == 2) and
      (all(.artifacts[];
        type == "object" and
        (keys | sort) == (["arch", "name", "platform", "sha256", "size", "url"] | sort) and
        .platform == "linux" and
        (.arch == "amd64" or .arch == "arm64") and
        .name == ("one-browser-egress-linux-" + .arch) and
        (.size | type == "number" and floor == . and . >= 1 and . <= 268435456) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .url == ($release_base + "/" + $tag + "/" + .name))) and
      ([.artifacts[].arch] | sort) == ["amd64", "arm64"] and
      (.imageIndex | exact_image_reference) and
      (.images | type == "array" and length == 2) and
      (all(.images[];
        type == "object" and
        (keys | sort) == ["arch", "platform", "reference"] and
        .platform == "linux" and
        (.arch == "amd64" or .arch == "arm64") and
        (.reference | exact_image_reference))) and
      ([.images[].arch] | sort) == ["amd64", "arm64"] and
      ([.images[].reference] | unique | length) == 2 and
      (.imageIndex as $index | all(.images[]; .reference != $index))
    ' "$manifest" >/dev/null || die 'release manifest identity is invalid'
  ACTION_SHA=$(jq -er '.actionCommit' "$manifest")
  SOURCE_SHA=$(jq -er '.sourceCommit' "$manifest")
  IMAGE_INDEX=$(jq -er '.imageIndex' "$manifest")
  validate_source_sha "$ACTION_SHA" || die 'release manifest actionCommit is invalid'
  validate_source_sha "$SOURCE_SHA" || die 'release manifest sourceCommit is invalid'
}

select_native_artifact() {
  local manifest=$1 count expected_name expected_url
  count=$(jq -er --arg platform "$PLATFORM" --arg arch "$ARCH" \
    '[.artifacts[] | select(.platform == $platform and .arch == $arch)] | length' "$manifest")
  [[ "$count" == 1 ]] || die "manifest must contain exactly one $PLATFORM/$ARCH native artifact"
  IFS=$'\t' read -r ASSET_NAME ASSET_SIZE ASSET_SHA ASSET_URL < <(
    jq -er --arg platform "$PLATFORM" --arg arch "$ARCH" '
      .artifacts[] | select(.platform == $platform and .arch == $arch) |
      [.name, .size, .sha256, .url] | @tsv
    ' "$manifest"
  )
  expected_name="one-browser-egress-$PLATFORM-$ARCH"
  [[ "$ASSET_NAME" == "$expected_name" ]] || die 'native artifact name is not exact'
  validate_safe_name "$ASSET_NAME" || die 'native artifact name is invalid'
  [[ "$ASSET_SIZE" =~ ^[1-9][0-9]*$ && "$ASSET_SIZE" -le 268435456 ]] ||
    die 'native artifact size is invalid'
  validate_sha256 "$ASSET_SHA" || die 'native artifact SHA-256 is invalid'
  expected_url=$(release_url "$ASSET_NAME")
  [[ "$ASSET_URL" == "$expected_url" ]] || die 'native artifact URL is not the exact Action release asset URL'
}

select_docker_image() {
  local manifest=$1 count expected_prefix digest
  count=$(jq -er --arg platform "$PLATFORM" --arg arch "$ARCH" \
    '[.images[] | select(.platform == $platform and .arch == $arch)] | length' "$manifest")
  [[ "$count" == 1 ]] || die "manifest must contain exactly one $PLATFORM/$ARCH image"
  IMAGE=$(jq -er --arg platform "$PLATFORM" --arg arch "$ARCH" \
    '.images[] | select(.platform == $platform and .arch == $arch) | .reference' "$manifest")
  expected_prefix="$EGRESS_IMAGE_REPOSITORY@sha256:"
  [[ "$IMAGE" == "$expected_prefix"* ]] || die 'Docker image is outside the fixed Egress GHCR package'
  digest=${IMAGE#"$expected_prefix"}
  validate_sha256 "$digest" || die 'Docker image must use one exact lowercase sha256 digest'
}

checksum_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die 'sha256sum or shasum is required'
  fi
}

load_config_env() {
  local file=$1 key line value
  local seen='|'
  [[ -f "$file" && ! -L "$file" ]] || die "configuration must be a regular file: $file"
  # Both commands only read the file; cmp compares it with the NUL-stripped stream.
  # shellcheck disable=SC2094
  if ! LC_ALL=C tr -d '\000' <"$file" | cmp -s "$file" -; then
    die 'configuration contains a NUL byte'
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" != *$'\r'* ]] || die 'configuration contains a carriage return'
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] ||
      die 'configuration contains an invalid line'
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    case "$key" in
      EGRESS_ID|EGRESS_BIND_ADDR|EGRESS_CONTROL_URL|EGRESS_CONTROL_TOKEN|EGRESS_HEARTBEAT_INTERVAL_SECONDS|EGRESS_SHUTDOWN_GRACE_SECONDS)
        ;;
      *) die "configuration key is not allowed: $key" ;;
    esac
    [[ "$seen" != *"|$key|"* ]] || die "configuration key is duplicated: $key"
    seen+="$key|"
    export "$key=$value"
  done <"$file"
}

validate_config_syntax() (
  load_config_env "$1"
)

run_with_config() {
  local file=$1
  shift
  (
    load_config_env "$file"
    "$@"
  )
}

verify_native_download() {
  local asset=$1 sums=$2 actual actual_size binary_version listed count
  count=$(awk -v name="$ASSET_NAME" '$2 == name { count++ } END { print count+0 }' "$sums")
  [[ "$count" == 1 ]] || die 'SHA256SUMS must contain the native asset exactly once'
  listed=$(awk -v name="$ASSET_NAME" '$2 == name { print $1 }' "$sums")
  validate_sha256 "$listed" || die 'SHA256SUMS contains an invalid native digest'
  [[ "$listed" == "$ASSET_SHA" ]] || die 'manifest and SHA256SUMS disagree'
  actual_size=$(wc -c <"$asset")
  [[ "$actual_size" -eq "$ASSET_SIZE" ]] || die 'downloaded native asset size mismatch'
  actual=$(checksum_file "$asset")
  [[ "$actual" == "$ASSET_SHA" ]] || die 'downloaded native asset SHA-256 mismatch'
  binary_version=$("$asset" version) || die 'downloaded native binary did not report a version'
  [[ "$binary_version" == "$VERSION" ]] ||
    die 'downloaded native binary version does not match the requested release'
}

ensure_native_user() {
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]] || id one-browser-egress >/dev/null 2>&1; then
    return
  fi
  command -v useradd >/dev/null 2>&1 || die 'useradd is required for native installation'
  useradd --system --user-group --home-dir /var/lib/one-browser-egress \
    --shell /usr/sbin/nologin one-browser-egress
}

make_dir() {
  local mode=$1 owner=$2 group=$3 path=$4
  if [[ "${ONE_EGRESS_TESTING:-false}" == true ]]; then
    mkdir -p "$path"
    chmod "$mode" "$path"
  else
    install -d -m "$mode" -o "$owner" -g "$group" "$path"
  fi
}

install_native() {
  local asset=$1 service_target_tmp target_tmp unit_tmp
  ensure_native_user
  make_dir 0755 root root "$INSTALL_DIR"
  make_dir 0755 root root "$INSTALL_DIR/bin"
  make_dir 0750 root one-browser-egress "$CONFIG_DIR"
  make_dir 0700 one-browser-egress one-browser-egress "$STATE_DIR"
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] ||
    die "native configuration must already exist at $CONFIG_FILE"
  validate_config_syntax "$CONFIG_FILE"
  target_tmp=$(mktemp "$INSTALL_DIR/bin/.one-browser-egress.XXXXXX")
  install -m 0755 "$asset" "$target_tmp"
  run_with_config "$CONFIG_FILE" "$target_tmp" validate-config >/dev/null ||
    die 'native configuration validation failed'
  mv -f "$target_tmp" "$BINARY"
  unit_tmp=$(mktemp "$INSTALL_DIR/.one-browser-egress.service.XXXXXX")
  cat >"$unit_tmp" <<EOF
[Unit]
Description=One Browser Egress
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=one-browser-egress
Group=one-browser-egress
EnvironmentFile=$CONFIG_FILE
ExecStart=$BINARY serve
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
  service_target_tmp=$(mktemp "$(dirname "$SERVICE_FILE")/.one-browser-egress.service.XXXXXX")
  install -m 0644 "$unit_tmp" "$service_target_tmp"
  mv -f "$service_target_tmp" "$SERVICE_FILE"
  rm -f -- "$unit_tmp"
  systemctl daemon-reload
  systemctl enable --now one-browser-egress.service
  systemctl is-active --quiet one-browser-egress.service ||
    die 'native service did not remain active'
}

install_docker() {
  local compose_tmp image_version
  command -v docker >/dev/null 2>&1 || die 'docker is required for Docker mode'
  docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'
  make_dir 0755 root root "$INSTALL_DIR"
  make_dir 0750 root root "$CONFIG_DIR"
  make_dir 0700 65532 65532 "$STATE_DIR"
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] ||
    die "Docker configuration must already exist at $CONFIG_FILE"
  validate_config_syntax "$CONFIG_FILE"
  docker pull "$IMAGE" >/dev/null
  image_version=$(
    docker run --rm --read-only --network none --cap-drop ALL \
      --security-opt no-new-privileges "$IMAGE" version
  ) || die 'Docker Egress image did not report a version'
  [[ "$image_version" == "$VERSION" ]] ||
    die 'Docker Egress image version does not match the requested release'
  docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
    --env-file "$CONFIG_FILE" "$IMAGE" validate-config >/dev/null ||
    die 'Docker configuration validation failed'
  compose_tmp=$(mktemp "$INSTALL_DIR/.compose.XXXXXX")
  cat >"$compose_tmp" <<EOF
services:
  egress:
    image: $IMAGE
    container_name: one-browser-egress
    restart: unless-stopped
    env_file:
      - $CONFIG_FILE
    volumes:
      - $STATE_DIR:/var/lib/one-browser-egress
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF
  mv -f "$compose_tmp" "$COMPOSE_FILE"
  docker compose --project-name one-browser-egress -f "$COMPOSE_FILE" up -d
  [[ "$(docker inspect --format '{{.State.Running}}' one-browser-egress)" == true ]] ||
    die 'Docker Egress did not remain running'
}

write_record() {
  local source=$1 record_tmp
  record_tmp=$(mktemp "$INSTALL_DIR/.installation.XXXXXX")
  {
    printf 'schema=1\n'
    printf 'mode=%s\n' "$MODE"
    printf 'platform=%s\n' "$PLATFORM"
    printf 'arch=%s\n' "$ARCH"
    printf 'version=%s\n' "$VERSION"
    printf 'action_commit=%s\n' "$ACTION_SHA"
    printf 'source_commit=%s\n' "$SOURCE_SHA"
    printf 'image_index=%s\n' "$IMAGE_INDEX"
    printf 'immutable_source=%s\n' "$source"
  } >"$record_tmp"
  chmod 0600 "$record_tmp"
  mv -f "$record_tmp" "$RECORD"
}

main() {
  local existing_mode installed_version manifest source temp_dir
  MODE=
  VERSION=
  CONFIRMATION=
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --mode) [[ "$#" -ge 2 ]] || die '--mode requires a value'; MODE=$2; shift 2 ;;
      --version) [[ "$#" -ge 2 ]] || die '--version requires a value'; VERSION=$2; shift 2 ;;
      --confirm) [[ "$#" -ge 2 ]] || die '--confirm requires a value'; CONFIRMATION=$2; shift 2 ;;
      -h|--help) show_help; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  validate_mode "$MODE" || die '--mode must be native or docker'
  validate_version "$VERSION" || die '--version must be an explicit version such as 26.810.1629; latest is forbidden'
  detect_platform
  configure_paths
  require_real_confirmation
  require_supported_lifecycle
  assert_managed_paths_safe
  existing_mode=$(detect_existing_mode)
  [[ -z "$existing_mode" || "$existing_mode" == "$MODE" ]] ||
    die "Egress is installed in $existing_mode mode; uninstall before switching to $MODE"
  installed_version=$(read_record version 2>/dev/null || true)
  if [[ "$installed_version" == "$VERSION" ]] && runtime_complete; then
    log "One Browser Egress $VERSION is already installed in $MODE mode"
    return 0
  fi
  manifest=$(release_url manifest.json)
  log "Plan: install $MODE Egress $VERSION for $PLATFORM/$ARCH"
  log "Manifest: $manifest"
  if [[ "$DRY_RUN" == true ]]; then
    log 'DRY_RUN=true: no network request or host mutation was performed'
    return 0
  fi
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-browser-egress-install.XXXXXX")
  TEMP_INSTALL_DIR=$temp_dir
  chmod 0700 "$temp_dir"
  trap cleanup EXIT INT TERM HUP
  download "$manifest" "$temp_dir/manifest.json" 1048576
  load_manifest "$temp_dir/manifest.json"
  if [[ "$MODE" == native ]]; then
    select_native_artifact "$temp_dir/manifest.json"
    download "$(release_url SHA256SUMS)" "$temp_dir/SHA256SUMS" 65536
    download "$ASSET_URL" "$temp_dir/$ASSET_NAME" "$ASSET_SIZE"
    verify_native_download "$temp_dir/$ASSET_NAME" "$temp_dir/SHA256SUMS"
    install_native "$temp_dir/$ASSET_NAME"
    source=$ASSET_URL
  else
    select_docker_image "$temp_dir/manifest.json"
    install_docker
    source=$IMAGE
  fi
  write_record "$source"
  log "Installed One Browser Egress $VERSION in $MODE mode from an immutable source"
}

if [[ "${ONE_EGRESS_LIBRARY_ONLY:-false}" != true ]]; then
  main "$@"
fi

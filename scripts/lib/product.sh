#!/usr/bin/env bash
# shellcheck disable=SC2034 # PRODUCT_* variables are consumed by the sourcing script.
# Loads one product from products.json into PRODUCT_* variables.
#
# Source it and call `load_product <key>`, or execute it as
# `product.sh <key>` to print the fields as GitHub output lines.
#
# Names that every product derives the same way (image, environment, remote
# directory, container, Compose service) are computed here rather than stored.

PRODUCT_MANIFEST="${PRODUCT_MANIFEST:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/products.json}"

product_die() {
  printf '%s\n' "$*" >&2
  exit 1
}

product_field() {
  jq -er --arg key "$PRODUCT_KEY" --arg field "$1" '
    .[$key][$field] |
    if type == "string" or type == "number" then tostring
    else error("missing scalar field") end
  ' "$PRODUCT_MANIFEST" 2>/dev/null || product_die "products.json: $PRODUCT_KEY.$1 must be a string or number"
}

product_list() {
  jq -r --arg key "$PRODUCT_KEY" --arg field "$1" '
    .[$key][$field] |
    if type == "array" and all(type == "string") then .[]
    else error("missing list field") end
  ' "$PRODUCT_MANIFEST" 2>/dev/null || product_die "products.json: $PRODUCT_KEY.$1 must be a list of strings"
}

product_require() {
  local value=$1 pattern=$2 label=$3
  [[ "$value" =~ $pattern ]] || product_die "products.json: $PRODUCT_KEY.$label is invalid: $value"
}

load_product() {
  local item items

  PRODUCT_KEY=${1:-}
  [[ "$PRODUCT_KEY" =~ ^[a-z][a-z0-9]*$ ]] || product_die "Invalid product key: ${PRODUCT_KEY:-<empty>}"
  command -v jq >/dev/null || product_die 'jq is required'
  [[ -f "$PRODUCT_MANIFEST" && ! -L "$PRODUCT_MANIFEST" ]] || product_die "Product manifest is missing: $PRODUCT_MANIFEST"
  jq -e --arg key "$PRODUCT_KEY" 'has($key)' "$PRODUCT_MANIFEST" >/dev/null ||
    product_die "Unknown product: $PRODUCT_KEY"

  PRODUCT_TITLE="$(product_field title)"
  PRODUCT_BACKEND_REPOSITORY="$(product_field backend_repository)"
  PRODUCT_BACKEND_PACKAGE="$(product_field backend_package)"
  PRODUCT_WEB_REPOSITORY="$(product_field web_repository)"
  PRODUCT_WEB_PACKAGE="$(product_field web_package)"
  PRODUCT_PUBLIC_URL="$(product_field public_url)"
  PRODUCT_SERVICE_PORT="$(product_field service_port)"
  PRODUCT_READY_PATH="$(product_field ready_path)"
  PRODUCT_PNPM_VERSION="$(product_field pnpm_version)"
  # Optional: only the Go backend sets it.
  PRODUCT_BACKEND_LANGUAGE="$(jq -r --arg key "$PRODUCT_KEY" '.[$key].backend_language // "rust"' "$PRODUCT_MANIFEST")"

  product_require "$PRODUCT_TITLE" '^One [A-Za-z0-9 ]+$' title
  product_require "$PRODUCT_BACKEND_REPOSITORY" '^voiceofhu/[a-z0-9-]+$' backend_repository
  product_require "$PRODUCT_WEB_REPOSITORY" '^voiceofhu/[a-z0-9-]+$' web_repository
  product_require "$PRODUCT_BACKEND_PACKAGE" '^[a-z0-9-]+$' backend_package
  product_require "$PRODUCT_WEB_PACKAGE" '^[a-z0-9-]+$' web_package
  product_require "$PRODUCT_PUBLIC_URL" '^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' public_url
  product_require "$PRODUCT_SERVICE_PORT" '^[1-9][0-9]{0,4}$' service_port
  product_require "$PRODUCT_READY_PATH" '^(/[A-Za-z0-9._-]+)+$' ready_path
  product_require "$PRODUCT_PNPM_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$' pnpm_version
  product_require "$PRODUCT_BACKEND_LANGUAGE" '^(rust|go)$' backend_language

  PRODUCT_REMOTE_REQUIRED_DIRS=()
  items="$(product_list remote_required_dirs)" || exit 1
  for item in $items; do
    product_require "$item" '^[A-Za-z0-9._-]+$' remote_required_dirs
    PRODUCT_REMOTE_REQUIRED_DIRS+=("$item")
  done

  PRODUCT_WEB_GATES=()
  items="$(product_list web_gates)" || exit 1
  for item in $items; do
    product_require "$item" '^[a-z][a-z:-]*$' web_gates
    PRODUCT_WEB_GATES+=("$item")
  done
  ((${#PRODUCT_WEB_GATES[@]} > 0)) || product_die "products.json: $PRODUCT_KEY.web_gates must not be empty"

  PRODUCT_NAME="one-$PRODUCT_KEY"
  PRODUCT_IMAGE="ghcr.io/voiceofhu/$PRODUCT_NAME"
  PRODUCT_ENVIRONMENT="$PRODUCT_NAME-prod"
  PRODUCT_REMOTE_DIR="/opt/$PRODUCT_NAME"
  PRODUCT_CONTAINER="$PRODUCT_NAME"
  PRODUCT_SERVICE="$PRODUCT_KEY"
  PRODUCT_WEB_DIST="/opt/$PRODUCT_NAME/web-dist"
  PRODUCT_DOCKERFILE='deploy/docker/Dockerfile'
  PRODUCT_COMPOSE_FILE='deploy/docker/docker-compose.yml'
  if [[ "$PRODUCT_KEY" == node ]]; then
    PRODUCT_IMAGE='ghcr.io/voiceofhu/one-node-server'
    PRODUCT_CONTAINER='one-node-server'
    PRODUCT_SERVICE=server
    PRODUCT_WEB_DIST='/app/web-dist'
    PRODUCT_DOCKERFILE=Dockerfile
    PRODUCT_COMPOSE_FILE='deploy/docker-compose.yml'
  elif [[ "$PRODUCT_KEY" == browser ]]; then
    PRODUCT_IMAGE='ghcr.io/voiceofhu/one-browser-backend'
    PRODUCT_CONTAINER='one-browser-server'
    PRODUCT_SERVICE=server
    PRODUCT_DOCKERFILE=Dockerfile
    PRODUCT_COMPOSE_FILE='deploy/docker-compose.yml'
  fi
  PRODUCT_SERVER_WORKFLOW="$PRODUCT_KEY-server.yml"
  PRODUCT_WEB_WORKFLOW="$PRODUCT_KEY-web.yml"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  load_product "${1:-}"
  printf '%s=%s\n' \
    title "$PRODUCT_TITLE" \
    name "$PRODUCT_NAME" \
    backend_repository "$PRODUCT_BACKEND_REPOSITORY" \
    web_repository "$PRODUCT_WEB_REPOSITORY" \
    public_url "$PRODUCT_PUBLIC_URL" \
    image "$PRODUCT_IMAGE" \
    dockerfile "$PRODUCT_DOCKERFILE" \
    compose_file "$PRODUCT_COMPOSE_FILE" \
    environment "$PRODUCT_ENVIRONMENT" \
    remote_dir "$PRODUCT_REMOTE_DIR" \
    pnpm_version "$PRODUCT_PNPM_VERSION" \
    backend_language "$PRODUCT_BACKEND_LANGUAGE"
fi

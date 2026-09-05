#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

[[ "$#" -ge 1 ]] || die 'usage: dispatch-workflow.sh WORKFLOW.yml KEY=VALUE ...'
workflow="$1"
shift

case "$workflow" in
  user.yml|one-browser-backend.yml|app.yml|app-debug.yml|egress.yml|one-amz.yml|node.yml|node-server.yml) ;;
  browser-runtime.yml)
    die 'Browser Runtime source repository trust root is unresolved; dispatch is blocked'
    ;;
  *) die 'workflow is outside the fixed dispatcher allowlist' ;;
esac

require_tool curl
require_tool jq
validate_api_url

action_repository="${ACTION_REPOSITORY:-}"
action_ref="${ACTION_REF:-main}"
validate_repository "$action_repository"
[[ "$action_repository" == "$FIXED_ACTION_REPOSITORY" ]] ||
  die 'ACTION_REPOSITORY must be the fixed central Action repository'
validate_ref "$action_ref"

declare -a input_keys=()
declare -a input_values=()

input_index() {
  local wanted="$1"
  local index
  for index in "${!input_keys[@]}"; do
    if [[ "${input_keys[$index]}" == "$wanted" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

input_value() {
  local index
  index="$(input_index "$1")" || return 1
  printf '%s\n' "${input_values[$index]}"
}

require_inputs() {
  local expected
  local count=0
  for expected in "$@"; do
    input_index "$expected" >/dev/null || die "required workflow input is missing: $expected"
    count=$((count + 1))
  done
  ((${#input_keys[@]} == count)) || die 'workflow inputs differ from the fixed key allowlist'
}

require_repository() {
  local key="$1"
  local expected="$2"
  local value
  value="$(input_value "$key")"
  validate_repository "$value"
  [[ "$value" == "$expected" ]] || die "$key differs from the fixed source repository"
}

validate_version() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  ((${#value} <= 32)) \
    && [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die 'version must be an unprefixed three-component numeric version'
}

for assignment in "$@"; do
  [[ "$assignment" == *=* ]] || die 'workflow input must use KEY=VALUE'
  key="${assignment%%=*}"
  value="${assignment#*=}"
  [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || die 'workflow input name is invalid'
  [[ "$key" != confirmation ]] ||
    die 'confirmation is dispatcher-owned and must not be supplied by a caller'
  [[ "$key" != expected_action_sha ]] ||
    die 'expected_action_sha is dispatcher-owned and must not be supplied by a caller'
  input_index "$key" >/dev/null && die "duplicate workflow input: $key"
  input_keys+=("$key")
  input_values+=("$value")
done

publish_supported=false
case "$workflow" in
  user.yml)
    require_inputs backend_repository backend_ref web_repository web_ref \
      version publish
    require_repository backend_repository voiceofhu/one-user-backend
    require_repository web_repository voiceofhu/one-user-web
    publish_supported=true
    ;;
  one-amz.yml)
    require_inputs backend_repository backend_ref web_repository web_ref \
      version environment publish deploy
    require_repository backend_repository voiceofhu/one-amz-backend-next
    require_repository web_repository voiceofhu/one-amz-web-next
    publish_supported=true
    ;;
  one-browser-backend.yml)
    require_inputs backend_repository backend_ref web_repository web_ref \
      version environment publish deploy
    require_repository backend_repository voiceofhu/one-browser-backend-next
    require_repository web_repository voiceofhu/one-browser-web-next
    publish_supported=true
    ;;
  node-server.yml)
    require_inputs backend_repository backend_ref web_repository web_ref \
      version publish deploy
    require_repository backend_repository voiceofhu/one-node-server
    require_repository web_repository voiceofhu/one-node-web
    publish_supported=true
    ;;
  app.yml)
    require_inputs app_repository app_ref version publish
    require_repository app_repository voiceofhu/one-browser-app
    publish_supported=true
    ;;
  app-debug.yml)
    require_inputs app_repository app_ref upload_artifact
    require_repository app_repository voiceofhu/one-browser-app
    ;;
  egress.yml)
    require_inputs egress_repository egress_ref version environment publish deploy
    require_repository egress_repository voiceofhu/one-browser-egress
    publish_supported=true
    ;;
  node.yml)
    require_inputs node_repository node_ref version
    require_repository node_repository voiceofhu/one-node-node
    publish_supported=true
    ;;
esac

for index in "${!input_keys[@]}"; do
  key="${input_keys[$index]}"
  [[ "$key" == *_ref ]] || continue
  validate_ref "${input_values[$index]}"
done

version="$(input_value version || printf '')"
validate_version "$version"
environment="$(input_value environment || printf dev)"
case "$environment" in
  dev|stage|prod) ;;
  *) die 'environment must be dev, stage, or prod' ;;
esac

publish="$(input_value publish || printf false)"
deploy="$(input_value deploy || printf false)"
upload_artifact="$(input_value upload_artifact || printf false)"
if [[ "$workflow" == node.yml ]]; then
  publish=true
fi
for value in "$publish" "$deploy" "$upload_artifact"; do
  [[ "$value" == true || "$value" == false ]] || die 'mutation inputs must be true or false'
done
if [[ "$deploy" == true && "$workflow" != node-server.yml ]]; then
  die 'deployment is implemented only for One Node Server'
fi
if [[ "$deploy" == true && "$publish" != true ]]; then
  die 'One Node Server deployment requires publication'
fi
[[ "$upload_artifact" == false ]] || die 'artifact upload is not implemented; refusing before API access'
if [[ "$publish" == true ]]; then
  [[ "$publish_supported" == true ]] || die 'workflow publication is not implemented'
  [[ -n "$version" ]] || die 'publication requires a canonical version'
  if [[ "$workflow" == egress.yml && "$environment" != prod ]]; then
    die 'Egress publication requires environment=prod'
  fi
fi

case "${DRY_RUN:-true}" in
  true|1|yes) dry_run=true ;;
  false|0|no) dry_run=false ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

normalize_github_token
action_sha="$(GH_TOKEN="$GH_TOKEN" \
  bash "$SCRIPT_DIR/resolve-ref.sh" "$action_repository" "$action_ref")"

for index in "${!input_keys[@]}"; do
  key="${input_keys[$index]}"
  [[ "$key" == *_ref ]] || continue
  prefix="${key%_ref}"
  repository_key="${prefix}_repository"
  repository="$(input_value "$repository_key")"
  source_ref="${input_values[$index]}"
  input_values[$index]="$(GH_TOKEN="$GH_TOKEN" \
    bash "$SCRIPT_DIR/resolve-ref.sh" "$repository" "$source_ref")"
done

dispatch_confirmation="dispatch:$workflow:$action_sha"
mutation_confirmation="mutate:$workflow:$action_sha"
if [[ "$dry_run" == false ]]; then
  [[ "${CONFIRM_DISPATCH:-}" == "$dispatch_confirmation" ]] ||
    die "real dispatch requires CONFIRM_DISPATCH=$dispatch_confirmation"
  if [[ "$publish" == true ]]; then
    [[ "${CONFIRM_MUTATION:-}" == "$mutation_confirmation" ]] ||
      die "publication requires CONFIRM_MUTATION=$mutation_confirmation"
  elif [[ -n "${CONFIRM_MUTATION:-}" ]]; then
    die 'non-mutating dispatch rejects CONFIRM_MUTATION'
  fi
fi

payload="$(jq -cn \
  --arg ref "$action_ref" \
  --arg expected_action_sha "$action_sha" \
  '{ref: $ref, inputs: {expected_action_sha: $expected_action_sha}}')"
for index in "${!input_keys[@]}"; do
  key="${input_keys[$index]}"
  value="${input_values[$index]}"
  if [[ "$key" == publish || "$key" == deploy || "$key" == upload_artifact ]]; then
    payload="$(jq -c --arg key "$key" --argjson value "$value" \
      '.inputs[$key] = $value' <<<"$payload")"
  else
    payload="$(jq -c --arg key "$key" --arg value "$value" \
      '.inputs[$key] = $value' <<<"$payload")"
  fi
done
if [[ "$publish" == true ]]; then
  if [[ "$workflow" == user.yml ]]; then
    workflow_base=one-user
  elif [[ "$workflow" == node-server.yml ]]; then
    workflow_base=one-node-server
  else
    workflow_base="${workflow%.yml}"
  fi
  payload="$(jq -c \
    --arg confirmation "enable:$workflow_base:$action_sha" \
    '.inputs.confirmation = $confirmation' <<<"$payload")"
fi

payload_size="${#payload}"
((payload_size > 0 && payload_size <= MAX_DISPATCH_BODY_BYTES)) ||
  die 'dispatch payload exceeds the fixed size limit'

printf 'Workflow: %s@%s -> %s\n' "$action_repository" "$action_ref" "$action_sha"
printf 'File: %s\n' "$workflow"
jq . <<<"$payload"
printf 'Real dispatch confirmation: %s\n' "$dispatch_confirmation"
if [[ "$publish" == true ]]; then
  printf 'Publication confirmation: %s\n' "$mutation_confirmation"
fi

if [[ "$dry_run" == true ]]; then
  unset GH_TOKEN
  printf '%s\n' 'DRY_RUN=true: no workflow was dispatched.'
  exit 0
fi

payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT
printf '%s' "$payload" >"$payload_file"
github_post "repos/$action_repository/actions/workflows/$workflow/dispatches" \
  "$payload_file" "$response_file"
unset GH_TOKEN
printf 'Dispatched %s at exact Action SHA %s.\n' "$workflow" "$action_sha"

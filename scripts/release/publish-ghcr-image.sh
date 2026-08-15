#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'GHCR publication blocked: %s\n' "$1" >&2
  exit 1
}

require_value() {
  [[ -n "${!1:-}" ]] || die "$1 is required"
}

valid_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

valid_repository() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$ ]]
}

for name in \
  WORKFLOW_NAME PUBLISH_IMAGE LOCAL_IMAGE ACTION_REPOSITORY ACTION_SHA VERSION DEPLOYMENT_ENVIRONMENT \
  GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_ACTOR GITHUB_TOKEN RUN_URL \
  PUBLISHED_IMAGE_PATH; do
  require_value "$name"
done

valid_sha "$ACTION_SHA" || die 'ACTION_SHA must be an exact commit SHA'
[[ "$ACTION_REPOSITORY" == voiceofhu/one-action ]] ||
  die 'ACTION_REPOSITORY must be the fixed central Action repository'
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'VERSION must be three numeric components without a v prefix'
((${#VERSION} <= 32)) || die 'VERSION must not exceed 32 characters'
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] ||
  die 'GitHub run identity is invalid'
[[ "$GITHUB_ACTOR" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die 'GitHub actor is invalid'
[[ "$GITHUB_TOKEN" =~ ^[A-Za-z0-9_.~-]{20,4096}$ ]] || die 'GitHub token shape is invalid'
[[ "$RUN_URL" == "https://github.com/$ACTION_REPOSITORY/actions/runs/$GITHUB_RUN_ID" ]] ||
  die 'RUN_URL is not bound to the fixed Action repository and run ID'
case "$DEPLOYMENT_ENVIRONMENT" in
  dev|stage|prod) ;;
  *) die 'DEPLOYMENT_ENVIRONMENT must be dev, stage, or prod' ;;
esac

source_kind=''
case "$WORKFLOW_NAME:$PUBLISH_IMAGE" in
  one-user:ghcr.io/voiceofhu/one-user)
    source_kind=combined
    expected_backend_repository=voiceofhu/one-user-backend
    expected_web_repository=voiceofhu/one-user-web
    ;;
  one-amz:ghcr.io/voiceofhu/one-amz-backend-next)
    source_kind=combined
    expected_backend_repository=voiceofhu/one-amz-backend-next
    expected_web_repository=voiceofhu/one-amz-web-next
    ;;
  one-browser-backend:ghcr.io/voiceofhu/one-browser-backend-next)
    source_kind=backend
    expected_source_repository=voiceofhu/one-browser-backend-next
    ;;
  *)
    die 'workflow/image pair is not a fixed publication trust anchor'
    ;;
esac

if [[ "$source_kind" == combined ]]; then
  for name in BACKEND_REPOSITORY BACKEND_SHA WEB_REPOSITORY WEB_SHA; do
    require_value "$name"
  done
  valid_repository "$BACKEND_REPOSITORY" && valid_repository "$WEB_REPOSITORY" ||
    die 'combined source repository is invalid'
  [[ "$BACKEND_REPOSITORY" == "$expected_backend_repository" \
    && "$WEB_REPOSITORY" == "$expected_web_repository" ]] ||
    die 'combined sources do not match the fixed product repositories'
  valid_sha "$BACKEND_SHA" && valid_sha "$WEB_SHA" ||
    die 'combined source SHA is invalid'
  if [[ "$WORKFLOW_NAME" == one-user ]]; then
    expected_tag="$VERSION"
  else
    expected_tag="run-a${ACTION_SHA:0:12}-b${BACKEND_SHA:0:12}-w${WEB_SHA:0:12}-r${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}"
  fi
else
  for name in SOURCE_REPOSITORY SOURCE_SHA; do
    require_value "$name"
  done
  valid_repository "$SOURCE_REPOSITORY" || die 'backend source repository is invalid'
  [[ "$SOURCE_REPOSITORY" == "$expected_source_repository" ]] ||
    die 'backend source does not match the fixed product repository'
  valid_sha "$SOURCE_SHA" || die 'backend source SHA is invalid'
  expected_tag="run-a${ACTION_SHA:0:12}-s${SOURCE_SHA:0:12}-r${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}"
fi

[[ "${PUBLISH_TAG:-}" == "$expected_tag" ]] || die 'PUBLISH_TAG does not match the publication version policy'
[[ "$PUBLISH_TAG" != latest && "$PUBLISH_TAG" != dev && "$PUBLISH_TAG" != stage && "$PUBLISH_TAG" != prod ]] ||
  die 'mutable image aliases are forbidden'
[[ "$LOCAL_IMAGE" =~ ^local/[a-z0-9][a-z0-9._-]{0,127}:[A-Za-z0-9._-]{1,128}$ ]] ||
  die 'LOCAL_IMAGE is invalid'
[[ "$PUBLISHED_IMAGE_PATH" == publication/published-image.json ]] ||
  die 'published image record path is fixed'

image_user="$(docker image inspect --format '{{.Config.User}}' "$LOCAL_IMAGE")"
image_principal="${image_user%%:*}"
if [[ -z "$image_user" || "${image_principal,,}" == root || "$image_principal" =~ ^0+$ ]]; then
  die 'final image Config.User must be non-empty and non-root'
fi

image_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$LOCAL_IMAGE")"
image_action_sha="$(docker image inspect --format '{{index .Config.Labels "one.action.revision"}}' "$LOCAL_IMAGE")"
image_action_repository="$(docker image inspect --format '{{index .Config.Labels "one.action.repository"}}' "$LOCAL_IMAGE")"
image_environment="$(docker image inspect --format '{{index .Config.Labels "one.environment"}}' "$LOCAL_IMAGE")"
image_source="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$LOCAL_IMAGE")"
image_source_sha="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$LOCAL_IMAGE")"
[[ "$image_version" == "$VERSION" \
  && "$image_action_sha" == "$ACTION_SHA" \
  && "$image_action_repository" == "$ACTION_REPOSITORY" \
  && "$image_environment" == "$DEPLOYMENT_ENVIRONMENT" ]] ||
  die 'local image version, Action identity, or environment label is not bound to the publication inputs'
if [[ "$source_kind" == combined ]]; then
  image_web_sha="$(docker image inspect --format '{{index .Config.Labels "one.web.revision"}}' "$LOCAL_IMAGE")"
  [[ "$image_source" == "https://github.com/$BACKEND_REPOSITORY" \
    && "$image_source_sha" == "$BACKEND_SHA" \
    && "$image_web_sha" == "$WEB_SHA" ]] ||
    die 'local combined image labels are not bound to the exact backend and Web sources'
else
  [[ "$image_source" == "https://github.com/$SOURCE_REPOSITORY" \
    && "$image_source_sha" == "$SOURCE_SHA" ]] ||
    die 'local backend image labels are not bound to the exact source'
fi

remote_ref="$PUBLISH_IMAGE:$PUBLISH_TAG"
docker image tag "$LOCAL_IMAGE" "$remote_ref"

docker_config="$(mktemp -d)"
push_output="$(mktemp)"
manifest_verify="$(mktemp)"
registry_headers="$(mktemp)"
logged_in=false
cleanup() {
  if [[ "$logged_in" == true ]]; then
    DOCKER_CONFIG="$docker_config" docker logout ghcr.io >/dev/null 2>&1 || true
  fi
  rm -rf -- "$docker_config"
  rm -f -- "$push_output" "$manifest_verify" "$registry_headers"
}
trap cleanup EXIT

registry_path="${PUBLISH_IMAGE#ghcr.io/}"
registry_token="$(
  {
    printf '%s\n' 'silent' 'show-error' 'fail'
    printf '%s\n' 'connect-timeout = 10' 'max-time = 30' 'max-filesize = 32768'
    printf 'url = "https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull,push"\n' "$registry_path"
    printf 'user = "%s:%s"\n' "$GITHUB_ACTOR" "$GITHUB_TOKEN"
  } | curl --config - |
    jq -er '(.token // .access_token) | select(type == "string")'
)" || die 'could not acquire a bounded GHCR manifest read token'
[[ "$registry_token" =~ ^[A-Za-z0-9._~+/=-]{20,4096}$ ]] ||
  die 'GHCR manifest read token shape is invalid'

registry_manifest_status() {
  local tag="$1"
  local status
  : >"$registry_headers"
  status="$(
    {
      printf '%s\n' 'silent' 'show-error' 'head'
      printf '%s\n' 'connect-timeout = 10' 'max-time = 30'
      printf 'url = "https://ghcr.io/v2/%s/manifests/%s"\n' "$registry_path" "$tag"
      printf 'header = "Authorization: Bearer %s"\n' "$registry_token"
      printf '%s\n' 'header = "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"'
      printf 'dump-header = "%s"\n' "$registry_headers"
      printf '%s\n' 'output = "/dev/null"' 'write-out = "%{http_code}"'
    } | curl --config -
  )" || die 'GHCR manifest HEAD failed before a trustworthy status was returned'
  [[ "$status" =~ ^[0-9]{3}$ ]] || die 'GHCR manifest HEAD returned an invalid status'
  printf '%s' "$status"
}

export DOCKER_CONFIG="$docker_config"
printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin >/dev/null
unset GITHUB_TOKEN
logged_in=true

preflight_status="$(registry_manifest_status "$PUBLISH_TAG")"
case "$preflight_status" in
  404) ;;
  200) die 'unique run tag already exists and will not be overwritten' ;;
  *) die "could not prove the unique run tag is absent; registry returned HTTP $preflight_status" ;;
esac

docker image push "$remote_ref" 2>&1 | tee "$push_output"
mapfile -t pushed_digests < <(
  LC_ALL=C sed -nE \
    -e "s/^${PUBLISH_TAG}: digest: (sha256:[0-9a-f]{64}) size: [1-9][0-9]*$/\\1/p" \
    -e 's/^digest: (sha256:[0-9a-f]{64}) size: [1-9][0-9]*$/\1/p' \
    "$push_output"
)
if ((${#pushed_digests[@]} != 1)); then
  die 'registry push did not return exactly one canonical digest line'
fi
digest="${pushed_digests[0]}"
docker buildx imagetools inspect "$PUBLISH_IMAGE@$digest" --raw >"$manifest_verify"
manifest_size="$(wc -c <"$manifest_verify")"
manifest_size="${manifest_size//[[:space:]]/}"
[[ "$manifest_size" =~ ^[1-9][0-9]*$ ]] || die 'digest-qualified registry readback was empty'
((manifest_size <= 8 * 1024 * 1024)) || die 'registry manifest exceeds the fixed size limit'

readback_status="$(registry_manifest_status "$PUBLISH_TAG")"
[[ "$readback_status" == 200 ]] ||
  die "published run tag readback returned HTTP $readback_status"
mapfile -t readback_digests < <(
  LC_ALL=C sed -nE 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*(sha256:[0-9a-f]{64})\r?$/\1/p' \
    "$registry_headers"
)
if ((${#readback_digests[@]} != 1)) || [[ "${readback_digests[0]}" != "$digest" ]]; then
  die 'published run tag does not resolve to the registry digest returned by push'
fi
unset registry_token

mkdir -p -- "$(dirname -- "$PUBLISHED_IMAGE_PATH")"
image_ref="$PUBLISH_IMAGE@$digest"
if [[ "$WORKFLOW_NAME" == one-user ]]; then
  image_ref="$PUBLISH_IMAGE:$PUBLISH_TAG"
fi
if [[ "$source_kind" == combined ]]; then
  jq -n \
    --arg action_sha "$ACTION_SHA" \
    --arg action_repository "$ACTION_REPOSITORY" \
    --arg backend_repository "$BACKEND_REPOSITORY" \
    --arg backend_sha "$BACKEND_SHA" \
    --arg web_repository "$WEB_REPOSITORY" \
    --arg web_sha "$WEB_SHA" \
    --arg version "$VERSION" \
    --arg environment "$DEPLOYMENT_ENVIRONMENT" \
    --arg image "$PUBLISH_IMAGE" \
    --arg image_ref "$image_ref" \
    --arg tag "$PUBLISH_TAG" \
    --arg digest "$digest" \
    --arg run_url "$RUN_URL" \
    '{
      schema_version: 1,
      published: true,
      action_repository: $action_repository,
      action_sha: $action_sha,
      sources: {
        backend: {repository: $backend_repository, sha: $backend_sha},
        web: {repository: $web_repository, sha: $web_sha}
      },
      version: $version,
      environment: $environment,
      run_url: $run_url,
      image: {
        name: $image,
        tag: $tag,
        digest: $digest,
        reference: $image_ref
      },
      deployment: {performed: false}
    }' >"$PUBLISHED_IMAGE_PATH"
else
  jq -n \
    --arg action_sha "$ACTION_SHA" \
    --arg action_repository "$ACTION_REPOSITORY" \
    --arg source_repository "$SOURCE_REPOSITORY" \
    --arg source_sha "$SOURCE_SHA" \
    --arg version "$VERSION" \
    --arg environment "$DEPLOYMENT_ENVIRONMENT" \
    --arg image "$PUBLISH_IMAGE" \
    --arg image_ref "$image_ref" \
    --arg tag "$PUBLISH_TAG" \
    --arg digest "$digest" \
    --arg run_url "$RUN_URL" \
    '{
      schema_version: 1,
      published: true,
      action_repository: $action_repository,
      action_sha: $action_sha,
      sources: {backend: {repository: $source_repository, sha: $source_sha}},
      version: $version,
      environment: $environment,
      run_url: $run_url,
      image: {
        name: $image,
        tag: $tag,
        digest: $digest,
        reference: $image_ref
      },
      deployment: {performed: false}
    }' >"$PUBLISHED_IMAGE_PATH"
fi

jq -e \
  '.published == true and
   .action_repository == "voiceofhu/one-action" and
   (.action_sha | test("^[0-9a-f]{40}$")) and
   (.image.digest | test("^sha256:[0-9a-f]{64}$")) and
   .deployment.performed == false' \
  "$PUBLISHED_IMAGE_PATH" >/dev/null

{
  echo "## GHCR image published"
  echo
  echo "- Image: \`$PUBLISH_IMAGE\`"
  echo "- Action: \`$ACTION_REPOSITORY@$ACTION_SHA\`"
  echo "- Published tag: \`$PUBLISH_TAG\`"
  echo "- Published reference: \`$image_ref\`"
  echo "- Version label: \`$VERSION\`"
  echo "- Final Config.User: \`$image_user\`"
  echo "- Published: \`true\`"
  echo "- Deploy: not run"
  echo
  echo '<details><summary>published-image.json</summary>'
  echo
  echo '```json'
  cat "$PUBLISHED_IMAGE_PATH"
  echo '```'
  echo '</details>'
} >>"$GITHUB_STEP_SUMMARY"

{
  echo "digest=$digest"
  echo "image=$PUBLISH_IMAGE"
  echo "image_ref=$image_ref"
  echo "tag=$PUBLISH_TAG"
} >>"$GITHUB_OUTPUT"

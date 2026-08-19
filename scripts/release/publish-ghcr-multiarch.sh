#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'GHCR multi-platform publication blocked: %s\n' "$1" >&2
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
  WORKFLOW_NAME PUBLISH_IMAGE PUBLISH_TAG ACTION_REPOSITORY ACTION_SHA \
  BACKEND_REPOSITORY BACKEND_SHA WEB_REPOSITORY WEB_SHA VERSION \
  DEPLOYMENT_ENVIRONMENT GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_ACTOR \
  GITHUB_TOKEN RUN_URL PUBLISHED_IMAGE_PATH; do
  require_value "$name"
done

valid_sha "$ACTION_SHA" || die 'ACTION_SHA must be an exact commit SHA'
valid_sha "$BACKEND_SHA" || die 'BACKEND_SHA must be an exact commit SHA'
valid_sha "$WEB_SHA" || die 'WEB_SHA must be an exact commit SHA'
valid_repository "$BACKEND_REPOSITORY" || die 'BACKEND_REPOSITORY is invalid'
valid_repository "$WEB_REPOSITORY" || die 'WEB_REPOSITORY is invalid'
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
[[ "$PUBLISHED_IMAGE_PATH" == publication/published-image.json ]] ||
  die 'published image record path is fixed'
case "$DEPLOYMENT_ENVIRONMENT" in
  dev | stage | prod) ;;
  *) die 'DEPLOYMENT_ENVIRONMENT must be dev, stage, or prod' ;;
esac

case "$WORKFLOW_NAME:$PUBLISH_IMAGE" in
  one-user:ghcr.io/voiceofhu/one-user)
    expected_backend_repository=voiceofhu/one-user-backend
    expected_web_repository=voiceofhu/one-user-web
    expected_tag="$VERSION"
    ;;
  one-node-server:ghcr.io/voiceofhu/node-server)
    expected_backend_repository=voiceofhu/one-node-server
    expected_web_repository=voiceofhu/one-node-web
    expected_tag="$VERSION"
    ;;
  one-amz:ghcr.io/voiceofhu/one-amz-backend-next)
    expected_backend_repository=voiceofhu/one-amz-backend-next
    expected_web_repository=voiceofhu/one-amz-web-next
    expected_tag="run-a${ACTION_SHA:0:12}-b${BACKEND_SHA:0:12}-w${WEB_SHA:0:12}-r${GITHUB_RUN_ID}-a${GITHUB_RUN_ATTEMPT}"
    ;;
  *) die 'workflow/image pair is not a fixed combined publication trust anchor' ;;
esac
[[ "$BACKEND_REPOSITORY" == "$expected_backend_repository" &&
  "$WEB_REPOSITORY" == "$expected_web_repository" ]] ||
  die 'combined sources do not match the fixed product repositories'

[[ "$PUBLISH_TAG" == "$expected_tag" ]] || die 'PUBLISH_TAG does not match the publication version policy'
[[ "$PUBLISH_TAG" != latest && "$PUBLISH_TAG" != dev && "$PUBLISH_TAG" != stage && "$PUBLISH_TAG" != prod ]] ||
  die 'mutable image aliases are forbidden'

registry_path="${PUBLISH_IMAGE#ghcr.io/}"
[[ "$registry_path" != "$PUBLISH_IMAGE" ]] || die 'PUBLISH_IMAGE must use ghcr.io'
final_ref="$PUBLISH_IMAGE:$PUBLISH_TAG"

manifest_raw="$(mktemp)"
manifest_formatted="$(mktemp)"
registry_headers="$(mktemp)"
cleanup() {
  rm -f -- "$manifest_raw" "$manifest_formatted" "$registry_headers"
}
trap cleanup EXIT

registry_token="$({
  printf '%s\n' 'silent' 'show-error' 'fail'
  printf '%s\n' 'connect-timeout = 10' 'max-time = 30' 'max-filesize = 32768'
  printf 'url = "https://ghcr.io/token?service=ghcr.io&scope=repository:%s:pull,push"\n' "$registry_path"
  printf 'user = "%s:%s"\n' "$GITHUB_ACTOR" "$GITHUB_TOKEN"
} | curl --config - | jq -er '(.token // .access_token) | select(type == "string")')" ||
  die 'could not acquire a bounded GHCR manifest token'
[[ "$registry_token" =~ ^[A-Za-z0-9._~+/=-]{20,4096}$ ]] ||
  die 'GHCR manifest token shape is invalid'
unset GITHUB_TOKEN

registry_manifest_status() {
  local tag="$1"
  local status
  : >"$registry_headers"
  status="$({
    printf '%s\n' 'silent' 'show-error' 'head'
    printf '%s\n' 'connect-timeout = 10' 'max-time = 30'
    printf 'url = "https://ghcr.io/v2/%s/manifests/%s"\n' "$registry_path" "$tag"
    printf 'header = "Authorization: Bearer %s"\n' "$registry_token"
    printf '%s\n' \
      'header = "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"'
    printf 'dump-header = "%s"\n' "$registry_headers"
    printf '%s\n' 'output = "/dev/null"' 'write-out = "%{http_code}"'
  } | curl --config -)" || die 'GHCR manifest HEAD failed before a trustworthy status was returned'
  [[ "$status" =~ ^[0-9]{3}$ ]] || die 'GHCR manifest HEAD returned an invalid status'
  printf '%s' "$status"
}

registry_manifest_digest() {
  local -a digests
  mapfile -t digests < <(
    LC_ALL=C sed -nE \
      's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*(sha256:[0-9a-f]{64})\r?$/\1/p' \
      "$registry_headers"
  )
  ((${#digests[@]} == 1)) || die 'GHCR response did not return exactly one manifest digest'
  printf '%s' "${digests[0]}"
}

preflight_status="$(registry_manifest_status "$PUBLISH_TAG")"
case "$preflight_status" in
  404) ;;
  200) die 'multi-platform publication tag already exists and will not be overwritten' ;;
  *) die "could not prove the multi-platform publication tag is absent; registry returned HTTP $preflight_status" ;;
esac

amd64_status="$(registry_manifest_status "$PUBLISH_TAG-amd64")"
[[ "$amd64_status" == 200 ]] || die "amd64 image tag returned HTTP $amd64_status"
amd64_digest="$(registry_manifest_digest)"
arm64_status="$(registry_manifest_status "$PUBLISH_TAG-arm64")"
[[ "$arm64_status" == 200 ]] || die "arm64 image tag returned HTTP $arm64_status"
arm64_digest="$(registry_manifest_digest)"
[[ "$amd64_digest" != "$arm64_digest" ]] || die 'architecture image tags unexpectedly resolve to the same digest'

docker buildx imagetools create \
  --annotation "index:org.opencontainers.image.source=https://github.com/$BACKEND_REPOSITORY" \
  --annotation "index:org.opencontainers.image.revision=$BACKEND_SHA" \
  --annotation "index:org.opencontainers.image.version=$VERSION" \
  --annotation "index:one.action.revision=$ACTION_SHA" \
  --annotation "index:one.web.revision=$WEB_SHA" \
  --tag "$final_ref" \
  "$PUBLISH_IMAGE@$amd64_digest" \
  "$PUBLISH_IMAGE@$arm64_digest"

published_status="$(registry_manifest_status "$PUBLISH_TAG")"
[[ "$published_status" == 200 ]] || die "published multi-platform tag returned HTTP $published_status"
digest="$(registry_manifest_digest)"
[[ "$digest" != "$amd64_digest" && "$digest" != "$arm64_digest" ]] ||
  die 'multi-platform OCI index digest unexpectedly matches a child image digest'
image_ref="$PUBLISH_IMAGE:$PUBLISH_TAG@$digest"

docker buildx imagetools inspect "$image_ref" --raw >"$manifest_raw"
manifest_size="$(wc -c <"$manifest_raw")"
manifest_size="${manifest_size//[[:space:]]/}"
[[ "$manifest_size" =~ ^[1-9][0-9]*$ ]] || die 'published OCI index readback was empty'
((manifest_size <= 8 * 1024 * 1024)) || die 'published OCI index exceeds the fixed size limit'

jq -e \
  --arg amd64_digest "$amd64_digest" \
  --arg arm64_digest "$arm64_digest" '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.index.v1+json" and
    (.manifests | type == "array" and length == 2) and
    ([.manifests[].platform | [.os, .architecture]] | sort) ==
      [["linux", "amd64"], ["linux", "arm64"]] and
    ([.manifests[].digest] | sort) == ([$amd64_digest, $arm64_digest] | sort) and
    all(.manifests[];
      (.digest | test("^sha256:[0-9a-f]{64}$")) and
      (.size | type == "number" and . > 0)
    )
  ' "$manifest_raw" >/dev/null ||
  die 'published OCI index must contain exactly linux/amd64 and linux/arm64'

docker buildx imagetools inspect "$image_ref" --format '{{json .Manifest}}' >"$manifest_formatted"
jq -e \
  --arg digest "$digest" '
    .digest == $digest and
    .mediaType == "application/vnd.oci.image.index.v1+json" and
    (.size | type == "number" and . > 0)
  ' "$manifest_formatted" >/dev/null ||
  die 'published OCI index descriptor does not match the immutable registry digest'

readback_status="$(registry_manifest_status "$PUBLISH_TAG")"
[[ "$readback_status" == 200 ]] || die "published multi-platform tag returned HTTP $readback_status"
readback_digest="$(registry_manifest_digest)"
[[ "$readback_digest" == "$digest" ]] ||
  die 'published multi-platform tag does not resolve to the OCI index digest'
unset registry_token

mkdir -p -- "$(dirname -- "$PUBLISHED_IMAGE_PATH")"
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
  --arg amd64_digest "$amd64_digest" \
  --arg arm64_digest "$arm64_digest" \
  --arg run_url "$RUN_URL" '
    {
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
        reference: $image_ref,
        platforms: [
          {os: "linux", architecture: "amd64", digest: $amd64_digest},
          {os: "linux", architecture: "arm64", digest: $arm64_digest}
        ]
      },
      deployment: {performed: false}
    }
  ' >"$PUBLISHED_IMAGE_PATH"

jq -e '
  .published == true and
  .action_repository == "voiceofhu/one-action" and
  (.action_sha | test("^[0-9a-f]{40}$")) and
  (.image.digest | test("^sha256:[0-9a-f]{64}$")) and
  .image.reference == (.image.name + ":" + .image.tag + "@" + .image.digest) and
  ([.image.platforms[].architecture] | sort) == ["amd64", "arm64"] and
  .deployment.performed == false
' "$PUBLISHED_IMAGE_PATH" >/dev/null

{
  echo "## GHCR multi-platform image published"
  echo
  echo "- Image: \`$PUBLISH_IMAGE\`"
  echo "- Action: \`$ACTION_REPOSITORY@$ACTION_SHA\`"
  echo "- Version tag: \`$PUBLISH_TAG\`"
  echo "- linux/amd64: \`$amd64_digest\`"
  echo "- linux/arm64: \`$arm64_digest\`"
  echo "- Server-aligned reference: \`$image_ref\`"
  echo "- Version label: \`$VERSION\`"
  echo "- Deploy: not run"
} >>"$GITHUB_STEP_SUMMARY"

{
  echo "digest=$digest"
  echo "image=$PUBLISH_IMAGE"
  echo "image_ref=$image_ref"
  echo "tag=$PUBLISH_TAG"
} >>"$GITHUB_OUTPUT"

#!/usr/bin/env bash
# Triggers a One Action workflow without any GitHub API token: pushes the
# annotated tag deploy/<workflow>/<version> at the published Action commit over
# the normal Git remote. The tag message pins the exact source commits
# (`<name>_ref=<sha>` lines) that scripts/github/read-trigger.sh reads in CI.
#
#   trigger.sh WORKFLOW.yml ACTION_SHA VERSION KEY_ref=SHA...
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -ge 4 ]] || die 'usage: trigger.sh WORKFLOW.yml ACTION_SHA VERSION KEY_ref=SHA...'
workflow=$1
action_sha=$2
version=$3
shift 3

[[ "$workflow" =~ ^([a-z][a-z0-9]*-(server|web|app|runtime|egress))\.yml$ ]] ||
  die "workflow is outside the release naming contract: $workflow"
name=${BASH_REMATCH[1]}
workflow_file="$PROJECT_ROOT/.github/workflows/$workflow"
[[ -f "$workflow_file" ]] || die "workflow does not exist: $workflow"
grep -Fq "\"deploy/$name/*\"" "$workflow_file" ||
  die "$workflow does not listen for deploy/$name/* tags"
[[ "$action_sha" =~ ^[0-9a-f]{40}$ ]] || die 'ACTION_SHA must be an exact commit SHA'
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'version must be an unprefixed three-component numeric version'

message=
for assignment in "$@"; do
  [[ "$assignment" =~ ^([a-z][a-z0-9]*_ref)=([0-9a-f]{40})$ ]] ||
    die "source pins must be KEY_ref=<40-hex SHA>, got: $assignment"
  [[ "$message" != *"${BASH_REMATCH[1]}="* ]] || die "duplicate source pin: ${BASH_REMATCH[1]}"
  message+="$assignment"$'\n'
done

tag="deploy/$name/$version"
printf 'Trigger: push tag %s at Action %s\n%s' "$tag" "$action_sha" "$message"

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: no tag was created or pushed.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

git -C "$PROJECT_ROOT" tag -a "$tag" -F - "$action_sha" <<<"${message%$'\n'}" ||
  die "could not create tag $tag (already released this version?)"
if ! git -C "$PROJECT_ROOT" push origin "refs/tags/$tag"; then
  git -C "$PROJECT_ROOT" tag -d "$tag" >/dev/null
  die "could not push tag $tag; the workflow was not triggered"
fi
printf 'Triggered %s: https://github.com/voiceofhu/one-action/actions/workflows/%s\n' \
  "$tag" "$workflow"

# shellcheck shell=bash
# Release-source checks shared by release-app.sh and release-android.sh. The
# sourcing script provides die() and sources scripts/lib/git-remote.sh.

# Sets checkout_sha to the HEAD of DIR once it is the clean root checkout of
# REPOSITORY, on BRANCH and already pushed to origin.
verify_checkout() {
  local label=$1 dir=$2 repository=$3 branch=$4 branch_variable=$5 missing_hint=$6 root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
    die "$label Git repository is unavailable or incomplete: $dir; $missing_hint"
  [[ "$(cd "$dir" && pwd -P)" == "$(cd "$root" && pwd -P)" ]] ||
    die "$label directory must be the $label repository root: $dir"
  checkout_sha="$(git -C "$dir" rev-parse --verify HEAD)"
  [[ "$checkout_sha" == "$(git -C "$dir" rev-parse --verify "${branch}^{commit}")" ]] ||
    die "$label HEAD must match $branch_variable ($branch) before validation"
  is_github_remote "$(origin_remote_url "$dir")" "$repository" ||
    die "$label origin differs from the configured source repository"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=all)" ]] ||
    die "$label worktree must be clean before release validation"
  git -C "$dir" fetch --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$dir" merge-base --is-ancestor "$checkout_sha" "refs/remotes/origin/$branch" ||
    die "$label HEAD is not pushed to origin/$branch"
}

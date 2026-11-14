#!/usr/bin/env bash
# Deploy targets publish by default, but DRY_RUN=true must be honoured whether it
# comes from the command line or the environment. A target-specific
# `DRY_RUN = false` once silently ignored `DRY_RUN=true make deploy-x` and
# published for real.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Prints the DRY_RUN value the recipe would pass, without running it.
resolved() {
  make -C "$PROJECT_ROOT" -n "$@" 2>/dev/null |
    grep -o 'DRY_RUN="[a-z]*"' | head -n 1 | cut -d'"' -f2
}

targets=$(grep -ho '^deploy-[A-Za-z0-9_-]*: DRY_RUN' "$PROJECT_ROOT"/make/*.mk | cut -d: -f1)
[[ -n "$targets" ]] || fail 'no deploy targets found'

for target in $targets; do
  [[ "$(env -u DRY_RUN bash -c "$(declare -f resolved); PROJECT_ROOT='$PROJECT_ROOT' resolved $target")" == false ]] ||
    fail "$target: default must publish (DRY_RUN=false)"
  [[ "$(DRY_RUN=true resolved "$target")" == true ]] ||
    fail "$target: DRY_RUN=true in the environment was ignored"
  [[ "$(env -u DRY_RUN bash -c "$(declare -f resolved); PROJECT_ROOT='$PROJECT_ROOT' resolved $target DRY_RUN=true")" == true ]] ||
    fail "$target: DRY_RUN=true on the command line was ignored"
done

[[ "$(DRY_RUN=true resolved deploy-servers PRODUCTS=user)" == true ]] ||
  fail 'deploy-servers: DRY_RUN=true in the environment was ignored'

printf 'ok: %s deploy targets honour DRY_RUN\n' "$(printf '%s\n' $targets | wc -l | tr -d ' ')"

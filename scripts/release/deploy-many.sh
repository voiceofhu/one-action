#!/usr/bin/env bash
# Runs `make deploy-<product>-<kind>` for several products concurrently with one shared
# version. Each product writes its own log; the summary lists what passed and failed.
#
#   scripts/release/deploy-many.sh                     every server product
#   scripts/release/deploy-many.sh user mail notify    only these
#   KIND=web scripts/release/deploy-many.sh user pay   web-only deploys
#   DRY_RUN=true scripts/release/deploy-many.sh        plan only, nothing changes
#   JOBS=3 scripts/release/deploy-many.sh              at most 3 at a time (default: all)
#
# Products only push their own repositories; the one shared step is refreshing the
# Action checkout. A release that fails there has changed nothing, so it is retried.
# Written for the macOS system bash 3.2 (no `wait -n`, no associative arrays).
set -Euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ALL_PRODUCTS=(user object notify pay mail amz vps template node browser)
KIND=${KIND:-server}
DRY_RUN=${DRY_RUN:-false}
RETRIES=2
# Marker the release scripts print when they stopped before touching any repository.
UNCHANGED='no source repositories were changed'

case "$KIND" in
  server|web) ;;
  *) printf 'KIND must be server or web, got %s\n' "$KIND" >&2; exit 2 ;;
esac

products=("$@")
[[ ${#products[@]} -gt 0 ]] || products=("${ALL_PRODUCTS[@]}")
for product in "${products[@]}"; do
  [[ " ${ALL_PRODUCTS[*]} " == *" $product "* ]] || {
    printf 'Unknown product: %s (known: %s)\n' "$product" "${ALL_PRODUCTS[*]}" >&2
    exit 2
  }
done
JOBS=${JOBS:-${#products[@]}}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { printf 'JOBS must be a positive integer\n' >&2; exit 2; }

# One version for the whole batch, in the same format as config.mk's GENERATED_VERSION.
VERSION=${VERSION:-$(TZ=Asia/Shanghai date '+%y %m%d %H%M' |
  awk '{printf "%d.%d.%d", $1, $2, $3}')}
VERSION=${VERSION#v}
LOG_DIR=${LOG_DIR:-${TMPDIR:-/tmp}/one-deploy-$KIND-$VERSION}
mkdir -p "$LOG_DIR"

# One product, retried while it fails before changing anything.
deploy() {
  local product=$1 log="$LOG_DIR/$1.log" attempt=0
  while :; do
    if make --no-print-directory -C "$PROJECT_ROOT" "deploy-$product-$KIND" \
      VERSION="$VERSION" DRY_RUN="$DRY_RUN" >>"$log" 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ $attempt -gt $RETRIES ]] || ! grep -q "$UNCHANGED" "$log"; then
      return 1
    fi
    printf '\n--- retry %d after a failure that changed nothing ---\n\n' "$attempt" >>"$log"
    sleep $((2 + RANDOM % 5))
  done
}

printf 'Deploying %s (%s) as %s, DRY_RUN=%s, %s at a time\nLogs: %s\n\n' \
  "${products[*]}" "$KIND" "$VERSION" "$DRY_RUN" "$JOBS" "$LOG_DIR"

pids=()      # pid per running slot, parallel to names
names=()
passed=()
failed=()
started=$(date +%s)
trap 'printf "\nStopping…\n" >&2; for pid in "${pids[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done; exit 130' INT TERM

# Collects finished jobs; returns once at least one slot is free.
reap() {
  local i pid status
  while :; do
    for i in "${!pids[@]}"; do
      pid=${pids[$i]}
      [[ -n "$pid" ]] || continue
      kill -0 "$pid" 2>/dev/null && continue
      wait "$pid"; status=$?
      local took=$(( $(date +%s) - started ))
      if [[ $status -eq 0 ]]; then
        passed+=("${names[$i]}")
        printf '  ✓ %-9s %4ss\n' "${names[$i]}" "$took"
      else
        failed+=("${names[$i]}")
        printf '  ✗ %-9s %4ss  → %s\n' "${names[$i]}" "$took" "$LOG_DIR/${names[$i]}.log"
      fi
      pids[$i]=''
    done
    local running=0
    for pid in "${pids[@]:-}"; do [[ -n "$pid" ]] && running=$((running + 1)); done
    [[ $running -lt ${1:-$JOBS} ]] && return 0
    sleep 1
  done
}

for product in "${products[@]}"; do
  reap "$JOBS"
  : >"$LOG_DIR/$product.log"
  deploy "$product" &
  pids+=("$!")
  names+=("$product")
  printf '  … %s started\n' "$product"
  # Staggered starts keep the shared Action refresh from colliding.
  sleep 1
done
reap 1

printf '\nVersion %s\n  ok:     %s\n  failed: %s\n' \
  "$VERSION" "${passed[*]:-none}" "${failed[*]:-none}"
for product in "${failed[@]:-}"; do
  [[ -n "$product" ]] || continue
  printf '\n━━━ %s (last 15 lines) ━━━\n' "$product"
  tail -n 15 "$LOG_DIR/$product.log"
done
[[ ${#failed[@]} -eq 0 ]]

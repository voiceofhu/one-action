#!/usr/bin/env bash
# Runs `make deploy-<product>-<kind>` for several products in a row with one shared
# version, keeps going when one fails, and prints a summary at the end.
#
#   scripts/release/deploy-many.sh                     every server product
#   scripts/release/deploy-many.sh user mail notify    only these
#   KIND=web scripts/release/deploy-many.sh user pay   web-only deploys
#   DRY_RUN=true scripts/release/deploy-many.sh        plan only, nothing changes
set -Euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ALL_PRODUCTS=(user object notify pay mail amz vps template node browser)
KIND=${KIND:-server}
DRY_RUN=${DRY_RUN:-false}

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

# One version for the whole batch, in the same format as config.mk's GENERATED_VERSION.
VERSION=${VERSION:-$(TZ=Asia/Shanghai date '+%y %m%d %H%M' |
  awk '{printf "%d.%d.%d", $1, $2, $3}')}
VERSION=${VERSION#v}

printf 'Deploying %s (%s) as %s, DRY_RUN=%s\n\n' \
  "${products[*]}" "$KIND" "$VERSION" "$DRY_RUN"

passed=()
failed=()
for product in "${products[@]}"; do
  printf '━━━ %s ━━━\n' "$product"
  if make --no-print-directory -C "$PROJECT_ROOT" "deploy-$product-$KIND" \
    VERSION="$VERSION" DRY_RUN="$DRY_RUN"; then
    passed+=("$product")
  else
    failed+=("$product")
    printf '✗ %s failed, continuing\n' "$product" >&2
  fi
  printf '\n'
done

printf 'Version %s\n' "$VERSION"
printf '  ok:     %s\n' "${passed[*]:-none}"
printf '  failed: %s\n' "${failed[*]:-none}"
[[ ${#failed[@]} -eq 0 ]]

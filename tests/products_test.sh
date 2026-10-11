#!/usr/bin/env bash
# Every products.json product must load, and its <product>-server.yml and
# <product>-web.yml entries must be dispatch-only shells that forward their
# inputs unchanged to the shared reusable workflows.
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/product.sh
source "$PROJECT_ROOT/scripts/lib/product.sh"

products=()
for product in $(jq -r 'keys[]' "$PROJECT_ROOT/products.json"); do
  (load_product "$product")
  products+=("$product")
done

ruby -ryaml -e '
  root = ARGV.shift
  workflows = "#{root}/.github/workflows"
  load = ->(file) { YAML.safe_load(File.read("#{workflows}/#{file}"), aliases: true) }

  entries = {
    "server" => {
      reusable: "reusable-deploy-server.yml",
      inputs: %w[backend_ref backend_repository confirmation expected_action_sha publish version web_ref web_repository],
      permissions: { "contents" => "read", "packages" => "write" },
    },
    "web" => {
      reusable: "reusable-deploy-web.yml",
      inputs: %w[confirmation deploy expected_action_sha publish version web_ref web_repository],
      permissions: nil,
    },
  }
  secrets = %w[DEPLOY_HOST DEPLOY_KNOWN_HOSTS DEPLOY_PORT DEPLOY_SSH_KEY DEPLOY_USER GH_TOKEN]

  ARGV.each do |product|
    entries.each do |component, contract|
      file = "#{product}-#{component}.yml"
      fail = ->(message) { abort("#{file}: #{message}") }
      document = load.(file)
      trigger = document.fetch("on")
      fail.("must be dispatch-only") unless trigger.keys == ["workflow_dispatch"]
      inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
      fail.("unexpected dispatch inputs") unless inputs.keys.sort == contract[:inputs]
      fail.("top-level permissions must be contents: read") unless
        document.fetch("permissions") == { "contents" => "read" }
      jobs = document.fetch("jobs")
      fail.("must contain exactly one release job") unless jobs.keys == ["release"]
      job = jobs.fetch("release")
      fail.("must call #{contract[:reusable]}") unless
        job.fetch("uses") == "./.github/workflows/#{contract[:reusable]}"
      fail.("unexpected job permissions") unless job["permissions"] == contract[:permissions]
      forwarded = contract[:inputs].to_h { |name| [name, "${{ inputs.#{name} }}"] }
      fail.("must forward every input unchanged with product: #{product}") unless
        job.fetch("with") == { "product" => product }.merge(forwarded)
      fail.("must pass exactly the deployment secrets") unless
        job.fetch("secrets") == secrets.to_h { |name| [name, "${{ secrets.#{name} }}"] }
      if component == "server"
        fail.("publish concurrency changed") unless document.fetch("concurrency") == {
          "group" => "one-#{product}-publish-${{ inputs.version }}", "cancel-in-progress" => false
        }
      end
    end
  end

  server = load.("reusable-deploy-server.yml")
  jobs = server.fetch("jobs")
  abort("reusable-deploy-server.yml: unexpected jobs") unless jobs.keys == %w[prepare publish deploy]
  abort("reusable-deploy-server.yml: prepare timeout changed") unless
    jobs.fetch("prepare").fetch("timeout-minutes") <= 2
  abort("reusable-deploy-server.yml: publish must use the shared image publisher") unless
    jobs.fetch("publish").fetch("uses") == "./.github/workflows/reusable-publish-server-image.yml"
  web = load.("reusable-deploy-web.yml")
  [server.fetch("jobs").fetch("deploy"), web.fetch("jobs").fetch("deploy")].each do |deploy|
    abort("deploy environment changed") unless
      deploy.fetch("environment").fetch("name") == "one-${{ inputs.product }}-prod"
    abort("deploy concurrency changed") unless deploy.fetch("concurrency") == {
      "group" => "one-${{ inputs.product }}-prod-deploy", "cancel-in-progress" => false
    }
  end
  abort("reusable-deploy-server.yml: deploy must wait for prepare and publish") unless
    jobs.fetch("deploy").fetch("needs") == %w[prepare publish]
' "$PROJECT_ROOT" "${products[@]}"

# The dispatcher must derive repositories and confirmations from the manifest.
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
dispatch() {
  PATH="$PROJECT_ROOT/tests/fakes:$PATH" FAKE_CURL_LOG="$test_dir/curl.log" \
    FAKE_EXPECTED_AUTH=abcdefghijklmnopqrstuvwxyz123456 GH_TOKEN=abcdefghijklmnopqrstuvwxyz123456 \
    ACTION_REPOSITORY=voiceofhu/one-action DRY_RUN=true \
    bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" "$@" 2>&1
}
action_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for product in "${products[@]}"; do
  load_product "$product"
  server="$(dispatch "$PRODUCT_SERVER_WORKFLOW" \
    "backend_repository=$PRODUCT_BACKEND_REPOSITORY" backend_ref=main \
    "web_repository=$PRODUCT_WEB_REPOSITORY" web_ref=main version=1.2.3 publish=true)"
  grep -Fq "\"confirmation\": \"enable:$PRODUCT_NAME:$action_sha\"" <<<"$server" ||
    product_die "$PRODUCT_SERVER_WORKFLOW dispatch has the wrong confirmation: $server"
  web="$(dispatch "$PRODUCT_WEB_WORKFLOW" "web_repository=$PRODUCT_WEB_REPOSITORY" web_ref=main \
    version=1.2.3 publish=true deploy=true)"
  grep -Fq "\"confirmation\": \"enable:$PRODUCT_KEY-web:$action_sha\"" <<<"$web" ||
    product_die "$PRODUCT_WEB_WORKFLOW dispatch has the wrong confirmation: $web"
  if dispatch "$PRODUCT_WEB_WORKFLOW" web_repository=voiceofhu/not-this-product web_ref=main \
    version=1.2.3 publish=true deploy=true >/dev/null; then
    product_die "$PRODUCT_WEB_WORKFLOW accepted a foreign Web repository"
  fi
done

printf 'Product manifest and %s entry workflow pairs are consistent.\n' "${#products[@]}"

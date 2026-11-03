#!/usr/bin/env bash
# Every products.json product must load, and its <product>-server.yml and
# <product>-web.yml entries must be thin shells that run only on their own
# deploy/<product>-<component>/* tag and call the shared reusable workflows
# (a Next.js Web, web_runtime next, deploys through its own image workflow).
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/product.sh
source "$PROJECT_ROOT/scripts/lib/product.sh"

# Checks the given products.json products (default: every product).
requested=("$@")
if [[ "${#requested[@]}" -eq 0 ]]; then
  while IFS= read -r product; do
    requested+=("$product")
  done < <(jq -r 'keys[]' "$PROJECT_ROOT/products.json")
fi
products=()
for product in "${requested[@]}"; do
  products+=("$product:$(load_product "$product"; printf '%s' "$PRODUCT_WEB_RUNTIME")")
done

ruby -ryaml -e '
  root = ARGV.shift
  workflows = "#{root}/.github/workflows"
  load = ->(file) { YAML.safe_load(File.read("#{workflows}/#{file}"), aliases: true) }

  entries = {
    "server" => {
      reusable: "reusable-deploy-server.yml",
      permissions: { "contents" => "read", "packages" => "write" },
    },
    "web" => {
      reusable: "reusable-deploy-web.yml",
      permissions: nil,
    },
  }
  secrets = %w[DEPLOY_HOST DEPLOY_KNOWN_HOSTS DEPLOY_PORT DEPLOY_SSH_KEY DEPLOY_USER GH_TOKEN]

  image_web = {
    reusable: "reusable-deploy-web-image.yml",
    permissions: { "contents" => "read", "packages" => "write" },
  }
  ARGV.each do |entry|
    product, runtime = entry.split(":", 2)
    entries.each do |component, contract|
      contract = image_web if component == "web" && runtime == "next"
      file = "#{product}-#{component}.yml"
      fail = ->(message) { abort("#{file}: #{message}") }
      document = load.(file)
      trigger = document.fetch("on")
      fail.("must run only on its deploy tag") unless
        trigger == { "push" => { "tags" => ["deploy/#{product}-#{component}/*"] } }
      fail.("top-level permissions must be contents: read") unless
        document.fetch("permissions") == { "contents" => "read" }
      jobs = document.fetch("jobs")
      fail.("must contain exactly one release job") unless jobs.keys == ["release"]
      job = jobs.fetch("release")
      fail.("must call #{contract[:reusable]}") unless
        job.fetch("uses") == "./.github/workflows/#{contract[:reusable]}"
      fail.("unexpected job permissions") unless job["permissions"] == contract[:permissions]
      fail.("must pass only product: #{product}") unless
        job.fetch("with") == { "product" => product }
      fail.("must pass exactly the deployment secrets") unless
        job.fetch("secrets") == secrets.to_h { |name| [name, "${{ secrets.#{name} }}"] }
      if component == "server"
        fail.("publish concurrency changed") unless document.fetch("concurrency") == {
          "group" => "one-#{product}-publish-${{ github.ref_name }}", "cancel-in-progress" => false
        }
      end
    end
  end

  server = load.("reusable-deploy-server.yml")
  jobs = server.fetch("jobs")
  abort("reusable-deploy-server.yml: unexpected jobs") unless jobs.keys == %w[prepare publish publish_web deploy]
  abort("reusable-deploy-server.yml: prepare timeout changed") unless
    jobs.fetch("prepare").fetch("timeout-minutes") <= 2
  abort("reusable-deploy-server.yml: publish must use the shared image publisher") unless
    jobs.fetch("publish").fetch("uses") == "./.github/workflows/reusable-publish-server-image.yml"
  web = load.("reusable-deploy-web.yml")
  web_image = load.("reusable-deploy-web-image.yml")
  abort("reusable-deploy-web-image.yml: unexpected jobs") unless
    web_image.fetch("jobs").keys == %w[prepare publish deploy]
  abort("reusable-deploy-web-image.yml: publish must use the shared image publisher") unless
    web_image.fetch("jobs").fetch("publish").fetch("uses") == "./.github/workflows/reusable-publish-server-image.yml"
  [server, web, web_image].map { |document| document.fetch("jobs").fetch("deploy") }.each do |deploy|
    abort("deploy environment changed") unless
      deploy.fetch("environment").fetch("name") == "one-${{ inputs.product }}-prod"
    abort("deploy concurrency changed") unless deploy.fetch("concurrency") == {
      "group" => "one-${{ inputs.product }}-prod-deploy", "cancel-in-progress" => false
    }
  end
  abort("reusable-deploy-server.yml: deploy must wait for prepare and publish") unless
    jobs.fetch("deploy").fetch("needs") == %w[prepare publish publish_web]
' "$PROJECT_ROOT" "${products[@]}"

printf 'Product manifest and %s entry workflow pairs are consistent.\n' "${#products[@]}"

SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/deploy.mk
include $(PROJECT_ROOT)/make/validate.mk
include $(PROJECT_ROOT)/make/node.mk

.PHONY: fix fix-servers
fix: fix-servers

fix-servers: export PRODUCTS := $(PRODUCTS)
fix-servers: export SOURCE_ROOT := $(SOURCE_ROOT)
fix-servers:
	@set -eu; \
		source "$(PROJECT_ROOT)/scripts/lib/product.sh"; \
		products=$${PRODUCTS:-$$(jq -r 'keys | join(" ")' "$$PRODUCT_MANIFEST")}; \
		for product in $$products; do \
			load_product "$$product"; \
			if [[ "$$PRODUCT_BACKEND_LANGUAGE" != rust ]]; then \
				printf 'Skipping %s: not a Rust backend\n' "$$PRODUCT_TITLE"; \
				continue; \
			fi; \
			backend_dir_variable=ONE_$$(printf '%s' "$$PRODUCT_KEY" | tr '[:lower:]' '[:upper:]')_BACKEND_DIR; \
			backend_dir=$${!backend_dir_variable:-$$SOURCE_ROOT/$$PRODUCT_NAME/backend}; \
			printf 'Formatting %s: %s\n' "$$PRODUCT_TITLE" "$$backend_dir"; \
			(cd -- "$$backend_dir" && cargo fmt --all); \
		done

.PHONY: help
help:
	@printf '%s\n' \
		"One Action" \
		"" \
		"Products: $(SERVER_PRODUCTS)" \
		"Apps (Tauri): $(APP_PRODUCTS)" \
		"" \
		"Local fixes:" \
		"  make fix                       Format all Rust server products (PRODUCTS=\"user mail\" to pick)" \
		"  make fix-servers               Same as make fix (used by the release scripts)" \
		"" \
		"Local checks:" \
		"  make validate                  Validate every shell and workflow contract" \
		"  make validate-<product>        Validate one product's Server/Web release contracts" \
		"  make validate-<product>-web    Validate one product's Web deployment contracts" \
		"  make validate-<app>-app        Validate App (Tauri) release contracts" \
		"  make validate-node-runtime     Validate One Node Runtime release contracts" \
		"  make validate-browser-runtime  Validate One Browser Chromium runtime release contracts" \
		"  make node-check                Test the One Node lifecycle locally" \
		"  make node-bundle-installers    Build local One Node installer snapshots" \
		"" \
		"Releases (publish unless DRY_RUN=true; VERSION= overrides the generated version):" \
		"  make deploy-<product>-server   Publish and deploy a Server with its Web" \
		"  make deploy-<product>-web      Deploy a Web without restarting its Server" \
		"  make deploy-servers            Deploy every Server (PRODUCTS=\"user mail\" to pick)" \
		"  make deploy-webs               Deploy every Web (PRODUCTS=...)" \
		"  make deploy-<app>-app          Check a desktop App and tag installer publication" \
		"  make deploy-<app>-apk          Build the signed Android APK locally and publish it ($(ANDROID_PRODUCTS))" \
		"  make deploy-node               Check One Node source and tag compile/upload" \
		"  make deploy-browser-runtime    Publish staged Chromium runtime (VERSION=, CHROMIUM_REF=)"

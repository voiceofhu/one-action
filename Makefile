SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/workflows.mk
include $(PROJECT_ROOT)/make/egress.mk
include $(PROJECT_ROOT)/make/node.mk

.PHONY: help
help:
	@printf '%s\n' \
		"One Action (greenfield)" \
		"" \
		"Safety defaults:" \
		"  DRY_RUN=true                Resolve and print only; never dispatch" \
		"  CONFIRM_DISPATCH=...        Action-SHA-bound guard when DRY_RUN=false" \
		"  CONFIRM_MUTATION=...        Action-SHA-bound publication guard" \
		"" \
		"Checks:" \
		"  make validate               Check shell syntax and workflow YAML" \
		"  make egress-installer-test Test installers with local fixtures only" \
		"  make node-check             Test the namespaced Node lifecycle locally" \
		"  make node-bundle-installers Build local Node installer snapshots" \
		"  make check-token            Read-only GitHub token/access check" \
		"" \
		"Workflow plans (dry-run by default):" \
		"  make dispatch-one-user" \
		"  make dispatch-one-browser-backend" \
		"  make dispatch-app" \
		"  make dispatch-app-debug" \
		"  make dispatch-egress" \
		"  make dispatch-browser-runtime  BLOCKED: Runtime trust root unresolved" \
		"  make dispatch-node             Exact-SHA One Node build/test; publication blocked" \
		"  make dispatch-one-amz" \
		"  make deploy-user             Publish combined User image, then deploy exact digest" \
		"" \
		"Example real dispatch (non-publishing build validation):" \
		"  First dry-run and copy its exact Action SHA into <action-sha>" \
		"  make dispatch-one-user DRY_RUN=false \\" \
		"    CONFIRM_DISPATCH='dispatch:user.yml:<action-sha>'" \
		"" \
		"Example GHCR publication (no deployment):" \
		"  make dispatch-one-user PUBLISH=true VERSION=1.2.3 DRY_RUN=false \\" \
		"    CONFIRM_DISPATCH='dispatch:user.yml:<action-sha>' \\" \
		"    CONFIRM_MUTATION='mutate:user.yml:<action-sha>'" \
		"" \
		"Example Egress public Release (no deployment):" \
		"  make dispatch-egress PUBLISH=true VERSION=1.2.3 ENVIRONMENT=prod DRY_RUN=false \\" \
		"    CONFIRM_DISPATCH='dispatch:egress.yml:<action-sha>' \\" \
		"    CONFIRM_MUTATION='mutate:egress.yml:<action-sha>'" \
		"" \
		"Example One User production deployment:" \
		"  make deploy-user VERSION=1.2.3" \
		"  make deploy-user VERSION=1.2.3 DRY_RUN=false \\" \
		"    CONFIRM_DISPATCH='dispatch:user.yml:<action-sha>' \\" \
		"    CONFIRM_MUTATION='mutate:user.yml:<action-sha>'" \
		"" \
		"Example One Node exact-source validation (no publication/deployment):" \
		"  make dispatch-node" \
		"  make dispatch-node DRY_RUN=false \\" \
		"    CONFIRM_DISPATCH='dispatch:node.yml:<action-sha>'"

SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/user.mk
include $(PROJECT_ROOT)/make/node.mk
include $(PROJECT_ROOT)/make/browser.mk

.PHONY: help
help:
	@printf '%s\n' \
		"One Action" \
		"" \
		"Local checks:" \
		"  make validate               Validate active shell and workflow contracts locally" \
		"  make validate-user          Validate only One User release contracts" \
		"  make validate-node          Validate only One Node Runtime release contracts" \
		"  make validate-node-server   Validate only One Node Server release contracts" \
		"  make validate-browser-egress Validate only Browser Egress release contracts" \
		"  make node-check             Test the One Node lifecycle locally" \
		"  make node-bundle-installers Build local One Node installer snapshots" \
		"  make check-token            Check read-only access to active workflows" \
		"" \
		"Product releases:" \
		"  make deploy-user            Compile, upload, and deploy One User" \
		"  make deploy-node-server     Compile, upload, and deploy One Node Server" \
		"  make deploy-node            Check One Node source and dispatch compile/upload" \
		"  make deploy-browser-app     Dispatch One Browser App installer publication" \
		"  make deploy-app-server      Check Browser Backend/Web and dispatch image publication" \
		"  make deploy-browser-egress  Check Browser Egress and dispatch package/image publication"

SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/user.mk
include $(PROJECT_ROOT)/make/object.mk
include $(PROJECT_ROOT)/make/notify.mk
include $(PROJECT_ROOT)/make/pay.mk
include $(PROJECT_ROOT)/make/node.mk
include $(PROJECT_ROOT)/make/browser.mk

.PHONY: help
help:
	@printf '%s\n' \
		"One Action" \
		"" \
		"Local checks:" \
		"  make validate-object        Validate One Object Server/Web release contracts" \
		"  make validate-object-web    Validate One Object Web deployment contracts" \
		"  make validate-notify        Validate One Notify Server/Web release contracts" \
		"  make validate-pay           Validate One Pay Server/Web release contracts" \
		"  make validate               Validate active shell and workflow contracts locally" \
		"  make validate-user          Validate only One User release contracts" \
		"  make validate-user-web      Validate One User Web deployment contracts" \
		"  make validate-node          Validate only One Node Runtime release contracts" \
		"  make validate-node-server   Validate only One Node Server release contracts" \
		"  make validate-browser-app   Validate Browser App release version contracts" \
		"  make validate-browser-egress Validate only Browser Egress release contracts" \
		"  make node-check             Test the One Node lifecycle locally" \
		"  make node-bundle-installers Build local One Node installer snapshots" \
		"  make check-token            Check read-only access to active workflows" \
		"" \
		"Product releases:" \
		"  make deploy-object-server   Publish and deploy One Object with Web" \
		"  make deploy-object-web      Deploy Web without restarting Object Server" \
		"  make deploy-pay-server      Publish and deploy One Pay with Web" \
		"  make deploy-pay-web         Deploy Web without restarting Pay Server" \
		"  make deploy-notify-server   Publish and deploy One Notify with Web" \
		"  make deploy-notify-web      Deploy Web without restarting Notify Server" \
		"  make deploy-user-server     Compile, upload, and deploy One User with Web" \
		"  make deploy-user-web        Check and deploy Web without restarting User Server" \
		"  make deploy-node-server     Compile, upload, and deploy One Node Server" \
		"  make deploy-node-web        Check and deploy Web without restarting Node Server" \
		"  make deploy-node            Check One Node source and dispatch compile/upload" \
		"  make deploy-browser-app     Check One Browser App and dispatch installer publication" \
		"  make deploy-browser-server  Check, publish, and deploy Browser Server with Web" \
		"  make deploy-browser-web     Check and deploy Web without restarting Server" \
		"  make deploy-browser-egress  Check Browser Egress and dispatch package/image publication"

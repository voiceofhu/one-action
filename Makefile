SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := help

include $(PROJECT_ROOT)/make/config.mk
include $(PROJECT_ROOT)/make/github.mk
include $(PROJECT_ROOT)/make/user.mk
include $(PROJECT_ROOT)/make/object.mk
include $(PROJECT_ROOT)/make/notify.mk
include $(PROJECT_ROOT)/make/pay.mk
include $(PROJECT_ROOT)/make/amz.mk
include $(PROJECT_ROOT)/make/mail.mk
include $(PROJECT_ROOT)/make/vps.mk
include $(PROJECT_ROOT)/make/template.mk
include $(PROJECT_ROOT)/make/node.mk
include $(PROJECT_ROOT)/make/browser.mk

# Batch deploys: `make deploy-servers` (all) or `make deploy-servers PRODUCTS="user mail"`.
.PHONY: deploy-servers deploy-webs
deploy-servers:
	@KIND=server DRY_RUN="$(if $(filter command line,$(origin DRY_RUN)),$(DRY_RUN),false)" \
		VERSION="$(VERSION)" bash $(PROJECT_ROOT)/scripts/release/deploy-many.sh $(PRODUCTS)
deploy-webs:
	@KIND=web DRY_RUN="$(if $(filter command line,$(origin DRY_RUN)),$(DRY_RUN),false)" \
		VERSION="$(VERSION)" bash $(PROJECT_ROOT)/scripts/release/deploy-many.sh $(PRODUCTS)

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
		"  make validate-amz           Validate One AMZ Server/Web release contracts" \
		"  make validate-mail          Validate One Mail Server/Web release contracts" \
		"  make validate-vps           Validate One VPS Server/Web release contracts" \
		"  make validate-template      Validate One Template Server/Web release contracts" \
		"  make validate-template-web  Validate One Template Web deployment contracts" \
		"  make validate               Validate active shell and workflow contracts locally" \
		"  make validate-user          Validate only One User release contracts" \
		"  make validate-user-web      Validate One User Web deployment contracts" \
		"  make validate-node          Validate One Node Server/Web release contracts" \
		"  make validate-browser       Validate One Browser Server/Web release contracts" \
		"  make validate-node-runtime  Validate only One Node Runtime release contracts" \
		"  make validate-browser-app   Validate desktop App (Tauri) release contracts" \
		"  make validate-mail-app      Validate desktop App (Tauri) release contracts" \
		"  make validate-browser-egress Validate only Browser Egress release contracts" \
		"  make node-check             Test the One Node lifecycle locally" \
		"  make node-bundle-installers Build local One Node installer snapshots" \
		"" \
		"Product releases:" \
		"  make deploy-servers         Deploy every server product (PRODUCTS=\"user mail\" to pick)" \
		"  make deploy-webs            Deploy every web without restarting servers (PRODUCTS=...)" \
		"  make deploy-object-server   Publish and deploy One Object with Web" \
		"  make deploy-object-web      Deploy Web without restarting Object Server" \
		"  make deploy-pay-server      Publish and deploy One Pay with Web" \
		"  make deploy-pay-web         Deploy Web without restarting Pay Server" \
		"  make deploy-amz-server      Publish and deploy One AMZ with Web" \
		"  make deploy-amz-web         Deploy Web without restarting AMZ Server" \
		"  make deploy-mail-server     Publish and deploy One Mail with Web" \
		"  make deploy-mail-web        Deploy Web without restarting Mail Server" \
		"  make deploy-vps-server      Publish and deploy One VPS with Web" \
		"  make deploy-vps-web         Deploy Web without restarting VPS Server" \
		"  make deploy-template-server Publish and deploy One Template with Web" \
		"  make deploy-template-web    Deploy Web without restarting Template Server" \
		"  make deploy-notify-server   Publish and deploy One Notify with Web" \
		"  make deploy-notify-web      Deploy Web without restarting Notify Server" \
		"  make deploy-user-server     Compile, upload, and deploy One User with Web" \
		"  make deploy-user-web        Check and deploy Web without restarting User Server" \
		"  make deploy-node-server     Publish and deploy One Node with Web" \
		"  make deploy-node-web        Deploy Web without restarting Node Server" \
		"  make deploy-node            Check One Node source and tag compile/upload" \
		"  make deploy-browser-app     Check One Browser App and tag installer publication" \
		"  make deploy-mail-app        Check One Mail App and tag installer publication" \
		"  make deploy-browser-server  Publish and deploy One Browser with Web" \
		"  make deploy-browser-web     Deploy Web without restarting Browser Server" \
		"  make deploy-browser-egress  Check Browser Egress and tag package/image publication"

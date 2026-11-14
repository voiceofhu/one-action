.PHONY: deploy-vps-server deploy-vps-web

deploy-vps-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-vps-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(VPS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh vps

deploy-vps-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-vps-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(VPS_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh vps

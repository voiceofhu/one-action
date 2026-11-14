.PHONY: deploy-ip-server deploy-ip-web

deploy-ip-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-ip-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(IP_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh ip

deploy-ip-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-ip-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(IP_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh ip

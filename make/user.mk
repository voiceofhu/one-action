.PHONY: deploy-user-server deploy-user-web

deploy-user-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-user-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh user

deploy-user-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-user-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh user

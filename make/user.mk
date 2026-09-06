.PHONY: deploy-user-server deploy-user-web

deploy-user-server: DRY_RUN = false
deploy-user-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-user-release.sh

deploy-user-web: DRY_RUN = false
deploy-user-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-user-web-release.sh

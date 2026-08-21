.PHONY: deploy-user

deploy-user: DRY_RUN = false
deploy-user:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-user-release.sh

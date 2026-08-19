.PHONY: dispatch-one-user deploy-user

dispatch-one-user:
	$(call dispatch_workflow,user.yml,\
		backend_repository="$${ONE_USER_BACKEND_REPOSITORY}" \
		backend_ref="$${ONE_USER_BACKEND_REF}" \
		web_repository="$${ONE_USER_WEB_REPOSITORY}" \
		web_ref="$${ONE_USER_WEB_REF}" \
		version="$${VERSION}" publish="$${PUBLISH}")

deploy-user: DRY_RUN = false
deploy-user:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-user-release.sh

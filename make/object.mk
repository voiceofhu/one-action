.PHONY: deploy-object-server deploy-object-web

deploy-object-server: DRY_RUN = false
deploy-object-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(OBJECT_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh object

deploy-object-web: DRY_RUN = false
deploy-object-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(OBJECT_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh object

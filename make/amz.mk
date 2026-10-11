.PHONY: deploy-amz-server deploy-amz-web

deploy-amz-server: DRY_RUN = false
deploy-amz-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(AMZ_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh amz

deploy-amz-web: DRY_RUN = false
deploy-amz-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(AMZ_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh amz

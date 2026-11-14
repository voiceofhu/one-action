.PHONY: deploy-template-server deploy-template-web

deploy-template-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-template-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(TEMPLATE_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh template

deploy-template-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-template-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(TEMPLATE_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh template

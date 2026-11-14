.PHONY: deploy-mail-server deploy-mail-web deploy-mail-pc

deploy-mail-server: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-mail-server:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(MAIL_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-server.sh mail

deploy-mail-web: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-mail-web:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(MAIL_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-web.sh mail

deploy-mail-pc: DRY_RUN = $(DEPLOY_DRY_RUN)
deploy-mail-pc:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(MAIL_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/release-app.sh mail

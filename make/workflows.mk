.PHONY: dispatch-one-user deploy-user dispatch-one-browser-backend dispatch-app \
	dispatch-app-debug dispatch-egress dispatch-browser-runtime dispatch-one-amz

define dispatch_workflow
	@bash $(PROJECT_ROOT)/scripts/github/dispatch-workflow.sh $(1) $(2)
endef

dispatch-one-user:
	$(call dispatch_workflow,user.yml,\
		backend_repository="$${ONE_USER_BACKEND_REPOSITORY}" \
		backend_ref="$${ONE_USER_BACKEND_REF}" \
		web_repository="$${ONE_USER_WEB_REPOSITORY}" \
		web_ref="$${ONE_USER_WEB_REF}" \
		version="$${VERSION}" environment="$${ENVIRONMENT}" \
		publish="$${PUBLISH}" deploy="$${DEPLOY}")

deploy-user: DRY_RUN = false
deploy-user:
	@DRY_RUN="$(DRY_RUN)" VERSION="$(USER_RELEASE_VERSION)" \
		bash $(PROJECT_ROOT)/scripts/release/deploy-user-release.sh

dispatch-one-browser-backend:
	$(call dispatch_workflow,one-browser-backend.yml,\
		backend_repository="$${ONE_BROWSER_BACKEND_REPOSITORY}" \
		backend_ref="$${ONE_BROWSER_BACKEND_REF}" \
		version="$${VERSION}" environment="$${ENVIRONMENT}" \
		publish="$${PUBLISH}" deploy="$${DEPLOY}")

dispatch-app:
	$(call dispatch_workflow,app.yml,\
		app_repository="$${ONE_BROWSER_APP_REPOSITORY}" \
		app_ref="$${ONE_BROWSER_APP_REF}" \
		version="$${VERSION}" publish="$${PUBLISH}")

dispatch-app-debug:
	$(call dispatch_workflow,app-debug.yml,\
		app_repository="$${ONE_BROWSER_APP_REPOSITORY}" \
		app_ref="$${ONE_BROWSER_APP_REF}" upload_artifact="$${PUBLISH}")

dispatch-egress:
	$(call dispatch_workflow,egress.yml,\
		egress_repository="$${ONE_BROWSER_EGRESS_REPOSITORY}" \
		egress_ref="$${ONE_BROWSER_EGRESS_REF}" \
		version="$${VERSION}" environment="$${ENVIRONMENT}" \
		publish="$${PUBLISH}" deploy="$${DEPLOY}")

dispatch-browser-runtime:
	$(call dispatch_workflow,browser-runtime.yml,\
		runtime_repository="$${BROWSER_RUNTIME_REPOSITORY}" \
		runtime_ref="$${BROWSER_RUNTIME_REF}" \
		version="$${VERSION}" publish="$${PUBLISH}")

dispatch-one-amz:
	$(call dispatch_workflow,one-amz.yml,\
		backend_repository="$${ONE_AMZ_BACKEND_REPOSITORY}" \
		backend_ref="$${ONE_AMZ_BACKEND_REF}" \
		web_repository="$${ONE_AMZ_WEB_REPOSITORY}" \
		web_ref="$${ONE_AMZ_WEB_REF}" \
		version="$${VERSION}" environment="$${ENVIRONMENT}" \
		publish="$${PUBLISH}" deploy="$${DEPLOY}")

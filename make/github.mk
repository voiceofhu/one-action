.PHONY: validate validate-user validate-node-runtime validate-browser-app

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

validate-user:
	@bash $(PROJECT_ROOT)/scripts/validate.sh user

validate-node-runtime:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node-runtime

validate-browser-app:
	@bash $(PROJECT_ROOT)/scripts/validate.sh browser-app

.PHONY: validate-mail-app
validate-mail-app:
	@bash $(PROJECT_ROOT)/scripts/validate.sh mail-app

.PHONY: validate-user-web
validate-user-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh user-web

.PHONY: validate-object validate-object-web
validate-object:
	@bash $(PROJECT_ROOT)/scripts/validate.sh object
validate-object-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh object-web

.PHONY: validate-notify validate-notify-web
validate-notify:
	@bash $(PROJECT_ROOT)/scripts/validate.sh notify
validate-notify-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh notify-web

.PHONY: validate-amz validate-amz-web validate-mail validate-mail-web
validate-amz:
	@bash $(PROJECT_ROOT)/scripts/validate.sh amz
validate-amz-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh amz-web
validate-mail:
	@bash $(PROJECT_ROOT)/scripts/validate.sh mail
validate-mail-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh mail-web

.PHONY: validate-pay validate-pay-web
validate-pay:
	@bash $(PROJECT_ROOT)/scripts/validate.sh pay
validate-pay-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh pay-web

.PHONY: validate-vps validate-vps-web
validate-vps:
	@bash $(PROJECT_ROOT)/scripts/validate.sh vps
validate-vps-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh vps-web

.PHONY: validate-template validate-template-web
validate-template:
	@bash $(PROJECT_ROOT)/scripts/validate.sh template
validate-template-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh template-web

.PHONY: validate-node validate-node-web validate-browser validate-browser-web
validate-node:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node
validate-node-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node-web
validate-browser:
	@bash $(PROJECT_ROOT)/scripts/validate.sh browser
validate-browser-web:
	@bash $(PROJECT_ROOT)/scripts/validate.sh browser-web

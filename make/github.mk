.PHONY: validate validate-user validate-node validate-node-server validate-browser-egress check-token

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

validate-user:
	@bash $(PROJECT_ROOT)/scripts/validate.sh user

validate-node:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node

validate-node-server:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node-server

validate-browser-egress:
	@bash $(PROJECT_ROOT)/scripts/validate.sh browser-egress

check-token:
	@bash $(PROJECT_ROOT)/scripts/github/check-token.sh

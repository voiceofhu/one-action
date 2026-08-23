.PHONY: validate validate-user validate-node-server check-token

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

validate-user:
	@bash $(PROJECT_ROOT)/scripts/validate.sh user

validate-node-server:
	@bash $(PROJECT_ROOT)/scripts/validate.sh node-server

check-token:
	@bash $(PROJECT_ROOT)/scripts/github/check-token.sh

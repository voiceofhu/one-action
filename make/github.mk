.PHONY: validate check-token

validate:
	@bash $(PROJECT_ROOT)/scripts/validate.sh

check-token:
	@bash $(PROJECT_ROOT)/scripts/github/check-token.sh

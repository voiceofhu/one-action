override ACTION_REPOSITORY := voiceofhu/one-action
ACTION_REF ?= main
override GITHUB_API_URL := https://api.github.com
DRY_RUN ?= true
CONFIRM_DISPATCH ?=
CONFIRM_MUTATION ?=

ONE_USER_BACKEND_REPOSITORY ?= voiceofhu/one-user-backend
ONE_USER_BACKEND_REF ?= main
ONE_USER_WEB_REPOSITORY ?= voiceofhu/one-user-web
ONE_USER_WEB_REF ?= main

SOURCE_ROOT ?= $(abspath $(PROJECT_ROOT)/..)
ONE_USER_BACKEND_DIR ?= $(SOURCE_ROOT)/one-user/backend
ONE_USER_WEB_DIR ?= $(SOURCE_ROOT)/one-user/web
GENERATED_VERSION ?= $(shell node -e "\
  const d=new Date(new Date().toLocaleString('en-US',{timeZone:'Asia/Shanghai'}));\
  const strip=value=>String(Number(value));\
  const year=String(d.getFullYear()).slice(-2);\
  const monthDay=String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');\
  const hourMinute=String(d.getHours()).padStart(2,'0')+String(d.getMinutes()).padStart(2,'0');\
  process.stdout.write([year,monthDay,hourMinute].map(strip).join('.'));\
")
USER_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

ONE_BROWSER_BACKEND_REPOSITORY ?= voiceofhu/one-browser-backend-next
ONE_BROWSER_BACKEND_REF ?= main
ONE_BROWSER_APP_REPOSITORY ?= voiceofhu/one-browser-app-next
ONE_BROWSER_APP_REF ?= main
ONE_BROWSER_EGRESS_REPOSITORY ?= voiceofhu/one-browser-egress-next
ONE_BROWSER_EGRESS_REF ?= main
BROWSER_RUNTIME_REPOSITORY ?=
BROWSER_RUNTIME_REF ?= main

ONE_NODE_REPOSITORY ?= voiceofhu/one-node-node
ONE_NODE_REF ?= main

ONE_AMZ_BACKEND_REPOSITORY ?= voiceofhu/one-amz-backend-next
ONE_AMZ_BACKEND_REF ?= main
ONE_AMZ_WEB_REPOSITORY ?= voiceofhu/one-amz-web-next
ONE_AMZ_WEB_REF ?= main

VERSION ?=
ENVIRONMENT ?= dev
PUBLISH ?= false
DEPLOY ?= false

ENV_FILE ?= $(PROJECT_ROOT)/.env
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

# Export values so recipes expand them inside quoted shell parameters rather
# than interpolating untrusted Make values into recipe source.
export ACTION_REPOSITORY ACTION_REF GITHUB_API_URL DRY_RUN
export CONFIRM_DISPATCH CONFIRM_MUTATION GH_TOKEN
export ONE_USER_BACKEND_REPOSITORY ONE_USER_BACKEND_REF
export ONE_USER_WEB_REPOSITORY ONE_USER_WEB_REF
export ONE_USER_BACKEND_DIR ONE_USER_WEB_DIR GENERATED_VERSION
export ONE_BROWSER_BACKEND_REPOSITORY ONE_BROWSER_BACKEND_REF
export ONE_BROWSER_APP_REPOSITORY ONE_BROWSER_APP_REF
export ONE_BROWSER_EGRESS_REPOSITORY ONE_BROWSER_EGRESS_REF
export BROWSER_RUNTIME_REPOSITORY BROWSER_RUNTIME_REF
export ONE_NODE_REPOSITORY ONE_NODE_REF
export ONE_AMZ_BACKEND_REPOSITORY ONE_AMZ_BACKEND_REF
export ONE_AMZ_WEB_REPOSITORY ONE_AMZ_WEB_REF
export VERSION ENVIRONMENT PUBLISH DEPLOY

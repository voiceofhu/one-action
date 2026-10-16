DRY_RUN ?= true

SOURCE_ROOT ?= $(abspath $(PROJECT_ROOT)/..)
GENERATED_VERSION ?= $(shell node -e "\
  const d=new Date(new Date().toLocaleString('en-US',{timeZone:'Asia/Shanghai'}));\
  const strip=value=>String(Number(value));\
  const year=String(d.getFullYear()).slice(-2);\
  const monthDay=String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');\
  const hourMinute=String(d.getHours()).padStart(2,'0')+String(d.getMinutes()).padStart(2,'0');\
  process.stdout.write([year,monthDay,hourMinute].map(strip).join('.'));\
")
USER_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))
NODE_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

ONE_BROWSER_APP_REF ?= main
ONE_BROWSER_EGRESS_REPOSITORY ?= voiceofhu/one-browser-egress
ONE_BROWSER_APP_DIR ?= $(SOURCE_ROOT)/one-browser/app
ONE_BROWSER_EGRESS_DIR ?= $(SOURCE_ROOT)/one-browser/egress
BROWSER_APP_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))
BROWSER_EGRESS_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

ONE_NODE_REPOSITORY ?= voiceofhu/one-node-node
ONE_NODE_REF ?= main
ONE_NODE_DIR ?= $(SOURCE_ROOT)/one-node/node

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
export DRY_RUN
export GENERATED_VERSION
export ONE_BROWSER_APP_REF
export ONE_BROWSER_EGRESS_REPOSITORY
export ONE_BROWSER_APP_DIR
export ONE_BROWSER_EGRESS_DIR
export ONE_NODE_REPOSITORY ONE_NODE_REF
export ONE_NODE_DIR
export VERSION ENVIRONMENT PUBLISH DEPLOY

BROWSER_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

OBJECT_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

NOTIFY_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

PAY_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))
AMZ_RELEASE_VERSION = $(PAY_RELEASE_VERSION)
MAIL_RELEASE_VERSION = $(PAY_RELEASE_VERSION)

VPS_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))
TEMPLATE_RELEASE_VERSION = $(patsubst v%,%,$(strip $(if $(VERSION),$(VERSION),$(GENERATED_VERSION))))

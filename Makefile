# Entry points for every workflow. Targets call scripts and contain no logic;
# every script runs on its own.

.DEFAULT_GOAL := help

SERVICE_VERSION_FILES := $(wildcard services/*/versions/*/version.env)
SERVICE_TARGETS := $(foreach file,$(SERVICE_VERSION_FILES),service-$(word 2,$(subst /, ,$(file)))-$(word 4,$(subst /, ,$(file))))
SMOKE_SERVICE_TARGETS := $(addprefix smoke-,$(SERVICE_TARGETS))

.PHONY: help bootstrap build test lint check services smoke smoke-toolchain smoke-services
.PHONY: $(SERVICE_TARGETS) $(SMOKE_SERVICE_TARGETS)

help:
	@echo "bootstrap                       install the pinned WASIX toolchain into work/toolchains"
	@echo "services                        build every service version into work/services"
	@echo "service-<name>-<version>        build one service version"
	@echo "smoke                           run every smoke test"
	@echo "smoke-toolchain                 build and run the toolchain smoke test"
	@echo "smoke-services                  smoke-test every built service version"
	@echo "smoke-service-<name>-<version>  smoke-test one service version"
	@echo "build                           cargo build"
	@echo "test                            cargo test"
	@echo "lint                            cargo fmt --check and cargo clippy"
	@echo "check                           lint, test and smoke-toolchain"

bootstrap:
	toolchain/bootstrap.sh --all

smoke-toolchain:
	toolchain/bootstrap.sh --all --check

build:
	cargo build --workspace

test:
	cargo test --workspace

lint:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings

check: lint test smoke-toolchain

services: $(SERVICE_TARGETS)

smoke: smoke-toolchain smoke-services

smoke-services: $(SMOKE_SERVICE_TARGETS)

define service_version_rules
service-$(1)-$(2):
	services/$(1)/build.sh $(2)

smoke-service-$(1)-$(2):
	services/$(1)/smoke/smoke.sh $(2)
endef

$(foreach file,$(SERVICE_VERSION_FILES),$(eval $(call service_version_rules,$(word 2,$(subst /, ,$(file))),$(word 4,$(subst /, ,$(file))))))

# Entry points for every workflow. Targets call scripts and contain no logic;
# every script runs on its own.

.DEFAULT_GOAL := help

SERVICE_VERSION_FILES := $(wildcard services/*/versions/*/version.env)
SERVICE_TARGETS := $(foreach file,$(SERVICE_VERSION_FILES),service-$(word 2,$(subst /, ,$(file)))-$(word 4,$(subst /, ,$(file))))
SMOKE_SERVICE_TARGETS := $(addprefix smoke-,$(SERVICE_TARGETS))
CLEAN_SERVICE_TARGETS := $(addprefix clean-,$(SERVICE_TARGETS))
PURGE_SERVICE_TARGETS := $(addprefix purge-,$(SERVICE_TARGETS))
RUN_SERVICE_TARGETS := $(addprefix run-,$(SERVICE_TARGETS))

.PHONY: help bootstrap setup-wasmer build test lint check services services-list smoke smoke-toolchain smoke-services lifecycle-tests lifecycle-tests-long lifecycle-tests-release lifecycle-tests-long-release
.PHONY: clean clean-services clean-wasmer clean-wasix-libc purge
.PHONY: $(SERVICE_TARGETS) $(SMOKE_SERVICE_TARGETS) $(CLEAN_SERVICE_TARGETS) $(PURGE_SERVICE_TARGETS) $(RUN_SERVICE_TARGETS)

help:
	@echo "bootstrap                       install the pinned WASIX toolchain into work/toolchains"
	@echo "services                        build every service version into work/services"
	@echo "service-<name>-<version>        bootstrap if needed, then build one service version"
	@echo "smoke                           run every smoke test"
	@echo "smoke-toolchain                 build and run the toolchain smoke test"
	@echo "smoke-services                  smoke-test every built service version"
	@echo "smoke-service-<name>-<version>  build if needed, then smoke-test one service version"
	@echo "setup-wasmer                    check out the pinned Wasmer into work/wasmer and apply patches/wasmer"
	@echo "build                           setup-wasmer, then cargo build"
	@echo "test                            setup-wasmer, then cargo test"
	@echo "lint                            setup-wasmer, then cargo fmt --check and cargo clippy"
	@echo "lifecycle-tests                 freeze and fork every built service through the host (quick matrix)"
	@echo "lifecycle-tests-long            the same with thousands of forks"
	@echo "lifecycle-tests-release         the quick matrix on a release build, for latency figures"
	@echo "lifecycle-tests-long-release    the long matrix on a release build"
	@echo "services-list                   list services assembled under work/services"
	@echo "run-service-<name>-<version>    run one service through a host and print its endpoint; RECIPE=<file> feeds the initializer, CLONES=<n> forks clones on Enter"
	@echo "check                           lint, test and smoke-toolchain"
	@echo "clean                           remove build outputs: every service, cargo, the toolchain smoke"
	@echo "clean-services                  remove every service's build and output; keep source checkouts"
	@echo "clean-wasmer                    reset work/wasmer to the pristine tag so setup-wasmer re-applies the series"
	@echo "clean-wasix-libc                reset work/wasix-libc to the pristine tag so bootstrap re-applies the series"
	@echo "clean-service-<name>-<version>  the same for one service version"
	@echo "purge-service-<name>-<version>  also remove its source checkout"
	@echo "purge                           remove work/ and target/ entirely, including the toolchain"

bootstrap:
	toolchain/bootstrap.sh --all

smoke-toolchain: bootstrap
	toolchain/bootstrap.sh --all --check

setup-wasmer:
	scripts/setup-wasmer

build: setup-wasmer
	cargo build --workspace

test: setup-wasmer
	cargo test --workspace

lint: setup-wasmer
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	! grep -rniE 'mysql|valkey|beanstalkd' crates/servicecache

check: lint test smoke-toolchain

lifecycle-tests: setup-wasmer
	SERVICECACHE_LIFECYCLE=quick cargo test --test lifecycle -- --nocapture

lifecycle-tests-long: setup-wasmer
	SERVICECACHE_LIFECYCLE=long cargo test --test lifecycle -- --nocapture

lifecycle-tests-release: setup-wasmer
	SERVICECACHE_LIFECYCLE=quick cargo test --release --test lifecycle -- --nocapture

lifecycle-tests-long-release: setup-wasmer
	SERVICECACHE_LIFECYCLE=long cargo test --release --test lifecycle -- --nocapture

services-list:
	SERVICECACHE_SERVICES_DIR=work/services cargo run -- services list

clean: clean-services
	cargo clean
	rm -rf work/build/toolchain-smoke

clean-services: $(CLEAN_SERVICE_TARGETS)

clean-wasmer:
	git -C work/wasmer checkout --quiet -- . && git -C work/wasmer clean --quiet -fdx

clean-wasix-libc:
	git -C work/wasix-libc checkout --quiet -- . && git -C work/wasix-libc clean --quiet -fdx

purge:
	rm -rf work target

services: $(SERVICE_TARGETS)

smoke: smoke-toolchain smoke-services

smoke-services: $(SMOKE_SERVICE_TARGETS)

define service_version_rules
service-$(1)-$(2): bootstrap
	services/$(1)/build.sh $(2)

work/services/$(1)-$(2)/BUILD-INFO: services/$(1)/build.sh services/$(1)/service.toml \
    $$(wildcard services/$(1)/deps.sh) services/$(1)/versions/$(2)/version.env \
    $$(shell find services/$(1)/versions/$(2)/patches -type f) | bootstrap
	services/$(1)/build.sh $(2)

smoke-service-$(1)-$(2): work/services/$(1)-$(2)/BUILD-INFO
	services/$(1)/smoke/smoke.sh $(2)

run-service-$(1)-$(2): work/services/$(1)-$(2)/BUILD-INFO | setup-wasmer
	SERVICECACHE_SERVICES_DIR=work/services cargo run --release -- run $(1)@$(2) $$(if $$(RECIPE),--recipe $$(RECIPE)) $$(if $$(CLONES),--clones $$(CLONES))

clean-service-$(1)-$(2):
	toolchain/clean.sh $(1) $(2)

purge-service-$(1)-$(2):
	toolchain/clean.sh --sources $(1) $(2)
endef

$(foreach file,$(SERVICE_VERSION_FILES),$(eval $(call service_version_rules,$(word 2,$(subst /, ,$(file))),$(word 4,$(subst /, ,$(file))))))

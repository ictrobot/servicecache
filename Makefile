# Entry points for every workflow. Targets call scripts and contain no logic;
# every script runs on its own.

.DEFAULT_GOAL := help

# One interpreter for every Python the tooling runs, checked once here and
# exported so that scripts and sub-makes inherit it. sc_python in lib.sh
# reports on standard error if the selected interpreter is unavailable or too old.
SC_PYTHON := $(shell bash -c 'source toolchain/lib.sh && sc_python')
ifeq ($(SC_PYTHON),)
$(error Python 3.11 or newer is required; set SC_PYTHON to the interpreter to use)
endif
export SC_PYTHON

SERVICE_VERSION_FILES := $(wildcard services/*/versions/*/version.nix)
SERVICE_TARGETS := $(foreach file,$(SERVICE_VERSION_FILES),service-$(word 2,$(subst /, ,$(file)))-$(word 4,$(subst /, ,$(file))))
SOURCE_TAR_BUILD_TARGETS := $(addsuffix -from-source-tar,$(SERVICE_TARGETS))
SMOKE_SERVICE_TARGETS := $(addprefix smoke-,$(SERVICE_TARGETS))
CLEAN_SERVICE_TARGETS := $(addprefix clean-,$(SERVICE_TARGETS))
RUN_TARGETS := $(patsubst service-%,run-%,$(SERVICE_TARGETS))
REQUEST_TARGETS := $(patsubst service-%,request-%,$(SERVICE_TARGETS))
LIFECYCLE_SERVICE_TARGETS := $(addprefix lifecycle-,$(SERVICE_TARGETS))
# Per-name aggregates that fan out to every installed version of a service.
SERVICE_NAMES := $(sort $(foreach file,$(SERVICE_VERSION_FILES),$(word 2,$(subst /, ,$(file)))))
SERVICE_NAME_TARGETS := $(foreach verb,service smoke-service clean-service lifecycle-service,$(addprefix $(verb)-,$(SERVICE_NAMES)))

# Wasmer variants: build, test and clean targets per wasmer/<variant>/.
WASMER_VARIANTS := $(patsubst wasmer/%/patches.list,%,$(wildcard wasmer/*/patches.list))
WASMER_TARGETS := $(addprefix wasmer-,$(WASMER_VARIANTS))
TEST_WASMER_TARGETS := $(addprefix test-wasmer-,$(WASMER_VARIANTS))
CLEAN_WASMER_TARGETS := $(addprefix clean-wasmer-,$(WASMER_VARIANTS))
EXTENSION_NAMES := $(patsubst extensions/%/smoke.sh,%,$(wildcard extensions/*/smoke.sh))
SMOKE_EXTENSION_TARGETS := $(addprefix smoke-extension-,$(EXTENSION_NAMES))

.PHONY: help setup-wasmer setup-wasmer-dev build build-release test test-python lint lint-python check serve services services-list smoke smoke-toolchain smoke-services smoke-extensions smoke-openssl lifecycle-tests lifecycle-tests-long lifecycle-tests-release lifecycle-tests-long-release
.PHONY: clean clean-services clean-wasmer purge
.PHONY: $(SOURCE_TAR_BUILD_TARGETS) $(SERVICE_TARGETS) $(SMOKE_SERVICE_TARGETS) $(CLEAN_SERVICE_TARGETS) $(RUN_TARGETS) $(REQUEST_TARGETS) $(LIFECYCLE_SERVICE_TARGETS)
.PHONY: $(SERVICE_NAME_TARGETS) $(WASMER_TARGETS) $(TEST_WASMER_TARGETS) $(CLEAN_WASMER_TARGETS) $(SMOKE_EXTENSION_TARGETS)

help:
	@echo "services                        build every service version into work/services"
	@echo "service-<name>-<version>        build through Nix and link the selected output into work/services"
	@echo "service-<name>-<version>-from-source-tar build into work/services-from-source-tar"
	@echo "smoke                           run every smoke test"
	@echo "smoke-toolchain                 build the toolchain fixtures through Nix, copy them to work/build/toolchain-smoke and run them under Wasmer"
	@echo "smoke-services                  build and smoke-test every service version"
	@echo "smoke-service-<name>-<version>  select the Nix output and smoke-test one service version"
	@echo "smoke-extensions                run every Wasmer extension's demo ($(EXTENSION_NAMES))"
	@echo "smoke-extension-<name>          build one extension's demo through Nix and run it under the extensions CLI; stock must refuse it"
	@echo "setup-wasmer                    prepare the servicecache Wasmer variant the host builds against"
	@echo "setup-wasmer-dev                put work/wasmer-dev's exported branches at the committed patch sets (clones it if missing)"
	@echo "wasmer-<variant>                build a Wasmer CLI with Nix and link it into work/wasmer/<variant> ($(WASMER_VARIANTS))"
	@echo "test-wasmer-<variant>           run the Wasmer variant's unit tests through Nix"
	@echo "build                           setup-wasmer, then cargo build"
	@echo "build-release                   setup-wasmer, then cargo build --release"
	@echo "test                            setup-wasmer, then the Python unit tests and cargo test"
	@echo "lint                            setup-wasmer, then ruff and pyright (through uv), cargo fmt --check, cargo clippy, cargo deny, the patch header checks and the flake's checks"
	@echo "lifecycle-tests                 build every service, then freeze and fork each through the host (quick matrix)"
	@echo "lifecycle-tests-long            the same plus the long cases (thousands of forks)"
	@echo "lifecycle-tests-release         the quick matrix on a release build, for latency figures"
	@echo "lifecycle-tests-long-release    the long matrix on a release build"
	@echo "lifecycle-service-<name>-<version> build if needed, then run its quick lifecycle trials"
	@echo "serve                           serve the manager's HTTP API for services under work/services (--socket/SERVICECACHE_SOCKET overrides the socket)"
	@echo "services-list                   list services assembled under work/services"
	@echo "run-<name>-<version>            run one service through a host and print its endpoint; RECIPE=<file> feeds the initializer, CLONES=<n> forks clones on Enter"
	@echo "request-<name>-<version>        request an instance from the running manager; RECIPE=<file> feeds the initializer"
	@echo "check                           lint, test and smoke-toolchain"
	@echo "clean                           remove build outputs: every service, cargo, the toolchain smoke"
	@echo "clean-services                  remove service links under work/services"
	@echo "clean-wasmer                    remove Wasmer CLI output links (also clean-wasmer-<variant>)"
	@echo "clean-service-<name>-<version>  the same for one service version"
	@echo "service-<name>                  (also smoke-/clean-/lifecycle-service-<name>) the same across every installed version"
	@echo "purge                           remove work/ and target/ entirely"

smoke-toolchain:
	toolchain/smoke/run.sh

setup-wasmer:
	wasmer/setup.sh

setup-wasmer-dev:
	wasmer/setup-dev.sh

build: setup-wasmer
	cargo build --workspace

build-release: setup-wasmer
	cargo build --release --workspace

test: setup-wasmer test-python
	cargo test --workspace

test-python:
	$(SC_PYTHON) -m unittest toolchain/guest_artifacts.py

lint: setup-wasmer lint-python
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo deny -L error --config deny.toml check licenses bans
	! grep -rniE 'mysql|mariadb|postgres|valkey|beanstalkd' crates/servicecache
	toolchain/check-patches.sh
	toolchain/nix.sh check

# The developer tools, from the locked dev group in pyproject.toml. Nothing
# a build runs needs them, or anything beyond an interpreter.
lint-python:
	uv sync --locked
	uv run ruff check .
	uv run ruff format --check .
	uv run pyright

check: lint test smoke-toolchain

lifecycle-tests: services setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --test lifecycle

lifecycle-tests-long: services setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --test lifecycle -- --include-ignored

lifecycle-tests-release: services setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --release --test lifecycle

lifecycle-tests-long-release: services setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --release --test lifecycle -- --include-ignored

serve: setup-wasmer
	SERVICECACHE_SERVICES_DIR=work/services cargo run -- serve

services-list:
	SERVICECACHE_SERVICES_DIR=work/services cargo run -- services list

clean: clean-services
	cargo clean
	rm -rf work/build/toolchain-smoke

clean-services: $(CLEAN_SERVICE_TARGETS)

clean-wasmer: $(CLEAN_WASMER_TARGETS)

purge:
	rm -rf work target

services: $(SERVICE_TARGETS)

smoke: smoke-toolchain smoke-services smoke-extensions smoke-openssl

smoke-openssl: wasmer-stock
	libs/openssl/smoke.sh

smoke-services: $(SMOKE_SERVICE_TARGETS)

smoke-extensions: $(SMOKE_EXTENSION_TARGETS)

define extension_rules
smoke-extension-$(1): wasmer-extensions wasmer-stock
	extensions/$(1)/smoke.sh
endef

$(foreach name,$(EXTENSION_NAMES),$(eval $(call extension_rules,$(name))))

define wasmer_variant_rules
wasmer-$(1):
	wasmer/build.sh $(1)

test-wasmer-$(1):
	wasmer/test.sh $(1)

clean-wasmer-$(1):
	rm -rf work/wasmer/$(1)
endef

$(foreach variant,$(WASMER_VARIANTS),$(eval $(call wasmer_variant_rules,$(variant))))

# The targets that use a built service version wait for its build target:
# Nix decides for itself whether anything needs building.
define service_version_rules
service-$(1)-$(2):
	toolchain/service.sh $(1) $(2)

service-$(1)-$(2)-from-source-tar:
	tools/build-source-tar.sh $(1) $(2)

smoke-service-$(1)-$(2): service-$(1)-$(2)
	services/$(1)/smoke/smoke.sh $(2)

run-$(1)-$(2): service-$(1)-$(2) | setup-wasmer
	SERVICECACHE_SERVICES_DIR=work/services cargo run --release -- run $(1)@$(2) $$(if $$(RECIPE),--recipe $$(RECIPE)) $$(if $$(CLONES),--clones $$(CLONES))

request-$(1)-$(2): | setup-wasmer
	cargo run -- request $(1)@$(2) $$(if $$(RECIPE),--recipe $$(RECIPE))

lifecycle-service-$(1)-$(2): service-$(1)-$(2) | setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --test lifecycle -- '$(1)::$(2)::'

clean-service-$(1)-$(2):
	rm -rf work/services/$(1)-$(2)
endef

$(foreach file,$(SERVICE_VERSION_FILES),$(eval $(call service_version_rules,$(word 2,$(subst /, ,$(file))),$(word 4,$(subst /, ,$(file))))))

# service-<name>, smoke-service-<name>, clean-service-<name>,
# lifecycle-service-<name>: every version of that
# service. There is no run-<name>: run starts one guest. The lifecycle
# aggregate is one cargo run with a name filter, so its trials share the
# harness's parallelism.
define service_name_rules
service-$(1): $(filter service-$(1)-%,$(SERVICE_TARGETS))
smoke-service-$(1): $(filter smoke-service-$(1)-%,$(SMOKE_SERVICE_TARGETS))
clean-service-$(1): $(filter clean-service-$(1)-%,$(CLEAN_SERVICE_TARGETS))
lifecycle-service-$(1): $(filter service-$(1)-%,$(SERVICE_TARGETS)) | setup-wasmer
	SERVICECACHE_LIFECYCLE=1 cargo test --test lifecycle -- '$(1)::'
endef
$(foreach name,$(SERVICE_NAMES),$(eval $(call service_name_rules,$(name))))

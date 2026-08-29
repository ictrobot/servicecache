# Entry points for every workflow. Targets call scripts and contain no logic;
# every script runs on its own.

.DEFAULT_GOAL := help
.PHONY: help bootstrap check-toolchain build test lint check

help:
	@echo "bootstrap        install the pinned WASIX toolchain into work/toolchains"
	@echo "check-toolchain  bootstrap, then build and run the toolchain smoke test"
	@echo "build            cargo build"
	@echo "test             cargo test"
	@echo "lint             cargo fmt --check and cargo clippy"
	@echo "check            lint, test and check-toolchain"

bootstrap:
	toolchain/bootstrap.sh --all

check-toolchain:
	toolchain/bootstrap.sh --all --check

build:
	cargo build --workspace

test:
	cargo test --workspace

lint:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings

check: lint test check-toolchain

.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e pilot benchmark-pin28

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, pilot, benchmark-pin28, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

pilot:
	@test -n "$$SYMPHONY_LIVE_PULL_REQUEST_URL" || (echo "SYMPHONY_LIVE_PULL_REQUEST_URL is required" >&2; exit 2)
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs --only pin18_pilot

benchmark-pin28:
	$(MIX) symphony.benchmark.pin28 --check

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci

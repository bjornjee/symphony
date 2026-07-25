.PHONY: symphony-workflow symphony-workflow-check symphony-run symphony-up \
	symphony-status symphony-logs symphony-restart symphony-down

PORT ?= 4000
CA_BUNDLE ?= /etc/ssl/cert.pem

SYMPHONY_MANIFEST := workflow-manifest.yml
SYMPHONY_WORKFLOW := workflows/symphony/workflow.md
CA_BUNDLE_PATH := $(abspath $(CA_BUNDLE))

symphony-workflow:
	cd elixir && mise exec -- mix workflow.bootstrap --manifest ../$(SYMPHONY_MANIFEST)

symphony-workflow-check:
	cd elixir && mise exec -- mix workflow.bootstrap --manifest ../$(SYMPHONY_MANIFEST) --check

symphony-run:
	@PORT="$(PORT)" CA_BUNDLE="$(CA_BUNDLE_PATH)" SYMPHONY_WORKFLOW="$(SYMPHONY_WORKFLOW)" \
		./bin/symphony-service run

symphony-up:
	@PORT="$(PORT)" CA_BUNDLE="$(CA_BUNDLE_PATH)" SYMPHONY_WORKFLOW="$(SYMPHONY_WORKFLOW)" \
		./bin/symphony-service up

symphony-status:
	@PORT="$(PORT)" ./bin/symphony-service status

symphony-logs:
	@PORT="$(PORT)" ./bin/symphony-service logs

symphony-restart:
	@PORT="$(PORT)" CA_BUNDLE="$(CA_BUNDLE_PATH)" SYMPHONY_WORKFLOW="$(SYMPHONY_WORKFLOW)" \
		./bin/symphony-service restart

symphony-down:
	@PORT="$(PORT)" ./bin/symphony-service down

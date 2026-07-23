.PHONY: symphony-workflow symphony-workflow-check symphony-run

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
	@test -f .env || { echo "error: .env is missing; create it with LINEAR_API_KEY" >&2; exit 1; }
	@test -f "$(CA_BUNDLE_PATH)" || { echo "error: CA bundle $(CA_BUNDLE_PATH) is missing; override CA_BUNDLE=/path/to/cert.pem" >&2; exit 1; }
	@test -f "$(SYMPHONY_WORKFLOW)" || { echo "error: $(SYMPHONY_WORKFLOW) is missing; run make symphony-workflow" >&2; exit 1; }
	@unset LINEAR_API_KEY; set -a; . ./.env; set +a; \
	test -n "$${LINEAR_API_KEY:-}" || { echo "error: .env must set LINEAR_API_KEY" >&2; exit 1; }; \
	cd elixir; \
	ERL_AFLAGS="$${ERL_AFLAGS:+$${ERL_AFLAGS} }-eval 'public_key:cacerts_load(\"$(CA_BUNDLE_PATH)\").'" \
	exec mise exec -- ./bin/symphony \
		--i-understand-that-this-will-be-running-without-the-usual-guardrails \
		--port "$(PORT)" \
		"../$(SYMPHONY_WORKFLOW)"

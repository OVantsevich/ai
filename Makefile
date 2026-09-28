COMPOSE := docker compose -f platform/deploy/docker-compose.yaml --env-file platform/deploy/.env
ENV_FILE := platform/deploy/.env

.DEFAULT_GOAL := help

.PHONY: help init up down restart ps logs pull memory-push check-protocol db-apply db-shell

help: ## Show available commands
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## Create .env from example and local data directories
	@test -f $(ENV_FILE) || (cp platform/deploy/.env.example $(ENV_FILE) && echo "Created $(ENV_FILE): fill in the values")
	@grep -q '^GITLAB_MCP_AUTH_TOKEN=.' $(ENV_FILE) || { \
		sed -i '/^GITLAB_MCP_AUTH_TOKEN=/d' $(ENV_FILE); \
		echo "GITLAB_MCP_AUTH_TOKEN=$$(openssl rand -hex 24)" >> $(ENV_FILE); }
	@mkdir -p data/memory data/workspaces data/logs

up: init ## Start the platform
	$(COMPOSE) up -d

down: ## Stop the platform
	$(COMPOSE) down

restart: ## Restart the platform
	$(COMPOSE) restart

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Follow logs (make logs s=n8n for one service)
	$(COMPOSE) logs -f --tail=100 $(s)

pull: ## Pull fresh images
	$(COMPOSE) pull

check-protocol: ## Validate protocol examples against schemas
	docker run --rm -v $(CURDIR)/platform/protocol:/protocol:ro python:3.12-alpine \
		sh -c "pip install -q --disable-pip-version-check --root-user-action=ignore jsonschema && python /protocol/validate.py"

db-apply: ## Apply SQL schema to the running postgres (idempotent)
	@for f in platform/deploy/postgres/init/*.sql; do \
		echo "apply $$f"; \
		$(COMPOSE) exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -q -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"' < $$f || exit 1; \
	done

db-shell: ## Open psql in the platform database
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

memory-push: ## Push role memory (data/memory) to its remote
	@test -d data/memory/.git || (echo "data/memory is not a git repository yet" && exit 1)
	git -C data/memory push

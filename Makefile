COMPOSE := docker compose -f platform/deploy/docker-compose.yaml --env-file platform/deploy/.env
ENV_FILE := platform/deploy/.env

.DEFAULT_GOAL := help

.PHONY: help init up down restart ps logs pull memory-push

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

memory-push: ## Push role memory (data/memory) to its remote
	@test -d data/memory/.git || (echo "data/memory is not a git repository yet" && exit 1)
	git -C data/memory push

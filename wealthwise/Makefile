.DEFAULT_GOAL := help
.PHONY: help setup up down reset logs ps smoke test api-test web-build dev-lite-api dev-lite-web k8s-setup k8s-up k8s-deploy k8s-status k8s-logs k8s-smoke k8s-down

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup: ## Install .NET, Node and check Docker in WSL (idempotent)
	bash scripts/setup-wsl.sh

up: ## Build and start the whole stack (web :4200, gateway :8800, api :5080)
	docker compose up -d --build
	@echo "Open http://localhost:4200"

down: ## Stop the stack (keeps data)
	docker compose down

reset: ## Stop and delete all data volumes
	docker compose down -v

logs: ## Tail logs
	docker compose logs -f --tail=100

ps: ## Show container status
	docker compose ps

smoke: ## End-to-end check through gateway: auth, list, trade, queue->audit
	bash scripts/smoke.sh

test: api-test web-build ## Run backend tests and build the frontend

api-test: ## xUnit: domain + API integration tests (no Docker needed)
	dotnet test api/WealthWise.slnx

web-build: ## Production build of the Angular app
	cd web && npm ci && npm run build

dev-lite-api: ## API only, in-memory DB, no Docker (http://localhost:5080)
	Database__Provider=InMemory dotnet run --project api/src/WealthWise.Api --urls http://localhost:5080

dev-lite-web: ## Angular dev server proxied straight to the lite API
	cd web && npm install && npm run start:lite

k8s-setup: ## Install kubectl and kind (no sudo)
	bash scripts/setup-k8s.sh

k8s-up: ## Create kind cluster, ingress, build+load images, deploy -> http://localhost:8080
	bash scripts/k8s.sh up

k8s-deploy: ## Rebuild images and roll out after code changes
	bash scripts/k8s.sh deploy

k8s-status: ## Pods, services, ingress
	bash scripts/k8s.sh status

k8s-logs: ## Tail logs (make k8s-logs APP=kong)
	bash scripts/k8s.sh logs $(or $(APP),api)

k8s-smoke: ## End-to-end check against the cluster via a port-forward to Kong
	bash scripts/k8s.sh smoke

k8s-down: ## Delete the kind cluster
	bash scripts/k8s.sh down

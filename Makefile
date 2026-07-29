SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --warn-undefined-variables --no-print-directory

.PHONY: help lint secrets clean

help: ## affiche cette aide
	@grep -E "^[a-zA-Z_-]+:.*## " $(MAKEFILE_LIST) | sed "s/:.*## /\t/"

lint: ## hygiene + lint : rejoue les hooks pre-commit sur tout le depot
	pre-commit run --all-files

secrets: ## scan des secrets sur tout l historique (gitleaks)
	gitleaks detect --source . --verbose

clean: ## supprime les artefacts locaux (sans echouer si absents)
	rm -rf .terraform */.terraform *.tfplan out

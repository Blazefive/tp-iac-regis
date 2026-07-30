SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --warn-undefined-variables --no-print-directory

# Dedicated AWS profile, so the machine default profile is left alone.
AWS_PROFILE ?= tp2
export AWS_PROFILE

ROOT    := envs/dev-aws
TF      := terraform -chdir=$(ROOT)
PLAN    := dev.tfplan
BACKEND := $(ROOT)/backend.hcl
STATE   := dev-aws/terraform.tfstate

# Must match `project` and `region` in $(ROOT)/terraform.tfvars.
PROJECT := tp-iac-regis
REGION  := eu-west-3

# Read from backend.hcl rather than hardcoded: the bucket name embeds the AWS
# account id and this repository is public.
BUCKET := $(shell awk -F'"' '/bucket/ {print $$2}' $(BACKEND) 2>/dev/null)

.PHONY: help lint secrets clean ip check-backend bootstrap init fmt validate \
        plan apply drift state destroy teardown leftovers

help: ## list available targets
	@grep -E "^[a-zA-Z_-]+:.*## " $(MAKEFILE_LIST) | sed "s/:.*## /\t/"

# ---- Repository hygiene (lab 1) ---------------------------------------------

lint: ## run every pre-commit hook over the whole repository
	pre-commit run --all-files

secrets: ## scan the full history for secrets (gitleaks)
	gitleaks detect --source . --verbose

clean: ## remove local artefacts, without failing if absent
	rm -rf .terraform envs/*/.terraform envs/*/*.tfplan out

# ---- Part A: foundation and remote state ------------------------------------

ip: ## print your public IP as a /32, for admin_cidr
	@printf '%s/32\n' "$$(curl -s https://checkip.amazonaws.com)"

check-backend:
	@test -f $(BACKEND) \
	  || { printf 'missing %s -- run: make bootstrap\n' "$(BACKEND)"; exit 1; }

bootstrap: ## create the S3 state bucket: versioning, public access blocked, encrypted
	@set -eu; \
	account="$$(aws sts get-caller-identity --query Account --output text)"; \
	bucket="$(PROJECT)-tfstate-$$account"; \
	aws s3api create-bucket --bucket "$$bucket" --region $(REGION) \
	  --create-bucket-configuration LocationConstraint=$(REGION) >/dev/null 2>&1 \
	  || printf 'bucket %s already exists, reapplying settings\n' "$$bucket"; \
	aws s3api put-bucket-versioning --bucket "$$bucket" \
	  --versioning-configuration Status=Enabled; \
	aws s3api put-public-access-block --bucket "$$bucket" \
	  --public-access-block-configuration \
	  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true; \
	aws s3api put-bucket-encryption --bucket "$$bucket" \
	  --server-side-encryption-configuration \
	  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'; \
	printf 'bucket = "%s"\n' "$$bucket" >$(BACKEND); \
	printf '\n%s is ready, %s written (git-ignored).\nNext: make init\n' "$$bucket" "$(BACKEND)"

init: check-backend ## initialise the root module on the S3 backend
	$(TF) init -backend-config=backend.hcl -input=false

# ---- Part B: deployment -----------------------------------------------------

fmt: ## rewrite all HCL in canonical format
	terraform fmt -recursive

validate: ## check syntax and internal consistency
	$(TF) validate

plan: ## compute and save the plan -- CHANGES NOTHING
	$(TF) plan -out=$(PLAN) -input=false

apply: ## apply EXACTLY the saved and reviewed plan
	$(TF) apply $(PLAN)

# ---- Part D: drift, state, teardown -----------------------------------------

drift: ## inject drift: open SSH to 0.0.0.0/0 outside Terraform
	aws ec2 authorize-security-group-ingress \
	  --group-id "$$($(TF) output -raw security_group_id)" \
	  --protocol tcp --port 22 --cidr 0.0.0.0/0
	@printf '\ndrift in place. Next: make plan\n'

state: check-backend ## list the state, then the sensitive data it holds
	$(TF) state list
	@printf '\n-- what the tfstate reveals --\n'
	@aws s3 cp s3://$(BUCKET)/$(STATE) - \
	  | jq -r '.resources[] | select(.type=="aws_instance") | .instances[0].attributes
	      | "user_data : \(.user_data[0:50])...",
	        "private ip: \(.private_ip)",
	        "public ip : \(.public_ip)"'
	@aws s3 cp s3://$(BUCKET)/$(STATE) - \
	  | jq -r '.resources[] | select(.type=="aws_security_group") | .instances[0].attributes.ingress[]
	      | "rule      : \(.from_port)/\(.protocol) from \(.cidr_blocks|join(","))"'

destroy: ## destroy the eight resources
	$(TF) destroy

teardown: check-backend ## delete the state bucket -- AFTER destroy, never before
	@set -eu; \
	for key in Versions DeleteMarkers; do \
	  payload="$$(aws s3api list-object-versions --bucket $(BUCKET) --output json \
	    --query "{Objects:($$key[]||\`[]\`)[].{Key:Key,VersionId:VersionId}}")"; \
	  case "$$payload" in *'"Objects": []'*|*'"Objects":[]'*) continue;; esac; \
	  aws s3api delete-objects --bucket $(BUCKET) --delete "$$payload" >/dev/null; \
	done; \
	aws s3api delete-bucket --bucket $(BUCKET) --region $(REGION); \
	rm -f $(BACKEND); \
	printf '%s deleted\n' "$(BUCKET)"

# The training AWS account is SHARED: every lookup filters on the Project tag,
# so it can never point at - let alone delete - a classmate's resource.
leftovers: ## find MY forgotten billable resources
	@printf -- '-- instances --\n'
	@aws ec2 describe-instances --filters "Name=tag:Project,Values=$(PROJECT)" \
	  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
	  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
	@printf -- '-- unattached volumes --\n'
	@aws ec2 describe-volumes --filters "Name=tag:Project,Values=$(PROJECT)" \
	  "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text
	@printf -- '-- unassociated elastic IPs --\n'
	@aws ec2 describe-addresses --filters "Name=tag:Project,Values=$(PROJECT)" \
	  --query 'Addresses[?AssociationId==null].PublicIp' --output text
	@printf -- '-- VPCs --\n'
	@aws ec2 describe-vpcs --filters "Name=tag:Project,Values=$(PROJECT)" \
	  --query 'Vpcs[].VpcId' --output text
	@printf '\n(no line above means nothing billable for %s)\n' "$(PROJECT)"

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --warn-undefined-variables --no-print-directory

# A dedicated AWS profile on a workstation, so the machine default profile is
# left alone.
#
# NOT exported when AWS_ACCESS_KEY_ID is already in the environment. A CI runner
# authenticates with key variables and has no ~/.aws/credentials, so exporting
# AWS_PROFILE there makes the provider look for a profile that does not exist
# and fail with "failed to get shared config profile, tp2" - before creating
# anything, but also before doing anything useful.
ifndef AWS_ACCESS_KEY_ID
AWS_PROFILE ?= tp2
export AWS_PROFILE
endif

ROOT        := envs/dev-aws
TF          := terraform -chdir=$(ROOT)
PLAN        := dev.tfplan
BACKEND     := $(ROOT)/backend.hcl
STATE_KEY   := dev-aws/terraform.tfstate
REGION      ?= eu-west-3
PROJECT     ?= tp-iac-regis

ANSIBLE_DIR := ansible
INVENTORY   := $(ANSIBLE_DIR)/inventory.generated.ini
PLAYBOOK    ?= yoxii.yml

# One variable drives BOTH the reachability probe and ansible-playbook. It was
# hardcoded at first, and the local run failed on step 4 while CI would have
# passed - the worst kind of bug, one that only appears off the golden path.
#   CI    : the secret is written to this default path.
#   local : make configure SSH_KEY=~/.ssh/tp2_ed25519
SSH_KEY     ?= $(HOME)/.ssh/id_ed25519

# Read from backend.hcl rather than hardcoded: the bucket name embeds the AWS
# account id and this repository is public.
BUCKET := $(shell awk -F'"' '/bucket/ {print $$2}' $(BACKEND) 2>/dev/null)

.PHONY: help lint secrets clean ip check-backend bootstrap init \
        fmt fmt-fix tflint trivy validate verify \
        plan apply inventory configure deploy \
        drift state destroy teardown leftovers

help: ## list available targets
	@grep -E "^[a-zA-Z_-]+:.*## " $(MAKEFILE_LIST) | sed "s/:.*## /\t/"

# ---- Repository hygiene (lab 1) ---------------------------------------------

lint: ## run every pre-commit hook over the whole repository
	pre-commit run --all-files

secrets: ## scan the full history for secrets (gitleaks)
	gitleaks detect --source . --verbose

clean: ## remove local artefacts, without failing if absent
	rm -rf .terraform envs/*/.terraform envs/*/*.tfplan $(INVENTORY) out

# =============================================================================
# STEP 1 - Infrastructure code validation
#
# Three gates, in this order, each failing the build on a non-zero exit:
#   fmt     formatting
#   tflint  correctness and quality
#   trivy   security misconfiguration
#
# `verify` chains them. Because .SHELLFLAGS carries -e and make stops on the
# first failing prerequisite, a red gate means nothing downstream runs - which
# is exactly the condition the assignment asks for.
# =============================================================================

fmt: ## STEP 1a - check Terraform formatting (does not rewrite)
	terraform fmt -recursive -check -diff

fmt-fix: ## rewrite Terraform in canonical format
	terraform fmt -recursive

tflint: ## STEP 1b - lint the Terraform for errors and bad practice
	@cd $(ROOT) && tflint --init >/dev/null && tflint --format compact

# .terraform and *.tfplan are excluded on purpose. With a plan file present trivy
# scans the PLAN SNAPSHOT instead of the HCL, and inline `#trivy:ignore:`
# comments - which live in the HCL - stop applying. The scan then re-reports
# exceptions that were already justified in the code, and the gate goes red for
# no reason.
trivy: ## STEP 1c - scan the Terraform for security misconfiguration
	trivy config --quiet --exit-code 1 --severity MEDIUM,HIGH,CRITICAL \
	  --skip-dirs '**/.terraform' --skip-files '**/*.tfplan' $(ROOT)

validate: ## check Terraform syntax and internal consistency
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate

verify: fmt tflint trivy ## STEP 1 - all validation gates, in order
	@printf '\n\033[32mValidations OK : fmt, tflint, trivy.\033[0m\n'

# =============================================================================
# STEP 2 - Provisioning, only once STEP 1 is green
# =============================================================================

ip: ## print your public IP as a /32, for admin_cidr
	@printf '%s/32\n' "$$(curl -fsS https://checkip.amazonaws.com)"

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

plan: ## compute and save the plan -- CHANGES NOTHING
	$(TF) plan -out=$(PLAN) -input=false

apply: verify ## STEP 2 - create the instance, only if STEP 1 passed
	$(TF) plan -out=$(PLAN) -input=false
	$(TF) apply -input=false $(PLAN)

# =============================================================================
# STEP 3 - Public IP -> Ansible inventory
# =============================================================================

inventory: ## STEP 3 - read terraform output and write the Ansible inventory
	@set -eu; \
	ip="$$($(TF) output -raw instance_public_ip)"; \
	printf 'IP publique : %s\n' "$$ip"; \
	{ \
	  printf '# Generated by `make inventory` from terraform output.\n'; \
	  printf '# Do not edit: the next run overwrites it. Git-ignored.\n\n'; \
	  printf '[web]\n'; \
	  printf 'aws-web-01 ansible_host=%s\n\n' "$$ip"; \
	  printf '[web:vars]\n'; \
	  printf 'ansible_user=ubuntu\n'; \
	} >$(INVENTORY); \
	printf 'inventaire ecrit : %s\n' "$(INVENTORY)"; \
	mkdir -p ~/.ssh && chmod 700 ~/.ssh; \
	ssh-keygen -R "$$ip" >/dev/null 2>&1 || true; \
	for i in $$(seq 1 30); do \
	  ssh-keyscan -T 5 -H "$$ip" 2>/dev/null >>~/.ssh/known_hosts && break; \
	  sleep 5; \
	done; \
	printf 'cle d hote apprise (host_key_checking reste actif)\n'; \
	cat $(INVENTORY)

# =============================================================================
# STEP 4 - Configuration through Ansible
# =============================================================================

configure: ## STEP 4 - apply the playbook to the freshly created instance
	@set -eu; \
	ip="$$(awk -F= '/ansible_host/ {print $$2}' $(INVENTORY))"; \
	test -f "$(SSH_KEY)" || { printf 'cle absente : %s\n' "$(SSH_KEY)"; exit 1; }; \
	printf 'attente de SSH sur %s avec %s\n' "$$ip" "$(SSH_KEY)"; \
	for i in $$(seq 1 30); do \
	  ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$(SSH_KEY)" \
	    ubuntu@"$$ip" true 2>/dev/null && break; \
	  [ "$$i" = 30 ] && { printf 'instance injoignable apres 5 min\n'; exit 1; }; \
	  sleep 10; \
	done; \
	cd $(ANSIBLE_DIR) && ansible-playbook -i ../$(INVENTORY) --private-key "$(SSH_KEY)" $(PLAYBOOK)

deploy: apply inventory configure ## STEPS 1 to 4, end to end
	@printf '\n\033[32mPipeline complet : validations, EC2, inventaire, configuration.\033[0m\n'
	@$(TF) output

# ---- Operations --------------------------------------------------------------

drift: ## inject drift: open SSH to 0.0.0.0/0 outside Terraform
	aws ec2 authorize-security-group-ingress \
	  --group-id "$$($(TF) output -raw security_group_id)" \
	  --protocol tcp --port 22 --cidr 0.0.0.0/0
	@printf '\ndrift in place. Next: make plan\n'

state: check-backend ## list the state, then the sensitive data it holds
	$(TF) state list
	@printf '\n-- what the tfstate reveals --\n'
	@aws s3 cp s3://$(BUCKET)/$(STATE_KEY) - \
	  | jq -r '.resources[] | select(.type=="aws_instance") | .instances[0].attributes
	      | "user_data : \(.user_data[0:50])...",
	        "private ip: \(.private_ip)",
	        "public ip : \(.public_ip)"'

destroy: ## destroy everything this root module manages
	$(TF) destroy

destroy-auto: ## same, without the confirmation prompt (for CI)
	$(TF) destroy -auto-approve -input=false

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

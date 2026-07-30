# M3 lab 2 - public nginx web server, hardened, with encrypted remote state.
# One root module, one resource file: eight resources, no abstraction that does
# not serve the assignment.

terraform {
  required_version = ">= 1.10" # ephemeral values and native S3 locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # PARTIAL configuration on purpose. A backend block accepts neither variables
  # nor interpolation, so the bucket name - which carries the AWS account id -
  # cannot live in terraform.tfvars. It is supplied at init time instead:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # The bucket itself is created outside Terraform (`make bootstrap`): a root
  # module cannot manage the backend it relies on.
  backend "s3" {
    key          = "dev-aws/terraform.tfstate"
    region       = "eu-west-3" # must be a literal, hence duplicated from var.region
    encrypt      = true        # server-side encryption enforced on write
    use_lockfile = true        # native S3 locking - defaults to FALSE
  }
}

provider "aws" {
  region = var.region

  # Every resource inherits these tags, including the ones we would forget. The
  # training account is shared between students: without Project and Owner,
  # nobody can tell who a resource belongs to.
  default_tags {
    tags = local.tags
  }
}

locals {
  prefix = "${var.project}-dev"

  tags = {
    Project     = var.project
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# --------------------------------------------------------------- Networking ---

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.prefix}-igw" }
}

# On AWS a subnet lives in exactly ONE availability zone: high availability is
# written into the topology, not into the resource.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}${var.availability_zone_suffix}"
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${var.availability_zone_suffix}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------ Security group --
#
# Rules are written as INLINE `ingress` blocks, deliberately. With separate
# resources (aws_vpc_security_group_ingress_rule), a rule added by hand in the
# console is an UNMANAGED object: Terraform never sees it and reports no drift,
# which makes part D of the assignment impossible.
#
# Ports and protocols stay hardcoded: they are the definition of the service,
# not a setting. Same for the hardening below - see variables.tf.
#
# AWS restricts descriptions to ^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$ - no
# apostrophe, no accent.

resource "aws_security_group" "web" {
  name        = "${local.prefix}-web"
  description = "Public HTTP - SSH restricted to the admin host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from the Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from the single allowed address"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "Unrestricted egress (package updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-sg-web" }
}

# ---------------------------------------------------------------- Instance ----

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [var.ami_owner_id]

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }
}

# Public half only: the private key never goes through Terraform, therefore
# never through the state file.
resource "aws_key_pair" "admin" {
  key_name   = "${local.prefix}-admin"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.admin.key_name

  # ---- Hardening: hardcoded on purpose, never a variable --------------------
  # A security control exposed as a variable becomes optional, and an optional
  # control with an unsafe provider default is exactly the root cause the course
  # documents (Saltzer & Schroeder, fail-safe defaults).

  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2 enforced. This attribute has NO safe default: the AWS default is
    # still "optional". Capital One, March 2019.
    http_tokens = "required"

    # A single network hop: blocks relaying through a reverse proxy or a poorly
    # isolated container. Raise to 2 only when running containers.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true # never a variable, see above
    volume_type = var.root_volume_type
    volume_size = var.root_volume_size_gb
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends nginx
    echo "<h1>${local.prefix} - deployed by Terraform</h1>" >/var/www/html/index.html
    systemctl enable --now nginx
  EOT

  # Without this line, changing user_data changes NOTHING on a running instance:
  # the script only runs on first boot, so the plan is green while the machine
  # keeps the old configuration. Set to true, the instance is replaced instead -
  # the immutable model.
  user_data_replace_on_change = true

  tags = { Name = "${local.prefix}-web" }
}

# Assertion re-evaluated on every plan and apply, after the state refresh: this
# is the drift detector for part D. It warns without blocking.
check "ssh_never_open_to_the_world" {
  assert {
    condition = !contains(
      flatten([
        for rule in aws_security_group.web.ingress :
        rule.cidr_blocks if rule.from_port <= 22 && rule.to_port >= 22
      ]),
      "0.0.0.0/0"
    )
    error_message = "SECURITY DRIFT: port 22 is reachable from 0.0.0.0/0."
  }
}

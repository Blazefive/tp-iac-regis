# Public web server, hardened, with encrypted remote state.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: a backend block accepts no variables, and the bucket
  # name carries the AWS account id. Supplied at init time via backend.hcl.
  backend "s3" {
    key          = "dev-aws/terraform.tfstate"
    region       = "eu-west-3" # literal required, hence duplicated from var.region
    encrypt      = true
    use_lockfile = true # native S3 locking, defaults to false
  }
}

provider "aws" {
  region = var.region

  # The training account is shared: without Project and Owner, nobody can tell
  # who a resource belongs to.
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

# Read, not created: the shared account is at its quota of 5 VPCs and every
# other region is denied by IAM. Consequence: destroy cannot remove them, which
# is correct since they were never ours.
data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

# AWS-0164, public IP on the subnet: this instance exists to serve a public
# application. The alternative - private subnet plus NAT gateway - costs about
# 35 USD a month. Compensated by restricted SSH, IMDSv2 and narrowed egress.
#trivy:ignore:AWS-0164:exp:2026-12-31
resource "aws_subnet" "public" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}${var.availability_zone_suffix}"
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${var.availability_zone_suffix}" }

  lifecycle {
    precondition {
      # Naming the problem beats surfacing InvalidSubnet.Range. No cidrcontains()
      # in Terraform 1.15: mask the subnet base with the VPC prefix length and it
      # must give the VPC base back.
      condition = cidrhost(
        "${cidrhost(var.public_subnet_cidr, 0)}/${split("/", data.aws_vpc.main.cidr_block)[1]}", 0
      ) == cidrhost(data.aws_vpc.main.cidr_block, 0)

      error_message = "public_subnet_cidr must sit inside the VPC range ${data.aws_vpc.main.cidr_block}."
    }
  }
}

# Our own table: editing the VPC main one would change routing for other
# people's subnets.
resource "aws_route_table" "public" {
  vpc_id = data.aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.main.id
  }

  tags = { Name = "${local.prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------ Security group --
#
# Inline ingress blocks, not separate rule resources: a rule added by hand in
# the console would otherwise be unmanaged, and Terraform would report no drift.
#
# Descriptions must match ^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$ - no accent.

# AWS-0104, unrestricted egress: the ports are already narrowed below; what
# remains is the destination, and no package mirror publishes a stable address
# range. Closing it properly needs an outbound proxy or VPC endpoints.
#trivy:ignore:AWS-0104:exp:2026-12-31
resource "aws_security_group" "web" {
  name        = "${local.prefix}-web"
  description = "Public HTTP - SSH restricted to the admin host"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "HTTP from the allowed source"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    # coalesce, not a hardcoded 0.0.0.0/0: left unset, the service is reachable
    # only from the administration address.
    cidr_blocks = [coalesce(var.http_cidr, var.admin_cidr)]
  }

  ingress {
    description = "SSH from the single allowed address"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Public game port"
    from_port   = var.game_port
    to_port     = var.game_port
    protocol    = "tcp"
    cidr_blocks = [coalesce(var.game_cidr, var.admin_cidr)]
  }

  # Egress narrowed to what the machine needs, instead of the usual protocol
  # "-1" on every port: no arbitrary outbound port for a reverse shell.

  egress {
    description = "HTTPS out: package repositories and PyPI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP out: package repositories still serving plain HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS over UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS over TCP, for answers too large for UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "NTP, without which the clock drifts and TLS starts failing"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
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

  # Hardening below is hardcoded, never a variable: an optional control with an
  # unsafe provider default is how misconfiguration gets industrialised.

  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2. No safe default: the AWS default is still "optional".
    http_tokens = "required"

    # One hop: blocks relaying through a reverse proxy or a weakly isolated
    # container. Raise to 2 only when running containers.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
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

    # Authorise the Ansible control node. Terraform gets the host serving;
    # Ansible takes over from there.
    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    printf '%s\n' '${var.ansible_control_public_key}' >>/home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys
  EOT

  # Without this, editing user_data changes nothing on a running instance: the
  # script only runs on first boot, so the plan is green while the machine keeps
  # the old configuration. Replaced instead - the immutable model.
  user_data_replace_on_change = true

  # Tag values accept Unicode, unlike security group descriptions.
  tags = { Name = var.instance_name }
}

# Re-evaluated on every plan and apply, after the state refresh: the drift
# detector. Warns without blocking.
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

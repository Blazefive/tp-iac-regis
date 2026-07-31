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
#
# The VPC and its internet gateway are READ, not created.
#
# Why: the training AWS account is shared, and eu-west-3 sits at its quota of 5
# VPCs, all belonging to other students. Every other region is refused by an
# explicit deny in the account IAM policy, so there is nowhere else to go.
# Deleting someone else's VPC to make room is not an option.
#
# What this costs: the root module no longer owns the VPC or the gateway, so
# `terraform destroy` cannot remove them - which is correct, they were never
# ours. Everything else stays managed: subnet, route table, association,
# security group, key pair, instance.

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

# On AWS a subnet lives in exactly ONE availability zone: high availability is
# written into the topology, not into the resource.
# trivy AWS-0164 "subnet associates public IP address" is acknowledged. The whole
# point of this instance is to serve a public web application, so it needs an
# address the public can reach. The alternative - private subnet, NAT gateway,
# load balancer - is correct architecture and costs about 35 USD a month for the
# NAT alone, which is not what a lab account is for.
#
# What compensates: SSH is restricted to one /32, IMDSv2 is enforced, egress is
# narrowed to four ports, and the root volume is encrypted.
#trivy:ignore:AWS-0164:exp:2026-12-31
resource "aws_subnet" "public" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}${var.availability_zone_suffix}"
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${var.availability_zone_suffix}" }

  lifecycle {
    precondition {
      # AWS rejects an out-of-range subnet anyway, but failing here names the
      # problem instead of surfacing InvalidSubnet.Range. Getting this wrong in a
      # VPC shared with the rest of the class is a real incident.
      #
      # There is no cidrcontains() in Terraform 1.15 - it is an OpenTofu
      # function. Equivalent with core functions: mask the subnet base address
      # with the VPC prefix length and it must give the VPC base address back.
      condition = cidrhost(
        "${cidrhost(var.public_subnet_cidr, 0)}/${split("/", data.aws_vpc.main.cidr_block)[1]}", 0
      ) == cidrhost(data.aws_vpc.main.cidr_block, 0)

      error_message = "public_subnet_cidr must sit inside the VPC range ${data.aws_vpc.main.cidr_block}."
    }
  }
}

# Our own route table rather than the VPC main one: the default route table is
# shared with every other subnet in this VPC, so editing it would change routing
# for other people's instances.
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

# trivy AWS-0104 "unrestricted egress to any IP address" is acknowledged, not
# silenced. The ports are already narrowed to 443, 80, 53 and 123; what remains
# is the DESTINATION, and no Ubuntu mirror publishes a stable address
# range to allowlist. Closing this properly means an outbound proxy or VPC
# endpoints - the right answer in production, out of scope for a lab.
#
# The expiry date is deliberate: an exception without one is a permanent hole
# that nobody revisits.
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
    # coalesce, not a hardcoded 0.0.0.0/0: with http_cidr left unset the service
    # is reachable only from the administration address. See variables.tf.
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

  # Egress is restricted to what the machine actually needs, instead of the
  # usual protocol = "-1" on every port. An instance that can only reach package
  # repositories, DNS and NTP is a poor foothold: no arbitrary outbound port for
  # a reverse shell, no exfiltration over a random high port.
  #
  # The destination still has to be 0.0.0.0/0 - nobody can allowlist every
  # Ubuntu mirror by address - which is why trivy's AWS-0104 is acknowledged
  # below rather than silenced.

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

    # Authorise the Ansible control node on the default user. Terraform creates
    # the host and gets it serving; Ansible takes over from there. Without this
    # the instance is unreachable to configuration management, and the only way
    # in is the operator laptop -- which does not scale and is not auditable.
    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    printf '%s\n' '${var.ansible_control_public_key}' >>/home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys
  EOT

  # Without this line, changing user_data changes NOTHING on a running instance:
  # the script only runs on first boot, so the plan is green while the machine
  # keeps the old configuration. Set to true, the instance is replaced instead -
  # the immutable model.
  user_data_replace_on_change = true

  # Tag VALUES accept Unicode, unlike security group descriptions, which AWS
  # restricts to ^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$ - no accent, no
  # apostrophe. So the accented name is fine here and would be rejected there.
  tags = { Name = var.instance_name }
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

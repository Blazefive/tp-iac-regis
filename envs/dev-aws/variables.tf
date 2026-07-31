# Inputs, alphabetical. Every variable has a description and a safe default,
# except admin_cidr which must be supplied.
#
# Deliberately NOT variables: root volume encryption, http_tokens, hop limit,
# and the service ports. Exposing a security control as a variable makes it
# optional, and an optional control is how misconfiguration gets industrialised.
# See main.tf.

variable "admin_cidr" {
  description = "Your public IP as a /32. The only source allowed on SSH. Get it with `make ip`."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single address in /32, not a range."
  }

  # The most common mistake in the world, and the one part D simulates.
  validation {
    condition     = !startswith(var.admin_cidr, "0.0.0.0")
    error_message = "admin_cidr must never open SSH to 0.0.0.0/0."
  }
}

variable "ansible_control_public_key" {
  description = "Public key of the Ansible control node, appended to the default user's authorized_keys so configuration management can reach the instance."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) AAAA", var.ansible_control_public_key))
    error_message = "ansible_control_public_key must be an OpenSSH public key, not a path and not a private key."
  }
}

variable "ami_name_pattern" {
  # PINNED TO AN EXACT BUILD, no trailing wildcard, on purpose.
  #
  # Two reasons, and the second one is not theoretical:
  #
  # 1. `most_recent = true` on a wildcard is non-deterministic. Canonical
  #    publishes a new image every few weeks, so the same code resolves a
  #    different AMI over time and the next plan proposes to replace the
  #    instance - a change nobody asked for.
  #
  # 2. This training account allowlists AMIs by id in its IAM policy. The
  #    wildcard resolved to the 20260714 build and RunInstances was refused with
  #    an explicit deny; 20260610 is the build every other student is running.
  #    An unpinned AMI is therefore not merely untidy here, it does not launch.
  description = "Exact AMI name. Pinned rather than a wildcard: reproducibility, and this account allowlists AMI ids."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260610"
}

variable "ami_owner_id" {
  description = "AWS account owning the AMI. 099720109477 is Canonical - never trust an unowned image."
  type        = string
  default     = "099720109477"
}

variable "availability_zone_suffix" {
  description = "Availability zone letter, appended to the region."
  type        = string
  default     = "a"

  validation {
    condition     = can(regex("^[a-c]$", var.availability_zone_suffix))
    error_message = "availability_zone_suffix must be a, b or c."
  }
}

variable "http_cidr" {
  # null means "the same as admin_cidr", i.e. restricted. That is the fail-safe
  # default: opening the service to the internet has to be written down
  # explicitly, it is never what you get by forgetting to set a value.
  #
  # What this host serves is GLPI, an administration console with well-known
  # default accounts (glpi/glpi, tech/tech...). A public website belongs on
  # 0.0.0.0/0; an admin console does not.
  description = "Source allowed on port 80. Leave null to restrict it to admin_cidr; set 0.0.0.0/0 only for a genuinely public site."
  type        = string
  default     = null

  validation {
    condition     = var.http_cidr == null || can(cidrhost(var.http_cidr, 0))
    error_message = "http_cidr must be a valid CIDR block, or null."
  }
}

variable "game_port" {
  # A second service on its own port, deliberately separate from 80. What runs
  # on 80 here is an administration console; what runs here is a public game.
  # Different audiences, different exposure, so a different rule.
  description = "TCP port of the public game. Set game_cidr to control who reaches it."
  type        = number
  default     = 8080

  validation {
    condition     = var.game_port > 1024 && var.game_port < 65536
    error_message = "game_port must be an unprivileged port, between 1025 and 65535."
  }
}

variable "game_cidr" {
  # Unlike http_cidr, this one defaults to null too: nothing is exposed unless
  # someone writes it down.
  description = "Source allowed on game_port. Leave null to restrict to admin_cidr; set 0.0.0.0/0 to open it to everyone."
  type        = string
  default     = null

  validation {
    condition     = var.game_cidr == null || can(cidrhost(var.game_cidr, 0))
    error_message = "game_cidr must be a valid CIDR block, or null."
  }
}

variable "instance_name" {
  description = "Name tag of the EC2 instance, as shown in the console."
  type        = string
  default     = "Régis"

  validation {
    condition     = length(var.instance_name) > 0 && length(var.instance_name) <= 255
    error_message = "instance_name must be between 1 and 255 characters."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t2.micro is the only one covered by the legacy 750 h/month free tier."
  type        = string
  default     = "t2.micro"
}

variable "owner" {
  description = "Person accountable for the resources (Owner tag)."
  type        = string
  default     = "Blazefive"
}

variable "project" {
  description = "Naming prefix. The training AWS account is shared: it must contain your name."
  type        = string
  default     = "tp-iac-regis"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase letters, digits and hyphens, 2 to 21 characters."
  }
}

variable "public_subnet_cidr" {
  # The default VPC is shared with the rest of the class. Taken ranges at the
  # time of writing: 172.31.0.0/24, .100.0/24, .200.0/24, .240.0/24. Check before
  # changing this:
  #   aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc> \
  #     --query 'Subnets[].CidrBlock'
  description = "Address range of the public subnet. Must sit inside the VPC range and overlap no existing subnet."
  type        = string
  default     = "172.31.50.0/24"
}

variable "vpc_id" {
  description = "Existing VPC to attach to. Read as a data source, never managed: see the note in main.tf."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "region" {
  description = "Single working region, so everything is easy to find again."
  type        = string
  default     = "eu-west-3" # Paris
}

variable "root_volume_size_gb" {
  description = "Root volume size in GiB."
  type        = number
  default     = 10

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 30
    error_message = "root_volume_size_gb must be between 8 and 30 (cost discipline)."
  }
}

variable "root_volume_type" {
  description = "Root volume type. gp3 is cheaper than gp2 at equal performance."
  type        = string
  default     = "gp3"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed on the instance."
  type        = string
  default     = "~/.ssh/tp2_ed25519.pub"
}

# vpc_cidr was removed: the VPC is read as a data source, not created here, so
# the variable had no reader left. tflint's terraform_unused_declarations rule
# caught it - which is the whole point of running a linter over infrastructure
# code rather than only asking whether it parses.

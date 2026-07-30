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

variable "ami_name_pattern" {
  description = "AMI name filter. Pins distribution, release, architecture and root device type."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
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
  description = "Address range of the public subnet. Must sit inside vpc_cidr."
  type        = string
  default     = "10.20.1.0/24"
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

variable "vpc_cidr" {
  description = "Address range of the VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

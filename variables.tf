variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name used for tags, resource names, and the SSM parameter path"
  type        = string
  default     = "k3s-dev"
}

variable "instance_type" {
  description = "Intel instance type for all nodes"
  type        = string
  default     = "t3.small"
}

variable "use_spot" {
  description = "Run nodes as persistent spot instances (stop on interruption)"
  type        = bool
  default     = true
}

variable "agent_count" {
  description = "Number of k3s agent (worker) nodes"
  type        = number
  default     = 2
}

variable "root_volume_gb" {
  description = "Root gp3 volume size per node"
  type        = number
  default     = 20
}

variable "k3s_version" {
  description = "k3s release to install"
  type        = string
  default     = "v1.36.5+k3s1"
}

variable "vpc_cidr" {
  description = "CIDR for the cluster VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "admin_cidr" {
  description = "CIDR allowed full network access to the nodes. null = your current public IP/32"
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Public key installed for the ubuntu user"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "auto_stop_enabled" {
  description = "Stop all nodes on a schedule (safety net if you forget ./cluster.sh down)"
  type        = bool
  default     = true
}

variable "auto_stop_schedule" {
  description = "EventBridge Scheduler expression for the auto-stop"
  type        = string
  default     = "cron(0 3 * * ? *)" # 03:00 daily
}

variable "auto_stop_timezone" {
  description = "IANA time zone for auto_stop_schedule, e.g. America/New_York (DST-aware)"
  type        = string
  default     = "UTC"
}

# Read by cluster.sh to configure the S3 backend (backends can't use variables).
# Declared here so terraform.tfvars can hold them without "undeclared variable" warnings.
variable "state_bucket" {
  description = "S3 bucket holding Terraform state (key k3s-dev/terraform.tfstate)"
  type        = string
}

variable "state_region" {
  description = "Region of state_bucket"
  type        = string
  default     = "us-east-1"
}

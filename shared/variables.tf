variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Project name for tagging and naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev|staging|prod)"
  type        = string
}

variable "owner" {
  description = "Owner or team for tagging"
  type        = string
}

variable "vault_address" {
  description = "Vault server address"
  type        = string
}

variable "vault_token" {
  description = "Vault token"
  type        = string
  sensitive   = true
}

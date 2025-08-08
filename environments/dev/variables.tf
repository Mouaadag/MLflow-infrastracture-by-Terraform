# Common Variables
variable "project_name" {
	description = "Name of the project"
	type        = string
	default     = "mlflow"
}

variable "owner" {
	description = "Owner of the resources"
	type        = string
}

variable "aws_region" {
	description = "AWS region"
	type        = string
	default     = "us-east-1"
}

# Networking
variable "vpc_cidr" {
	description = "CIDR block for VPC"
	type        = string
	default     = "10.0.0.0/16"
}

variable "allowed_cidr_blocks" {
	description = "CIDR blocks allowed for SSH access"
	type        = list(string)
	default     = ["0.0.0.0/0"]
}

# Note: EC2 key pair is now automatically generated using TLS provider
# No need for key_name variable

# SSL/Domain Configuration
variable "domain_name" {
	description = "Domain name for MLflow (leave empty to skip Route53 setup)"
	type        = string
	default     = ""
}

variable "subdomain_name" {
	description = "Subdomain name for MLflow"
	type        = string
	default     = "mlflow"
}

variable "ssl_certificate_arn" {
	description = "SSL certificate ARN for HTTPS"
	type        = string
	default     = ""
}

# Vault Configuration
variable "vault_address" {
	description = "Vault server address"
	type        = string
}

variable "vault_token" {
	description = "Vault token"
	type        = string
	sensitive   = true
}

# Monitoring
variable "alert_email_addresses" {
	description = "List of email addresses for alerts"
	type        = list(string)
	default     = []
}

variable "name_prefix" {
  description = "Name prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# Networking
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

# Security Groups
variable "alb_security_group_id" {
  description = "ALB security group ID"
  type        = string
}

variable "app_security_group_id" {
  description = "Application security group ID"
  type        = string
}

# EC2 Configuration
variable "ami_id" {
  description = "AMI ID for EC2 instances"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 Key Pair name"
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name"
  type        = string
}

# Auto Scaling Configuration
variable "min_capacity" {
  description = "Minimum number of instances"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of instances"
  type        = number
  default     = 10
}

variable "desired_capacity" {
  description = "Desired number of instances"
  type        = number
  default     = 2
}

# S3 Configuration
variable "s3_bucket_name" {
  description = "S3 bucket name for MLflow artifacts"
  type        = string
}

# Database Configuration
variable "database_connection_string" {
  description = "Database connection string"
  type        = string
  sensitive   = true
}

# ElastiCache Configuration
variable "elasticache_endpoint" {
  description = "ElastiCache endpoint"
  type        = string
  default     = ""
}

variable "elasticache_port" {
  description = "ElastiCache port"
  type        = number
  default     = 6379
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

# SSL Configuration
variable "enable_https" {
  description = "Enable HTTPS"
  type        = bool
  default     = false
}

variable "ssl_certificate_arn" {
  description = "SSL certificate ARN"
  type        = string
  default     = ""
}

# Security
variable "kms_key_id" {
  description = "KMS key ID for encryption"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for services that require ARN"
  type        = string
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for ALB"
  type        = bool
  default     = true
}

# Logging
variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
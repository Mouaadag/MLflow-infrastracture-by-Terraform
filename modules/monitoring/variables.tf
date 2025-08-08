variable "name_prefix" {
  description = "Name prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

# Resources to monitor
variable "alb_arn_suffix" {
  description = "ALB ARN suffix for monitoring"
  type        = string
}

variable "autoscaling_group_name" {
  description = "Auto Scaling Group name"
  type        = string
}

variable "rds_instance_id" {
  description = "RDS instance identifier"
  type        = string
}

variable "elasticache_cluster_id" {
  description = "ElastiCache cluster identifier"
  type        = string
  default     = ""
}

variable "cloudwatch_log_group" {
  description = "CloudWatch log group name"
  type        = string
}

# Notification settings
variable "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack webhook URL for notifications"
  type        = string
  default     = ""
  sensitive   = true
}

# Monitoring thresholds
variable "cpu_threshold_high" {
  description = "High CPU threshold percentage"
  type        = number
  default     = 80
}

variable "cpu_threshold_low" {
  description = "Low CPU threshold percentage"
  type        = number
  default     = 20
}

variable "memory_threshold" {
  description = "Memory threshold percentage"
  type        = number
  default     = 85
}

variable "disk_threshold" {
  description = "Disk usage threshold percentage"
  type        = number
  default     = 90
}

variable "response_time_threshold" {
  description = "Response time threshold in milliseconds"
  type        = number
  default     = 5000
}

variable "error_rate_threshold" {
  description = "Error rate threshold (count per period)"
  type        = number
  default     = 10
}

variable "db_connections_threshold" {
  description = "Database connections threshold"
  type        = number
  default     = 50
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
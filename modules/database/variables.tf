variable "name_prefix" {
  description = "Name prefix for all resources"
  type        = string
}

# RDS Configuration
variable "engine" {
  description = "Database engine"
  type        = string
  default     = "mysql"
}

variable "engine_version" {
  description = "Database engine version"
  type        = string
  default     = "8.0"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum allocated storage in GB"
  type        = number
  default     = 100
}

variable "storage_type" {
  description = "Storage type"
  type        = string
  default     = "gp2"
}

variable "database_name" {
  description = "Name of the database"
  type        = string
  default     = "mlflow"
}

variable "database_username" {
  description = "Database username"
  type        = string
  default     = "mlflow"
}

variable "database_password" {
  description = "Database password"
  type        = string
  default     = null
  sensitive   = true
}

variable "db_subnet_group_name" {
  description = "DB subnet group name"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for database"
  type        = string
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Backup window"
  type        = string
  default     = "07:00-09:00"
}

variable "maintenance_window" {
  description = "Maintenance window"
  type        = string
  default     = "Sun:09:00-Sun:11:00"
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = "Enhanced monitoring interval in seconds"
  type        = number
  default     = 0
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key ID for encryption"
  type        = string
}

# Database Parameters
variable "db_family" {
  description = "DB parameter group family"
  type        = string
  default     = "mysql8.0"
}

variable "db_parameters" {
  description = "List of DB parameters"
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    {
      name  = "innodb_buffer_pool_size"
      value = "{DBInstanceClassMemory*3/4}"
    }
  ]
}

# ElastiCache Configuration
variable "enable_elasticache" {
  description = "Enable ElastiCache"
  type        = bool
  default     = true
}

variable "cache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_num_nodes" {
  description = "Number of cache nodes"
  type        = number
  default     = 1
}

variable "cache_subnet_ids" {
  description = "Subnet IDs for ElastiCache"
  type        = list(string)
  default     = []
}

variable "cache_security_group_id" {
  description = "Security group ID for ElastiCache"
  type        = string
  default     = ""
}

variable "cache_parameter_group_family" {
  description = "ElastiCache parameter group family"
  type        = string
  default     = "redis7"
}

variable "cache_parameters" {
  description = "List of cache parameters"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "cache_auth_token" {
  description = "Auth token for Redis"
  type        = string
  default     = null
  sensitive   = true
}

variable "cache_snapshot_retention" {
  description = "Snapshot retention limit"
  type        = number
  default     = 7
}

variable "cache_snapshot_window" {
  description = "Snapshot window"
  type        = string
  default     = "05:00-07:00"
}

variable "cache_maintenance_window" {
  description = "Cache maintenance window"
  type        = string
  default     = "Sun:07:00-Sun:09:00"
}

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
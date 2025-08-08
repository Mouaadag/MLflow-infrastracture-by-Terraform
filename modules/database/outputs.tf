output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.mlflow.endpoint
}

output "rds_port" {
  description = "RDS instance port"
  value       = aws_db_instance.mlflow.port
}

output "database_name" {
  description = "Database name"
  value       = aws_db_instance.mlflow.db_name
}

output "database_username" {
  description = "Database username"
  value       = aws_db_instance.mlflow.username
  sensitive   = true
}

output "database_password" {
  description = "Database password"
  value       = var.database_password != null ? var.database_password : random_password.db_password.result
  sensitive   = true
}

output "rds_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.mlflow.id
}

output "rds_arn" {
  description = "RDS instance ARN"
  value       = aws_db_instance.mlflow.arn
}

output "elasticache_endpoint" {
  description = "ElastiCache primary endpoint"
  value       = var.enable_elasticache ? aws_elasticache_replication_group.mlflow[0].primary_endpoint_address : null
}

output "elasticache_port" {
  description = "ElastiCache port"
  value       = var.enable_elasticache ? 6379 : null
}

output "elasticache_auth_token" {
  description = "ElastiCache auth token"
  value       = var.enable_elasticache ? var.cache_auth_token : null
  sensitive   = true
}

output "elasticache_replication_group_id" {
  description = "ElastiCache replication group ID"
  value       = var.enable_elasticache ? aws_elasticache_replication_group.mlflow[0].id : null
}

output "database_connection_string" {
  description = "Database connection string for MLflow"
  value       = "${var.engine}+pymysql://${aws_db_instance.mlflow.username}:${var.database_password != null ? var.database_password : random_password.db_password.result}@${aws_db_instance.mlflow.endpoint}:${aws_db_instance.mlflow.port}/${aws_db_instance.mlflow.db_name}"
  sensitive   = true
}
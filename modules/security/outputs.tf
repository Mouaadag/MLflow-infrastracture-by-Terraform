output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}

output "mlflow_app_security_group_id" {
  description = "ID of the MLflow application security group"
  value       = aws_security_group.mlflow_app.id
}

output "database_security_group_id" {
  description = "ID of the database security group"
  value       = aws_security_group.database.id
}

output "elasticache_security_group_id" {
  description = "ID of the ElastiCache security group"
  value       = aws_security_group.elasticache.id
}

output "mlflow_instance_profile_name" {
  description = "Name of the MLflow instance profile"
  value       = aws_iam_instance_profile.mlflow_instance_profile.name
}

output "mlflow_instance_role_arn" {
  description = "ARN of the MLflow instance role"
  value       = aws_iam_role.mlflow_instance_role.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.mlflow.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key"
  value       = aws_kms_key.mlflow.arn
}
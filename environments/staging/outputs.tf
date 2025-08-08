output "mlflow_url" {
  description = "URL to access MLflow UI"
  value       = module.mlflow.mlflow_url
}

output "load_balancer_dns_name" {
  description = "ALB DNS name"
  value       = module.mlflow.load_balancer_dns_name
}

output "s3_bucket_name" {
  description = "Artifacts S3 bucket"
  value       = module.mlflow.s3_bucket_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.database.rds_endpoint
}

output "elasticache_endpoint" {
  description = "Redis endpoint"
  value       = module.database.elasticache_endpoint
}

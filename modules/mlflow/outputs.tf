output "s3_bucket_name" {
  description = "Name of the S3 bucket for MLflow artifacts"
  value       = aws_s3_bucket.mlflow_artifacts.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket for MLflow artifacts"
  value       = aws_s3_bucket.mlflow_artifacts.arn
}

output "load_balancer_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.mlflow.dns_name
}

output "load_balancer_zone_id" {
  description = "Zone ID of the load balancer"
  value       = aws_lb.mlflow.zone_id
}

output "load_balancer_arn" {
  description = "ARN of the load balancer"
  value       = aws_lb.mlflow.arn
}

output "load_balancer_arn_suffix" {
  description = "ARN suffix of the load balancer (for CloudWatch dimensions)"
  value       = aws_lb.mlflow.arn_suffix
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.mlflow.arn
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.mlflow.name
}

output "autoscaling_group_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = aws_autoscaling_group.mlflow.arn
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.mlflow.id
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group"
  value       = aws_cloudwatch_log_group.mlflow.name
}

output "mlflow_url" {
  description = "URL to access MLflow UI"
  value       = "http${var.enable_https ? "s" : ""}://${aws_lb.mlflow.dns_name}"
}
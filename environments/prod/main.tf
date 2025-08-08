# Production Environment Configuration
terraform {
  cloud {
    organization = "Mlflow-infra"

    workspaces {
      name = "mlflow-prod"
    }
  }
}

# Data sources
data "aws_availability_zones" "available" { state = "available" }
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Local variables
locals {
  environment = "prod"
  name_prefix = "${var.project_name}-${local.environment}"
  
  # Production-specific configuration
  common_tags = {
    Environment = local.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
    Owner       = var.owner
    CostCenter  = "production"
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Networking Module
module "networking" {
  source = "../../modules/networking"
  
  name_prefix      = local.name_prefix
  vpc_cidr         = var.vpc_cidr
  azs              = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
  
  enable_nat_gateway    = true
  enable_vpc_endpoints  = true
  region               = data.aws_region.current.name
  
  common_tags = local.common_tags
}

# Security Module
module "security" {
  source = "../../modules/security"
  
  name_prefix         = local.name_prefix
  vpc_id             = module.networking.vpc_id
  s3_bucket_arn      = "arn:aws:s3:::${local.name_prefix}-artifacts-${random_id.bucket_suffix.hex}"
  database_port      = 3306
  allowed_cidr_blocks = var.allowed_cidr_blocks
  account_id         = data.aws_caller_identity.current.account_id
  kms_deletion_window = 30  # Longer retention for prod
  
  common_tags = local.common_tags
  
  depends_on = [module.networking]
}

# Database Module
module "database" {
  source = "../../modules/database"
  
  name_prefix = local.name_prefix
  
  # RDS Configuration - Production settings
  engine                     = "mysql"
  engine_version            = "8.0.35"
  instance_class            = "db.r5.xlarge"  # High performance for prod
  allocated_storage         = 100
  max_allocated_storage     = 1000
  storage_type              = "gp3"
  
  database_name             = "mlflow"
  database_username         = "mlflow_admin"
  database_password         = data.vault_generic_secret.database.data["password"]
  
  db_subnet_group_name      = module.networking.database_subnet_group_name
  security_group_id         = module.security.database_security_group_id
  
  # High availability and backup
  multi_az                  = true
  backup_retention_period   = 30
  backup_window            = "03:00-05:00"
  maintenance_window       = "Sun:05:00-Sun:07:00"
  
  # Monitoring
  monitoring_interval       = 60
  performance_insights_enabled = true
  
  # Security
  deletion_protection       = true
  kms_key_id               = module.security.kms_key_id
  
  # ElastiCache Configuration
  enable_elasticache        = true
  cache_node_type          = "cache.r5.large"
  cache_num_nodes          = 3
  cache_subnet_ids         = module.networking.private_subnet_ids
  cache_security_group_id  = module.security.elasticache_security_group_id
  cache_auth_token         = data.vault_generic_secret.cache.data["auth_token"]
  cache_snapshot_retention = 14
  
  log_retention_days       = 90
  common_tags             = local.common_tags
  
  depends_on = [module.networking, module.security]
}

# MLflow Module
module "mlflow" {
  source = "../../modules/mlflow"
  
  name_prefix = local.name_prefix
  environment = local.environment
  aws_region  = data.aws_region.current.name
  
  # Networking
  vpc_id               = module.networking.vpc_id
  public_subnet_ids    = module.networking.public_subnet_ids
  private_subnet_ids   = module.networking.private_subnet_ids
  
  # Security Groups
  alb_security_group_id = module.security.alb_security_group_id
  app_security_group_id = module.security.mlflow_app_security_group_id
  
  # EC2 Configuration
  ami_id                  = data.aws_ami.amazon_linux.id
  instance_type           = "t3.xlarge"  # High performance for prod
  key_name               = var.key_name
  instance_profile_name  = module.security.mlflow_instance_profile_name
  
  # Auto Scaling - High availability
  min_capacity     = 2
  max_capacity     = 10
  desired_capacity = 3
  
  # S3 Configuration
  s3_bucket_name = "${local.name_prefix}-artifacts-${random_id.bucket_suffix.hex}"
  
  # Database
  database_connection_string = module.database.database_connection_string
  
  # ElastiCache
  elasticache_endpoint = module.database.elasticache_endpoint
  elasticache_port     = module.database.elasticache_port
  
  # Vault
  vault_address = var.vault_address
  vault_token   = var.vault_token
  
  # SSL Configuration
  enable_https          = true
  ssl_certificate_arn   = var.ssl_certificate_arn
  
  # Security
  kms_key_id                = module.security.kms_key_id
  enable_deletion_protection = true
  
  # Logging
  log_retention_days = 90
  
  common_tags = local.common_tags
  
  depends_on = [module.networking, module.security, module.database]
}

# Monitoring Module
module "monitoring" {
  source = "../../modules/monitoring"
  
  name_prefix    = local.name_prefix
  environment    = local.environment
  
  # Resources to monitor
  alb_arn_suffix           = module.mlflow.load_balancer_arn_suffix
  autoscaling_group_name   = module.mlflow.autoscaling_group_name
  rds_instance_id         = module.database.rds_instance_id
  elasticache_cluster_id  = coalesce(module.database.elasticache_replication_group_id, "")
  cloudwatch_log_group    = module.mlflow.cloudwatch_log_group_name
  
  # Notification settings
  sns_topic_arn          = aws_sns_topic.alerts.arn
  slack_webhook_url      = data.vault_generic_secret.monitoring.data["slack_webhook"]
  
  # Thresholds for production
  cpu_threshold_high     = 80
  cpu_threshold_low      = 20
  memory_threshold       = 85
  disk_threshold         = 90
  response_time_threshold = 5000
  error_rate_threshold   = 5
  
  common_tags = local.common_tags
  
  depends_on = [module.mlflow, module.database]
}

# Random ID for unique resource names
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = module.security.kms_key_id
  
  tags = local.common_tags
}

# SNS Topic Subscription
resource "aws_sns_topic_subscription" "email_alerts" {
  for_each = toset(var.alert_email_addresses)
  
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Route53 Record (if domain is provided)
resource "aws_route53_record" "mlflow" {
  count = var.domain_name != "" ? 1 : 0
  
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.subdomain_name != "" ? "${var.subdomain_name}.${var.domain_name}" : var.domain_name
  type    = "A"
  
  alias {
    name                   = module.mlflow.load_balancer_dns_name
    zone_id               = module.mlflow.load_balancer_zone_id
    evaluate_target_health = true
  }
}

# Data source for Route53 zone
data "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0
  
  name         = var.domain_name
  private_zone = false
}

# Backup configuration
resource "aws_backup_vault" "mlflow" {
  name        = "${local.name_prefix}-backup-vault"
  kms_key_arn = module.security.kms_key_arn
  
  tags = local.common_tags
}

resource "aws_backup_plan" "mlflow" {
  name = "${local.name_prefix}-backup-plan"
  
  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.mlflow.name
    schedule          = "cron(0 5 ? * * *)"  # Daily at 5 AM UTC
    
    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }
    
    recovery_point_tags = local.common_tags
  }
  
  rule {
    rule_name         = "weekly_backup"
    target_vault_name = aws_backup_vault.mlflow.name
    schedule          = "cron(0 5 ? * SUN *)"  # Weekly on Sunday
    
    lifecycle {
      cold_storage_after = 90
      delete_after       = 2555  # ~7 years
    }
    
    recovery_point_tags = local.common_tags
  }
  
  tags = local.common_tags
}

# IAM role for AWS Backup
resource "aws_iam_role" "backup" {
  name_prefix = "${local.name_prefix}-backup"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "mlflow" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${local.name_prefix}-backup-selection"
  plan_id      = aws_backup_plan.mlflow.id
  
  resources = [
    module.database.rds_arn
  ]
  
  condition {
    string_equals {
      key   = "aws:ResourceTag/Environment"
      value = local.environment
    }
  }
}
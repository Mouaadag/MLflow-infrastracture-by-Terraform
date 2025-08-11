terraform {
  cloud {
    organization = "Mlflow-infra"

    workspaces {
      name = "mlflow-dev"
    }
  }

  # Force CLI-driven workflow to upload files
  required_version = ">= 1.5"
}

# Create SSH key pair for EC2 instances
resource "tls_private_key" "mlflow_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "mlflow_key" {
  key_name   = "${var.project_name}-${local.environment}-key"
  public_key = tls_private_key.mlflow_key.public_key_openssh

  tags = {
    Name = "${var.project_name}-${local.environment}-keypair"
  }
}

locals {
	environment = "dev"
	name_prefix = "${var.project_name}-${local.environment}"

	common_tags = {
		Environment = local.environment
		Project     = var.project_name
		ManagedBy   = "Terraform"
		Owner       = var.owner
		CostCenter  = "development"
	}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
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

module "networking" {
	source = "../../modules/networking"

	name_prefix      = local.name_prefix
	vpc_cidr         = var.vpc_cidr
	azs              = slice(data.aws_availability_zones.available.names, 0, 2)
	public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]
	private_subnets  = ["10.0.11.0/24", "10.0.12.0/24"]
	database_subnets = ["10.0.21.0/24", "10.0.22.0/24"]

	enable_nat_gateway   = true
	enable_vpc_endpoints = true
	region               = data.aws_region.current.name

	common_tags = local.common_tags
}

resource "random_id" "bucket_suffix" { byte_length = 4 }

module "security" {
	source = "../../modules/security"

	name_prefix          = local.name_prefix
	vpc_id               = module.networking.vpc_id
	s3_bucket_arn        = "arn:aws:s3:::${local.name_prefix}-artifacts-${random_id.bucket_suffix.hex}"
	database_port        = 3306
	allowed_cidr_blocks  = var.allowed_cidr_blocks
		account_id           = data.aws_caller_identity.current.account_id
	kms_deletion_window  = 7

	common_tags = local.common_tags

	depends_on = [module.networking]
}

data "vault_generic_secret" "database" { path = "secret/dev/database" }
data "vault_generic_secret" "cache" { path = "secret/dev/cache" }
data "vault_generic_secret" "monitoring" { path = "secret/dev/monitoring" }

module "database" {
	source = "../../modules/database"

	name_prefix                 = local.name_prefix
	engine                      = "mysql"
	engine_version              = "8.0.43"
	instance_class              = "db.t3.micro"
	allocated_storage           = 20
	max_allocated_storage       = 100
	storage_type                = "gp3"
	database_name               = "mlflow"
	database_username           = "mlflow_admin"
	database_password           = data.vault_generic_secret.database.data["password"]
	db_subnet_group_name        = module.networking.database_subnet_group_name
	security_group_id           = module.security.database_security_group_id
	multi_az                    = false
	backup_retention_period     = 7
	backup_window               = "03:00-05:00"
	maintenance_window          = "Sun:05:00-Sun:07:00"
	monitoring_interval         = 0
	performance_insights_enabled = false
	deletion_protection         = false
	kms_key_id                  = module.security.kms_key_arn

	enable_elasticache          = true
	cache_node_type             = "cache.t3.micro"
	cache_num_nodes             = 1
	cache_subnet_ids            = module.networking.private_subnet_ids
	cache_security_group_id     = module.security.elasticache_security_group_id
	cache_auth_token            = data.vault_generic_secret.cache.data["auth_token"]
	cache_snapshot_retention    = 7

	log_retention_days          = 30
	common_tags                 = local.common_tags

	depends_on = [module.networking, module.security]
}

module "mlflow" {
	source = "../../modules/mlflow"

	name_prefix            = local.name_prefix
	environment            = local.environment
	aws_region             = data.aws_region.current.name
	vpc_id                 = module.networking.vpc_id
	public_subnet_ids      = module.networking.public_subnet_ids
	private_subnet_ids     = module.networking.private_subnet_ids
	alb_security_group_id  = module.security.alb_security_group_id
	app_security_group_id  = module.security.mlflow_app_security_group_id
	ami_id                 = data.aws_ami.amazon_linux.id
	instance_type          = "t3.micro"
	key_name               = aws_key_pair.mlflow_key.key_name
	instance_profile_name  = module.security.mlflow_instance_profile_name
	min_capacity           = 1
	max_capacity           = 2
	desired_capacity       = 1
	s3_bucket_name         = "${local.name_prefix}-artifacts-${random_id.bucket_suffix.hex}"
	database_connection_string = module.database.database_connection_string
	elasticache_endpoint   = module.database.elasticache_endpoint
	elasticache_port       = module.database.elasticache_port
	vault_address          = var.vault_address
	vault_token            = var.vault_token
	enable_https           = false
	ssl_certificate_arn    = ""
	kms_key_id             = module.security.kms_key_arn
	enable_deletion_protection = false
	log_retention_days     = 30
	common_tags            = local.common_tags

	depends_on = [module.networking, module.security, module.database]
}

resource "aws_sns_topic" "alerts" {
	name              = "${local.name_prefix}-alerts"
	kms_master_key_id = module.security.kms_key_arn
	tags = local.common_tags
}

module "monitoring" {
	source = "../../modules/monitoring"

	name_prefix            = local.name_prefix
	environment            = local.environment
	alb_arn_suffix         = module.mlflow.load_balancer_arn_suffix
	autoscaling_group_name = module.mlflow.autoscaling_group_name
	rds_instance_id        = module.database.rds_instance_id
	elasticache_cluster_id = coalesce(module.database.elasticache_replication_group_id, "")
	cloudwatch_log_group   = module.mlflow.cloudwatch_log_group_name
	sns_topic_arn          = aws_sns_topic.alerts.arn
	slack_webhook_url      = try(data.vault_generic_secret.monitoring.data["slack_webhook"], "")
	cpu_threshold_high     = 80
	cpu_threshold_low      = 20
	memory_threshold       = 85
	disk_threshold         = 90
	response_time_threshold = 5000
	error_rate_threshold   = 10
	common_tags            = local.common_tags

	depends_on = [module.mlflow, module.database]
}

locals {
  # Common tags
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
    CreatedAt   = formatdate("YYYY-MM-DD", timestamp())
  }

  # Naming convention
  name_prefix = "${var.project_name}-${var.environment}"
  
  # AZ mapping
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  
  # CIDR calculations
  vpc_cidr = var.vpc_cidr
  private_subnets = [
    for i in range(var.az_count) : cidrsubnet(local.vpc_cidr, 8, i)
  ]
  public_subnets = [
    for i in range(var.az_count) : cidrsubnet(local.vpc_cidr, 8, i + var.az_count)
  ]
  database_subnets = [
    for i in range(var.az_count) : cidrsubnet(local.vpc_cidr, 8, i + (var.az_count * 2))
  ]
  
  # Environment-specific configurations
  environment_config = {
    dev = {
      instance_type         = "t3.medium"
      min_capacity         = 1
      max_capacity         = 2
      desired_capacity     = 1
      db_instance_class    = "db.t3.micro"
      multi_az            = false
      backup_retention    = 7
      deletion_protection = false
    }
    staging = {
      instance_type         = "t3.large"
      min_capacity         = 2
      max_capacity         = 4
      desired_capacity     = 2
      db_instance_class    = "db.t3.small"
      multi_az            = true
      backup_retention    = 14
      deletion_protection = true
    }
    prod = {
      instance_type         = "t3.xlarge"
      min_capacity         = 2
      max_capacity         = 10
      desired_capacity     = 3
      db_instance_class    = "db.r5.large"
      multi_az            = true
      backup_retention    = 30
      deletion_protection = true
    }
  }
  
  # Current environment config
  env_config = local.environment_config[var.environment]
  
  # Secrets from Vault
  aws_secrets = data.vault_generic_secret.aws_credentials.data
  db_secrets  = data.vault_generic_secret.database.data
  mlflow_secrets = data.vault_generic_secret.mlflow.data
}
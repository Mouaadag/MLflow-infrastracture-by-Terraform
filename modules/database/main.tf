# Random password for database
resource "random_password" "db_password" {
  length  = 16
  special = true
}

# RDS Parameter Group
resource "aws_db_parameter_group" "mlflow" {
  family = var.db_family
  name   = "${var.name_prefix}-db-params"

  dynamic "parameter" {
    for_each = var.db_parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = var.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Instance
resource "aws_db_instance" "mlflow" {
  identifier = "${var.name_prefix}-db"

  # Engine configuration
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Database configuration
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  storage_encrypted     = true
  kms_key_id           = var.kms_key_id

  # Database credentials
  db_name  = var.database_name
  username = var.database_username
  password = var.database_password != null ? var.database_password : random_password.db_password.result

  # Networking
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  # Backup configuration
  backup_retention_period = var.backup_retention_period
  backup_window          = var.backup_window
  maintenance_window     = var.maintenance_window

  # High availability
  multi_az = var.multi_az

  # Monitoring
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_enhanced_monitoring[0].arn : null

  # Performance Insights
  performance_insights_enabled = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? var.kms_key_id : null

  # Parameter group
  parameter_group_name = aws_db_parameter_group.mlflow.name

  # Deletion protection
  deletion_protection = var.deletion_protection
  skip_final_snapshot = !var.deletion_protection

  final_snapshot_identifier = var.deletion_protection ? "${var.name_prefix}-db-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-db"
  })

  depends_on = [
    aws_db_parameter_group.mlflow
  ]
}

# RDS Enhanced Monitoring Role
resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  
  name_prefix = "${var.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  
  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "mlflow" {
  count = var.enable_elasticache ? 1 : 0
  
  name       = "${var.name_prefix}-cache-subnet"
  subnet_ids = var.cache_subnet_ids

  tags = var.common_tags
}

# ElastiCache Parameter Group
resource "aws_elasticache_parameter_group" "mlflow" {
  count = var.enable_elasticache ? 1 : 0
  
  family = var.cache_parameter_group_family
  name   = "${var.name_prefix}-cache-params"

  dynamic "parameter" {
    for_each = var.cache_parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }

  tags = var.common_tags
}

# ElastiCache Replication Group (Redis)
resource "aws_elasticache_replication_group" "mlflow" {
  count = var.enable_elasticache ? 1 : 0
  
  replication_group_id       = "${var.name_prefix}-cache"
  description                = "Redis cache for MLflow sessions"

  # Node configuration
  node_type            = var.cache_node_type
  num_cache_clusters   = var.cache_num_nodes
  port                 = 6379

  # Parameter group
  parameter_group_name = aws_elasticache_parameter_group.mlflow[0].name

  # Networking
  subnet_group_name  = aws_elasticache_subnet_group.mlflow[0].name
  security_group_ids = [var.cache_security_group_id]

  # Security
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.cache_auth_token

  # Backup
  snapshot_retention_limit = var.cache_snapshot_retention
  snapshot_window         = var.cache_snapshot_window

  # Maintenance
  maintenance_window = var.cache_maintenance_window

  # Logging
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.elasticache_slow[0].name
    destination_type = "cloudwatch-logs"
    log_format       = "text"
    log_type         = "slow-log"
  }

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-cache"
  })

  depends_on = [
    aws_elasticache_subnet_group.mlflow,
    aws_elasticache_parameter_group.mlflow
  ]
}

# CloudWatch Log Group for ElastiCache
resource "aws_cloudwatch_log_group" "elasticache_slow" {
  count = var.enable_elasticache ? 1 : 0
  
  name              = "/aws/elasticache/${var.name_prefix}-slow-log"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_id

  tags = var.common_tags
}

# SSM Parameters for database connection
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.name_prefix}/database/host"
  type  = "String"
  value = aws_db_instance.mlflow.address

  tags = var.common_tags
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.name_prefix}/database/port"
  type  = "String"
  value = tostring(aws_db_instance.mlflow.port)

  tags = var.common_tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.name_prefix}/database/name"
  type  = "String"
  value = aws_db_instance.mlflow.db_name

  tags = var.common_tags
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/${var.name_prefix}/database/username"
  type  = "String"
  value = aws_db_instance.mlflow.username

  tags = var.common_tags
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.name_prefix}/database/password"
  type  = "SecureString"
  value = var.database_password != null ? var.database_password : random_password.db_password.result

  tags = var.common_tags
}

# SSM Parameters for ElastiCache connection
resource "aws_ssm_parameter" "cache_endpoint" {
  count = var.enable_elasticache ? 1 : 0
  
  name  = "/${var.name_prefix}/cache/endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.mlflow[0].primary_endpoint_address

  tags = var.common_tags
}

resource "aws_ssm_parameter" "cache_port" {
  count = var.enable_elasticache ? 1 : 0
  
  name  = "/${var.name_prefix}/cache/port"
  type  = "String"
  value = "6379"

  tags = var.common_tags
}
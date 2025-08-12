# Data sources
data "aws_region" "current" {}

# Application Load Balancer Security Group
resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-alb-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# MLflow Application Security Group
resource "aws_security_group" "mlflow_app" {
  name_prefix = "${var.name_prefix}-mlflow-app"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB (nginx)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "MLflow from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-mlflow-app-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Database Security Group
resource "aws_security_group" "database" {
  name_prefix = "${var.name_prefix}-database"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL/PostgreSQL from MLflow"
    from_port       = var.database_port
    to_port         = var.database_port
    protocol        = "tcp"
    security_groups = [aws_security_group.mlflow_app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-database-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ElastiCache Security Group
resource "aws_security_group" "elasticache" {
  name_prefix = "${var.name_prefix}-elasticache"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from MLflow"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.mlflow_app.id]
  }

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-elasticache-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM Role for MLflow EC2 instances
resource "aws_iam_role" "mlflow_instance_role" {
  name_prefix = "${var.name_prefix}-mlflow-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for S3 access
resource "aws_iam_policy" "mlflow_s3_policy" {
  name_prefix = "${var.name_prefix}-mlflow-s3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for CloudWatch
resource "aws_iam_policy" "mlflow_cloudwatch_policy" {
  name_prefix = "${var.name_prefix}-mlflow-cloudwatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for Systems Manager
resource "aws_iam_policy" "mlflow_ssm_policy" {
  name_prefix = "${var.name_prefix}-mlflow-ssm"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:PutParameter",
          "ssm:UpdateInstanceInformation",
          "ssm:SendCommand"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for KMS access
resource "aws_iam_policy" "mlflow_kms_policy" {
  name_prefix = "${var.name_prefix}-mlflow-kms"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = aws_kms_key.mlflow.arn
      }
    ]
  })

  tags = var.common_tags
}

# Attach policies to role
resource "aws_iam_role_policy_attachment" "mlflow_s3_policy_attachment" {
  role       = aws_iam_role.mlflow_instance_role.name
  policy_arn = aws_iam_policy.mlflow_s3_policy.arn
}

resource "aws_iam_role_policy_attachment" "mlflow_cloudwatch_policy_attachment" {
  role       = aws_iam_role.mlflow_instance_role.name
  policy_arn = aws_iam_policy.mlflow_cloudwatch_policy.arn
}

resource "aws_iam_role_policy_attachment" "mlflow_ssm_policy_attachment" {
  role       = aws_iam_role.mlflow_instance_role.name
  policy_arn = aws_iam_policy.mlflow_ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "mlflow_kms_policy_attachment" {
  role       = aws_iam_role.mlflow_instance_role.name
  policy_arn = aws_iam_policy.mlflow_kms_policy.arn
}

resource "aws_iam_role_policy_attachment" "mlflow_ssm_managed_policy" {
  role       = aws_iam_role.mlflow_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "mlflow_instance_profile" {
  name_prefix = "${var.name_prefix}-mlflow-instance"
  role        = aws_iam_role.mlflow_instance_role.name

  tags = var.common_tags
}

# KMS Key for encryption
resource "aws_kms_key" "mlflow" {
  description             = "KMS key for MLflow encryption"
  deletion_window_in_days = var.kms_deletion_window

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowMLflowInstanceRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.mlflow_instance_role.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAutoScalingService"
        Effect = "Allow"
        Principal = {
          Service = "autoscaling.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ec2.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowEC2Service"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ec2.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.name_prefix}-kms-key"
  })
}

# KMS Key Alias
resource "aws_kms_alias" "mlflow" {
  name          = "alias/${var.name_prefix}-mlflow"
  target_key_id = aws_kms_key.mlflow.key_id
}

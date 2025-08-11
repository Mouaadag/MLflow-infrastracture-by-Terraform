# S3 Bucket for MLflow artifacts
resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket = var.s3_bucket_name

  tags = var.common_tags
}

resource "aws_s3_bucket_versioning" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_id
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    id     = "mlflow_artifacts_lifecycle"
    status = "Enabled"

    # Apply to the whole bucket
    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Application Load Balancer
resource "aws_lb" "mlflow" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.enable_deletion_protection

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb-access-logs"
    enabled = true
  }

  tags = var.common_tags
}

# S3 Bucket for ALB logs
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.s3_bucket_name}-alb-logs"

  tags = var.common_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket Policy for ALB logs
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Get the ELB service account for the current region
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/alb-access-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs.arn
      }
    ]
  })
}

# ALB Target Group
resource "aws_lb_target_group" "mlflow" {
  name     = "${var.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/health"
    matcher             = "200"
    port                = "80"
    protocol            = "HTTP"
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = var.common_tags
}

# ALB Listener
resource "aws_lb_listener" "mlflow" {
  load_balancer_arn = aws_lb.mlflow.arn
  port              = var.enable_https ? "443" : "80"
  protocol          = var.enable_https ? "HTTPS" : "HTTP"
  ssl_policy        = var.enable_https ? "ELBSecurityPolicy-TLS-1-2-2017-01" : null
  certificate_arn   = var.enable_https ? var.ssl_certificate_arn : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mlflow.arn
  }

  tags = var.common_tags
}

# HTTP to HTTPS redirect (if HTTPS is enabled)
resource "aws_lb_listener" "http_redirect" {
  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.mlflow.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.common_tags
}

# Launch Template
resource "aws_launch_template" "mlflow" {
  name_prefix   = "${var.name_prefix}-lt"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [var.app_security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    name_prefix            = var.name_prefix
    s3_bucket_name        = aws_s3_bucket.mlflow_artifacts.bucket
    database_connection_string = var.database_connection_string
    elasticache_endpoint  = var.elasticache_endpoint
    elasticache_port      = var.elasticache_port
    vault_address         = var.vault_address
    vault_token           = var.vault_token
    environment           = var.environment
    aws_region            = var.aws_region
    cloudwatch_log_group  = aws_cloudwatch_log_group.mlflow.name
  }))

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = true
      kms_key_id           = var.kms_key_id
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tags = var.common_tags

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name = "${var.name_prefix}-instance"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "mlflow" {
  name                = "${var.name_prefix}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.mlflow.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 1200  # 20 minutes to allow for full setup

  min_size         = var.min_capacity
  max_size         = var.max_capacity
  desired_capacity = var.desired_capacity

  launch_template {
    id      = aws_launch_template.mlflow.id
    version = "$Latest"
  }

  # Instance refresh
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  dynamic "tag" {
    for_each = var.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-asg"
    propagate_at_launch = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "${var.name_prefix}-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown              = 300
  autoscaling_group_name = aws_autoscaling_group.mlflow.name

  policy_type = "SimpleScaling"
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "${var.name_prefix}-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown              = 300
  autoscaling_group_name = aws_autoscaling_group.mlflow.name

  policy_type = "SimpleScaling"
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mlflow.name
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.name_prefix}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "20"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mlflow.name
  }

  tags = var.common_tags
}

# CloudWatch Log Group for MLflow
resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/aws/ec2/mlflow/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_id

  tags = var.common_tags
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "mlflow" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.mlflow.name],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.mlflow.arn_suffix],
            [".", "RequestCount", ".", "."],
            [".", "HTTPCode_Target_2XX_Count", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "MLflow Metrics"
          period  = 300
        }
      }
    ]
  })
}
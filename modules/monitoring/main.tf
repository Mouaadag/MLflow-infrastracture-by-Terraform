# CloudWatch Alarms for Application Load Balancer
resource "aws_cloudwatch_metric_alarm" "alb_response_time" {
  alarm_name          = "${var.name_prefix}-alb-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Average"
  threshold           = var.response_time_threshold
  alarm_description   = "This metric monitors ALB response time"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "alb_error_rate" {
  alarm_name          = "${var.name_prefix}-alb-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Sum"
  threshold           = var.error_rate_threshold
  alarm_description   = "This metric monitors ALB 5XX errors"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.common_tags
}

# CloudWatch Alarms for Auto Scaling Group
resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "${var.name_prefix}-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = var.cpu_threshold_high
  alarm_description   = "This metric monitors ASG CPU utilization"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    AutoScalingGroupName = var.autoscaling_group_name
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "asg_memory_high" {
  alarm_name          = "${var.name_prefix}-asg-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = "300"
  statistic           = "Average"
  threshold           = var.memory_threshold
  alarm_description   = "This metric monitors ASG memory utilization"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    AutoScalingGroupName = var.autoscaling_group_name
  }

  tags = var.common_tags
}

# CloudWatch Alarms for RDS
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = var.cpu_threshold_high
  alarm_description   = "This metric monitors RDS CPU utilization"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = var.db_connections_threshold
  alarm_description   = "This metric monitors RDS connections"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.common_tags
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "mlflow_main" {
  dashboard_name = "${var.name_prefix}-main-dashboard"

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
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "TargetResponseTime", ".", "."],
            [".", "HTTPCode_Target_2XX_Count", ".", "."],
            [".", "HTTPCode_Target_4XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Application Load Balancer Metrics"
          period  = 300
          yAxis = {
            left = {
              min = 0
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.autoscaling_group_name],
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", var.autoscaling_group_name],
            [".", "disk_used_percent", "AutoScalingGroupName", var.autoscaling_group_name, "device", "/dev/xvda1", "fstype", "xfs", "path", "/"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "EC2 Instance Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_id],
            [".", "DatabaseConnections", ".", "."],
            [".", "ReadLatency", ".", "."],
            [".", "WriteLatency", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "RDS Database Metrics"
          period  = 300
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6

        properties = {
          query = "SOURCE '${var.cloudwatch_log_group}'\n| fields @timestamp, @message\n| filter @message like /ERROR/\n| sort @timestamp desc\n| limit 100"
          region = "us-east-1"
          title  = "Recent Errors"
          view   = "table"
        }
      }
    ]
  })
}

# CloudWatch Insights Queries
resource "aws_cloudwatch_query_definition" "error_analysis" {
  name = "${var.name_prefix}/error-analysis"

  log_group_names = [var.cloudwatch_log_group]

  query_string = <<EOF
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() by bin(5m)
| sort @timestamp desc
EOF
}

resource "aws_cloudwatch_query_definition" "performance_analysis" {
  name = "${var.name_prefix}/performance-analysis"

  log_group_names = [var.cloudwatch_log_group]

  query_string = <<EOF
fields @timestamp, @message
| filter @message like /response_time/
| parse @message /response_time: (?<response_time>\d+)/
| stats avg(response_time), max(response_time), min(response_time) by bin(5m)
| sort @timestamp desc
EOF
}

# Custom Lambda function for Slack notifications
resource "aws_lambda_function" "slack_notification" {
  count = var.slack_webhook_url != "" ? 1 : 0

  filename         = data.archive_file.slack_lambda[0].output_path
  function_name    = "${var.name_prefix}-slack-notifications"
  role            = aws_iam_role.lambda_role[0].arn
  handler         = "index.handler"
  source_code_hash = data.archive_file.slack_lambda[0].output_base64sha256
  runtime         = "python3.9"
  timeout         = 30

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      ENVIRONMENT      = var.environment
    }
  }

  tags = var.common_tags
}

# Lambda deployment package
data "archive_file" "slack_lambda" {
  count = var.slack_webhook_url != "" ? 1 : 0

  type        = "zip"
  output_path = "/tmp/slack_lambda.zip"
  
  source {
    content = <<EOF
import json
import urllib3
import os

def handler(event, context):
    webhook_url = os.environ['SLACK_WEBHOOK_URL']
    environment = os.environ['ENVIRONMENT']
    
    http = urllib3.PoolManager()
    
    # Parse SNS message
    message = json.loads(event['Records'][0]['Sns']['Message'])
    
    # Format Slack message
    slack_message = {
        "text": f"🚨 MLflow Alert - {environment.upper()}",
        "attachments": [
            {
                "color": "danger" if message['NewStateValue'] == 'ALARM' else "good",
                "fields": [
                    {
                        "title": "Alarm Name",
                        "value": message['AlarmName'],
                        "short": True
                    },
                    {
                        "title": "State",
                        "value": message['NewStateValue'],
                        "short": True
                    },
                    {
                        "title": "Reason",
                        "value": message['NewStateReason'],
                        "short": False
                    }
                ]
            }
        ]
    }
    
    # Send to Slack
    response = http.request(
        'POST',
        webhook_url,
        body=json.dumps(slack_message).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    return {
        'statusCode': 200,
        'body': json.dumps('Success')
    }
EOF
    filename = "index.py"
  }
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  count = var.slack_webhook_url != "" ? 1 : 0

  name_prefix = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  count = var.slack_webhook_url != "" ? 1 : 0

  role       = aws_iam_role.lambda_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# SNS subscription for Lambda
resource "aws_sns_topic_subscription" "slack_lambda" {
  count = var.slack_webhook_url != "" ? 1 : 0

  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notification[0].arn
}

# Lambda permission for SNS
resource "aws_lambda_permission" "allow_sns" {
  count = var.slack_webhook_url != "" ? 1 : 0

  statement_id  = "AllowSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notification[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}
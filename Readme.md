# MLflow Infrastructure Resources Guide

This document serves as a comprehensive introduction to all the AWS resources we deploy to create a production-ready MLflow platform. Each resource plays a specific role in building a secure, scalable, and highly available machine learning experiment tracking system.

## 🔒 Security Module Resources

### Security Groups
- **ALB Security Group** (`aws_security_group.alb`): Controls traffic to the Application Load Balancer - allows HTTP (80) and HTTPS (443) from internet, enables public access to MLflow
- **MLflow App Security Group** (`aws_security_group.mlflow_app`): Protects EC2 instances running MLflow - allows HTTP (80) for nginx and MLflow (5000) only from ALB, plus SSH for management
- **Database Security Group** (`aws_security_group.database`): Secures RDS database - only allows MySQL/PostgreSQL traffic from MLflow instances on the database port
- **ElastiCache Security Group** (`aws_security_group.elasticache`): Protects Redis cache - only allows Redis traffic (6379) from MLflow instances

### IAM Resources
- **MLflow Instance Role** (`aws_iam_role.mlflow_instance_role`): Allows EC2 instances to assume permissions - enables MLflow instances to access AWS services
- **S3 Policy** (`aws_iam_policy.mlflow_s3_policy`): Grants S3 access for artifacts storage - MLflow stores model artifacts, datasets, and experiment data in S3
- **CloudWatch Policy** (`aws_iam_policy.mlflow_cloudwatch_policy`): Enables logging and monitoring - MLflow sends logs and metrics to CloudWatch for observability
- **SSM Policy** (`aws_iam_policy.mlflow_ssm_policy`): Allows Systems Manager access - retrieves database passwords and configuration from Parameter Store securely
- **KMS Policy** (`aws_iam_policy.mlflow_kms_policy`): Grants encryption/decryption permissions - enables MLflow to work with encrypted resources
- **Instance Profile** (`aws_iam_instance_profile.mlflow_instance_profile`): Attaches IAM role to EC2 instances - provides AWS API access to running instances

### Encryption
- **KMS Key** (`aws_kms_key.mlflow`): Encrypts data at rest - secures S3 artifacts, EBS volumes, database, CloudWatch logs, and SNS messages
- **KMS Alias** (`aws_kms_alias.mlflow`): Human-readable name for KMS key - easier key management and reference

## 🌐 Networking Module Resources

### Core Network
- **VPC** (`aws_vpc.main`): Isolated network environment - provides secure, dedicated cloud network for all MLflow resources
- **Internet Gateway** (`aws_internet_gateway.main`): Internet access for public subnets - enables ALB to receive traffic from internet
- **NAT Gateways** (`aws_nat_gateway.main`): Outbound internet for private subnets - allows MLflow instances to download packages and access AWS APIs

### Subnets
- **Public Subnets** (`aws_subnet.public`): Host load balancer - ALB receives internet traffic and routes to private instances
- **Private Subnets** (`aws_subnet.private`): Host MLflow instances - EC2 instances run securely without direct internet exposure
- **Database Subnets** (`aws_subnet.database`): Isolated database tier - RDS and ElastiCache run in dedicated network layer

### Routing & DNS
- **Route Tables**: Direct network traffic - ensures proper routing between subnets, internet, and NAT gateways
- **VPC Endpoints**: Private AWS API access - allows instances to reach S3 and EC2 APIs without internet routing

## 🗄️ Database Module Resources

### Primary Database
- **RDS MySQL Instance** (`aws_db_instance.mlflow`): Stores MLflow metadata - tracks experiments, runs, parameters, metrics, and model registry
- **DB Subnet Group** (`aws_db_subnet_group.database`): Database network placement - ensures RDS runs in secure database subnets
- **DB Parameter Group** (`aws_db_parameter_group.mlflow`): Database configuration - optimizes MySQL settings for MLflow workloads

### Caching Layer
- **ElastiCache Redis** (`aws_elasticache_replication_group.mlflow`): Session and data caching - improves MLflow UI performance and API response times
- **Cache Subnet Group** (`aws_elasticache_subnet_group.mlflow`): Cache network placement - places Redis in secure private subnets
- **Cache Parameter Group** (`aws_elasticache_parameter_group.mlflow`): Redis configuration - optimizes cache settings for MLflow

### Configuration Storage
- **SSM Parameters**: Store database credentials and connection details - secure parameter storage for sensitive configuration

## 🚀 MLflow Module Resources

### Compute
- **Launch Template** (`aws_launch_template.mlflow`): EC2 instance configuration - defines AMI, instance type, security groups, and user data script
- **Auto Scaling Group** (`aws_autoscaling_group.mlflow`): Manages MLflow instances - ensures high availability, scales based on demand, replaces unhealthy instances

### Load Balancing
- **Application Load Balancer** (`aws_lb.mlflow`): Distributes traffic to instances - provides single entry point, health checks, and SSL termination
- **Target Group** (`aws_lb_target_group.mlflow`): Groups healthy instances - routes traffic only to instances passing health checks
- **ALB Listeners**: Configure traffic routing - handle HTTP/HTTPS requests and route to MLflow instances

### Storage
- **S3 Artifacts Bucket** (`aws_s3_bucket.mlflow_artifacts`): Stores model artifacts and files - centralized storage for ML models, datasets, and experiment outputs
- **ALB Logs Bucket** (`aws_s3_bucket.alb_logs`): Stores load balancer logs - tracks access patterns and troubleshooting information

### Monitoring
- **CloudWatch Log Groups**: Collect application logs - stores MLflow server logs, nginx logs, and system logs for debugging

## 📢 Alerting Resources

### Notifications
- **SNS Topic** (`aws_sns_topic.alerts`): Infrastructure alerts - notifies on Auto Scaling events, health check failures, and system issues

## 🔑 Bootstrap Resources

### Access
- **Key Pair** (`aws_key_pair.mlflow_key`): SSH access to instances - enables secure shell access for troubleshooting and maintenance
- **Random ID** (`random_id.bucket_suffix`): Unique naming - ensures S3 bucket names are globally unique

## 🎯 Overall Purpose

This infrastructure creates a production-ready, highly available MLflow tracking server that provides:

1. **🔒 Security**: End-to-end encryption, network isolation, least-privilege access
2. **⚡ Performance**: Load balancing, caching layer, optimized database
3. **📈 Scalability**: Auto scaling, multi-AZ deployment, elastic resources
4. **🛡️ Reliability**: Health checks, automatic recovery, backup strategies
5. **👀 Observability**: Comprehensive logging, monitoring, and alerting
6. **🔧 Maintainability**: Infrastructure as code, automated deployments, parameter management

The result is an enterprise-grade MLflow platform for machine learning experiment tracking, model registry, and artifact management.
# Get current AWS account info
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Get latest Amazon Linux 2 AMI
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

# Get latest Ubuntu 20.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Vault data sources
data "vault_generic_secret" "aws_credentials" {
  path = "secret/${var.environment}/aws"
}

data "vault_generic_secret" "database" {
  path = "secret/${var.environment}/database"
}

data "vault_generic_secret" "mlflow" {
  path = "secret/${var.environment}/mlflow"
}
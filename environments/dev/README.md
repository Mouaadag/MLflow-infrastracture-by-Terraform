# MLflow Infrastructure – Dev Environment Quickstart

This guide walks you through deploying the MLflow dev environment end to end on AWS using Terraform and Vault.

## What you’ll deploy
- VPC with public/private/database subnets, NAT, endpoints
- Security (SGs, IAM role/profile, KMS key)
- RDS (MySQL) and ElastiCache (Redis)
- MLflow on EC2 behind an ALB
- CloudWatch logs/alarms/dashboard and SNS alerts

## Prerequisites
- macOS with zsh (default here)
- AWS CLI v2 configured with an account that can create the above resources
- Terraform >= 1.5
- Vault CLI and access to your Vault
- jq and openssl

Verify:
```zsh
aws sts get-caller-identity
terraform version
vault version
jq --version
openssl version
```

## 1) Configure Terraform state backend (HCP Terraform / Terraform Cloud)
We use Terraform Cloud as the remote backend, already wired in `environments/dev/main.tf`:

```
terraform {
  cloud {
    organization = "Mlflow-infra"
    workspaces { name = "mlflow-dev" }
  }
}
```

Sign in to HCP Terraform (Terraform Cloud) and ensure the workspace exists:

```zsh
terraform login
# In the TFC organization "Mlflow-infra", create a workspace named: mlflow-dev
# Optional: set variables in the workspace UI (same keys as terraform.tfvars) or keep them local.
```

## 2) Prepare Vault access and secrets
Set Vault address and token (or authenticate another way). Example with env vars:
```zsh
export VAULT_ADDR="https://your-vault.example.com:8200"
export VAULT_TOKEN="<your-root-or-approle-or-userpass-token>"
```

Create required dev secrets using the helper script (interactive prompts):
```zsh
# From repo root or this folder
../../scripts/vault-setup.sh setup dev
```

Or create minimal secrets manually:
```zsh
# Database password
vault kv put secret/dev/database \
  username=mlflow_admin password="$(openssl rand -base64 24 | tr -d '=+/ | cut -c1-24)" \
  host="" port="3306" database="mlflow"

# Redis auth token
vault kv put secret/dev/cache \
  auth_token="$(openssl rand -base64 32 | tr -d '=+/ | cut -c1-32)" \
  host="" port="6379"

# Optional monitoring webhook
vault kv put secret/dev/monitoring slack_webhook=""
```

## 3) Set environment variables and inputs
The infrastructure now automatically creates EC2 key pairs using the TLS provider - no manual setup required!

Create or edit `environments/dev/terraform.tfvars`:
```hcl
owner           = "your-name-or-team"
aws_region      = "us-east-1"          # or your region
vpc_cidr        = "10.0.0.0/16"
allowed_cidr_blocks = ["0.0.0.0/0"]     # tighten for SSH/SSM as needed

# NOTE: EC2 key pair is now automatically generated using TLS provider
# No need to manually create key_name - it will be auto-generated

# Optional
# domain_name       = "example.com"
# subdomain_name    = "mlflow"
# ssl_certificate_arn = "arn:aws:acm:..."
# alert_email_addresses = ["you@example.com"]
# vault_address     = "${env.VAULT_ADDR}"
# vault_token       = "${env.VAULT_TOKEN}"
```

Note: `vault_address` and `vault_token` come from env vars by default; you can also set them in tfvars.

## 4) Initialize and deploy
Use the deployment helper script from the project repo (it will detect the Cloud backend from the config):
```zsh
# From mlflow-infrastructure root
./scripts/deploy.sh init dev
./scripts/deploy.sh validate dev
./scripts/deploy.sh plan dev
./scripts/deploy.sh apply dev --force
```

Show outputs (URL, endpoints):
```zsh
./scripts/deploy.sh output dev
```

## 5) Access MLflow
- Output `mlflow_url` shows the ALB URL (HTTP by default in dev). Example: `http://<alb-dns>`
- If you enabled HTTPS and Route53, use your domain.

## 6) Clean up
```zsh
./scripts/deploy.sh destroy dev --force
```

## Troubleshooting
- Vault authentication: ensure `VAULT_ADDR`/`VAULT_TOKEN` are set and valid; run `vault status`.
- AWS permissions: the AWS identity must be able to create VPC, EC2, ALB, IAM, KMS, RDS, ElastiCache, CloudWatch, SNS, S3, DynamoDB.
- Backend: HCP Terraform Cloud backend is configured; ensure your organization and workspace are set correctly.
- Key Pair: automatically generated using TLS provider - no manual creation needed.
- Region AMI: we select latest Amazon Linux 2 AMI automatically; ensure the region supports it.
- Logs/Alarms: CloudWatch logs in `/aws/ec2/mlflow/<name-prefix>`; dashboards created automatically.

## SSH Access to EC2 Instances
After deployment, get the private key for SSH access:
```zsh
terraform output -raw private_key_pem > mlflow-dev-private-key.pem
chmod 600 mlflow-dev-private-key.pem
ssh -i mlflow-dev-private-key.pem ec2-user@<INSTANCE_PUBLIC_IP>
```

See `SSH_ACCESS.md` for detailed instructions on connecting to EC2 instances.

## File locations
- This env: `mlflow-infrastructure/environments/dev/`
- Modules: `mlflow-infrastructure/modules/`
- Shared scripts: `mlflow-infrastructure/scripts/`

If you want, I can add a staging quickstart similarly or wire HTTPS/Route53.

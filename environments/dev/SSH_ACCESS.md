# SSH Access to EC2 Instances

This infrastructure now automatically generates an EC2 key pair using the TLS provider. You no longer need to manually create a key pair in the AWS console.

## Getting the Private Key

After running `terraform apply`, you can retrieve the private key using:

```bash
# Get the private key (sensitive output)
terraform output -raw private_key_pem > mlflow-dev-private-key.pem

# Set proper permissions
chmod 600 mlflow-dev-private-key.pem
```

## Connecting to EC2 Instances

To SSH into your EC2 instances:

```bash
# Get the instance IPs (replace with actual instance IP)
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=mlflow-demo" \
           "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].PublicIpAddress' \
  --output text

# Connect using the generated key
ssh -i mlflow-dev-private-key.pem ec2-user@<INSTANCE_PUBLIC_IP>
```

## Security Notes

- The private key is stored in Terraform state (which should be encrypted at rest)
- The key is marked as sensitive in outputs
- For production use, consider using AWS Systems Manager Session Manager for secure access without SSH keys
- Always use proper IAM roles and least-privilege access principles

## Alternative Access Methods

For enhanced security, you can also use AWS Systems Manager Session Manager:

```bash
# Start a session without SSH keys
aws ssm start-session --target <INSTANCE_ID>
```

This requires the EC2 instances to have the SSM agent installed and proper IAM permissions.

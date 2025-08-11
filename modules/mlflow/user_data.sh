#!/bin/bash
set -e

# Variables from Terraform
NAME_PREFIX="${name_prefix}"
S3_BUCKET="${s3_bucket_name}"
DB_CONNECTION_STRING="${database_connection_string}"
CACHE_ENDPOINT="${elasticache_endpoint}"
CACHE_PORT="${elasticache_port}"
VAULT_ADDR="${vault_address}"
VAULT_TOKEN="${vault_token}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
LOG_GROUP="${cloudwatch_log_group}"

# Log all output
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting MLflow server setup for $ENVIRONMENT environment"

# Update system
yum update -y

# Install required packages
yum install -y python3 python3-pip git htop curl wget unzip nginx

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Install CloudWatch agent
yum install -y amazon-cloudwatch-agent

# Configure AWS region
aws configure set region $AWS_REGION

# Create mlflow user
useradd -m -s /bin/bash mlflow
usermod -aG wheel mlflow

# Create application directory
mkdir -p /opt/mlflow/config
mkdir -p /var/log/mlflow
chown -R mlflow:mlflow /opt/mlflow
chown -R mlflow:mlflow /var/log/mlflow

# Install Python dependencies
pip3 install --upgrade pip setuptools wheel

# Install MLflow and dependencies
pip3 install mlflow==2.8.1 boto3==1.34.0 pymysql==1.1.0 redis==5.0.1 gunicorn==21.2.0

# Get database password from SSM Parameter Store (more reliable than Vault for this use case)
echo "Retrieving database password from SSM..."
DB_PASSWORD=$(aws ssm get-parameter --name "/$NAME_PREFIX/database/password" --with-decryption --query 'Parameter.Value' --output text)

if [ -z "$DB_PASSWORD" ]; then
    echo "ERROR: Failed to retrieve database password from SSM"
    exit 1
fi

echo "Database password retrieved successfully"

# Replace PASSWORD placeholder in connection string
ACTUAL_DB_CONNECTION_STRING=$(echo "$DB_CONNECTION_STRING" | sed "s/PASSWORD/$DB_PASSWORD/g")

echo "Database connection string configured"

# Create MLflow startup script
cat > /opt/mlflow/start_mlflow.sh << EOF
#!/bin/bash
export AWS_DEFAULT_REGION="$AWS_REGION"
export MLFLOW_S3_ENDPOINT_URL=""

# Start MLflow server
exec mlflow server \\
    --backend-store-uri "$ACTUAL_DB_CONNECTION_STRING" \\
    --default-artifact-root "s3://$S3_BUCKET/artifacts" \\
    --host 0.0.0.0 \\
    --port 5000 \\
    --workers 4
EOF

chmod +x /opt/mlflow/start_mlflow.sh
chown mlflow:mlflow /opt/mlflow/start_mlflow.sh

# Test database connection before proceeding
echo "Testing database connection..."
python3 -c "
import pymysql
import sys
import os

try:
    # Parse connection string to get components
    conn_str = '$ACTUAL_DB_CONNECTION_STRING'
    # Extract components from mysql+pymysql://user:pass@host:port/db
    import re
    pattern = r'mysql\+pymysql://([^:]+):([^@]+)@([^:]+):(\d+)/(.+)'
    match = re.match(pattern, conn_str)
    if not match:
        print('Failed to parse connection string')
        sys.exit(1)
    
    user, password, host, port, database = match.groups()
    port = int(port)
    
    print(f'Connecting to {host}:{port} as {user}')
    connection = pymysql.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database=database
    )
    connection.close()
    print('Database connection successful!')
except Exception as e:
    print(f'Database connection failed: {e}')
    sys.exit(1)
"

if [ $? -ne 0 ]; then
    echo "ERROR: Database connection test failed. Exiting."
    exit 1
fi

# Create systemd service for MLflow
cat > /etc/systemd/system/mlflow.service << EOF
[Unit]
Description=MLflow Tracking Server
After=network.target
Wants=network.target

[Service]
Type=exec
User=mlflow
Group=mlflow
WorkingDirectory=/opt/mlflow
ExecStart=/opt/mlflow/start_mlflow.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mlflow

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Configure nginx as reverse proxy with health check
cat > /etc/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80 default_server;
    server_name _;
    
    # Health check endpoint for ALB
    location /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "healthy\n";
    }
    
    # Proxy to MLflow
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Remove default nginx config
rm -f /etc/nginx/conf.d/default.conf.bak

# Configure CloudWatch agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/mlflow/server.log",
                        "log_group_name": "$LOG_GROUP",
                        "log_stream_name": "server-{instance_id}",
                        "timezone": "UTC"
                    },
                    {
                        "file_path": "/var/log/user-data.log",
                        "log_group_name": "$LOG_GROUP",
                        "log_stream_name": "user-data-{instance_id}",
                        "timezone": "UTC"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "MLflow/Application",
        "metrics_collected": {
            "cpu": {
                "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
                "metrics_collection_interval": 60
            },
            "mem": {
                "measurement": ["mem_used_percent"],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

# Start and enable services
systemctl daemon-reload

# Start CloudWatch agent first
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Start MLflow
systemctl enable mlflow
systemctl start mlflow

# Wait for MLflow to be ready before starting nginx
echo "Waiting for MLflow to start..."
for i in {1..30}; do
    if curl -f http://localhost:5000/api/2.0/mlflow/experiments/list > /dev/null 2>&1; then
        echo "MLflow is running"
        break
    fi
    echo "Attempt $i: MLflow not ready yet, waiting..."
    sleep 10
done

# Now start nginx
systemctl enable nginx
systemctl start nginx

# Test the health endpoint through nginx
echo "Testing health endpoint..."
for i in {1..10}; do
    if curl -f http://localhost:80/health > /dev/null 2>&1; then
        echo "Health endpoint is working"
        break
    fi
    echo "Attempt $i: Health endpoint not ready yet, waiting..."
    sleep 5
done

# Final status check
echo "Final service status:"
systemctl status nginx --no-pager || echo "Nginx status failed"
systemctl status mlflow --no-pager || echo "MLflow status failed"
systemctl status amazon-cloudwatch-agent --no-pager || echo "CloudWatch agent status failed"

# Test final connectivity
echo "Final connectivity tests:"
curl -I http://localhost:80/health || echo "Health check failed"
curl -f http://localhost:5000/api/2.0/mlflow/experiments/list > /dev/null 2>&1 && echo "MLflow API working" || echo "MLflow API check failed"

echo "MLflow server setup completed successfully"
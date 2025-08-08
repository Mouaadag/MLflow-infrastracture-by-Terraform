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

echo "Starting MLflow server setup for $$ENVIRONMENT environment"

# Update system
yum update -y

# Install required packages
yum install -y python3 python3-pip git htop curl wget unzip

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Install CloudWatch agent
yum install -y amazon-cloudwatch-agent

# Install Vault CLI
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
yum -y install vault

# Configure Vault
export VAULT_ADDR="$$VAULT_ADDR"
export VAULT_TOKEN="$$VAULT_TOKEN"

# Create mlflow user
useradd -m -s /bin/bash mlflow
usermod -aG wheel mlflow

# Create application directory
mkdir -p /opt/mlflow
chown mlflow:mlflow /opt/mlflow

# Install Python dependencies
pip3 install --upgrade pip setuptools wheel

# Create requirements file
cat > /tmp/requirements.txt << EOF
mlflow[extras]==2.8.1
boto3==1.34.0
pymysql==1.1.0
redis==5.0.1
gunicorn==21.2.0
prometheus-client==0.19.0
psutil==5.9.6
cryptography==41.0.8
hvac==2.0.0
EOF

# Install Python packages
pip3 install -r /tmp/requirements.txt

# Create MLflow configuration directory
mkdir -p /opt/mlflow/config
chown mlflow:mlflow /opt/mlflow/config

# Retrieve secrets from Vault
vault kv get -field=password secret/$$ENVIRONMENT/database > /opt/mlflow/config/db_password
vault kv get -field=auth_token secret/$$ENVIRONMENT/cache > /opt/mlflow/config/cache_token
chmod 600 /opt/mlflow/config/*
chown mlflow:mlflow /opt/mlflow/config/*

# Create MLflow configuration file
cat > /opt/mlflow/config/mlflow.conf << EOF
[mlflow]
backend_store_uri = $$DB_CONNECTION_STRING
default_artifact_root = s3://$$S3_BUCKET/artifacts
host = 0.0.0.0
port = 5000
workers = 4

[database]
connection_string = $$DB_CONNECTION_STRING

[cache]
redis_host = $$CACHE_ENDPOINT
redis_port = $$CACHE_PORT
redis_auth_token_file = /opt/mlflow/config/cache_token

[logging]
level = INFO
file = /var/log/mlflow/server.log

[metrics]
enable_prometheus = true
prometheus_port = 8080
EOF

chown mlflow:mlflow /opt/mlflow/config/mlflow.conf

# Create logging directory
mkdir -p /var/log/mlflow
chown mlflow:mlflow /var/log/mlflow

# Create MLflow startup script
cat > /opt/mlflow/start_mlflow.sh << 'EOF'
#!/bin/bash

# Load configuration
source /opt/mlflow/config/mlflow.conf

# Set environment variables
export AWS_DEFAULT_REGION="${aws_region}"
export MLFLOW_S3_ENDPOINT_URL=""
export MLFLOW_TRACKING_URI=""

# Read database password
DB_PASSWORD=$$(cat /opt/mlflow/config/db_password)
DB_TEMPLATE="${database_connection_string}"
# Replace the literal placeholder PASSWORD in the template with the real password
export DB_CONNECTION_STRING="$$(printf '%s' "$$DB_TEMPLATE" | sed "s|PASSWORD|$$DB_PASSWORD|g")"

# Read cache auth token if exists
if [ -f "/opt/mlflow/config/cache_token" ]; then
    CACHE_AUTH_TOKEN=$$(cat /opt/mlflow/config/cache_token)
    export REDIS_URL="redis://default:$$CACHE_AUTH_TOKEN@${elasticache_endpoint}:${elasticache_port}/0"
fi

# Start MLflow server with Gunicorn
exec gunicorn \
    --bind 0.0.0.0:5000 \
    --workers 4 \
    --worker-class sync \
    --worker-connections 1000 \
    --max-requests 1000 \
    --max-requests-jitter 100 \
    --timeout 60 \
    --keepalive 5 \
    --access-logfile /var/log/mlflow/access.log \
    --error-logfile /var/log/mlflow/error.log \
    --log-level info \
    --capture-output \
    --enable-stdio-inheritance \
    mlflow.server:app \
    --backend-store-uri "$$DB_CONNECTION_STRING" \
    --default-artifact-root "s3://${s3_bucket_name}/artifacts" \
    --host 0.0.0.0 \
    --port 5000
EOF

chmod +x /opt/mlflow/start_mlflow.sh
chown mlflow:mlflow /opt/mlflow/start_mlflow.sh

# Create health check endpoint script
cat > /opt/mlflow/health_check.py << 'EOF'
#!/usr/bin/env python3
import json
import os
import sys
import time
import requests
import psutil
from prometheus_client import start_http_server, Gauge, Counter

# Metrics
health_check_gauge = Gauge('mlflow_health_status', 'MLflow health status')
request_counter = Counter('mlflow_health_checks_total', 'Total health checks')

def check_mlflow_health():
    try:
        response = requests.get('http://localhost:5000/health', timeout=5)
        if response.status_code == 200:
            health_check_gauge.set(1)
            return True
        else:
            health_check_gauge.set(0)
            return False
    except Exception as e:
        health_check_gauge.set(0)
        return False

def get_system_metrics():
    cpu_percent = psutil.cpu_percent()
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    
    return {
        'cpu_percent': cpu_percent,
        'memory_percent': memory.percent,
        'disk_percent': disk.percent
    }

if __name__ == "__main__":
    # Start prometheus metrics server
    start_http_server(8080)
    
    while True:
        request_counter.inc()
        is_healthy = check_mlflow_health()
        metrics = get_system_metrics()
        
        status = {
            'status': 'healthy' if is_healthy else 'unhealthy',
            'timestamp': time.time(),
            'metrics': metrics
        }
        
        print(json.dumps(status))
        time.sleep(30)
EOF

chmod +x /opt/mlflow/health_check.py
chown mlflow:mlflow /opt/mlflow/health_check.py

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
LimitNPROC=32768

# Security
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/mlflow /opt/mlflow

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for health check
cat > /etc/systemd/system/mlflow-health.service << EOF
[Unit]
Description=MLflow Health Check Service
After=mlflow.service
Requires=mlflow.service

[Service]
Type=simple
User=mlflow
Group=mlflow
WorkingDirectory=/opt/mlflow
ExecStart=/usr/bin/python3 /opt/mlflow/health_check.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mlflow-health

[Install]
WantedBy=multi-user.target
EOF

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
                        "log_group_name": "$$LOG_GROUP",
                        "log_stream_name": "server-{instance_id}",
                        "timezone": "UTC"
                    },
                    {
                        "file_path": "/var/log/mlflow/access.log",
                        "log_group_name": "$$LOG_GROUP",
                        "log_stream_name": "access-{instance_id}",
                        "timezone": "UTC"
                    },
                    {
                        "file_path": "/var/log/mlflow/error.log",
                        "log_group_name": "$$LOG_GROUP",
                        "log_stream_name": "error-{instance_id}",
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
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_system",
                    "cpu_usage_user"
                ],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time",
                    "read_bytes",
                    "write_bytes",
                    "reads",
                    "writes"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            },
            "netstat": {
                "measurement": [
                    "tcp_established",
                    "tcp_time_wait"
                ],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

# Initialize the database
sudo -u mlflow python3 -c "
import mlflow
from mlflow.store.db.base_sql_store import BaseSqlStore
from mlflow.store.db.utils import create_default_experiment_and_user

# Initialize database tables
store = BaseSqlStore('$$DB_CONNECTION_STRING', '/tmp')
store._initialize_tables()
create_default_experiment_and_user(store)
print('Database initialized successfully')
"

# Start and enable services
systemctl daemon-reload
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

systemctl enable mlflow
systemctl start mlflow

systemctl enable mlflow-health
systemctl start mlflow-health

# Wait for services to start
sleep 10

# Verify services are running
systemctl status mlflow --no-pager
systemctl status mlflow-health --no-pager

# Create a simple health check endpoint for ALB
mkdir -p /var/www/html
cat > /var/www/html/health << 'EOF'
#!/bin/bash
if curl -f http://localhost:5000/api/2.0/mlflow/experiments/list > /dev/null 2>&1; then
    echo "Status: 200 OK"
    echo "Content-Type: text/plain"
    echo ""
    echo "OK"
else
    echo "Status: 503 Service Unavailable"
    echo "Content-Type: text/plain"
    echo ""
    echo "Service Unavailable"
fi
EOF

chmod +x /var/www/html/health

# Install and configure nginx for health checks
yum install -y nginx
cat > /etc/nginx/conf.d/health.conf << 'EOF'
server {
    listen 80;
    server_name _;
    
    location /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "OK\n";
    }
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $$host;
        proxy_set_header X-Real-IP $$remote_addr;
        proxy_set_header X-Forwarded-For $$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $$scheme;
    }
}
EOF

systemctl enable nginx
systemctl start nginx

echo "MLflow server setup completed successfully"
echo "Services status:"
systemctl status mlflow --no-pager -l
systemctl status mlflow-health --no-pager -l
systemctl status nginx --no-pager -l
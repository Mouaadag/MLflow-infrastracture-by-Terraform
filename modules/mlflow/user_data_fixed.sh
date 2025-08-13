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

echo "Starting MLflow server setup for $ENVIRONMENT environment on Amazon Linux 2023"

# Fix curl conflict first (AL2023 specific issue)
dnf remove -y curl-minimal || true
dnf install -y curl

# Update system
dnf update -y

# Install Python 3.11 from AL2023 repositories (much easier than compiling!)
dnf install -y python3.11 python3.11-pip python3.11-devel

# Install build dependencies
dnf groupinstall -y "Development Tools"
dnf install -y openssl-devel bzip2-devel libffi-devel xz-devel sqlite-devel zlib-devel git htop wget unzip

# Create symlinks for easier access
ln -sf /usr/bin/python3.11 /usr/local/bin/python3
ln -sf /usr/bin/pip3.11 /usr/local/bin/pip3

# Update PATH to prioritize our Python 3.11
export PATH="/usr/local/bin:$PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile

# Install nginx 1.29.0 from source (as AL2023 repos don't have the latest version)
cd /tmp
wget http://nginx.org/download/nginx-1.29.0.tar.gz
tar -xzf nginx-1.29.0.tar.gz
cd nginx-1.29.0

# Install nginx build dependencies
dnf install -y pcre-devel zlib-devel

# Configure and compile nginx
./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib64/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module

make && make install

# Create nginx user and directories
useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" --user-group nginx || true
mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
mkdir -p /etc/nginx/conf.d
mkdir -p /var/log/nginx
chown -R nginx:nginx /var/cache/nginx /var/log/nginx

# Create nginx systemd service
cat > /etc/systemd/system/nginx.service << 'EOF'
[Unit]
Description=The nginx HTTP and reverse proxy server
Documentation=http://nginx.org/en/docs/
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=5
KillMode=process
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Create basic nginx.conf
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
}
EOF

# Install AWS CLI v2
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# Install CloudWatch agent
dnf install -y amazon-cloudwatch-agent

# Configure AWS region
aws configure set region $AWS_REGION

# Create mlflow user
useradd -m -s /bin/bash mlflow || true
usermod -aG wheel mlflow || true

# Create application directory
mkdir -p /opt/mlflow/config
mkdir -p /var/log/mlflow
chown -R mlflow:mlflow /opt/mlflow
chown -R mlflow:mlflow /var/log/mlflow

# Install Python dependencies using Python 3.11
/usr/bin/python3.11 -m pip install --upgrade pip setuptools wheel

# Install MLflow 3.2.0 and dependencies
/usr/bin/python3.11 -m pip install mlflow==3.2.0 boto3==1.35.0 pymysql==1.1.1 redis==5.1.1 gunicorn==23.0.0

# Get database password from SSM Parameter Store
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
export PATH="/usr/local/bin:\$PATH"

# Start MLflow server using Python 3.11
exec /usr/bin/python3.11 -m mlflow server \\
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
/usr/bin/python3.11 -c "
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
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
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

echo "MLflow server setup completed successfully with Python 3.11, MLflow 3.2.0, and nginx 1.29.0 on Amazon Linux 2023"

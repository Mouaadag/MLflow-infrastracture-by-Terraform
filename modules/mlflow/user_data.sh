#!/bin/bash
set -e

# Variables from Terraform (with defaults for manual testing)
NAME_PREFIX="${name_prefix:-mlflow-test}"
S3_BUCKET="${s3_bucket_name:-mlflow-test-bucket}"
DB_CONNECTION_STRING="${database_connection_string:-sqlite:////opt/mlflow/mlflow.db}"
CACHE_ENDPOINT="${elasticache_endpoint:-}"
CACHE_PORT="${elasticache_port:-6379}"
VAULT_ADDR="${vault_address:-}"
VAULT_TOKEN="${vault_token:-}"
ENVIRONMENT="${environment:-dev}"
AWS_REGION="${aws_region:-us-east-1}"
LOG_GROUP="${cloudwatch_log_group:-/aws/ec2/mlflow}"

# Log all output
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting MLflow server setup for $ENVIRONMENT environment on Amazon Linux 2023"
echo "Current memory status:"
free -h

# Check available memory and set appropriate flags
TOTAL_MEM=$(free -m | awk 'NR==2{printf "%.0f", $2}')
echo "Total memory: ${TOTAL_MEM}MB"

if [ "$TOTAL_MEM" -lt 2048 ]; then
    echo "WARNING: Low memory detected (${TOTAL_MEM}MB). Using conservative approach."
    LOW_MEMORY=true
else
    echo "Sufficient memory detected (${TOTAL_MEM}MB). Using standard approach."
    LOW_MEMORY=false
fi

# Function to check if process succeeded or was killed by OOM
check_oom() {
    if [ $? -eq 137 ] || [ $? -eq 143 ]; then
        echo "ERROR: Process was likely killed due to out of memory"
        echo "Current memory status:"
        free -h
        return 1
    fi
    return 0
}

# Fix curl conflict first (AL2023 specific issue)
echo "Fixing curl-minimal conflict..."
dnf remove -y curl-minimal 2>/dev/null || true
dnf install -y curl
check_oom || exit 1

# Update system with memory considerations
echo "Updating system packages..."
if [ "$LOW_MEMORY" = true ]; then
    echo "Skipping full system update due to low memory"
else
    dnf update -y
    check_oom || exit 1
fi

# Install Python 3.11 from AL2023 repositories
echo "Installing Python 3.11 and basic development tools..."
dnf install -y python3.11 python3.11-pip python3.11-devel
check_oom || exit 1

# Install essential build dependencies
echo "Installing essential build tools..."
if [ "$LOW_MEMORY" = true ]; then
    # Install minimal build tools for low memory systems
    dnf install -y gcc gcc-c++ make openssl-devel bzip2-devel libffi-devel xz-devel sqlite-devel zlib-devel
    check_oom || exit 1
else
    # Install full development tools
    dnf groupinstall -y "Development Tools"
    check_oom || exit 1
    dnf install -y openssl-devel bzip2-devel libffi-devel xz-devel sqlite-devel zlib-devel
    check_oom || exit 1
fi

# Install additional utilities
echo "Installing additional utilities..."
dnf install -y git htop wget unzip
check_oom || exit 1

# Create symlinks for easier access
ln -sf /usr/bin/python3.11 /usr/local/bin/python3
ln -sf /usr/bin/pip3.11 /usr/local/bin/pip3

# Update PATH to prioritize our Python 3.11
export PATH="/usr/local/bin:$PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile

# Install nginx with fallback options
echo "Installing nginx..."

# Function to install nginx from repository (fallback for low memory)
install_nginx_from_repo() {
    echo "Installing nginx from repository (fallback option)..."
    dnf install -y nginx
    check_oom || exit 1
    
    # Create basic directories that might be missing
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
    
    echo "Nginx installed from repository"
    return 0
}

# Function to compile nginx from source
compile_nginx_from_source() {
    echo "Compiling nginx 1.29.0 from source..."
    
    cd /tmp
    wget http://nginx.org/download/nginx-1.29.0.tar.gz
    tar -xzf nginx-1.29.0.tar.gz
    cd nginx-1.29.0
    
    # Install nginx build dependencies
    dnf install -y pcre-devel zlib-devel
    check_oom || exit 1
    
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
    check_oom || exit 1
    
    echo "Nginx compiled successfully from source"
    return 0
}

# Try to compile from source first, fall back to repository if needed
if [ "$LOW_MEMORY" = true ]; then
    echo "Using repository nginx due to low memory"
    install_nginx_from_repo
    NGINX_FROM_REPO=true
else
    echo "Attempting to compile nginx from source"
    if ! compile_nginx_from_source; then
        echo "Source compilation failed, falling back to repository version"
        install_nginx_from_repo
        NGINX_FROM_REPO=true
    else
        NGINX_FROM_REPO=false
    fi
fi

# Create nginx user and directories (only if not from repo)
if [ "$NGINX_FROM_REPO" = false ]; then
    echo "Setting up nginx user and directories..."
    useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" --user-group nginx 2>/dev/null || true
    mkdir -p /var/cache/nginx/{client_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx
    
    # Create nginx systemd service (custom compiled version)
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
else
    echo "Using repository nginx, systemd service already configured"
    # Ensure directories exist
    mkdir -p /etc/nginx/conf.d
    mkdir -p /var/log/nginx
fi

# Create basic nginx.conf (works for both compiled and repository versions)
echo "Creating nginx configuration..."
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /var/run/nginx.pid;

# Load dynamic modules if available
include /usr/share/nginx/modules/*.conf;

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

    # Include server configurations
    include /etc/nginx/conf.d/*.conf;
}
EOF

# Install AWS CLI v2
echo "Installing AWS CLI v2..."
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
check_oom || exit 1

# Install CloudWatch agent
echo "Installing CloudWatch agent..."
dnf install -y amazon-cloudwatch-agent
check_oom || exit 1

# Configure AWS region
aws configure set region $AWS_REGION

# Create mlflow user
useradd -m -s /bin/bash mlflow 2>/dev/null || true
usermod -aG wheel mlflow 2>/dev/null || true

# Create application directory
mkdir -p /opt/mlflow/config
mkdir -p /var/log/mlflow
chown -R mlflow:mlflow /opt/mlflow
chown -R mlflow:mlflow /var/log/mlflow

# Install Python dependencies using Python 3.11
echo "Installing Python dependencies..."
/usr/bin/python3.11 -m pip install --upgrade pip setuptools wheel
check_oom || exit 1

# Install MLflow 3.2.0 and dependencies
echo "Installing MLflow and dependencies..."
/usr/bin/python3.11 -m pip install mlflow==3.2.0 boto3==1.35.0 pymysql==1.1.1 redis==5.1.1 gunicorn==23.0.0
check_oom || exit 1

# Handle database connection string and password
echo "Configuring database connection..."

# Check if we're using SQLite (for testing/dev)
if [[ "$DB_CONNECTION_STRING" == sqlite://* ]]; then
    echo "Using SQLite database for testing/development"
    ACTUAL_DB_CONNECTION_STRING="$DB_CONNECTION_STRING"
    
    # Ensure SQLite directory exists
    SQLITE_DIR=$(dirname "${DB_CONNECTION_STRING#sqlite://}")
    mkdir -p "$SQLITE_DIR"
    chown -R mlflow:mlflow "$SQLITE_DIR"
    
else
    # For MySQL/PostgreSQL, get password from SSM Parameter Store
    echo "Retrieving database password from SSM..."
    
    # Try to get the password from SSM
    DB_PASSWORD=""
    if command -v aws >/dev/null 2>&1; then
        DB_PASSWORD=$(aws ssm get-parameter --name "/$NAME_PREFIX/database/password" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    fi
    
    if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "None" ]; then
        echo "WARNING: Failed to retrieve database password from SSM. Falling back to SQLite for testing."
        ACTUAL_DB_CONNECTION_STRING="sqlite:////opt/mlflow/mlflow.db"
        mkdir -p /opt/mlflow
        chown -R mlflow:mlflow /opt/mlflow
    else
        echo "Database password retrieved successfully"
        # Replace PASSWORD placeholder in connection string
        ACTUAL_DB_CONNECTION_STRING=$(echo "$DB_CONNECTION_STRING" | sed "s/PASSWORD/$DB_PASSWORD/g")
    fi
fi

echo "Database connection string configured: $(echo "$ACTUAL_DB_CONNECTION_STRING" | sed 's/:[^:@]*@/:***@/g')"

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

if [[ "$ACTUAL_DB_CONNECTION_STRING" == sqlite://* ]]; then
    echo "Using SQLite database - no connection test needed"
    # Test SQLite file creation
    SQLITE_FILE="${ACTUAL_DB_CONNECTION_STRING#sqlite://}"
    SQLITE_DIR=$(dirname "$SQLITE_FILE")
    mkdir -p "$SQLITE_DIR"
    touch "$SQLITE_FILE"
    chown mlflow:mlflow "$SQLITE_FILE"
    echo "SQLite database file prepared at $SQLITE_FILE"
else
    # Test MySQL/PostgreSQL connection
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
        database=database,
        connect_timeout=10
    )
    connection.close()
    print('Database connection successful!')
except Exception as e:
    print(f'Database connection failed: {e}')
    sys.exit(1)
"

    if [ $? -ne 0 ]; then
        echo "WARNING: Database connection test failed. Falling back to SQLite for testing."
        ACTUAL_DB_CONNECTION_STRING="sqlite:////opt/mlflow/mlflow.db"
        mkdir -p /opt/mlflow
        touch /opt/mlflow/mlflow.db
        chown -R mlflow:mlflow /opt/mlflow
        echo "Using SQLite fallback database"
    fi
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
cat > /etc/nginx/conf.d/mlflow.conf << 'EOF'
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
        
        # Handle large file uploads
        client_max_body_size 100M;
    }
}
EOF

# Remove any conflicting default configurations
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Configure CloudWatch agent
echo "Configuring CloudWatch agent..."
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
                    },
                    {
                        "file_path": "/var/log/nginx/access.log",
                        "log_group_name": "$LOG_GROUP",
                        "log_stream_name": "nginx-access-{instance_id}",
                        "timezone": "UTC"
                    },
                    {
                        "file_path": "/var/log/nginx/error.log",
                        "log_group_name": "$LOG_GROUP",
                        "log_stream_name": "nginx-error-{instance_id}",
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
            },
            "disk": {
                "measurement": ["used_percent"],
                "metrics_collection_interval": 60,
                "resources": ["*"]
            }
        }
    }
}
EOF

# Start and enable services with proper error handling
echo "Starting and enabling services..."
systemctl daemon-reload

# Start CloudWatch agent first
echo "Starting CloudWatch agent..."
if ! systemctl enable amazon-cloudwatch-agent; then
    echo "WARNING: Failed to enable CloudWatch agent"
fi
if ! systemctl start amazon-cloudwatch-agent; then
    echo "WARNING: Failed to start CloudWatch agent"
    systemctl status amazon-cloudwatch-agent --no-pager || true
fi

# Start MLflow
echo "Starting MLflow service..."
if ! systemctl enable mlflow; then
    echo "ERROR: Failed to enable MLflow service"
    exit 1
fi
if ! systemctl start mlflow; then
    echo "ERROR: Failed to start MLflow service"
    systemctl status mlflow --no-pager || true
    journalctl -u mlflow -n 50 --no-pager || true
    exit 1
fi

# Wait for MLflow to be ready before starting nginx
echo "Waiting for MLflow to start..."
MLFLOW_READY=false
for i in {1..60}; do
    if curl -f http://localhost:5000/api/2.0/mlflow/experiments/list > /dev/null 2>&1; then
        echo "MLflow is running (attempt $i)"
        MLFLOW_READY=true
        break
    fi
    echo "Attempt $i/60: MLflow not ready yet, waiting..."
    sleep 10
done

if [ "$MLFLOW_READY" = false ]; then
    echo "ERROR: MLflow failed to start within timeout period"
    echo "MLflow service status:"
    systemctl status mlflow --no-pager || true
    echo "MLflow logs:"
    journalctl -u mlflow -n 100 --no-pager || true
    exit 1
fi

# Test nginx configuration before starting
echo "Testing nginx configuration..."
if ! nginx -t; then
    echo "ERROR: Nginx configuration test failed"
    exit 1
fi

# Now start nginx
echo "Starting nginx service..."
if ! systemctl enable nginx; then
    echo "ERROR: Failed to enable nginx service"
    exit 1
fi
if ! systemctl start nginx; then
    echo "ERROR: Failed to start nginx service"
    systemctl status nginx --no-pager || true
    journalctl -u nginx -n 50 --no-pager || true
    exit 1
fi

# Test the health endpoint through nginx
echo "Testing health endpoint..."
HEALTH_READY=false
for i in {1..20}; do
    if curl -f http://localhost:80/health > /dev/null 2>&1; then
        echo "Health endpoint is working (attempt $i)"
        HEALTH_READY=true
        break
    fi
    echo "Attempt $i/20: Health endpoint not ready yet, waiting..."
    sleep 5
done

if [ "$HEALTH_READY" = false ]; then
    echo "WARNING: Health endpoint not responding, but continuing..."
fi

# Final status check and summary
echo "=== Final service status ==="
echo "System memory:"
free -h

echo "Service statuses:"
systemctl is-active nginx && echo "✓ Nginx: Active" || echo "✗ Nginx: Inactive"
systemctl is-active mlflow && echo "✓ MLflow: Active" || echo "✗ MLflow: Inactive"
systemctl is-active amazon-cloudwatch-agent && echo "✓ CloudWatch Agent: Active" || echo "✗ CloudWatch Agent: Inactive"

# Final connectivity tests
echo "=== Final connectivity tests ==="
curl -I http://localhost:80/health 2>/dev/null && echo "✓ Health check endpoint: OK" || echo "✗ Health check endpoint: FAILED"
curl -f http://localhost:5000/api/2.0/mlflow/experiments/list > /dev/null 2>&1 && echo "✓ MLflow API: OK" || echo "✗ MLflow API: FAILED"

# Display important information
echo "=== Setup Summary ==="
echo "Environment: $ENVIRONMENT"
echo "Python version: $(/usr/bin/python3.11 --version)"
echo "MLflow version: $(/usr/bin/python3.11 -c 'import mlflow; print(mlflow.__version__)' 2>/dev/null || echo 'Unknown')"
echo "Nginx version: $(nginx -v 2>&1 | cut -d' ' -f3 || echo 'Unknown')"
echo "Database: $(echo "$ACTUAL_DB_CONNECTION_STRING" | sed 's/:[^:@]*@/:***@/g')"
echo "S3 Bucket: $S3_BUCKET"
echo "Nginx from repository: ${NGINX_FROM_REPO:-unknown}"
echo "Low memory mode: ${LOW_MEMORY:-unknown}"

echo "MLflow server setup completed successfully with Python 3.11, MLflow 3.2.0, and nginx on Amazon Linux 2023"
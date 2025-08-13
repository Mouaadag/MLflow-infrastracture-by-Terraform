#!/bin/bash
set -euo pipefail

# ========= VARIABLES PROVIDED BY TERRAFORM (required) =========
NAME_PREFIX="${name_prefix}"
S3_BUCKET="${s3_bucket_name}"
AWS_REGION="${aws_region}"

DB_HOST="${database_host}"
DB_PORT="${database_port:-3306}"
DB_NAME="${database_name}"
DB_USER="${database_user}"
SSM_PASSWORD_PARAM="${ssm_password_parameter}"   # e.g. /mlflow/db/password

CLOUDWATCH_LOG_GROUP="${cloudwatch_log_group}"   # e.g. /mlflow/prod

MLFLOW_PORT=5000

# ========= LOGGING (user-data) =========
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "[INFO] User-data started at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ========= BASIC VALIDATION =========
for v in NAME_PREFIX S3_BUCKET AWS_REGION DB_HOST DB_PORT DB_NAME DB_USER SSM_PASSWORD_PARAM CLOUDWATCH_LOG_GROUP; do
  if [ -z "${!v:-}" ]; then
    echo "[ERROR] Missing required variable: $v"
    exit 1
  fi
done

# ========= SYSTEM PREP =========
echo "[INFO] Updating system and installing base packages..."
dnf update -y
dnf install -y python3.11 python3.11-pip nginx awscli amazon-cloudwatch-agent \
               git wget unzip htop

# Ensure python3/pip3 point to 3.11
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2 || true
alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.11 2 || true

# ========= SERIAL CONSOLE (OS-side) =========
# NOTE: You must also enable the EC2 Serial Console at the account level and have IAM permissions to use it.
systemctl enable serial-getty@ttyS0.service
systemctl start serial-getty@ttyS0.service
echo 'ec2-user:MLflowSerial2024!' | chpasswd || true
echo "[INFO] Serial console login enabled for ec2-user (password set)."

# ========= FETCH DB PASSWORD FROM SSM =========
echo "[INFO] Fetching DB password from SSM: ${SSM_PASSWORD_PARAM}"
DB_PASSWORD="$(aws ssm get-parameter \
  --name "${SSM_PASSWORD_PARAM}" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "${AWS_REGION}" || true)"

if [ -z "${DB_PASSWORD}" ]; then
  echo "[ERROR] Failed to retrieve DB password from SSM."
  exit 1
fi

DB_CONNECTION_STRING="mysql+pymysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# ========= APPLICATION USER & DIRS =========
id -u mlflow >/dev/null 2>&1 || useradd -m -s /bin/bash mlflow
mkdir -p /opt/mlflow /var/log/mlflow
chown -R mlflow:mlflow /opt/mlflow /var/log/mlflow

# ========= PYTHON/MLFLOW INSTALL =========
echo "[INFO] Installing MLflow and deps with pip..."
/usr/bin/pip3.11 install --upgrade pip setuptools wheel
/usr/bin/pip3.11 install mlflow==3.2.0 boto3==1.35.0 pymysql==1.1.1 gunicorn==23.0.0

# ========= MLflow START SCRIPT (logs to file for CloudWatch) =========
cat >/opt/mlflow/start_mlflow.sh <<EOF
#!/bin/bash
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_REGION}"

LOG_FILE="/var/log/mlflow/server.log"
mkdir -p \$(dirname "\${LOG_FILE}")
touch "\${LOG_FILE}"
chown mlflow:mlflow "\${LOG_FILE}"

# Exec MLflow and redirect stdout/stderr to the log file
exec /usr/bin/python3.11 -m mlflow server \\
  --backend-store-uri "${DB_CONNECTION_STRING}" \\
  --default-artifact-root "s3://${S3_BUCKET}/artifacts" \\
  --host 0.0.0.0 \\
  --port ${MLFLOW_PORT} >> "\${LOG_FILE}" 2>&1
EOF
chmod +x /opt/mlflow/start_mlflow.sh
chown mlflow:mlflow /opt/mlflow/start_mlflow.sh

# ========= SYSTEMD SERVICE FOR MLFLOW =========
cat >/etc/systemd/system/mlflow.service <<'EOF'
[Unit]
Description=MLflow Tracking Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=mlflow
Group=mlflow
WorkingDirectory=/opt/mlflow
ExecStart=/opt/mlflow/start_mlflow.sh
Restart=always
RestartSec=10
# Increase file descriptor limit (useful under load)
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ========= NGINX REVERSE PROXY (with /health) =========
cat >/etc/nginx/conf.d/mlflow.conf <<EOF
server {
    listen 80;
    server_name _;

    # ALB/NLB health check
    location /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 'healthy\n';
    }

    # Proxy to MLflow backend
    location / {
        proxy_pass http://127.0.0.1:${MLFLOW_PORT};
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

# Validate nginx config now (but start after MLflow is ready)
nginx -t

# ========= CLOUDWATCH AGENT CONFIG (ship key logs) =========
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "${CLOUDWATCH_LOG_GROUP}",
            "log_stream_name": "user-data-{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/mlflow/server.log",
            "log_group_name": "${CLOUDWATCH_LOG_GROUP}",
            "log_stream_name": "mlflow-{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "${CLOUDWATCH_LOG_GROUP}",
            "log_stream_name": "nginx-error-{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOF

# ========= START SERVICES (CloudWatch → MLflow → verify → nginx) =========
systemctl daemon-reload
systemctl enable amazon-cloudwatch-agent mlflow
systemctl start amazon-cloudwatch-agent
systemctl start mlflow

echo "[INFO] Waiting for MLflow (port ${MLFLOW_PORT})..."
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${MLFLOW_PORT}/api/2.0/mlflow/experiments/list" >/dev/null; then
    echo "[INFO] MLflow API responding."
    break
  fi
  echo "[WARN] MLflow not ready yet (attempt $i/30)."
  sleep 5
done

# If MLflow is still not responding, print service logs for visibility
if ! curl -fsS "http://127.0.0.1:${MLFLOW_PORT}/api/2.0/mlflow/experiments/list" >/dev/null; then
  echo "[ERROR] MLflow failed to start. Recent logs:"
  tail -n 200 /var/log/mlflow/server.log || true
  systemctl status mlflow --no-pager || true
  exit 1
fi

# Start nginx after MLflow is healthy to avoid 502s during boot
systemctl enable nginx
systemctl restart nginx

# ========= FINAL CHECKS =========
echo "[INFO] Final port check:"
ss -tulpn | grep -E '(:80|:5000)' || echo "No process listening on 80 or 5000!"

echo "[INFO] Health endpoint via nginx:"
if curl -fsS http://127.0.0.1/health >/dev/null; then
  echo "[INFO] /health OK"
else
  echo "[ERROR] /health failed"
fi

echo "[INFO] Completed at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

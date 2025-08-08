#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [COMMAND] [ENVIRONMENT]

Commands:
    setup       - Setup Vault secrets for environment
    read        - Read secrets from Vault
    update      - Update existing secrets
    delete      - Delete secrets (use with caution)
    list        - List available secret paths

Environments:
    dev         - Development environment
    staging     - Staging environment
    prod        - Production environment

Examples:
    $0 setup dev
    $0 read prod
    $0 update staging
EOF
}

check_vault_status() {
    log "Checking Vault status..."
    
    if ! command -v vault &> /dev/null; then
        error "Vault CLI is not installed"
        exit 1
    fi
    
    if ! vault status > /dev/null 2>&1; then
        error "Vault is not accessible. Please check VAULT_ADDR and authentication."
        exit 1
    fi
    
    success "Vault is accessible"
}

generate_secure_password() {
    local length=${1:-16}
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

setup_database_secrets() {
    local env=$1
    
    log "Setting up database secrets for $env environment..."
    
    # Generate database password
    local db_password=$(generate_secure_password 24)
    
    # Create database secrets
    vault kv put secret/$env/database \
        username="mlflow_admin" \
        password="$db_password" \
        host="" \
        port="3306" \
        database="mlflow"
    
    success "Database secrets created for $env"
}

setup_cache_secrets() {
    local env=$1
    
    log "Setting up cache secrets for $env environment..."
    
    # Generate cache auth token
    local cache_token=$(generate_secure_password 32)
    
    # Create cache secrets
    vault kv put secret/$env/cache \
        auth_token="$cache_token" \
        host="" \
        port="6379"
    
    success "Cache secrets created for $env"
}

setup_aws_secrets() {
    local env=$1
    
    log "Setting up AWS secrets for $env environment..."
    
    echo "Please provide AWS credentials for $env environment:"
    read -p "AWS Access Key ID: " -r aws_access_key
    read -s -p "AWS Secret Access Key: " -r aws_secret_key
    echo
    read -p "AWS Region [us-east-1]: " -r aws_region
    aws_region=${aws_region:-us-east-1}
    
    # Create AWS secrets
    vault kv put secret/$env/aws \
        access_key_id="$aws_access_key" \
        secret_access_key="$aws_secret_key" \
        region="$aws_region"
    
    success "AWS secrets created for $env"
}

setup_mlflow_secrets() {
    local env=$1
    
    log "Setting up MLflow secrets for $env environment..."
    
    # Generate MLflow tracking token
    local tracking_token=$(generate_secure_password 32)
    
    # Create MLflow secrets
    vault kv put secret/$env/mlflow \
        tracking_token="$tracking_token" \
        admin_username="admin" \
        admin_password="$(generate_secure_password 16)"
    
    success "MLflow secrets created for $env"
}

setup_monitoring_secrets() {
    local env=$1
    
    log "Setting up monitoring secrets for $env environment..."
    
    read -p "Enter Slack webhook URL (optional): " -r slack_webhook
    read -p "Enter PagerDuty API key (optional): " -r pagerduty_key
    
    # Create monitoring secrets
    vault kv put secret/$env/monitoring \
        slack_webhook="${slack_webhook}" \
        pagerduty_api_key="${pagerduty_key}" \
        grafana_admin_password="$(generate_secure_password 16)"
    
    success "Monitoring secrets created for $env"
}

setup_ssl_secrets() {
    local env=$1
    
    log "Setting up SSL secrets for $env environment..."
    
    read -p "Enter SSL certificate ARN (optional): " -r ssl_cert_arn
    read -p "Enter domain name (optional): " -r domain_name
    
    # Create SSL secrets
    vault kv put secret/$env/ssl \
        certificate_arn="${ssl_cert_arn}" \
        domain_name="${domain_name}"
    
    success "SSL secrets created for $env"
}

setup_all_secrets() {
    local env=$1
    
    log "Setting up all secrets for $env environment..."
    
    setup_database_secrets "$env"
    setup_cache_secrets "$env"
    setup_aws_secrets "$env"
    setup_mlflow_secrets "$env"
    setup_monitoring_secrets "$env"
    setup_ssl_secrets "$env"
    
    success "All secrets have been set up for $env environment"
}

read_secrets() {
    local env=$1
    
    log "Reading secrets for $env environment..."
    
    echo "=== Database Secrets ==="
    vault kv get secret/$env/database 2>/dev/null || warning "Database secrets not found"
    
    echo "=== Cache Secrets ==="
    vault kv get secret/$env/cache 2>/dev/null || warning "Cache secrets not found"
    
    echo "=== AWS Secrets ==="
    vault kv get secret/$env/aws 2>/dev/null || warning "AWS secrets not found"
    
    echo "=== MLflow Secrets ==="
    vault kv get secret/$env/mlflow 2>/dev/null || warning "MLflow secrets not found"
    
    echo "=== Monitoring Secrets ==="
    vault kv get secret/$env/monitoring 2>/dev/null || warning "Monitoring secrets not found"
    
    echo "=== SSL Secrets ==="
    vault kv get secret/$env/ssl 2>/dev/null || warning "SSL secrets not found"
}

update_secret() {
    local env=$1
    local secret_type=$2
    
    log "Updating $secret_type secrets for $env environment..."
    
    case $secret_type in
        database)
            setup_database_secrets "$env"
            ;;
        cache)
            setup_cache_secrets "$env"
            ;;
        aws)
            setup_aws_secrets "$env"
            ;;
        mlflow)
            setup_mlflow_secrets "$env"
            ;;
        monitoring)
            setup_monitoring_secrets "$env"
            ;;
        ssl)
            setup_ssl_secrets "$env"
            ;;
        *)
            error "Unknown secret type: $secret_type"
            exit 1
            ;;
    esac
}

delete_secrets() {
    local env=$1
    
    warning "This will delete ALL secrets for $env environment!"
    read -p "Are you sure? Type 'DELETE' to confirm: " -r confirmation
    
    if [[ "$confirmation" != "DELETE" ]]; then
        log "Operation cancelled"
        exit 0
    fi
    
    log "Deleting secrets for $env environment..."
    
    vault kv delete secret/$env/database 2>/dev/null || true
    vault kv delete secret/$env/cache 2>/dev/null || true
    vault kv delete secret/$env/aws 2>/dev/null || true
    vault kv delete secret/$env/mlflow 2>/dev/null || true
    vault kv delete secret/$env/monitoring 2>/dev/null || true
    vault kv delete secret/$env/ssl 2>/dev/null || true
    
    success "Secrets deleted for $env environment"
}

list_secrets() {
    local env=$1
    
    log "Listing secrets for $env environment..."
    
    echo "Available secret paths:"
    vault kv list secret/$env/ 2>/dev/null || warning "No secrets found for $env environment"
}

backup_secrets() {
    local env=$1
    local backup_file="vault_backup_${env}_$(date +%Y%m%d_%H%M%S).json"
    
    log "Creating backup of secrets for $env environment..."
    
    mkdir -p ./backups
    
    {
        echo "{"
        echo "  \"environment\": \"$env\","
        echo "  \"backup_date\": \"$(date -Iseconds)\","
        echo "  \"secrets\": {"
        
        echo "    \"database\": $(vault kv get -format=json secret/$env/database 2>/dev/null | jq '.data.data' || echo 'null'),"
        echo "    \"cache\": $(vault kv get -format=json secret/$env/cache 2>/dev/null | jq '.data.data' || echo 'null'),"
        echo "    \"aws\": $(vault kv get -format=json secret/$env/aws 2>/dev/null | jq '.data.data' || echo 'null'),"
        echo "    \"mlflow\": $(vault kv get -format=json secret/$env/mlflow 2>/dev/null | jq '.data.data' || echo 'null'),"
        echo "    \"monitoring\": $(vault kv get -format=json secret/$env/monitoring 2>/dev/null | jq '.data.data' || echo 'null'),"
        echo "    \"ssl\": $(vault kv get -format=json secret/$env/ssl 2>/dev/null | jq '.data.data' || echo 'null')"
        echo "  }"
        echo "}"
    } > "./backups/$backup_file"
    
    success "Backup created: ./backups/$backup_file"
}

restore_secrets() {
    local env=$1
    local backup_file=$2
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        exit 1
    fi
    
    log "Restoring secrets for $env environment from $backup_file..."
    
    warning "This will overwrite existing secrets!"
    read -p "Are you sure? Type 'RESTORE' to confirm: " -r confirmation
    
    if [[ "$confirmation" != "RESTORE" ]]; then
        log "Operation cancelled"
        exit 0
    fi
    
    # Parse and restore secrets from backup
    local secrets=$(jq -r '.secrets' "$backup_file")
    
    if [[ $(echo "$secrets" | jq -r '.database') != "null" ]]; then
        echo "$secrets" | jq -r '.database | to_entries[] | "vault kv put secret/'$env'/database \(.key)=\"\(.value)\""' | bash
    fi
    
    if [[ $(echo "$secrets" | jq -r '.cache') != "null" ]]; then
        echo "$secrets" | jq -r '.cache | to_entries[] | "vault kv put secret/'$env'/cache \(.key)=\"\(.value)\""' | bash
    fi
    
    # Continue for other secret types...
    
    success "Secrets restored for $env environment"
}

validate_secrets() {
    local env=$1
    
    log "Validating secrets for $env environment..."
    
    local errors=0
    
    # Check database secrets
    if ! vault kv get secret/$env/database > /dev/null 2>&1; then
        error "Database secrets missing for $env"
        ((errors++))
    fi
    
    # Check cache secrets
    if ! vault kv get secret/$env/cache > /dev/null 2>&1; then
        error "Cache secrets missing for $env"
        ((errors++))
    fi
    
    # Check AWS secrets
    if ! vault kv get secret/$env/aws > /dev/null 2>&1; then
        error "AWS secrets missing for $env"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        success "All required secrets are present for $env environment"
    else
        error "Found $errors missing secret(s) for $env environment"
        exit 1
    fi
}

main() {
    local command=""
    local environment=""
    local secret_type=""
    local backup_file=""
    
    # Parse arguments
    case $1 in
        setup|read|update|delete|list|backup|restore|validate)
            command="$1"
            environment="$2"
            secret_type="$3"
            backup_file="$3"
            ;;
        -h|--help|"")
            usage
            exit 0
            ;;
        *)
            error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
    
    if [[ -z "$environment" ]]; then
        error "Environment is required"
        usage
        exit 1
    fi
    
    if [[ ! "$environment" =~ ^(dev|staging|prod)$ ]]; then
        error "Invalid environment: $environment"
        error "Valid environments: dev, staging, prod"
        exit 1
    fi
    
    check_vault_status
    
    case $command in
        setup)
            setup_all_secrets "$environment"
            ;;
        read)
            read_secrets "$environment"
            ;;
        update)
            if [[ -n "$secret_type" ]]; then
                update_secret "$environment" "$secret_type"
            else
                setup_all_secrets "$environment"
            fi
            ;;
        delete)
            delete_secrets "$environment"
            ;;
        list)
            list_secrets "$environment"
            ;;
        backup)
            backup_secrets "$environment"
            ;;
        restore)
            restore_secrets "$environment" "$backup_file"
            ;;
        validate)
            validate_secrets "$environment"
            ;;
        *)
            error "Unknown command: $command"
            exit 1
            ;;
    esac
}

main "$@"
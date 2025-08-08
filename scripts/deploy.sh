#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENTS=("dev" "staging" "prod")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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
Usage: $0 [COMMAND] [ENVIRONMENT] [OPTIONS]

Commands:
    plan        - Run terraform plan
    apply       - Run terraform apply
    destroy     - Run terraform destroy
    validate    - Validate terraform configuration
    init        - Initialize terraform
    output      - Show terraform outputs
    refresh     - Refresh terraform state

Environments:
    dev         - Development environment
    staging     - Staging environment
    prod        - Production environment

Options:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -f, --force         Skip confirmation prompts
    --var-file FILE     Specify additional variables file
    --target RESOURCE   Target specific resource

Examples:
    $0 plan dev
    $0 apply prod --var-file=custom.tfvars
    $0 destroy staging --force
    $0 validate dev
EOF
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        error "Terraform is not installed. Please install Terraform first."
        exit 1
    fi
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install AWS CLI first."
        exit 1
    fi
    
    # Check if vault is installed
    if ! command -v vault &> /dev/null; then
        error "Vault CLI is not installed. Please install Vault CLI first."
        exit 1
    fi
    
    # Check terraform version
    TERRAFORM_VERSION=$(terraform version -json | jq -r '.terraform_version')
    log "Terraform version: $TERRAFORM_VERSION"
    
    success "Prerequisites check passed"
}

validate_environment() {
    local env=$1
    
    if [[ ! " ${ENVIRONMENTS[@]} " =~ " ${env} " ]]; then
        error "Invalid environment: $env"
        error "Valid environments: ${ENVIRONMENTS[*]}"
        exit 1
    fi
    
    if [[ ! -d "$ROOT_DIR/environments/$env" ]]; then
        error "Environment directory not found: $ROOT_DIR/environments/$env"
        exit 1
    fi
}

setup_environment() {
    local env=$1
    
    log "Setting up environment: $env"
    
    # Change to environment directory
    cd "$ROOT_DIR/environments/$env"
    
    # Set environment variables
    export TF_VAR_environment="$env"
    export TF_LOG_PATH="./terraform.log"

    # Vault configuration (non-blocking)
    # Prefer env, else ~/.vault-token, and validate if possible.
    if [[ -n "$VAULT_ADDR" && -z "$TF_VAR_vault_address" ]]; then
        export TF_VAR_vault_address="$VAULT_ADDR"
    fi

    if [[ -z "$VAULT_TOKEN" && -f "$HOME/.vault-token" ]]; then
        VAULT_TOKEN="$(cat "$HOME/.vault-token" 2>/dev/null || true)"
    fi

    if [[ -n "$VAULT_TOKEN" ]]; then
        export TF_VAR_vault_token="$VAULT_TOKEN"
    fi

    # Best-effort token validation if we have both address and token
    if [[ -n "$TF_VAR_vault_address" && -n "$TF_VAR_vault_token" ]]; then
        if VAULT_ADDR="$TF_VAR_vault_address" VAULT_TOKEN="$TF_VAR_vault_token" vault token lookup >/dev/null 2>&1; then
            log "Vault token validated"
        else
            warning "Vault token invalid or expired. Set VAULT_TOKEN and re-run, or run: VAULT_ADDR=$TF_VAR_vault_address vault login"
        fi
    else
        warning "Vault not configured. Export VAULT_ADDR and VAULT_TOKEN or set them in terraform.tfvars. Continuing without blocking."
    fi
    
    success "Environment setup complete"
}

terraform_init() {
    local extra_args=("$@")
    log "Initializing Terraform..."
    terraform init -upgrade "${extra_args[@]}"
}

terraform_validate() {
    log "Validating Terraform configuration..."
    terraform validate
}

terraform_plan() {
    local var_file="$1"; shift || true
    local target_resource="$1"; shift || true
    local args=("-var-file=./terraform.tfvars")
    [[ -n "$var_file" ]] && args+=("-var-file=$var_file")
    [[ -n "$target_resource" ]] && args+=("-target=$target_resource")
    log "Planning changes..."
    terraform plan "${args[@]}"
}

terraform_apply() {
    local var_file="$1"; shift || true
    local target_resource="$1"; shift || true
    local force="$1"; shift || true
    local args=("-var-file=./terraform.tfvars")
    [[ -n "$var_file" ]] && args+=("-var-file=$var_file")
    [[ -n "$target_resource" ]] && args+=("-target=$target_resource")
    if [[ "$force" == "true" ]]; then
        args+=("-auto-approve")
    fi
    log "Applying changes..."
    terraform apply "${args[@]}"
}

terraform_destroy() {
    local force="$1"; shift || true
    local args=("-var-file=./terraform.tfvars")
    if [[ "$force" == "true" ]]; then
        args+=("-auto-approve")
    fi
    log "Destroying resources..."
    terraform destroy "${args[@]}"
}

terraform_output() {
    terraform output -json || terraform output
}

terraform_refresh() {
    terraform refresh
}

main() {
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    local command="$1"; shift
    local env="$1"; shift

    # Flags
    local var_file=""
    local target=""
    local force="false"
    local verbose="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage; exit 0 ;;
            -v|--verbose)
                verbose="true"; export TF_LOG=INFO; shift ;;
            -f|--force)
                force="true"; shift ;;
            --var-file)
                var_file="$2"; shift 2 ;;
            --target)
                target="$2"; shift 2 ;;
            *)
                warning "Unknown option: $1"; shift ;;
        esac
    done

    check_prerequisites
    validate_environment "$env"
    setup_environment "$env"

    case "$command" in
        init)
            terraform_init ;;
        validate)
            terraform_validate ;;
        plan)
            terraform_init
            terraform_plan "$var_file" "$target" ;;
        apply)
            terraform_init
            terraform_apply "$var_file" "$target" "$force" ;;
        destroy)
            terraform_init
            terraform_destroy "$force" ;;
        output)
            terraform_output ;;
        refresh)
            terraform_refresh ;;
        *)
            error "Unknown command: $command"; usage; exit 1 ;;
    esac
}

main "$@"
#!/usr/bin/env bash
# setup-cloud-sql.sh — Configure a Cloud Run service to connect to Cloud SQL.
# Handles IAM, connection string, secrets, and optional VPC private IP setup.
#
# Usage:
#   ./setup-cloud-sql.sh proxy  <service> <sql-instance> [region]    # Auth Proxy (public IP)
#   ./setup-cloud-sql.sh vpc    <service> <sql-instance> [region]    # Private IP via VPC
#   ./setup-cloud-sql.sh secret <secret-name> <password>             # Create DB password secret
#   ./setup-cloud-sql.sh check  <sql-instance>                       # Verify SQL instance status
#
# Environment variables (optional):
#   CLOUD_RUN_REGION      Default region (default: us-central1)
#   DB_USER               Database username (default: app)
#   DB_NAME               Database name (default: appdb)
#   DB_SECRET             Secret Manager secret name for password (default: db-password)

set -euo pipefail

DEFAULT_REGION="${CLOUD_RUN_REGION:-us-central1}"
DB_USER="${DB_USER:-app}"
DB_NAME="${DB_NAME:-appdb}"
DB_SECRET="${DB_SECRET:-db-password}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

get_project() {
    gcloud config get-value project 2>/dev/null || die "No active GCP project"
}

get_service_account() {
    local service="$1" region="$2"
    gcloud run services describe "$service" --region="$region" \
        --format="value(spec.template.spec.serviceAccountName)" 2>/dev/null
}

cmd_proxy() {
    local service="$1" instance="$2" region="$3"
    local project
    project=$(get_project)
    local conn_string="$project:$region:$instance"

    log "Configuring Cloud Run service '$service' with Cloud SQL Auth Proxy"
    log "Connection string: $conn_string"

    # Get or determine service account
    local sa
    sa=$(get_service_account "$service" "$region" 2>/dev/null || true)
    if [[ -z "$sa" ]]; then
        sa="$(gcloud projects describe "$project" --format='value(projectNumber)')"-compute@developer.gserviceaccount.com
        log "Using default compute SA: $sa"
    else
        log "Service account: $sa"
    fi

    # Grant Cloud SQL Client role
    log "Granting roles/cloudsql.client to $sa"
    gcloud projects add-iam-policy-binding "$project" \
        --member="serviceAccount:$sa" \
        --role="roles/cloudsql.client" \
        --quiet --no-user-output-enabled 2>/dev/null || true

    # Grant Secret Manager access
    log "Granting roles/secretmanager.secretAccessor to $sa"
    gcloud projects add-iam-policy-binding "$project" \
        --member="serviceAccount:$sa" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet --no-user-output-enabled 2>/dev/null || true

    # Update Cloud Run service
    log "Updating Cloud Run service with Cloud SQL connection"
    gcloud run services update "$service" \
        --add-cloudsql-instances="$conn_string" \
        --update-env-vars="DB_HOST=/cloudsql/$conn_string,DB_USER=$DB_USER,DB_NAME=$DB_NAME" \
        --update-secrets="DB_PASS=$DB_SECRET:latest" \
        --region="$region" \
        --quiet

    log "Done. Service '$service' is now connected to Cloud SQL instance '$instance' via Auth Proxy."
    log "Connection path: /cloudsql/$conn_string"
}

cmd_vpc() {
    local service="$1" instance="$2" region="$3"
    local project
    project=$(get_project)

    # Get Cloud SQL private IP
    local private_ip
    private_ip=$(gcloud sql instances describe "$instance" \
        --format="value(ipAddresses[0].ipAddress)" 2>/dev/null) || die "Cannot get IP for instance $instance"

    log "Configuring Cloud Run service '$service' with Cloud SQL via Private IP"
    log "Private IP: $private_ip"

    # Check if service has VPC connectivity
    local vpc_status
    vpc_status=$(gcloud run services describe "$service" --region="$region" \
        --format="value(spec.template.metadata.annotations['run.googleapis.com/vpc-access-connector'])" 2>/dev/null || true)
    local net_status
    net_status=$(gcloud run services describe "$service" --region="$region" \
        --format="value(spec.template.metadata.annotations['run.googleapis.com/network-interfaces'])" 2>/dev/null || true)

    if [[ -z "$vpc_status" && -z "$net_status" ]]; then
        die "Service '$service' has no VPC connectivity. Configure --vpc-connector or --network/--subnet first."
    fi

    # Determine database port based on instance type
    local db_port=5432
    local db_type
    db_type=$(gcloud sql instances describe "$instance" --format="value(databaseVersion)" 2>/dev/null || echo "")
    if [[ "$db_type" == MYSQL* ]]; then
        db_port=3306
    elif [[ "$db_type" == SQLSERVER* ]]; then
        db_port=1433
    fi
    log "Database type: $db_type (port $db_port)"

    # Update Cloud Run service
    gcloud run services update "$service" \
        --update-env-vars="DB_HOST=$private_ip,DB_PORT=$db_port,DB_USER=$DB_USER,DB_NAME=$DB_NAME" \
        --update-secrets="DB_PASS=$DB_SECRET:latest" \
        --region="$region" \
        --quiet

    log "Done. Service '$service' connects to Cloud SQL at $private_ip:$db_port via VPC."
}

cmd_secret() {
    local secret_name="$1" password="$2"
    local project
    project=$(get_project)

    log "Creating secret '$secret_name' in Secret Manager"

    if gcloud secrets describe "$secret_name" --project="$project" &>/dev/null; then
        log "Secret exists. Adding new version."
        echo -n "$password" | gcloud secrets versions add "$secret_name" --data-file=- --quiet
    else
        echo -n "$password" | gcloud secrets create "$secret_name" \
            --data-file=- --replication-policy=automatic --quiet
    fi

    log "Secret '$secret_name' ready."
}

cmd_check() {
    local instance="$1"
    log "Checking Cloud SQL instance: $instance"

    gcloud sql instances describe "$instance" \
        --format="table(name,state,databaseVersion,settings.tier,ipAddresses[].ipAddress,region)"

    echo ""
    log "Connection name:"
    gcloud sql instances describe "$instance" --format="value(connectionName)"
}

# --- Main ---
ACTION="${1:-}"
case "$ACTION" in
    proxy|vpc)
        SERVICE="${2:-}"
        INSTANCE="${3:-}"
        REGION="${4:-$DEFAULT_REGION}"
        [[ -z "$SERVICE" || -z "$INSTANCE" ]] && die "Usage: $0 $ACTION <service> <sql-instance> [region]"
        "cmd_$ACTION" "$SERVICE" "$INSTANCE" "$REGION"
        ;;
    secret)
        SECRET_NAME="${2:-}"
        PASSWORD="${3:-}"
        [[ -z "$SECRET_NAME" || -z "$PASSWORD" ]] && die "Usage: $0 secret <secret-name> <password>"
        cmd_secret "$SECRET_NAME" "$PASSWORD"
        ;;
    check)
        INSTANCE="${2:-}"
        [[ -z "$INSTANCE" ]] && die "Usage: $0 check <sql-instance>"
        cmd_check "$INSTANCE"
        ;;
    *)
        echo "Usage: $0 {proxy|vpc|secret|check} ..."
        echo ""
        echo "Commands:"
        echo "  proxy  <service> <sql-instance> [region]  Connect via Cloud SQL Auth Proxy"
        echo "  vpc    <service> <sql-instance> [region]  Connect via Private IP (requires VPC)"
        echo "  secret <name> <password>                  Create/update DB password secret"
        echo "  check  <sql-instance>                     Show SQL instance status and connection info"
        exit 1
        ;;
esac

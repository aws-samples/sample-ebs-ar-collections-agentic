#!/bin/bash
set -e

# =============================================================================
# Oracle EBS Cash Flow Analytics — Teardown Script
# =============================================================================
# Destroys all AWS resources created by deploy.sh in the correct order:
#   1. Glue Zero-ETL integration (must go before Redshift cluster)
#   2. AgentCore runtime (runs outside CloudFormation)
#   3. S3 bucket contents (buckets can't be deleted while non-empty)
#   4. CloudFormation stack (Redshift, Lambda, Cognito, API GW, CloudFront)
#   5. Secrets Manager secret (optional, requires --delete-secrets)
#
# Usage:
#   ./destroy.sh                    # Interactive — prompts for confirmation
#   ./destroy.sh --force            # Skip confirmation
#   ./destroy.sh --delete-secrets   # Also delete the EBS credentials secret
#   ./destroy.sh --force --delete-secrets
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy-config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[destroy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[destroy]${NC} $1"; }
error() { echo -e "${RED}[destroy]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[destroy]${NC} $1"; }

FORCE=0
DELETE_SECRETS=0
for arg in "$@"; do
  case "$arg" in
    --force)          FORCE=1 ;;
    --delete-secrets) DELETE_SECRETS=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      warn "Unknown argument: $arg"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
[ -f "$CONFIG_FILE" ] || error "deploy-config.json not found."

_read_cfg() {
  python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
keys = '$1'.split('.')
v = c
for k in keys:
    v = v.get(k) if isinstance(v, dict) else None
print(v if v is not None else '')
"
}

REGION=$(_read_cfg 'aws_region')
STACK_NAME=$(_read_cfg 'stack_name')
CLUSTER_ID=$(_read_cfg 'redshift.cluster_id')
SECRET_NAME=$(_read_cfg 'oracle_ebs.secret_name')
INTEGRATION_NAME=$(_read_cfg 'zero_etl.integration_name')
AGENT_NAME="cash_flow_analytics_agent"

[ -z "$REGION" ] && error "aws_region not set in deploy-config.json"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION") \
  || error "Cannot determine AWS account ID."

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo ""
warn "This will destroy all resources for the Cash Flow Analytics deployment:"
echo "  - Region:        $REGION"
echo "  - Account:       $ACCOUNT_ID"
echo "  - Stack:         $STACK_NAME"
echo "  - Integration:   $INTEGRATION_NAME"
echo "  - Agent:         $AGENT_NAME"
if [ "$DELETE_SECRETS" -eq 1 ]; then
  echo "  - Secret:        $SECRET_NAME (will be deleted)"
else
  echo "  - Secret:        $SECRET_NAME (RETAINED — use --delete-secrets to remove)"
fi
echo ""

if [ "$FORCE" -ne 1 ]; then
  read -p "Type 'destroy' to continue: " CONFIRM
  if [ "$CONFIRM" != "destroy" ]; then
    error "Aborted."
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# 1. Glue Zero-ETL integration
# ---------------------------------------------------------------------------
destroy_zero_etl() {
  log "Deleting Zero-ETL integration: ${INTEGRATION_NAME}"

  INT_ARN=$(aws glue describe-integrations --region "$REGION" \
    --query "Integrations[?IntegrationName=='${INTEGRATION_NAME}'].IntegrationArn" \
    --output text 2>/dev/null || echo "")

  if [ -z "$INT_ARN" ] || [ "$INT_ARN" = "None" ]; then
    info "  No integration found — skipping"
    return
  fi

  aws glue delete-integration \
    --integration-identifier "$INT_ARN" \
    --region "$REGION" \
    --output text --query 'Status' >/dev/null 2>&1 || {
      warn "  Failed to delete integration (may already be deleting)"
      return
    }

  log "  Waiting for integration deletion..."
  for i in $(seq 1 30); do
    STATUS=$(aws glue describe-integrations --region "$REGION" \
      --query "Integrations[?IntegrationName=='${INTEGRATION_NAME}'].Status" \
      --output text 2>/dev/null || echo "")
    if [ -z "$STATUS" ] || [ "$STATUS" = "None" ]; then
      log "  ✓ Integration deleted"
      break
    fi
    info "    $i/30: $STATUS"
    sleep 15
  done
  echo ""
}

# ---------------------------------------------------------------------------
# 2. AgentCore runtime
# ---------------------------------------------------------------------------
destroy_agent() {
  log "Deleting AgentCore runtime: ${AGENT_NAME}"

  # List runtimes and find by name
  RUNTIMES_JSON=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$REGION" --output json 2>/dev/null || echo '{"agentRuntimes":[]}')

  RUNTIME_IDS=$(echo "$RUNTIMES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('agentRuntimes', []):
    name = r.get('agentRuntimeName', '')
    rid = r.get('agentRuntimeId', '')
    if name.startswith('${AGENT_NAME}'):
        print(rid)
" 2>/dev/null || echo "")

  if [ -z "$RUNTIME_IDS" ]; then
    info "  No AgentCore runtime found — skipping"
    return
  fi

  for RID in $RUNTIME_IDS; do
    log "  Deleting runtime: $RID"
    aws bedrock-agentcore-control delete-agent-runtime \
      --agent-runtime-id "$RID" \
      --region "$REGION" \
      --output text --query 'status' >/dev/null 2>&1 \
      && log "    ✓ Deleted" \
      || warn "    Delete failed (may already be gone)"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# 3. Empty S3 buckets (so CFN can delete them)
# ---------------------------------------------------------------------------
empty_s3_buckets() {
  log "Emptying S3 buckets..."

  for BUCKET in "cash-flow-frontend-${ACCOUNT_ID}" "cash-flow-logs-${ACCOUNT_ID}"; do
    if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
      log "  Emptying s3://${BUCKET}"
      # Delete current objects
      aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" 2>/dev/null >/dev/null || true

      # Delete all object versions and delete markers (handles pagination)
      python3 -c "
import boto3
s3 = boto3.client('s3', region_name='${REGION}')
paginator = s3.get_paginator('list_object_versions')
deleted = 0
for page in paginator.paginate(Bucket='${BUCKET}'):
    objects = []
    for v in page.get('Versions', []):
        objects.append({'Key': v['Key'], 'VersionId': v['VersionId']})
    for dm in page.get('DeleteMarkers', []):
        objects.append({'Key': dm['Key'], 'VersionId': dm['VersionId']})
    if objects:
        # delete_objects handles up to 1000 per call
        for i in range(0, len(objects), 1000):
            s3.delete_objects(Bucket='${BUCKET}', Delete={'Objects': objects[i:i+1000], 'Quiet': True})
        deleted += len(objects)
print(f'  Deleted {deleted} object versions/markers from ${BUCKET}')
" 2>/dev/null || true
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# 4. CloudFormation stack
# ---------------------------------------------------------------------------
destroy_stack() {
  log "Deleting CloudFormation stack: ${STACK_NAME}"

  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "DOES_NOT_EXIST")

  if echo "$STATUS" | grep -q "does not exist\|DOES_NOT_EXIST"; then
    info "  Stack does not exist — skipping"
    return
  fi

  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION" 2>&1 || warn "  delete-stack returned non-zero (continuing)"

  log "  Waiting for stack deletion..."
  for i in $(seq 1 60); do
    STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "does not exist")

    if echo "$STATUS" | grep -q "does not exist"; then
      log "  ✓ Stack deleted"
      return
    fi

    if [ "$STATUS" = "DELETE_FAILED" ]; then
      warn "  Stack DELETE_FAILED. Checking what couldn't delete..."
      FAILED=$(aws cloudformation list-stack-resources \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
        --output text 2>/dev/null || echo "")
      echo "$FAILED" | while IFS=$'\t' read -r LID REASON; do
        warn "    - $LID: $REASON"
      done

      # Retry with --retain-resources for S3 buckets
      warn "  Re-emptying buckets and retrying with --retain-resources for stuck S3..."
      empty_s3_buckets

      RETAIN=$(aws cloudformation list-stack-resources \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED' && ResourceType=='AWS::S3::Bucket'].LogicalResourceId" \
        --output text 2>/dev/null || echo "")

      if [ -n "$RETAIN" ]; then
        # Force-delete the buckets outside CFN
        for LID in $RETAIN; do
          BUCKET=$(aws cloudformation describe-stack-resource \
            --stack-name "$STACK_NAME" --logical-resource-id "$LID" \
            --region "$REGION" --query 'StackResourceDetail.PhysicalResourceId' \
            --output text 2>/dev/null || echo "")
          [ -n "$BUCKET" ] && aws s3 rb "s3://${BUCKET}" --force --region "$REGION" 2>/dev/null || true
        done
        RETAIN_ARGS=$(echo "$RETAIN" | tr '\n' ' ')
        aws cloudformation delete-stack \
          --stack-name "$STACK_NAME" \
          --retain-resources $RETAIN_ARGS \
          --region "$REGION" 2>&1 || true
      else
        aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION" 2>&1 || true
      fi
    fi

    info "    $i/60: $STATUS"
    sleep 15
  done

  warn "  Stack deletion timed out after 15 min. Check the CloudFormation console."
  echo ""
}

# ---------------------------------------------------------------------------
# 5. Secrets Manager (optional)
# ---------------------------------------------------------------------------
destroy_secret() {
  if [ "$DELETE_SECRETS" -ne 1 ]; then
    info "Secret '${SECRET_NAME}' retained. Use --delete-secrets to remove."
    return
  fi

  log "Deleting Secrets Manager secret: ${SECRET_NAME}"
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery \
    --region "$REGION" \
    --output text --query 'ARN' 2>/dev/null \
    && log "  ✓ Secret deleted" \
    || info "  Secret not found or already deleted"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
destroy_zero_etl
destroy_agent
empty_s3_buckets
destroy_stack
destroy_secret

log "All done ✓"
info ""
info "Notes:"
info "  - ECR images, CodeBuild projects, and IAM roles created by AgentCore are not deleted."
info "    Run 'agentcore destroy --force --delete-ecr-repo' on the server to clean those up."
info "  - Redshift automated snapshots may persist for up to 35 days."
info "  - Oracle EBS PL/SQL packages are NOT affected by this script."

#!/bin/bash
set -e

# =============================================================================
# Oracle EBS Cash Flow Analytics — Unified Deployment Script
# =============================================================================
# Deploys all AWS components from deploy-config.json:
#   0. Secrets Manager secret (EBS credentials)
#   1. CloudFormation stack (infrastructure: S3, CloudFront, Cognito, API GW)
#   2. Collections Lambda (ebs-collections-actions)
#   3. Zero-ETL integration (Glue) — validates connectivity before creation
#   4. AgentCore Agent (cash_flow_analytics_agent)
#   5. Frontend (React → S3 → CloudFront)
#
# Post-deployment (after Zero ETL initial load completes):
#   ./deploy.sh views              # Create Redshift analytical views
#
# Usage:
#   ./deploy.sh                    # Deploy all components (except views)
#   ./deploy.sh secrets            # Create/update Secrets Manager secret only
#   ./deploy.sh infra              # Deploy only CloudFormation stack
#   ./deploy.sh lambda             # Deploy only the collections Lambda
#   ./deploy.sh zero-etl           # Deploy only Zero-ETL integration
#   ./deploy.sh views              # Deploy Redshift views (after Zero ETL replication)
#   ./deploy.sh agent              # Deploy only the AgentCore agent
#   ./deploy.sh frontend           # Deploy only the frontend
#   ./deploy.sh secrets infra lambda zero-etl # Deploy multiple components
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy-config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[deploy]${NC} $1"; }
error() { echo -e "${RED}[deploy]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[deploy]${NC} $1"; }

# ---------------------------------------------------------------------------
# Config loader — reads deploy-config.json via _read_config.py helper
# (avoids shell→Python string interpolation; values pass via argv, not source)
# ---------------------------------------------------------------------------
load_config() {
  [ -f "$CONFIG_FILE" ] || error "deploy-config.json not found. Copy the template and fill in your values."
  [ -f "${SCRIPT_DIR}/_read_config.py" ] || error "_read_config.py helper not found at ${SCRIPT_DIR}"

  # Read config values via the standalone helper (key passes via argv, no interpolation)
  _read_cfg() {
    python3 "${SCRIPT_DIR}/_read_config.py" "$1" "$CONFIG_FILE"
  }

  REGION=$(_read_cfg 'aws_region')
  STACK_NAME=$(_read_cfg 'stack_name')
  CLUSTER_ID=$(_read_cfg 'redshift.cluster_id')
  DATABASE=$(_read_cfg 'redshift.database')
  DB_USER=$(_read_cfg 'redshift.db_user')
  EBS_HOST=$(_read_cfg 'oracle_ebs.host')
  EBS_PORT=$(_read_cfg 'oracle_ebs.port')
  SECRET_NAME=$(_read_cfg 'oracle_ebs.secret_name')
  # Optional: TLS verification toggle for EBS REST. Defaults to "true" (secure).
  # Set oracle_ebs.verify_ssl=false in deploy-config.json ONLY for UAT hosts
  # with self-signed/expired certs. Never disable in production.
  EBS_VERIFY_SSL=$(_read_cfg 'oracle_ebs.verify_ssl')
  [ -z "$EBS_VERIFY_SSL" ] && EBS_VERIFY_SSL="true"
  MODEL_ID=$(_read_cfg 'agentcore.model_id')
  EXECUTION_ROLE=$(_read_cfg 'agentcore.execution_role')
  VPC_ID=$(_read_cfg 'vpc.vpc_id')
  SUBNET_IDS=$(_read_cfg 'vpc.subnet_ids')
  SECURITY_GROUP_ID=$(_read_cfg 'vpc.security_group_id')
  LAMBDA_FUNCTION="ebs-collections-actions"

  # Validate required values
  MISSING=""
  [ -z "$REGION" ]      && MISSING="${MISSING}  - aws_region\n"
  [ -z "$DATABASE" ]    && MISSING="${MISSING}  - redshift.database\n"
  [ -z "$DB_USER" ]     && MISSING="${MISSING}  - redshift.db_user\n"
  [ -z "$EBS_HOST" ]    && MISSING="${MISSING}  - oracle_ebs.host\n"
  [ -z "$EBS_PORT" ]    && MISSING="${MISSING}  - oracle_ebs.port\n"
  [ -z "$SECRET_NAME" ] && MISSING="${MISSING}  - oracle_ebs.secret_name\n"

  if [ -n "$MISSING" ]; then
    error "deploy-config.json has null/empty required values:\n${MISSING}Fill in these values before deploying."
  fi

  # Derive account ID from current credentials
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION") \
    || error "Cannot determine AWS account ID. Check your credentials."

  log "Account: ${ACCOUNT_ID} | Region: ${REGION} | Stack: ${STACK_NAME}"
}

# ---------------------------------------------------------------------------
# 0. Secrets Manager — EBS Credentials
# ---------------------------------------------------------------------------
deploy_secrets() {
  log "Setting up Secrets Manager secret: ${SECRET_NAME}"

  # Check if secret already exists
  if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
    info "  Secret '${SECRET_NAME}' already exists."
    info "  To update it: aws secretsmanager update-secret --secret-id ${SECRET_NAME} --secret-string '{\"sysadmin\":\"<NEW_PASSWORD>\"}' --region ${REGION}"
    log "Secrets Manager secret exists ✓"
    echo ""
    return
  fi

  log "Secret '${SECRET_NAME}' does not exist. Creating..."

  # Prompt for EBS sysadmin password
  echo ""
  info "  The Lambda function needs Oracle EBS sysadmin credentials to call ISG REST APIs."
  info "  These are stored securely in AWS Secrets Manager as '${SECRET_NAME}'."
  echo ""
  echo -n "  Enter EBS sysadmin password (input hidden): "
  read -s EBS_PASSWORD
  echo ""

  if [ -z "$EBS_PASSWORD" ]; then
    error "Password cannot be empty."
  fi

  # Create the secret
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Oracle EBS sysadmin credentials for ISG REST API (used by collections Lambda)" \
    --secret-string "{\"sysadmin\":\"${EBS_PASSWORD}\"}" \
    --region "$REGION" \
    --output text --query 'ARN'

  # Clear password from memory
  EBS_PASSWORD=""

  log "Secrets Manager secret created ✓"
  info "  To update later: aws secretsmanager update-secret --secret-id ${SECRET_NAME} --secret-string '{\"sysadmin\":\"<PASSWORD>\"}' --region ${REGION}"
  echo ""
}

# ---------------------------------------------------------------------------
# 1. CloudFormation Infrastructure
# ---------------------------------------------------------------------------
deploy_infra() {
  log "Deploying CloudFormation stack: ${STACK_NAME}"

  CFN_TEMPLATE="${SCRIPT_DIR}/frontend/infrastructure.yaml"
  [ -f "$CFN_TEMPLATE" ] || error "CloudFormation template not found at $CFN_TEMPLATE"

  # Build parameters as a JSON array. Values are passed via environment variables
  # (NOT interpolated into Python source) to avoid quote-injection from any
  # config value that contains a single or double quote.
  PARAMS_JSON=$(
    SES_SENDER=$(_read_cfg 'ses.sender_email') \
    EXECUTION_ROLE="$EXECUTION_ROLE" \
    VPC_ID="$VPC_ID" \
    SUBNET_IDS="$SUBNET_IDS" \
    SECURITY_GROUP_ID="$SECURITY_GROUP_ID" \
    DATABASE="$DATABASE" \
    DB_USER="$DB_USER" \
    CLUSTER_ID="$CLUSTER_ID" \
    EBS_HOST="$EBS_HOST" \
    EBS_PORT="$EBS_PORT" \
    SECRET_NAME="$SECRET_NAME" \
    python3 - << 'PYEOF'
import json, os
params = []
def add(key, env_name):
    val = os.environ.get(env_name, '')
    if val:
        params.append({"ParameterKey": key, "ParameterValue": val})

add("AgentRuntimeArn", "EXECUTION_ROLE")
add("VpcId", "VPC_ID")
add("SubnetIds", "SUBNET_IDS")
add("SecurityGroupId", "SECURITY_GROUP_ID")
add("RedshiftDatabaseName", "DATABASE")
add("RedshiftMasterUsername", "DB_USER")
add("RedshiftClusterIdentifier", "CLUSTER_ID")
add("EbsHost", "EBS_HOST")
add("EbsPort", "EBS_PORT")
add("EbsSecretName", "SECRET_NAME")
add("SenderEmail", "SES_SENDER")

print(json.dumps(params))
PYEOF
)

  # Check if stack exists
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  # Write parameters JSON to a temp file (avoids shell quoting issues)
  PARAMS_FILE=$(mktemp /tmp/cfn-params.XXXXXX.json)
  trap "rm -f $PARAMS_FILE" EXIT
  echo "$PARAMS_JSON" > "$PARAMS_FILE"

  if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
    log "Creating new stack..."
    if [ "$PARAMS_JSON" != "[]" ]; then
      aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://${CFN_TEMPLATE}" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameters "file://${PARAMS_FILE}" \
        --region "$REGION" \
        --output text --query 'StackId'
    else
      aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://${CFN_TEMPLATE}" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --region "$REGION" \
        --output text --query 'StackId'
    fi

    log "Waiting for stack creation..."
    aws cloudformation wait stack-create-complete \
      --stack-name "$STACK_NAME" \
      --region "$REGION"
  else
    log "Updating existing stack (status: ${STACK_STATUS})..."
    if [ "$PARAMS_JSON" != "[]" ]; then
      UPDATE_OUTPUT=$(aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://${CFN_TEMPLATE}" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameters "file://${PARAMS_FILE}" \
        --region "$REGION" \
        --output text --query 'StackId' 2>&1)
    else
      UPDATE_OUTPUT=$(aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://${CFN_TEMPLATE}" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --region "$REGION" \
        --output text --query 'StackId' 2>&1)
    fi

    if [ $? -ne 0 ]; then
      if echo "$UPDATE_OUTPUT" | grep -qi "no updates"; then
        warn "No updates to apply (stack is current)."
      else
        warn "Update failed: $UPDATE_OUTPUT"
      fi
      _read_stack_outputs
      return
    fi

    log "Waiting for stack update..."
    aws cloudformation wait stack-update-complete \
      --stack-name "$STACK_NAME" \
      --region "$REGION"
  fi

  _read_stack_outputs
  log "CloudFormation stack deployed ✓"
  echo ""
}

_read_stack_outputs() {
  log "Reading stack outputs..."
  STACK_OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output json 2>/dev/null || echo "[]")

  CF_URL=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='CloudFrontURL': print(o['OutputValue'])
" 2>/dev/null || echo "")

  WS_URL=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='WebSocketURL': print(o['OutputValue'])
" 2>/dev/null || echo "")

  USER_POOL_ID=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='UserPoolId': print(o['OutputValue'])
" 2>/dev/null || echo "")

  USER_POOL_CLIENT_ID=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='UserPoolClientId': print(o['OutputValue'])
" 2>/dev/null || echo "")

  S3_BUCKET=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='WebsiteBucket': print(o['OutputValue'])
" 2>/dev/null || echo "cash-flow-frontend-${ACCOUNT_ID}")

  # Override CLUSTER_ID from stack output (CFN-created Redshift)
  CFN_CLUSTER_ID=$(echo "$STACK_OUTPUTS" | python3 -c "
import json,sys
outputs=json.load(sys.stdin)
for o in outputs:
  if o['OutputKey']=='RedshiftClusterId': print(o['OutputValue'])
" 2>/dev/null || echo "")
  if [ -n "$CFN_CLUSTER_ID" ]; then
    CLUSTER_ID="$CFN_CLUSTER_ID"
  fi

  if [ -n "$CF_URL" ]; then
    info "  CloudFront:  ${CF_URL}"
    info "  WebSocket:   ${WS_URL}"
    info "  UserPool:    ${USER_POOL_ID}"
    info "  ClientId:    ${USER_POOL_CLIENT_ID}"
    info "  S3 Bucket:   ${S3_BUCKET}"
  fi
}

# ---------------------------------------------------------------------------
# 2. Collections Lambda
# ---------------------------------------------------------------------------
deploy_lambda() {
  log "Deploying collections Lambda: ${LAMBDA_FUNCTION}"

  LAMBDA_DIR="${SCRIPT_DIR}/collections_agent/lambda"
  ZIP_FILE="${SCRIPT_DIR}/lambda-package.zip"

  [ -f "$LAMBDA_DIR/ebs_collections_actions.py" ] || error "Lambda source not found at $LAMBDA_DIR"

  rm -f "$ZIP_FILE"

  log "Packaging Lambda zip..."
  (
    cd "$LAMBDA_DIR"

    # Clean any previously vendored deps so nothing stale leaks into the zip.
    rm -rf requests certifi charset_normalizer idna urllib3 \
           *.dist-info __pycache__ bin ./*.so

    # Install everything EXCEPT charset_normalizer as Linux x86_64 / py3.11 wheels.
    # charset_normalizer ships an optional mypyc-compiled .so that is fragile to
    # package correctly (it lives as a top-level sibling file and breaks imports
    # on Lambda with "No module named '<hash>__mypyc'"). We install it separately
    # as the universal pure-Python wheel so the package is self-contained and
    # import-safe on any runtime — no compiled extensions at all.
    pip install requests==2.31.0 -t . \
      --platform manylinux2014_x86_64 \
      --python-version 3.11 \
      --implementation cp \
      --abi cp311 \
      --only-binary=:all: \
      || error "Lambda dependency install failed. Ensure pip>=20.3 and internet access to PyPI."

    # Force the pure-Python (py3-none-any) charset_normalizer wheel, overwriting
    # any compiled variant pulled in as a transitive dep above.
    pip install "charset-normalizer==3.3.2" -t . --upgrade \
      --platform any \
      --python-version 3.11 \
      --implementation py \
      --only-binary=:all: \
      || error "charset-normalizer pure-Python install failed."

    # Belt-and-suspenders: ensure no compiled charset_normalizer artifact remains.
    rm -f ./*__mypyc*.so
    find charset_normalizer -name '*.so' -delete 2>/dev/null || true

    zip -qr "$ZIP_FILE" \
      ebs_collections_actions.py \
      requests/ \
      certifi/ \
      charset_normalizer/ \
      idna/ \
      urllib3/
  ) || error "Lambda packaging failed"

  ZIPSIZE=$(du -h "$ZIP_FILE" | cut -f1)
  log "Package created: $ZIP_FILE ($ZIPSIZE)"

  # Check if Lambda exists (created by CloudFormation)
  if ! aws lambda get-function --function-name "$LAMBDA_FUNCTION" --region "$REGION" &>/dev/null; then
    warn "Lambda function ${LAMBDA_FUNCTION} does not exist yet."
    warn "Run './deploy.sh infra' first to create it via CloudFormation."
    warn "Skipping Lambda deployment."
    return
  fi

  # Update environment variables from config
  log "Updating Lambda environment variables..."
  LAMBDA_UPDATE_ARGS="--function-name $LAMBDA_FUNCTION --region $REGION"
  LAMBDA_UPDATE_ARGS="${LAMBDA_UPDATE_ARGS} --environment Variables={CLUSTER_ID=${CLUSTER_ID},DATABASE=${DATABASE},DB_USER=${DB_USER},EBS_HOST=${EBS_HOST},EBS_PORT=${EBS_PORT},SECRET_NAME=${SECRET_NAME},AWS_REGION_NAME=${REGION},EBS_VERIFY_SSL=${EBS_VERIFY_SSL}}"

  # Add VPC config if provided — places Lambda in EBiz VPC to reach ISG REST API
  if [ -n "$VPC_ID" ] && [ -n "$SUBNET_IDS" ] && [ -n "$SECURITY_GROUP_ID" ]; then
    log "Configuring Lambda VPC: ${VPC_ID} (subnets: ${SUBNET_IDS})"
    LAMBDA_UPDATE_ARGS="${LAMBDA_UPDATE_ARGS} --vpc-config SubnetIds=${SUBNET_IDS},SecurityGroupIds=${SECURITY_GROUP_ID}"
  fi

  aws lambda update-function-configuration \
    $LAMBDA_UPDATE_ARGS \
    --output text --query 'FunctionArn' 2>/dev/null || true

  aws lambda wait function-updated-v2 \
    --function-name "$LAMBDA_FUNCTION" \
    --region "$REGION" 2>/dev/null || true

  log "Updating Lambda function code..."
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION" \
    --zip-file "fileb://$ZIP_FILE" \
    --region "$REGION" \
    --output text --query 'FunctionArn'

  log "Waiting for Lambda update to complete..."
  aws lambda wait function-updated-v2 \
    --function-name "$LAMBDA_FUNCTION" \
    --region "$REGION" 2>/dev/null || true

  log "Collections Lambda deployed ✓"

  # --- WebSocket Lambdas (authorizer + handler) ---
  WEBSOCKET_DIR="${SCRIPT_DIR}/frontend/lambda"
  WEBSOCKET_ZIP="${SCRIPT_DIR}/websocket-package.zip"

  AUTHORIZER_FUNCTION="cash-flow-websocket-authorizer"
  HANDLER_FUNCTION="cash-flow-websocket-handler"

  # Install dependencies if not already present
  if [ ! -d "$WEBSOCKET_DIR/jose" ]; then
    log "Installing WebSocket Lambda dependencies..."
    (
      cd "$WEBSOCKET_DIR"

      # Clean any stale host-native deps before installing.
      rm -rf jose cryptography cffi pycparser ecdsa pyasn1 rsa \
             *.dist-info __pycache__ ./*.so six.py

      # Linux x86_64 wheels matching the Lambda runtime (Python 3.11).
      # No silent fallback to a host-native install — that is what produces
      # packages that import locally but fail on Lambda.
      pip install -r "$WEBSOCKET_DIR/requirements.txt" -t "$WEBSOCKET_DIR" \
        --platform manylinux2014_x86_64 \
        --python-version 3.11 \
        --implementation cp \
        --abi cp311 \
        --only-binary=:all: \
        || error "WebSocket Lambda dependency install failed. Ensure pip>=20.3 and that prebuilt manylinux wheels exist for all packages in requirements.txt."
    ) || error "WebSocket Lambda dependency packaging failed"
  fi

  if aws lambda get-function --function-name "$AUTHORIZER_FUNCTION" --region "$REGION" &>/dev/null; then
    log "Deploying WebSocket authorizer Lambda: ${AUTHORIZER_FUNCTION}"
    rm -f "$WEBSOCKET_ZIP"
    (
      cd "$WEBSOCKET_DIR"
      zip -qr "$WEBSOCKET_ZIP" \
        authorizer.py \
        jose/ \
        cryptography/ \
        cffi/ \
        pycparser/ \
        ecdsa/ \
        pyasn1/ \
        rsa/ \
        six.py
      # Add any compiled extensions
      for so in *.so; do
        [ -f "$so" ] && zip -q "$WEBSOCKET_ZIP" "$so"
      done
    )
    aws lambda update-function-code \
      --function-name "$AUTHORIZER_FUNCTION" \
      --zip-file "fileb://$WEBSOCKET_ZIP" \
      --region "$REGION" \
      --output text --query 'FunctionArn'
    aws lambda wait function-updated-v2 \
      --function-name "$AUTHORIZER_FUNCTION" \
      --region "$REGION" 2>/dev/null || true
    log "WebSocket authorizer Lambda deployed ✓"
  else
    warn "Authorizer Lambda ${AUTHORIZER_FUNCTION} does not exist yet. Run './deploy.sh infra' first."
  fi

  if aws lambda get-function --function-name "$HANDLER_FUNCTION" --region "$REGION" &>/dev/null; then
    log "Deploying WebSocket handler Lambda: ${HANDLER_FUNCTION}"
    rm -f "$WEBSOCKET_ZIP"
    (
      cd "$WEBSOCKET_DIR"
      zip -qr "$WEBSOCKET_ZIP" \
        websocket_handler.py \
        boto3/ \
        botocore/ \
        jmespath/ \
        s3transfer/ \
        dateutil/ \
        six.py \
        requests/ \
        certifi/ \
        charset_normalizer/ \
        idna/ \
        urllib3/
    )
    aws lambda update-function-code \
      --function-name "$HANDLER_FUNCTION" \
      --zip-file "fileb://$WEBSOCKET_ZIP" \
      --region "$REGION" \
      --output text --query 'FunctionArn'
    aws lambda wait function-updated-v2 \
      --function-name "$HANDLER_FUNCTION" \
      --region "$REGION" 2>/dev/null || true
    log "WebSocket handler Lambda deployed ✓"
  else
    warn "Handler Lambda ${HANDLER_FUNCTION} does not exist yet. Run './deploy.sh infra' first."
  fi

  rm -f "$WEBSOCKET_ZIP"

  echo ""
}

# ---------------------------------------------------------------------------
# 3. Redshift Views
# ---------------------------------------------------------------------------
deploy_views() {
  log "Creating Redshift analytical views"

  # Ensure we have the cluster ID from CFN if not in config
  if [ -z "$CLUSTER_ID" ]; then
    _read_stack_outputs
  fi
  [ -z "$CLUSTER_ID" ] && error "Redshift cluster ID not found. Run './deploy.sh infra' first."

  [ -f "${SCRIPT_DIR}/setup_redshift_views.py" ] || error "setup_redshift_views.py not found"

  # Check that Zero ETL tables exist before creating views.
  # Values pass via env vars (not source interpolation) to avoid quote-injection.
  log "Checking if Zero ETL tables exist in Redshift..."
  TABLE_CHECK=$(
    REGION="$REGION" \
    CLUSTER_ID="$CLUSTER_ID" \
    DATABASE="$DATABASE" \
    DB_USER="$DB_USER" \
    python3 - << 'PYEOF' 2>/dev/null
import boto3, os, time
rs = boto3.client('redshift-data', region_name=os.environ['REGION'])
r = rs.execute_statement(
    ClusterIdentifier=os.environ['CLUSTER_ID'],
    Database=os.environ['DATABASE'] + '_zetl',
    DbUser=os.environ['DB_USER'],
    Sql=("SELECT schemaname || '.' || tablename FROM pg_tables "
         "WHERE tablename ILIKE '%payment_schedules%' LIMIT 1")
)
for _ in range(30):
    s = rs.describe_statement(Id=r['Id'])
    if s['Status'] == 'FINISHED':
        break
    if s['Status'] in ('FAILED', 'ABORTED'):
        print('QUERY_FAILED')
        raise SystemExit(0)
    time.sleep(1)
res = rs.get_statement_result(Id=r['Id'])
print('FOUND' if res['TotalNumRows'] > 0 else 'NOT_FOUND')
PYEOF
)
  [ -z "$TABLE_CHECK" ] && TABLE_CHECK="QUERY_FAILED"

  if [ "$TABLE_CHECK" != "FOUND" ]; then
    warn "Zero ETL tables not yet available in Redshift."
    warn "The Zero ETL initial load must complete before views can be created."
    warn "Check replication status in the AWS DMS or Glue console, then run:"
    warn ""
    warn "  ./deploy.sh views"
    warn ""
    return
  fi

  # Export for setup_redshift_views.py
  export CLUSTER_ID DATABASE DB_USER REGION

  python3 "${SCRIPT_DIR}/setup_redshift_views.py" || error "View creation failed"

  log "Redshift views deployed ✓"
  echo ""
}

# ---------------------------------------------------------------------------
# 4. Zero-ETL Integration
# ---------------------------------------------------------------------------
deploy_zero_etl() {
  log "Setting up Zero-ETL integration"

  [ -f "${SCRIPT_DIR}/setup_zero_etl.py" ] || error "setup_zero_etl.py not found"

  python3 "${SCRIPT_DIR}/setup_zero_etl.py" || ZETL_RC=$?
  ZETL_RC=${ZETL_RC:-0}

  if [ $ZETL_RC -eq 0 ]; then
    log "Zero-ETL integration deployed ✓"
  elif [ $ZETL_RC -eq 2 ]; then
    log "Zero-ETL integration already exists or in progress — skipping ✓"
  else
    error "Zero-ETL setup failed"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# 5. AgentCore Agent
# ---------------------------------------------------------------------------
deploy_agent() {
  log "Deploying AgentCore agent: cash_flow_analytics_agent"

  AGENT_DIR="${SCRIPT_DIR}/agentcore_version"

  [ -f "$AGENT_DIR/agent_strands.py" ] || error "Agent source not found at $AGENT_DIR"

  # Ensure the chart-output bucket exists with a 1-day expiration policy.
  # Done at deploy time (with deployer credentials) rather than from the agent
  # runtime, because the runtime's assumed-role session policy strips
  # s3:PutLifecycleConfiguration even when the role itself has admin perms.
  # Idempotent: head-bucket succeeds → skip create; lifecycle put is always
  # safe to re-run.
  CHART_BUCKET="cash-flow-charts-${ACCOUNT_ID}"
  log "Ensuring chart bucket s3://${CHART_BUCKET} exists with 1-day expiry..."

  if aws s3api head-bucket --bucket "$CHART_BUCKET" --region "$REGION" 2>/dev/null; then
    log "  bucket exists ✓"
  else
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$CHART_BUCKET" --region "$REGION" >/dev/null \
        && log "  bucket created ✓" \
        || warn "  could not create chart bucket (continuing — agent will retry on first chart)"
    else
      aws s3api create-bucket --bucket "$CHART_BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" >/dev/null \
        && log "  bucket created ✓" \
        || warn "  could not create chart bucket (continuing — agent will retry on first chart)"
    fi
  fi

  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$CHART_BUCKET" --region "$REGION" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-charts-1d","Status":"Enabled","Filter":{"Prefix":"charts/"},"Expiration":{"Days":1}}]}' 2>/dev/null \
    && log "  lifecycle (charts/ → expire 1d) applied ✓" \
    || warn "  could not apply lifecycle policy — charts may accumulate"

  if ! command -v agentcore &>/dev/null; then
    log "Installing agentcore CLI..."
    pip install bedrock-agentcore-starter-toolkit --quiet
  fi

  if ! command -v uv &>/dev/null; then
    log "Installing uv (required by agentcore deploy)..."
    pip install uv --quiet
  fi

  # Update agentcore.yaml with config values.
  # Values pass via env vars to avoid quote-injection from $CONFIG_FILE / $AGENT_DIR.
  log "Updating agentcore.yaml with config values..."
  CONFIG_FILE="$CONFIG_FILE" AGENT_DIR="$AGENT_DIR" python3 - << 'PYEOF' 2>/dev/null || warn "Could not auto-update agentcore.yaml (pyyaml may not be installed). Update manually."
import json, os, yaml
cfg = json.load(open(os.environ['CONFIG_FILE']))
ac_path = os.path.join(os.environ['AGENT_DIR'], 'agentcore.yaml')
with open(ac_path) as f:
    ac = yaml.safe_load(f)
ac['region'] = cfg['aws_region']
ac['runtime']['environment']['AWS_REGION'] = cfg['aws_region']
ac['runtime']['environment']['CLUSTER_ID'] = cfg['redshift']['cluster_id']
ac['runtime']['environment']['DATABASE'] = cfg['redshift']['database']
ac['runtime']['environment']['DB_USER'] = cfg['redshift']['db_user']
ac['runtime']['environment']['MODEL_ID'] = cfg['agentcore']['model_id']
role = cfg['agentcore'].get('execution_role', '')
if role:
    ac['execution_role'] = role
with open(ac_path, 'w') as f:
    yaml.dump(ac, f, default_flow_style=False)
print('agentcore.yaml updated')
PYEOF

  # Generate .bedrock_agentcore.yaml in the format the CLI expects.
  # Values pass via env vars (no shell→Python source interpolation).
  log "Generating .bedrock_agentcore.yaml..."
  CONFIG_FILE="$CONFIG_FILE" AGENT_DIR="$AGENT_DIR" ACCOUNT_ID="$ACCOUNT_ID" \
  python3 - << 'PYEOF' || error "Could not generate .bedrock_agentcore.yaml"
import json, os, yaml
cfg = json.load(open(os.environ['CONFIG_FILE']))
agent_dir = os.environ['AGENT_DIR']
account_id = os.environ['ACCOUNT_ID']
agent_name = 'cash_flow_analytics_agent'
region = cfg['aws_region']
role = cfg['agentcore'].get('execution_role', '') or None

ac = {
    'default_agent': agent_name,
    'agents': {
        agent_name: {
            'name': agent_name,
            'language': 'python',
            'entrypoint': os.path.join(agent_dir, 'agent_strands.py'),
            'deployment_type': 'direct_code_deploy',
            'runtime_type': 'PYTHON_3_10',
            'platform': 'linux/amd64',
            'source_path': agent_dir,
            'aws': {
                'execution_role': role,
                'execution_role_auto_create': role is None,
                'account': account_id,
                'region': region,
                'network_configuration': {'network_mode': 'PUBLIC'},
                'protocol_configuration': {'server_protocol': 'HTTP'},
                'observability': {'enabled': True},
            },
            'memory': {'mode': 'NO_MEMORY'},
        }
    }
}

with open(os.path.join(agent_dir, '.bedrock_agentcore.yaml'), 'w') as f:
    yaml.dump(ac, f, default_flow_style=False)
print('.bedrock_agentcore.yaml generated')
PYEOF

  log "Running agentcore deploy..."
  (
    cd "$AGENT_DIR"
    agentcore deploy --auto-update-on-conflict \
      --env AWS_REGION="$REGION" \
      --env CLUSTER_ID="$CLUSTER_ID" \
      --env DATABASE="$DATABASE" \
      --env DB_USER="$DB_USER" \
      --env COLLECTIONS_LAMBDA="$LAMBDA_FUNCTION" \
      --env MODEL_ID="$MODEL_ID"
  )

  log "AgentCore agent deployed ✓"

  # Attach tool permissions (Redshift Data API, Lambda invoke, Secrets Manager, SES)
  # to the AgentCore-created execution role
  AGENT_NAME="cash_flow_analytics_agent"
  log "Attaching tool permissions to AgentCore execution role..."

  AGENT_EXEC_ROLE=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeId | [0]" \
    --output text 2>/dev/null || echo "")

  if [ -n "$AGENT_EXEC_ROLE" ] && [ "$AGENT_EXEC_ROLE" != "None" ]; then
    AGENT_ROLE_ARN=$(aws bedrock-agentcore-control get-agent-runtime \
      --agent-runtime-id "$AGENT_EXEC_ROLE" \
      --region "$REGION" \
      --query 'roleArn' --output text 2>/dev/null || echo "")

    if [ -n "$AGENT_ROLE_ARN" ] && [ "$AGENT_ROLE_ARN" != "None" ]; then
      AGENT_ROLE_NAME=$(echo "$AGENT_ROLE_ARN" | awk -F'/' '{print $NF}')
      log "Agent execution role: ${AGENT_ROLE_NAME}"

      ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      TOOL_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RedshiftDataAPIExecute",
      "Effect": "Allow",
      "Action": [
        "redshift-data:ExecuteStatement",
        "redshift-data:BatchExecuteStatement"
      ],
      "Resource": "arn:aws:redshift:${REGION}:${ACCOUNT_ID}:cluster:${CLUSTER_ID}"
    },
    {
      "Sid": "RedshiftDataAPIRead",
      "Effect": "Allow",
      "Action": [
        "redshift-data:DescribeStatement",
        "redshift-data:GetStatementResult",
        "redshift-data:ListStatements",
        "redshift-data:CancelStatement"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RedshiftGetCredentials",
      "Effect": "Allow",
      "Action": [
        "redshift:GetClusterCredentials",
        "redshift:DescribeClusters"
      ],
      "Resource": [
        "arn:aws:redshift:${REGION}:${ACCOUNT_ID}:cluster:${CLUSTER_ID}",
        "arn:aws:redshift:${REGION}:${ACCOUNT_ID}:dbuser:${CLUSTER_ID}/${DB_USER}",
        "arn:aws:redshift:${REGION}:${ACCOUNT_ID}:dbname:${CLUSTER_ID}/*"
      ]
    },
    {
      "Sid": "InvokeCollectionsLambda",
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION}"
    },
    {
      "Sid": "GetEbsSecret",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${SECRET_NAME}*"
    },
    {
      "Sid": "SESSendEmail",
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "arn:aws:ses:${REGION}:${ACCOUNT_ID}:identity/*"
    },
    {
      "Sid": "CodeInterpreterAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:StartCodeInterpreterSession",
        "bedrock-agentcore:InvokeCodeInterpreter",
        "bedrock-agentcore:StopCodeInterpreterSession",
        "bedrock-agentcore:GetCodeInterpreterSession",
        "bedrock-agentcore:ListCodeInterpreterSessions"
      ],
      "Resource": "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:*"
    },
    {
      "Sid": "ChartBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:HeadBucket",
        "s3:CreateBucket"
      ],
      "Resource": [
        "arn:aws:s3:::cash-flow-charts-${ACCOUNT_ID}",
        "arn:aws:s3:::cash-flow-charts-${ACCOUNT_ID}/*"
      ]
    }
  ]
}
EOF
)

      aws iam put-role-policy \
        --role-name "$AGENT_ROLE_NAME" \
        --policy-name "CashFlowAgentToolPermissions" \
        --policy-document "$TOOL_POLICY" \
        --region "$REGION" 2>/dev/null \
        && log "Agent tool permissions attached ✓" \
        || warn "Could not attach tool permissions to ${AGENT_ROLE_NAME}"
    else
      warn "Could not resolve agent execution role ARN — skipping policy attachment"
    fi
  else
    warn "Could not find agent runtime — skipping policy attachment"
  fi

  # Update WebSocket handler Lambda with the agent ARN
  HANDLER_FUNCTION="cash-flow-websocket-handler"
  AGENT_NAME="cash_flow_analytics_agent"
  AGENT_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes \
    --region "$REGION" \
    --query "agentRuntimes[?agentRuntimeName=='${AGENT_NAME}'].agentRuntimeArn | [0]" \
    --output text 2>/dev/null || true)

  if [ -n "$AGENT_RUNTIME_ARN" ] && [ "$AGENT_RUNTIME_ARN" != "None" ]; then
    log "Updating ${HANDLER_FUNCTION} with AGENT_ARN=${AGENT_RUNTIME_ARN}"
    aws lambda update-function-configuration \
      --function-name "$HANDLER_FUNCTION" \
      --region "$REGION" \
      --environment "Variables={AGENT_ARN=${AGENT_RUNTIME_ARN},WEBSOCKET_STAGE=prod,WEBSOCKET_DOMAIN=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='cash-flow-websocket-api'].ApiEndpoint" --output text | sed 's|wss://||'),CONNECTIONS_TABLE=cash-flow-websocket-connections}" \
      --output text --query 'FunctionArn' 2>/dev/null || warn "Could not update AGENT_ARN on ${HANDLER_FUNCTION}"
    aws lambda wait function-updated-v2 \
      --function-name "$HANDLER_FUNCTION" \
      --region "$REGION" 2>/dev/null || true
    log "WebSocket handler AGENT_ARN updated ✓"

    # Update CloudFormation stack with agent ARN so IAM policy allows InvokeAgentRuntime
    log "Updating CloudFormation stack with AgentRuntimeArn..."
    CFN_TEMPLATE="${SCRIPT_DIR}/frontend/infrastructure.yaml"
    aws cloudformation update-stack \
      --stack-name "$STACK_NAME" \
      --template-body "file://$CFN_TEMPLATE" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --parameters \
        ParameterKey=AgentRuntimeArn,ParameterValue="$AGENT_RUNTIME_ARN" \
        ParameterKey=VpcId,UsePreviousValue=true \
        ParameterKey=SubnetIds,UsePreviousValue=true \
        ParameterKey=SecurityGroupId,UsePreviousValue=true \
        ParameterKey=EbsHost,UsePreviousValue=true \
        ParameterKey=EbsPort,UsePreviousValue=true \
        ParameterKey=EbsSecretName,UsePreviousValue=true \
        ParameterKey=SenderEmail,UsePreviousValue=true \
        ParameterKey=RedshiftNodeType,UsePreviousValue=true \
        ParameterKey=RedshiftNumberOfNodes,UsePreviousValue=true \
        ParameterKey=RedshiftMasterUsername,UsePreviousValue=true \
        ParameterKey=RedshiftMasterPassword,UsePreviousValue=true \
        ParameterKey=RedshiftDatabaseName,UsePreviousValue=true \
        ParameterKey=RedshiftClusterIdentifier,UsePreviousValue=true \
      --region "$REGION" \
      --output text 2>/dev/null && \
    aws cloudformation wait stack-update-complete \
      --stack-name "$STACK_NAME" \
      --region "$REGION" 2>/dev/null && \
    log "CloudFormation stack updated with AgentRuntimeArn ✓" || \
    warn "CloudFormation update skipped (stack may already have this value or no changes detected)"
  else
    warn "Could not retrieve AgentCore runtime ARN. Update AGENT_ARN on ${HANDLER_FUNCTION} manually."
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# 6. Frontend
# ---------------------------------------------------------------------------
deploy_frontend() {
  log "Deploying frontend to S3 + CloudFront"

  FRONTEND_DIR="${SCRIPT_DIR}/frontend"

  [ -f "$FRONTEND_DIR/package.json" ] || error "Frontend source not found at $FRONTEND_DIR"

  # Read stack outputs if not already loaded
  if [ -z "$S3_BUCKET" ] || [ -z "$WS_URL" ]; then
    _read_stack_outputs
  fi

  # Update frontend aws-config.js with stack outputs
  if [ -n "$USER_POOL_ID" ] && [ -n "$USER_POOL_CLIENT_ID" ] && [ -n "$WS_URL" ]; then
    log "Updating frontend/src/aws-config.js with stack outputs..."
    cat > "${FRONTEND_DIR}/src/aws-config.js" <<JSEOF
// AWS Resource Configuration — auto-generated by deploy.sh
const awsConfig = {
  region: '${REGION}',
  userPoolId: '${USER_POOL_ID}',
  userPoolClientId: '${USER_POOL_CLIENT_ID}',
  websocketUrl: '${WS_URL}',
};

export default awsConfig;
JSEOF
    log "aws-config.js updated"
  else
    warn "Stack outputs not available. aws-config.js not updated — update manually."
  fi

  (
    cd "$FRONTEND_DIR"

    if [ ! -d "node_modules" ]; then
      log "Installing npm dependencies..."
      npm install
    fi

    log "Building React app..."
    npm run build

    # Use bucket from stack outputs or derive from account
    S3_BUCKET="${S3_BUCKET:-cash-flow-frontend-${ACCOUNT_ID}}"

    log "Uploading to s3://${S3_BUCKET}/"
    aws s3 sync build/ "s3://${S3_BUCKET}/" \
      --delete \
      --cache-control "public,max-age=31536000,immutable" \
      --exclude "index.html" \
      --region "$REGION"

    aws s3 cp build/index.html "s3://${S3_BUCKET}/index.html" \
      --cache-control "no-cache,no-store,must-revalidate" \
      --region "$REGION"

    # Invalidate CloudFront
    CF_DIST_ID=$(aws cloudfront list-distributions \
      --query "DistributionList.Items[?Origins.Items[0].DomainName=='${S3_BUCKET}.s3.${REGION}.amazonaws.com'].Id" \
      --output text 2>/dev/null || echo "")

    if [ -n "$CF_DIST_ID" ] && [ "$CF_DIST_ID" != "None" ]; then
      log "Invalidating CloudFront: ${CF_DIST_ID}"
      aws cloudfront create-invalidation \
        --distribution-id "$CF_DIST_ID" \
        --paths "/*" \
        --output text --query 'Invalidation.Id'
    else
      warn "Could not auto-detect CloudFront distribution. Invalidate manually if needed."
    fi
  )

  if [ -n "$CF_URL" ]; then
    log "Frontend deployed ✓  →  ${CF_URL}"
  else
    log "Frontend deployed ✓"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
load_config

TARGETS=("$@")

# Default: deploy everything in order
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("secrets" "infra" "lambda" "zero-etl" "agent" "frontend")
fi

echo ""
log "Deploying: ${TARGETS[*]}"
echo "============================================="
echo ""

for target in "${TARGETS[@]}"; do
  case "$target" in
    secrets)  deploy_secrets  ;;
    infra)    deploy_infra    ;;
    lambda)   deploy_lambda   ;;
    views)    deploy_views    ;;
    zero-etl) deploy_zero_etl ;;
    agent)    deploy_agent    ;;
    frontend) deploy_frontend ;;
    *)        error "Unknown target: $target (valid: secrets, infra, lambda, views, zero-etl, agent, frontend)" ;;
  esac
done

log "All done ✓"
